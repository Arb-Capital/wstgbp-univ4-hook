// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {WstGBPBackstopHook} from "../src/WstGBPBackstopHook.sol";
import {WstGBPHybridHook} from "../src/WstGBPHybridHook.sol";
import {WstGBPSwapRouter} from "../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPQuoter} from "../src/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../src/interfaces/IwstGBP.sol";

/// @notice Mines + CREATE2-deploys a hook, initializes the tGBP/wstGBP pool, and deploys the
///         settle-first router and quoter integrators use.
///
/// Choose the hook with env `HOOK`:
///   - `HOOK=hybrid` (default): `WstGBPHybridHook` — in-band LP first, backstop the rest (fee 5bps).
///   - `HOOK=backstop`: `WstGBPBackstopHook` — pure backstop, LP blocked (fee 0).
///
/// Usage: forge script script/DeployHook.s.sol --rpc-url $ETH_RPC_URL --broadcast --private-key $PK
contract DeployHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    /// @dev sqrt(1) in Q64.96 — starting price inside the live band.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external returns (address hook, WstGBPSwapRouter router, WstGBPQuoter quoter, PoolKey memory key) {
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        IwstGBP wrapper = IwstGBP(WSTGBP);
        address tgbp = wrapper.gem();

        bool hybrid = keccak256(bytes(vm.envOr("HOOK", string("hybrid")))) == keccak256(bytes("hybrid"));

        // Hybrid allows LP (flags 0x88); backstop blocks it (flags 0x888 with beforeAddLiquidity).
        uint160 flags = hybrid
            ? uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
            : uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory creationCode = hybrid ? type(WstGBPHybridHook).creationCode : type(WstGBPBackstopHook).creationCode;
        (uint24 fee, int24 tickSpacing) = hybrid ? (uint24(500), int24(60)) : (uint24(0), int24(1));

        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, abi.encode(pm, wrapper));

        vm.startBroadcast();
        hook = hybrid
            ? address(new WstGBPHybridHook{salt: salt}(pm, wrapper))
            : address(new WstGBPBackstopHook{salt: salt}(pm, wrapper));
        require(hook == predicted, "DeployHook: mined address mismatch");

        key = PoolKey({
            currency0: Currency.wrap(tgbp),
            currency1: Currency.wrap(WSTGBP),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        pm.initialize(key, SQRT_PRICE_1_1);

        router = new WstGBPSwapRouter(pm);
        quoter = new WstGBPQuoter(wrapper);
        vm.stopBroadcast();

        console2.log(hybrid ? "WstGBPHybridHook:  " : "WstGBPBackstopHook:", hook);
        console2.log("WstGBPSwapRouter:  ", address(router));
        console2.log("WstGBPQuoter:      ", address(quoter));
        console2.log("currency0 (tGBP):  ", tgbp);
        console2.log("currency1 (wstGBP):", WSTGBP);
        console2.log("Pool initialized. Swap via WstGBPSwapRouter (settle-first).");
    }
}
