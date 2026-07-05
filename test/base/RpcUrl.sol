// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Single home for the fork-RPC resolution, so every fork suite — including the standalone
///         flipped-ordering ones that deliberately skip the {ForkBase} fixture chain — honors the
///         same precedence: explicit `ETH_RPC_URL` > `ALCHEMY_API_KEY`-composed Alchemy endpoint
///         (forge auto-loads a project-root `.env`) > the public fallback. The Makefile mirrors
///         this chain for make-invoked child processes.
library RpcUrl {
    function resolve(Vm vm) internal view returns (string memory) {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length > 0) return url;
        string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(key).length > 0) return string.concat("https://eth-mainnet.g.alchemy.com/v2/", key);
        return "https://ethereum-rpc.publicnode.com";
    }
}
