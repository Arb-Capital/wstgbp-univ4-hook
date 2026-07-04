// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WethWstGbpForkBase} from "./base/WethWstGbpForkBase.sol";

/// @notice Phase 4 adversarial suite. Each scenario has a matching economic-argument section in
///         `SECURITY_WETH_WSTGBP.md`; the tests are the executable half of those notes.
/// @dev Sign conventions: with wstGBP = currency0, `d > 0` (pool prices WETH rich) is closed by
///      selling WETH (`zeroForOne == false`), `d < 0` by selling wstGBP (`zeroForOne == true`).
contract WethWstGbpAdversarialTest is WethWstGbpForkBase {
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;

    /// @dev WETH needed to move the pool's sqrt price up to `targetSqrtP` at liquidity `L`
    ///      (currency1 in): dy = L * (sqrtTarget - sqrtNow) / Q96.
    function _wethToClose(uint160 targetSqrtP) internal view returns (uint256 dy) {
        (uint160 sqrtNow,,,) = _slot0();
        require(targetSqrtP > sqrtNow, "gap must be closable by WETH in");
        uint128 liq = PM.getLiquidity(key.toId());
        dy = (uint256(liq) * (targetSqrtP - sqrtNow)) / Q96;
    }

    // ---------------------------------------------------------------- 1. trade-splitting neutrality

    /// @notice One swap closing a deviation vs ten slices closing the same deviation. VERIFIED (spec
    ///         §3.3 said verify, don't assume) — splitting is NOT neutral under this design: a single
    ///         swap pays the PRE-swap deviation's fee on its whole amount, while slices integrate
    ///         down the shrinking linear ramp, converging to the schedule's integral (~the average of
    ///         the first and last slice fees, here ~45% less). The integral is the economically
    ///         meaningful surcharge floor; the single-swap premium above it taxes unsophisticated
    ///         flow, and per-swap gas bounds how far splitting can chase the floor. Full economic
    ///         note in SECURITY_WETH_WSTGBP.md; the assertions pin the ACTUAL semantics.
    function test_tradeSplittingConvergesToScheduleIntegral() public {
        // Fair -1% => d ~ +1%: redeem side (WETH in) closes. Size the full close to the fair target.
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 99) / 100, block.timestamp);
        uint256 wethIn = _wethToClose(_fairSqrtPriceX96(_fairWad()));

        uint256 snap = vm.snapshotState();

        // Path A: single swap.
        SwapObservation memory one = _swapAndObserve(false, -int256(wethIn));
        uint256 feeValueA = wethIn * one.pmFee / 1e6;

        vm.revertToState(snap);

        // Path B: ten slices. Each re-reads live slot0 (only the fair price is cached), so each
        // pays the then-current deviation's fee.
        uint256 feeValueB;
        uint24 firstSliceFee;
        uint24 lastSliceFee;
        for (uint256 i = 0; i < 10; i++) {
            SwapObservation memory o = _swapAndObserve(false, -int256(wethIn / 10));
            feeValueB += (wethIn / 10) * o.pmFee / 1e6;
            if (i == 0) firstSliceFee = o.pmFee;
            if (i == 9) lastSliceFee = o.pmFee;
        }

        emit log_named_uint("single-swap fee value (WETH wei)", feeValueA);
        emit log_named_uint("ten-slice fee value  (WETH wei)", feeValueB);
        emit log_named_uint("first slice fee ppm", firstSliceFee);
        emit log_named_uint("last slice fee ppm", lastSliceFee);

        // Slices see a shrinking deviation, so the last slice is cheaper than the first.
        assertLt(lastSliceFee, firstSliceFee, "deviation shrinks along the slices");
        // Splitting is strictly cheaper (the single swap pays the pre-swap fee on its whole amount)...
        assertLt(feeValueB, feeValueA, "splitting reduces the total fee paid");
        // ...but bounded: the slice total stays above the linear schedule's midpoint integral
        // (avg(first,last) on the sliced amounts), so the advantage cannot exceed ~2x on the
        // surcharge component. No further slicing can beat the integral floor.
        uint256 integralFloor = wethIn * ((uint256(firstSliceFee) + uint256(lastSliceFee)) / 2) / 1e6;
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
        uint256 wethBefore = _bal(WETH, address(this));

        // Push: sell wstGBP (opening flow, d moves positive) — pays mint-side base, no surcharge.
        SwapObservation memory push = _swapAndObserve(true, -int256(2000 * WAD));
        assertEq(push.pmFee, 3000, "push pays base only (opening)");

        // Close: accomplice sells WETH back to fair — pays base + surcharge (armed by the push).
        uint256 wethIn = _wethToClose(_fairSqrtPriceX96(_fairWad()));
        SwapObservation memory close = _swapAndObserve(false, -int256(wethIn));
        assertGt(close.pmFee, 500, "the push armed the surcharge for whoever closes");

        // Combined PnL in wstGBP terms at fair value: strictly negative.
        uint256 fair = _fairWad();
        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dWeth = int256(_bal(WETH, address(this))) - int256(wethBefore);
        int256 pnlWsg = dWsg + dWeth * int256(fair) / int256(WAD);
        emit log_named_int("pair net PnL (wstGBP wei, fair-valued)", pnlWsg);
        assertLt(pnlWsg, 0, "push-then-close strictly loses");

        // And the loss exceeds the total fee the pair paid to POL on the closing leg alone — there
        // is no residual 'fee advantage' to fund the manipulation.
        uint256 closeFeeValueWsg = wethIn * close.pmFee / 1e6 * fair / WAD;
        assertGt(uint256(-pnlWsg), closeFeeValueWsg, "loss exceeds the closing-leg fee paid");
    }

    // ---------------------------------------------------------------- 3. JIT liquidity

    /// @notice Quantifies JIT capture around a surcharged swap: a JIT LP mints a tick-tight position,
    ///         lets the big closing swap execute, burns. No v1 mitigation (spec: document; the
    ///         surcharge itself shrinks the JIT edge by taxing the flow JIT wants to farm).
    function test_jitLiquidityCaptureQuantified() public {
        // Arm a ~1% deviation; the closing swap will pay base + surcharge.
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 99) / 100, block.timestamp);
        uint256 wethIn = _wethToClose(_fairSqrtPriceX96(_fairWad()));

        // JIT: 10x the POL liquidity, one spacing wide around the current tick.
        (, int24 tickNow,,) = _slot0();
        int24 jitLower = _floorToSpacing(tickNow);
        int24 jitUpper = jitLower + TICK_SPACING;
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 wethBefore = _bal(WETH, address(this));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: jitLower, tickUpper: jitUpper, liquidityDelta: 1e23, salt: "jit"}),
            ""
        );

        SwapObservation memory o = _swapAndObserve(false, -int256(wethIn));
        assertGt(o.pmFee, 500, "swap was surcharged");

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: jitLower, tickUpper: jitUpper, liquidityDelta: -1e23, salt: "jit"}),
            ""
        );

        // JIT PnL in wstGBP terms at fair (fees captured minus adverse selection on inventory).
        uint256 fair = _fairWad();
        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dWeth = int256(_bal(WETH, address(this))) - int256(wethBefore);
        int256 jitPnlWsg = dWsg + dWeth * int256(fair) / int256(WAD);
        uint256 totalFeeValueWsg = wethIn * o.pmFee / 1e6 * fair / WAD;

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
        // d ~ +0.12% — just past the 0.10% threshold.
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 99_880) / 100_000, block.timestamp);
        (uint24 feeJustPast, int256 d1) = _expectedFee(false);
        assertGt(d1, 1000, "past the threshold");
        assertLt(d1, 2000, "barely");
        SwapObservation memory first = _swapAndObserve(false, -int256(WAD / 30));
        assertEq(first.pmFee, feeJustPast);
        // Continuity: at most the ramp of the tiny excess — no jump to cap or step.
        assertLt(uint256(first.pmFee), 500 + uint256(d1 - 1000), "fee ~ base + slope*(d - threshold)");

        // The swap itself walked d back under the threshold: the follow-up pays exactly base.
        (uint24 feeAfter, int256 d2) = _expectedFee(false);
        assertLt(d2, 1000, "crossed back under");
        SwapObservation memory second = _swapAndObserve(false, -int256(WAD / 500));
        assertEq(second.pmFee, feeAfter);
        assertEq(second.pmFee, 500, "base only under the threshold");
    }

    // ---------------------------------------------------------------- 5. fallback under load

    /// @notice A flapping oracle mid-bundle cannot produce inconsistent pricing: the first verdict of
    ///         the transaction rules the whole transaction (cached), swaps never revert.
    function test_fallbackConsistentUnderLoadWithinTransaction() public {
        _brickFeed(ETH_USD_FEED);
        SwapObservation memory a = _swapAndObserve(true, -int256(100 * WAD));
        _mockFeed(ETH_USD_FEED, ETH_USD_ANSWER, block.timestamp); // feed "recovers" mid-tx
        SwapObservation memory b = _swapAndObserve(false, -int256(WAD / 100));
        _brickFeed(ETH_USD_FEED); // and flaps again
        SwapObservation memory c = _swapAndObserve(true, -int256(WAD));

        assertTrue(a.fallbackMode && b.fallbackMode && c.fallbackMode, "one verdict per tx");
        assertEq(a.pmFee, 3000);
        assertEq(b.pmFee, 3000);
        assertEq(c.pmFee, 3000);
    }
}
