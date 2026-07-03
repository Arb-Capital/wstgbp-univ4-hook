// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {WsgemHookHelper} from "../src/adapter/WsgemHookHelper.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";

/// @notice Deploys the `WsgemHookHelper` — the owner-bound wrap/unwrap target for CoW Protocol hooks
///         (plain CREATE; unlike the v4 hook there are no permission flags to mine). Asserts the I-02
///         cached-feed parity and that the helper is not on the tGBP ban list (it becomes the
///         mint/redeem caller, and pulls/pays the owner's tGBP/wstGBP).
///
/// Usage: ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> ETHERSCAN_API_KEY=<key> \
///        make deploy-hook-helper
///        (forge script script/DeployHookHelper.s.sol --rpc-url $ETH_RPC_URL --sender $ETH_FROM
///         --keystore $ETH_KEYSTORE --broadcast --slow --verify --etherscan-api-key $ETHERSCAN_API_KEY)
///
/// @dev Separate from `DeployWstGBP.s.sol` because the v1 system (hook/router/quoter/adapter) is already
///      live on mainnet; this adds the CoW-hooks venue after the fact. Token-specific: pins wstGBP.
contract DeployHookHelper is Script {
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;

    function run() external returns (WsgemHookHelper helper) {
        Iwsgem wrapper = Iwsgem(WSTGBP);

        vm.startBroadcast();
        helper = new WsgemHookHelper(wrapper);
        // The helper caches the wrapper's immutable `act`/`pip` feed proxies and prices unwraps directly
        // off them; assert they match the wrapper's so the cached reads can never diverge from it (I-02).
        require(address(helper.act()) == wrapper.act(), "DeployHookHelper: act feed mismatch");
        require(address(helper.pip()) == wrapper.pip(), "DeployHookHelper: pip feed mismatch");
        // The helper is the mint/redeem caller and the `transferFrom` spender of both tokens, so it must
        // not be ban-listed (blacklist, permissive default — no allowlisting needed).
        require(wrapper.canPass(address(helper)), "DeployHookHelper: helper is ban-listed");
        vm.stopBroadcast();

        console2.log("WsgemHookHelper:    ", address(helper));
        console2.log("wrapper (wstGBP):    ", WSTGBP);
        console2.log("gem (tGBP):          ", wrapper.gem());
        console2.log("CoW hooks: target the helper; owners approve it, output is owner-bound.");
    }
}
