// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {WsgemBackstopHook} from "../src/v4/WsgemBackstopHook.sol";
import {WsgemSwapRouter} from "../src/v4/periphery/WsgemSwapRouter.sol";
import {WsgemQuoter} from "../src/v4/periphery/WsgemQuoter.sol";
import {WsgemDirectAdapter} from "../src/adapter/WsgemDirectAdapter.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";

/// @notice Mines + CREATE2-deploys the `WsgemBackstopHook`, initializes the tGBP/wstGBP pool (fee 0,
///         tickSpacing 1, LP blocked), and deploys the settle-first router + quoter (the v4 venue) plus the
///         `WsgemDirectAdapter` (the non-v4 venue for DEX aggregators / CoW solvers — no flag mining, no
///         pool). Asserts the I-02 cached-feed parity for the hook, the quoter, AND the adapter, and that
///         the adapter is not on the tGBP ban list (it becomes the mint/redeem caller).
///
/// Usage: ETH_RPC_URL=<rpc> PK=<key> ETHERSCAN_API_KEY=<key> make deploy
///        (forge script script/DeployWstGBP.s.sol --rpc-url $ETH_RPC_URL --private-key $PK
///         --broadcast --slow --verify --etherscan-api-key $ETHERSCAN_API_KEY)
///
/// @dev This is the concrete, token-specific deploy: it pins the tGBP/wstGBP addresses. Future pairs get
///      their own sibling deploy script — the core `Wsgem*` contracts are generic and pair-agnostic.
contract DeployWstGBP is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    /// @dev sqrt(1) in Q64.96 — starting price inside the live band.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run()
        external
        returns (
            WsgemBackstopHook hook,
            WsgemSwapRouter router,
            WsgemQuoter quoter,
            WsgemDirectAdapter adapter,
            PoolKey memory key
        )
    {
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        Iwsgem wrapper = Iwsgem(WSTGBP);
        address tgbp = wrapper.gem();
        // v4 sorts pool currencies ascending. For tGBP/wstGBP this is (tgbp, wstGBP), but sort explicitly
        // so this script stays a correct template for a future pair whose wrapper sorts below its gem.
        (address currency0, address currency1) = tgbp < WSTGBP ? (tgbp, WSTGBP) : (WSTGBP, tgbp);

        // Backstop permissions: beforeSwap + beforeSwapReturnDelta (custom curve) + beforeAddLiquidity
        // (reverts to block LP) ⇒ flags 0x888. Pool fee 0 / tickSpacing 1 (no AMM, so no LP fee).
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WsgemBackstopHook).creationCode, abi.encode(pm, wrapper));

        vm.startBroadcast();
        hook = new WsgemBackstopHook{salt: salt}(pm, wrapper);
        require(address(hook) == predicted, "DeployWstGBP: mined address mismatch");

        // The hook caches the wrapper's immutable `act`/`pip` feed proxies and prices swaps directly off
        // them; assert they match the wrapper's so the cached reads can never diverge from it.
        require(address(hook.act()) == wrapper.act(), "DeployWstGBP: act feed mismatch");
        require(address(hook.pip()) == wrapper.pip(), "DeployWstGBP: pip feed mismatch");
        require(wrapper.canPass(address(hook)), "DeployWstGBP: hook is ban-listed");
        require(wrapper.canPass(POOL_MANAGER), "DeployWstGBP: pool manager is ban-listed");

        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pm.initialize(key, SQRT_PRICE_1_1);

        router = new WsgemSwapRouter(pm);
        quoter = new WsgemQuoter(wrapper);
        // The quoter caches the same `act`/`pip` feed proxies as the hook; assert at deploy time that they
        // match the wrapper's, so the quoter prices off the same feeds `wstGBP` reads (and the same ones
        // the hook executes against).
        require(address(quoter.act()) == wrapper.act(), "DeployWstGBP: quoter act feed mismatch");
        require(address(quoter.pip()) == wrapper.pip(), "DeployWstGBP: quoter pip feed mismatch");

        // The non-v4 venue: a standalone approve+swap adapter that calls `wstGBP.mint`/`redeem` directly,
        // for DEX aggregators / CoW solvers. No flag mining, no pool. Same cached-feed parity (I-02), and
        // it must not be ban-listed because it becomes the mint/redeem caller (blacklist, permissive default).
        adapter = new WsgemDirectAdapter(wrapper);
        require(address(adapter.act()) == wrapper.act(), "DeployWstGBP: adapter act feed mismatch");
        require(address(adapter.pip()) == wrapper.pip(), "DeployWstGBP: adapter pip feed mismatch");
        require(wrapper.canPass(address(adapter)), "DeployWstGBP: adapter is ban-listed");
        vm.stopBroadcast();

        console2.log("WsgemBackstopHook:  ", address(hook));
        console2.log("WsgemSwapRouter:    ", address(router));
        console2.log("WsgemQuoter:        ", address(quoter));
        console2.log("WsgemDirectAdapter: ", address(adapter));
        console2.log("currency0 (tGBP):    ", tgbp);
        console2.log("currency1 (wstGBP):  ", WSTGBP);
        console2.log("Pool initialized. v4: swap via WsgemSwapRouter (settle-first).");
        console2.log("Aggregators/CoW: swap via WsgemDirectAdapter (approve + swap).");
    }
}
