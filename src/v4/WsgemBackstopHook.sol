// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Iwsgem} from "../core/interfaces/Iwsgem.sol";
import {IAct, IPip} from "../core/interfaces/IFeeds.sol";
import {WsgemWrap} from "../core/WsgemWrap.sol";

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

/// @title WsgemBackstopHook (pure backstop — no AMM/LP)
/// @notice A Uniswap v4 hook that gives a gem/wsgem pool effectively unlimited depth by routing
///         every swap through the wsgem wrapper's atomic mint/redeem at the protocol's own prices:
///         buys execute at `wsgem.mintcost()`, sells at `wsgem.burncost()`. LP adds are blocked.
///
/// @dev `beforeSwap` returns a `BeforeSwapDelta` whose specified leg exactly cancels the swap so the
///      AMM is bypassed entirely. The hook `take`s the swap's input currency from the PoolManager,
///      feeds it into `wsgem.mint`/`redeem`, and `settle`s the output — wrapping the swap's own
///      tokens with no inventory. Settle-first routing required (see `WsgemSwapRouter`).
///
///      The pool's two currencies are gem and wsgem in v4's canonical sorted order; the constructor
///      adapts to whichever address sorts lower. A swap is a BUY of wsgem (mint) when its input currency
///      is gem and a SELL (redeem) when its input is wsgem — i.e. `isBuy == (zeroForOne == gemIsZero)`.
///      Ownerless, holds no capital.
///
/// @dev SLIPPAGE IS THE CALLER'S RESPONSIBILITY. `beforeSwap` executes at the wrapper's live oracle price
///      (`mintcost`/`burncost`) with NO intrinsic slippage check, price floor, or sanity bound — it is a
///      pure price-taker. wsgem governance can move that price/spread between blocks (fees settable up to
///      100%), so an unbounded swap (e.g. `minAmountOut == 0`, or a custom settle-first integration with no
///      bounds) executes at whatever the oracle says, however unfavorable. Always swap through
///      `WsgemSwapRouter` (or a solver) that enforces `minAmountOut`/`maxAmountIn`. See the README trust
///      model.
contract WsgemBackstopHook is BaseHook {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;

    Currency public immutable currency0; // min(gem, wsgem) — v4 canonical pool ordering
    Currency public immutable currency1; // max(gem, wsgem)
    Currency public immutable gemCurrency; // the underlying ("gem"), whichever slot it sorts into
    Currency public immutable wsgemCurrency; // the wrapper token ("wsgem")
    Iwsgem public immutable wrapper;
    address public immutable gem;
    address public immutable wsgem;
    /// @dev True when `gem` is currency0 (gem < wsgem). A swap is a BUY iff `zeroForOne == gemIsZero`.
    bool public immutable gemIsZero;
    /// @dev The wrapper's two immutable price feeds, cached so the hook can read the backstop price
    ///      directly (act.mintcost(pip.read())) and skip the wrapper's dispatch hop. Byte-identical to
    ///      `wrapper.mintcost()`/`burncost()`/`cooldown()` because `mint`/`redeem` use the same feeds.
    IAct public immutable act;
    IPip public immutable pip;

    error IdenticalCurrencies();
    error PoolNotSupported();
    error LiquidityNotAllowed();
    error WrapperUnderfunded(uint256 needed, uint256 available);
    error RedeemUnderpaid(uint256 expected, uint256 received);
    error RedeemCooldownActive();
    error TransferFailed();

    constructor(IPoolManager _poolManager, Iwsgem _wrapper) BaseHook(_poolManager) {
        wrapper = _wrapper;
        address _wsgem = address(_wrapper);
        wsgem = _wsgem;
        address _gem = _wrapper.gem();
        gem = _gem;
        act = IAct(_wrapper.act());
        pip = IPip(_wrapper.pip());
        if (_gem == _wsgem) revert IdenticalCurrencies();

        Currency _gemCurrency = Currency.wrap(_gem);
        Currency _wsgemCurrency = Currency.wrap(_wsgem);
        gemCurrency = _gemCurrency;
        wsgemCurrency = _wsgemCurrency;
        // v4 sorts pool currencies ascending; adapt to whichever token sorts lower rather than assuming
        // gem < wsgem (true for tGBP/wstGBP, but not for an arbitrary pair).
        bool _gemIsZero = _gem < _wsgem;
        gemIsZero = _gemIsZero;
        (currency0, currency1) = _gemIsZero ? (_gemCurrency, _wsgemCurrency) : (_wsgemCurrency, _gemCurrency);

        // One-time max approval so `wrapper.mint` can pull gem from this hook during swaps.
        // Unbounded is safe here: the hook holds no persistent gem (only transient sub-unit dust
        // mid-swap) and the wrapper is the trusted counterparty, so the approval exposes nothing
        // extra; a just-in-time exact approval would only add an SSTORE to every buy.
        IERC20Minimal(_gem).approve(_wsgem, type(uint256).max);
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
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1)
        ) {
            revert PoolNotSupported();
        }

        // A swap is a BUY of wsgem (mint) when its input currency is gem, and a SELL (redeem) otherwise.
        // gem is currency0 exactly when `gemIsZero`, so paying currency0 (`zeroForOne`) is a buy iff
        // `gemIsZero`; the equality below is that XNOR and works for both address orderings.
        bool isBuy = params.zeroForOne == gemIsZero;

        // Sells need an atomic redeem; a non-zero cooldown defers the wrapper's payout (incompatible
        // with an atomic swap) and this pool has no LP to fall back to, so reject the sell outright
        // rather than burn wsgem into a deferred, hook-owned redemption.
        if (!isBuy && act.cooldown() != 0) revert RedeemCooldownActive();

        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount = (exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified));
        specifiedAmount.toInt128(); // bound

        int128 deltaSpecified;
        int128 deltaUnspecified;

        if (isBuy) {
            // BUY wsgem: gem in -> wsgem out (mint). `gemCurrency`/`wsgemCurrency` are role-based, so
            // the take/settle are correct regardless of which token sorts into currency0/currency1.
            if (exactInput) {
                uint256 gemIn = specifiedAmount;
                poolManager.take(gemCurrency, address(this), gemIn);
                uint256 wOut = wrapper.mint(gemIn);
                _settleToManager(wsgemCurrency, wOut);
                deltaSpecified = gemIn.toInt128();
                deltaUnspecified = -wOut.toInt128();
            } else {
                uint256 wOut = specifiedAmount;
                uint256 gemIn = FullMath.mulDivRoundingUp(wOut, _mintcost(), WAD);
                poolManager.take(gemCurrency, address(this), gemIn);
                wrapper.mint(gemIn); // mints >= wOut; surplus stays as dust
                _settleToManager(wsgemCurrency, wOut);
                deltaSpecified = -wOut.toInt128();
                deltaUnspecified = gemIn.toInt128();
            }
        } else {
            // SELL wsgem: wsgem in -> gem out (redeem).
            if (exactInput) {
                uint256 wIn = specifiedAmount;
                uint256 claim = FullMath.mulDiv(wIn, _burncost(), WAD);
                _requireWrapperFunded(claim);
                poolManager.take(wsgemCurrency, address(this), wIn);
                uint256 received = _redeem(wIn);
                // The funded pre-check assumes an atomic (cooldown()==0) redeem; assert the wrapper
                // actually paid the full claim so a cooldown change can't silently zero the output.
                if (received < claim) revert RedeemUnderpaid(claim, received);
                _settleToManager(gemCurrency, received);
                deltaSpecified = wIn.toInt128();
                deltaUnspecified = -received.toInt128();
            } else {
                uint256 tOut = specifiedAmount;
                uint256 bc = _burncost();
                uint256 wIn = FullMath.mulDivRoundingUp(tOut, WAD, bc);
                uint256 claim = FullMath.mulDiv(wIn, bc, WAD); // >= tOut
                _requireWrapperFunded(claim);
                poolManager.take(wsgemCurrency, address(this), wIn);
                uint256 received = _redeem(wIn); // returns >= tOut; surplus stays as dust
                if (received < tOut) revert RedeemUnderpaid(tOut, received);
                _settleToManager(gemCurrency, tOut);
                deltaSpecified = -tOut.toInt128();
                deltaUnspecified = wIn.toInt128();
            }
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, deltaUnspecified), 0);
    }

    /// @dev The backstop ask, read directly off the wrapper's immutable feeds (== `wrapper.mintcost()`).
    function _mintcost() internal view returns (uint256) {
        return WsgemWrap.price(act, pip, true);
    }

    /// @dev The backstop bid, read directly off the wrapper's immutable feeds (== `wrapper.burncost()`).
    function _burncost() internal view returns (uint256) {
        return WsgemWrap.price(act, pip, false);
    }

    function _redeem(uint256 wIn) internal returns (uint256 received) {
        received = WsgemWrap.redeem(wrapper, gem, wIn);
    }

    function _requireWrapperFunded(uint256 needed) internal view {
        uint256 available = IERC20Minimal(gem).balanceOf(wsgem);
        if (available < needed) revert WrapperUnderfunded(needed, available);
    }

    function _settleToManager(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        _safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
        poolManager.settle();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (!WsgemWrap.transfer(token, to, amount)) revert TransferFailed();
    }
}
