// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {XautWstGbpForkBase} from "./base/XautWstGbpForkBase.sol";
import {XautWstGbpHook} from "../src/xaut/XautWstGbpHook.sol";
import {FeeMath} from "../src/xaut/lib/FeeMath.sol";
import {OracleLib} from "../src/xaut/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/xaut/interfaces/IAggregatorV3.sol";
import {DeployXautHook} from "../script/DeployXautHook.s.sol";

/// @notice Fork suite for the XAUT venue: the hook against the real PoolManager, real wstGBP wrapper
///         (NAV driven via vm.store), real XAUT (dealt), and mocked-deterministic XAU/USD + GBP/USD
///         feeds. Fee ground truth is the PoolManager's own Swap event (`_swapAndObserve`).
/// @dev One transaction per test function: scenarios that need a fresh transient cache live in
///      separate tests (see the fixture NatSpec). Remember the fixture's TWO SIGN TRAPS
///      (fair = x/(g·nav), wstGBP-per-XAUT): raising XAU/USD RAISES fair, leaving d < 0 (mint side
///      closes — the gold-rally direction); raising GBP/USD or NAV LOWERS fair, leaving d > 0
///      (redeem side closes — the conveyor direction, same trap as the USDC venue). AMOUNT SCALE:
///      one XAUT is ~$2,625, so XAUT-side amounts run ~2000x smaller in token count than the USDC
///      suite's (`XAUT_UNIT / 20` ≈ $131 stands in for its 100 USDC); wstGBP-side WAD amounts carry
///      over unchanged.
contract XautWstGbpHookTest is XautWstGbpForkBase {
    bytes32 constant ORACLE_FALLBACK_SIG = keccak256("OracleFallback(uint8)");

    // In the real pair wstGBP sorts below XAUT: zeroForOne == wstGBP in == mint side.
    bool constant MINT_ZF1 = true;
    bool constant REDEEM_ZF1 = false;

    // ---------------------------------------------------------------- initialization guards

    function test_initializeRevertsOnStaticFee() public {
        PoolKey memory bad = key;
        bad.fee = 3000; // static
        bad.tickSpacing = 61; // distinct pool
        vm.prank(address(PM));
        vm.expectRevert(XautWstGbpHook.NotDynamicFee.selector);
        hook.beforeInitialize(address(this), bad, 1 << 96);

        // End-to-end through the PoolManager (revert reason arrives wrapped — assert it reverts).
        vm.expectRevert();
        PM.initialize(bad, 79228162514264337593543950336);
    }

    function test_initializeRevertsOnWrongCurrencies() public {
        (address c0, address c1) = GEM < XAUT ? (GEM, XAUT) : (XAUT, GEM);
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(PM));
        vm.expectRevert(XautWstGbpHook.PoolNotSupported.selector);
        hook.beforeInitialize(address(this), bad, 1 << 96);

        vm.expectRevert();
        PM.initialize(bad, 79228162514264337593543950336);
    }

    function test_secondPoolWithDifferentTickSpacingAllowed() public {
        // Fee logic is per-poolId; the pair-level fair price is shared correctly across keys.
        PoolKey memory second = key;
        second.tickSpacing = 10;
        PM.initialize(second, _fairSqrtPriceX96(_fairWad()));
    }

    /// @dev Two LIVE pools under the one hook, swapped in the same transaction: each swap prices off
    ///      ITS OWN slot0 deviation, while the pair-level fair price is read from the oracles exactly
    ///      once and shared across poolIds (the NatSpec claim `_beforeInitialize` rests on).
    function test_twoLivePoolsPriceTheirOwnDeviation() public {
        // Second pool: tickSpacing 10, initialized 2% ABOVE fair (d ≈ +20_000 ppm), thin LP.
        PoolKey memory second = key;
        second.tickSpacing = 10;
        uint160 sqrtSecond = _fairSqrtPriceX96(_fairWad() * 102 / 100);
        PM.initialize(second, sqrtSecond);
        int24 anchor = TickMath.getTickAtSqrtPrice(sqrtSecond) / 10 * 10;
        lpRouter.modifyLiquidity(
            second,
            ModifyLiquidityParams({tickLower: anchor - 500, tickUpper: anchor + 500, liquidityDelta: 2e15, salt: 0}),
            ""
        );

        // One oracle read (per feed) serves both pools' swaps in this transaction.
        vm.expectCall(XAU_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);
        vm.expectCall(GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);

        // Canonical pool at ~zero deviation: redeem side pays base only.
        SwapObservation memory first = _swapAndObserve(REDEEM_ZF1, -int256(XAUT_UNIT / 100));
        assertEq(first.pmFee, 500, "canonical pool: base redeem fee at zero deviation");

        // Second pool at +2%: the same redeem side is the CLOSING flow there, and 0.5x(20000-1000)
        // saturates the 60 bps surcharge cap => exactly base + cap, robust to init rounding.
        vm.recordLogs();
        swapRouter.swap(
            second,
            SwapParams({
                zeroForOne: REDEEM_ZF1,
                amountSpecified: -int256(XAUT_UNIT / 20),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSecondSwapFee;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != HOOK_SWAPFEE_SIG) continue;
            (uint24 fee, int256 d, bool fallbackMode) = abi.decode(logs[i].data, (uint24, int256, bool));
            assertEq(fee, 500 + 6000, "second pool: base + saturated surcharge off ITS deviation");
            assertGt(d, 19_000, "second pool's own deviation observed");
            assertFalse(fallbackMode, "live pricing");
            sawSecondSwapFee = true;
        }
        assertTrue(sawSecondSwapFee, "second pool swap priced by the hook");
    }

    function test_constructorState() public view {
        assertEq(address(hook.xauUsdFeed()), XAU_USD_FEED);
        assertEq(address(hook.gbpUsdFeed()), GBP_USD_FEED);
        assertEq(address(hook.wrapper()), WSGEM);
        assertEq(hook.xaut(), XAUT);
        assertTrue(hook.wstGbpIsCurrency0(), "wstGBP sorts below XAUT");
        assertEq(Currency.unwrap(hook.currency0()), WSGEM);
        assertEq(Currency.unwrap(hook.currency1()), XAUT);
        assertEq(hook.owner(), owner);
        assertFalse(hook.paused());
        // Exact permission bits — no strays (a stray return-delta bit would break quotability).
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            "exact flag bits"
        );
    }

    // ---------------------------------------------------------------- constructor guards

    function _deployWithArgs(bytes memory args, bytes4 expectedError) internal {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(XautWstGbpHook).creationCode, args);
        (
            address pm,
            IAggregatorV3 xauUsd,
            IAggregatorV3 gbpUsd,
            address wrapper_,
            address xaut_,
            FeeMath.FeeParams memory params,
            address owner_
        ) = abi.decode(args, (address, IAggregatorV3, IAggregatorV3, address, address, FeeMath.FeeParams, address));
        vm.expectRevert(expectedError);
        new XautWstGbpHook{salt: salt}(PM, xauUsd, gbpUsd, wrapper, xaut_, params, owner_);
        // silence unused warnings
        pm;
        wrapper_;
    }

    function test_constructorRejectsBadXauFeedDecimals() public {
        address fake = makeAddr("6dec xau feed");
        vm.mockCall(fake, abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(6)));
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(fake), IAggregatorV3(GBP_USD_FEED), wrapper, XAUT, _defaultParams(), owner),
            XautWstGbpHook.BadFeedDecimals.selector
        );
    }

    function test_constructorRejectsBadGbpFeedDecimals() public {
        // EITHER feed off the 8-dec scale must be rejected — the composition cancels the scales only
        // when they match.
        address fake = makeAddr("6dec gbp feed");
        vm.mockCall(fake, abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(6)));
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(XAU_USD_FEED), IAggregatorV3(fake), wrapper, XAUT, _defaultParams(), owner),
            XautWstGbpHook.BadFeedDecimals.selector
        );
    }

    function test_constructorRejectsNonSixDecimalQuote() public {
        // An 18-decimal "XAUT" (any standard ERC20) must be rejected: OracleLib's XAUT_UNIT is
        // compiled for 6 decimals.
        address fake = makeAddr("18dec quote");
        vm.mockCall(fake, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        _deployWithArgs(
            abi.encode(
                PM, IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, fake, _defaultParams(), owner
            ),
            XautWstGbpHook.BadQuoteDecimals.selector
        );
    }

    function test_constructorRejectsIdenticalCurrencies() public {
        _deployWithArgs(
            abi.encode(
                PM, IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, WSGEM, _defaultParams(), owner
            ),
            XautWstGbpHook.IdenticalCurrencies.selector
        );
    }

    function test_constructorRejectsBadParams() public {
        FeeMath.FeeParams memory bad = _defaultParams();
        bad.maxFee = 200_000; // above the 10% ceiling
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, XAUT, bad, owner),
            FeeMath.FeeParamsOutOfBounds.selector
        );
    }

    // ---------------------------------------------------------------- fee correctness

    function test_baseFeesAtZeroDeviation() public {
        // Pool sits at oracle fair (init) — inside the threshold band, both sides pay base only.
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(100 * WAD)); // 100 wstGBP in
        assertTrue(mint.mintSide);
        assertEq(mint.pmFee, 3000, "mint base 30 bps");
        assertFalse(mint.fallbackMode);
        assertLt(_abs(mint.deviationPpm), 1000, "inside band");

        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(XAUT_UNIT / 20)); // 0.05 XAUT in
        assertFalse(redeem.mintSide);
        assertEq(redeem.pmFee, 500, "redeem base 5 bps");

        // Band symmetry observed on-chain.
        assertEq(mint.pmFee - redeem.pmFee, 2500, "mint = redeem + 25 bps");
    }

    function test_feeMatchesFeeMathWhenFairMovesUp() public {
        // Fair +1% (XAU/USD UP 1% — the gold-rally leg): pool now prices XAUT cheap (wstGBP rich),
        // d < 0, mint side closes.
        _mockFeed(XAU_USD_FEED, (XAU_USD_ANSWER * 101) / 100, block.timestamp);

        (uint24 expectedMint, int256 dBefore) = _expectedFee(MINT_ZF1);
        assertLt(dBefore, -1000, "deviation below -threshold");
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(10 * WAD));
        assertEq(mint.pmFee, expectedMint, "mint side fee == FeeMath");
        assertGt(mint.pmFee, 3000, "mint side pays surcharge");
        assertEq(mint.deviationPpm, dBefore, "hook saw the same deviation");

        // The opener (redeem side) pays base only at the *new* (post-swap) deviation.
        (uint24 expectedRedeem, int256 dAfter) = _expectedFee(REDEEM_ZF1);
        assertEq(expectedRedeem, 500, "opening flow pays base");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(XAUT_UNIT / 100));
        assertEq(redeem.pmFee, 500);
        assertEq(redeem.deviationPpm, dAfter);
    }

    function test_feeMatchesFeeMathWhenFairMovesDown() public {
        // Fair -~1% (GBP/USD UP 1% — the sign trap): pool prices XAUT rich (wstGBP cheap), d > 0,
        // redeem side closes. This is the post-NAV-ratchet conveyor geometry driven from the cable
        // leg, same trap as the USDC venue.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);

        (uint24 expectedRedeem, int256 dBefore) = _expectedFee(REDEEM_ZF1);
        assertGt(dBefore, 1000, "deviation above +threshold");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(XAUT_UNIT / 8));
        assertEq(redeem.pmFee, expectedRedeem, "redeem side fee == FeeMath");
        assertGt(redeem.pmFee, 500, "redeem side pays surcharge");

        (uint24 expectedMint,) = _expectedFee(MINT_ZF1);
        assertEq(expectedMint, 3000, "opening flow pays base");
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 3000);
    }

    function test_surchargeCapSaturatesOnChain() public {
        // Fair +10% (a gold flash rally): |d| ~ 9.1% >> threshold; mint-side surcharge saturates at
        // the cap.
        _mockFeed(XAU_USD_FEED, (XAU_USD_ANSWER * 110) / 100, block.timestamp);
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 9000, "base 3000 + cap 6000");
    }

    function test_navDrivesDeviationToo() public {
        // NAV +2% moves fair DOWN (more tGBP per wstGBP => fewer wstGBP per XAUT): d > 0. This is
        // the weekly ratchet step as the hook sees it.
        _setNav((NAV * 102) / 100);
        (uint24 expectedRedeem, int256 d) = _expectedFee(REDEEM_ZF1);
        assertGt(d, 1000);
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(XAUT_UNIT / 8));
        assertEq(redeem.pmFee, expectedRedeem);
        assertGt(redeem.pmFee, 500);
    }

    function test_exactOutputChargesSameFeeSchedule() public {
        // Positive amountSpecified = exact-out; the fee override applies identically.
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, int256(XAUT_UNIT / 250)); // 0.004 XAUT out
        assertTrue(mint.mintSide);
        assertEq(mint.pmFee, 3000);
    }

    function test_slot0LpFeeStaysZero() public {
        // The override fee is per-swap and never written to slot0 — document the observation trap.
        _swapAndObserve(MINT_ZF1, -int256(WAD));
        (,,, uint24 lpFee) = _slot0();
        assertEq(lpFee, 0, "slot0 lpFee is not the charged fee");
    }

    function test_thirdPartyLpAllowed() public {
        // Real AMM pool: anyone may LP (unlike the backstop hook).
        _addLiquidity(1e13);
        _addLiquidity(-1e13);
    }

    // ---------------------------------------------------------------- oracle failure matrix

    function _assertFallbackSwap(uint8 expectedReason) internal {
        vm.recordLogs();
        _swap(MINT_ZF1, -int256(WAD));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawFallback;
        bool sawSwapFee;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == ORACLE_FALLBACK_SIG) {
                assertEq(abi.decode(logs[i].data, (uint8)), expectedReason, "fallback reason");
                sawFallback = true;
            } else if (logs[i].topics[0] == HOOK_SWAPFEE_SIG) {
                (uint24 fee, int256 d, bool fallbackMode) = abi.decode(logs[i].data, (uint24, int256, bool));
                assertEq(fee, 3000, "fallbackFee");
                assertEq(d, 0, "no deviation in fallback");
                assertTrue(fallbackMode, "fallbackMode flagged");
                sawSwapFee = true;
            }
        }
        assertTrue(sawFallback, "OracleFallback emitted");
        assertTrue(sawSwapFee, "swap completed with SwapFee");
    }

    // --- XAU/USD feed failures (reasons 1..3), GBP/USD healthy throughout ---

    function test_xauFeedRevertFallsBack() public {
        _brickFeed(XAU_USD_FEED);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_CALL));
    }

    function test_xauFeedShortReturndataFallsBack() public {
        // One word back (< 160 bytes) — decode-impossible, classified as a call failure.
        vm.mockCall(
            XAU_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint256(1))
        );
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_CALL));
    }

    function test_xauFeedZeroAnswerFallsBack() public {
        _mockFeed(XAU_USD_FEED, 0, block.timestamp);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_ANSWER));
    }

    function test_xauFeedNegativeAnswerFallsBack() public {
        _mockFeed(XAU_USD_FEED, -1, block.timestamp);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_ANSWER));
    }

    function test_xauFeedAbsurdAnswerFallsBack() public {
        _mockFeed(XAU_USD_FEED, int256(1e31), block.timestamp); // > MAX_ANSWER
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_ANSWER));
    }

    function test_xauFeedStaleFallsBack() public {
        _mockFeed(XAU_USD_FEED, XAU_USD_ANSWER, block.timestamp - 90_001);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_STALE));
    }

    function test_xauFeedFutureTimestampFallsBack() public {
        // updatedAt in the future is stale, not fresh.
        _mockFeed(XAU_USD_FEED, XAU_USD_ANSWER, block.timestamp + 3600);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_STALE));
    }

    // --- GBP/USD feed failures (reasons 4..6), XAU/USD healthy throughout ---

    function test_gbpFeedRevertFallsBack() public {
        _brickFeed(GBP_USD_FEED);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_CALL));
    }

    function test_gbpFeedShortReturndataFallsBack() public {
        vm.mockCall(
            GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint256(1))
        );
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_CALL));
    }

    function test_gbpFeedZeroAnswerFallsBack() public {
        _mockFeed(GBP_USD_FEED, 0, block.timestamp);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_ANSWER));
    }

    function test_gbpFeedNegativeAnswerFallsBack() public {
        _mockFeed(GBP_USD_FEED, -1, block.timestamp);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_ANSWER));
    }

    function test_gbpFeedAbsurdAnswerFallsBack() public {
        _mockFeed(GBP_USD_FEED, int256(1e31), block.timestamp); // > MAX_ANSWER
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_ANSWER));
    }

    function test_gbpFeedStaleFallsBack() public {
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp - 90_001);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_STALE));
    }

    function test_gbpFeedFutureTimestampFallsBack() public {
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp + 3600);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_STALE));
    }

    // --- precedence, NAV, retunes ---

    /// @dev The XAU/USD feed is read FIRST, so when both feeds are broken the XAU reason wins.
    function test_bothFeedsBrokenXauReasonWins() public {
        _brickFeed(XAU_USD_FEED);
        _brickFeed(GBP_USD_FEED);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_CALL));
    }

    function test_navZeroPipPausedFallsBack() public {
        _setNav(0);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.NAV_BAD));
    }

    /// @dev The staleness windows live in FeeParams, so an owner retune can flip a feed that hasn't
    ///      changed at all from fresh to stale: the next transaction's swap must fall back. XAU
    ///      variant — exercises the 10-field struct's NEW ninth field end-to-end.
    function test_xauStalenessRetuneFlipsFreshFeedIntoFallback() public {
        _mockFeed(XAU_USD_FEED, XAU_USD_ANSWER, block.timestamp - 60_000); // fresh under 90_000s...
        FeeMath.FeeParams memory p = _defaultParams();
        p.xauUsdStalenessSec = 50_000; // ...stale under the tightened window
        vm.prank(owner);
        hook.setFeeParams(p);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_STALE));
    }

    function test_gbpStalenessRetuneFlipsFreshFeedIntoFallback() public {
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp - 60_000); // fresh under 90_000s...
        FeeMath.FeeParams memory p = _defaultParams();
        p.gbpUsdStalenessSec = 50_000; // ...stale under the tightened window
        vm.prank(owner);
        hook.setFeeParams(p);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_STALE));
    }

    /// @dev A swap with the WHOLE oracle surface broken (both feeds bricked AND pip paused)
    ///      completes and emits OracleFallback with the first failure's reason.
    function test_allOraclesBrokenSwapStillCompletes() public {
        _brickFeed(XAU_USD_FEED);
        _brickFeed(GBP_USD_FEED);
        _setNav(0);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.XAU_FEED_CALL)); // first failure wins
    }

    // ---------------------------------------------------------------- production params smoke

    /// @dev The suites run at the fixture's WORKING defaults; `DeployXautHook.simParams()` is the
    ///      goldsim sweep winner (sim/RESULTS_XAUT.md, 2026-07-16). This test retunes the
    ///      LIVE hook to the shipped literals (imported from the deploy script — no duplicated
    ///      constants) and pins only VALUE-GENERIC properties — checkParams accepts them on-chain,
    ///      both directional bases charge at ~zero deviation, and the production staleness windows
    ///      accept the fixture's fresh feeds — so re-stamping the params after any re-sweep cannot
    ///      churn this test.
    function test_productionSimParamsBaseFees() public {
        FeeMath.FeeParams memory p = new DeployXautHook().simParams();
        vm.prank(owner);
        hook.setFeeParams(p); // reverts if the shipped literals ever fail checkParams

        // Zero deviation: both production bases charge, live-priced (no fallback).
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(100 * WAD));
        assertEq(mint.pmFee, p.baseFeeMintSide, "production mint base");
        assertFalse(mint.fallbackMode, "production staleness windows accept the fixture feeds");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(XAUT_UNIT / 20));
        assertEq(redeem.pmFee, p.baseFeeRedeemSide, "production redeem base");
        assertFalse(redeem.fallbackMode, "live pricing on the redeem side too");
    }

    // ---------------------------------------------------------------- transient cache

    function test_fairPriceCachedWithinTransaction() public {
        // Exactly ONE read per feed for two swaps in the same transaction.
        vm.expectCall(XAU_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);
        vm.expectCall(GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);
        _swap(MINT_ZF1, -int256(WAD));
        _swap(REDEEM_ZF1, -int256(XAUT_UNIT / 100));
    }

    function test_fallbackVerdictCachedWithinTransaction() public {
        _brickFeed(XAU_USD_FEED);
        vm.recordLogs();
        _swap(MINT_ZF1, -int256(WAD));
        _swap(REDEEM_ZF1, -int256(XAUT_UNIT / 100));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fallbackEvents;
        uint256 swapFeeEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == ORACLE_FALLBACK_SIG) fallbackEvents++;
            if (logs[i].topics[0] == HOOK_SWAPFEE_SIG) swapFeeEvents++;
        }
        assertEq(fallbackEvents, 1, "OracleFallback emitted once per tx");
        assertEq(swapFeeEvents, 2, "both swaps completed");
    }

    function test_oracleChangeMidTransactionInvisible() public {
        // By-design intra-tx stickiness: the fair price read by swap 1 serves swap 2 even though the
        // feed moved in between (a real bundle sees the same).
        SwapObservation memory first = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(first.pmFee, 3000);
        _mockFeed(XAU_USD_FEED, (XAU_USD_ANSWER * 110) / 100, block.timestamp); // would be a big deviation...
        SwapObservation memory second = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(second.pmFee, 3000, "...but the cached fair price still rules this tx");
    }

    // ---------------------------------------------------------------- admin

    function test_setFeeParams() public {
        FeeMath.FeeParams memory p = _defaultParams();
        p.baseFeeMintSide = 2500;
        p.baseFeeRedeemSide = 1000;
        vm.expectEmit(address(hook));
        emit XautWstGbpHook.FeeParamsSet(p);
        vm.prank(owner);
        hook.setFeeParams(p);

        (uint24 baseMint, uint24 baseRedeem,,,,,,,,) = hook.feeParams();
        assertEq(baseMint, 2500);
        assertEq(baseRedeem, 1000);

        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 2500, "new base applies to the next swap");
    }

    function test_setFeeParamsRejectsOutOfBounds() public {
        FeeMath.FeeParams memory p = _defaultParams();
        p.minFee = 0;
        vm.prank(owner);
        vm.expectRevert(FeeMath.FeeParamsOutOfBounds.selector);
        hook.setFeeParams(p);

        // The 10-field struct's two staleness windows are each independently required nonzero.
        p = _defaultParams();
        p.xauUsdStalenessSec = 0;
        vm.prank(owner);
        vm.expectRevert(FeeMath.FeeParamsOutOfBounds.selector);
        hook.setFeeParams(p);

        p = _defaultParams();
        p.gbpUsdStalenessSec = 0;
        vm.prank(owner);
        vm.expectRevert(FeeMath.FeeParamsOutOfBounds.selector);
        hook.setFeeParams(p);
    }

    function test_adminOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setFeeParams(_defaultParams());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPaused(true);
    }

    function test_pauseForcesFallbackFeeAndSkipsOracle() public {
        vm.prank(owner);
        hook.setPaused(true);
        assertTrue(hook.paused());

        // No oracle call at all while paused — neither feed.
        vm.expectCall(XAU_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 0);
        vm.expectCall(GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 0);
        _assertFallbackSwap(hook.REASON_PAUSED());
    }

    function test_unpauseRestoresPricing() public {
        vm.prank(owner);
        hook.setPaused(true);
        vm.prank(owner);
        hook.setPaused(false);
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 3000);
        assertFalse(mint.fallbackMode);
    }

    function test_twoStepOwnershipTransfer() public {
        address newOwner = makeAddr("new owner");
        vm.prank(owner);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), owner, "unchanged until accepted");
        assertEq(hook.pendingOwner(), newOwner);

        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.setPaused(true);
    }

    // ---------------------------------------------------------------- never-revert fuzz

    /// @dev Arbitrary oracle state — both answers, NAV, both feeds' staleness — must never block a
    ///      swap.
    function testFuzz_swapNeverRevertsOnOracleState(
        int256 xauAnswer,
        int256 gbpAnswer,
        uint256 nav,
        uint32 xauAge,
        uint32 gbpAge
    ) public {
        xauAnswer = bound(xauAnswer, -1, int256(uint256(2e30))); // spans bad, good and absurd
        gbpAnswer = bound(gbpAnswer, -1, int256(uint256(2e30)));
        nav = bound(nav, 0, 2e30);
        xauAge = uint32(bound(xauAge, 0, 200_000));
        gbpAge = uint32(bound(gbpAge, 0, 200_000));

        _mockFeed(XAU_USD_FEED, xauAnswer, block.timestamp - xauAge);
        _mockFeed(GBP_USD_FEED, gbpAnswer, block.timestamp - gbpAge);
        _setNav(nav);

        _swap(MINT_ZF1, -int256(WAD)); // must not revert
        _swap(REDEEM_ZF1, -int256(XAUT_UNIT / 100));
    }

    // ---------------------------------------------------------------- helpers

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
