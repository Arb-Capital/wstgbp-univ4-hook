// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title WstGBPSwapRouter
/// @notice A "settle-first" router for the tGBP/wstGBP backstop pool.
/// @dev The backstop hook wraps/unwraps the swap's input token during `beforeSwap`, which runs before
///      a v4 swap surfaces the taker's input. So this router **settles the input into the PoolManager
///      before calling `swap`**, letting the hook take those exact incoming tokens and feed them into
///      `wstGBP.mint`/`redeem` — no hook buffer required. Any solver/aggregator that settles-first
///      works the same way.
///
///      Slippage/safety: `swapExactInput` enforces `minAmountOut`; `swapExactOutput` enforces
///      `maxAmountIn` and refunds the unused input to the payer. Both take a `deadline` and a
///      `recipient` (`address(0)` ⇒ `msg.sender`). The payer (`msg.sender`) must approve this router
///      for the input token (Permit2 not used, for clarity).
contract WstGBPSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error Expired();
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error TransferFailed();

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // < 0 exact-input, > 0 exact-output
        uint256 maxAmountIn;
        uint256 minAmountOut;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

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
        // Enforce full delivery of the requested output (min == amountOut): the backstop always fills
        // exactly, but if a swap is served by pool liquidity only (e.g. the hook steps aside) a shallow
        // AMM could otherwise under-deliver and silently short-change the recipient.
        (amountIn,) = _execute(key, zeroForOne, int256(amountOut), maxAmountIn, amountOut, recipient);
    }

    function _execute(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 maxAmountIn,
        uint256 minAmountOut,
        address recipient
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        address to = recipient == address(0) ? msg.sender : recipient;
        bytes memory res = poolManager.unlock(
            abi.encode(CallbackData(msg.sender, to, key, zeroForOne, amountSpecified, maxAmountIn, minAmountOut))
        );
        (amountIn, amountOut) = abi.decode(res, (uint256, uint256));
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
        if (preIn > 0) _settleFromUser(inputC, d.payer, preIn);

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

    function _settleFromUser(Currency c, address payer, uint256 amount) internal {
        poolManager.sync(c);
        (bool ok, bytes memory data) = Currency.unwrap(c)
            .call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, payer, address(poolManager), amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        poolManager.settle();
    }
}
