// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Iwsgem} from "../core/interfaces/Iwsgem.sol";
import {IAct, IPip} from "../core/interfaces/IFeeds.sol";
import {WsgemWrap} from "../core/WsgemWrap.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title WsgemHookHelper
/// @notice An owner-bound wrap/unwrap target for CoW Protocol hooks (and any other "untrusted executor"
///         context): it pulls gem/wsgem from a user who approved it and ALWAYS pays the proceeds back to
///         that same user, at the wrapper's own oracle prices (`mintcost` / `burncost`).
///
///         CoW hooks are `{target, callData, gasLimit}` entries in an order's appData, executed via the
///         public HooksTrampoline: `msg.sender` at this contract is the trampoline (or literally anyone —
///         hook callData is public and the trampoline is permissionless). The existing
///         {WsgemDirectAdapter} cannot be a hook target because it pulls from `msg.sender`, and the
///         trampoline holds no funds. This helper closes that gap with a deliberately tiny surface:
///
///         - `wrapAll` sweeps `min(balance, allowance)` of the owner's gem — post-hook proceeds vary with
///           order surplus, so the amount must resolve at execution time; the owner's allowance is the cap.
///         - `unwrap`/`unwrapAll` redeem the owner's wsgem back to gem ahead of a sell (pre-hook).
///
/// @dev SECURITY MODEL — anyone may call every function; safety comes from the funds being hard-wired
///      owner -> owner. The worst an arbitrary caller can do is trigger a conversion of whatever the
///      owner has approved, at the fair oracle price, delivered to the owner: bounded griefing (the
///      ~25bps mint/burn spread on a forced round-trip), never extraction. `minAmountOut` protects the
///      honest hook path against oracle movement between order signing and execution; it cannot bind a
///      direct caller (who picks their own args), which is fine because the price is oracle-fixed either
///      way. Users should grant exact-amount approvals (the hook dapp does) so `wrapAll` can never sweep
///      more than the intended order's proceeds.
///
///      Hook execution is weak-guarantee (solver social consensus): a skipped `wrapAll` post-hook leaves
///      the owner holding gem plus a spent-or-revocable approval; a skipped `unwrap` pre-hook leaves the
///      owner without the sell-token, so the order simply cannot settle. Neither loses value.
///
///      Pricing, redeem balance-diff safety, and the non-standard-ERC20 transfer come from the shared
///      {WsgemWrap} library — byte-identical to the v4 backstop hook and the direct adapter. Compliance:
///      this helper becomes the `mint`/`redeem` caller, so its address must not be on the gem ban list.
///      Sells require a zero redeem cooldown so the wrapper settles gem atomically within the call.
contract WsgemHookHelper {
    Iwsgem public immutable wrapper;
    address public immutable gem; // the wrapper's underlying ("gem")
    address public immutable wsgem; // the wrapper token itself
    /// @dev The wrapper's two immutable price feeds, cached so the helper prices off them directly —
    ///      byte-identical to `wrapper.mintcost()`/`burncost()`. See {IFeeds}.
    IAct public immutable act;
    IPip public immutable pip;

    /// @notice Emitted once per wrap; `caller` is the executor (e.g. the HooksTrampoline), never the payer.
    event Wrap(address indexed owner, address indexed caller, uint256 amountIn, uint256 amountOut);
    /// @notice Emitted once per unwrap; `caller` is the executor, never the payer.
    event Unwrap(address indexed owner, address indexed caller, uint256 amountIn, uint256 amountOut);

    error IdenticalCurrencies();
    error NothingToConvert();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error WrapperUnderfunded(uint256 needed, uint256 available);
    error RedeemUnderpaid(uint256 expected, uint256 received);
    error RedeemCooldownActive();
    error InvalidPrice();
    error TransferFailed();

    constructor(Iwsgem _wrapper) {
        wrapper = _wrapper;
        address _wsgem = address(_wrapper);
        wsgem = _wsgem;
        address _gem = _wrapper.gem();
        gem = _gem;
        // A wrapper naming itself as its own underlying would make wrap and unwrap indistinguishable;
        // reject it (mirrors the adapter's and the hook's same-currency guard).
        if (_gem == _wsgem) revert IdenticalCurrencies();
        act = IAct(_wrapper.act());
        pip = IPip(_wrapper.pip());
        // One-time max approval so `wrapper.mint` can pull gem from this helper during wraps. Safe: the
        // helper holds no persistent balance (everything is forwarded within the call) and the wrapper
        // is the trusted counterparty. `redeem` burns the helper's own wsgem, so it needs no approval.
        IERC20Minimal(_gem).approve(_wsgem, type(uint256).max);
    }

    /// @notice Wrap the owner's gem into wsgem at `mintcost`, sweeping `min(balance, allowance)` — the
    ///         allowance is the owner's cap on how much a hook may convert. All minted wsgem goes to
    ///         `owner`. Designed as a CoW POST-hook target (order buys gem, proceeds vary with surplus).
    /// @param owner The user whose gem is wrapped and who receives the wsgem.
    /// @param minAmountOut Minimum acceptable wsgem out (guards the signed hook against oracle movement).
    /// @return amountOut The wsgem minted and delivered to `owner`.
    function wrapAll(address owner, uint256 minAmountOut) external returns (uint256 amountOut) {
        uint256 amountIn = _sweepable(gem, owner);
        if (amountIn == 0) revert NothingToConvert();
        _pull(gem, owner, amountIn);
        amountOut = wrapper.mint(amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        if (!WsgemWrap.transfer(wsgem, owner, amountOut)) revert TransferFailed();
        emit Wrap(owner, msg.sender, amountIn, amountOut);
    }

    /// @notice Unwrap a fixed `amountIn` of the owner's wsgem back to gem at `burncost`. All redeemed gem
    ///         goes to `owner`. Designed as a CoW PRE-hook target (the amount is known at order signing;
    ///         the redeemed gem then funds the order's sell side from the owner's wallet).
    /// @param owner The user whose wsgem is redeemed and who receives the gem.
    /// @param amountIn Exact wsgem to redeem (must be within the owner's balance and approval).
    /// @param minAmountOut Minimum acceptable gem out (guards the signed hook against oracle movement).
    /// @return amountOut The gem delivered to `owner`.
    function unwrap(address owner, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        if (amountIn == 0) revert NothingToConvert();
        return _unwrap(owner, amountIn, minAmountOut);
    }

    /// @notice `unwrap`, but sweeping `min(balance, allowance)` of the owner's wsgem — for "sell
    ///         everything" flows where the exact balance at execution time may differ from signing time.
    function unwrapAll(address owner, uint256 minAmountOut) external returns (uint256 amountOut) {
        uint256 amountIn = _sweepable(wsgem, owner);
        if (amountIn == 0) revert NothingToConvert();
        return _unwrap(owner, amountIn, minAmountOut);
    }

    function _unwrap(address owner, uint256 amountIn, uint256 minAmountOut) internal returns (uint256 amountOut) {
        // Atomic only when cooldown is 0 — a deferred redeem would strand the payout on the wrapper.
        if (act.cooldown() != 0) revert RedeemCooldownActive();
        uint256 bc = WsgemWrap.price(act, pip, false);
        // A live-NAV 100% redemption fee makes burncost 0 (the wrapper's redeem only guards nav==0),
        // which would burn the input for 0 gem out; reject it (mirrors the adapter's sell path).
        if (bc == 0) revert InvalidPrice();
        uint256 claim = WsgemWrap.quoteIn(false, amountIn, bc);
        uint256 available = IERC20Minimal(gem).balanceOf(wsgem);
        if (available < claim) revert WrapperUnderfunded(claim, available);
        _pull(wsgem, owner, amountIn);
        amountOut = WsgemWrap.redeem(wrapper, gem, amountIn);
        // The funded pre-check assumes an atomic redeem; assert the wrapper paid the full claim so a
        // cooldown change can't silently zero the output.
        if (amountOut < claim) revert RedeemUnderpaid(claim, amountOut);
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        if (!WsgemWrap.transfer(gem, owner, amountOut)) revert TransferFailed();
        emit Unwrap(owner, msg.sender, amountIn, amountOut);
    }

    /// @dev The sweep amount for `owner`: their balance, capped by what they approved this helper for.
    function _sweepable(address token, address owner) internal view returns (uint256) {
        uint256 balance = IERC20Minimal(token).balanceOf(owner);
        uint256 allowance = IERC20Minimal(token).allowance(owner, address(this));
        return balance < allowance ? balance : allowance;
    }

    /// @dev Pull `amount` of `token` from `owner` into this helper via `transferFrom`, tolerating
    ///      non-standard (no-boolean-return) tokens.
    function _pull(address token, address owner, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, owner, address(this), amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
