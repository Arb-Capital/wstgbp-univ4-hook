// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {WethWstGbpForkBase} from "./base/WethWstGbpForkBase.sol";
import {WethWstGbpHook} from "../src/weth/WethWstGbpHook.sol";
import {FeeMath} from "../src/weth/lib/FeeMath.sol";
import {OracleLib} from "../src/weth/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";

/// @notice Phase 2 fork suite: the hook against the real PoolManager, real wstGBP wrapper (NAV driven
///         via vm.store), and mocked-deterministic Chainlink feeds. Fee ground truth is the
///         PoolManager's own Swap event (`_swapAndObserve`).
/// @dev One transaction per test function: scenarios that need a fresh transient cache live in
///      separate tests (see the fixture NatSpec).
contract WethWstGbpHookTest is WethWstGbpForkBase {
    bytes32 constant ORACLE_FALLBACK_SIG = keccak256("OracleFallback(uint8)");

    // In the real pair wstGBP sorts below WETH: zeroForOne == wstGBP in == mint side.
    bool constant MINT_ZF1 = true;
    bool constant REDEEM_ZF1 = false;

    // ---------------------------------------------------------------- initialization guards

    function test_initializeRevertsOnStaticFee() public {
        PoolKey memory bad = key;
        bad.fee = 3000; // static
        bad.tickSpacing = 61; // distinct pool
        vm.prank(address(PM));
        vm.expectRevert(WethWstGbpHook.NotDynamicFee.selector);
        hook.beforeInitialize(address(this), bad, 1 << 96);

        // End-to-end through the PoolManager (revert reason arrives wrapped — assert it reverts).
        vm.expectRevert();
        PM.initialize(bad, 79228162514264337593543950336);
    }

    function test_initializeRevertsOnWrongCurrencies() public {
        (address c0, address c1) = GEM < WETH ? (GEM, WETH) : (WETH, GEM);
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(PM));
        vm.expectRevert(WethWstGbpHook.PoolNotSupported.selector);
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

    function test_constructorState() public view {
        assertEq(address(hook.ethUsdFeed()), ETH_USD_FEED);
        assertEq(address(hook.gbpUsdFeed()), GBP_USD_FEED);
        assertEq(address(hook.wrapper()), WSGEM);
        assertEq(hook.weth(), WETH);
        assertTrue(hook.wstGbpIsCurrency0(), "wstGBP sorts below WETH");
        assertEq(Currency.unwrap(hook.currency0()), WSGEM);
        assertEq(Currency.unwrap(hook.currency1()), WETH);
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
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(WethWstGbpHook).creationCode, args);
        (
            address pm,
            IAggregatorV3 ethUsd,
            IAggregatorV3 gbpUsd,
            address wrapper_,
            address weth_,
            FeeMath.FeeParams memory params,
            address owner_
        ) = abi.decode(args, (address, IAggregatorV3, IAggregatorV3, address, address, FeeMath.FeeParams, address));
        vm.expectRevert(expectedError);
        new WethWstGbpHook{salt: salt}(PM, ethUsd, gbpUsd, wrapper, weth_, params, owner_);
        // silence unused warnings
        pm;
        wrapper_;
    }

    function test_constructorRejectsBadFeedDecimals() public {
        address fake = makeAddr("6dec feed");
        vm.mockCall(fake, abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(6)));
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(fake), IAggregatorV3(GBP_USD_FEED), wrapper, WETH, _defaultParams(), owner),
            WethWstGbpHook.BadFeedDecimals.selector
        );
    }

    function test_constructorRejectsIdenticalCurrencies() public {
        _deployWithArgs(
            abi.encode(
                PM, IAggregatorV3(ETH_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, WSGEM, _defaultParams(), owner
            ),
            WethWstGbpHook.IdenticalCurrencies.selector
        );
    }

    function test_constructorRejectsBadParams() public {
        FeeMath.FeeParams memory bad = _defaultParams();
        bad.maxFee = 200_000; // above the 10% ceiling
        _deployWithArgs(
            abi.encode(PM, IAggregatorV3(ETH_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, WETH, bad, owner),
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

        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(WAD / 20)); // 0.05 WETH in
        assertFalse(redeem.mintSide);
        assertEq(redeem.pmFee, 500, "redeem base 5 bps");

        // Band symmetry observed on-chain.
        assertEq(mint.pmFee - redeem.pmFee, 2500, "mint = redeem + 25 bps");
    }

    function test_feeMatchesFeeMathWhenFairMovesUp() public {
        // Fair +1% (ETH/USD up): pool now prices WETH cheap, d < 0, mint side closes.
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 101) / 100, block.timestamp);

        (uint24 expectedMint, int256 dBefore) = _expectedFee(MINT_ZF1);
        assertLt(dBefore, -1000, "deviation below -threshold");
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(10 * WAD));
        assertEq(mint.pmFee, expectedMint, "mint side fee == FeeMath");
        assertGt(mint.pmFee, 3000, "mint side pays surcharge");
        assertEq(mint.deviationPpm, dBefore, "hook saw the same deviation");

        // The opener (redeem side) pays base only at the *new* (post-swap) deviation.
        (uint24 expectedRedeem, int256 dAfter) = _expectedFee(REDEEM_ZF1);
        assertEq(expectedRedeem, 500, "opening flow pays base");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(WAD / 100));
        assertEq(redeem.pmFee, 500);
        assertEq(redeem.deviationPpm, dAfter);
    }

    function test_feeMatchesFeeMathWhenFairMovesDown() public {
        // Fair -1% (ETH/USD down): pool prices WETH rich, d > 0, redeem side closes.
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 99) / 100, block.timestamp);

        (uint24 expectedRedeem, int256 dBefore) = _expectedFee(REDEEM_ZF1);
        assertGt(dBefore, 1000, "deviation above +threshold");
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(WAD / 10));
        assertEq(redeem.pmFee, expectedRedeem, "redeem side fee == FeeMath");
        assertGt(redeem.pmFee, 500, "redeem side pays surcharge");

        (uint24 expectedMint,) = _expectedFee(MINT_ZF1);
        assertEq(expectedMint, 3000, "opening flow pays base");
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 3000);
    }

    function test_surchargeCapSaturatesOnChain() public {
        // Fair +10%: |d| ~ 9.1% >> threshold; mint-side surcharge saturates at the cap.
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 110) / 100, block.timestamp);
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(mint.pmFee, 9000, "base 3000 + cap 6000");
    }

    function test_navDrivesDeviationToo() public {
        // NAV +2% moves fair DOWN (more tGBP per wstGBP => fewer wstGBP per WETH): d > 0.
        _setNav((NAV * 102) / 100);
        (uint24 expectedRedeem, int256 d) = _expectedFee(REDEEM_ZF1);
        assertGt(d, 1000);
        SwapObservation memory redeem = _swapAndObserve(REDEEM_ZF1, -int256(WAD / 10));
        assertEq(redeem.pmFee, expectedRedeem);
        assertGt(redeem.pmFee, 500);
    }

    function test_exactOutputChargesSameFeeSchedule() public {
        // Positive amountSpecified = exact-out; the fee override applies identically.
        SwapObservation memory mint = _swapAndObserve(MINT_ZF1, int256(WAD / 100)); // 0.01 WETH out
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
        _addLiquidity(1e20);
        _addLiquidity(-1e20);
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

    function test_ethFeedRevertFallsBack() public {
        _brickFeed(ETH_USD_FEED);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.ETH_FEED_CALL));
    }

    function test_ethFeedStaleFallsBack() public {
        _mockFeed(ETH_USD_FEED, ETH_USD_ANSWER, block.timestamp - 4501);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.ETH_FEED_STALE));
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

    /// @dev Phase 2 acceptance: a swap with BOTH oracles bricked completes and emits OracleFallback.
    function test_bothFeedsBrickedSwapStillCompletes() public {
        _brickFeed(ETH_USD_FEED);
        _brickFeed(GBP_USD_FEED);
        _setNav(0);
        _assertFallbackSwap(uint8(OracleLib.FallbackReason.ETH_FEED_CALL)); // first failure wins
    }

    // ---------------------------------------------------------------- transient cache

    function test_fairPriceCachedWithinTransaction() public {
        // Exactly ONE oracle read for two swaps in the same transaction.
        vm.expectCall(ETH_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);
        vm.expectCall(GBP_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 1);
        _swap(MINT_ZF1, -int256(WAD));
        _swap(REDEEM_ZF1, -int256(WAD / 100));
    }

    function test_fallbackVerdictCachedWithinTransaction() public {
        _brickFeed(ETH_USD_FEED);
        vm.recordLogs();
        _swap(MINT_ZF1, -int256(WAD));
        _swap(REDEEM_ZF1, -int256(WAD / 100));
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
        _mockFeed(ETH_USD_FEED, (ETH_USD_ANSWER * 110) / 100, block.timestamp); // would be a big deviation...
        SwapObservation memory second = _swapAndObserve(MINT_ZF1, -int256(WAD));
        assertEq(second.pmFee, 3000, "...but the cached fair price still rules this tx");
    }

    // ---------------------------------------------------------------- admin

    function test_setFeeParams() public {
        FeeMath.FeeParams memory p = _defaultParams();
        p.baseFeeMintSide = 2500;
        p.baseFeeRedeemSide = 1000;
        vm.expectEmit(address(hook));
        emit WethWstGbpHook.FeeParamsSet(p);
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
        vm.expectCall(ETH_USD_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), 0);
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

    /// @dev Arbitrary oracle state — answers, NAV, staleness — must never block a swap.
    function testFuzz_swapNeverRevertsOnOracleState(int256 ethAnswer, int256 gbpAnswer, uint256 nav, uint32 age)
        public
    {
        ethAnswer = bound(ethAnswer, -1, int256(uint256(2e30))); // spans bad, good and absurd
        gbpAnswer = bound(gbpAnswer, -1, int256(uint256(2e30)));
        nav = bound(nav, 0, 2e30);
        age = uint32(bound(age, 0, 200_000));

        _mockFeed(ETH_USD_FEED, ethAnswer, block.timestamp - age);
        _mockFeed(GBP_USD_FEED, gbpAnswer, block.timestamp);
        _setNav(nav);

        _swap(MINT_ZF1, -int256(WAD)); // must not revert
        _swap(REDEEM_ZF1, -int256(WAD / 100));
    }

    // ---------------------------------------------------------------- helpers

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
