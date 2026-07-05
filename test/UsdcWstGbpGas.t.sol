// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {UsdcWstGbpForkBase} from "./base/UsdcWstGbpForkBase.sol";

/// @notice Gas snapshots: hook-pool swap overhead vs an otherwise-identical static-fee (hookless)
///         control pool. Targets: warm (fair price cached this tx) < 10k overhead; cold < 70k —
///         tighter than the WETH venue's 80k ceiling because this venue's cold path pays ONE
///         Chainlink proxy→aggregator chain, not two.
/// @dev Measurement design — three pools, one test transaction (same as the WETH venue's):
///      1. a throwaway swap on control pool A warms all SHARED infra (tokens, the wstGBP compliance
///         proxy chain, PM base slots, router) so it contaminates neither side of the comparison;
///      2. control pool B's first swap = pool-cold baseline (c1), second = warm baseline (c2);
///      3. the hook pool's first swap = pool-cold + oracle-cold (h1), second = fully warm (h2).
///      coldOverhead = h1 − c1, warmOverhead = h2 − c2. The feed is UNMOCKED here
///      (vm.clearMockedCalls) so the cold path pays the real Chainlink proxy gas it will pay in
///      production — the fixture's mocks cost ~0 gas and would understate it.
contract UsdcWstGbpGasTest is UsdcWstGbpForkBase {
    PoolKey warmupKey; // control A
    PoolKey controlKey; // control B

    function setUp() public override {
        super.setUp();
        // Real Chainlink feed for honest cold-read costs (the fork block's round is live; the
        // resulting fee VALUE is irrelevant to the measurement, only the code path matters).
        vm.clearMockedCalls();

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
        uint160 sqrtP = _fairSqrtPriceX96(761904761904761904); // fixture-default fair; exact value immaterial
        PM.initialize(warmupKey, sqrtP);
        PM.initialize(controlKey, sqrtP);
        // The fixture's ticks are spacing-1 aligned; the warmup pool (spacing 30) needs its own
        // 30-aligned range (the WETH venue's spacing-60 ticks were incidentally 30-aligned).
        int24 wLo = _alignDown(tickLower, 30);
        int24 wHi = _alignDown(tickUpper, 30) + 30;
        lpRouter.modifyLiquidity(
            warmupKey, ModifyLiquidityParams({tickLower: wLo, tickUpper: wHi, liquidityDelta: 5e17, salt: 0}), ""
        );
        lpRouter.modifyLiquidity(
            controlKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 5e17, salt: 0}),
            ""
        );
    }

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24 aligned) {
        aligned = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) aligned -= spacing;
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
        // The WETH venue's cold path measured ~66k with ~24k of it being TWO Chainlink
        // proxy→aggregator chains; this venue reads one, so ~54k is expected — 70k is the
        // regression ceiling, not a target.
        assertLt(coldOverhead, 70_000, "cold overhead regression ceiling");
    }
}
