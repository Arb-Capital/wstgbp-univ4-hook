// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IwstGBP} from "./interfaces/IwstGBP.sol";
import {IMaseerAct, IMaseerPip} from "./interfaces/IMaseerFeeds.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title WstGBPHybridHook (M2 — best-execution: third-party LP + backstop)
/// @notice Like {WstGBPBackstopHook}, but lets third-party concentrated LP coexist in the pool and
///         gives swappers best execution: a swap first consumes LP that beats the backstop edge
///         (filling the real AMM, so the pool fee accrues to those LPs), then backstops the
///         remainder via `wstGBP.mint`/`redeem` at the edge (mintcost for buys / burncost for sells).
///         LP priced worse than the current edge is never used (the backstop is always at least as
///         good) and is arbed back into the band by the backstop itself.
///
/// @dev Mechanism: `beforeSwap` runs a reentrancy-guarded **nested** `poolManager.swap` bounded at
///      the fee-adjusted edge to consume in-band LP, then backstops the residual, then returns a
///      combined `BeforeSwapDelta`. The fee adjustment (`mintcost*(1-fee)` / `burncost/(1-fee)`)
///      ensures the swapper's all-in price never exceeds the backstop edge. Settle-first routing is
///      still required (the backstop takes the input from the PoolManager during `beforeSwap`).
///
///      Pool convention: currency0 = tGBP, currency1 = wstGBP. zeroForOne = BUY wstGBP. Exact-input
///      and exact-output are both supported.
contract WstGBPHybridHook is BaseHook {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PIPS = 1_000_000;
    /// @dev 1e18 << 192, the numerator for converting a WAD tGBP/wstGBP price to sqrtPriceX96.
    uint256 internal constant PRICE_NUMERATOR = uint256(1e18) << 192;

    Currency public immutable currency0; // tGBP
    Currency public immutable currency1; // wstGBP
    IwstGBP public immutable wrapper;
    address public immutable tgbp;
    address public immutable wst;
    /// @dev The wrapper's two immutable price feeds, cached so the hook can read the backstop price
    ///      directly (act.mintcost(pip.read())) and skip the wrapper's dispatch hop. Byte-identical to
    ///      `wrapper.mintcost()`/`burncost()`/`cooldown()` because `mint`/`redeem` use the same feeds.
    IMaseerAct public immutable act;
    IMaseerPip public immutable pip;

    /// @dev Reentrancy guard: while true, the (nested) swap is the hook's own AMM fill, so the swap
    ///      callback is a passthrough and the backstop logic is skipped. Transient (EIP-1153): the flag
    ///      only lives within a single transaction and auto-clears at its end, so the hook keeps no
    ///      persistent storage at all.
    bool private transient _inNestedSwap;

    error BadCurrencyOrdering();
    error PoolNotSupported();
    error WrapperUnderfunded(uint256 needed, uint256 available);
    error RedeemUnderpaid(uint256 expected, uint256 received);
    error BackstopResidualTooSmall();
    error TransferFailed();

    constructor(IPoolManager _poolManager, IwstGBP _wrapper) BaseHook(_poolManager) {
        wrapper = _wrapper;
        wst = address(_wrapper);
        address _tgbp = _wrapper.gem();
        tgbp = _tgbp;
        act = IMaseerAct(_wrapper.act());
        pip = IMaseerPip(_wrapper.pip());
        if (_tgbp >= wst) revert BadCurrencyOrdering();
        currency0 = Currency.wrap(_tgbp);
        currency1 = Currency.wrap(wst);
        // One-time max approval so `wrapper.mint` can pull tGBP during swaps. Unbounded is safe: the
        // hook holds no persistent tGBP (only transient sub-unit dust) and the wrapper is trusted, so
        // it exposes nothing extra; a just-in-time exact approval would only add an SSTORE per buy.
        IERC20Minimal(_tgbp).approve(wst, type(uint256).max);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false, // LP is ALLOWED in the hybrid
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Passthrough for the hook's own nested AMM fill: let the real AMM run, no backstop.
        if (_inNestedSwap) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        if (Currency.unwrap(key.currency0) != tgbp || Currency.unwrap(key.currency1) != wst) {
            revert PoolNotSupported();
        }

        // A non-zero redemption cooldown makes `wstGBP.redeem` non-atomic, so the sell backstop cannot
        // settle within the swap. Fall back to pool liquidity only: step aside (zero delta) so the
        // outer AMM fills the sell against in-range LP. The swapper is protected by the router's
        // slippage bounds (minAmountOut on exact-in, full-delivery on exact-out). Buys are unaffected
        // because mint is always atomic.
        if (!params.zeroForOne && act.cooldown() != 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // The backstop price for this direction (mintcost for buys / burncost for sells), read once and
        // reused for both the AMM edge and the residual backstop. Constant within the tx, so this is
        // identical to reading it separately in each helper — it just avoids the extra oracle hops.
        uint256 cost = params.zeroForOne ? _mintcost() : _burncost();

        // 1) Fill in-band LP via a nested AMM swap bounded at the fee-adjusted backstop edge.
        uint160 edge = _edgeSqrtPrice(params.zeroForOne, key.fee, cost);
        (uint256 ammIn, uint256 ammOut) = _fillAmm(key, params.zeroForOne, params.amountSpecified, edge);

        // 2) Backstop the residual and combine. The specified leg cancels the OUTER swap entirely so
        //    the outer AMM is a no-op; the unspecified leg is the combined input/output.
        BeforeSwapDelta delta;
        if (params.amountSpecified < 0) {
            // EXACT-INPUT: backstop the residual input; deliver AMM output + backstop output. A residual
            // below the wrapper's mint/redeem threshold can't be backstopped, so it is neither taken nor
            // charged — only `ammIn + inConsumed` is billed, and the unfillable remainder is left in the
            // PoolManager for the router to refund (or for the outer AMM to fill as bonus output). The
            // hook keeps no dust.
            uint256 amountIn = uint256(-params.amountSpecified);
            (uint256 bOut, uint256 inConsumed) = _backstopExactIn(params.zeroForOne, amountIn - ammIn, cost);
            uint256 totalOut = ammOut + bOut;
            uint256 totalIn = ammIn + inConsumed;
            delta = toBeforeSwapDelta(totalIn.toInt128(), -totalOut.toInt128());
        } else {
            // EXACT-OUTPUT: backstop the residual output; charge AMM input + backstop input.
            uint256 amountOut = uint256(params.amountSpecified);
            uint256 totalIn = ammIn + _backstopExactOut(params.zeroForOne, amountOut - ammOut, cost);
            delta = toBeforeSwapDelta(-amountOut.toInt128(), totalIn.toInt128());
        }
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev Run a nested AMM swap bounded at `edge` (same `amountSpecified` sign as the outer swap:
    ///      negative = exact-input, positive = exact-output), returning the input consumed and output
    ///      received (both positive). Skips the AMM if the price is already at/past the edge.
    function _fillAmm(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 edge)
        internal
        returns (uint256 ammIn, uint256 ammOut)
    {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        bool hasRoom = zeroForOne ? sqrtP > edge : sqrtP < edge;
        if (!hasRoom) return (0, 0);

        _inNestedSwap = true;
        BalanceDelta d = poolManager.swap(key, SwapParams(zeroForOne, amountSpecified, edge), "");
        _inNestedSwap = false;

        if (zeroForOne) {
            ammIn = uint256(uint128(-d.amount0())); // tGBP paid into the AMM
            ammOut = uint256(uint128(d.amount1())); // wstGBP received
        } else {
            ammIn = uint256(uint128(-d.amount1())); // wstGBP paid into the AMM
            ammOut = uint256(uint128(d.amount0())); // tGBP received
        }
    }

    /// @dev Exact-input backstop. Returns the output produced AND the input actually consumed. A
    ///      residual below the wrapper's mint/redeem threshold can't be wrapped, so it is left
    ///      untouched (NOT taken from the PoolManager): the caller bills only `inConsumed`, and the
    ///      router refunds the remainder — the hook keeps no dust. Output is settled to the
    ///      PoolManager; the input-side delta is reconciled by the combined `BeforeSwapDelta`.
    function _backstopExactIn(bool zeroForOne, uint256 residualIn, uint256 cost)
        internal
        returns (uint256 out, uint256 inConsumed)
    {
        if (residualIn == 0) return (0, 0);

        if (zeroForOne) {
            // BUY: below the mint threshold the wrapper can't mint; leave it for the router to refund.
            // `cost` is mintcost for this direction.
            if (residualIn < cost) return (0, 0);
            poolManager.take(currency0, address(this), residualIn);
            out = wrapper.mint(residualIn);
            _settleToManager(currency1, out);
            inConsumed = residualIn;
        } else {
            // SELL: below the redeem minimum the wrapper can't redeem; leave it for the router to refund.
            if (residualIn < WAD) return (0, 0);
            uint256 claim = FullMath.mulDiv(residualIn, cost, WAD); // `cost` is burncost
            _requireWrapperFunded(claim);
            poolManager.take(currency1, address(this), residualIn);
            out = _redeem(residualIn);
            // Guard against a non-atomic (cooldown()>0) redeem silently paying nothing.
            if (out < claim) revert RedeemUnderpaid(claim, out);
            _settleToManager(currency0, out);
            inConsumed = residualIn;
        }
    }

    /// @dev Exact-output backstop: produce exactly `residualOut` of the output currency via the
    ///      wrapper (rounding the input up, keeping any surplus as dust), settle it to the
    ///      PoolManager, and return the input spent. The input is taken from the PoolManager (the
    ///      router pre-settled it); the surplus over what the backstop needs is refunded by the
    ///      router via its `maxAmountIn` accounting.
    function _backstopExactOut(bool zeroForOne, uint256 residualOut, uint256 cost) internal returns (uint256 inSpent) {
        if (residualOut == 0) return 0;

        if (zeroForOne) {
            // BUY exact-out: need `residualOut` wstGBP; pay tGBP. `cost` is mintcost.
            uint256 tgbpIn = FullMath.mulDivRoundingUp(residualOut, cost, WAD);
            // A sub-threshold residual can't be minted at a fair price (the wrapper needs >= mintcost
            // in). Revert rather than clamp the input up and overcharge the swapper for the shortfall
            // (which would also make the hybrid worse than the pure backstop and leave dust in the hook).
            if (tgbpIn < cost) revert BackstopResidualTooSmall();
            poolManager.take(currency0, address(this), tgbpIn);
            wrapper.mint(tgbpIn); // mints >= residualOut wstGBP; <= 1 wei rounding surplus stays as dust
            _settleToManager(currency1, residualOut);
            inSpent = tgbpIn;
        } else {
            // SELL exact-out: need `residualOut` tGBP; pay wstGBP. `cost` is burncost.
            uint256 wIn = FullMath.mulDivRoundingUp(residualOut, WAD, cost);
            // A sub-threshold residual can't be redeemed (the wrapper needs >= 1 wstGBP in). Revert
            // rather than clamp the input up and overcharge the swapper.
            if (wIn < WAD) revert BackstopResidualTooSmall();
            uint256 claim = FullMath.mulDiv(wIn, cost, WAD); // >= residualOut
            _requireWrapperFunded(claim);
            poolManager.take(currency1, address(this), wIn);
            uint256 received = _redeem(wIn); // returns >= residualOut tGBP; surplus stays as dust
            if (received < residualOut) revert RedeemUnderpaid(residualOut, received);
            _settleToManager(currency0, residualOut);
            inSpent = wIn;
        }
    }

    /// @dev The sqrtPriceX96 at which the swapper's all-in AMM price equals the backstop edge.
    ///      Buy ceiling = mintcost*(1-fee); sell floor = burncost/(1-fee). Returns a price limit
    ///      clamped to valid bounds.
    function _edgeSqrtPrice(bool zeroForOne, uint24 fee, uint256 cost) internal pure returns (uint160) {
        uint256 adj = zeroForOne
            ? FullMath.mulDiv(cost, PIPS - fee, PIPS)  // mintcost*(1-fee)
            : FullMath.mulDiv(cost, PIPS, PIPS - fee); // burncost/(1-fee)
        // sqrtPriceX96 = sqrt( (1e18 << 192) / adj ), since pool price (wstGBP/tGBP) = 1e18/adj.
        uint256 sp = FixedPointMathLib.sqrt(PRICE_NUMERATOR / adj);
        if (sp <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sp);
    }

    /// @dev The backstop ask, read directly off the wrapper's immutable feeds (== `wrapper.mintcost()`).
    function _mintcost() internal view returns (uint256) {
        return act.mintcost(pip.read());
    }

    /// @dev The backstop bid, read directly off the wrapper's immutable feeds (== `wrapper.burncost()`).
    function _burncost() internal view returns (uint256) {
        return act.burncost(pip.read());
    }

    function _redeem(uint256 wIn) internal returns (uint256 received) {
        uint256 before = IERC20Minimal(tgbp).balanceOf(address(this));
        wrapper.redeem(wIn);
        received = IERC20Minimal(tgbp).balanceOf(address(this)) - before;
    }

    function _requireWrapperFunded(uint256 needed) internal view {
        uint256 available = IERC20Minimal(tgbp).balanceOf(wst);
        if (available < needed) revert WrapperUnderfunded(needed, available);
    }

    function _settleToManager(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        _safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
        poolManager.settle();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), to)
            mstore(add(ptr, 0x24), amount)

            ok := call(gas(), token, 0, ptr, 0x44, 0, 0x20)
            if ok {
                switch returndatasize()
                case 0 { ok := 1 }
                case 0x20 {
                    returndatacopy(ptr, 0, 0x20)
                    ok := iszero(iszero(mload(ptr)))
                }
                default { ok := 0 }
            }
        }
        if (!ok) revert TransferFailed();
    }
}
