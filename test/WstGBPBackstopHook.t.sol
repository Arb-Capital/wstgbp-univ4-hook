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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {WstGBPBackstopHook} from "../src/WstGBPBackstopHook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {WstGBPSwapRouter} from "../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPQuoter} from "../src/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../src/interfaces/IwstGBP.sol";
import {IMaseerAct, IMaseerPip} from "../src/interfaces/IMaseerFeeds.sol";

interface IPermit2DomainSeparator {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev MaseerOne exposes its immutable compliance feed via a public `cop()` getter (not in IwstGBP).
interface IHasCop {
    function cop() external view returns (address);
}

/// @notice Mainnet-fork tests for the pure-backstop hook (no LP) + the settle-first router & quoter.
contract WstGBPBackstopHookForkTest is Test {
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
    bytes32 constant BPSIN_SLOT = keccak256("maseer.gate.bpsin");
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

    /// @notice F1 regression: a non-zero redemption cooldown makes `wstGBP.redeem` defer payout, so a
    ///         sell would burn the seller's wstGBP for ~0 tGBP. With `minAmountOut == 0` there is no
    ///         slippage backstop, so the hook itself must revert (`RedeemUnderpaid`) for both
    ///         exact-in and exact-out sells; buys are unaffected, and the quoter flags it off-chain.
    function test_sellRevertsWhenRedeemCooldownActive() public {
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(1 days)));
        assertEq(wrapper.cooldown(), 1 days, "cooldown set");

        (,, bool executable, string memory reason) = quoter.previewSwap(false, -int256(1_000 * WAD));
        assertFalse(executable, "preview not executable under cooldown");
        assertEq(reason, "redeem cooldown active", "preview reason");

        // Both sell directions revert instead of silently delivering ~0 output (minAmountOut == 0).
        vm.expectRevert();
        _swapIn(false, 1_000 * WAD);
        vm.expectRevert();
        _swapOut(false, 1_000 * WAD, 2_000 * WAD);

        // Buys mint atomically regardless of redemption cooldown.
        assertEq(_swapIn(true, 1_000 * WAD), 1_000 * WAD * WAD / wrapper.mintcost(), "buy unaffected");
        _assertHookClean();
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

    // --- Capacity ---

    /// @notice A buy whose mint would push total supply past `capacity()` must revert (wrapper
    ///         `ExceedsCap`), and the quoter must flag it; a buy within the headroom still works.
    function test_buyRevertsWhenCapacityExceeded() public {
        uint256 headroom = 100 * WAD;
        vm.store(ACT, CAPACITY_SLOT, bytes32(wrapper.totalSupply() + headroom));

        (,, bool executable, string memory reason) = quoter.previewSwap(true, -int256(1_000 * WAD));
        assertFalse(executable, "preview not executable past capacity");
        assertEq(reason, "exceeds capacity", "preview reason");

        vm.expectRevert();
        _swapIn(true, 1_000 * WAD); // mints ~1000/mintcost wstGBP >> 100 headroom

        assertGt(_swapIn(true, 50 * WAD), 0, "buy within the capacity headroom still works");
    }

    /// @notice L-02 regression: an exact-output buy rounds the tGBP input UP, so `wrapper.mint` mints
    ///         strictly more wstGBP than the requested `amountOut` whenever `mintcost < WAD`. The
    ///         capacity preview must gate on that *minted* amount, not on the requested output — else it
    ///         reports `executable = true` at a tight capacity boundary while execution reverts in mint.
    ///         The live NAV is > par, so we drive it sub-par (pip price slot + zero ask spread) to
    ///         materialize the overshoot deterministically.
    function test_previewCapacityUsesMintedNotRequestedOutput() public {
        // Sub-par NAV with no ask spread => mintcost == nav < WAD, so the rounded-up exact-out input
        // mints more wstGBP than requested.
        vm.store(ACT, BPSIN_SLOT, bytes32(uint256(0)));
        vm.store(wrapper.pip(), PRICE_SLOT, bytes32(uint256(0.5e18)));
        uint256 mc = wrapper.mintcost();
        assertLt(mc, WAD, "forced sub-par mintcost");

        uint256 amountOut = 1_000 * WAD + 1; // non-whole so the ceil-rounded input overshoots the mint
        uint256 amountIn = quoter.quoteExactOutput(true, amountOut);
        uint256 minted = FullMath.mulDiv(amountIn, WAD, mc); // == wrapper.mint(amountIn)
        assertGt(minted, amountOut, "exact-out buy mints strictly more than requested");

        // Capacity sits exactly at the requested-output boundary: the OLD check (vs amountOut) passes,
        // but the real mint (vs minted) is one unit over.
        vm.store(ACT, CAPACITY_SLOT, bytes32(wrapper.totalSupply() + amountOut));
        (,, bool executable, string memory reason) = quoter.previewSwap(true, int256(amountOut));
        assertFalse(executable, "preview must gate on the minted amount, not the requested output");
        assertEq(reason, "exceeds capacity", "reason");

        // Execution indeed reverts at this capacity (wrapper ExceedsCap inside mint).
        vm.expectRevert();
        router.swapExactOutput(key, true, amountOut, amountIn + 10 * WAD, address(this), block.timestamp);

        // Give capacity for the full minted amount and the preview flips to executable.
        vm.store(ACT, CAPACITY_SLOT, bytes32(wrapper.totalSupply() + minted));
        (,, bool ok2,) = quoter.previewSwap(true, int256(amountOut));
        assertTrue(ok2, "executable once capacity covers the minted amount");
    }

    /// @notice I-02 regression: the hook caches the wrapper's immutable `act`/`pip` feed proxies at
    ///         construction and prices swaps directly off them (skipping the wrapper dispatch hop). Assert
    ///         the cached proxies equal the wrapper's and that the cached-feed prices equal the wrapper
    ///         facade prices, so that optimization can never silently diverge from `wstGBP` itself.
    function test_cachedFeedsMatchWrapper() public view {
        assertEq(address(hook.act()), wrapper.act(), "act proxy == wrapper.act()");
        assertEq(address(hook.pip()), wrapper.pip(), "pip proxy == wrapper.pip()");
        IMaseerAct a = hook.act();
        uint256 nav = hook.pip().read();
        assertEq(a.mintcost(nav), wrapper.mintcost(), "cached mintcost == facade");
        assertEq(a.burncost(nav), wrapper.burncost(), "cached burncost == facade");
        assertEq(a.cooldown(), wrapper.cooldown(), "cached cooldown == facade");
    }

    // --- Fuzz: quoter == execution and the hook is left clean, across all four modes ---

    function testFuzz_buyExactInputMatchesQuoter(uint256 amtIn) public {
        amtIn = bound(amtIn, wrapper.mintcost(), 200_000 * WAD);
        uint256 w0 = _bal(WST, address(this));
        uint256 got = _swapIn(true, amtIn);
        assertEq(got, quoter.quoteExactInput(true, amtIn), "buy exact-in == quoter");
        assertEq(_bal(WST, address(this)) - w0, got, "recipient received output");
        _assertHookClean();
    }

    function testFuzz_sellExactInputMatchesQuoter(uint256 amtIn) public {
        amtIn = bound(amtIn, WAD, 100_000 * WAD);
        uint256 t0 = _bal(TGBP, address(this));
        uint256 got = _swapIn(false, amtIn);
        assertEq(got, quoter.quoteExactInput(false, amtIn), "sell exact-in == quoter");
        assertEq(_bal(TGBP, address(this)) - t0, got, "recipient received output");
        _assertHookClean();
    }

    function testFuzz_buyExactOutputMatchesQuoter(uint256 amtOut) public {
        amtOut = bound(amtOut, 2 * WAD, 100_000 * WAD);
        uint256 expectedIn = quoter.quoteExactOutput(true, amtOut);
        uint256 w0 = _bal(WST, address(this));
        uint256 spent = _swapOut(true, amtOut, expectedIn);
        assertEq(spent, expectedIn, "buy exact-out input == quoter");
        assertEq(_bal(WST, address(this)) - w0, amtOut, "recipient received exact output");
        assertLe(_bal(WST, address(hook)), 2, "hook keeps <= ~1 wei wstGBP dust");
        assertEq(_bal(TGBP, address(hook)), 0, "hook holds no tGBP");
    }

    function testFuzz_sellExactOutputMatchesQuoter(uint256 amtOut) public {
        amtOut = bound(amtOut, 2 * WAD, 50_000 * WAD);
        uint256 expectedIn = quoter.quoteExactOutput(false, amtOut);
        uint256 t0 = _bal(TGBP, address(this));
        uint256 spent = _swapOut(false, amtOut, expectedIn);
        assertEq(spent, expectedIn, "sell exact-out input == quoter");
        assertEq(_bal(TGBP, address(this)) - t0, amtOut, "recipient received exact output");
        assertLe(_bal(TGBP, address(hook)), 2, "hook keeps <= ~1 wei tGBP dust");
        assertEq(_bal(WST, address(hook)), 0, "hook holds no wstGBP");
    }

    // --- Router events (B3) ---

    function test_routerEmitsSwapEvent() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        vm.expectEmit(true, true, true, true, address(router));
        emit WstGBPSwapRouter.Swap(address(this), address(this), key.toId(), true, amtIn, expectedOut);
        router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);
    }

    // --- Permit2 entrypoints (A2) ---

    function test_permit2_buyExactInput() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 1_000 * WAD;
        address permit2 = address(router.PERMIT2()); // resolve before pranking (it's an external call)
        deal(TGBP, alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(TGBP).approve(permit2, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(pk, TGBP, amtIn, 0, block.timestamp + 1 hours);

        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        vm.prank(alice);
        uint256 out = router.swapExactInputPermit2(key, true, amtIn, expectedOut, alice, permit, sig);

        assertEq(out, expectedOut, "permit2 buy == backstop price");
        assertEq(_bal(WST, alice), out, "alice received wstGBP");
        assertEq(_bal(TGBP, alice), 0, "alice spent exact tGBP via permit2 (no router approval)");
    }

    function test_permit2_sellExactOutput() public {
        uint256 pk = 0xA11CE; // a code-free EOA (Permit2 uses ecrecover, not EIP-1271)
        address bob = vm.addr(pk);
        vm.etch(bob, ""); // belt-and-suspenders: ensure no code so the ecrecover path is taken
        uint256 tOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(tOut * WAD, wrapper.burncost());
        uint256 maxIn = expectedIn + 5 * WAD;
        address permit2 = address(router.PERMIT2()); // resolve before pranking (it's an external call)
        IERC20Minimal(WST).transfer(bob, maxIn); // fund bob from the test contract's wstGBP
        vm.prank(bob);
        IERC20Minimal(WST).approve(permit2, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(pk, WST, maxIn, 0, block.timestamp + 1 hours);

        uint256 w0 = _bal(WST, bob);
        vm.prank(bob);
        uint256 spent = router.swapExactOutputPermit2(key, false, tOut, maxIn, bob, permit, sig);

        assertEq(spent, expectedIn, "permit2 sell input == backstop price");
        assertEq(_bal(TGBP, bob), tOut, "bob received exact tGBP");
        assertEq(w0 - _bal(WST, bob), spent, "permit2 surplus refunded to bob");
    }

    // --- Tiny exact-out reverts on the pure backstop (F3 / C7) ---

    function test_tinyExactOutputRevertsOnBackstop() public {
        // Wrapper minimums are 1 wstGBP to mint / 1 to burn; a sub-1-unit exact-out can't be served and
        // the pure backstop has no LP to fall back to, so it reverts on the wrapper dust threshold.
        vm.expectRevert();
        router.swapExactOutput(key, true, 0.5e18, 100 * WAD, address(this), block.timestamp); // buy < 1 wstGBP
        vm.expectRevert();
        router.swapExactOutput(key, false, 0.5e18, 100 * WAD, address(this), block.timestamp); // sell, wIn < 1 wstGBP
    }

    // --- Red-team pass (2026-06-03) ---

    /// @notice L-02 (red-team): a paused oracle reads as a zero NAV, so `mintcost()`/`burncost()` are 0 and
    ///         the quote arithmetic would divide by zero. `previewSwap` must degrade gracefully —
    ///         `(executable=false, "oracle paused")` for all four modes — instead of reverting.
    function test_previewSwapHandlesPausedOracle() public {
        vm.store(wrapper.pip(), PRICE_SLOT, bytes32(uint256(0)));
        assertEq(wrapper.mintcost(), 0, "paused mintcost == 0");
        assertEq(wrapper.burncost(), 0, "paused burncost == 0");

        _assertOraclePaused(true, -int256(1_000 * WAD)); // buy exact-in
        _assertOraclePaused(true, int256(1_000 * WAD)); // buy exact-out
        _assertOraclePaused(false, -int256(1_000 * WAD)); // sell exact-in
        _assertOraclePaused(false, int256(1_000 * WAD)); // sell exact-out
    }

    /// @notice M-01 (red-team): the wstGBP compliance gate (`cop.pass`, a permissive blacklist) is applied
    ///         to every mint/redeem/transfer. Banning the *hook* makes `wrapper.mint`/`redeem` revert, so
    ///         every swap reverts with no owner/recovery path — a third-party kill-switch over the whole
    ///         pool. Banning the *PoolManager* also bricks buys: the hook settles wstGBP to the PM, and
    ///         `wstGBP.transfer` gates the destination through `cop.pass`.
    function test_blacklistBricksPool() public {
        address cop = IHasCop(WST).cop();
        assertGt(_swapIn(true, 100 * WAD), 0, "buy works before any ban");

        // Ban the hook => both directions revert (mint and redeem both gate on cop.pass(msg.sender=hook)).
        vm.mockCall(cop, abi.encodeWithSignature("pass(address)", address(hook)), abi.encode(false));
        vm.expectRevert();
        _swapIn(true, 1_000 * WAD);
        vm.expectRevert();
        _swapIn(false, 1_000 * WAD);
        vm.clearMockedCalls();

        // Ban the PoolManager => buys revert at the settle transfer (wstGBP.transfer to a banned dst).
        vm.mockCall(cop, abi.encodeWithSignature("pass(address)", address(PM)), abi.encode(false));
        vm.expectRevert();
        _swapIn(true, 1_000 * WAD);
    }

    /// @notice M-02 (red-team): the hook executes at the live oracle price with NO intrinsic slippage or
    ///         price-sanity check — protection lives entirely in the caller. Prove both halves: a router
    ///         swap with a real `minAmountOut` reverts when the price moves adverse, while the same swap
    ///         with `minAmountOut == 0` executes at the worse price and the buyer simply eats it.
    function test_hookAppliesNoSlippageCallerMustBound() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 fairOut = quoter.quoteExactInput(true, amtIn);

        // Move NAV up ~10% (adverse to a buyer: higher mintcost => less wstGBP out).
        uint256 nav0 = wrapper.navprice();
        vm.store(wrapper.pip(), PRICE_SLOT, bytes32(nav0 * 110 / 100));
        uint256 worseOut = quoter.quoteExactInput(true, amtIn);
        assertLt(worseOut, fairOut, "price moved adverse to the buyer");

        // Caller-enforced slippage DOES protect: demanding the pre-move output reverts at the router.
        vm.expectRevert(abi.encodeWithSelector(WstGBPSwapRouter.InsufficientOutput.selector, worseOut, fairOut));
        router.swapExactInput(key, true, amtIn, fairOut, address(this), block.timestamp);

        // The hook itself applies NONE: `minAmountOut == 0` executes at the worse live price.
        uint256 got = router.swapExactInput(key, true, amtIn, 0, address(this), block.timestamp);
        assertEq(got, worseOut, "executes at the live (worse) price; no hook-level guard");
        _assertHookClean();
    }

    /// @notice I-04 (red-team): the hook's callbacks are gated by `onlyPoolManager`, so nothing — including
    ///         a hostile token mid-mint/redeem — can re-enter `beforeSwap`/`beforeAddLiquidity` directly;
    ///         only the PoolManager can drive them. (A hostile-token reentrancy harness was judged
    ///         disproportionate: the real tGBP/wstGBP have no transfer callback, and the actual protections
    ///         are this access-control guard plus the zero-net delta accounting the other tests assert.)
    function test_hookCallbacksRejectNonPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 * WAD), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(this),
            key,
            ModifyLiquidityParams({tickLower: -1, tickUpper: 1, liquidityDelta: int256(1), salt: 0}),
            ""
        );
    }

    // --- helpers ---

    function _assertOraclePaused(bool zeroForOne, int256 amountSpecified) internal view {
        (uint256 amountIn, uint256 amountOut, bool executable, string memory reason) =
            quoter.previewSwap(zeroForOne, amountSpecified);
        assertFalse(executable, "paused oracle => not executable");
        assertEq(reason, "oracle paused", "paused reason");
        assertEq(amountIn, 0, "paused amountIn == 0");
        assertEq(amountOut, 0, "paused amountOut == 0");
    }

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
}
