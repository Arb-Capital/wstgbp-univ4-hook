// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {OracleLib} from "../src/weth/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";

/// @dev Configurable Chainlink mock: normal answers, reverts, and short (non-decodable) returns.
contract MockAggregator {
    uint8 public constant MODE_NORMAL = 0;
    uint8 public constant MODE_REVERT = 1;
    uint8 public constant MODE_SHORT_RETURN = 2;

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

/// @notice Pure/mocked unit suite for OracleLib — no fork. Pins the composition against
///         hand-computed vectors and walks the entire failure taxonomy: nothing here may revert.
contract WethWstGbpOracleLibTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant NOW = 1_800_000_000;
    uint256 constant ETH_WINDOW = 4500;
    uint256 constant GBP_WINDOW = 90_000;
    uint256 constant Q96 = 2 ** 96;

    MockAggregator ethUsd;
    MockAggregator gbpUsd;
    MockNav wrapper;

    function setUp() public {
        vm.warp(NOW);
        ethUsd = new MockAggregator();
        gbpUsd = new MockAggregator();
        wrapper = new MockNav();
        // Healthy defaults: ETH $2500, GBP $1.25, NAV 1.05 tGBP/wstGBP.
        ethUsd.set(2500e8, NOW);
        gbpUsd.set(1.25e8, NOW);
        wrapper.set(1.05e18);
    }

    function _fair() internal view returns (uint256 fairWad, OracleLib.FallbackReason reason) {
        return OracleLib.fairPriceWad(
            IAggregatorV3(address(ethUsd)), IAggregatorV3(address(gbpUsd)), address(wrapper), ETH_WINDOW, GBP_WINDOW
        );
    }

    function _assertReason(OracleLib.FallbackReason expected) internal view {
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(expected), "reason");
        assertEq(fairWad, 0, "failed composition returns 0");
    }

    // ---------------------------------------------------------------- composition vectors

    function test_compositionHandVector1() public view {
        // (2500 / 1.25) / 1.05 = 1904.761904... — exact floor computed by hand (Python big-int).
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE));
        assertEq(fairWad, 1904761904761904761904);
    }

    function test_compositionHandVector2AwkwardPrimes() public {
        // E = $1837.65432101, G = $1.27653421, N = 1.037019382716049382:
        // floor(E·1e36 / (G·N)) = 1388175861463768858392 (≈ 1388.1758… wstGBP/WETH).
        ethUsd.set(183765432101, NOW);
        gbpUsd.set(127653421, NOW);
        wrapper.set(1037019382716049382);
        (uint256 fairWad, OracleLib.FallbackReason reason) = _fair();
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE));
        assertEq(fairWad, 1388175861463768858392);
    }

    function test_compositionParNavIsExact() public {
        wrapper.set(1e18);
        (uint256 fairWad,) = _fair();
        assertEq(fairWad, 2000e18, "2500/1.25 at par NAV");
    }

    // ---------------------------------------------------------------- staleness boundaries

    function test_stalenessBoundaryPerFeed() public {
        // Exactly at the window: fresh.
        ethUsd.set(2500e8, NOW - ETH_WINDOW);
        (, OracleLib.FallbackReason r1) = _fair();
        assertEq(uint8(r1), uint8(OracleLib.FallbackReason.NONE), "eth at window is fresh");

        // One second past: stale — and only the ETH reason fires.
        ethUsd.set(2500e8, NOW - ETH_WINDOW - 1);
        _assertReason(OracleLib.FallbackReason.ETH_FEED_STALE);

        // GBP has its own (much longer) window.
        ethUsd.set(2500e8, NOW);
        gbpUsd.set(1.25e8, NOW - GBP_WINDOW);
        (, OracleLib.FallbackReason r2) = _fair();
        assertEq(uint8(r2), uint8(OracleLib.FallbackReason.NONE), "gbp at window is fresh");
        gbpUsd.set(1.25e8, NOW - GBP_WINDOW - 1);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_STALE);

        // updatedAt in the future is stale, not fresh.
        gbpUsd.set(1.25e8, NOW + 1);
        _assertReason(OracleLib.FallbackReason.GBP_FEED_STALE);
    }

    // ---------------------------------------------------------------- failure taxonomy

    function test_ethFeedFailures() public {
        ethUsd.setMode(ethUsd.MODE_REVERT());
        _assertReason(OracleLib.FallbackReason.ETH_FEED_CALL);

        ethUsd.setMode(ethUsd.MODE_SHORT_RETURN());
        _assertReason(OracleLib.FallbackReason.ETH_FEED_CALL);

        ethUsd.set(0, NOW);
        _assertReason(OracleLib.FallbackReason.ETH_FEED_ANSWER);

        ethUsd.set(-1, NOW);
        _assertReason(OracleLib.FallbackReason.ETH_FEED_ANSWER);

        ethUsd.set(int256(uint256(1e30) + 1), NOW);
        _assertReason(OracleLib.FallbackReason.ETH_FEED_ANSWER);
    }

    function test_ethFeedNoCode() public {
        // A codeless address staticcalls "successfully" with empty returndata — must map to CALL.
        (, OracleLib.FallbackReason reason) = OracleLib.fairPriceWad(
            IAggregatorV3(makeAddr("no code")), IAggregatorV3(address(gbpUsd)), address(wrapper), ETH_WINDOW, GBP_WINDOW
        );
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.ETH_FEED_CALL));
    }

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
        // E minimal, G·N maximal floors the composition to 0 (< 2, the reserved sentinel space).
        ethUsd.set(1, NOW);
        gbpUsd.set(1e30, NOW);
        wrapper.set(1e30);
        _assertReason(OracleLib.FallbackReason.NAV_BAD);
    }

    // ---------------------------------------------------------------- pool price orientation

    function test_poolPriceAtOneIsWadBothOrientations() public pure {
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(uint160(Q96), true), 1e18);
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(uint160(Q96), false), 1e18);
    }

    function test_poolPriceOrientationInverts() public pure {
        // sqrtP = 2·2^96 ⇒ raw pool price 4: direct orientation reads 4e18, inverted reads 0.25e18.
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(uint160(2 * Q96), false), 4e18);
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(uint160(2 * Q96), true), 0.25e18);
    }

    function test_poolPriceRealisticVector() public pure {
        // Real-pair orientation (wstGBP = currency0): pool price WETH-per-wstGBP = 1/2000,
        // sqrtP = floor(2^96/sqrt(2000)) ⇒ poolWad = 1999999999999999979432 (hand-computed floor).
        uint160 sqrtP = 1771595571142957112070504448;
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(sqrtP, true), 1999999999999999979432);
    }

    function test_poolPriceExtremesAreTotal() public pure {
        // MIN squares to zero at Q96: inverted orientation hits the division guard sentinel;
        // direct orientation floors to 0. MAX: direct is ~3.4e56; inverted floors to 0.
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(TickMath.MIN_SQRT_PRICE, true), OracleLib.EXTREME_PRICE_SENTINEL);
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(TickMath.MIN_SQRT_PRICE, false), 0);
        assertEq(
            OracleLib.poolPriceWstGbpPerWethWad(TickMath.MAX_SQRT_PRICE, false),
            340256786836388094070642339899681172762184831912720469415
        );
        assertEq(OracleLib.poolPriceWstGbpPerWethWad(TickMath.MAX_SQRT_PRICE, true), 0);
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
        d = OracleLib.deviationPpm(340256786836388094070642339899681172762184831912720469415, 2);
        assertGt(d, 0);
    }

    // ---------------------------------------------------------------- fuzz totality

    function testFuzz_poolPriceAndDeviationNeverRevert(uint160 sqrtP, uint256 fairWad, bool wstGbpIsC0) public pure {
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        fairWad = bound(fairWad, 2, 1e40);
        uint256 poolWad = OracleLib.poolPriceWstGbpPerWethWad(sqrtP, wstGbpIsC0);
        OracleLib.deviationPpm(poolWad, fairWad); // must be total
    }

    function testFuzz_deviationOfSelfIsZero(uint256 x) public pure {
        x = bound(x, 2, 1e60);
        assertEq(OracleLib.deviationPpm(x, x), 0);
    }
}
