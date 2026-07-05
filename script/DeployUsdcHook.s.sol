// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {UsdcWstGbpHook} from "../src/usdc/UsdcWstGbpHook.sol";
import {FeeMath} from "../src/usdc/lib/FeeMath.sol";
import {OracleLib} from "../src/usdc/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/usdc/interfaces/IAggregatorV3.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";

/// @notice Mines + CREATE2-deploys the `UsdcWstGbpHook` (fee-only dynamic-fee hook for the
///         wstGBP/USDC pool) with the sim-recommended FeeParams (sim/RESULTS_USDC.md) baked into
///         the constructor and the Arb Capital multisig as owner FROM CONSTRUCTION — no
///         deployer-owned window, no post-deploy setter step, nothing to accept. Pool init is the
///         separate `InitUsdcPool.s.sol` and MUST follow IMMEDIATELY (init is permissionless and
///         the canonical PoolKey is predictable from the hook address — DEPLOY.md); Etherscan
///         verification comes AFTER init, via `make verify-usdc-hook` (resumes this broadcast).
///
/// Usage:  make deploy-usdc-hook-dry   (keyless mainnet-fork simulation)
///         ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> make deploy-usdc-hook
///         then IMMEDIATELY:  USDC_HOOK=<hook> ... make init-usdc-pool   (verify afterwards)
contract DeployUsdcHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    /// @dev Arb Capital multisig — `setFeeParams` / `setPaused` owner (Ownable2Step for any LATER
    ///      transfer; construction assigns directly).
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    /// @dev Composed-fair-price plausibility corridor (wstGBP per USDC, WAD): today's fair sits at
    ///      ~0.75e18; the corridor covers GBP/USD in [$0.67, $2.50] at NAV in [1.0, 1.1], while a
    ///      missed 1e6/1e8/1e12 decimal or orientation bug lands 6+ orders of magnitude outside.
    uint256 internal constant FAIR_MIN = 0.4e18;
    uint256 internal constant FAIR_MAX = 1.5e18;

    /// @dev sim/RESULTS_USDC.md "Recommended starting FeeParams" (2026-07-05 cable sweep, robust
    ///      worst-case-rank winner across 6 regime×organic cells; conveyor stays alive — ~40% of
    ///      the static-5 control's redeem volume at >2x its house take) — regenerate with
    ///      `make sim-sweep-usdc` and update here if the recommendation moves before launch.
    ///      Slope 1.0x (not the WETH venue's 0.5x demotion): splitting-erosion is gas-bounded at
    ///      this venue's small conveyor notionals (SECURITY_USDC_WSTGBP.md §1), and 0.5x ranks
    ///      16-23 in the trend-2025 cells. fallbackFee = mint-side base: fail-safe idles the
    ///      conveyor during oracle outages instead of subsidizing toxic flow.
    function simParams() public pure returns (FeeMath.FeeParams memory p) {
        p = FeeMath.FeeParams({
            baseFeeMintSide: 3000,
            baseFeeRedeemSide: 500,
            minFee: 50,
            maxFee: 10_000,
            fallbackFee: 3000,
            deviationThresholdPpm: 1000,
            toxicitySlopePpm: 1_000_000,
            surchargeCapPpm: 6000,
            gbpUsdStalenessSec: 90_000
        });
    }

    function run() external returns (UsdcWstGbpHook hook) {
        FeeMath.FeeParams memory params = simParams();

        // --- pre-flight (view-only, before mining) -----------------------------------------
        require(MULTISIG.code.length > 0, "DeployUsdcHook: multisig has no code (wrong chain?)");
        require(IAggregatorV3(GBP_USD_FEED).decimals() == 8, "DeployUsdcHook: GBP/USD decimals");
        require(IERC20Metadata(USDC).decimals() == 6, "DeployUsdcHook: USDC decimals");
        // Compose the fair price through the SAME library the hook uses: feed fresh, the wrapper
        // NAV live, and the result inside the plausibility corridor.
        (uint256 fairWad, OracleLib.FallbackReason reason) =
            OracleLib.fairPriceWad(IAggregatorV3(GBP_USD_FEED), WSTGBP, params.gbpUsdStalenessSec);
        require(reason == OracleLib.FallbackReason.NONE, "DeployUsdcHook: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "DeployUsdcHook: fair price implausible");
        console2.log("composed fair (wstGBP per USDC, WAD):", fairWad);

        // --- mine + deploy -----------------------------------------------------------------
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args =
            abi.encode(IPoolManager(POOL_MANAGER), IAggregatorV3(GBP_USD_FEED), Iwsgem(WSTGBP), USDC, params, MULTISIG);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(UsdcWstGbpHook).creationCode, args);

        vm.startBroadcast();
        hook = new UsdcWstGbpHook{salt: salt}(
            IPoolManager(POOL_MANAGER), IAggregatorV3(GBP_USD_FEED), Iwsgem(WSTGBP), USDC, params, MULTISIG
        );
        vm.stopBroadcast();
        require(address(hook) == predicted, "DeployUsdcHook: mined address mismatch");

        // --- post-deploy asserts -------------------------------------------------------------
        // EXACT flag bits — a stray return-delta bit would break router-quotability.
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "DeployUsdcHook: unexpected permission bits");
        require(address(hook.gbpUsdFeed()) == GBP_USD_FEED, "DeployUsdcHook: gbp feed mismatch");
        require(address(hook.wrapper()) == WSTGBP, "DeployUsdcHook: wrapper mismatch");
        require(hook.usdc() == USDC, "DeployUsdcHook: usdc mismatch");
        require(hook.wstGbpIsCurrency0() == (WSTGBP < USDC), "DeployUsdcHook: orientation mismatch");
        require(Currency.unwrap(hook.currency0()) == (WSTGBP < USDC ? WSTGBP : USDC), "DeployUsdcHook: c0");
        require(hook.owner() == MULTISIG, "DeployUsdcHook: owner mismatch");
        require(!hook.paused(), "DeployUsdcHook: deployed paused");
        _assertParams(hook, params);

        console2.log("UsdcWstGbpHook:", address(hook));
        console2.log("owner (multisig):", MULTISIG);
        console2.log("Next: run InitUsdcPool.s.sol IMMEDIATELY (init race, DEPLOY.md);");
        console2.log("      Etherscan verify AFTERWARDS: make verify-usdc-hook");
    }

    function _assertParams(UsdcWstGbpHook hook, FeeMath.FeeParams memory p) internal view {
        (
            uint24 baseMint,
            uint24 baseRedeem,
            uint24 minFee,
            uint24 maxFee,
            uint24 fallbackFee,
            uint24 threshold,
            uint24 slope,
            uint24 cap,
            uint24 gbpWin
        ) = hook.feeParams();
        require(
            baseMint == p.baseFeeMintSide && baseRedeem == p.baseFeeRedeemSide && minFee == p.minFee
                && maxFee == p.maxFee && fallbackFee == p.fallbackFee && threshold == p.deviationThresholdPpm
                && slope == p.toxicitySlopePpm && cap == p.surchargeCapPpm && gbpWin == p.gbpUsdStalenessSec,
            "DeployUsdcHook: feeParams mismatch"
        );
    }
}
