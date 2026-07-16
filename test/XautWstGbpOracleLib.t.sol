// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {OracleLib} from "../src/xaut/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/xaut/interfaces/IAggregatorV3.sol";

/// @dev Configurable Chainlink mock: normal answers, reverts, short (non-decodable) returns, and
///      full-length returns whose ignored uint80 words carry dirty high bits (F-1 regression).
contract MockAggregator {
    uint8 public constant MODE_NORMAL = 0;
    uint8 public constant MODE_REVERT = 1;
    uint8 public constant MODE_SHORT_RETURN = 2;
    uint8 public constant MODE_DIRTY_WORDS = 3;

    int256 public answer;
    uint256 public updatedAt;
    uint8 public mode;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        mode = MODE_NORMAL;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == MODE_REVERT) revert("feed down");
        if (mode == MODE_SHORT_RETURN) {
            assembly {
                mstore(0, 1)
                return(0, 64) // 64 bytes < the 160 a well-formed round occupies
            }
        }
        if (mode == MODE_DIRTY_WORDS) {
            // A well-formed 160-byte round whose roundId/answeredInRound words have every bit set
            // (invalid as uint80): a narrow-typed abi.decode of these words reverts in the CALLER's
            // frame, which is exactly what OracleLib must not let happen.
            int256 a = answer;
            uint256 u = updatedAt;
            assembly {
                mstore(0x00, not(0)) // roundId: dirty beyond uint80
                mstore(0x20, a)
                mstore(0x40, u) // startedAt (ignored)
                mstore(0x60, u)
                mstore(0x80, not(0)) // answeredInRound: dirty beyond uint80
                return(0x00, 160)
            }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Minimal wrapper mock exposing only `navprice()`, with the same failure modes.
contract MockNav {
    uint8 public constant MODE_NORMAL = 0;
    uint8 public constant MODE_REVERT = 1;
    uint8 public constant MODE_SHORT_RETURN = 2;

    uint256 public nav;
    uint8 public mode;

    function set(uint256 nav_) external {
        nav = nav_;
        mode = MODE_NORMAL;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function navprice() external view returns (uint256) {
        if (mode == MODE_REVERT) revert("pip down");
        if (mode == MODE_SHORT_RETURN) {
            assembly {
                return(0, 16)
            }
        }
        return nav;
    }
}

/// @notice Pure/mocked unit suite for the XAUT venue's OracleLib — no fork. Pins the two-feed
///         composition `x·WAD²/(g·nav)` against hand-computed vectors and walks the entire failure
///         taxonomy per feed (XAU reasons 1..3, GBP reasons 4..6, NAV_BAD 7): nothing here may
///         revert. Pool prices carry the 6-decimal `XAUT_UNIT` constant: a raw unit ratio of 1 is
///         1e-12 wstGBP-per-XAUT, i.e. poolWad = 1e6.
contract XautWstGbpOracleLibTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant NOW = 1_800_000_000;
    uint256 constant XAU_WINDOW = 90_000;
    uint256 constant GBP_WINDOW = 90_000;
    uint256 constant Q96 = 2 ** 96;

    MockAggregator xauUsd;
    MockAggregator gbpUsd;
    MockNav wrapper;

    function setUp() public {
        vm.warp(NOW);
        xauUsd = new MockAggregator();
        gbpUsd = new MockAggregator();
        wrapper = new MockNav();
        // Healthy defaults (the fixture's deterministic values): gold $2,625, GBP $1.25, NAV 1.05
        // tGBP/wstGBP ⇒ fair = 2625/1.3125 = exactly 2000 wstGBP/XAUT.
        xauUsd.set(2625e8, NOW);
        gbpUsd.set(1.25e8, NOW);
        wrapper.set(1.05e18);
    }

    function _fair() internal view returns (uint256 fairWad, OracleLib.FallbackReason reason) {
        return OracleLib.fairPriceWad(
            IAggregatorV3(address(xauUsd)), IAggregatorV3(address(gbpUsd)), address(wrapper), XAU_WINDOW, GBP_WINDOW
        );
    }

    function _assertReason(OracleLib.FallbackReason expected) internal view {
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(expected), "reason");
        assertEq(fairWad, 0, "failed composition returns 0");
    }

    // ---------------------------------------------------------------- composition vectors

    function test_compositionHandVector1() public view {
        // 2625e8·1e36 / (1.25e8 · 1.05e18) = 2000.000000000000000000 exactly — the fixture values
        // are chosen so the composition pins a clean round number (verified by hand, Python big-int).
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE));
        assertEq(fairWad, 2000e18);
    }

    function test_compositionHandVector2AwkwardPrimes() public {
        // X = $2647.65432101, G = $1.27653421, N = 1.037019382716049382:
        // floor(X·1e36 / (G·N)) = 2000055057093801599104 (≈ 2000.0550… wstGBP/XAUT).
        xauUsd.set(264765432101, NOW);
        gbpUsd.set(127653421, NOW);
        wrapper.set(1037019382716049382);
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE));
        assertEq(fairWad, 2000055057093801599104);
    }

    function test_compositionParNavIsExact() public {
        wrapper.set(1e18);
        (uint256 fairWad,) = _fair();
        assertEq(fairWad, 2100e18, "2625/1.25 at par NAV");
    }

    // ---------------------------------------------------------------- staleness boundaries

    function test_stalenessBoundaryPerFeed() public {
        // Exactly at the window: fresh.
        xauUsd.set(2625e8, NOW - XAU_WINDOW);
        (, OracleLib.FallbackReason r1) = _fair();
        assertEq(uint8(r1), uint8(OracleLib.FallbackReason.NONE), "xau at window is fresh");

        // One second past: stale — and only the XAU reason fires.
        xauUsd.set(2625e8, NOW - XAU_WINDOW - 1);
        _assertReason(OracleLib.FallbackReason.XAU_FEED_STALE);

        // GBP has its own window.
        xauUsd.set(2625e8, NOW);
        gbpUsd.set(1.25e8, NOW - GBP_WINDOW);
        (, OracleLib.FallbackReason r2) = _fair();
        assertEq(uint8(r2), uint8(OracleLib.FallbackReason.NONE), "gbp at window is fresh");
        gbpUsd.set(1.25e8, NOW - GBP_WINDOW - 1);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_STALE);

        // updatedAt in the future is stale, not fresh — on either feed.
        gbpUsd.set(1.25e8, NOW + 1);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_STALE);
        gbpUsd.set(1.25e8, NOW);
        xauUsd.set(2625e8, NOW + 1);
        _assertReason(OracleLib.FallbackReason.XAU_FEED_STALE);
    }

    /// @dev The two windows are positional: argument 4 governs the XAU feed, argument 5 the GBP
    ///      feed. Both production windows are 90_000, so the boundary test above could not catch a
    ///      transposition — asymmetric windows over equal-age rounds make one observable.
    function test_stalenessWindowsArePerFeed() public {
        // Same age on both feeds; only the XAU window is short: the XAU feed is the stale one.
        xauUsd.set(2625e8, NOW - 4501);
        gbpUsd.set(1.25e8, NOW - 4501);
        (, OracleLib.FallbackReason r) = OracleLib.fairPriceWad(
            IAggregatorV3(address(xauUsd)), IAggregatorV3(address(gbpUsd)), address(wrapper), 4500, 90_000
        );
        assertEq(uint8(r), uint8(OracleLib.FallbackReason.XAU_FEED_STALE), "xau window is arg 4");

        // Windows swapped: the same rounds now fail on the GBP side only.
        (, r) = OracleLib.fairPriceWad(
            IAggregatorV3(address(xauUsd)), IAggregatorV3(address(gbpUsd)), address(wrapper), 90_000, 4500
        );
        assertEq(uint8(r), uint8(OracleLib.FallbackReason.GBP_FEED_STALE), "gbp window is arg 5");
    }

    // ---------------------------------------------------------------- failure taxonomy

    function test_xauFeedFailures() public {
        xauUsd.setMode(xauUsd.MODE_REVERT());
        _assertReason(OracleLib.FallbackReason.XAU_FEED_CALL);

        xauUsd.setMode(xauUsd.MODE_SHORT_RETURN());
        _assertReason(OracleLib.FallbackReason.XAU_FEED_CALL);

        xauUsd.set(0, NOW);
        _assertReason(OracleLib.FallbackReason.XAU_FEED_ANSWER);

        xauUsd.set(-1, NOW);
        _assertReason(OracleLib.FallbackReason.XAU_FEED_ANSWER);

        xauUsd.set(int256(uint256(1e30) + 1), NOW);
        _assertReason(OracleLib.FallbackReason.XAU_FEED_ANSWER);
    }

    /// @dev GBP failures with the XAU feed healthy: every reason must land in the GBP block of the
    ///      enum — the `_readFeed` code + 3 shift applied to the second feed only.
    function test_gbpFeedFailures() public {
        gbpUsd.setMode(gbpUsd.MODE_REVERT());
        _assertReason(OracleLib.FallbackReason.GBP_FEED_CALL);

        gbpUsd.setMode(gbpUsd.MODE_SHORT_RETURN());
        _assertReason(OracleLib.FallbackReason.GBP_FEED_CALL);

        gbpUsd.set(0, NOW);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_ANSWER);

        gbpUsd.set(-5, NOW);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_ANSWER);

        gbpUsd.set(int256(uint256(1e30) + 1), NOW);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_ANSWER);
    }

    /// @dev The XAU feed is read FIRST: when both feeds are broken the XAU reason wins — whatever
    ///      the GBP failure kind — and healing the XAU feed then surfaces the GBP reason.
    function test_bothFeedsBrokenXauReasonWins() public {
        // Different failure kinds on purpose (XAU stale vs GBP call): first-feed-wins, not
        // kind-wins.
        xauUsd.set(2625e8, NOW - XAU_WINDOW - 1);
        gbpUsd.setMode(gbpUsd.MODE_REVERT());
        _assertReason(OracleLib.FallbackReason.XAU_FEED_STALE);

        // Both dead at the call level: still the XAU entry.
        xauUsd.setMode(xauUsd.MODE_REVERT());
        _assertReason(OracleLib.FallbackReason.XAU_FEED_CALL);

        // Heal XAU only: the GBP reason (errG + 3) surfaces.
        xauUsd.set(2625e8, NOW);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_CALL);
    }

    /// @dev F-1 regression: a >=160-byte round whose IGNORED uint80 words (roundId /
    ///      answeredInRound) carry dirty high bits must be read normally — never revert.
    ///      `abi.decode` validates value types, so decoding those words as uint80 would give a
    ///      hostile/buggy aggregator a revert path in the hook's own frame (swap DoS). Covered in
    ///      BOTH feed positions.
    function test_dirtyUint80WordsStillReadable() public {
        // XAU position alone...
        xauUsd.setMode(xauUsd.MODE_DIRTY_WORDS());
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE), "dirty xau words read fine");
        assertEq(fairWad, 2000e18, "composition unaffected");

        // ...then the GBP position too.
        gbpUsd.setMode(gbpUsd.MODE_DIRTY_WORDS());
        (fairWad, reason) = _fair();
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE), "dirty gbp words read fine");
        assertEq(fairWad, 2000e18, "composition unaffected");
    }

    function test_xauFeedNoCode() public {
        // A codeless address staticcalls "successfully" with empty returndata — must map to CALL.
        (, OracleLib.FallbackReason reason) = OracleLib.fairPriceWad(
            IAggregatorV3(makeAddr("no code")), IAggregatorV3(address(gbpUsd)), address(wrapper), XAU_WINDOW, GBP_WINDOW
        );
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.XAU_FEED_CALL));
    }

    function test_gbpFeedNoCode() public {
        (, OracleLib.FallbackReason reason) = OracleLib.fairPriceWad(
            IAggregatorV3(address(xauUsd)), IAggregatorV3(makeAddr("no code")), address(wrapper), XAU_WINDOW, GBP_WINDOW
        );
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.GBP_FEED_CALL));
    }

    function test_navFailures() public {
        // nav == 0 is the pip's documented paused state — the load-bearing fallback trigger.
        wrapper.set(0);
        _assertReason(OracleLib.FallbackReason.NAV_BAD);

        wrapper.setMode(wrapper.MODE_REVERT());
        _assertReason(OracleLib.FallbackReason.NAV_BAD);

        wrapper.setMode(wrapper.MODE_SHORT_RETURN());
        _assertReason(OracleLib.FallbackReason.NAV_BAD);

        wrapper.set(1e30 + 1);
        _assertReason(OracleLib.FallbackReason.NAV_BAD);
    }

    function test_compositionFlooringToSubSentinelIsNavBad() public {
        // X minimal, G·N maximal floors the composition to 0 (< 2, the reserved sentinel space).
        xauUsd.set(1, NOW);
        gbpUsd.set(1e30, NOW);
        wrapper.set(1e30);
        _assertReason(OracleLib.FallbackReason.NAV_BAD);

        // Exact boundary: X·1e36 = G·N floors fair to exactly 1 — inside the reserved sentinel
        // space — with all three answers individually passing their bounds. Must be NAV_BAD.
        xauUsd.set(1e8, NOW);
        gbpUsd.set(1e22, NOW);
        wrapper.set(1e22);
        _assertReason(OracleLib.FallbackReason.NAV_BAD);
    }

    // ---------------------------------------------------------------- pool price orientation

    function test_poolPriceAtRawParityIsXautUnit() public pure {
        // Raw unit ratio 1 (sqrtP = Q96) means 1 wstGBP-wei per XAUT-base-unit = 1e-12 wstGBP per
        // XAUT ⇒ poolWad = 1e6 in both orientations. The 18/18 WETH venue read 1e18 here; the delta
        // IS the folded decimal gap.
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(uint160(Q96), true), 1e6);
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(uint160(Q96), false), 1e6);
    }

    function test_poolPriceOrientationInverts() public pure {
        // sqrtP = 2·2^96 ⇒ raw pool price 4: direct orientation reads 4e6, inverted reads 0.25e6.
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(uint160(2 * Q96), false), 4e6);
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(uint160(2 * Q96), true), 0.25e6);
    }

    function test_poolPriceRealisticVector() public pure {
        // Real-pair orientation (wstGBP = currency0) at the fixture fair 2000e18 wstGBP/XAUT — raw
        // pool price XAUT_UNIT/fair = 5e-16: sqrtP = isqrt((1e6 << 192) / fair) =
        // 1771595571142957102961 ⇒ poolWad = 2000000000000008522059 (hand-computed floor;
        // ~4e-9 ppm above fair from isqrt flooring — the init script's <1000 ppm assert covers the
        // same rounding).
        uint160 sqrtP = 1771595571142957102961;
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(sqrtP, true), 2000000000000008522059);
    }

    function test_poolPriceExtremesAreTotal() public pure {
        // MIN squares to zero at Q96: inverted orientation hits the division guard sentinel;
        // direct orientation floors to 0. MAX: direct is ~3.4e44; inverted floors to 0.
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(TickMath.MIN_SQRT_PRICE, true), OracleLib.EXTREME_PRICE_SENTINEL);
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(TickMath.MIN_SQRT_PRICE, false), 0);
        assertEq(
            OracleLib.poolPriceWstGbpPerXautWad(TickMath.MAX_SQRT_PRICE, false),
            340256786836388094070642339899681172762184831
        );
        assertEq(OracleLib.poolPriceWstGbpPerXautWad(TickMath.MAX_SQRT_PRICE, true), 0);
    }

    // ---------------------------------------------------------------- deviation

    function test_deviationSignsAndMagnitude() public pure {
        assertEq(OracleLib.deviationPpm(1010e18, 1000e18), 10_000, "+1% = +10000 ppm");
        assertEq(OracleLib.deviationPpm(990e18, 1000e18), -10_000, "-1% = -10000 ppm");
        assertEq(OracleLib.deviationPpm(1000e18, 1000e18), 0);
        assertEq(OracleLib.deviationPpm(0, 1000e18), -1_000_000, "empty pool saturates to -100%");
    }

    function test_deviationExtremesNoRevert() public pure {
        // Sentinel pool price over the minimum trusted fair price: huge but well inside int256.
        int256 d = OracleLib.deviationPpm(OracleLib.EXTREME_PRICE_SENTINEL, 2);
        assertGt(d, 0);
        // Max direct pool price over minimum fair.
        d = OracleLib.deviationPpm(340256786836388094070642339899681172762184831, 2);
        assertGt(d, 0);
    }

    // ---------------------------------------------------------------- fuzz totality

    function testFuzz_poolPriceAndDeviationNeverRevert(uint160 sqrtP, uint256 fairWad, bool wstGbpIsC0) public pure {
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        fairWad = bound(fairWad, 2, 1e40);
        uint256 poolWad = OracleLib.poolPriceWstGbpPerXautWad(sqrtP, wstGbpIsC0);
        OracleLib.deviationPpm(poolWad, fairWad); // must be total
    }

    function testFuzz_deviationOfSelfIsZero(uint256 x) public pure {
        x = bound(x, 2, 1e60);
        assertEq(OracleLib.deviationPpm(x, x), 0);
    }
}
