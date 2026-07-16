// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {WstGBPFixture} from "./WstGBPFixture.sol";
import {XautWstGbpHook} from "../../src/xaut/XautWstGbpHook.sol";
import {FeeMath} from "../../src/xaut/lib/FeeMath.sol";
import {OracleLib} from "../../src/xaut/lib/OracleLib.sol";
import {IAggregatorV3} from "../../src/xaut/interfaces/IAggregatorV3.sol";

/// @title XautWstGbpForkBase
/// @notice Fork scaffolding for the XAUT/wstGBP dynamic-fee venue: extends {WstGBPFixture} (which
///         pins the wstGBP wrapper + NAV driver) with XAUT, the Chainlink XAU/USD and GBP/USD feeds
///         (both mocked to deterministic values — the fork block's real rounds are then irrelevant to
///         staleness), the mined hook, a dynamic-fee pool initialized at oracle fair, and wide-range
///         POL through the canonical v4 test routers (this venue is a REAL AMM pool, unlike the
///         backstop).
/// @dev Deviation is driven from any of three legs: `_setNav` (wstGBP leg) or `_mockFeed` on either
///      Chainlink feed moves fair while pool spot stays; swapping moves pool spot while fair stays.
///
///      TWO SIGN TRAPS (fair here is wstGBP-per-XAUT = x/(g·nav)):
///      - raising XAU/USD RAISES fair, leaving the pool cheap in XAUT terms (d < 0 — the mint side
///        closes; the gold-rally direction);
///      - raising GBP/USD or NAV LOWERS fair, leaving the pool rich in XAUT terms (d > 0 — the
///        redeem side closes; the post-ratchet conveyor direction, same trap as the USDC venue).
///      Feed-driven deviation tests must expect the leg-dependent inversion.
///
///      AMOUNT SCALE: XAUT is 6 decimals — every XAUT amount in this fixture and its suites is in
///      1e6 base units (`XAUT_UNIT`), never WAD. One whole XAUT is ~$2,625 at the fixture's feed
///      values, so XAUT token counts run ~2000× smaller than the USDC fixture's.
///
///      TRANSIENT-CACHE CAVEAT for test authors: a Foundry test function is ONE transaction, so the
///      hook's per-transaction fair-price/fallback cache persists across consecutive swaps inside a
///      single test. Oracle changes made mid-test after a swap are therefore invisible to later swaps
///      in the same test — by design (that IS the intra-tx semantics). Scenarios that need "the next
///      transaction" must live in separate test functions.
abstract contract XautWstGbpForkBase is WstGBPFixture {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;

    uint256 constant XAUT_UNIT = 1e6;

    // Deterministic oracle state: gold $2,625, GBP $1.25, NAV 1.05 => fair = 2625/1.3125 =
    // EXACTLY 2000e18 wstGBP/XAUT (chosen so parity asserts pin a clean round number).
    int256 constant XAU_USD_ANSWER = 2625e8;
    int256 constant GBP_USD_ANSWER = 1.25e8;
    uint256 constant NAV = 1.05e18;

    /// @dev High-vol pair (gold-in-GBP ~37% annualized): spacing 60 like the WETH venue — POL
    ///      brackets are wide here, so 60-tick (~0.6%) edge quantization is immaterial (the USDC
    ///      venue's spacing-1 tight-bracket rationale does not apply).
    int24 constant TICK_SPACING = 60;
    /// @dev ±5580 ticks (= 93 spacings) ≈ ×/÷1.75 — same wide static POL policy as the WETH/USDC
    ///      fixtures (breadth keeps every fee-regime test in range).
    int24 constant RANGE_TICKS = 5580;

    bytes32 constant PM_SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant HOOK_SWAPFEE_SIG = keccak256("SwapFee(bool,uint24,int256,bool)");

    XautWstGbpHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    PoolKey key;
    address owner;
    int24 tickLower;
    int24 tickUpper;

    receive() external payable {}

    function setUp() public virtual override {
        super.setUp(); // fork + force the wrapper's market open (irrelevant here except for seeding)
        owner = makeAddr("owner");

        // Deterministic oracle state before anything reads it.
        _setNav(NAV);
        _mockFeed(XAU_USD_FEED, XAU_USD_ANSWER, block.timestamp);
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp);

        lpRouter = new PoolModifyLiquidityTest(PM);
        swapRouter = new PoolSwapTest(PM);

        // Mine + CREATE2-deploy the hook at a flag-encoded address.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(
            PM, IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, XAUT, _defaultParams(), owner
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(XautWstGbpHook).creationCode, args);
        hook = new XautWstGbpHook{salt: salt}(
            PM, IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), wrapper, XAUT, _defaultParams(), owner
        );
        assertEq(address(hook), hookAddr, "mined address");

        // Dynamic-fee pool at the oracle fair price (deviation ~0 at init by construction).
        (address c0, address c1) = WSGEM < XAUT ? (WSGEM, XAUT) : (XAUT, WSGEM);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 initSqrtPrice = _fairSqrtPriceX96(_fairWad());
        PM.initialize(key, initSqrtPrice);

        // Wide-range POL around the init tick.
        int24 tick = TickMath.getTickAtSqrtPrice(initSqrtPrice);
        tickLower = _floorToSpacing(tick - RANGE_TICKS);
        tickUpper = _floorToSpacing(tick + RANGE_TICKS) + TICK_SPACING;

        _seedWsgem(600_000 * WAD, 400_000 * WAD); // ~400k wstGBP via the real wrapper mint
        deal(XAUT, address(this), 2_000 * XAUT_UNIT); // ~$5M of gold; stdStorage resolves the slot
        IERC20Minimal(WSGEM).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(XAUT).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(WSGEM).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(XAUT).approve(address(swapRouter), type(uint256).max);

        // ~100k wstGBP + ~50 XAUT at the default fair — same economic scale as the WETH/USDC
        // fixtures (the liquidityDelta is rescaled for this pair's ~5e-16 raw price). The
        // order-of-magnitude asserts fail loudly if a decimal constant is ever mis-scaled.
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 xautBefore = _bal(XAUT, address(this));
        _addLiquidity(9e15);
        uint256 wsgUsed = wsgBefore - _bal(WSGEM, address(this));
        uint256 xautUsed = xautBefore - _bal(XAUT, address(this));
        assertGt(wsgUsed, 50_000 * WAD, "seeded wstGBP order of magnitude");
        assertLt(wsgUsed, 200_000 * WAD, "seeded wstGBP order of magnitude");
        assertGt(xautUsed, 20 * XAUT_UNIT, "seeded XAUT order of magnitude");
        assertLt(xautUsed, 150 * XAUT_UNIT, "seeded XAUT order of magnitude");
    }

    // ---------------------------------------------------------------- params / oracle drivers

    /// @dev WETH-venue values as WORKING TEST DEFAULTS (the semantics under test are param-agnostic);
    ///      production params come from sim/RESULTS_XAUT.md via DeployXautHook.simParams().
    function _defaultParams() internal pure returns (FeeMath.FeeParams memory p) {
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

    function _mockFeed(address feed, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), answer, updatedAt, updatedAt, uint80(1))
        );
    }

    function _brickFeed(address feed) internal {
        vm.mockCallRevert(feed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), "feed bricked");
    }

    /// @dev The venue's live composed fair price, via the SAME library the hook uses.
    function _fairWad() internal view returns (uint256 fairWad) {
        OracleLib.FallbackReason reason;
        (fairWad, reason) =
            OracleLib.fairPriceWad(IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), WSGEM, 90_000, 90_000);
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE), "fixture oracle must be live");
    }

    /// @dev sqrtPriceX96 for a pool trading exactly at `fairWad` (wstGBP-per-XAUT): the raw pool
    ///      price (currency1 base units per currency0 base units) is XAUT_UNIT/fair when wstGBP is
    ///      currency0, fair/XAUT_UNIT otherwise — the 1e12 decimal gap folds into XAUT_UNIT exactly
    ///      as in OracleLib.
    function _fairSqrtPriceX96(uint256 fairWad) internal pure returns (uint160) {
        // priceRatioX192 = raw pool price << 192; sqrtPriceX96 = isqrt(priceRatioX192).
        uint256 ratioX192 = WSGEM < XAUT
            ? (XAUT_UNIT << 192) / fairWad  // 1e6/fair (1e6 << 192 ≈ 6.3e63 — no overflow)
            : ((fairWad << 96) / XAUT_UNIT) << 96; // fair/1e6 (split shifts: single <<192 would overflow)
        return uint160(_isqrt(ratioX192));
    }

    function _isqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        r = 1 << (_log2(x) / 2 + 1);
        for (uint256 i = 0; i < 8; ++i) {
            r = (r + x / r) / 2;
        }
        if (r > x / r) r = x / r; // floor
    }

    function _log2(uint256 x) private pure returns (uint256 n) {
        while (x > 1) {
            x >>= 1;
            ++n;
        }
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 spaced = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) spaced -= TICK_SPACING;
        return spaced;
    }

    // ---------------------------------------------------------------- pool actions

    function _addLiquidity(int256 liquidityDelta) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
            }),
            ""
        );
    }

    /// @dev Plain swap through the canonical v4 test router (swap-first is fine: this hook never
    ///      takes, it only overrides the fee). Positive `amountSpecified` = exact-out, negative =
    ///      exact-in (v4 convention).
    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    struct SwapObservation {
        uint24 pmFee; // fee field of the PoolManager's Swap event — ground truth
        int128 amount0; // user-perspective deltas from the same event (negative = paid to pool)
        int128 amount1;
        bool sawPmSwap;
        bool mintSide; // from the hook's SwapFee event
        uint24 hookFee;
        int256 deviationPpm;
        bool fallbackMode;
        bool sawSwapFee;
    }

    /// @dev Swap and read the charged fee from the PoolManager's own Swap event (the override fee is
    ///      per-swap and NEVER written to slot0 — `getSlot0().lpFee` stays 0 for a dynamic pool),
    ///      cross-checked against the hook's SwapFee event.
    function _swapAndObserve(bool zeroForOne, int256 amountSpecified) internal returns (SwapObservation memory o) {
        vm.recordLogs();
        _swap(zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(PM) && logs[i].topics[0] == PM_SWAP_SIG) {
                (int128 amount0, int128 amount1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                o.pmFee = fee;
                o.amount0 = amount0;
                o.amount1 = amount1;
                o.sawPmSwap = true;
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == HOOK_SWAPFEE_SIG) {
                o.mintSide = uint256(logs[i].topics[1]) == 1;
                (o.hookFee, o.deviationPpm, o.fallbackMode) = abi.decode(logs[i].data, (uint24, int256, bool));
                o.sawSwapFee = true;
            }
        }
        assertTrue(o.sawPmSwap, "PM Swap event observed");
        assertTrue(o.sawSwapFee, "hook SwapFee event observed");
        assertEq(o.pmFee, o.hookFee, "PM-charged fee == hook-reported fee");
    }

    /// @dev The fee the hook SHOULD charge right now, computed test-side from independently read
    ///      state through the same libraries (the parity anchor for fee-correctness asserts).
    function _expectedFee(bool zeroForOne) internal view returns (uint24, int256) {
        (uint160 sqrtPriceX96,,,) = _slot0();
        uint256 poolWad = OracleLib.poolPriceWstGbpPerXautWad(sqrtPriceX96, WSGEM < XAUT);
        int256 d = OracleLib.deviationPpm(poolWad, _fairWad());
        bool isMintSide = zeroForOne == (WSGEM < XAUT);
        return (FeeMath.swapFee(isMintSide, d, _defaultParams()), d);
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        return PM.getSlot0(key.toId());
    }
}
