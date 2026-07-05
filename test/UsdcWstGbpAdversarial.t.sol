// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {UsdcWstGbpForkBase} from "./base/UsdcWstGbpForkBase.sol";

/// @notice Adversarial suite for the USDC venue. Each scenario has a matching economic-argument
///         section in `SECURITY_USDC_WSTGBP.md`; the tests are the executable half of those notes.
/// @dev Sign conventions: with wstGBP = currency0, `d > 0` (pool prices USDC rich / wstGBP cheap —
///      the post-ratchet geometry) is closed by selling USDC (`zeroForOne == false`), `d < 0` by
///      selling wstGBP (`zeroForOne == true`). Fair is driven from the GBP/USD leg: GBP UP ⇒ fair
///      DOWN ⇒ d > 0.
contract UsdcWstGbpAdversarialTest is UsdcWstGbpForkBase {
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;

    /// @dev USDC (currency1, base units) needed to move the pool's sqrt price up to `targetSqrtP` at
    ///      liquidity `L`: dy = L * (sqrtTarget - sqrtNow) / Q96.
    function _usdcToClose(uint160 targetSqrtP) internal view returns (uint256 dy) {
        (uint160 sqrtNow,,,) = _slot0();
        require(targetSqrtP > sqrtNow, "gap must be closable by USDC in");
        uint128 liq = PM.getLiquidity(key.toId());
        dy = (uint256(liq) * (targetSqrtP - sqrtNow)) / Q96;
    }

    // ---------------------------------------------------------------- 1. trade-splitting neutrality

    /// @notice One swap closing a deviation vs ten slices closing the same deviation. As in the WETH
    ///         venue (verified there first): splitting is NOT neutral — a single swap pays the
    ///         PRE-swap deviation's fee on its whole amount, while slices integrate down the
    ///         shrinking linear ramp, converging to the schedule's integral. The integral is the
    ///         economically meaningful surcharge floor; the single-swap premium above it taxes
    ///         unsophisticated flow, and per-swap gas bounds how far splitting can chase the floor —
    ///         especially relevant here, where conveyor-arb notionals are small vs mainnet gas.
    function test_tradeSplittingConvergesToScheduleIntegral() public {
        // GBP +1% => fair -1% => d ~ +1%: redeem side (USDC in) closes. Size the full close to fair.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);
        uint256 usdcIn = _usdcToClose(_fairSqrtPriceX96(_fairWad()));

        uint256 snap = vm.snapshotState();

        // Path A: single swap.
        SwapObservation memory one = _swapAndObserve(false, -int256(usdcIn));
        uint256 feeValueA = usdcIn * one.pmFee / 1e6;

        vm.revertToState(snap);

        // Path B: ten slices. Each re-reads live slot0 (only the fair price is cached), so each
        // pays the then-current deviation's fee.
        uint256 feeValueB;
        uint24 firstSliceFee;
        uint24 lastSliceFee;
        for (uint256 i = 0; i < 10; i++) {
            SwapObservation memory o = _swapAndObserve(false, -int256(usdcIn / 10));
            feeValueB += (usdcIn / 10) * o.pmFee / 1e6;
            if (i == 0) firstSliceFee = o.pmFee;
            if (i == 9) lastSliceFee = o.pmFee;
        }

        emit log_named_uint("single-swap fee value (USDC units)", feeValueA);
        emit log_named_uint("ten-slice fee value  (USDC units)", feeValueB);
        emit log_named_uint("first slice fee ppm", firstSliceFee);
        emit log_named_uint("last slice fee ppm", lastSliceFee);

        // Slices see a shrinking deviation, so the last slice is cheaper than the first.
        assertLt(lastSliceFee, firstSliceFee, "deviation shrinks along the slices");
        // Splitting is strictly cheaper (the single swap pays the pre-swap fee on its whole amount)...
        assertLt(feeValueB, feeValueA, "splitting reduces the total fee paid");
        // ...but bounded: the slice total stays above the linear schedule's midpoint integral
        // (avg(first,last) on the sliced amounts), so the advantage cannot exceed ~2x on the
        // surcharge component. No further slicing can beat the integral floor.
        uint256 integralFloor = usdcIn * ((uint256(firstSliceFee) + uint256(lastSliceFee)) / 2) / 1e6;
        assertGe(feeValueB + feeValueB / 20, integralFloor, "slice total ~ schedule integral (5% tol)");
        assertLt(feeValueA, 2 * feeValueB, "single-swap premium bounded (<2x for a linear ramp)");
    }

    // ---------------------------------------------------------------- 2. push-then-close

    /// @notice A manipulator pushing the pool off fair (paying base, arming the surcharge) plus an
    ///         accomplice closing it back cannot end up net positive: the pair's combined loss is
    ///         strictly positive and exceeds any fee the surcharge could have "redirected".
    function test_pushThenCloseStrictlyLoses() public {
        // Start at fair. The pair pushes d to ~ +1% and closes back to ~0.
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 usdcBefore = _bal(USDC, address(this));

        // Push: sell wstGBP (opening flow, d moves positive) — pays mint-side base, no surcharge.
        SwapObservation memory push = _swapAndObserve(true, -int256(2000 * WAD));
        assertEq(push.pmFee, 3000, "push pays base only (opening)");

        // Close: accomplice sells USDC back to fair — pays base + surcharge (armed by the push).
        uint256 usdcIn = _usdcToClose(_fairSqrtPriceX96(_fairWad()));
        SwapObservation memory close = _swapAndObserve(false, -int256(usdcIn));
        assertGt(close.pmFee, 500, "the push armed the surcharge for whoever closes");

        // Combined PnL in wstGBP terms at fair value: strictly negative.
        uint256 fair = _fairWad();
        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dUsdc = int256(_bal(USDC, address(this))) - int256(usdcBefore);
        int256 pnlWsg = dWsg + dUsdc * int256(fair) / int256(USDC_UNIT);
        emit log_named_int("pair net PnL (wstGBP wei, fair-valued)", pnlWsg);
        assertLt(pnlWsg, 0, "push-then-close strictly loses");

        // And the loss exceeds the total fee the pair paid to POL on the closing leg alone — there
        // is no residual 'fee advantage' to fund the manipulation.
        uint256 closeFeeValueWsg = usdcIn * close.pmFee / 1e6 * fair / USDC_UNIT;
        assertGt(uint256(-pnlWsg), closeFeeValueWsg, "loss exceeds the closing-leg fee paid");
    }

    // ---------------------------------------------------------------- 3. JIT liquidity

    /// @notice Quantifies JIT capture around a surcharged swap: a JIT LP mints a tight position over
    ///         the expected move, lets the big closing swap execute, burns. No v1 mitigation (the
    ///         surcharge itself shrinks the JIT edge by taxing the flow JIT wants to farm). At
    ///         spacing 1 a "one-spacing" position would be a degenerate 1-tick sliver, so the JIT
    ///         position here spans the ~1% closing move (~120 ticks) — the realistic JIT shape.
    function test_jitLiquidityCaptureQuantified() public {
        // Arm a ~1% deviation; the closing swap will pay base + surcharge.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);
        uint256 usdcIn = _usdcToClose(_fairSqrtPriceX96(_fairWad()));

        // JIT: 10x the POL liquidity across the closing move (price rises toward fair: USDC in).
        (, int24 tickNow,,) = _slot0();
        int24 jitLower = tickNow;
        int24 jitUpper = tickNow + 120;
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 usdcBefore = _bal(USDC, address(this));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: jitLower, tickUpper: jitUpper, liquidityDelta: 5e18, salt: "jit"}),
            ""
        );

        SwapObservation memory o = _swapAndObserve(false, -int256(usdcIn));
        assertGt(o.pmFee, 500, "swap was surcharged");

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: jitLower, tickUpper: jitUpper, liquidityDelta: -5e18, salt: "jit"}),
            ""
        );

        // JIT PnL in wstGBP terms at fair (fees captured minus adverse selection on inventory).
        uint256 fair = _fairWad();
        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dUsdc = int256(_bal(USDC, address(this))) - int256(usdcBefore);
        int256 jitPnlWsg = dWsg + dUsdc * int256(fair) / int256(USDC_UNIT);
        uint256 totalFeeValueWsg = usdcIn * o.pmFee / 1e6 * fair / USDC_UNIT;

        emit log_named_uint("swap fee ppm", o.pmFee);
        emit log_named_uint("total fee value (wstGBP wei)", totalFeeValueWsg);
        emit log_named_int("JIT PnL (wstGBP wei, fair-valued)", jitPnlWsg);
        // Documented exposure: JIT can profit (fees scale with its liquidity share)...
        // ...but its capture is bounded by the fee the swap actually paid.
        assertLt(jitPnlWsg, int256(totalFeeValueWsg), "JIT capture bounded by the fee paid");
    }

    // ---------------------------------------------------------------- 4. threshold-boundary sandwich

    /// @notice The surcharge ramps linearly FROM ZERO at the threshold, so a bundle that walks the
    ///         deviation across the boundary finds no discontinuity to sandwich: the fee just above
    ///         the threshold is within rounding of the fee just below it.
    function test_noFeeCliffAtThresholdBoundary() public {
        // GBP +0.12% => fair -~0.12% => d ~ +1200 ppm — just past the 1000 ppm threshold.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 100_120) / 100_000, block.timestamp);
        (uint24 feeJustPast, int256 d1) = _expectedFee(false);
        assertGt(d1, 1000, "past the threshold");
        assertLt(d1, 2000, "barely");
        SwapObservation memory first = _swapAndObserve(false, -int256(300 * USDC_UNIT));
        assertEq(first.pmFee, feeJustPast);
        // Continuity: at most the ramp of the tiny excess — no jump to cap or step.
        assertLt(uint256(first.pmFee), 500 + uint256(d1 - 1000), "fee ~ base + slope*(d - threshold)");

        // The swap itself walked d back under the threshold: the follow-up pays exactly base.
        (uint24 feeAfter, int256 d2) = _expectedFee(false);
        assertLt(d2, 1000, "crossed back under");
        SwapObservation memory second = _swapAndObserve(false, -int256(5 * USDC_UNIT));
        assertEq(second.pmFee, feeAfter);
        assertEq(second.pmFee, 500, "base only under the threshold");
    }

    // ---------------------------------------------------------------- 5. fallback under load

    /// @notice A flapping oracle mid-bundle cannot produce inconsistent pricing: the first verdict of
    ///         the transaction rules the whole transaction (cached), swaps never revert.
    function test_fallbackConsistentUnderLoadWithinTransaction() public {
        _brickFeed(GBP_USD_FEED);
        SwapObservation memory a = _swapAndObserve(true, -int256(100 * WAD));
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp); // feed "recovers" mid-tx
        SwapObservation memory b = _swapAndObserve(false, -int256(25 * USDC_UNIT));
        _brickFeed(GBP_USD_FEED); // and flaps again
        SwapObservation memory c = _swapAndObserve(true, -int256(WAD));

        assertTrue(a.fallbackMode && b.fallbackMode && c.fallbackMode, "one verdict per tx");
        assertEq(a.pmFee, 3000);
        assertEq(b.pmFee, 3000);
        assertEq(c.pmFee, 3000);
    }
}
