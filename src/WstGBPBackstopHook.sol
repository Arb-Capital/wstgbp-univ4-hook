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
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title WstGBPBackstopHook (pure backstop — no AMM/LP)
/// @notice A Uniswap v4 hook that gives a tGBP/wstGBP pool effectively unlimited depth by routing
///         every swap through the wstGBP wrapper's atomic mint/redeem at the protocol's own prices:
///         buys execute at `wstGBP.mintcost()`, sells at `wstGBP.burncost()`. LP adds are blocked.
///
/// @dev `beforeSwap` returns a `BeforeSwapDelta` whose specified leg exactly cancels the swap so the
///      AMM is bypassed entirely. The hook `take`s the swap's input currency from the PoolManager,
///      feeds it into `wstGBP.mint`/`redeem`, and `settle`s the output — wrapping the swap's own
///      tokens with no inventory. Settle-first routing required (see `WstGBPSwapRouter`).
///
///      Pool convention (enforced in the constructor): currency0 = tGBP, currency1 = wstGBP, so
///      `zeroForOne == true` is a BUY of wstGBP and `false` is a SELL. Ownerless, holds no capital.
///
/// @dev SLIPPAGE IS THE CALLER'S RESPONSIBILITY. `beforeSwap` executes at the wrapper's live oracle price
///      (`mintcost`/`burncost`) with NO intrinsic slippage check, price floor, or sanity bound — it is a
///      pure price-taker. wstGBP governance can move that price/spread between blocks (fees settable up to
///      100%), so an unbounded swap (e.g. `minAmountOut == 0`, or a custom settle-first integration with no
///      bounds) executes at whatever the oracle says, however unfavorable. Always swap through
///      `WstGBPSwapRouter` (or a solver) that enforces `minAmountOut`/`maxAmountIn`. See the README trust
///      model.
contract WstGBPBackstopHook is BaseHook {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;

    Currency public immutable currency0; // tGBP (lower address)
    Currency public immutable currency1; // wstGBP
    IwstGBP public immutable wrapper;
    address public immutable tgbp;
    address public immutable wst;
    /// @dev The wrapper's two immutable price feeds, cached so the hook can read the backstop price
    ///      directly (act.mintcost(pip.read())) and skip the wrapper's dispatch hop. Byte-identical to
    ///      `wrapper.mintcost()`/`burncost()`/`cooldown()` because `mint`/`redeem` use the same feeds.
    IMaseerAct public immutable act;
    IMaseerPip public immutable pip;

    error BadCurrencyOrdering();
    error PoolNotSupported();
    error LiquidityNotAllowed();
    error WrapperUnderfunded(uint256 needed, uint256 available);
    error RedeemUnderpaid(uint256 expected, uint256 received);
    error RedeemCooldownActive();
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
        // One-time max approval so `wrapper.mint` can pull tGBP from this hook during swaps.
        // Unbounded is safe here: the hook holds no persistent tGBP (only transient sub-unit dust
        // mid-swap) and the wrapper is the trusted counterparty, so the approval exposes nothing
        // extra; a just-in-time exact approval would only add an SSTORE to every buy.
        IERC20Minimal(_tgbp).approve(wst, type(uint256).max);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // implemented to revert: this pool has no AMM liquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // required for the custom-curve delta to be applied
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev Executes the swap at the wrapper's live `mintcost`/`burncost`. Applies NO slippage or price
    ///      bound of its own (see the contract-level note) — callers must enforce their own via the router.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (Currency.unwrap(key.currency0) != tgbp || Currency.unwrap(key.currency1) != wst) {
            revert PoolNotSupported();
        }

        // Sells need an atomic redeem; a non-zero cooldown defers the wrapper's payout (incompatible
        // with an atomic swap) and this pool has no LP to fall back to, so reject the sell outright
        // rather than burn wstGBP into a deferred, hook-owned redemption.
        if (!params.zeroForOne && act.cooldown() != 0) revert RedeemCooldownActive();

        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount = (exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified));
        specifiedAmount.toInt128(); // bound

        int128 deltaSpecified;
        int128 deltaUnspecified;

        if (params.zeroForOne) {
            // BUY wstGBP: tGBP (currency0) in -> wstGBP (currency1) out.
            if (exactInput) {
                uint256 tgbpIn = specifiedAmount;
                poolManager.take(currency0, address(this), tgbpIn);
                uint256 wOut = wrapper.mint(tgbpIn);
                _settleToManager(currency1, wOut);
                deltaSpecified = tgbpIn.toInt128();
                deltaUnspecified = -wOut.toInt128();
            } else {
                uint256 wOut = specifiedAmount;
                uint256 tgbpIn = FullMath.mulDivRoundingUp(wOut, _mintcost(), WAD);
                poolManager.take(currency0, address(this), tgbpIn);
                wrapper.mint(tgbpIn); // mints >= wOut; surplus stays as dust
                _settleToManager(currency1, wOut);
                deltaSpecified = -wOut.toInt128();
                deltaUnspecified = tgbpIn.toInt128();
            }
        } else {
            // SELL wstGBP: wstGBP (currency1) in -> tGBP (currency0) out.
            if (exactInput) {
                uint256 wIn = specifiedAmount;
                uint256 claim = FullMath.mulDiv(wIn, _burncost(), WAD);
                _requireWrapperFunded(claim);
                poolManager.take(currency1, address(this), wIn);
                uint256 received = _redeem(wIn);
                // The funded pre-check assumes an atomic (cooldown()==0) redeem; assert the wrapper
                // actually paid the full claim so a cooldown change can't silently zero the output.
                if (received < claim) revert RedeemUnderpaid(claim, received);
                _settleToManager(currency0, received);
                deltaSpecified = wIn.toInt128();
                deltaUnspecified = -received.toInt128();
            } else {
                uint256 tOut = specifiedAmount;
                uint256 bc = _burncost();
                uint256 wIn = FullMath.mulDivRoundingUp(tOut, WAD, bc);
                uint256 claim = FullMath.mulDiv(wIn, bc, WAD); // >= tOut
                _requireWrapperFunded(claim);
                poolManager.take(currency1, address(this), wIn);
                uint256 received = _redeem(wIn); // returns >= tOut; surplus stays as dust
                if (received < tOut) revert RedeemUnderpaid(tOut, received);
                _settleToManager(currency0, tOut);
                deltaSpecified = -tOut.toInt128();
                deltaUnspecified = wIn.toInt128();
            }
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, deltaUnspecified), 0);
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
