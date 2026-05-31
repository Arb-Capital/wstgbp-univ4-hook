// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {WstGBPHybridHook} from "../src/WstGBPHybridHook.sol";
import {WstGBPSwapRouter} from "../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPHybridQuoter} from "../src/periphery/WstGBPHybridQuoter.sol";
import {IwstGBP} from "../src/interfaces/IwstGBP.sol";

/// @notice Fork tests for the M2 hybrid hook: third-party LP + backstop, best execution.
contract WstGBPHybridHookForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

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
    uint24 constant FEE = 500; // 5bps to LPs
    int24 constant TS = 60;

    IwstGBP wrapper = IwstGBP(WST);
    WstGBPHybridHook hook;
    WstGBPSwapRouter router;
    WstGBPHybridQuoter hybridQuoter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        _forceMarketOpen();

        router = new WstGBPSwapRouter(PM);
        hybridQuoter = new WstGBPHybridQuoter(wrapper, PM);
        lpRouter = new PoolModifyLiquidityTest(PM);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(PM, wrapper);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WstGBPHybridHook).creationCode, args);
        hook = new WstGBPHybridHook{salt: salt}(PM, wrapper);
        assertEq(address(hook), hookAddr, "mined address");

        key = PoolKey({
            currency0: Currency.wrap(TGBP),
            currency1: Currency.wrap(WST),
            fee: FEE,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key, TickMath.getSqrtPriceAtTick(0)); // 1:1, inside the live band

        // fund
        deal(TGBP, address(this), 2_000_000 * WAD);
        IERC20Minimal(TGBP).approve(WST, type(uint256).max);
        wrapper.mint(1_000_000 * WAD);

        // approvals
        IERC20Minimal(TGBP).approve(address(router), type(uint256).max);
        IERC20Minimal(WST).approve(address(router), type(uint256).max);
        IERC20Minimal(TGBP).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(WST).approve(address(lpRouter), type(uint256).max);

        // third-party concentrated LP around the current price (deep, near 1:1)
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(1e24), salt: 0}), ""
        );

        vm.label(WST, "wstGBP");
        vm.label(TGBP, "tGBP");
        vm.label(address(hook), "HybridHook");
    }

    function test_buyBlendsLpThenBackstop() public {
        uint256 amtIn = 5_000 * WAD;
        uint256 backstopOnly = amtIn * WAD / wrapper.mintcost(); // what pure backstop (M1) would give
        (uint160 spBefore,,,) = PM.getSlot0(key.toId());

        uint256 w0 = _bal(WST, address(this));
        uint256 received = router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);

        (uint160 spAfter,,,) = PM.getSlot0(key.toId());
        assertEq(_bal(WST, address(this)) - w0, received, "router output");
        assertGt(received, backstopOnly, "blended price beats pure backstop (LP was used)");
        assertLt(spAfter, spBefore, "buy moved pool price down toward the edge (AMM ran)");
        assertApproxEqAbs(_bal(WST, address(hook)), 0, 1e12, "hook holds ~no wstGBP");
        assertApproxEqAbs(_bal(TGBP, address(hook)), 0, 1e12, "hook holds ~no tGBP");
    }

    function test_sellBlendsLpThenBackstop() public {
        uint256 amtIn = 5_000 * WAD;
        uint256 backstopOnly = amtIn * wrapper.burncost() / WAD;
        (uint160 spBefore,,,) = PM.getSlot0(key.toId());

        uint256 t0 = _bal(TGBP, address(this));
        uint256 received = router.swapExactInput(key, false, amtIn, 0, address(this), block.timestamp);

        (uint160 spAfter,,,) = PM.getSlot0(key.toId());
        assertEq(_bal(TGBP, address(this)) - t0, received, "router output");
        assertGt(received, backstopOnly, "blended price beats pure backstop (LP was used)");
        assertGt(spAfter, spBefore, "sell moved pool price up toward the edge (AMM ran)");
    }

    function test_buyExactOutputBlendsLpThenBackstop() public {
        uint256 amtOut = 5_000 * WAD;
        uint256 backstopOnlyIn = _ceil(amtOut * wrapper.mintcost(), WAD); // pure-backstop (M1) input
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));

        uint256 spent = router.swapExactOutput(key, true, amtOut, backstopOnlyIn, address(this), block.timestamp);

        assertEq(_bal(WST, address(this)) - w0, amtOut, "exact wstGBP out");
        assertEq(t0 - _bal(TGBP, address(this)), spent, "tGBP spent == router report");
        assertLt(spent, backstopOnlyIn, "blended input beats pure backstop (LP was used)");
        assertApproxEqAbs(_bal(WST, address(hook)), 0, 1e12, "hook holds ~no wstGBP");
        assertApproxEqAbs(_bal(TGBP, address(hook)), 0, 1e12, "hook holds ~no tGBP");
    }

    function test_sellExactOutputBlendsLpThenBackstop() public {
        uint256 amtOut = 5_000 * WAD;
        uint256 backstopOnlyIn = _ceil(amtOut * WAD, wrapper.burncost());
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));

        uint256 spent = router.swapExactOutput(key, false, amtOut, backstopOnlyIn, address(this), block.timestamp);

        assertEq(_bal(TGBP, address(this)) - t0, amtOut, "exact tGBP out");
        assertEq(w0 - _bal(WST, address(this)), spent, "wstGBP spent == router report");
        assertLt(spent, backstopOnlyIn, "blended input beats pure backstop (LP was used)");
    }

    /// @dev Price already past the edge (wstGBP more expensive than mintcost): the AMM is skipped
    ///      entirely (no revert), out-of-band LP is ignored, and the swap prices at the backstop.
    function test_pastEdgeSkipsAmmAndIgnoresOutOfBandLp() public {
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(TGBP),
            currency1: Currency.wrap(WST),
            fee: 3000, // distinct pool from the setUp pool
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key2, TickMath.getSqrtPriceAtTick(-120)); // wstGBP ~1.012 tGBP, above mintcost
        lpRouter.modifyLiquidity(
            key2, ModifyLiquidityParams({tickLower: -1200, tickUpper: 0, liquidityDelta: int256(1e23), salt: 0}), ""
        );

        uint256 amtIn = 5_000 * WAD;
        uint256 backstopOnly = amtIn * WAD / wrapper.mintcost();
        (uint160 spBefore,,,) = PM.getSlot0(key2.toId());

        uint256 received = router.swapExactInput(key2, true, amtIn, 0, address(this), block.timestamp);

        (uint160 spAfter,,,) = PM.getSlot0(key2.toId());
        assertEq(received, backstopOnly, "out-of-band LP ignored; exact backstop price");
        assertEq(spAfter, spBefore, "AMM untouched (pool price unchanged)");
    }

    /// @dev A swap far larger than in-band LP depth: consume the LP, then backstop the rest. No revert.
    function test_largeSwapBlendsDeepThenBackstops() public {
        uint256 amtIn = 500_000 * WAD;
        uint256 backstopOnly = amtIn * WAD / wrapper.mintcost();
        uint256 w0 = _bal(WST, address(this));

        uint256 received = router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);

        assertEq(_bal(WST, address(this)) - w0, received, "out");
        assertGt(received, backstopOnly, "blended (LP used) on a large swap");
        assertLt(received, amtIn, "sanity: price > 1");
        assertApproxEqAbs(_bal(WST, address(hook)), 0, 1e12, "hook clean");
    }

    /// @dev LPs earn the pool fee on the portion they fill (fee growth increases on the input token).
    function test_lpEarnsFee() public {
        (uint256 fg0Before,) = PM.getFeeGrowthGlobals(key.toId());
        router.swapExactInput(key, true, 5_000 * WAD, 0, address(this), block.timestamp); // buy: fee on tGBP (token0)
        (uint256 fg0After,) = PM.getFeeGrowthGlobals(key.toId());
        assertGt(fg0After, fg0Before, "LP earned fee on the tGBP input");
    }

    function test_buyRevertsWhenMintMarketClosed() public {
        vm.store(ACT, OPEN_MINT, bytes32(type(uint256).max));
        vm.expectRevert();
        router.swapExactInput(key, true, 50_000 * WAD, 0, address(this), block.timestamp); // needs backstop
    }

    function test_sellRevertsWhenWrapperUnderfunded() public {
        deal(TGBP, WST, 1 * WAD);
        vm.expectRevert();
        router.swapExactInput(key, false, 50_000 * WAD, 0, address(this), block.timestamp); // needs backstop redeem
    }

    /// @dev With no in-range LP, the hybrid must price exactly at the backstop edge — i.e. identical
    ///      to the pure-backstop M1 hook. This is what lets one hook subsume both.
    function test_noLpBehavesLikePureBackstop() public {
        // a second pool on the same hook, with NO liquidity added
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(TGBP),
            currency1: Currency.wrap(WST),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key2, TickMath.getSqrtPriceAtTick(0));

        uint256 amtIn = 1_000 * WAD;
        uint256 backstopOnly = amtIn * WAD / wrapper.mintcost();
        uint256 w0 = _bal(WST, address(this));

        uint256 received = router.swapExactInput(key2, true, amtIn, 0, address(this), block.timestamp);

        assertEq(_bal(WST, address(this)) - w0, received, "out");
        assertEq(received, backstopOnly, "no LP => exactly pure-backstop price (== M1)");
    }

    /// @notice Under a non-zero redemption cooldown the redeem backstop can't settle atomically, so a
    ///         hybrid SELL must fall back to pool liquidity only (no redeem) while BUYS keep
    ///         backstopping (mint is always atomic). Verified by the wrapper supply staying flat.
    function test_sellFallsBackToLpWhenCooldownActive() public {
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(1 days)));
        assertEq(wrapper.cooldown(), 1 days, "cooldown set");

        uint256 supplyBefore = wrapper.totalSupply();
        (uint160 spBefore,,,) = PM.getSlot0(key.toId());
        uint256 t0 = _bal(TGBP, address(this));

        uint256 received = router.swapExactInput(key, false, 1_000 * WAD, 0, address(this), block.timestamp);

        assertGt(received, 0, "sell filled from LP");
        assertEq(_bal(TGBP, address(this)) - t0, received, "router output");
        assertEq(wrapper.totalSupply(), supplyBefore, "no redeem occurred: LP only, wrapper untouched");
        (uint160 spAfter,,,) = PM.getSlot0(key.toId());
        assertGt(spAfter, spBefore, "AMM ran (sell moved pool price up)");

        // Buys still backstop atomically under cooldown (mint is unaffected).
        uint256 w0 = _bal(WST, address(this));
        uint256 bought = router.swapExactInput(key, true, 50_000 * WAD, 0, address(this), block.timestamp);
        assertGt(bought, 0, "buy still works under cooldown");
        assertEq(_bal(WST, address(this)) - w0, bought, "buy output");
    }

    /// @notice When the backstop is unavailable (cooldown) AND there is no LP, a sell cannot be served
    ///         — it must REVERT, never deliver less than asked. Exercises the router's slippage floor
    ///         (exact-in) and full-delivery enforcement (exact-out) so the swapper is never
    ///         short-changed. Buys still backstop.
    function test_cooldownSellWithNoLpRevertsNotShortChanged() public {
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(TGBP),
            currency1: Currency.wrap(WST),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key2, TickMath.getSqrtPriceAtTick(0));
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(1 days)));

        vm.expectRevert(); // exact-in: fills 0 from the empty pool, below the minOut floor
        router.swapExactInput(key2, false, 1_000 * WAD, 1, address(this), block.timestamp);

        vm.expectRevert(); // exact-out: delivers 0, below the enforced full-delivery amount
        router.swapExactOutput(key2, false, 1_000 * WAD, type(uint256).max, address(this), block.timestamp);

        uint256 w0 = _bal(WST, address(this));
        uint256 bought = router.swapExactInput(key2, true, 1_000 * WAD, 0, address(this), block.timestamp);
        assertGt(bought, 0, "buy backstops on the no-LP pool under cooldown");
        assertEq(_bal(WST, address(this)) - w0, bought, "buy output");
    }

    // --- LP-aware quoter: exact parity with blended execution ---

    function test_lpQuoteMatchesExecution_buyExactInput() public {
        uint256 amtIn = 5_000 * WAD;
        uint256 quoted = hybridQuoter.quoteExactInput(key, true, amtIn);
        uint256 received = router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);
        assertEq(received, quoted, "LP quote == execution (buy exact-in)");
    }

    function test_lpQuoteMatchesExecution_sellExactInput() public {
        uint256 amtIn = 5_000 * WAD;
        uint256 quoted = hybridQuoter.quoteExactInput(key, false, amtIn);
        uint256 received = router.swapExactInput(key, false, amtIn, 0, address(this), block.timestamp);
        assertEq(received, quoted, "LP quote == execution (sell exact-in)");
    }

    function test_lpQuoteMatchesExecution_buyExactOutput() public {
        uint256 amtOut = 5_000 * WAD;
        uint256 quotedIn = hybridQuoter.quoteExactOutput(key, true, amtOut);
        uint256 spent = router.swapExactOutput(key, true, amtOut, quotedIn + 100 * WAD, address(this), block.timestamp);
        assertEq(spent, quotedIn, "LP quote == execution (buy exact-out)");
    }

    function test_lpQuoteMatchesExecution_sellExactOutput() public {
        uint256 amtOut = 5_000 * WAD;
        uint256 quotedIn = hybridQuoter.quoteExactOutput(key, false, amtOut);
        uint256 spent = router.swapExactOutput(key, false, amtOut, quotedIn + 100 * WAD, address(this), block.timestamp);
        assertEq(spent, quotedIn, "LP quote == execution (sell exact-out)");
    }

    /// @dev A large swap that consumes deep LP across the band before backstopping — the most
    ///      tick-crossing-heavy path for the quoter's AMM replay to match.
    function test_lpQuoteMatchesExecution_largeBuy() public {
        uint256 amtIn = 600_000 * WAD;
        uint256 quoted = hybridQuoter.quoteExactInput(key, true, amtIn);
        uint256 received = router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);
        assertEq(received, quoted, "LP quote == execution (large buy)");
    }

    function testFuzz_lpQuoteMatchesExecution_buyExactInput(uint256 amtIn) public {
        amtIn = bound(amtIn, wrapper.mintcost(), 800_000 * WAD);
        uint256 quoted = hybridQuoter.quoteExactInput(key, true, amtIn);
        uint256 received = router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);
        assertEq(received, quoted, "fuzz LP quote == execution (buy exact-in)");
    }

    function testFuzz_lpQuoteMatchesExecution_sellExactInput(uint256 amtIn) public {
        amtIn = bound(amtIn, WAD, 300_000 * WAD);
        uint256 quoted = hybridQuoter.quoteExactInput(key, false, amtIn);
        uint256 received = router.swapExactInput(key, false, amtIn, 0, address(this), block.timestamp);
        assertEq(received, quoted, "fuzz LP quote == execution (sell exact-in)");
    }

    /// @dev With no in-range LP the hybrid quote must collapse to the pure backstop price.
    function test_lpQuoteMatchesBackstopWhenNoLp() public {
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(TGBP),
            currency1: Currency.wrap(WST),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key2, TickMath.getSqrtPriceAtTick(0));

        uint256 amtIn = 1_000 * WAD;
        assertEq(
            hybridQuoter.quoteExactInput(key2, true, amtIn), amtIn * WAD / wrapper.mintcost(), "no-LP buy == backstop"
        );
        assertEq(
            hybridQuoter.quoteExactInput(key2, false, amtIn), amtIn * wrapper.burncost() / WAD, "no-LP sell == backstop"
        );
        assertEq(
            hybridQuoter.quoteExactOutput(key2, true, amtIn),
            _ceil(amtIn * wrapper.mintcost(), WAD),
            "no-LP buy-out == backstop"
        );
        assertEq(
            hybridQuoter.quoteExactOutput(key2, false, amtIn),
            _ceil(amtIn * WAD, wrapper.burncost()),
            "no-LP sell-out == backstop"
        );
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IERC20Minimal(t).balanceOf(who);
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
