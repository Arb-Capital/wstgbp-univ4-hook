// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {XautWstGbpHook} from "../src/xaut/XautWstGbpHook.sol";
import {OracleLib} from "../src/xaut/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/xaut/interfaces/IAggregatorV3.sol";

/// @notice INIT-ONLY: creates the XAUT/wstGBP dynamic-fee pool AT THE ORACLE FAIR PRICE (via the
///         same OracleLib the hook prices with, so on-chain deviation is ~0 at init by
///         construction) — and nothing else. No funds move; any address can run it, once.
///
///         The oracle fair is METAL-priced: expect the pool to drift to d ≈ -basis (~-50bps,
///         XAUt trades under the XAU/USD feed) after funding + the first arb — that is the
///         venue's designed rest state, not a mispriced init (see the hook NatSpec and
///         SECURITY_XAUT_WSTGBP.md; initializing at fair*(1-basis) instead would hardcode a basis
///         estimate and break the deviation assert below).
///
///         FUNDING IS A UI ACTION, not a script: the pool is a normal v4 AMM (the hook has no
///         liquidity callbacks), so the treasury Safe adds/collects/removes POL through the
///         Uniswap web app / canonical PositionManager like any pool
///         (`test/XautWstGbpPositionManager.t.sol` pins that exact path — spacing-60 bracket
///         shape for this high-vol venue; range selection in DEPLOY.md).
///
/// Env:    XAUT_HOOK  deployed hook address (required)
///
/// Usage:  XAUT_HOOK=<hook> make init-xaut-pool-dry / make init-xaut-pool
contract InitXautPool is Script {
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address internal constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    /// @dev High-vol pair (gold-in-GBP ~37% annualized): spacing 60 like the WETH venue — POL
    ///      brackets are wide here, so 60-tick (~0.6%) edge quantization is immaterial (the USDC
    ///      venue's spacing-1 tight-bracket rationale does not apply).
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant WAD = 1e18;
    /// @dev One whole XAUT (6 decimals) — the pool-side decimal fold, matching OracleLib.
    uint256 internal constant XAUT_UNIT = 1e6;
    /// @dev Same plausibility corridor as the deploy script (wstGBP per XAUT, WAD); FAIR_MIN also
    ///      rejects an orientation flip (see DeployXautHook — the inverse ≈ 4e14).
    uint256 internal constant FAIR_MIN = 500e18;
    uint256 internal constant FAIR_MAX = 20_000e18;

    function run() external returns (PoolKey memory key) {
        XautWstGbpHook hook = XautWstGbpHook(vm.envAddress("XAUT_HOOK"));

        // --- pre-flight ----------------------------------------------------------------------
        require(address(hook.wrapper()) == WSTGBP && hook.xaut() == XAUT, "InitXautPool: wrong hook");
        require(hook.owner() == MULTISIG, "InitXautPool: hook not multisig-owned");
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(XAU_USD_FEED), IAggregatorV3(GBP_USD_FEED), WSTGBP, 90_000, 90_000);
        require(reason == OracleLib.FallbackReason.NONE, "InitXautPool: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "InitXautPool: fair price implausible");

        (address c0, address c1) = WSTGBP < XAUT ? (WSTGBP, XAUT) : (XAUT, WSTGBP);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 sqrtPriceX96 = _fairSqrtPriceX96(fairWad, WSTGBP < XAUT);

        // --- init (reverts if the pool already exists — natural re-run guard) ------------------
        vm.startBroadcast();
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        // --- post-asserts ------------------------------------------------------------------------
        (uint160 sqrtNow, int24 tickNow,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(sqrtNow == sqrtPriceX96, "InitXautPool: slot0 mismatch");
        uint256 poolWad = OracleLib.poolPriceWstGbpPerXautWad(sqrtNow, WSTGBP < XAUT);
        int256 d = OracleLib.deviationPpm(poolWad, fairWad);
        require(uint256(d < 0 ? -d : d) < 1000, "InitXautPool: init deviation too large");

        console2.log("PoolId:", vm.toString(PoolId.unwrap(key.toId())));
        console2.log("init sqrtPriceX96:", sqrtPriceX96);
        console2.log("init tick:", vm.toString(tickNow));
        console2.log("fair (wstGBP per XAUT, WAD):", fairWad);
        console2.log("init deviation (ppm):", vm.toString(d));
        console2.log("NEXT: fund POL via the Uniswap UI (see DEPLOY.md, XAUT venue section).");
        console2.log("      Post-funding drift to d ~ -50bps vs the metal feed is the designed");
        console2.log("      rest state (token-metal basis), not an incident.");
    }

    /// @dev sqrtPriceX96 of a pool trading exactly at `fairWad` (wstGBP per XAUT): the raw pool
    ///      price (currency1 base units per currency0 base units) is XAUT_UNIT/fair when wstGBP is
    ///      currency0 — the 1e12 decimal gap folds into XAUT_UNIT exactly as in OracleLib.
    ///      (1e6 << 192 ≈ 6.3e63 — no overflow; at fair ~2400e18 the ratio is ~2.6e42.)
    function _fairSqrtPriceX96(uint256 fairWad, bool wstGbpIsCurrency0) internal pure returns (uint160) {
        uint256 ratioX192 = wstGbpIsCurrency0 ? (XAUT_UNIT << 192) / fairWad : ((fairWad << 96) / XAUT_UNIT) << 96;
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
