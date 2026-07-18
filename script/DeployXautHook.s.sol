// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {XautWstGbpHook} from "../src/xaut/XautWstGbpHook.sol";
import {FeeMath} from "../src/xaut/lib/FeeMath.sol";
import {OracleLib} from "../src/xaut/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/xaut/interfaces/IAggregatorV3.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";
import {XautPoolInitBase, IXautBlocklist} from "./XautPoolInitBase.sol";

/// @notice Mines + CREATE2-deploys the `XautWstGbpHook` (fee-only dynamic-fee hook for the
///         XAUT/wstGBP pool) with the sim-recommended FeeParams (sim/RESULTS_XAUT.md) baked into
///         the constructor and the Arb Capital multisig as owner FROM CONSTRUCTION — no
///         deployer-owned window, no post-deploy setter step, nothing to accept. The same script
///         then initializes the canonical dynamic-fee pool at the deployed hook's oracle fair
///         price via the shared `XautPoolInitBase` core (the SAME code path the recovery-only
///         `InitXautPool.s.sol` runs, so the two can never diverge) and asserts the resulting
///         slot0. If hook deployment confirms but this script's initialization transaction is not
///         sent, recover by RESUMING this broadcast (`make deploy-xaut-hook-resume` — re-sends
///         only the pending tx, keeping the record complete for verify); the standalone
///         `InitXautPool.s.sol` is last-resort and breaks the verify resume (DEPLOY.md §X3).
///         Etherscan verification comes afterwards via `make verify-xaut-hook` (resumes this
///         broadcast).
///
/// Usage:  make deploy-xaut-hook-dry   (keyless mainnet-fork simulation)
///         ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> make deploy-xaut-hook
///         then: make verify-xaut-hook
contract DeployXautHook is XautPoolInitBase {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    /// @dev Fixed protocol parties that will hold or move XAUt for this venue — checked against the
    ///      token's issuer blocklist in pre-flight (SECURITY_XAUT_WSTGBP.md §8; the accepted issuer
    ///      surface, made executable). PositionManager + Permit2 are the POL-funding path.
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev EIP-1967 implementation slot — XAUt is an issuer-controlled upgradeable proxy; the
    ///      current implementation is logged so the deploy record pins what was reviewed.
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev The sim/RESULTS_XAUT.md winner (goldsim sweep 2026-07-16, PAXG gold leg): bases
    ///      (50,10) bps, threshold 1000 ppm, slope 1.0x, cap 100 bps — best worst-case rank
    ///      across all six regime×organic cells (max rank 7; next best 9). The threshold sits
    ///      BELOW the token–metal basis magnitude deliberately (grid designed at the ~5000 ppm
    ///      discount estimate): in the discount regime the redeem conveyor reads non-closing at
    ///      rest (never surcharged) and the sub-basis threshold turns the misclassified resting
    ///      mint side into surcharge revenue without starving the conveyor. The basis is
    ///      SIGN-UNSTABLE in live data (~11bp PREMIUM measured 2026-07-16): in the premium
    ///      regime the surcharged side flips to the conveyor (ramp, not cap) — confirmed
    ///      non-fragile across basis {-50,-25,0,25,50,100} bps and gas 0.2–25 gwei (RESULTS
    ///      sensitivity tables). The basis is SIGN-UNSTABLE in live data, so ranking runs exist
    ///      for BOTH regimes: this config wins the design-anchor run (basis 50) outright and is
    ///      the UNIQUE minimax winner across the union of both runs' cells (worst rank 7 vs 9
    ///      next-best; RESULTS_XAUT_BASIS0.md + readiness addendum). The basis-0 run alone picks
    ///      the thr=3000 sibling (rank 6 vs 7, worth $12–122 in the organic-0 bleed cells) —
    ///      which collapses to rank 39 in the discount regime and loses $1.3k–3.3k per
    ///      organic-1 cell, so it is not shipped. The production-params smoke test in
    ///      test/XautWstGbpHook.t.sol imports THIS function, value-generically.
    function simParams() public pure returns (FeeMath.FeeParams memory p) {
        p = FeeMath.FeeParams({
            baseFeeMintSide: 5000,
            baseFeeRedeemSide: 1000,
            minFee: 50,
            maxFee: 10_000,
            fallbackFee: 5000,
            deviationThresholdPpm: 1000,
            toxicitySlopePpm: 1_000_000,
            surchargeCapPpm: 10_000,
            xauUsdStalenessSec: 90_000,
            gbpUsdStalenessSec: 90_000
        });
    }

    function run() external returns (XautWstGbpHook hook) {
        FeeMath.FeeParams memory params = simParams();

        // --- pre-flight (view-only, before mining) -----------------------------------------
        require(MULTISIG.code.length > 0, "DeployXautHook: multisig has no code (wrong chain?)");
        require(IAggregatorV3(XAU_USD_FEED).decimals() == 8, "DeployXautHook: XAU/USD decimals");
        require(IAggregatorV3(GBP_USD_FEED).decimals() == 8, "DeployXautHook: GBP/USD decimals");
        require(IERC20Metadata(XAUT).decimals() == 6, "DeployXautHook: XAUT decimals");
        // XAUt issuer surface (SECURITY §8): none of the fixed protocol parties may be on the
        // token's blocklist, and the proxy implementation in force is logged for the deploy record.
        // Checked again manually before POL funding (DEPLOY.md §X). The recovery-only standalone
        // initializer repeats the checks because it may be run later than this deployment.
        require(!IXautBlocklist(XAUT).isBlocked(POOL_MANAGER), "DeployXautHook: PoolManager blocked by XAUt");
        require(!IXautBlocklist(XAUT).isBlocked(MULTISIG), "DeployXautHook: multisig blocked by XAUt");
        require(!IXautBlocklist(XAUT).isBlocked(POSITION_MANAGER), "DeployXautHook: PositionManager blocked by XAUt");
        require(!IXautBlocklist(XAUT).isBlocked(PERMIT2), "DeployXautHook: Permit2 blocked by XAUt");
        console2.log("XAUt proxy implementation:", address(uint160(uint256(vm.load(XAUT, EIP1967_IMPL_SLOT)))));
        // Compose the fair price through the SAME library the hook uses: feeds fresh, the wrapper
        // NAV live, and the result inside the plausibility corridor.
        (uint256 fairWad, OracleLib.FallbackReason reason) = OracleLib.fairPriceWad(
            IAggregatorV3(XAU_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            WSTGBP,
            params.xauUsdStalenessSec,
            params.gbpUsdStalenessSec
        );
        require(reason == OracleLib.FallbackReason.NONE, "DeployXautHook: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "DeployXautHook: fair price implausible");
        console2.log("composed fair (wstGBP per XAUT, WAD):", fairWad);

        // --- mine + deploy -----------------------------------------------------------------
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(POOL_MANAGER),
            IAggregatorV3(XAU_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            Iwsgem(WSTGBP),
            XAUT,
            params,
            MULTISIG
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(XautWstGbpHook).creationCode, args);

        vm.startBroadcast();
        hook = new XautWstGbpHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            IAggregatorV3(XAU_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            Iwsgem(WSTGBP),
            XAUT,
            params,
            MULTISIG
        );
        vm.stopBroadcast();
        require(address(hook) == predicted, "DeployXautHook: mined address mismatch");

        // --- post-deploy asserts -------------------------------------------------------------
        // EXACT flag bits — a stray return-delta bit would break router-quotability.
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "DeployXautHook: unexpected permission bits");
        require(address(hook.xauUsdFeed()) == XAU_USD_FEED, "DeployXautHook: xau feed mismatch");
        require(address(hook.gbpUsdFeed()) == GBP_USD_FEED, "DeployXautHook: gbp feed mismatch");
        require(address(hook.wrapper()) == WSTGBP, "DeployXautHook: wrapper mismatch");
        require(hook.xaut() == XAUT, "DeployXautHook: xaut mismatch");
        require(hook.wstGbpIsCurrency0() == (WSTGBP < XAUT), "DeployXautHook: orientation mismatch");
        require(Currency.unwrap(hook.currency0()) == (WSTGBP < XAUT ? WSTGBP : XAUT), "DeployXautHook: c0");
        require(hook.owner() == MULTISIG, "DeployXautHook: owner mismatch");
        require(!hook.paused(), "DeployXautHook: deployed paused");
        _assertParams(hook, params);

        // --- initialize canonical pool (shared core — see XautPoolInitBase) -----------------
        console2.log("XautWstGbpHook:", address(hook));
        console2.log("owner (multisig):", MULTISIG);
        _initPoolAtHookFair(hook);
        console2.log("Next: Etherscan verify: make verify-xaut-hook");
        console2.log("      then fund POL via the Uniswap UI (DEPLOY.md, XAUT venue section).");
    }

    function _assertParams(XautWstGbpHook hook, FeeMath.FeeParams memory p) internal view {
        (
            uint24 baseMint,
            uint24 baseRedeem,
            uint24 minFee,
            uint24 maxFee,
            uint24 fallbackFee,
            uint24 threshold,
            uint24 slope,
            uint24 cap,
            uint24 xauWin,
            uint24 gbpWin
        ) = hook.feeParams();
        require(
            baseMint == p.baseFeeMintSide && baseRedeem == p.baseFeeRedeemSide && minFee == p.minFee
                && maxFee == p.maxFee && fallbackFee == p.fallbackFee && threshold == p.deviationThresholdPpm
                && slope == p.toxicitySlopePpm && cap == p.surchargeCapPpm && xauWin == p.xauUsdStalenessSec
                && gbpWin == p.gbpUsdStalenessSec,
            "DeployXautHook: feeParams mismatch"
        );
    }
}
