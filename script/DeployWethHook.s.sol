// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {WethWstGbpHook} from "../src/weth/WethWstGbpHook.sol";
import {FeeMath} from "../src/weth/lib/FeeMath.sol";
import {OracleLib} from "../src/weth/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";

/// @notice Mines + CREATE2-deploys the `WethWstGbpHook` (fee-only dynamic-fee hook for the
///         WETH/wstGBP pool) with the sim-recommended FeeParams (sim/RESULTS.md) baked into the
///         constructor and the Arb Capital multisig as owner FROM CONSTRUCTION — no deployer-owned
///         window, no post-deploy setter step, nothing to accept. Pool init is the separate
///         `InitWethPool.s.sol` and MUST follow IMMEDIATELY (init is permissionless and the
///         canonical PoolKey is predictable from the hook address — DEPLOY.md §3); Etherscan
///         verification comes AFTER init, via `make verify-weth-hook` (resumes this broadcast).
///
/// Usage:  make deploy-weth-hook-dry   (keyless mainnet-fork simulation)
///         ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> make deploy-weth-hook
///         then IMMEDIATELY:  WETH_HOOK=<hook> ... make init-weth-pool   (verify afterwards)
contract DeployWethHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    /// @dev Arb Capital multisig — `setFeeParams` / `setPaused` owner (Ownable2Step for any LATER
    ///      transfer; construction assigns directly).
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    /// @dev Composed-fair-price plausibility corridor (wstGBP per WETH, WAD): a decimals or
    ///      orientation bug lands orders of magnitude outside it.
    uint256 internal constant FAIR_MIN = 200e18;
    uint256 internal constant FAIR_MAX = 50_000e18;

    /// @dev sim/RESULTS.md "Recommended starting FeeParams" — regenerate with `make sim-sweep`
    ///      and update here if the recommendation moves before launch.
    function simParams() public pure returns (FeeMath.FeeParams memory p) {
        p = FeeMath.FeeParams({
            baseFeeMintSide: 3000,
            baseFeeRedeemSide: 500,
            minFee: 200,
            maxFee: 10_000,
            fallbackFee: 3000,
            deviationThresholdPpm: 1000,
            toxicitySlopePpm: 500_000,
            surchargeCapPpm: 6000,
            ethUsdStalenessSec: 4500,
            gbpUsdStalenessSec: 90_000
        });
    }

    function run() external returns (WethWstGbpHook hook) {
        FeeMath.FeeParams memory params = simParams();

        // --- pre-flight (view-only, before mining) -----------------------------------------
        require(MULTISIG.code.length > 0, "DeployWethHook: multisig has no code (wrong chain?)");
        require(IAggregatorV3(ETH_USD_FEED).decimals() == 8, "DeployWethHook: ETH/USD decimals");
        require(IAggregatorV3(GBP_USD_FEED).decimals() == 8, "DeployWethHook: GBP/USD decimals");
        // Compose the fair price through the SAME library the hook uses: both feeds fresh, the
        // wrapper NAV live, and the result inside the plausibility corridor.
        (uint256 fairWad, OracleLib.FallbackReason reason) = OracleLib.fairPriceWad(
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            WSTGBP,
            params.ethUsdStalenessSec,
            params.gbpUsdStalenessSec
        );
        require(reason == OracleLib.FallbackReason.NONE, "DeployWethHook: oracle not live");
        require(fairWad > FAIR_MIN && fairWad < FAIR_MAX, "DeployWethHook: fair price implausible");
        console2.log("composed fair (wstGBP per WETH, WAD):", fairWad);

        // --- mine + deploy -----------------------------------------------------------------
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(POOL_MANAGER),
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            Iwsgem(WSTGBP),
            WETH,
            params,
            MULTISIG
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WethWstGbpHook).creationCode, args);

        vm.startBroadcast();
        hook = new WethWstGbpHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            Iwsgem(WSTGBP),
            WETH,
            params,
            MULTISIG
        );
        vm.stopBroadcast();
        require(address(hook) == predicted, "DeployWethHook: mined address mismatch");

        // --- post-deploy asserts -------------------------------------------------------------
        // EXACT flag bits — a stray return-delta bit would break router-quotability.
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "DeployWethHook: unexpected permission bits");
        require(address(hook.ethUsdFeed()) == ETH_USD_FEED, "DeployWethHook: eth feed mismatch");
        require(address(hook.gbpUsdFeed()) == GBP_USD_FEED, "DeployWethHook: gbp feed mismatch");
        require(address(hook.wrapper()) == WSTGBP, "DeployWethHook: wrapper mismatch");
        require(hook.weth() == WETH, "DeployWethHook: weth mismatch");
        require(hook.wstGbpIsCurrency0() == (WSTGBP < WETH), "DeployWethHook: orientation mismatch");
        require(Currency.unwrap(hook.currency0()) == (WSTGBP < WETH ? WSTGBP : WETH), "DeployWethHook: c0");
        require(hook.owner() == MULTISIG, "DeployWethHook: owner mismatch");
        require(!hook.paused(), "DeployWethHook: deployed paused");
        _assertParams(hook, params);

        console2.log("WethWstGbpHook:", address(hook));
        console2.log("owner (multisig):", MULTISIG);
        console2.log("Next: run InitWethPool.s.sol IMMEDIATELY (init race, DEPLOY.md section 3);");
        console2.log("      Etherscan verify AFTERWARDS: make verify-weth-hook");
    }

    function _assertParams(WethWstGbpHook hook, FeeMath.FeeParams memory p) internal view {
        (
            uint24 baseMint,
            uint24 baseRedeem,
            uint24 minFee,
            uint24 maxFee,
            uint24 fallbackFee,
            uint24 threshold,
            uint24 slope,
            uint24 cap,
            uint24 ethWin,
            uint24 gbpWin
        ) = hook.feeParams();
        require(
            baseMint == p.baseFeeMintSide && baseRedeem == p.baseFeeRedeemSide && minFee == p.minFee
                && maxFee == p.maxFee && fallbackFee == p.fallbackFee && threshold == p.deviationThresholdPpm
                && slope == p.toxicitySlopePpm && cap == p.surchargeCapPpm && ethWin == p.ethUsdStalenessSec
                && gbpWin == p.gbpUsdStalenessSec,
            "DeployWethHook: feeParams mismatch"
        );
    }
}
