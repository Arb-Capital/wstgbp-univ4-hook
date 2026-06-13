// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {IwstGBP} from "../../src/core/interfaces/IwstGBP.sol";

/// @dev Permit2 exposes its EIP-712 domain separator for signing test permits.
interface IPermit2DomainSeparator {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title MaseerForkBase
/// @notice Venue-agnostic mainnet-fork scaffolding shared by every wstGBP swap venue (the v4 backstop hook
///         and the direct aggregator/solver adapter): it forks mainnet, forces the MaseerGate markets open,
///         and exposes the storage-slot constants plus the price/seed/permit helpers that drive the real
///         wstGBP/tGBP/oracle deterministically. Venue-specific scaffolding (deploying the hook + pool, or
///         the adapter) lives in subclasses.
/// @dev Prices are driven by `vm.store`-ing the wrapper's NAV slot (`PRICE_SLOT` on `wrapper.pip()`) and the
///      gate's spread slots (`BPSIN_SLOT`/`BPSOUT_SLOT` on `ACT`), then reading
///      `wrapper.mintcost()`/`burncost()` back as ground truth (see `MaseerGate`/`MaseerPrice`).
abstract contract MaseerForkBase is Test {
    address constant WST = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address constant TGBP = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;
    address constant ACT = 0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f;
    /// @dev Canonical Permit2, deployed at the same address on every chain.
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 constant OPEN_MINT = keccak256("maseer.gate.mint.open");
    bytes32 constant HALT_MINT = keccak256("maseer.gate.mint.halt");
    bytes32 constant OPEN_BURN = keccak256("maseer.gate.burn.open");
    bytes32 constant HALT_BURN = keccak256("maseer.gate.burn.halt");
    bytes32 constant COOLDOWN_SLOT = keccak256("maseer.gate.cooldown");
    bytes32 constant CAPACITY_SLOT = keccak256("maseer.gate.capacity");
    bytes32 constant BPSIN_SLOT = keccak256("maseer.gate.bpsin"); // ask spread (mintcost), on ACT
    bytes32 constant BPSOUT_SLOT = keccak256("maseer.gate.bpsout"); // bid spread (burncost), on ACT
    bytes32 constant PRICE_SLOT = keccak256("maseer.price.price"); // NAV slot in the MaseerPrice (pip) proxy

    uint256 constant WAD = 1e18;

    // Canonical Permit2 typehashes (for signing test permits).
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    IwstGBP wrapper = IwstGBP(WST);

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        _forceMarketOpen();
    }

    // --- wrapper state drivers ---

    function _forceMarketOpen() internal {
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

    /// @dev Deal `tgbpAmount` tGBP to the test contract and mint `mintAmount` wstGBP from it (the market
    ///      must already be open). Leaves the test contract holding the minted wstGBP plus the unspent tGBP.
    function _seedWst(uint256 tgbpAmount, uint256 mintAmount) internal {
        deal(TGBP, address(this), tgbpAmount);
        IERC20Minimal(TGBP).approve(WST, type(uint256).max);
        wrapper.mint(mintAmount);
    }

    // --- helpers ---

    /// @dev Sign a Permit2 `PermitTransferFrom` whose spender is `spender` (the venue that will call
    ///      `permitTransferFrom`). Reads the domain separator off the canonical Permit2.
    function _signPermitFor(uint256 pk, address spender, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig)
    {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, spender, nonce, deadline));
        bytes32 ds = IPermit2DomainSeparator(PERMIT2_ADDR).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return IERC20Minimal(token).balanceOf(who);
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
