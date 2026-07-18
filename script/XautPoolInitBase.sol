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

/// @notice Shared canonical-pool-initialization core for the XAUT/wstGBP venue scripts. The normal
///         `DeployXautHook` flow and the recovery-only `InitXautPool` MUST initialize identically
///         (same PoolKey, same hook-derived oracle fair, same sqrt/tick math, same post-asserts),
///         so the whole routine lives here once — a retune edit cannot diverge the two paths.
abstract contract XautPoolInitBase is Script {
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    /// @dev Arb Capital multisig — `setFeeParams` / `setPaused` owner (Ownable2Step for any LATER
    ///      transfer; construction assigns directly).
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    /// @dev High-vol pair (gold-in-GBP ~37% annualized): spacing 60 like the WETH venue — POL
    ///      brackets are wide here, so 60-tick (~0.6%) edge quantization is immaterial (the USDC
    ///      venue's spacing-1 tight-bracket rationale does not apply).
    int24 internal constant TICK_SPACING = 60;
    /// @dev One whole XAUT (6 decimals) — the pool-side decimal fold, matching OracleLib.
    uint256 internal constant XAUT_UNIT = 1e6;
    /// @dev Composed-fair-price plausibility corridor (wstGBP per XAUT, WAD): fair sits in the low
    ///      thousands-e18 (gold ~$2,300–3,100 in GBP·NAV terms at 2026 values). A missed
    ///      1e6/1e8/1e12 decimal bug lands many orders of magnitude outside; FAIR_MIN = 500e18 also
    ///      catches an ORIENTATION flip (the inverse, XAUT-per-wstGBP, is ~4e14 — six orders below
    ///      the floor). Unlike the USDC venue there is no near-1:1 ambiguity, so the corridor is
    ///      deliberately wide: MIN covers gold down to ~$680 at cable·NAV ≈ 1.37, MAX up to ~$27k.
    uint256 internal constant FAIR_MIN = 500e18;
    uint256 internal constant FAIR_MAX = 20_000e18;

    /// @dev Initializes the canonical dynamic-fee pool AT THE ORACLE FAIR PRICE, composed through
    ///      the same OracleLib the hook prices with, USING THE DEPLOYED HOOK'S OWN feed addresses
    ///      and staleness windows (read from `hook.xauUsdFeed()/gbpUsdFeed()/feeParams()`, never
    ///      duplicated — a retuned deploy cannot drift out from under init), then re-reads slot0
    ///      and asserts |deviation| < 1000 ppm. NOTE the post-asserts run in forge's pre-broadcast
    ///      SIMULATION, not against the mined chain — the on-chain confirmation is the DEPLOY.md
    ///      §X3½ read-backs.
    function _initPoolAtHookFair(XautWstGbpHook hook) internal returns (PoolKey memory key) {
        (,,,,,,,, uint24 xauWin, uint24 gbpWin) = hook.feeParams();
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(hook.xauUsdFeed(), hook.gbpUsdFeed(), address(hook.wrapper()), xauWin, gbpWin);
        require(reason == OracleLib.FallbackReason.NONE, "XautPoolInit: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "XautPoolInit: fair price implausible");

        (address c0, address c1) = WSTGBP < XAUT ? (WSTGBP, XAUT) : (XAUT, WSTGBP);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 sqrtPriceX96 = _fairSqrtPriceX96(fairWad, WSTGBP < XAUT);

        // Reverts if the pool already exists — natural re-run guard.
        vm.startBroadcast();
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        (uint160 sqrtNow, int24 tickNow,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(sqrtNow == sqrtPriceX96, "XautPoolInit: slot0 mismatch");
        uint256 poolWad = OracleLib.poolPriceWstGbpPerXautWad(sqrtNow, WSTGBP < XAUT);
        int256 d = OracleLib.deviationPpm(poolWad, fairWad);
        require(uint256(d < 0 ? -d : d) < 1000, "XautPoolInit: init deviation too large");

        console2.log("PoolId:", vm.toString(PoolId.unwrap(key.toId())));
        console2.log("init sqrtPriceX96:", sqrtPriceX96);
        console2.log("init tick:", vm.toString(tickNow));
        console2.log("fair (wstGBP per XAUT, WAD):", fairWad);
        console2.log("init deviation (ppm):", vm.toString(d));
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
