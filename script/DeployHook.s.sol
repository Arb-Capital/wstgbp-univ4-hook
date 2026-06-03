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
import {WstGBPSwapRouter} from "../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPQuoter} from "../src/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../src/interfaces/IwstGBP.sol";

/// @notice Mines + CREATE2-deploys the `WstGBPBackstopHook`, initializes the tGBP/wstGBP pool (fee 0,
///         tickSpacing 1, LP blocked), and deploys the settle-first router and quoter integrators use.
///
/// Usage: forge script script/DeployHook.s.sol --rpc-url $ETH_RPC_URL --broadcast --private-key $PK
contract DeployHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    /// @dev sqrt(1) in Q64.96 — starting price inside the live band.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run()
        external
        returns (WstGBPBackstopHook hook, WstGBPSwapRouter router, WstGBPQuoter quoter, PoolKey memory key)
    {
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        IwstGBP wrapper = IwstGBP(WSTGBP);
        address tgbp = wrapper.gem();

        // Backstop permissions: beforeSwap + beforeSwapReturnDelta (custom curve) + beforeAddLiquidity
        // (reverts to block LP) ⇒ flags 0x888. Pool fee 0 / tickSpacing 1 (no AMM, so no LP fee).
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WstGBPBackstopHook).creationCode, abi.encode(pm, wrapper));

        vm.startBroadcast();
        hook = new WstGBPBackstopHook{salt: salt}(pm, wrapper);
        require(address(hook) == predicted, "DeployHook: mined address mismatch");

        // I-02 guard: the hook caches the wrapper's immutable `act`/`pip` feed proxies and prices swaps
        // directly off them. Assert they equal the wrapper's so the cached-feed optimization can never
        // diverge from the wrapper facade at deploy time.
        require(address(hook.act()) == wrapper.act(), "DeployHook: act feed mismatch");
        require(address(hook.pip()) == wrapper.pip(), "DeployHook: pip feed mismatch");

        key = PoolKey({
            currency0: Currency.wrap(tgbp),
            currency1: Currency.wrap(WSTGBP),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pm.initialize(key, SQRT_PRICE_1_1);

        router = new WstGBPSwapRouter(pm);
        quoter = new WstGBPQuoter(wrapper);
        vm.stopBroadcast();

        console2.log("WstGBPBackstopHook:", address(hook));
        console2.log("WstGBPSwapRouter:  ", address(router));
        console2.log("WstGBPQuoter:      ", address(quoter));
        console2.log("currency0 (tGBP):  ", tgbp);
        console2.log("currency1 (wstGBP):", WSTGBP);
        console2.log("Pool initialized. Swap via WstGBPSwapRouter (settle-first).");
    }
}
