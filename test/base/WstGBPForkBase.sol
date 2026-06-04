// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {WstGBPBackstopHook} from "../../src/WstGBPBackstopHook.sol";
import {WstGBPSwapRouter} from "../../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPQuoter} from "../../src/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../../src/interfaces/IwstGBP.sol";

/// @dev Permit2 exposes its EIP-712 domain separator for signing test permits.
interface IPermit2DomainSeparator {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title WstGBPForkBase
/// @notice Shared mainnet-fork scaffolding for the backstop-hook test suites: it forks mainnet, forces
///         the MaseerGate markets open, mines+deploys the hook at a flag-encoded address, initializes the
///         canonical tGBP/wstGBP pool, and seeds the test contract with tGBP/wstGBP. Subclasses inherit
///         the addresses, storage-slot constants, and swap/quote/sign helpers.
/// @dev Extracted verbatim from the original `WstGBPBackstopHook.t.sol` setup so the existing suite and
///      the new fuzz/invariant suites share one source of truth. Prices are driven in tests by
///      `vm.store`-ing the wrapper's NAV slot (`PRICE_SLOT` on `wrapper.pip()`) and the gate's spread
///      slots (`BPSIN_SLOT`/`BPSOUT_SLOT` on `ACT`), then reading `wrapper.mintcost()`/`burncost()` back
///      as ground truth (see `MaseerGate`/`MaseerPrice`).
abstract contract WstGBPForkBase is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant WST = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address constant TGBP = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;
    address constant ACT = 0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f;

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
    WstGBPBackstopHook hook;
    WstGBPSwapRouter router;
    WstGBPQuoter quoter;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapFirstRouter;
    PoolKey key;

    receive() external payable {}

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        _forceMarketOpen();

        router = new WstGBPSwapRouter(PM);
        quoter = new WstGBPQuoter(wrapper);
        lpRouter = new PoolModifyLiquidityTest(PM);
        swapFirstRouter = new PoolSwapTest(PM);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory args = abi.encode(PM, wrapper);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WstGBPBackstopHook).creationCode, args);
        hook = new WstGBPBackstopHook{salt: salt}(PM, wrapper);
        assertEq(address(hook), hookAddr, "mined address");

        key = PoolKey({
            currency0: Currency.wrap(TGBP),
            currency1: Currency.wrap(WST),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key, 79228162514264337593543950336);

        deal(TGBP, address(this), 1_000_000 * WAD);
        IERC20Minimal(TGBP).approve(WST, type(uint256).max);
        wrapper.mint(500_000 * WAD);

        IERC20Minimal(TGBP).approve(address(router), type(uint256).max);
        IERC20Minimal(WST).approve(address(router), type(uint256).max);
        IERC20Minimal(TGBP).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(WST).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(TGBP).approve(address(swapFirstRouter), type(uint256).max);
    }

    // --- helpers ---

    function _signPermit(uint256 pk, address token, uint256 amount, uint256 nonce, uint256 deadline)
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
        // spender is the router (the caller of permitTransferFrom).
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, address(router), nonce, deadline));
        bytes32 ds = IPermit2DomainSeparator(address(router.PERMIT2())).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _swapIn(bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        return router.swapExactInput(key, zeroForOne, amountIn, 0, address(this), block.timestamp);
    }

    function _swapOut(bool zeroForOne, uint256 amountOut, uint256 maxIn) internal returns (uint256) {
        return router.swapExactOutput(key, zeroForOne, amountOut, maxIn, address(this), block.timestamp);
    }

    function _assertHookClean() internal view {
        assertEq(_bal(TGBP, address(hook)), 0, "hook holds no tGBP");
        assertEq(_bal(WST, address(hook)), 0, "hook holds no wstGBP");
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return IERC20Minimal(token).balanceOf(who);
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

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
}
