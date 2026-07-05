// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {UsdcWstGbpForkBase} from "./base/UsdcWstGbpForkBase.sol";
import {SettableFeed} from "./base/SettableFeed.sol";
import {UsdcWstGbpHook} from "../src/usdc/UsdcWstGbpHook.sol";
import {FeeMath} from "../src/usdc/lib/FeeMath.sol";
import {OracleLib} from "../src/usdc/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/usdc/interfaces/IAggregatorV3.sol";

/// @notice Stateful (invariant) suite for the wstGBP/USDC dynamic-fee hook. A `UsdcHookHandler`
///         drives long randomly-interleaved sequences of swaps (all four modes + deviation-closing
///         arb), third-party LP add/remove, oracle drift/breakage/healing on both legs (GBP/USD feed
///         + NAV), time warps, pause toggles, and owner fee-retunes, and the invariants assert the
///         cross-sequence properties the stateless suites can't reach:
///
///         1. Every executed swap's fee (PM `Swap` event ground truth) equals an independent
///            FeeMath/OracleLib recomputation from the same pre-swap state — under ANY interleaving
///            of oracle state, params, pause, and pool price.
///         2. The fee always lands in the `[minFee, maxFee]` of the params active at swap time.
///         3. The STOCK v4 Quoter matches execution to the wei on every swap (the venue's key
///            router-quotability property), and never fails while the swap itself succeeds.
///         4. Funding-pre-validated swaps NEVER revert, whatever the oracle state (never-brick).
///         5. Fallback-regime correctness: `fallbackMode` swaps pay exactly `fallbackFee`; a swap is
///            never priced "live" while the oracle is verifiably bad.
///         6. The fee-only hook never takes custody of a single wei.
///         7. `slot0.lpFee` stays 0 (the documented trap) and the PM/hook event pair stays coherent.
///
/// @dev ORACLE DRIVER: the base fixture's `vm.mockCall` registration is cleared and the GBP/USD
///      proxy is `vm.etch`ed with {SettableFeed}, making oracle state ordinary journaled storage
///      (robust under the invariant harness's per-run snapshot/restore). NAV keeps the fixture's
///      `vm.store` pip-slot mechanism.
///
/// @dev TRANSIENT-CACHE CANARY: each fuzzed handler call should execute as its own transaction, so
///      the hook's per-transaction fair cache must reset between calls. Rather than bet the fee
///      mirror on that, the handler ALSO models the "cache persisted across calls" hypothesis
///      (mirroring `_beforeSwap`'s write-once cache) and counts swaps explained only by the stale
///      cache into `staleCacheMatches`; `invariant_transientCacheFreshPerCall` asserts it stays 0,
///      which empirically pins the harness semantics. If a foundry upgrade ever flips this, that
///      invariant fails self-describingly (remediation: flip the mirror's cache model) — no silent
///      wrong-pass is possible. Quoter parity and the fallback checks are cache-agnostic.
///
/// @dev `fail_on_revert = false` (foundry.toml): the handler NEVER asserts — every checked call is
///      try/catch-wrapped and violations are recorded into ghost counters the invariants surface, so
///      lenient revert handling can't mask a violation (same pattern as the other venues' suites).
contract UsdcWstGbpHookInvariants is UsdcWstGbpForkBase {
    using StateLibrary for IPoolManager;

    UsdcHookHandler internal handler;

    function setUp() public override {
        super.setUp(); // pool initialized at oracle fair against the fixture's mocked feed value

        // Swap the mockCall-driven feed for an etched settable one (see the suite NatSpec).
        vm.clearMockedCalls();
        SettableFeed impl = new SettableFeed();
        vm.etch(GBP_USD_FEED, address(impl).code);
        // ETCH PITFALL: the real proxy's storage (owner/aggregator addresses) still occupies slots
        // 0..2 and would read back as garbage — initialize every slot explicitly.
        SettableFeed(GBP_USD_FEED).setReverting(false);
        SettableFeed(GBP_USD_FEED).set(GBP_USD_ANSWER, block.timestamp);

        // The etched oracle must compose to the exact same live fair the pool was initialized at.
        (uint256 fair, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(GBP_USD_FEED), WSGEM, 90_000);
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE), "etched oracle live");
        assertEq(fair, 761904761904761904, "etched fair matches fixture fair");
        // The stock Quoter must exist at the fork block (hard dependency of invariant 3).
        assertGt(address(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203).code.length, 0, "stock quoter deployed");

        handler = new UsdcHookHandler(PM, key, hook, swapRouter, lpRouter, owner, wrapper.pip(), tickLower, tickUpper);

        // Endow the actor: wstGBP minted in base setUp plus dealt USDC.
        IERC20Minimal(WSGEM).transfer(address(handler), 150_000 * WAD);
        deal(USDC, address(handler), 750_000 * USDC_UNIT);

        // Weighted action mix (selector multiplicity = weight): 50% swap flow, the rest split
        // between oracle drift/breakage, time, LP churn, and admin. GBP/USD drift carries double
        // weight — it is this venue's only FX driver.
        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = UsdcHookHandler.mintExactIn.selector;
        selectors[1] = UsdcHookHandler.mintExactIn.selector;
        selectors[2] = UsdcHookHandler.redeemExactIn.selector;
        selectors[3] = UsdcHookHandler.redeemExactIn.selector;
        selectors[4] = UsdcHookHandler.mintExactOut.selector;
        selectors[5] = UsdcHookHandler.mintExactOut.selector;
        selectors[6] = UsdcHookHandler.redeemExactOut.selector;
        selectors[7] = UsdcHookHandler.redeemExactOut.selector;
        selectors[8] = UsdcHookHandler.arbToFair.selector;
        selectors[9] = UsdcHookHandler.arbToFair.selector;
        selectors[10] = UsdcHookHandler.driftGbpUsd.selector;
        selectors[11] = UsdcHookHandler.driftGbpUsd.selector;
        selectors[12] = UsdcHookHandler.driftNav.selector;
        selectors[13] = UsdcHookHandler.breakOracle.selector;
        selectors[14] = UsdcHookHandler.healOracle.selector;
        selectors[15] = UsdcHookHandler.warpForward.selector;
        selectors[16] = UsdcHookHandler.addLiquidity.selector;
        selectors[17] = UsdcHookHandler.removeLiquidity.selector;
        selectors[18] = UsdcHookHandler.setPause.selector;
        selectors[19] = UsdcHookHandler.reTuneFeeParams.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Every swap's PM-charged fee equals the independent FeeMath/OracleLib recomputation.
    function invariant_feeMatchesFeeMath() public view {
        assertEq(handler.feeParityViolations(), 0, "fee diverged from FeeMath mirror");
    }

    /// @notice Canary: no swap was ever explained only by a transient cache leaked across handler
    ///         calls (see the suite NatSpec — a failure here is a harness-semantics change, not a
    ///         hook bug, and the remediation is to flip the mirror's cache model).
    function invariant_transientCacheFreshPerCall() public view {
        assertEq(handler.staleCacheMatches(), 0, "hook fair-cache leaked across transactions");
    }

    /// @notice The charged fee always respects the clamp of the params active at swap time.
    function invariant_feeWithinBounds() public view {
        assertEq(handler.feeBoundViolations(), 0, "fee escaped [minFee, maxFee]");
    }

    /// @notice Stock-quoter parity to the wei on every swap, and the quoter never fails while the
    ///         swap itself succeeds (router-quotability).
    function invariant_quoterMatchesExecution() public view {
        assertEq(handler.quoterParityFailures(), 0, "stock quoter diverged from execution");
        assertEq(handler.quoterRevertedButSwapSucceeded(), 0, "quoter failed on an executable swap");
    }

    /// @notice Funding-pre-validated swaps never revert, whatever the oracle/pause/params state.
    function invariant_swapNeverRevertsOnOracleState() public view {
        assertEq(handler.unexpectedSwapReverts(), 0, "swap reverted on oracle state");
    }

    /// @notice Fallback swaps pay exactly `fallbackFee`; nothing is priced live off a bad oracle.
    function invariant_fallbackRegimeCorrect() public view {
        assertEq(handler.fallbackFeeMismatches(), 0, "fallback swap paid != fallbackFee");
        assertEq(handler.liveWhenOracleBad(), 0, "swap priced live while oracle bad");
    }

    /// @notice Fee-only: the hook never holds a wei of any pool (or wrapper-underlying) token.
    function invariant_hookHoldsNoTokens() public view {
        assertEq(IERC20Minimal(WSGEM).balanceOf(address(hook)), 0, "hook holds wstGBP");
        assertEq(IERC20Minimal(USDC).balanceOf(address(hook)), 0, "hook holds USDC");
        assertEq(IERC20Minimal(GEM).balanceOf(address(hook)), 0, "hook holds tGBP");
    }

    /// @notice The documented trap stays true (override fees never persist to slot0) and every
    ///         observed swap's PM/hook event pair was coherent.
    function invariant_slot0LpFeeZeroAndEventsConsistent() public view {
        (,,, uint24 lpFee) = _slot0();
        assertEq(lpFee, 0, "slot0.lpFee acquired a value");
        assertEq(handler.eventConsistencyViolations(), 0, "PM/hook event pair incoherent");
    }
}

/// @notice Drives the randomized action mix and records every property violation into ghost
///         counters (never asserts — see the suite NatSpec). Sized for the REAL mainnet pair
///         (wstGBP = currency0, fair ~0.76 wstGBP/USDC at the fixture's oracle values).
contract UsdcHookHandler is Test {
    using StateLibrary for IPoolManager;

    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    bytes32 internal constant PM_SWAP_SIG =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant HOOK_SWAPFEE_SIG = keccak256("SwapFee(bool,uint24,int256,bool)");
    bytes32 internal constant PRICE_SLOT = keccak256("maseer.price.price"); // pip NAV slot
    bytes32 internal constant LP_SALT = bytes32(uint256(0xB0B)); // distinct from the fixture POL's salt 0
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_UNIT = 1e6;
    // The fixture's oracle anchors; drift is always relative to these so it can never compound away.
    int256 internal constant GBP_ANCHOR = 1.25e8;
    uint256 internal constant NAV_ANCHOR = 1.05e18;

    IPoolManager internal immutable pm;
    UsdcWstGbpHook internal immutable hook;
    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTest internal immutable lpRouter;
    address internal immutable owner;
    address internal immutable pip;
    address internal immutable wsgem;
    address internal immutable usdc;
    bool internal immutable wstGbpIsC0;
    int24 internal immutable tickLower;
    int24 internal immutable tickUpper;
    PoolKey internal key;
    PoolId internal poolId;
    SettableFeed internal gbpFeed;

    // ---- violation ghosts (surfaced by the invariants; never asserted here) ----
    uint256 public feeParityViolations;
    uint256 public staleCacheMatches;
    uint256 public feeBoundViolations;
    uint256 public quoterParityFailures;
    uint256 public quoterRevertedButSwapSucceeded;
    uint256 public unexpectedSwapReverts;
    uint256 public fallbackFeeMismatches;
    uint256 public liveWhenOracleBad;
    uint256 public eventConsistencyViolations;
    // ---- persistent-cache-hypothesis ghost (see suite NatSpec) ----
    bool internal cacheSet;
    uint256 internal cacheWord; // 1 = fallback verdict, else the cached fairWad
    // ---- state ghosts / telemetry ----
    uint256 public handlerLiquidity;
    uint256 public totalSwaps;
    uint256 public fallbackSwaps;
    uint256 public surchargedSwaps;
    int256 internal lastGbpAnswer = GBP_ANCHOR;
    uint256 internal lastNav = NAV_ANCHOR;

    /// @dev PoolSwapTest refunds leftover native balance to msg.sender (the documented gotcha).
    receive() external payable {}

    constructor(
        IPoolManager _pm,
        PoolKey memory _key,
        UsdcWstGbpHook _hook,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _lpRouter,
        address _owner,
        address _pip,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        pm = _pm;
        key = _key;
        poolId = _key.toId();
        hook = _hook;
        swapRouter = _swapRouter;
        lpRouter = _lpRouter;
        owner = _owner;
        pip = _pip;
        wsgem = address(_hook.wrapper());
        usdc = _hook.usdc();
        wstGbpIsC0 = _hook.wstGbpIsCurrency0();
        gbpFeed = SettableFeed(address(_hook.gbpUsdFeed()));
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        IERC20Minimal(wsgem).approve(address(_swapRouter), type(uint256).max);
        IERC20Minimal(usdc).approve(address(_swapRouter), type(uint256).max);
        IERC20Minimal(wsgem).approve(address(_lpRouter), type(uint256).max);
        IERC20Minimal(usdc).approve(address(_lpRouter), type(uint256).max);
    }

    // ================================================================ swap actions

    function mintExactIn(uint256 amt) public {
        amt = bound(amt, WAD, 2_000 * WAD); // wstGBP in
        _observedSwap(wstGbpIsC0, -int256(amt));
    }

    function redeemExactIn(uint256 amt) public {
        amt = bound(amt, USDC_UNIT, 2_500 * USDC_UNIT); // USDC in
        _observedSwap(!wstGbpIsC0, -int256(amt));
    }

    function mintExactOut(uint256 amt) public {
        amt = bound(amt, USDC_UNIT, 1_500 * USDC_UNIT); // USDC out
        _observedSwap(wstGbpIsC0, int256(amt));
    }

    function redeemExactOut(uint256 amt) public {
        amt = bound(amt, WAD, 1_000 * WAD); // wstGBP out
        _observedSwap(!wstGbpIsC0, int256(amt));
    }

    /// @dev Close the pool toward oracle fair (deliberately generates surcharged "informed" flow and
    ///      keeps random one-sided flow from walking the price out of the POL range for whole runs).
    function arbToFair() public {
        if (hook.paused()) return;
        FeeMath.FeeParams memory p = _params();
        (uint256 fair, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(address(gbpFeed)), wsgem, p.gbpUsdStalenessSec);
        if (reason != OracleLib.FallbackReason.NONE) return;
        uint160 target = _fairSqrtPriceX96(fair);
        (uint160 sqrtNow,,,) = pm.getSlot0(poolId);
        uint128 liq = pm.getLiquidity(poolId);
        // Overflow guards for the closing-amount formulas (never near-binding at sane prices).
        if (liq == 0 || sqrtNow == 0 || target == 0 || sqrtNow > type(uint128).max || target > type(uint128).max) {
            return;
        }
        if (target > sqrtNow) {
            // price up = currency1 in (USDC when wstGBP is currency0)
            uint256 amtIn = FullMath.mulDiv(liq, target - sqrtNow, FixedPoint96.Q96);
            amtIn = _min(amtIn, 15_000 * USDC_UNIT);
            if (amtIn > 0) _observedSwap(false, -int256(amtIn));
        } else if (target < sqrtNow) {
            uint256 amtIn = FullMath.mulDiv(uint256(liq) << 96, sqrtNow - target, uint256(target) * sqrtNow);
            amtIn = _min(amtIn, 12_000 * WAD);
            if (amtIn > 0) _observedSwap(true, -int256(amtIn));
        }
    }

    // ================================================================ oracle actions

    function driftGbpUsd(uint256 ppm) public {
        ppm = bound(ppm, 0, 60_000); // ±3% around the anchor (sign from parity) — the only FX driver
        lastGbpAnswer = _drifted(GBP_ANCHOR, ppm, 30_000);
        gbpFeed.set(lastGbpAnswer, block.timestamp);
    }

    function driftNav(uint256 ppm) public {
        ppm = bound(ppm, 0, 60_000); // ±3%
        int256 nav = _drifted(int256(NAV_ANCHOR), ppm, 30_000);
        lastNav = uint256(nav);
        vm.store(pip, PRICE_SLOT, bytes32(lastNav));
    }

    /// @dev One breakage mode per OracleLib FallbackReason family.
    function breakOracle(uint8 mode) public {
        mode = uint8(bound(mode, 0, 4));
        if (mode == 0) gbpFeed.setReverting(true); // GBP_FEED_CALL
        else if (mode == 1) gbpFeed.set(0, block.timestamp); // GBP_FEED_ANSWER
        else if (mode == 2) gbpFeed.set(int256(2e30), block.timestamp); // GBP_FEED_ANSWER (absurd)
        else if (mode == 3) gbpFeed.set(lastGbpAnswer, 1); // GBP_FEED_STALE (ancient round)
        else vm.store(pip, PRICE_SLOT, bytes32(0)); // NAV_BAD (pip paused)
    }

    function healOracle() public {
        gbpFeed.setReverting(false);
        gbpFeed.set(lastGbpAnswer, block.timestamp);
        vm.store(pip, PRICE_SLOT, bytes32(lastNav));
    }

    /// @dev Ages `updatedAt` organically into staleness (retuned windows — floor 600s — flip first).
    function warpForward(uint256 s) public {
        vm.warp(block.timestamp + bound(s, 300, 21_600));
    }

    // ================================================================ LP / admin actions

    function addLiquidity(uint256 l) public {
        l = bound(l, 1e14, 1e17);
        try lpRouter.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, int256(l), LP_SALT), "") {
            handlerLiquidity += l;
        } catch {} // funding/price-edge failure is the handler's problem, not a property
    }

    function removeLiquidity(uint256 l) public {
        if (handlerLiquidity == 0) return;
        l = bound(l, 1, handlerLiquidity);
        try lpRouter.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, -int256(l), LP_SALT), "") {
            handlerLiquidity -= l;
        } catch {}
    }

    function setPause(bool p) public {
        vm.prank(owner);
        hook.setPaused(p);
    }

    /// @dev Valid-by-construction params (mirrors `checkParams` bounds); the staleness floor keeps
    ///      both fresh and stale regimes reachable under the warp action.
    function reTuneFeeParams(uint256 seed) public {
        uint24 minFee = uint24(bound(seed, 1, 500));
        uint24 maxFee = uint24(bound(seed >> 16, minFee > 1000 ? minFee : 1000, 100_000));
        FeeMath.FeeParams memory p = FeeMath.FeeParams({
            baseFeeMintSide: uint24(bound(seed >> 32, minFee, maxFee)),
            baseFeeRedeemSide: uint24(bound(seed >> 48, minFee, maxFee)),
            minFee: minFee,
            maxFee: maxFee,
            fallbackFee: uint24(bound(seed >> 64, minFee, maxFee)),
            deviationThresholdPpm: uint24(bound(seed >> 80, 0, 100_000)),
            toxicitySlopePpm: uint24(bound(seed >> 96, 0, 2_000_000)),
            surchargeCapPpm: uint24(bound(seed >> 112, 0, maxFee)),
            gbpUsdStalenessSec: uint24(bound(seed >> 128, 600, 100_000))
        });
        vm.prank(owner);
        hook.setFeeParams(p);
    }

    // ================================================================ the observed swap core

    /// @dev Quote → funding-pre-validate → execute → classify. Never asserts; ghosts only.
    function _observedSwap(bool zeroForOne, int256 amountSpecified) internal {
        FeeMath.FeeParams memory p = _params();
        bool isMintSide = zeroForOne == wstGbpIsC0;
        bool paused = hook.paused();
        (uint160 sqrtBefore,,,) = pm.getSlot0(poolId);
        (uint24 expFresh, uint256 freshWord) = _expectedFresh(isMintSide, p, sqrtBefore, paused);

        (bool qOk, uint256 quoted) = _quote(zeroForOne, amountSpecified);
        if (!_funded(zeroForOne, amountSpecified, qOk, quoted)) return;

        vm.recordLogs();
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
        catch {
            // Funding was pre-validated, so the only plausible causes are oracle/params state —
            // exactly what invariant 4 forbids.
            unexpectedSwapReverts++;
            return;
        }

        Obs memory o = _scanLogs();
        if (!o.sawPmSwap || !o.sawSwapFee || o.pmFee != o.hookFee || o.evMintSide != isMintSide) {
            eventConsistencyViolations++;
            return;
        }
        totalSwaps++;

        // ---- fee parity (fresh mirror first, then the persistent-cache hypothesis) ----
        if (o.pmFee != expFresh) {
            if (cacheSet && o.pmFee == _expectedCached(isMintSide, p, sqrtBefore, paused)) {
                staleCacheMatches++;
            } else {
                feeParityViolations++;
            }
        }
        if (o.pmFee < p.minFee || o.pmFee > p.maxFee) feeBoundViolations++;

        // ---- fallback-regime coherence ----
        if (o.evFallback) {
            fallbackSwaps++;
            if (o.pmFee != p.fallbackFee) fallbackFeeMismatches++;
        } else {
            if (o.pmFee > (isMintSide ? p.baseFeeMintSide : p.baseFeeRedeemSide)) surchargedSwaps++;
            // Priced live while the fresh read says the oracle is bad, and no live cached fair
            // could legitimately explain it (cache unset or itself a fallback verdict).
            if (freshWord == 1 && !paused && (!cacheSet || cacheWord == 1)) liveWhenOracleBad++;
        }

        // ---- stock-quoter parity ----
        if (qOk) {
            uint256 executed = amountSpecified < 0
                ? uint256(uint128(zeroForOne ? o.amount1 : o.amount0))  // exact-in: output received
                : uint256(uint128(-(zeroForOne ? o.amount0 : o.amount1))); // exact-out: input paid
            if (executed != quoted) quoterParityFailures++;
        } else {
            quoterRevertedButSwapSucceeded++;
        }

        // ---- prime the persistent-cache hypothesis (mirrors _beforeSwap's write-once cache) ----
        if (!paused && !cacheSet) {
            cacheSet = true;
            cacheWord = freshWord;
        }
    }

    struct Obs {
        bool sawPmSwap;
        bool sawSwapFee;
        uint24 pmFee;
        int128 amount0;
        int128 amount1;
        bool evMintSide;
        uint24 hookFee;
        bool evFallback;
    }

    function _scanLogs() internal view returns (Obs memory o) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == PM_SWAP_SIG) {
                (int128 a0, int128 a1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                o.pmFee = fee;
                o.amount0 = a0;
                o.amount1 = a1;
                o.sawPmSwap = true;
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == HOOK_SWAPFEE_SIG) {
                o.evMintSide = uint256(logs[i].topics[1]) == 1;
                (o.hookFee,, o.evFallback) = abi.decode(logs[i].data, (uint24, int256, bool));
                o.sawSwapFee = true;
            }
        }
    }

    /// @dev Full independent mirror of `_beforeSwap` pricing from a FRESH oracle read.
    ///      `word` is what the hook would write to its fair cache (1 = fallback verdict).
    function _expectedFresh(bool isMintSide, FeeMath.FeeParams memory p, uint160 sqrtBefore, bool paused)
        internal
        view
        returns (uint24 fee, uint256 word)
    {
        if (paused) return (p.fallbackFee, 0); // pause path never touches the cache
        (uint256 fair, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(address(gbpFeed)), wsgem, p.gbpUsdStalenessSec);
        if (reason != OracleLib.FallbackReason.NONE) return (p.fallbackFee, 1);
        int256 d = OracleLib.deviationPpm(OracleLib.poolPriceWstGbpPerUsdcWad(sqrtBefore, wstGbpIsC0), fair);
        return (FeeMath.swapFee(isMintSide, d, p), fair);
    }

    /// @dev The same pricing under the "cache persisted across handler calls" hypothesis.
    function _expectedCached(bool isMintSide, FeeMath.FeeParams memory p, uint160 sqrtBefore, bool paused)
        internal
        view
        returns (uint24)
    {
        if (paused || cacheWord == 1) return p.fallbackFee;
        int256 d = OracleLib.deviationPpm(OracleLib.poolPriceWstGbpPerUsdcWad(sqrtBefore, wstGbpIsC0), cacheWord);
        return FeeMath.swapFee(isMintSide, d, p);
    }

    function _quote(bool zeroForOne, int256 amountSpecified) internal returns (bool qOk, uint256 quoted) {
        if (amountSpecified < 0) {
            try QUOTER.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(uint256(-amountSpecified)), hookData: ""
                })
            ) returns (
                uint256 out, uint256
            ) {
                return (true, out);
            } catch {}
        } else {
            try QUOTER.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(uint256(amountSpecified)), hookData: ""
                })
            ) returns (
                uint256 amtIn, uint256
            ) {
                return (true, amtIn);
            } catch {}
        }
    }

    /// @dev A swap is only attempted when its worst-case input is provably funded, so a subsequent
    ///      revert can never be the handler's own doing. Exact-out without a quote uses generous
    ///      real-pair price caps (fair drifts at most ±~6% around ~0.76 wstGBP/USDC here).
    function _funded(bool zeroForOne, int256 amountSpecified, bool qOk, uint256 quoted) internal view returns (bool) {
        address tokenIn = zeroForOne ? (wstGbpIsC0 ? wsgem : usdc) : (wstGbpIsC0 ? usdc : wsgem);
        uint256 bal = IERC20Minimal(tokenIn).balanceOf(address(this));
        if (amountSpecified < 0) return bal >= uint256(-amountSpecified);
        uint256 need;
        if (qOk) {
            need = quoted + quoted / 4; // headroom over the quote (belt over braces)
        } else if (tokenIn == wsgem) {
            // wstGBP in for USDC out: ≤ 2e12 wstGBP-wei per USDC-unit (≈ 2 wstGBP/USDC, ~2.6x fair).
            need = uint256(amountSpecified) * 2e12;
        } else {
            // USDC in for wstGBP out: ≤ 3 USDC-units per 1e12 wstGBP-wei (≈ 3 USDC/wstGBP, ~2.3x fair).
            need = uint256(amountSpecified) / 1e12 * 3;
        }
        return bal >= need;
    }

    function _params() internal view returns (FeeMath.FeeParams memory p) {
        // Wholesale-decode the getter's tuple (identical encoding to the struct) — the many-return
        // destructuring blows the stack in the optimizer-off coverage build.
        (bool ok, bytes memory ret) = address(hook).staticcall(abi.encodeWithSignature("feeParams()"));
        require(ok, "feeParams read");
        p = abi.decode(ret, (FeeMath.FeeParams));
    }

    /// @dev ±`capPpm` drift around an anchor from an unsigned seed (low bit = sign).
    function _drifted(int256 anchor, uint256 ppm, uint256 capPpm) internal pure returns (int256) {
        bool up = ppm & 1 == 1;
        uint256 mag = ppm / 2 > capPpm ? capPpm : ppm / 2;
        return anchor * int256(up ? 1_000_000 + mag : 1_000_000 - mag) / 1_000_000;
    }

    /// @dev Port of the fixture's fair→sqrtPriceX96 conversion, orientation-parameterized (carries
    ///      the USDC_UNIT decimal fold).
    function _fairSqrtPriceX96(uint256 fairWad) internal view returns (uint160) {
        uint256 ratioX192 = wstGbpIsC0 ? (USDC_UNIT << 192) / fairWad : ((fairWad << 96) / USDC_UNIT) << 96;
        return uint160(_isqrt(ratioX192));
    }

    function _isqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 n;
        while (xx > 1) {
            xx >>= 1;
            ++n;
        }
        r = 1 << (n / 2 + 1);
        for (uint256 i = 0; i < 8; ++i) {
            r = (r + x / r) / 2;
        }
        if (r > x / r) r = x / r;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
