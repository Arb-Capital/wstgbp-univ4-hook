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

/// @dev XAUt (Tether Gold) issuer-blocklist probe — `isBlocked` verified live 2026-07-16
///      (the legacy-Tether `isBlackListed`/`getBlackListStatus` selectors revert on this token).
interface IXautBlocklist {
    function isBlocked(address account) external view returns (bool);
}

/// @notice INIT-ONLY: creates the XAUT/wstGBP dynamic-fee pool AT THE ORACLE FAIR PRICE — composed
///         through the same OracleLib the hook prices with, USING THE DEPLOYED HOOK'S OWN feed
///         addresses and staleness windows (read from `hook.xauUsdFeed()/gbpUsdFeed()/feeParams()`,
///         never duplicated here — a retuned deploy can't drift out from under this script), so
///         on-chain deviation is ~0 at init by construction — and nothing else. No funds move; any
///         address can run it, once.
///
///         The oracle fair is METAL-priced: after funding + the first arb the pool drifts to
///         d ≈ -basis, the token–metal gap. The basis is small and SIGN-UNSTABLE (~+50bp discount
///         estimated 2026-07-11; ~11bp premium — XAUt ABOVE the feed — measured 2026-07-16), so the
///         rest state may sit either side of zero; both regimes are priced in the sweep
///         (sim/RESULTS_XAUT.md extended basis table; see the hook NatSpec and
///         SECURITY_XAUT_WSTGBP.md §6). Initializing at fair*(1-basis) instead would hardcode a
///         basis estimate and break the deviation assert below.
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
        // XAUt issuer surface (SECURITY §8): re-check the blocklist immediately before init — the
        // deploy-time check may be stale by now, and POL funding follows this step.
        require(!IXautBlocklist(XAUT).isBlocked(POOL_MANAGER), "InitXautPool: PoolManager blocked by XAUt");
        require(!IXautBlocklist(XAUT).isBlocked(MULTISIG), "InitXautPool: multisig blocked by XAUt");
        // Price with the deployed hook's OWN oracle configuration (feeds + staleness windows) so
        // init can never diverge from what the hook will price with (review finding 2026-07-16).
        (,,,,,,,, uint24 xauWin, uint24 gbpWin) = hook.feeParams();
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(hook.xauUsdFeed(), hook.gbpUsdFeed(), address(hook.wrapper()), xauWin, gbpWin);
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
        console2.log("NEXT: fund POL via the Uniswap UI (see DEPLOY.md, XAUT venue section;");
        console2.log("      re-run the XAUt blocklist checks there immediately before funding).");
        console2.log("      Post-funding drift to |d| <~ 50bps vs the metal feed (EITHER side -");
        console2.log("      the token-metal basis is sign-unstable) is the designed rest state,");
        console2.log("      not an incident.");
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
