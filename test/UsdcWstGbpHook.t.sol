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

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {UsdcWstGbpForkBase} from "./base/UsdcWstGbpForkBase.sol";
import {UsdcWstGbpHook} from "../src/usdc/UsdcWstGbpHook.sol";
import {FeeMath} from "../src/usdc/lib/FeeMath.sol";
import {OracleLib} from "../src/usdc/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/usdc/interfaces/IAggregatorV3.sol";
import {DeployUsdcHook} from "../script/DeployUsdcHook.s.sol";

/// @notice Fork suite for the USDC venue: the hook against the real PoolManager, real wstGBP wrapper
///         (NAV driven via vm.store), real USDC (dealt), and a mocked-deterministic GBP/USD feed.
///         Fee ground truth is the PoolManager's own Swap event (`_swapAndObserve`).
/// @dev One transaction per test function: scenarios that need a fresh transient cache live in
///      separate tests (see the fixture NatSpec). Remember the fixture's SIGN TRAP: raising
///      GBP/USD or NAV LOWERS fair (wstGBP-per-USDC), leaving d > 0 (redeem side closes).
contract UsdcWstGbpHookTest is UsdcWstGbpForkBase {
    bytes32 constant ORACLE_FALLBACK_SIG = keccak256("OracleFallback(uint8)");

    // In the real pair wstGBP sorts below USDC: zeroForOne == wstGBP in == mint side.
    bool constant MINT_ZF1 = true;
    bool constant REDEEM_ZF1 = false;

    // ---------------------------------------------------------------- initialization guards

    function test_initializeRevertsOnStaticFee() public {
        PoolKey memory bad = key;
        bad.fee = 500; // static — the live 5bps pool's tier, pointedly
        bad.tickSpacing = 61; // distinct pool
        vm.prank(address(PM));
        vm.expectRevert(UsdcWstGbpHook.NotDynamicFee.selector);
        hook.beforeInitialize(address(this), bad, 1 << 96);

        // End-to-end through the PoolManager (revert reason arrives wrapped — assert it reverts).
        vm.expectRevert();
        PM.initialize(bad, 79228162514264337593543950336);
    }

    function test_initializeRevertsOnWrongCurrencies() public {
        (address c0, address c1) = GEM < USDC ? (GEM, USDC) : (USDC, GEM);
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(PM));
        vm.expectRevert(UsdcWstGbpHook.PoolNotSupported.selector);
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
    ///      ITS OWN slot0 deviation, while the pair-level fair price is read from the oracle exactly
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
            ModifyLiquidityParams({tickLower: anchor - 500, tickUpper: anchor + 500, liquidityDelta: 2e18, salt: 0}),
            ""
        );

        // One oracle read serves both pools' swaps in this transaction.
        vm.expectCall(GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);

        // Canonical pool at ~zero deviation: redeem side pays base only.
        SwapObservation memory first = _swapAndObserve(REDEEM_ZF1, -int256(25 * USDC_UNIT));
        assertEq(first.pmFee, 500, "canonical pool: base redeem fee at zero deviation");

        // Second pool at +2%: the same redeem side is the CLOSING flow there, and 0.5x(20000-1000)
        // saturates the 60 bps surcharge cap => exactly base + cap, robust to init rounding.
        vm.recordLogs();
        swapRouter.swap(
            second,
            SwapParams({
                zeroForOne: REDEEM_ZF1,
                amountSpecified: -int256(100 * USDC_UNIT),
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
        assertEq(address(hook.gbpUsdFeed()), GBP_USD_FEED);
        assertEq(address(hook.wrapper()), WSGEM);
        assertEq(hook.usdc(), USDC);
        assertTrue(hook.wstGbpIsCurrency0(), "wstGBP sorts below USDC");
        assertEq(Currency.unwrap(hook.currency0()), WSGEM);
        assertEq(Currency.unwrap(hook.currency1()), USDC);
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
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(UsdcWstGbpHook).creationCode, args);
        (
            address pm,
            IAggregatorV3 gbpUsd,
            address wrapper_,
            address usdc_,
            FeeMath.FeeParams memory params,
            address owner_
        ) = abi.decode(args, (address, IAggregatorV3, address, address, FeeMath.FeeParams, address));
        vm.expectRevert(expectedError);
        new UsdcWstGbpHook{salt: salt}(PM, gbpUsd, wrapper, usdc_, params, owner_);
        // silence unused warnings
        pm;
        wrapper_;
    }

    function test_constructorRejectsBadFeedDecimals() public {
        address fake = makeAddr("6dec feed");
        vm.mockCall(fake, abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(6)));
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(fake), wrapper, USDC, _defaultParams(), owner),
            UsdcWstGbpHook.BadFeedDecimals.selector
        );
    }

    function test_constructorRejectsNonSixDecimalQuote() public {
        // An 18-decimal "USDC" (any standard ERC20) must be rejected: OracleLib's USDC_UNIT is
        // compiled for 6 decimals.
        address fake = makeAddr("18dec quote");
        vm.mockCall(fake, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(GBP_USD_FEED), wrapper, fake, _defaultParams(), owner),
            UsdcWstGbpHook.BadQuoteDecimals.selector
        );
    }

    function test_constructorRejectsIdenticalCurrencies() public {
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(GBP_USD_FEED), wrapper, WSGEM, _defaultParams(), owner),
            UsdcWstGbpHook.IdenticalCurrencies.selector
        );
    }

    function test_constructorRejectsBadParams() public {
        FeeMath.FeeParams memory bad = _defaultParams();
        bad.maxFee = 200_000; // above the 10% ceiling
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(GBP_USD_FEED), wrapper, USDC, bad, owner),
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

        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(100 * USDC_UNIT)); // 100 USDC in
        assertFalse(redeem.mintSide);
        assertEq(redeem.pmFee, 500, "redeem base 5 bps");

        // Band symmetry observed on-chain.
        assertEq(mint.pmFee - redeem.pmFee, 2500, "mint = redeem + 25 bps");
    }

    function test_feeMatchesFeeMathWhenFairMovesUp() public {
        // Fair +~1% (GBP/USD DOWN 1% — the sign trap): pool now prices USDC cheap (wstGBP rich),
        // d < 0, mint side closes.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 99) / 100, block.timestamp);

        (uint24 expectedMint, int256 dBefore) = _expectedFee(MINT_ZF1);
        assertLt(dBefore, -1000, "deviation below -threshold");
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(10 * WAD));
        assertEq(mint.pmFee, expectedMint, "mint side fee == FeeMath");
        assertGt(mint.pmFee, 3000, "mint side pays surcharge");
        assertEq(mint.deviationPpm, dBefore, "hook saw the same deviation");

        // The opener (redeem side) pays base only at the *new* (post-swap) deviation.
        (uint24 expectedRedeem, int256 dAfter) = _expectedFee(REDEEM_ZF1);
        assertEq(expectedRedeem, 500, "opening flow pays base");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(25 * USDC_UNIT));
        assertEq(redeem.pmFee, 500);
        assertEq(redeem.deviationPpm, dAfter);
    }

    function test_feeMatchesFeeMathWhenFairMovesDown() public {
        // Fair -~1% (GBP/USD UP 1%): pool prices USDC rich (wstGBP cheap), d > 0, redeem side
        // closes. This is the post-NAV-ratchet conveyor geometry driven from the cable leg.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);

        (uint24 expectedRedeem, int256 dBefore) = _expectedFee(REDEEM_ZF1);
        assertGt(dBefore, 1000, "deviation above +threshold");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(250 * USDC_UNIT));
        assertEq(redeem.pmFee, expectedRedeem, "redeem side fee == FeeMath");
        assertGt(redeem.pmFee, 500, "redeem side pays surcharge");

        (uint24 expectedMint,) = _expectedFee(MINT_ZF1);
        assertEq(expectedMint, 3000, "opening flow pays base");
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 3000);
    }

    function test_surchargeCapSaturatesOnChain() public {
        // Fair +~11% (GBP/USD DOWN 10%): |d| ~ 10% >> threshold; mint-side surcharge saturates at
        // the cap.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 90) / 100, block.timestamp);
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 9000, "base 3000 + cap 6000");
    }

    function test_navDrivesDeviationToo() public {
        // NAV +2% moves fair DOWN (more tGBP per wstGBP => fewer wstGBP per USDC): d > 0. This is
        // the weekly ratchet step as the hook sees it.
        _setNav((NAV * 102) / 100);
        (uint24 expectedRedeem, int256 d) = _expectedFee(REDEEM_ZF1);
        assertGt(d, 1000);
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(250 * USDC_UNIT));
        assertEq(redeem.pmFee, expectedRedeem);
        assertGt(redeem.pmFee, 500);
    }

    function test_exactOutputChargesSameFeeSchedule() public {
        // Positive amountSpecified = exact-out; the fee override applies identically.
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, int256(10 * USDC_UNIT)); // 10 USDC out
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
        _addLiquidity(1e16);
        _addLiquidity(-1e16);
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

    function test_gbpFeedRevertFallsBack() public {
        _brickFeed(GBP_USD_FEED);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_CALL));
    }

    function test_gbpFeedZeroAnswerFallsBack() public {
        _mockFeed(GBP_USD_FEED, 0, block.timestamp);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_ANSWER));
    }

    function test_gbpFeedStaleFallsBack() public {
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp - 90_001);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_STALE));
    }

    function test_navZeroPipPausedFallsBack() public {
        _setNav(0);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.NAV_BAD));
    }

    /// @dev The staleness window lives in FeeParams, so an owner retune can flip a feed that hasn't
    ///      changed at all from fresh to stale: the next transaction's swap must fall back.
    function test_stalenessRetuneFlipsFreshFeedIntoFallback() public {
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp - 60_000); // fresh under 90_000s...
        FeeMath.FeeParams memory p = _defaultParams();
        p.gbpUsdStalenessSec = 50_000; // ...stale under the tightened window
        vm.prank(owner);
        hook.setFeeParams(p);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_STALE));
    }

    /// @dev A swap with the WHOLE oracle surface broken (feed bricked AND pip paused) completes and
    ///      emits OracleFallback with the first failure's reason.
    function test_allOraclesBrokenSwapStillCompletes() public {
        _brickFeed(GBP_USD_FEED);
        _setNav(0);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.GBP_FEED_CALL)); // first failure wins
    }

    // ---------------------------------------------------------------- production params smoke

    /// @dev The suites run at the fixture's WORKING defaults (slope 0.5x, minFee 200), not the
    ///      shipped `DeployUsdcHook.simParams()` (sim/RESULTS_USDC.md winner: slope 1.0x, minFee
    ///      50). These two tests retune the LIVE hook to the exact shipped literals (imported from
    ///      the deploy script — no duplicated constants) and pin that they are accepted by
    ///      checkParams on-chain and price correctly end-to-end. Split across two tests because
    ///      the per-transaction fair cache makes mid-test feed changes invisible (fixture NatSpec).
    function test_productionSimParamsBaseFees() public {
        FeeMath.FeeParams memory p = new DeployUsdcHook().simParams();
        vm.prank(owner);
        hook.setFeeParams(p); // reverts if the shipped literals ever fail checkParams

        // Zero deviation: both production bases charge, band symmetry intact.
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(100 * WAD));
        assertEq(mint.pmFee, p.baseFeeMintSide, "production mint base");
        assertFalse(mint.fallbackMode, "production staleness window accepts the fixture feed");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(100 * USDC_UNIT));
        assertEq(redeem.pmFee, p.baseFeeRedeemSide, "production redeem base");
        assertEq(mint.pmFee - redeem.pmFee, 2500, "band symmetry at production params");
    }

    function test_productionSimParamsSurchargeAndQuoterParity() public {
        FeeMath.FeeParams memory p = new DeployUsdcHook().simParams();
        vm.prank(owner);
        hook.setFeeParams(p);

        // Drive the post-ratchet geometry BEFORE any swap (fair caches on first read):
        // GBP +1% => fair -~1% => d ~ +10000 ppm — past threshold+cap at slope 1.0x.
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 101) / 100, block.timestamp);

        // Independent mirror at PRODUCTION params (the fixture's _expectedFee uses the working
        // defaults, so recompute here).
        (uint160 sqrtP,,,) = _slot0();
        uint256 poolWad = OracleLib.poolPriceWstGbpPerUsdcWad(sqrtP, WSGEM < USDC);
        int256 d = OracleLib.deviationPpm(poolWad, _fairWad());
        assertGt(d, int256(uint256(p.deviationThresholdPpm)), "closing regime armed");
        uint24 expected = FeeMath.swapFee(false, d, p);
        uint256 ramp = uint256(d) - p.deviationThresholdPpm; // slope 1.0x: surcharge = min(ramp, cap)
        uint256 surcharge = ramp > p.surchargeCapPpm ? p.surchargeCapPpm : ramp;
        assertEq(expected, uint24(p.baseFeeRedeemSide + surcharge), "slope-1.0x schedule shape");

        // Stock-quoter parity holds at production params, exact to the wei.
        (uint256 quotedOut,) = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: REDEEM_ZF1, exactAmount: uint128(100 * USDC_UNIT), hookData: ""
                })
            );
        SwapObservation memory close = _swapAndObserve(REDEEM_ZF1, -int256(100 * USDC_UNIT));
        assertEq(close.pmFee, expected, "production fee == independent FeeMath mirror");
        assertEq(uint256(uint128(close.amount0)), quotedOut, "quoted == executed at production params");
    }

    // ---------------------------------------------------------------- transient cache

    function test_fairPriceCachedWithinTransaction() public {
        // Exactly ONE oracle read for two swaps in the same transaction.
        vm.expectCall(GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);
        _swap(MINT_ZF1, -int256(WAD));
        _swap(REDEEM_ZF1, -int256(25 * USDC_UNIT));
    }

    function test_fallbackVerdictCachedWithinTransaction() public {
        _brickFeed(GBP_USD_FEED);
        vm.recordLogs();
        _swap(MINT_ZF1, -int256(WAD));
        _swap(REDEEM_ZF1, -int256(25 * USDC_UNIT));
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
        _mockFeed(GBP_USD_FEED, (GBP_USD_ANSWER * 90) / 100, block.timestamp); // would be a big deviation...
        SwapObservation memory second = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(second.pmFee, 3000, "...but the cached fair price still rules this tx");
    }

    // ---------------------------------------------------------------- admin

    function test_setFeeParams() public {
        FeeMath.FeeParams memory p = _defaultParams();
        p.baseFeeMintSide = 2500;
        p.baseFeeRedeemSide = 1000;
        vm.expectEmit(address(hook));
        emit UsdcWstGbpHook.FeeParamsSet(p);
        vm.prank(owner);
        hook.setFeeParams(p);

        (uint24 baseMint, uint24 baseRedeem,,,,,,,) = hook.feeParams();
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

        // No oracle call at all while paused.
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

    /// @dev Arbitrary oracle state — answer, NAV, staleness — must never block a swap.
    function testFuzz_swapNeverRevertsOnOracleState(int256 gbpAnswer, uint256 nav, uint32 age) public {
        gbpAnswer = bound(gbpAnswer, -1, int256(uint256(2e30))); // spans bad, good and absurd
        nav = bound(nav, 0, 2e30);
        age = uint32(bound(age, 0, 200_000));

        _mockFeed(GBP_USD_FEED, gbpAnswer, block.timestamp - age);
        _setNav(nav);

        _swap(MINT_ZF1, -int256(WAD)); // must not revert
        _swap(REDEEM_ZF1, -int256(25 * USDC_UNIT));
    }

    // ---------------------------------------------------------------- helpers

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
