// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
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

/// @notice Mines + CREATE2-deploys the `XautWstGbpHook` (fee-only dynamic-fee hook for the
///         XAUT/wstGBP pool) with the sim-recommended FeeParams (sim/RESULTS_XAUT.md) baked into
///         the constructor and the Arb Capital multisig as owner FROM CONSTRUCTION — no
///         deployer-owned window, no post-deploy setter step, nothing to accept. Pool init is the
///         separate `InitXautPool.s.sol` and MUST follow IMMEDIATELY (init is permissionless and
///         the canonical PoolKey is predictable from the hook address — DEPLOY.md); Etherscan
///         verification comes AFTER init, via `make verify-xaut-hook` (resumes this broadcast).
///
/// Usage:  make deploy-xaut-hook-dry   (keyless mainnet-fork simulation)
///         ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> make deploy-xaut-hook
///         then IMMEDIATELY:  XAUT_HOOK=<hook> ... make init-xaut-pool   (verify afterwards)
contract DeployXautHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address internal constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    /// @dev Arb Capital multisig — `setFeeParams` / `setPaused` owner (Ownable2Step for any LATER
    ///      transfer; construction assigns directly).
    address internal constant MULTISIG = 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c;

    /// @dev Composed-fair-price plausibility corridor (wstGBP per XAUT, WAD): fair sits in the low
    ///      thousands-e18 (gold ~$2,300–3,100 in GBP·NAV terms at 2026 values). A missed
    ///      1e6/1e8/1e12 decimal bug lands many orders of magnitude outside; FAIR_MIN = 500e18 also
    ///      catches an ORIENTATION flip (the inverse, XAUT-per-wstGBP, is ~4e14 — six orders below
    ///      the floor). Unlike the USDC venue there is no near-1:1 ambiguity, so the corridor is
    ///      deliberately wide: MIN covers gold down to ~$680 at cable·NAV ≈ 1.37, MAX up to ~$27k.
    uint256 internal constant FAIR_MIN = 500e18;
    uint256 internal constant FAIR_MAX = 20_000e18;

    /// @dev The sim/RESULTS_XAUT.md winner (goldsim sweep 2026-07-16, PAXG gold leg): bases
    ///      (50,10) bps, threshold 1000 ppm, slope 1.0x, cap 100 bps — best worst-case rank
    ///      across all six regime×organic cells (max rank 7; next best 9). The threshold sits
    ///      BELOW the ~5000 ppm token–metal basis deliberately: the redeem conveyor reads
    ///      non-closing at the rest state (never surcharged), so a sub-basis threshold turns the
    ///      misclassified resting mint side into surcharge revenue without starving the conveyor —
    ///      confirmed non-fragile across basis {0,25,50,100} bps and gas 0.2–25 gwei (RESULTS
    ///      sensitivity tables). The production-params smoke test in test/XautWstGbpHook.t.sol
    ///      imports THIS function, value-generically.
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

        console2.log("XautWstGbpHook:", address(hook));
        console2.log("owner (multisig):", MULTISIG);
        console2.log("Next: run InitXautPool.s.sol IMMEDIATELY (init race, DEPLOY.md);");
        console2.log("      Etherscan verify AFTERWARDS: make verify-xaut-hook");
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
