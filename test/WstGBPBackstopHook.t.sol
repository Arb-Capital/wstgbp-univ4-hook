// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {WstGBPBackstopHook} from "../src/WstGBPBackstopHook.sol";
import {WstGBPSwapRouter} from "../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPQuoter} from "../src/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../src/interfaces/IwstGBP.sol";

/// @notice Mainnet-fork tests for the pure-backstop hook (no LP) + the settle-first router & quoter.
contract WstGBPBackstopHookForkTest is Test {
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

    uint256 constant WAD = 1e18;

    IwstGBP wrapper = IwstGBP(WST);
    WstGBPBackstopHook hook;
    WstGBPSwapRouter router;
    WstGBPQuoter quoter;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapFirstRouter;
    PoolKey key;

    receive() external payable {}

    function setUp() public {
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

    // --- Pricing (buy @ mintcost, sell @ burncost) ---

    function test_buyExactInput() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_swapIn(true, amtIn), expectedOut, "router output");
        assertEq(_bal(TGBP, address(this)), t0 - amtIn, "exact tGBP spent");
        assertEq(_bal(WST, address(this)), w0 + expectedOut, "wstGBP at mintcost");
        _assertHookClean();
    }

    function test_buyExactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(amtOut * wrapper.mintcost(), WAD);
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_swapOut(true, amtOut, expectedIn + 10 * WAD), expectedIn, "input spent");
        assertEq(_bal(WST, address(this)), w0 + amtOut, "exact wstGBP out");
        assertEq(_bal(TGBP, address(this)), t0 - expectedIn, "tGBP paid (rounded up)");
    }

    function test_sellExactInput() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * wrapper.burncost() / WAD;
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_swapIn(false, amtIn), expectedOut, "router output");
        assertEq(_bal(WST, address(this)), w0 - amtIn, "exact wstGBP spent");
        assertEq(_bal(TGBP, address(this)), t0 + expectedOut, "tGBP at burncost");
        _assertHookClean();
    }

    function test_sellExactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(amtOut * WAD, wrapper.burncost());
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_swapOut(false, amtOut, expectedIn + 10 * WAD), expectedIn, "input spent");
        assertEq(_bal(TGBP, address(this)), t0 + amtOut, "exact tGBP out");
        assertEq(_bal(WST, address(this)), w0 - expectedIn, "wstGBP paid (rounded up)");
    }

    function test_roundTripSpreadIsAboutTwentyFiveBps() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 t0 = _bal(TGBP, address(this));
        uint256 wReceived = _swapIn(true, amtIn);
        _swapIn(false, wReceived);
        uint256 netLoss = t0 - _bal(TGBP, address(this));
        assertGe(netLoss, amtIn * 20 / 10_000, "spread >= ~20bps");
        assertLe(netLoss, amtIn * 30 / 10_000, "spread <= ~30bps");
    }

    // --- Quoter ---

    function test_quoterMatchesExecution_exactInput() public {
        uint256 amtIn = 1_000 * WAD;
        assertEq(quoter.quoteExactInput(true, amtIn), _swapIn(true, amtIn), "buy quote==exec");
        assertEq(quoter.quoteExactInput(false, amtIn), _swapIn(false, amtIn), "sell quote==exec");
    }

    function test_quoterMatchesExecution_exactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 qb = quoter.quoteExactOutput(true, amtOut);
        assertEq(_swapOut(true, amtOut, qb + 10 * WAD), qb, "buy out quote==exec");
        uint256 qs = quoter.quoteExactOutput(false, amtOut);
        assertEq(_swapOut(false, amtOut, qs + 10 * WAD), qs, "sell out quote==exec");
    }

    function test_previewSwapReportsExecutability() public {
        (,, bool ok, string memory r) = quoter.previewSwap(true, -int256(1_000 * WAD));
        assertTrue(ok);
        assertEq(bytes(r).length, 0);
        vm.store(ACT, OPEN_MINT, bytes32(type(uint256).max));
        (,, bool ok2, string memory r2) = quoter.previewSwap(true, -int256(1_000 * WAD));
        assertFalse(ok2);
        assertEq(r2, "mint market closed");
    }

    // --- Router hardening ---

    function test_minAmountOutEnforced() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = quoter.quoteExactInput(true, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WstGBPSwapRouter.InsufficientOutput.selector, q, q + 1));
        router.swapExactInput(key, true, amtIn, q + 1, address(this), block.timestamp);
    }

    function test_maxAmountInEnforced() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 q = quoter.quoteExactOutput(true, amtOut);
        vm.expectRevert();
        router.swapExactOutput(key, true, amtOut, q - 1, address(this), block.timestamp);
    }

    function test_deadlineEnforced() public {
        vm.expectRevert(WstGBPSwapRouter.Expired.selector);
        router.swapExactInput(key, true, 1_000 * WAD, 0, address(this), block.timestamp - 1);
    }

    function test_recipientReceivesOutput() public {
        address bob = address(0xB0B);
        uint256 amtIn = 1_000 * WAD;
        uint256 expected = quoter.quoteExactInput(true, amtIn);
        uint256 payerWst = _bal(WST, address(this));
        router.swapExactInput(key, true, amtIn, 0, bob, block.timestamp);
        assertEq(_bal(WST, bob), expected, "recipient got output");
        assertEq(_bal(WST, address(this)), payerWst, "payer got none");
    }

    function test_exactOutputRefundsSurplusToPayer() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 q = quoter.quoteExactOutput(true, amtOut);
        uint256 t0 = _bal(TGBP, address(this));
        assertEq(_swapOut(true, amtOut, q + 5_000 * WAD), q, "spent == quote");
        assertEq(_bal(TGBP, address(this)), t0 - q, "surplus refunded");
    }

    // --- Guards ---

    function test_addLiquidityReverts() public {
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1e18), salt: 0}), ""
        );
    }

    function test_swapRevertsWhenMintMarketClosed() public {
        vm.store(ACT, OPEN_MINT, bytes32(type(uint256).max));
        vm.expectRevert();
        _swapIn(true, 1_000 * WAD);
    }

    function test_sellRevertsWhenWrapperUnderfunded() public {
        deal(TGBP, WST, 1 * WAD);
        vm.expectRevert();
        _swapIn(false, 1_000 * WAD);
    }

    function test_swapFirstRoutingIsUnsupported() public {
        vm.expectRevert();
        swapFirstRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1_000_000 * WAD),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // --- helpers ---

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
}
