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

import {WethWstGbpHook} from "../src/weth/WethWstGbpHook.sol";
import {OracleLib} from "../src/weth/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";

/// @notice INIT-ONLY: creates the WETH/wstGBP dynamic-fee pool AT THE ORACLE FAIR PRICE (via the
///         same OracleLib the hook prices with, so on-chain deviation is ~0 at init by
///         construction) — and nothing else. No funds move; any address can run it, once.
///
///         FUNDING IS A UI ACTION, not a script: the pool is a normal v4 AMM (the hook has no
///         liquidity callbacks), so the treasury Safe adds/collects/removes POL through the
///         Uniswap web app / canonical PositionManager like any pool
///         (`test/WethWstGbpPositionManager.t.sol` pins that exact path). The `POLCompounder`
///         remains in the repo as OPTIONAL automation to migrate into later; it is not part of the
///         launch path.
///
/// Env:    WETH_HOOK  deployed hook address (required)
///
/// Usage:  WETH_HOOK=<hook> make init-weth-pool-dry / make init-weth-pool
contract InitWethPool is Script {
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant WAD = 1e18;
    /// @dev Same plausibility corridor as the deploy script (wstGBP per WETH, WAD).
    uint256 internal constant FAIR_MIN = 200e18;
    uint256 internal constant FAIR_MAX = 50_000e18;

    function run() external returns (PoolKey memory key) {
        WethWstGbpHook hook = WethWstGbpHook(vm.envAddress("WETH_HOOK"));

        // --- pre-flight ----------------------------------------------------------------------
        require(address(hook.wrapper()) == WSTGBP && hook.weth() == WETH, "InitWethPool: wrong hook");
        require(hook.owner() == MULTISIG, "InitWethPool: hook not multisig-owned");
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(ETH_USD_FEED), IAggregatorV3(GBP_USD_FEED), WSTGBP, 4500, 90_000);
        require(reason == OracleLib.FallbackReason.NONE, "InitWethPool: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "InitWethPool: fair price implausible");

        (address c0, address c1) = WSTGBP < WETH ? (WSTGBP, WETH) : (WETH, WSTGBP);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 sqrtPriceX96 = _fairSqrtPriceX96(fairWad, WSTGBP < WETH);

        // --- init (reverts if the pool already exists — natural re-run guard) ------------------
        vm.startBroadcast();
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        // --- post-asserts ------------------------------------------------------------------------
        (uint160 sqrtNow, int24 tickNow,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(sqrtNow == sqrtPriceX96, "InitWethPool: slot0 mismatch");
        uint256 poolWad = OracleLib.poolPriceWstGbpPerWethWad(sqrtNow, WSTGBP < WETH);
        int256 d = OracleLib.deviationPpm(poolWad, fairWad);
        require(uint256(d < 0 ? -d : d) < 1000, "InitWethPool: init deviation too large");

        console2.log("PoolId:", vm.toString(PoolId.unwrap(key.toId())));
        console2.log("init sqrtPriceX96:", sqrtPriceX96);
        console2.log("init tick:", vm.toString(tickNow));
        console2.log("fair (wstGBP per WETH, WAD):", fairWad);
        console2.log("pool price (WETH per wstGBP, WAD):", poolWad == 0 ? 0 : WAD * WAD / poolWad);
        console2.log("init deviation (ppm):", vm.toString(d));
        console2.log("NEXT: fund POL via the Uniswap UI (see DEPLOY.md 'Funding via the Uniswap UI').");
    }

    /// @dev sqrtPriceX96 of a pool trading exactly at `fairWad` (wstGBP per WETH): the raw pool
    ///      price (currency1 per currency0) is 1/fair when wstGBP is currency0.
    function _fairSqrtPriceX96(uint256 fairWad, bool wstGbpIsCurrency0) internal pure returns (uint160) {
        uint256 ratioX192 = wstGbpIsCurrency0 ? (WAD << 192) / fairWad : ((fairWad << 96) / WAD) << 96;
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
