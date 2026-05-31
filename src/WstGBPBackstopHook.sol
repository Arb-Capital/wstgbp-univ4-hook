// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IwstGBP} from "./interfaces/IwstGBP.sol";

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
///         (For a pool that should ALSO consume third-party in-band LP first, use `WstGBPHybridHook`
///         — with no LP it behaves identically to this hook.)
///
/// @dev `beforeSwap` returns a `BeforeSwapDelta` whose specified leg exactly cancels the swap so the
///      AMM is bypassed entirely. The hook `take`s the swap's input currency from the PoolManager,
///      feeds it into `wstGBP.mint`/`redeem`, and `settle`s the output — wrapping the swap's own
///      tokens with no inventory. Settle-first routing required (see `WstGBPSwapRouter`).
///
///      Pool convention (enforced in the constructor): currency0 = tGBP, currency1 = wstGBP, so
///      `zeroForOne == true` is a BUY of wstGBP and `false` is a SELL. Ownerless, holds no capital.
contract WstGBPBackstopHook is BaseHook {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;

    Currency public immutable currency0; // tGBP (lower address)
    Currency public immutable currency1; // wstGBP
    IwstGBP public immutable wrapper;
    address public immutable tgbp;
    address public immutable wst;

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
        if (_tgbp >= wst) revert BadCurrencyOrdering();
        currency0 = Currency.wrap(_tgbp);
        currency1 = Currency.wrap(wst);
        // One-time max approval so `wrapper.mint` can pull tGBP from this hook during swaps.
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
        if (!params.zeroForOne && wrapper.cooldown() != 0) revert RedeemCooldownActive();

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
                uint256 tgbpIn = FullMath.mulDivRoundingUp(wOut, wrapper.mintcost(), WAD);
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
                uint256 claim = FullMath.mulDiv(wIn, wrapper.burncost(), WAD);
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
                uint256 wIn = FullMath.mulDivRoundingUp(tOut, WAD, wrapper.burncost());
                uint256 claim = FullMath.mulDiv(wIn, wrapper.burncost(), WAD); // >= tOut
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
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
