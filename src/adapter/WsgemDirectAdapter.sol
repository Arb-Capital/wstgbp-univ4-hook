// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Iwsgem} from "../core/interfaces/Iwsgem.sol";
import {IAct, IPip} from "../core/interfaces/IFeeds.sol";
import {WsgemWrap} from "../core/WsgemWrap.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title WsgemDirectAdapter
/// @notice A standalone, ownerless, inventory-free venue that routes a gem<->wsgem swap straight through
///         the wsgem wrapper's atomic mint/redeem at the protocol's own oracle prices — buys execute at
///         `mintcost`, sells at `burncost`, the same ~25bps spread as the v4 backstop hook. Unlike the
///         hook it does NOT touch a Uniswap pool: it uses ordinary "approve → swap → receive"
///         (swap-then-settle) semantics, so any DEX aggregator (Odos, LI.FI, Paraswap) or CoW Protocol
///         solver can call it like a normal swap contract.
///
/// @dev The price math, redeem balance-diff safety, and non-standard-ERC20 transfer all come from the
///      shared {WsgemWrap} library — byte-identical to `WsgemBackstopHook`, so the two venues can never
///      price differently (enforced by parity tests). The adapter computes the exact input up front (it
///      reads the oracle directly) and pulls exactly that, so exact-output needs no refund step.
///
///      SLIPPAGE IS THE CALLER'S RESPONSIBILITY. Each swap executes at the wrapper's live
///      `mintcost`/`burncost`, which wsgem governance can move between blocks. `swapExactInput` enforces
///      `minAmountOut`; `swapExactOutput` enforces `maxAmountIn` and full delivery. Always pass real
///      bounds. Quotes are point-in-time (the oracle ratchets up).
///
///      Compliance: the adapter becomes the `mint`/`redeem` caller, so its address must not be on the
///      gem ban list (the blacklist is permissive by default — no allowlisting needed). Sells require a
///      zero redeem cooldown (this deployment) so the wrapper settles gem atomically within the call.
contract WsgemDirectAdapter {
    /// @dev Canonical Permit2, deployed at the same address on every chain.
    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    Iwsgem public immutable wrapper;
    address public immutable gem; // the wrapper's underlying ("gem")
    address public immutable wsgem; // the wrapper token itself
    /// @dev The wrapper's two immutable price feeds, cached so the adapter prices off them directly
    ///      (`act.mintcost(pip.read())` / `burncost`) — byte-identical to `wrapper.mintcost()`/`burncost()`,
    ///      matching `WsgemBackstopHook`/`WsgemQuoter`. See {IFeeds}.
    IAct public immutable act;
    IPip public immutable pip;

    /// @notice Emitted once per swap. `buy` is true when the input is gem (mint), false when wsgem (redeem).
    event Swap(address indexed payer, address indexed recipient, bool buy, uint256 amountIn, uint256 amountOut);

    error IdenticalCurrencies();
    error UnsupportedToken(address token);
    error Expired();
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error WrapperUnderfunded(uint256 needed, uint256 available);
    error RedeemUnderpaid(uint256 expected, uint256 received);
    error RedeemCooldownActive();
    error InvalidPrice();
    error Permit2TokenMismatch();
    error TransferFailed();

    struct SwapData {
        address payer;
        address recipient;
        bool buy; // tokenIn == gem
        bool exactInput;
        uint256 specified; // exact-in: amountIn; exact-out: amountOut
        uint256 limit; // exact-in: minAmountOut; exact-out: maxAmountIn
        bool usePermit2;
        ISignatureTransfer.PermitTransferFrom permit;
        bytes signature;
    }

    constructor(Iwsgem _wrapper) {
        wrapper = _wrapper;
        address _wsgem = address(_wrapper);
        wsgem = _wsgem;
        address _gem = _wrapper.gem();
        gem = _gem;
        // `_isBuy` resolves direction from `tokenIn` by matching `gem` first; if the wrapper named itself
        // as its own underlying the two tokens would be indistinguishable and sells unreachable. Reject it
        // (mirrors the hook's same-currency guard).
        if (_gem == _wsgem) revert IdenticalCurrencies();
        act = IAct(_wrapper.act());
        pip = IPip(_wrapper.pip());
        // One-time max approval so `wrapper.mint` can pull gem from this adapter during buys. Safe:
        // the adapter holds no persistent gem (only transient exact-output dust) and the wrapper is the
        // trusted counterparty. `redeem` burns the adapter's own wsgem, so it needs no approval.
        IERC20Minimal(_gem).approve(wsgem, type(uint256).max);
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // -----------------------------------------------------------------------
    // Approval-based entrypoints (payer approves this adapter for the input token)
    // -----------------------------------------------------------------------

    /// @notice Swap an exact input amount, reverting if the output is below `minAmountOut`.
    /// @param tokenIn The input token: `gem` to buy wsgem (mint), `wsgem` to sell wsgem (redeem).
    /// @param amountIn Exact input amount.
    /// @param minAmountOut Minimum acceptable output.
    /// @param recipient Receives the output (`address(0)` ⇒ `msg.sender`).
    /// @param deadline Latest block timestamp at which the swap may execute.
    /// @return amountOut The output delivered to `recipient`.
    function swapExactInput(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountOut) {
        ISignatureTransfer.PermitTransferFrom memory noPermit;
        (, amountOut) = _swap(
            SwapData(msg.sender, _to(recipient), _isBuy(tokenIn), true, amountIn, minAmountOut, false, noPermit, "")
        );
    }

    /// @notice Swap for an exact output amount, reverting if the input exceeds `maxAmountIn`.
    /// @param tokenIn The input token: `gem` to buy wsgem (mint), `wsgem` to sell wsgem (redeem).
    /// @param amountOut Exact output amount delivered to `recipient`.
    /// @param maxAmountIn Maximum input the payer will provide (the exact input is computed and pulled).
    /// @param recipient Receives the output (`address(0)` ⇒ `msg.sender`).
    /// @param deadline Latest block timestamp at which the swap may execute.
    /// @return amountIn The input actually spent (pulled from `msg.sender`).
    function swapExactOutput(
        address tokenIn,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountIn) {
        ISignatureTransfer.PermitTransferFrom memory noPermit;
        (amountIn,) = _swap(
            SwapData(msg.sender, _to(recipient), _isBuy(tokenIn), false, amountOut, maxAmountIn, false, noPermit, "")
        );
    }

    // -----------------------------------------------------------------------
    // Permit2 entrypoints (payer signs a PermitTransferFrom; no adapter approval)
    // -----------------------------------------------------------------------

    /// @notice Exact-input swap funded via a Permit2 SignatureTransfer. `permit.permitted.token` must be
    ///         `tokenIn` and `.amount >= amountIn`; the swap deadline is `permit.deadline`.
    function swapExactInputPermit2(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external ensure(permit.deadline) returns (uint256 amountOut) {
        (, amountOut) = _swap(
            SwapData(msg.sender, _to(recipient), _isBuy(tokenIn), true, amountIn, minAmountOut, true, permit, signature)
        );
    }

    /// @notice Exact-output swap funded via a Permit2 SignatureTransfer. `permit.permitted.token` must be
    ///         `tokenIn` and `.amount >= maxAmountIn` (only the computed exact input is pulled).
    function swapExactOutputPermit2(
        address tokenIn,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external ensure(permit.deadline) returns (uint256 amountIn) {
        (amountIn,) = _swap(
            SwapData(
                msg.sender, _to(recipient), _isBuy(tokenIn), false, amountOut, maxAmountIn, true, permit, signature
            )
        );
    }

    // -----------------------------------------------------------------------
    // Quotes (exact, gas-free — mirror execution via the shared library)
    // -----------------------------------------------------------------------

    /// @notice Output for an exact-input swap at the current backstop price.
    function quoteExactInput(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        bool buy = _isBuy(tokenIn);
        amountOut = WsgemWrap.quoteIn(buy, amountIn, WsgemWrap.price(act, pip, buy));
    }

    /// @notice Input required for an exact-output swap at the current backstop price (rounded up).
    function quoteExactOutput(address tokenIn, uint256 amountOut) external view returns (uint256 amountIn) {
        bool buy = _isBuy(tokenIn);
        amountIn = WsgemWrap.quoteOut(buy, amountOut, WsgemWrap.price(act, pip, buy));
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _swap(SwapData memory d) internal returns (uint256 amountIn, uint256 amountOut) {
        if (d.buy) {
            // BUY wsgem: pay gem, mint at `mintcost`.
            if (d.exactInput) {
                amountIn = d.specified;
                _pull(d, gem, amountIn);
                amountOut = wrapper.mint(amountIn);
                if (amountOut < d.limit) revert InsufficientOutput(amountOut, d.limit);
            } else {
                amountOut = d.specified;
                amountIn = WsgemWrap.quoteOut(true, amountOut, _mintcost());
                if (amountIn > d.limit) revert ExcessiveInput(amountIn, d.limit);
                _pull(d, gem, amountIn);
                // Mints >= amountOut by construction (input rounded up); assert and keep the surplus as
                // harmless price-bounded dust. Deliver exactly the requested output.
                uint256 minted = wrapper.mint(amountIn);
                if (minted < amountOut) revert InsufficientOutput(minted, amountOut);
            }
            if (!WsgemWrap.transfer(wsgem, d.recipient, amountOut)) revert TransferFailed();
        } else {
            // SELL wsgem: redeem to gem at `burncost`. Atomic only when cooldown is 0.
            if (act.cooldown() != 0) revert RedeemCooldownActive();
            uint256 bc = _burncost();
            // A live-NAV 100% redemption fee makes burncost 0 (the wrapper's redeem only guards nav==0,
            // not burncost==0), which would burn the input for 0 gem out; reject it so the sell path
            // matches the buy path, where mintcost==0 iff nav==0 and the wrapper's mint already reverts.
            if (bc == 0) revert InvalidPrice();
            if (d.exactInput) {
                amountIn = d.specified;
                uint256 claim = WsgemWrap.quoteIn(false, amountIn, bc);
                _requireWrapperFunded(claim);
                _pull(d, wsgem, amountIn);
                amountOut = WsgemWrap.redeem(wrapper, gem, amountIn);
                // The funded pre-check assumes an atomic redeem; assert the wrapper paid the full claim so
                // a cooldown change can't silently zero the output.
                if (amountOut < claim) revert RedeemUnderpaid(claim, amountOut);
                if (amountOut < d.limit) revert InsufficientOutput(amountOut, d.limit);
            } else {
                amountOut = d.specified;
                amountIn = WsgemWrap.quoteOut(false, amountOut, bc);
                if (amountIn > d.limit) revert ExcessiveInput(amountIn, d.limit);
                uint256 claim = WsgemWrap.quoteIn(false, amountIn, bc); // >= amountOut
                _requireWrapperFunded(claim);
                _pull(d, wsgem, amountIn);
                uint256 received = WsgemWrap.redeem(wrapper, gem, amountIn); // >= amountOut; surplus is dust
                if (received < amountOut) revert RedeemUnderpaid(amountOut, received);
            }
            if (!WsgemWrap.transfer(gem, d.recipient, amountOut)) revert TransferFailed();
        }
        emit Swap(d.payer, d.recipient, d.buy, amountIn, amountOut);
    }

    /// @dev Pull `amount` of `token` from the payer into this adapter, via Permit2 or a plain
    ///      `transferFrom`. A zero amount is a no-op (the wrapper's own dust check will revert the swap).
    function _pull(SwapData memory d, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (d.usePermit2) {
            if (d.permit.permitted.token != token) revert Permit2TokenMismatch();
            PERMIT2.permitTransferFrom(
                d.permit,
                ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
                d.payer,
                d.signature
            );
        } else {
            (bool ok, bytes memory data) =
                token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, d.payer, address(this), amount));
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
    }

    /// @dev BUY when `tokenIn` is gem, SELL when it is wsgem; anything else is unroutable.
    function _isBuy(address tokenIn) internal view returns (bool) {
        if (tokenIn == gem) return true;
        if (tokenIn == wsgem) return false;
        revert UnsupportedToken(tokenIn);
    }

    function _to(address recipient) internal view returns (address) {
        return recipient == address(0) ? msg.sender : recipient;
    }

    function _mintcost() internal view returns (uint256) {
        return WsgemWrap.price(act, pip, true);
    }

    function _burncost() internal view returns (uint256) {
        return WsgemWrap.price(act, pip, false);
    }

    function _requireWrapperFunded(uint256 needed) internal view {
        uint256 available = IERC20Minimal(gem).balanceOf(wsgem);
        if (available < needed) revert WrapperUnderfunded(needed, available);
    }
}
