// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @title WstGBPSwapRouter
/// @notice A "settle-first" router for the tGBP/wstGBP backstop pool.
/// @dev The backstop hook wraps/unwraps the swap's input token during `beforeSwap`, which runs before
///      a v4 swap surfaces the taker's input. So this router **settles the input into the PoolManager
///      before calling `swap`**, letting the hook take those exact incoming tokens and feed them into
///      `wstGBP.mint`/`redeem` — no hook buffer required. Any solver/aggregator that settles-first
///      works the same way.
///
///      Slippage/safety: `swapExactInput` enforces `minAmountOut`; `swapExactOutput` enforces
///      `maxAmountIn` and full delivery of the requested output, refunding the unused input. Both take
///      a `deadline` and a `recipient` (`address(0)` ⇒ `msg.sender`). The payer (`msg.sender`) must
///      approve this router for the input token, OR use the `*Permit2` entrypoints and sign a Permit2
///      `PermitTransferFrom` (the payer approves the canonical Permit2, not this router).
contract WstGBPSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Canonical Permit2, deployed at the same address on every chain.
    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    IPoolManager public immutable poolManager;

    /// @notice Emitted once per swap with the user-facing amounts (beyond the PoolManager's own `Swap`).
    event Swap(
        address indexed payer,
        address indexed recipient,
        PoolId indexed poolId,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    error NotPoolManager();
    error Expired();
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error Permit2TokenMismatch();
    error TransferFailed();

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // < 0 exact-input, > 0 exact-output
        uint256 maxAmountIn;
        uint256 minAmountOut;
        bool usePermit2;
        ISignatureTransfer.PermitTransferFrom permit;
        bytes signature;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // -----------------------------------------------------------------------
    // Approval-based entrypoints (payer approves this router for the input token)
    // -----------------------------------------------------------------------

    /// @notice Swap an exact input amount, reverting if the output is below `minAmountOut`.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountIn Exact input (tGBP for a buy, wstGBP for a sell).
    /// @param minAmountOut Minimum acceptable output.
    /// @param recipient Receives the output (`address(0)` ⇒ `msg.sender`).
    /// @param deadline Latest block timestamp at which the swap may execute.
    /// @return amountOut The output delivered to `recipient`.
    function swapExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountOut) {
        (, amountOut) = _execute(key, zeroForOne, -int256(amountIn), amountIn, minAmountOut, recipient);
    }

    /// @notice Swap for an exact output amount, reverting if the input exceeds `maxAmountIn`.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountOut Exact output (wstGBP for a buy, tGBP for a sell).
    /// @param maxAmountIn Maximum input the payer will provide; surplus is refunded.
    /// @param recipient Receives the output (`address(0)` ⇒ `msg.sender`).
    /// @param deadline Latest block timestamp at which the swap may execute.
    /// @return amountIn The input actually spent (pulled from `msg.sender`).
    function swapExactOutput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountIn) {
        // Enforce full delivery by setting the slippage floor to the exact output (min == amountOut):
        // the swap reverts rather than ever delivering the recipient less than they asked for.
        (amountIn,) = _execute(key, zeroForOne, int256(amountOut), maxAmountIn, amountOut, recipient);
    }

    // -----------------------------------------------------------------------
    // Permit2 entrypoints (payer signs a PermitTransferFrom; no router approval)
    // -----------------------------------------------------------------------

    /// @notice Exact-input swap funded via a Permit2 SignatureTransfer. `permit.permitted.token` must be
    ///         the input currency and `.amount >= amountIn`; the swap deadline is `permit.deadline`.
    function swapExactInputPermit2(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external ensure(permit.deadline) returns (uint256 amountOut) {
        (, amountOut) = _executePermit2(
            key, zeroForOne, -int256(amountIn), amountIn, minAmountOut, recipient, permit, signature
        );
    }

    /// @notice Exact-output swap funded via a Permit2 SignatureTransfer. `permit.permitted.token` must be
    ///         the input currency and `.amount >= maxAmountIn`; surplus input is refunded to the payer.
    function swapExactOutputPermit2(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external ensure(permit.deadline) returns (uint256 amountIn) {
        (amountIn,) = _executePermit2(
            key, zeroForOne, int256(amountOut), maxAmountIn, amountOut, recipient, permit, signature
        );
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _execute(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        address recipient
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        ISignatureTransfer.PermitTransferFrom memory noPermit;
        return _run(
            CallbackData(
                msg.sender,
                recipient == address(0) ? msg.sender : recipient,
                key,
                zeroForOne,
                amountSpecified,
                maxAmountIn,
                minAmountOut,
                false,
                noPermit,
                ""
            )
        );
    }

    function _executePermit2(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        address recipient,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        return _run(
            CallbackData(
                msg.sender,
                recipient == address(0) ? msg.sender : recipient,
                key,
                zeroForOne,
                amountSpecified,
                maxAmountIn,
                minAmountOut,
                true,
                permit,
                signature
            )
        );
    }

    function _run(CallbackData memory d) internal returns (uint256 amountIn, uint256 amountOut) {
        bytes memory res = poolManager.unlock(abi.encode(d));
        (amountIn, amountOut) = abi.decode(res, (uint256, uint256));
        emit Swap(d.payer, d.recipient, d.key.toId(), d.zeroForOne, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        Currency inputC = d.zeroForOne ? d.key.currency0 : d.key.currency1;
        Currency outputC = d.zeroForOne ? d.key.currency1 : d.key.currency0;
        bool exactInput = d.amountSpecified < 0;

        // 1) Settle the input into the PoolManager BEFORE swapping. Exact-input pays the exact
        //    amount; exact-output pays the max and the surplus is refunded below.
        uint256 preIn = exactInput ? uint256(-d.amountSpecified) : d.maxAmountIn;
        if (preIn > 0) _settleFromUser(d, inputC, preIn);

        // 2) Swap. The hook takes the now-present input, wraps/unwraps it, and settles the output.
        uint160 limit = d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        poolManager.swap(d.key, SwapParams(d.zeroForOne, d.amountSpecified, limit), "");

        // 3) Input side: never spend more than maxAmountIn; refund the unused remainder to the payer.
        int256 inD = poolManager.currencyDelta(address(this), inputC);
        if (inD < 0) revert ExcessiveInput(preIn + uint256(-inD), d.maxAmountIn);
        uint256 refund = uint256(inD);
        uint256 amountIn = preIn - refund;
        if (refund > 0) poolManager.take(inputC, d.payer, refund);

        // 4) Output side: enforce the slippage floor, then deliver to the recipient.
        int256 outD = poolManager.currencyDelta(address(this), outputC);
        uint256 amountOut = outD > 0 ? uint256(outD) : 0;
        if (amountOut < d.minAmountOut) revert InsufficientOutput(amountOut, d.minAmountOut);
        if (amountOut > 0) poolManager.take(outputC, d.recipient, amountOut);

        return abi.encode(amountIn, amountOut);
    }

    function _settleFromUser(CallbackData memory d, Currency c, uint256 amount) internal {
        poolManager.sync(c);
        if (d.usePermit2) {
            // Permit2 moves `d.permit.permitted.token`; it must be the input currency or the settle
            // below would credit nothing and the swap would revert.
            if (d.permit.permitted.token != Currency.unwrap(c)) revert Permit2TokenMismatch();
            PERMIT2.permitTransferFrom(
                d.permit,
                ISignatureTransfer.SignatureTransferDetails({to: address(poolManager), requestedAmount: amount}),
                d.payer,
                d.signature
            );
        } else {
            (bool ok, bytes memory data) = Currency.unwrap(c)
                .call(
                    abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, d.payer, address(poolManager), amount)
                );
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
        poolManager.settle();
    }
}
