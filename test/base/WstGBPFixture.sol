// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {Iwsgem} from "../../src/core/interfaces/Iwsgem.sol";
import {ForkBase} from "./ForkBase.sol";

/// @title WstGBPFixture
/// @notice The concrete, token-specific fork fixture: it pins the mainnet tGBP/wstGBP addresses and the
///         deployed wrapper's gate/oracle storage-slot keys, and implements the market/NAV/seed drivers
///         that drive the real wstGBP/tGBP/oracle deterministically. This is the test-side analog of the
///         deploy script — the single place that names the concrete pair. A future pair gets its own
///         sibling fixture; the generic {ForkBase} and the venue bases are reused unchanged.
/// @dev Prices are driven by `vm.store`-ing the wrapper's NAV slot (`PRICE_SLOT` on `wrapper.pip()`) and the
///      gate's spread slots (`BPSIN_SLOT`/`BPSOUT_SLOT` on `ACT`), then reading
///      `wrapper.mintcost()`/`burncost()` back as ground truth.
abstract contract WstGBPFixture is ForkBase {
    address constant WSGEM = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE; // wstGBP (the wrapper token)
    address constant GEM = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287; // tGBP (the underlying)
    address constant ACT = 0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f; // the market-timing/fee feed

    // Storage-slot keys of the deployed wrapper's gate/oracle feeds. These strings are the live external
    // contracts' OWN slot keys (used directly by `vm.store`); they MUST stay byte-identical to the on-chain
    // layout, so they are not renamed even though the rest of the codebase drops the legacy naming.
    bytes32 constant OPEN_MINT = keccak256("maseer.gate.mint.open");
    bytes32 constant HALT_MINT = keccak256("maseer.gate.mint.halt");
    bytes32 constant OPEN_BURN = keccak256("maseer.gate.burn.open");
    bytes32 constant HALT_BURN = keccak256("maseer.gate.burn.halt");
    bytes32 constant COOLDOWN_SLOT = keccak256("maseer.gate.cooldown");
    bytes32 constant CAPACITY_SLOT = keccak256("maseer.gate.capacity");
    bytes32 constant BPSIN_SLOT = keccak256("maseer.gate.bpsin"); // ask spread (mintcost), on ACT
    bytes32 constant BPSOUT_SLOT = keccak256("maseer.gate.bpsout"); // bid spread (burncost), on ACT
    bytes32 constant PRICE_SLOT = keccak256("maseer.price.price"); // NAV slot in the oracle (pip) feed proxy

    Iwsgem wrapper = Iwsgem(WSGEM);

    // --- wrapper state drivers ---

    function _forceMarketOpen() internal override {
        vm.store(ACT, OPEN_MINT, bytes32(uint256(0)));
        vm.store(ACT, HALT_MINT, bytes32(type(uint256).max));
        vm.store(ACT, OPEN_BURN, bytes32(uint256(0)));
        vm.store(ACT, HALT_BURN, bytes32(type(uint256).max));
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(0)));
        vm.store(ACT, CAPACITY_SLOT, bytes32(type(uint256).max));
    }

    /// @dev Set the wrapper's NAV (oracle price), recomputing `mintcost()`/`burncost()` from it.
    function _setNav(uint256 nav) internal {
        vm.store(wrapper.pip(), PRICE_SLOT, bytes32(nav));
    }

    /// @dev Set the ask (mint) / bid (burn) spreads in basis points (each <= 10_000 in the real gate).
    function _setSpreads(uint256 bpsin, uint256 bpsout) internal {
        vm.store(ACT, BPSIN_SLOT, bytes32(bpsin));
        vm.store(ACT, BPSOUT_SLOT, bytes32(bpsout));
    }

    /// @dev Deal `gemAmount` gem to the test contract and mint `mintAmount` wsgem from it (the market
    ///      must already be open). Leaves the test contract holding the minted wsgem plus the unspent gem.
    function _seedWsgem(uint256 gemAmount, uint256 mintAmount) internal {
        deal(GEM, address(this), gemAmount);
        IERC20Minimal(GEM).approve(WSGEM, type(uint256).max);
        wrapper.mint(mintAmount);
    }
}
