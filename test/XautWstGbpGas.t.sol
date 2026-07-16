// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {XautWstGbpForkBase} from "./base/XautWstGbpForkBase.sol";

/// @notice Gas snapshots: hook-pool swap overhead vs an otherwise-identical static-fee (hookless)
///         control pool. Targets: warm (fair price cached this tx) < 10k overhead; cold < 80k —
///         the WETH venue's ceiling, NOT the USDC venue's tighter 70k, because this venue's cold
///         path pays TWO Chainlink proxy→aggregator chains (XAU/USD + GBP/USD, ~66k measured on the
///         WETH venue's identical two-feed path), not one.
/// @dev Measurement design — three pools, one test transaction (same as the WETH/USDC venues'):
///      1. a throwaway swap on control pool A warms all SHARED infra (tokens, the wstGBP compliance
///         proxy chain, PM base slots, router) so it contaminates neither side of the comparison;
///      2. control pool B's first swap = pool-cold baseline (c1), second = warm baseline (c2);
///      3. the hook pool's first swap = pool-cold + oracle-cold (h1), second = fully warm (h2).
///      coldOverhead = h1 − c1, warmOverhead = h2 − c2. The feeds are UNMOCKED here
///      (vm.clearMockedCalls) so the cold path pays the real Chainlink proxy gas it will pay in
///      production — the fixture's mocks cost ~0 gas and would understate it.
///
///      REGIME PINNING (extra step vs the sister venues): with live feeds the real gold price sits
///      far from the fixture's mocked XAU_USD_ANSWER, so the fixture pool would rest tens of percent
///      off the real fair and the measured mint-side swap would take the cap-saturated surcharge
///      branch (~+400 gas) — a code path the WETH/USDC gas suites' measurements never took (their
///      live-feed deviation put the measured direction on the NON-closing side). Re-basing every
///      pool to the LIVE fair pins the measurement to the venue's rest-state base-fee path, keeping
///      it deterministic in regime and the cross-venue warm numbers comparable.
contract XautWstGbpGasTest is XautWstGbpForkBase {
    PoolKey warmupKey; // control A
    PoolKey controlKey; // control B

    function setUp() public override {
        super.setUp();
        // Real Chainlink feeds for honest cold-read costs (the fork block's rounds are live; the
        // resulting fee VALUE is irrelevant to the measurement, only the code path matters — which
        // is exactly why the pools are re-based to the live fair below).
        vm.clearMockedCalls();
        uint160 sqrtP = _fairSqrtPriceX96(_fairWad()); // the LIVE fair, not the fixture's mocked one
        // Fund the re-basing: at the live fair the control positions sit off-center in the fixture
        // range (heavier wstGBP side) and the hook-pool alignment swap below can cost six figures of
        // wstGBP against 9e15 of liquidity — mint plenty via the real wrapper.
        _seedWsgem(2_000_000 * WAD, 1_600_000 * WAD);

        // The fixture's POL must straddle the live fair for the hook-pool measurements (its range is
        // ±5580 ticks ≈ ×/÷1.75 around the mocked fair); if gold drifts further than that from
        // XAU_USD_ANSWER, update the fixture constant.
        int24 liveTick = TickMath.getTickAtSqrtPrice(sqrtP);
        assertGt(liveTick, tickLower, "live fair inside the fixture POL range");
        assertLt(liveTick, tickUpper, "live fair inside the fixture POL range");

        warmupKey = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 3000, tickSpacing: 30, hooks: IHooks(address(0))
        });
        controlKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        PM.initialize(warmupKey, sqrtP);
        PM.initialize(controlKey, sqrtP);
        // The fixture's spacing-60 ticks are incidentally 30-aligned, so the warmup pool (spacing
        // 30) can share them — same shortcut as the WETH venue (the USDC fixture's spacing-1 ticks
        // needed their own aligned range).
        lpRouter.modifyLiquidity(
            warmupKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 9e15, salt: 0}),
            ""
        );
        lpRouter.modifyLiquidity(
            controlKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 9e15, salt: 0}),
            ""
        );

        // Park the hook pool (initialized at the mocked fair by the fixture) exactly at the live
        // fair too: one price-limited swap.
        (uint160 cur,,,) = _slot0();
        if (cur != sqrtP) {
            bool zeroForOne = sqrtP < cur; // zeroForOne pushes sqrtPrice down
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: zeroForOne ? -int256(1_000_000 * WAD) : -int256(1_500 * XAUT_UNIT),
                    sqrtPriceLimitX96: sqrtP // the limit, not the input, terminates this swap
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            (cur,,,) = _slot0();
            assertEq(cur, sqrtP, "hook pool parked at the live fair");
        }

        // One nominal swap per pool: initializes each pool's feeGrowthGlobal0 slot (a one-time
        // 0→nonzero SSTORE, ~22k) OUTSIDE the measured transaction and SYMMETRICALLY. A zeroForOne
        // alignment swap above already pays it for the hook pool, so skipping this here would leave
        // it in the control legs only and understate the cold overhead by ~17k — and swapping ALL
        // three pools (not just the controls) keeps the symmetry even when the alignment ran the
        // other direction or not at all. (The sister venues' suites were symmetric the other way —
        // no pool had ever swapped — so their subtraction cancelled it too.) The ~4.5 ppm of
        // deviation this adds to the parked hook pool is deep inside the surcharge-free band.
        _nominalSwap(warmupKey);
        _nominalSwap(controlKey);
        _nominalSwap(key);
    }

    function _nominalSwap(PoolKey memory k) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(WAD), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _timedSwap(PoolKey memory k, string memory label) internal returns (uint256 gasUsed) {
        vm.startSnapshotGas(label);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(WAD), // 1 wstGBP in, identical for every measurement
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        gasUsed = vm.stopSnapshotGas(label);
    }

    function test_gasOverheadVsStaticFeePool() public {
        _timedSwap(warmupKey, "warmupSwapDiscarded"); // warm shared infra out of the comparison

        uint256 controlCold = _timedSwap(controlKey, "controlSwapPoolCold");
        uint256 controlWarm = _timedSwap(controlKey, "controlSwapWarm");
        uint256 hookCold = _timedSwap(key, "hookSwapOracleCold");
        uint256 hookWarm = _timedSwap(key, "hookSwapWarm");

        uint256 coldOverhead = hookCold - controlCold;
        uint256 warmOverhead = hookWarm - controlWarm;
        vm.snapshotValue("hookColdOverheadGas", coldOverhead);
        vm.snapshotValue("hookWarmOverheadGas", warmOverhead);

        emit log_named_uint("control pool-cold", controlCold);
        emit log_named_uint("control warm", controlWarm);
        emit log_named_uint("hook cold (real oracle)", hookCold);
        emit log_named_uint("hook warm", hookWarm);
        emit log_named_uint("cold overhead", coldOverhead);
        emit log_named_uint("warm overhead", warmOverhead);

        assertLt(warmOverhead, 10_000, "warm overhead target (<10k)");
        // The WETH venue measured ~66k cold on this exact two-feed path (~24k of it the two real
        // Chainlink proxy→aggregator chains + ~11k the wstGBP navprice proxy chain); the same is
        // expected here — 80k is the regression ceiling, not a target.
        assertLt(coldOverhead, 80_000, "cold overhead regression ceiling");
    }
}
