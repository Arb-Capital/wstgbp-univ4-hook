// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {XautWstGbpForkBase} from "./base/XautWstGbpForkBase.sol";
import {FeeMath} from "../src/xaut/lib/FeeMath.sol";
import {OracleLib} from "../src/xaut/lib/OracleLib.sol";

/// @notice Adversarial suite for the XAUT venue. Each scenario has a matching economic-argument
///         section in `SECURITY_XAUT_WSTGBP.md`; the tests are the executable half of those notes.
/// @dev Sign conventions: with wstGBP = currency0, `d > 0` (pool prices XAUT rich / wstGBP cheap —
///      the post-ratchet geometry) is closed by selling XAUT (`zeroForOne == false`), `d < 0` by
///      selling wstGBP (`zeroForOne == true`). Fair is `x/(g·nav)`: GBP or NAV UP ⇒ fair DOWN ⇒
///      d > 0; XAU UP ⇒ fair UP ⇒ d < 0 (the gold-rally — and token–metal-basis — side).
contract XautWstGbpAdversarialTest is XautWstGbpForkBase {
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;

    /// @dev XAUT (currency1, base units) needed to move the pool's sqrt price up to `targetSqrtP` at
    ///      liquidity `L`: dy = L * (sqrtTarget - sqrtNow) / Q96.
    function _xautToClose(uint160 targetSqrtP) internal view returns (uint256 dy) {
        (uint160 sqrtNow,,,) = _slot0();
        require(targetSqrtP > sqrtNow, "gap must be closable by XAUT in");
        uint128 liq = PM.getLiquidity(key.toId());
        dy = (uint256(liq) * (targetSqrtP - sqrtNow)) / Q96;
    }

    /// @dev wstGBP (currency0, wei) needed to move the pool's sqrt price DOWN to `targetSqrtP` at
    ///      liquidity `L`: dx = L * Q96 * (sqrtNow - sqrtTarget) / (sqrtNow * sqrtTarget).
    function _wsgToClose(uint160 targetSqrtP) internal view returns (uint256 dx) {
        (uint160 sqrtNow,,,) = _slot0();
        require(targetSqrtP < sqrtNow, "gap must be closable by wstGBP in");
        uint128 liq = PM.getLiquidity(key.toId());
        dx = FullMath.mulDiv(uint256(liq) << 96, sqrtNow - targetSqrtP, uint256(sqrtNow) * uint256(targetSqrtP));
    }

    // ---------------------------------------------------------------- 1. trade-splitting neutrality

    /// @notice One swap closing a deviation vs ten slices closing the same deviation. As in the WETH
    ///         and USDC venues (verified there first): splitting is NOT neutral — a single swap pays
    ///         the PRE-swap deviation's fee on its whole amount, while slices integrate down the
    ///         shrinking linear ramp, converging to the schedule's integral. The integral is the
    ///         economically meaningful surcharge floor; the single-swap premium above it taxes
    ///         unsophisticated flow, and per-swap gas bounds how far splitting can chase the floor —
    ///         especially relevant here, where a 1%-of-POL close is ~1 XAUT and each slice is a
    ///         ~$260 swap against mainnet gas.
    function test_tradeSplittingConvergesToScheduleIntegral() public {
        // GBP +1% => fair -1% => d ~ +1%: redeem side (XAUT in) closes. Size the full close to fair.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);
        uint256 xautIn = _xautToClose(_fairSqrtPriceX96(_fairWad()));

        uint256 snap = vm.snapshotState();

        // Path A: single swap.
        SwapObservation memory one = _swapAndObserve(false, -int256(xautIn));
        uint256 feeValueA = xautIn * one.pmFee / 1e6;

        vm.revertToState(snap);

        // Path B: ten slices. Each re-reads live slot0 (only the fair price is cached), so each
        // pays the then-current deviation's fee.
        uint256 feeValueB;
        uint24 firstSliceFee;
        uint24 lastSliceFee;
        for (uint256 i = 0; i < 10; i++) {
            SwapObservation memory o = _swapAndObserve(false, -int256(xautIn / 10));
            feeValueB += (xautIn / 10) * o.pmFee / 1e6;
            if (i == 0) firstSliceFee = o.pmFee;
            if (i == 9) lastSliceFee = o.pmFee;
        }

        emit log_named_uint("single-swap fee value (XAUT units)", feeValueA);
        emit log_named_uint("ten-slice fee value  (XAUT units)", feeValueB);
        emit log_named_uint("first slice fee ppm", firstSliceFee);
        emit log_named_uint("last slice fee ppm", lastSliceFee);

        // Slices see a shrinking deviation, so the last slice is cheaper than the first.
        assertLt(lastSliceFee, firstSliceFee, "deviation shrinks along the slices");
        // Splitting is strictly cheaper (the single swap pays the pre-swap fee on its whole amount)...
        assertLt(feeValueB, feeValueA, "splitting reduces the total fee paid");
        // ...but bounded: the slice total stays above the linear schedule's midpoint integral
        // (avg(first,last) on the sliced amounts), so the advantage cannot exceed ~2x on the
        // surcharge component. No further slicing can beat the integral floor.
        uint256 integralFloor = xautIn * ((uint256(firstSliceFee) + uint256(lastSliceFee)) / 2) / 1e6;
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
        uint256 xautBefore = _bal(XAUT, address(this));

        // Push: sell wstGBP (opening flow, d moves positive) — pays mint-side base, no surcharge.
        SwapObservation memory push = _swapAndObserve(true, -int256(2000 * WAD));
        assertEq(push.pmFee, 3000, "push pays base only (opening)");

        // Close: accomplice sells XAUT back to fair — pays base + surcharge (armed by the push).
        uint256 xautIn = _xautToClose(_fairSqrtPriceX96(_fairWad()));
        SwapObservation memory close = _swapAndObserve(false, -int256(xautIn));
        assertGt(close.pmFee, 500, "the push armed the surcharge for whoever closes");

        // Combined PnL in wstGBP terms at fair value: strictly negative.
        uint256 fair = _fairWad();
        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dXaut = int256(_bal(XAUT, address(this))) - int256(xautBefore);
        int256 pnlWsg = dWsg + dXaut * int256(fair) / int256(XAUT_UNIT);
        emit log_named_int("pair net PnL (wstGBP wei, fair-valued)", pnlWsg);
        assertLt(pnlWsg, 0, "push-then-close strictly loses");

        // And the loss exceeds the total fee the pair paid to POL on the closing leg alone — there
        // is no residual 'fee advantage' to fund the manipulation.
        uint256 closeFeeValueWsg = xautIn * close.pmFee / 1e6 * fair / XAUT_UNIT;
        assertGt(uint256(-pnlWsg), closeFeeValueWsg, "loss exceeds the closing-leg fee paid");
    }

    // ---------------------------------------------------------------- 3. JIT liquidity

    /// @notice Quantifies JIT capture around a surcharged swap: a JIT LP mints a tight position over
    ///         the expected move, lets the big closing swap execute, burns. No v1 mitigation (the
    ///         surcharge itself shrinks the JIT edge by taxing the flow JIT wants to farm). At
    ///         spacing 60 the tightest legal position is already 60 ticks; the JIT position here
    ///         spans three spacings (180 ticks) so the ~1% (~100-tick) closing move stays covered
    ///         from anywhere inside the current spacing — the realistic JIT shape.
    function test_jitLiquidityCaptureQuantified() public {
        // Arm a ~1% deviation; the closing swap will pay base + surcharge.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);
        uint256 xautIn = _xautToClose(_fairSqrtPriceX96(_fairWad()));

        // JIT: 10x the POL liquidity across the closing move (price rises toward fair: XAUT in).
        (, int24 tickNow,,) = _slot0();
        int24 jitLower = _floorToSpacing(tickNow);
        int24 jitUpper = jitLower + 3 * TICK_SPACING;
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 xautBefore = _bal(XAUT, address(this));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: jitLower, tickUpper: jitUpper, liquidityDelta: 9e16, salt: "jit"}),
            ""
        );

        SwapObservation memory o = _swapAndObserve(false, -int256(xautIn));
        assertGt(o.pmFee, 500, "swap was surcharged");

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: jitLower, tickUpper: jitUpper, liquidityDelta: -9e16, salt: "jit"}),
            ""
        );

        // JIT PnL in wstGBP terms at fair (fees captured minus adverse selection on inventory).
        uint256 fair = _fairWad();
        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dXaut = int256(_bal(XAUT, address(this))) - int256(xautBefore);
        int256 jitPnlWsg = dWsg + dXaut * int256(fair) / int256(XAUT_UNIT);
        uint256 totalFeeValueWsg = xautIn * o.pmFee / 1e6 * fair / XAUT_UNIT;

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
        SwapObservation memory first = _swapAndObserve(false, -int256(XAUT_UNIT / 10));
        assertEq(first.pmFee, feeJustPast);
        // Continuity: at most the ramp of the tiny excess — no jump to cap or step.
        assertLt(uint256(first.pmFee), 500 + uint256(d1 - 1000), "fee ~ base + slope*(d - threshold)");

        // The swap itself walked d back under the threshold: the follow-up pays exactly base.
        (uint24 feeAfter, int256 d2) = _expectedFee(false);
        assertLt(d2, 1000, "crossed back under");
        SwapObservation memory second = _swapAndObserve(false, -int256(XAUT_UNIT / 500));
        assertEq(second.pmFee, feeAfter);
        assertEq(second.pmFee, 500, "base only under the threshold");
    }

    // ---------------------------------------------------------------- 5. fallback under load

    /// @notice A flapping oracle mid-bundle cannot produce inconsistent pricing: the first verdict of
    ///         the transaction rules the whole transaction (cached), swaps never revert.
    function test_fallbackConsistentUnderLoadWithinTransaction() public {
        _brickFeed(XAU_USD_FEED);
        SwapObservation memory a = _swapAndObserve(true, -int256(100 * WAD));
        _mockFeed(XAU_USD_FEED, XAU_USD_ANSWER, block.timestamp); // feed "recovers" mid-tx
        SwapObservation memory b = _swapAndObserve(false, -int256(XAUT_UNIT / 100));
        _brickFeed(XAU_USD_FEED); // and flaps again
        SwapObservation memory c = _swapAndObserve(true, -int256(WAD));

        assertTrue(a.fallbackMode && b.fallbackMode && c.fallbackMode, "one verdict per tx");
        assertEq(a.pmFee, 3000);
        assertEq(b.pmFee, 3000);
        assertEq(c.pmFee, 3000);
    }

    // ---------------------------------------------------------------- 6. token–metal basis rest state

    /// @notice THIS venue's signature risk (hook/OracleLib NatSpec, decision 2026-07-11): XAU/USD
    ///         prices the metal while the pool trades the token, so the pool RESTS at d ≈ −basis
    ///         instead of 0. This test exercises the DISCOUNT regime (basis > 0, the 2026-07-11
    ///         ~0.5% estimate; the live basis is sign-unstable — the premium regime's side-flip is
    ///         pinned in the sim suite, `test_premium_regime_flips_the_surcharged_side`). Modeled
    ///         by raising the metal feed ~0.5% above the level the
    ///         pool trades at. Three claims: (a) with the working threshold (1000 ppm < basis) the
    ///         RESTING mint-side flow — ordinary sterling-into-gold wrappers, not arbitrageurs — is
    ///         misclassified as deviation-closing and pays the surcharge (the accepted cost the
    ///         goldsim threshold sizing exists to remove); (b) a threshold sized above the basis
    ///         (6000 ppm via `setFeeParams`) reclassifies the same flow to base-only; (c) the basis
    ///         rest state arms no manipulation edge — push-then-close still strictly loses there.
    function test_basisRestState_thresholdSizing() public {
        // Metal feed 0.5% above the token's trading level: fair rises to 2010e18, the pool rests
        // below it at d ≈ −5000 ppm (exactly 1/1.005 − 1 ≈ −4976 ppm).
        _mockFeed(XAU_USD_FEED, (XAU_USD_ANSWER * 1005) / 1000, block.timestamp);
        (, int256 dRest) = _expectedFee(true);
        assertLt(dRest, -4500, "pool rests below the metal-feed fair");
        assertGt(dRest, -5500, "by ~the modeled 0.5% basis");

        uint256 snap = vm.snapshotState();

        // (a) threshold 1000 < basis: resting mint-side flow pays base + ~0.5*(4976-1000) ppm.
        (uint24 expectedRestFee,) = _expectedFee(true);
        SwapObservation memory rest = _swapAndObserve(true, -int256(100 * WAD));
        assertEq(rest.pmFee, expectedRestFee);
        assertGt(rest.pmFee, 3000, "undersized threshold: resting mint flow is surcharged at rest");
        assertLt(rest.pmFee, 5100, "misclassification cost is the ramp, not the cap");
        // The redeem side opens at d < 0 and is untouched either way.
        SwapObservation memory opener = _swapAndObserve(false, -int256(XAUT_UNIT / 100));
        assertEq(opener.pmFee, 500, "redeem side pays base at the rest state");

        vm.revertToState(snap);

        // (b) threshold sized above the basis (6000 ppm): the same resting flow pays base only.
        FeeMath.FeeParams memory p = _defaultParams();
        p.deviationThresholdPpm = 6000;
        vm.prank(owner);
        hook.setFeeParams(p);
        SwapObservation memory sized = _swapAndObserve(true, -int256(100 * WAD));
        assertEq(sized.pmFee, 3000, "threshold above the basis: rest flow pays base only");

        vm.revertToState(snap);

        // (c) push-then-close at the basis rest state (back on the undersized threshold — the
        // adversary's best case: the surcharge is already armed at rest). Push: sell XAUT (opening
        // at d < 0, pays redeem base) driving d ~ -0.5% -> ~ -1.5%; accomplice closes back to rest.
        // PnL is valued at the pool's own rest price — the level the TOKEN actually trades; marking
        // at metal fair would only shift the mark, not the sign.
        (uint160 restSqrtP,,,) = _slot0();
        uint256 restWad = OracleLib.poolPriceWstGbpPerXautWad(restSqrtP, WSGEM < XAUT);
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 xautBefore = _bal(XAUT, address(this));

        SwapObservation memory push = _swapAndObserve(false, -int256(XAUT_UNIT));
        assertEq(push.pmFee, 500, "push pays redeem base only (opening at the rest state)");

        uint256 wsgIn = _wsgToClose(restSqrtP);
        SwapObservation memory close = _swapAndObserve(true, -int256(wsgIn));
        assertGt(close.pmFee, 3000, "the push armed a larger mint-side surcharge for whoever closes");

        int256 dWsg = int256(_bal(WSGEM, address(this))) - int256(wsgBefore);
        int256 dXaut = int256(_bal(XAUT, address(this))) - int256(xautBefore);
        int256 pnlWsg = dWsg + dXaut * int256(restWad) / int256(XAUT_UNIT);
        emit log_named_int("pair net PnL at basis rest (wstGBP wei, rest-valued)", pnlWsg);
        assertLt(pnlWsg, 0, "push-then-close strictly loses at the basis rest state");
        uint256 closeFeeValueWsg = wsgIn * close.pmFee / 1e6;
        assertGt(uint256(-pnlWsg), closeFeeValueWsg, "loss exceeds the closing-leg fee paid");
    }
}
