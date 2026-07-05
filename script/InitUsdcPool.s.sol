// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {UsdcWstGbpHook} from "../src/usdc/UsdcWstGbpHook.sol";
import {OracleLib} from "../src/usdc/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/usdc/interfaces/IAggregatorV3.sol";

/// @notice INIT-ONLY: creates the wstGBP/USDC dynamic-fee pool AT THE ORACLE FAIR PRICE (via the
///         same OracleLib the hook prices with, so on-chain deviation is ~0 at init by
///         construction) — and nothing else. No funds move; any address can run it, once.
///
///         FUNDING IS A UI ACTION, not a script: the pool is a normal v4 AMM (the hook has no
///         liquidity callbacks), so the treasury Safe adds/collects/removes POL through the
///         Uniswap web app / canonical PositionManager like any pool
///         (`test/UsdcWstGbpPositionManager.t.sol` pins that exact path — including the tight
///         spacing-1 bracket shape this near-stable venue wants; range selection in DEPLOY.md).
///
/// Env:    USDC_HOOK  deployed hook address (required)
///
/// Usage:  USDC_HOOK=<hook> make init-usdc-pool-dry / make init-usdc-pool
contract InitUsdcPool is Script {
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    /// @dev Near-stable pair: spacing 1 (the ±12.5bps wrapper band is ~2.5 ticks wide; spacing 60
    ///      would quantize POL range edges to ~60bps steps — unusable here).
    int24 internal constant TICK_SPACING = 1;
    uint256 internal constant WAD = 1e18;
    /// @dev One whole USDC (6 decimals) — the pool-side decimal fold, matching OracleLib.
    uint256 internal constant USDC_UNIT = 1e6;
    /// @dev Same plausibility corridor as the deploy script (wstGBP per USDC, WAD).
    uint256 internal constant FAIR_MIN = 0.4e18;
    uint256 internal constant FAIR_MAX = 1.5e18;

    function run() external returns (PoolKey memory key) {
        UsdcWstGbpHook hook = UsdcWstGbpHook(vm.envAddress("USDC_HOOK"));

        // --- pre-flight ----------------------------------------------------------------------
        require(address(hook.wrapper()) == WSTGBP && hook.usdc() == USDC, "InitUsdcPool: wrong hook");
        require(hook.owner() == MULTISIG, "InitUsdcPool: hook not multisig-owned");
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(GBP_USD_FEED), WSTGBP, 90_000);
        require(reason == OracleLib.FallbackReason.NONE, "InitUsdcPool: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "InitUsdcPool: fair price implausible");

        (address c0, address c1) = WSTGBP < USDC ? (WSTGBP, USDC) : (USDC, WSTGBP);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 sqrtPriceX96 = _fairSqrtPriceX96(fairWad, WSTGBP < USDC);

        // --- init (reverts if the pool already exists — natural re-run guard) ------------------
        vm.startBroadcast();
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        // --- post-asserts ------------------------------------------------------------------------
        (uint160 sqrtNow, int24 tickNow,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(sqrtNow == sqrtPriceX96, "InitUsdcPool: slot0 mismatch");
        uint256 poolWad = OracleLib.poolPriceWstGbpPerUsdcWad(sqrtNow, WSTGBP < USDC);
        int256 d = OracleLib.deviationPpm(poolWad, fairWad);
        require(uint256(d < 0 ? -d : d) < 1000, "InitUsdcPool: init deviation too large");

        console2.log("PoolId:", vm.toString(PoolId.unwrap(key.toId())));
        console2.log("init sqrtPriceX96:", sqrtPriceX96);
        console2.log("init tick:", vm.toString(tickNow));
        console2.log("fair (wstGBP per USDC, WAD):", fairWad);
        console2.log("pool price (USDC per wstGBP, WAD):", poolWad == 0 ? 0 : WAD * WAD / poolWad);
        console2.log("init deviation (ppm):", vm.toString(d));
        console2.log("NEXT: fund POL via the Uniswap UI (see DEPLOY.md, USDC venue section);");
        console2.log("      then migrate the static 5bps pool's LP out (same section).");
    }

    /// @dev sqrtPriceX96 of a pool trading exactly at `fairWad` (wstGBP per USDC): the raw pool
    ///      price (currency1 base units per currency0 base units) is USDC_UNIT/fair when wstGBP is
    ///      currency0 — the 1e12 decimal gap folds into USDC_UNIT exactly as in OracleLib.
    function _fairSqrtPriceX96(uint256 fairWad, bool wstGbpIsCurrency0) internal pure returns (uint160) {
        uint256 ratioX192 = wstGbpIsCurrency0 ? (USDC_UNIT << 192) / fairWad : ((fairWad << 96) / USDC_UNIT) << 96;
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
}
