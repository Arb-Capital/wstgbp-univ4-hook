// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

import {WstGBPFixture} from "./WstGBPFixture.sol";
import {WsgemBackstopHook} from "../../src/v4/WsgemBackstopHook.sol";
import {WsgemSwapRouter} from "../../src/v4/periphery/WsgemSwapRouter.sol";
import {WsgemQuoter} from "../../src/v4/periphery/WsgemQuoter.sol";

/// @title WsgemForkBase
/// @notice v4-specific fork scaffolding: extends {WstGBPFixture} with the canonical PoolManager, mines +
///         deploys the backstop hook at a flag-encoded address, initializes the canonical gem/wsgem pool,
///         seeds the test contract with gem/wsgem, and exposes the settle-first swap/quote helpers. The
///         three v4 suites (feature, fuzz, invariant) inherit this.
/// @dev The token-specific half (addresses, gate/oracle slot constants, market/NAV/seed drivers) lives in
///      {WstGBPFixture}; the generic half (Permit2 signing, balance/ceil helpers) in {ForkBase}. This base
///      is pair-agnostic and reused as-is across fixtures.
abstract contract WsgemForkBase is WstGBPFixture {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    WsgemBackstopHook hook;
    WsgemSwapRouter router;
    WsgemQuoter quoter;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapFirstRouter;
    PoolKey key;

    receive() external payable {}

    function setUp() public virtual override {
        super.setUp(); // fork + force the wrapper's markets open

        router = new WsgemSwapRouter(PM);
        quoter = new WsgemQuoter(wrapper);
        lpRouter = new PoolModifyLiquidityTest(PM);
        swapFirstRouter = new PoolSwapTest(PM);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory args = abi.encode(PM, wrapper);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WsgemBackstopHook).creationCode, args);
        hook = new WsgemBackstopHook{salt: salt}(PM, wrapper);
        assertEq(address(hook), hookAddr, "mined address");

        // v4 sorts currencies ascending; sort so this base stays correct for any fixture's pair.
        (address c0, address c1) = GEM < WSGEM ? (GEM, WSGEM) : (WSGEM, GEM);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key, 79228162514264337593543950336);

        _seedWsgem(1_000_000 * WAD, 500_000 * WAD);

        IERC20Minimal(GEM).approve(address(router), type(uint256).max);
        IERC20Minimal(WSGEM).approve(address(router), type(uint256).max);
        IERC20Minimal(GEM).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(WSGEM).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(GEM).approve(address(swapFirstRouter), type(uint256).max);
    }

    // --- helpers ---

    /// @dev v4-flavoured `_signPermit`: the spender is always this pool's settle-first router. Preserves the
    ///      original 5-arg signature the v4 suites call.
    function _signPermit(uint256 pk, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig)
    {
        return _signPermitFor(pk, address(router), token, amount, nonce, deadline);
    }

    function _swapIn(bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        return router.swapExactInput(key, zeroForOne, amountIn, 0, address(this), block.timestamp);
    }

    function _swapOut(bool zeroForOne, uint256 amountOut, uint256 maxIn) internal returns (uint256) {
        return router.swapExactOutput(key, zeroForOne, amountOut, maxIn, address(this), block.timestamp);
    }

    function _assertHookClean() internal view {
        assertEq(_bal(GEM, address(hook)), 0, "hook holds no gem");
        assertEq(_bal(WSGEM, address(hook)), 0, "hook holds no wsgem");
    }
}
