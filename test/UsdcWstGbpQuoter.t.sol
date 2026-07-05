// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {UsdcWstGbpForkBase} from "./base/UsdcWstGbpForkBase.sol";
import {IAggregatorV3} from "../src/usdc/interfaces/IAggregatorV3.sol";

/// @notice Parity suite: the STOCK v4 Quoter (design principle #2 — the whole point of fee-only)
///         against real execution, exact to the wei, in every fee regime including fallback and
///         paused. The Quoter simulates the actual hook inside its own reverted call context, so its
///         transient state is discarded and the following execution recomputes the identical fee from
///         the same persistent state.
/// @dev Quotes and executions share the test transaction; the Quoter's internal revert rolls back its
///      tstore writes, so each quote sees the same pre-swap world as its execution. Fee regimes are
///      driven from the GBP/USD leg — remember the sign trap: GBP UP ⇒ fair DOWN ⇒ d > 0.
contract UsdcWstGbpQuoterTest is UsdcWstGbpForkBase {
    IV4Quoter constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);

    bool constant MINT_ZF1 = true;
    bool constant REDEEM_ZF1 = false;

    // ---------------------------------------------------------------- parity helpers

    function _assertExactInParity(bool zeroForOne, uint128 amountIn) internal {
        (uint256 quotedOut,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: ""
            })
        );
        SwapObservation memory o = _swapAndObserve(zeroForOne, -int256(uint256(amountIn)));
        uint256 executedOut = uint256(uint128(zeroForOne ? o.amount1 : o.amount0));
        assertEq(executedOut, quotedOut, "exact-in: quoted == executed");
    }

    function _assertExactOutParity(bool zeroForOne, uint128 amountOut) internal {
        (uint256 quotedIn,) = QUOTER.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountOut, hookData: ""
            })
        );
        SwapObservation memory o = _swapAndObserve(zeroForOne, int256(uint256(amountOut)));
        uint256 executedIn = uint256(uint128(-(zeroForOne ? o.amount0 : o.amount1)));
        assertEq(executedIn, quotedIn, "exact-out: quoted == executed");
        // Exact-out delivered in full.
        assertEq(uint256(uint128(zeroForOne ? o.amount1 : o.amount0)), uint256(amountOut), "full delivery");
    }

    /// @dev All four modes in the current regime. Sizes small enough not to leave the regime being
    ///      tested (each quote is taken fresh against the then-current pool state).
    function _assertAllModes() internal {
        _assertExactInParity(MINT_ZF1, uint128(10 * WAD)); // 10 wstGBP in
        _assertExactInParity(REDEEM_ZF1, uint128(25 * USDC_UNIT)); // 25 USDC in
        _assertExactOutParity(MINT_ZF1, uint128(10 * USDC_UNIT)); // 10 USDC out
        _assertExactOutParity(REDEEM_ZF1, uint128(5 * WAD)); // 5 wstGBP out
    }

    // ---------------------------------------------------------------- regimes

    function test_parityAtZeroDeviation() public {
        _assertAllModes();
    }

    function test_parityClosingAboveThreshold() public {
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 99) / 100, block.timestamp); // fair +1% => d ~ -1%
        _assertAllModes();
    }

    function test_parityOppositeDeviation() public {
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp); // fair -1% => d ~ +1%
        _assertAllModes();
    }

    function test_parityCapSaturated() public {
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 90) / 100, block.timestamp); // |d| >> cap
        _assertAllModes();
    }

    function test_parityFallbackMode() public {
        _brickFeed(GBP_USD_FEED);
        _assertAllModes();
    }

    function test_parityNavZero() public {
        _setNav(0);
        _assertAllModes();
    }

    function test_parityPaused() public {
        vm.prank(owner);
        hook.setPaused(true);
        _assertAllModes();
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Any oracle regime × direction × mode × size: parity is exact.
    function testFuzz_parityAcrossRegimes(
        uint256 fairShiftPpm,
        bool shiftUp,
        bool zeroForOne,
        bool exactIn,
        uint256 size
    ) public {
        // Drive GBP/USD up to ±5% around the fixture default (spans base-only, ramp and cap regimes;
        // fair moves inversely).
        fairShiftPpm = bound(fairShiftPpm, 0, 50_000);
        int256 answer = int256(
            uint256(GBP_USD_ANSWER) * (shiftUp ? 1_000_000 + fairShiftPpm : 1_000_000 - fairShiftPpm) / 1_000_000
        );
        _mockFeed(GBP_USD_FEED, answer, block.timestamp);

        if (exactIn) {
            // Input sizes: wstGBP for the mint side, USDC for the redeem side.
            uint128 amountIn = zeroForOne
                ? uint128(bound(size, WAD, 500 * WAD))  // 1..500 wstGBP
                : uint128(bound(size, USDC_UNIT, 650 * USDC_UNIT)); // 1..650 USDC
            _assertExactInParity(zeroForOne, amountIn);
        } else {
            uint128 amountOut = zeroForOne
                ? uint128(bound(size, USDC_UNIT, 650 * USDC_UNIT))  // USDC out
                : uint128(bound(size, WAD, 500 * WAD)); // wstGBP out
            _assertExactOutParity(zeroForOne, amountOut);
        }
    }
}
