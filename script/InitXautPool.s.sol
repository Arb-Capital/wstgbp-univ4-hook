// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {XautWstGbpHook} from "../src/xaut/XautWstGbpHook.sol";
import {XautPoolInitBase, IXautBlocklist} from "./XautPoolInitBase.sol";

/// @notice LAST-RESORT RECOVERY: the normal `DeployXautHook` flow initializes the pool itself,
///         and if its initialization tx goes unsent the FIRST recovery is resuming that broadcast
///         (`make deploy-xaut-hook-resume`). Use this standalone script only when that broadcast
///         record is unusable (lost, or its recorded fair has drifted) — initializing here leaves
///         the deploy broadcast's init tx pending, so `make verify-xaut-hook` (--resume) will
///         fail afterwards; verify the hook directly with `forge verify-contract
///         --guess-constructor-args` (DEPLOY.md §X3). Creates the XAUT/wstGBP dynamic-fee pool AT
///         THE ORACLE FAIR PRICE via the shared `XautPoolInitBase` core — literally the SAME code
///         path the deploy script runs (hook-derived feeds + staleness windows, same PoolKey and
///         sqrt/tick math, same post-asserts), so recovery cannot diverge from the normal flow —
///         and nothing else. No funds move; any address can run it, once.
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
contract InitXautPool is XautPoolInitBase {
    function run() external returns (PoolKey memory key) {
        XautWstGbpHook hook = XautWstGbpHook(vm.envAddress("XAUT_HOOK"));

        // --- pre-flight ----------------------------------------------------------------------
        require(address(hook.wrapper()) == WSTGBP && hook.xaut() == XAUT, "InitXautPool: wrong hook");
        require(hook.owner() == MULTISIG, "InitXautPool: hook not multisig-owned");
        // XAUt issuer surface (SECURITY §8): re-check the blocklist immediately before init — the
        // deploy-time check may be stale by now, and POL funding follows this step.
        require(!IXautBlocklist(XAUT).isBlocked(POOL_MANAGER), "InitXautPool: PoolManager blocked by XAUt");
        require(!IXautBlocklist(XAUT).isBlocked(MULTISIG), "InitXautPool: multisig blocked by XAUt");

        // --- init (shared core; reverts if the pool already exists — natural re-run guard) -----
        key = _initPoolAtHookFair(hook);

        console2.log("NEXT: fund POL via the Uniswap UI (see DEPLOY.md, XAUT venue section;");
        console2.log("      re-run the XAUt blocklist checks there immediately before funding).");
        console2.log("      Post-funding drift to |d| <~ 50bps vs the metal feed (EITHER side -");
        console2.log("      the token-metal basis is sign-unstable) is the designed rest state,");
        console2.log("      not an incident.");
    }
}
