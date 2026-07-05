// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {RpcUrl} from "./RpcUrl.sol";

/// @dev Permit2 exposes its EIP-712 domain separator for signing test permits.
interface IPermit2DomainSeparator {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title ForkBase
/// @notice Generic, token-agnostic mainnet-fork scaffolding shared by every wsgem swap venue (the v4
///         backstop hook and the direct aggregator/solver adapter): it forks mainnet and exposes the
///         Permit2 signing + balance/ceil helpers. The concrete token wiring — addresses, the wrapper's
///         gate/oracle storage slots, and the market/NAV/seed drivers — lives in a token-specific fixture
///         subclass (see {WstGBPFixture}), which implements `_forceMarketOpen` (invoked by `setUp`).
/// @dev Reuse for a new pair = add a sibling fixture (copy `WstGBPFixture`, swap the addresses/slots) and
///      point the venue bases at it.
abstract contract ForkBase is Test {
    /// @dev Canonical Permit2, deployed at the same address on every chain.
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 constant WAD = 1e18;

    // Canonical Permit2 typehashes (for signing test permits).
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    function setUp() public virtual {
        vm.createSelectFork(RpcUrl.resolve(vm));
        _forceMarketOpen();
    }

    /// @dev Force the wrapper's market open for deterministic fork tests. Implemented by the concrete
    ///      fixture, which knows the deployed gate's storage layout.
    function _forceMarketOpen() internal virtual;

    // --- generic helpers ---

    /// @dev Sign a Permit2 `PermitTransferFrom` whose spender is `spender` (the venue that will call
    ///      `permitTransferFrom`). Reads the domain separator off the canonical Permit2. The EIP-712 digest
    ///      is built in `_permitDigest` so this helper's live locals stay under the stack limit when
    ///      `forge coverage` compiles without the optimizer/viaIR.
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(spender, token, amount, nonce, deadline));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev The EIP-712 digest a Permit2 `PermitTransferFrom` signature must sign over.
    function _permitDigest(address spender, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, spender, nonce, deadline));
        bytes32 ds = IPermit2DomainSeparator(PERMIT2_ADDR).DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", ds, structHash));
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return IERC20Minimal(token).balanceOf(who);
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
