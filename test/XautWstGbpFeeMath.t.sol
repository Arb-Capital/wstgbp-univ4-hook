// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "../src/xaut/lib/FeeMath.sol";

/// @dev External harness so `vm.expectRevert` can observe `checkParams` (internal library functions
///      revert inside the test frame otherwise).
contract XautFeeMathHarness {
    function checkParams(FeeMath.FeeParams memory p) external pure {
        FeeMath.checkParams(p);
    }

    function swapFee(bool isMintSide, int256 d, FeeMath.FeeParams memory p) external pure returns (uint24) {
        return FeeMath.swapFee(isMintSide, d, p);
    }
}

/// @notice Pure unit suite for the XAUT venue's FeeMath — no fork. Mirrors the sign-convention table
///         in the library NatSpec: d > 0 ⇒ XAUT rich (wstGBP cheap) ⇒ redeem side (XAUT-in) closes
///         and pays the surcharge; d < 0 ⇒ mint side (wstGBP-in) closes. All quantities ppm.
/// @dev The values below are deliberately IDENTICAL to the WETH/USDC suites': `swapFee`/`surchargePpm`
///      are byte-identical across the three dynamic-fee venues and all pin the same shared sim vector
///      table — only the struct shape (10 fields, two staleness windows) differs.
contract XautWstGbpFeeMathTest is Test {
    uint256 constant PPM = 1e6;
    bool constant MINT = true;
    bool constant REDEEM = false;

    XautFeeMathHarness harness;

    function setUp() public {
        harness = new XautFeeMathHarness();
    }

    function _defaults() internal pure returns (FeeMath.FeeParams memory p) {
        p = FeeMath.FeeParams({
            baseFeeMintSide: 3000,
            baseFeeRedeemSide: 500,
            minFee: 200,
            maxFee: 10_000,
            fallbackFee: 3000,
            deviationThresholdPpm: 1000,
            toxicitySlopePpm: 500_000,
            surchargeCapPpm: 6000,
            xauUsdStalenessSec: 90_000,
            gbpUsdStalenessSec: 90_000
        });
    }

    // ---------------------------------------------------------------- band symmetry & gating

    function test_bandSymmetryAtDefaults() public pure {
        FeeMath.FeeParams memory p = _defaults();
        assertEq(FeeMath.swapFee(MINT, 0, p), 3000, "mint base");
        assertEq(FeeMath.swapFee(REDEEM, 0, p), 500, "redeem base");
        // The structural wrapper redeem leg is 25 bps = 2500 ppm: mint = redeem + 2500.
        assertEq(FeeMath.swapFee(MINT, 0, p) - FeeMath.swapFee(REDEEM, 0, p), 2500, "band symmetry");
    }

    function test_directionGating() public pure {
        FeeMath.FeeParams memory p = _defaults();
        // d = +2000 (pool rich in XAUT terms — wstGBP cheap): redeem side (XAUT in) closes -> pays;
        // mint side opens -> base. This is the post-ratchet conveyor direction.
        assertEq(FeeMath.surchargePpm(REDEEM, 2000, p), 500, "redeem closes d>0");
        assertEq(FeeMath.surchargePpm(MINT, 2000, p), 0, "mint opens d>0");
        assertEq(FeeMath.swapFee(REDEEM, 2000, p), 1000, "redeem base+surcharge");
        assertEq(FeeMath.swapFee(MINT, 2000, p), 3000, "mint base only");
        // Mirror at d = -2000 (the gold-rally / token–metal-basis rest side).
        assertEq(FeeMath.surchargePpm(MINT, -2000, p), 500, "mint closes d<0");
        assertEq(FeeMath.surchargePpm(REDEEM, -2000, p), 0, "redeem opens d<0");
        // d = 0: nothing to close, either side.
        assertEq(FeeMath.surchargePpm(MINT, 0, p), 0);
        assertEq(FeeMath.surchargePpm(REDEEM, 0, p), 0);
    }

    // ---------------------------------------------------------------- threshold behavior

    function test_thresholdContinuity() public pure {
        FeeMath.FeeParams memory p = _defaults();
        // At the threshold exactly: no surcharge (band is inclusive).
        assertEq(FeeMath.surchargePpm(REDEEM, 1000, p), 0, "at threshold");
        // 1 ppm past: floor(1 * 500_000 / 1e6) = 0 — the surcharge ramps from zero, no fee cliff.
        assertEq(FeeMath.surchargePpm(REDEEM, 1001, p), 0, "floor rounding at +1");
        // 10 ppm past: floor(10 * 0.5) = 5.
        assertEq(FeeMath.surchargePpm(REDEEM, 1010, p), 5, "linear from zero");
        assertEq(FeeMath.swapFee(REDEEM, 1010, p), 505, "base + ramp");
    }

    // ---------------------------------------------------------------- caps & clamps

    function test_surchargeCapSaturates() public pure {
        FeeMath.FeeParams memory p = _defaults();
        // cap = 6000 binds from excess = 12_000 ppm (12000 * 0.5 = 6000) i.e. d = 13_000.
        assertEq(FeeMath.surchargePpm(REDEEM, 13_000, p), 6000, "exactly at cap");
        assertEq(FeeMath.surchargePpm(REDEEM, 1_000_000, p), 6000, "deep past cap");
        assertEq(FeeMath.swapFee(REDEEM, 1_000_000, p), 6500, "redeem base+cap");
        assertEq(FeeMath.swapFee(MINT, -1_000_000, p), 9000, "mint base+cap");
        // Extreme magnitudes (incl. int256 endpoints) saturate, never revert.
        assertEq(FeeMath.swapFee(REDEEM, type(int256).max, p), 6500);
        assertEq(FeeMath.swapFee(MINT, type(int256).min, p), 9000);
    }

    function test_maxFeeClampBinds() public pure {
        FeeMath.FeeParams memory p = _defaults();
        p.maxFee = 7000; // base 3000 + cap 6000 = 9000 > 7000
        p.surchargeCapPpm = 6000;
        assertEq(FeeMath.swapFee(MINT, -1_000_000, p), 7000, "clamped to maxFee");
    }

    function test_minFeeClampBinds() public pure {
        // Unvalidated params (base < minFee) still clamp up — the function is total; validity is
        // checkParams' job, not swapFee's.
        FeeMath.FeeParams memory p = _defaults();
        p.baseFeeRedeemSide = 100;
        p.minFee = 200;
        assertEq(FeeMath.swapFee(REDEEM, 0, p), 200, "clamped to minFee");
    }

    // ---------------------------------------------------------------- linearity

    function test_surchargeExactlyLinearBelowCap() public pure {
        FeeMath.FeeParams memory p = _defaults();
        uint256 thr = p.deviationThresholdPpm;
        // s(thr + 2e) == 2 * s(thr + e) while below the cap (exact: no floor loss at even excess).
        for (uint256 e = 100; e <= 4000; e += 700) {
            uint256 s1 = FeeMath.surchargePpm(REDEEM, int256(thr + e), p);
            uint256 s2 = FeeMath.surchargePpm(REDEEM, int256(thr + 2 * e), p);
            assertEq(s2, 2 * s1, "linear in excess");
        }
    }

    function testFuzz_surchargeMonotoneInDeviation(int256 a, int256 b) public pure {
        FeeMath.FeeParams memory p = _defaults();
        a = bound(a, 0, 1e62);
        b = bound(b, a, 1e62);
        assertLe(FeeMath.surchargePpm(REDEEM, a, p), FeeMath.surchargePpm(REDEEM, b, p), "monotone non-decreasing");
    }

    // ---------------------------------------------------------------- fuzz: bounds & totality

    /// @dev For arbitrary *valid* params and arbitrary deviation, the fee is always inside
    ///      [minFee, maxFee], fits under the override-flag bit, and never reverts.
    function testFuzz_feeAlwaysWithinBounds(
        uint24 minFee,
        uint24 maxFee,
        uint24 baseMint,
        uint24 baseRedeem,
        uint24 fallbackFee,
        uint24 threshold,
        uint24 slope,
        uint24 cap,
        int256 d,
        bool isMintSide
    ) public view {
        FeeMath.FeeParams memory p;
        p.minFee = uint24(bound(minFee, 1, 50_000));
        p.maxFee = uint24(bound(maxFee, p.minFee, 100_000));
        p.baseFeeMintSide = uint24(bound(baseMint, p.minFee, p.maxFee));
        p.baseFeeRedeemSide = uint24(bound(baseRedeem, p.minFee, p.maxFee));
        p.fallbackFee = uint24(bound(fallbackFee, p.minFee, p.maxFee));
        p.deviationThresholdPpm = uint24(bound(threshold, 0, 100_000));
        p.toxicitySlopePpm = slope;
        p.surchargeCapPpm = uint24(bound(cap, 0, p.maxFee));
        p.xauUsdStalenessSec = 90_000;
        p.gbpUsdStalenessSec = 90_000;
        harness.checkParams(p); // constructed valid by construction — must not revert

        uint24 fee = harness.swapFee(isMintSide, d, p);
        assertGe(fee, p.minFee, "fee >= minFee");
        assertLe(fee, p.maxFee, "fee <= maxFee");
        assertLt(fee, 1 << 23, "no flag-bit collision");
    }

    // ---------------------------------------------------------------- shared sim vectors

    /// @dev Cross-pin with the Python replay sim: this table is byte-for-byte the same as
    ///      `sim/tests/feemath_vectors.json` (duplicated as constants because `fs_permissions`
    ///      deliberately does not cover sim/), and the SAME table pins the WETH and USDC venues'
    ///      FeeMath — the three venues' swap-fee semantics may never drift apart. If any
    ///      implementation drifts, one of the suites fails. Fields: (isMintSide, deviationPpm, fee)
    ///      over default params unless noted.
    function test_sharedSimVectors() public pure {
        FeeMath.FeeParams memory p = _defaults();
        assertEq(FeeMath.swapFee(MINT, 0, p), 3000);
        assertEq(FeeMath.swapFee(REDEEM, 0, p), 500);
        assertEq(FeeMath.swapFee(REDEEM, 2000, p), 1000);
        assertEq(FeeMath.swapFee(MINT, 2000, p), 3000);
        assertEq(FeeMath.swapFee(MINT, -2000, p), 3500);
        assertEq(FeeMath.swapFee(REDEEM, -2000, p), 500);
        assertEq(FeeMath.swapFee(REDEEM, 1000, p), 500);
        assertEq(FeeMath.swapFee(REDEEM, 1001, p), 500);
        assertEq(FeeMath.swapFee(REDEEM, 1010, p), 505);
        assertEq(FeeMath.swapFee(MINT, -1010, p), 3005);
        assertEq(FeeMath.swapFee(REDEEM, 13_000, p), 6500);
        assertEq(FeeMath.swapFee(REDEEM, 10_000_000, p), 6500);
        assertEq(FeeMath.swapFee(MINT, -10_000_000, p), 9000);
        assertEq(FeeMath.swapFee(REDEEM, 4600, p), 2300);

        FeeMath.FeeParams memory q = _defaults();
        q.maxFee = 7000;
        assertEq(FeeMath.swapFee(MINT, -10_000_000, q), 7000);

        q = _defaults();
        q.baseFeeRedeemSide = 100;
        assertEq(FeeMath.swapFee(REDEEM, 0, q), 200);

        q = _defaults();
        q.toxicitySlopePpm = 0;
        assertEq(FeeMath.swapFee(REDEEM, 5000, q), 500);

        q = _defaults();
        q.toxicitySlopePpm = 1_000_000;
        assertEq(FeeMath.swapFee(REDEEM, 3000, q), 2500);

        q = _defaults();
        q.baseFeeMintSide = 2500;
        q.baseFeeRedeemSide = 1000;
        assertEq(FeeMath.swapFee(MINT, 0, q), 2500);
        assertEq(FeeMath.swapFee(REDEEM, 0, q), 1000);
    }

    // ---------------------------------------------------------------- checkParams rejections

    function _expectOutOfBounds(FeeMath.FeeParams memory p) internal {
        vm.expectRevert(FeeMath.FeeParamsOutOfBounds.selector);
        harness.checkParams(p);
    }

    function test_checkParamsAcceptsDefaults() public view {
        harness.checkParams(_defaults());
    }

    function test_checkParamsRejectsEachBound() public {
        FeeMath.FeeParams memory p;

        p = _defaults();
        p.minFee = 0;
        _expectOutOfBounds(p);

        p = _defaults();
        p.maxFee = 100_001; // above the 10% absolute ceiling
        _expectOutOfBounds(p);

        p = _defaults();
        p.baseFeeMintSide = 150; // below minFee
        _expectOutOfBounds(p);

        p = _defaults();
        p.baseFeeMintSide = 10_001; // above maxFee
        _expectOutOfBounds(p);

        p = _defaults();
        p.baseFeeRedeemSide = 150;
        _expectOutOfBounds(p);

        p = _defaults();
        p.baseFeeRedeemSide = 10_001;
        _expectOutOfBounds(p);

        p = _defaults();
        p.fallbackFee = 150;
        _expectOutOfBounds(p);

        p = _defaults();
        p.fallbackFee = 10_001;
        _expectOutOfBounds(p);

        p = _defaults();
        p.surchargeCapPpm = 10_001; // above maxFee
        _expectOutOfBounds(p);

        p = _defaults();
        p.deviationThresholdPpm = 100_001;
        _expectOutOfBounds(p);

        // BOTH staleness windows are individually required nonzero.
        p = _defaults();
        p.xauUsdStalenessSec = 0;
        _expectOutOfBounds(p);

        p = _defaults();
        p.gbpUsdStalenessSec = 0;
        _expectOutOfBounds(p);
    }
}
