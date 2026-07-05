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
import {UsdcWstGbpHook} from "../../src/usdc/UsdcWstGbpHook.sol";
import {FeeMath} from "../../src/usdc/lib/FeeMath.sol";
import {OracleLib} from "../../src/usdc/lib/OracleLib.sol";
import {IAggregatorV3} from "../../src/usdc/interfaces/IAggregatorV3.sol";

/// @title UsdcWstGbpForkBase
/// @notice Fork scaffolding for the wstGBP/USDC dynamic-fee venue: extends {WstGBPFixture} (which
///         pins the wstGBP wrapper + NAV driver) with USDC, the Chainlink GBP/USD feed (mocked to a
///         deterministic value — the fork block's real round is then irrelevant to staleness), the
///         mined hook, a dynamic-fee pool initialized at oracle fair, and wide-range POL through the
///         canonical v4 test routers (this venue is a REAL AMM pool, unlike the backstop).
/// @dev Deviation is driven from either side: `_setNav` (wstGBP leg) or `_mockFeed` (Chainlink leg)
///      moves fair while pool spot stays; swapping moves pool spot while fair stays.
///
///      SIGN TRAP (inverted vs the WETH venue's intuition): fair here is wstGBP-per-USDC =
///      1/(g·nav), so RAISING GBP/USD or NAV **lowers** fair, leaving the pool rich in USDC terms
///      (d > 0 — the redeem side closes). Feed-driven deviation tests must expect that inversion.
///
///      AMOUNT SCALE: USDC is 6 decimals — every USDC amount in this fixture and its suites is in
///      1e6 base units (`USDC_UNIT`), never WAD.
///
///      TRANSIENT-CACHE CAVEAT for test authors: a Foundry test function is ONE transaction, so the
///      hook's per-transaction fair-price/fallback cache persists across consecutive swaps inside a
///      single test. Oracle changes made mid-test after a swap are therefore invisible to later swaps
///      in the same test — by design (that IS the intra-tx semantics). Scenarios that need "the next
///      transaction" must live in separate test functions.
abstract contract UsdcWstGbpForkBase is WstGBPFixture {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;

    uint256 constant USDC_UNIT = 1e6;

    // Deterministic oracle state: GBP $1.25, NAV 1.05 => fair = 1/1.3125 = 0.761904… wstGBP/USDC.
    int256 constant GBP_USD_ANSWER = 1.25e8;
    uint256 constant NAV = 1.05e18;

    /// @dev Near-stable pair: spacing 1 so tight ranges (the ±12.5bps wrapper band is ~2.5 ticks
    ///      wide) can be placed exactly. Range edges need no spacing rounding at spacing 1.
    int24 constant TICK_SPACING = 1;
    /// @dev ±5580 ticks ≈ ×/÷1.75 — same wide static POL policy as the WETH fixture (breadth keeps
    ///      every fee-regime test in range; tight-range behavior is exercised separately).
    int24 constant RANGE_TICKS = 5580;

    bytes32 constant PM_SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant HOOK_SWAPFEE_SIG = keccak256("SwapFee(bool,uint24,int256,bool)");

    UsdcWstGbpHook hook;
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
        _mockFeed(GBP_USD_FEED, GBP_USD_ANSWER, block.timestamp);

        lpRouter = new PoolModifyLiquidityTest(PM);
        swapRouter = new PoolSwapTest(PM);

        // Mine + CREATE2-deploy the hook at a flag-encoded address.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(PM, IAggregatorV3(GBP_USD_FEED), wrapper, USDC, _defaultParams(), owner);
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(UsdcWstGbpHook).creationCode, args);
        hook = new UsdcWstGbpHook{salt: salt}(PM, IAggregatorV3(GBP_USD_FEED), wrapper, USDC, _defaultParams(), owner);
        assertEq(address(hook), hookAddr, "mined address");

        // Dynamic-fee pool at the oracle fair price (deviation ~0 at init by construction).
        (address c0, address c1) = WSGEM < USDC ? (WSGEM, USDC) : (USDC, WSGEM);
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
        deal(USDC, address(this), 2_000_000 * USDC_UNIT); // stdStorage resolves the FiatTokenProxy
        IERC20Minimal(WSGEM).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(WSGEM).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(swapRouter), type(uint256).max);

        // ~106k wstGBP + ~139k USDC at the default fair — same economic scale as the WETH fixture.
        // The order-of-magnitude asserts fail loudly if a decimal constant is ever mis-scaled.
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 usdcBefore = _bal(USDC, address(this));
        _addLiquidity(5e17);
        uint256 wsgUsed = wsgBefore - _bal(WSGEM, address(this));
        uint256 usdcUsed = usdcBefore - _bal(USDC, address(this));
        assertGt(wsgUsed, 50_000 * WAD, "seeded wstGBP order of magnitude");
        assertLt(wsgUsed, 200_000 * WAD, "seeded wstGBP order of magnitude");
        assertGt(usdcUsed, 50_000 * USDC_UNIT, "seeded USDC order of magnitude");
        assertLt(usdcUsed, 300_000 * USDC_UNIT, "seeded USDC order of magnitude");
    }

    // ---------------------------------------------------------------- params / oracle drivers

    /// @dev WETH-venue values as WORKING TEST DEFAULTS (the semantics under test are param-agnostic);
    ///      production params come from sim/RESULTS_USDC.md via DeployUsdcHook.simParams().
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
        (fairWad, reason) = OracleLib.fairPriceWad(IAggregatorV3(GBP_USD_FEED), WSGEM, 90_000);
        assertEq(uint8(reason), uint8(OracleLib.FallbackReason.NONE), "fixture oracle must be live");
    }

    /// @dev sqrtPriceX96 for a pool trading exactly at `fairWad` (wstGBP-per-USDC): the raw pool
    ///      price (currency1 base units per currency0 base units) is USDC_UNIT/fair when wstGBP is
    ///      currency0, fair/USDC_UNIT otherwise — the 1e12 decimal gap folds into USDC_UNIT exactly
    ///      as in OracleLib.
    function _fairSqrtPriceX96(uint256 fairWad) internal pure returns (uint160) {
        // priceRatioX192 = raw pool price << 192; sqrtPriceX96 = isqrt(priceRatioX192).
        uint256 ratioX192 = WSGEM < USDC
            ? (USDC_UNIT << 192) / fairWad  // 1e6/fair (1e6 << 192 ≈ 6.3e63 — no overflow)
            : ((fairWad << 96) / USDC_UNIT) << 96; // fair/1e6 (split shifts: single <<192 would overflow)
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
        uint256 poolWad = OracleLib.poolPriceWstGbpPerUsdcWad(sqrtPriceX96, WSGEM < USDC);
        int256 d = OracleLib.deviationPpm(poolWad, _fairWad());
        bool isMintSide = zeroForOne == (WSGEM < USDC);
        return (FeeMath.swapFee(isMintSide, d, _defaultParams()), d);
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        return PM.getSlot0(key.toId());
    }
}
