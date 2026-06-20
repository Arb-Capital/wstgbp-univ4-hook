// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {WsgemForkBase} from "./base/WsgemForkBase.sol";

/// @notice Stateless adversarial suite: lifts the four-mode quoter/execution parity across the WHOLE
///         oracle price range (the existing fuzz tests only run at the single forked NAV), pins down the
///         exact-output rounding/over-charge bounds, proves round-trips can never profit, proves a donated
///         hook balance can neither subsidize pricing nor be drained, and checks the extreme-price /
///         out-of-range inputs fail cleanly instead of corrupting a delta. Prices are driven by `vm.store`
///         on the wrapper's NAV/spread slots; the live `mintcost()`/`burncost()` are read back as truth.
contract WsgemBackstopHookFuzzTest is WsgemForkBase {
    // Wide NAV band for the parity sweep: 0.01 .. 100 gem per wsgem (WAD). Outputs stay within int128
    // and inputs within the (generously dealt) actor balance across this whole band.
    uint256 internal constant NAV_LO = 0.01e18;
    uint256 internal constant NAV_HI = 100e18;
    uint256 internal constant SWAP_CAP = 100_000 * 1e18;

    // -----------------------------------------------------------------------
    // Quoter == execution across the whole price range (all four modes)
    // -----------------------------------------------------------------------

    /// @notice The single highest-value addition: quoter == execution for every mode at ANY oracle price,
    ///         with the hook left clean (exact-in) or holding only price-bounded exact-out dust.
    function testFuzz_quoterMatchesExecutionAcrossPrices(uint256 navSeed, uint256 amt, uint8 mode) public {
        _setNav(bound(navSeed, NAV_LO, NAV_HI));
        deal(GEM, address(this), 1e30); // fund buys at any price
        deal(GEM, WSGEM, 1e30); // fund the wrapper for sells at any price
        mode = uint8(bound(mode, 0, 3));

        if (mode == 0) {
            uint256 mc = wrapper.mintcost();
            uint256 amtIn = bound(amt, mc + 1, mc + SWAP_CAP); // clear the wrapper dust floor
            assertEq(_swapIn(true, amtIn), quoter.quoteExactInput(true, amtIn), "buy exact-in == quoter");
            _assertHookClean();
        } else if (mode == 1) {
            uint256 amtIn = bound(amt, WAD, SWAP_CAP);
            if (_bal(WSGEM, address(this)) < amtIn) return;
            assertEq(_swapIn(false, amtIn), quoter.quoteExactInput(false, amtIn), "sell exact-in == quoter");
            _assertHookClean();
        } else if (mode == 2) {
            uint256 mc = wrapper.mintcost();
            uint256 amtOut = bound(amt, WAD, SWAP_CAP);
            uint256 q = quoter.quoteExactOutput(true, amtOut);
            assertEq(_swapOut(true, amtOut, q), q, "buy exact-out == quoter");
            // Over-mint dust is bounded by the price ratio (WAD/mintcost): tight at par, larger sub-par.
            assertLe(_bal(WSGEM, address(hook)), (WAD / mc) + 1, "buy exact-out wsgem dust bounded by WAD/mintcost");
            assertEq(_bal(GEM, address(hook)), 0, "no gem dust on a buy");
        } else {
            uint256 bc = wrapper.burncost();
            uint256 amtOut = bound(amt, WAD, SWAP_CAP);
            uint256 wIn = quoter.quoteExactOutput(false, amtOut);
            if (wIn < WAD || _bal(WSGEM, address(this)) < wIn) return; // redeem minimum + actor funding
            assertEq(_swapOut(false, amtOut, wIn), wIn, "sell exact-out == quoter");
            // Over-redeem dust is bounded by the price ratio (burncost/WAD): tight sub-par, larger above par.
            assertLe(_bal(GEM, address(hook)), (bc / WAD) + 1, "sell exact-out gem dust bounded by burncost/WAD");
            assertEq(_bal(WSGEM, address(hook)), 0, "no wsgem dust on a sell");
        }
    }

    // -----------------------------------------------------------------------
    // Exact-output rounding: ceiling, and never an over-charge beyond 1 wei
    // -----------------------------------------------------------------------

    /// @notice At any price, the exact-output input the caller pays is the true fair amount rounded UP by
    ///         at most 1 wei — never a hidden surcharge. (Pure quoter math; mirrors the hook's `mulDivRoundingUp`.)
    function testFuzz_exactOutInputIsExactCeiling(uint256 navSeed, uint256 amtOut, bool buy) public {
        _setNav(bound(navSeed, NAV_LO, NAV_HI));
        amtOut = bound(amtOut, WAD, SWAP_CAP);

        if (buy) {
            uint256 mc = wrapper.mintcost();
            uint256 input = quoter.quoteExactOutput(true, amtOut);
            uint256 floorFair = FullMath.mulDiv(amtOut, mc, WAD);
            assertGe(input, floorFair, "exact-out buy input below floor");
            assertLe(input - floorFair, 1, "exact-out buy over-charges by > 1 wei");
        } else {
            uint256 bc = wrapper.burncost();
            uint256 input = quoter.quoteExactOutput(false, amtOut);
            uint256 floorFair = FullMath.mulDiv(amtOut, WAD, bc);
            assertGe(input, floorFair, "exact-out sell input below floor");
            assertLe(input - floorFair, 1, "exact-out sell over-charges by > 1 wei");
        }
    }

    /// @notice L-02 generalized: with a sub-par NAV (mintcost < WAD), an exact-output buy mints strictly
    ///         more wsgem than requested. The caller still receives exactly `amtOut` and pays only the
    ///         rounded-up input; the over-mint is stuck in the hook as price-bounded dust (never credited
    ///         to the caller, never drawn from anyone).
    function testFuzz_subParNavMintsAtLeastRequested(uint256 navSeed, uint256 amtOut) public {
        _setSpreads(0, 0); // zero ask spread => mintcost == nav
        _setNav(bound(navSeed, 0.1e18, WAD - 1)); // strictly sub-par
        uint256 mc = wrapper.mintcost();
        assertLt(mc, WAD, "forced sub-par mintcost");
        amtOut = bound(amtOut, WAD, 50_000 * WAD);
        deal(GEM, address(this), 1e30);

        uint256 input = quoter.quoteExactOutput(true, amtOut);
        uint256 minted = FullMath.mulDiv(input, WAD, mc); // == wrapper.mint(input)
        assertGe(minted, amtOut, "mint must cover the requested output");

        uint256 w0 = _bal(WSGEM, address(this));
        assertEq(_swapOut(true, amtOut, input), input, "spent == rounded-up quote");
        assertEq(_bal(WSGEM, address(this)) - w0, amtOut, "caller received exactly the requested output");
        assertLe(_bal(WSGEM, address(hook)), (WAD / mc) + 1, "over-mint dust bounded by WAD/mintcost");
        assertEq(_bal(GEM, address(hook)), 0, "hook holds no gem");
    }

    // -----------------------------------------------------------------------
    // Round-trips can never profit (the anti-extraction property, fuzzed over price)
    // -----------------------------------------------------------------------

    function testFuzz_buyThenSellNeverProfits(uint256 navSeed, uint256 amtIn) public {
        _setNav(bound(navSeed, 0.5e18, 2e18));
        deal(GEM, address(this), 1e30);
        deal(GEM, WSGEM, 1e30);
        amtIn = bound(amtIn, 100 * WAD, 50_000 * WAD);

        uint256 t0 = _bal(GEM, address(this));
        uint256 wOut = _swapIn(true, amtIn);
        uint256 tBack = _swapIn(false, wOut);
        assertLe(tBack, amtIn, "buy->sell returned more gem than was paid (extraction)");
        assertLe(_bal(GEM, address(this)), t0, "net gem did not increase over the round-trip");
        _assertHookClean();
    }

    function testFuzz_sellThenBuyNeverProfits(uint256 navSeed, uint256 amtIn) public {
        _setNav(bound(navSeed, 0.5e18, 2e18));
        deal(GEM, address(this), 1e30);
        deal(GEM, WSGEM, 1e30);
        amtIn = bound(amtIn, 100 * WAD, 50_000 * WAD); // wsgem to sell (actor holds ~500k from setUp)

        uint256 w0 = _bal(WSGEM, address(this));
        uint256 tOut = _swapIn(false, amtIn);
        uint256 wBack = _swapIn(true, tOut);
        assertLe(wBack, amtIn, "sell->buy returned more wsgem than was paid (extraction)");
        assertLe(_bal(WSGEM, address(this)), w0, "net wsgem did not increase over the round-trip");
        _assertHookClean();
    }

    // -----------------------------------------------------------------------
    // A donated hook balance can neither change pricing nor be drained
    // -----------------------------------------------------------------------

    /// @notice The ownerless hook mints/redeems exactly what it settles and never dips into its own
    ///         balance, so an attacker who donates tokens to it can neither subsidize/poison the price nor
    ///         siphon the donation back out via swaps. Output always equals the (balance-blind) quoter and
    ///         the donation is untouched apart from <=1 wei exact-out dust accruing on top.
    function test_donatedHookBalanceDoesNotChangePricing() public {
        uint256 d = 1_000 * WAD;
        deal(GEM, address(hook), d);
        IERC20Minimal(WSGEM).transfer(address(hook), d); // seed wsgem from the actor's stack
        assertEq(_bal(GEM, address(hook)), d, "hook seeded with gem");
        assertEq(_bal(WSGEM, address(hook)), d, "hook seeded with wsgem");

        uint256 amt = 1_000 * WAD;

        uint256 qBuyIn = quoter.quoteExactInput(true, amt);
        assertEq(_swapIn(true, amt), qBuyIn, "buy exact-in price unaffected by donation");
        assertEq(_bal(GEM, address(hook)), d, "donated gem untouched (buy exact-in)");
        assertEq(_bal(WSGEM, address(hook)), d, "no wsgem drawn from donation (buy exact-in)");

        uint256 qSellIn = quoter.quoteExactInput(false, amt);
        assertEq(_swapIn(false, amt), qSellIn, "sell exact-in price unaffected by donation");
        assertEq(_bal(WSGEM, address(hook)), d, "donated wsgem untouched (sell exact-in)");
        assertEq(_bal(GEM, address(hook)), d, "no gem drawn from donation (sell exact-in)");

        uint256 qBuyOut = quoter.quoteExactOutput(true, amt);
        assertEq(_swapOut(true, amt, qBuyOut), qBuyOut, "buy exact-out price unaffected by donation");
        assertLe(_bal(WSGEM, address(hook)) - d, 1, "buy exact-out adds <=1 wei dust atop the donation");
        assertEq(_bal(GEM, address(hook)), d, "donated gem untouched (buy exact-out)");

        uint256 qSellOut = quoter.quoteExactOutput(false, amt);
        assertEq(_swapOut(false, amt, qSellOut), qSellOut, "sell exact-out price unaffected by donation");
        assertLe(_bal(GEM, address(hook)) - d, 1, "sell exact-out adds <=1 wei dust atop the donation");
    }

    // -----------------------------------------------------------------------
    // Extremes & out-of-range inputs fail cleanly (no silent corruption)
    // -----------------------------------------------------------------------

    /// @notice At a near-zero mintcost the minted output overflows int128; the hook's SafeCast
    ///         (`-wOut.toInt128()`) must revert rather than encode a corrupted `BeforeSwapDelta`.
    function test_extremeLowMintcostRevertsCleanlyOnOverflow() public {
        _setSpreads(0, 0);
        _setNav(1); // mintcost == 1 wei
        assertEq(wrapper.mintcost(), 1, "mintcost driven to 1 wei");
        deal(GEM, address(this), 1e30);

        // wOut = amtIn * 1e18 / 1 overflows int128 (> ~1.7e38) for amtIn above ~170e18.
        vm.expectRevert();
        router.swapExactInput(key, true, 200 * WAD, 0, address(this), block.timestamp);
        _assertHookClean(); // reverted => fully rolled back
    }

    /// @notice At an extreme-high mintcost a sub-mintcost buy can't clear the wrapper's dust floor and the
    ///         pure backstop has no LP to fall back to, so it reverts rather than silently settling zero.
    function test_extremeHighPriceBuyRevertsOnDust() public {
        _setNav(1e30);
        assertGe(wrapper.mintcost(), 1e30, "mintcost driven very high");
        vm.expectRevert();
        router.swapExactInput(key, true, 0.5e18, 0, address(this), block.timestamp);
        _assertHookClean();
    }

    /// @notice A specified amount above int128.max must revert cleanly (the `specifiedAmount.toInt128()`
    ///         bound in `_beforeSwap`), never wrap around. Fund the actor enough to reach the hook.
    function test_amountSpecifiedBeyondInt128RevertsCleanly() public {
        uint256 huge = uint256(uint128(type(int128).max)) + 1; // 2^127, one past int128.max
        deal(GEM, address(this), huge);
        vm.expectRevert();
        router.swapExactInput(key, true, huge, 0, address(this), block.timestamp);
    }

    /// @notice A zero-amount swap is not a silent value-moving no-op: it reverts (the wrapper's dust floor
    ///         rejects a zero mint/redeem, and v4 rejects a zero `amountSpecified`). Documents the
    ///         router's unguarded-but-safe zero case for both directions.
    function test_zeroAmountSwapsRevert() public {
        vm.expectRevert();
        router.swapExactInput(key, true, 0, 0, address(this), block.timestamp);
        vm.expectRevert();
        router.swapExactInput(key, false, 0, 0, address(this), block.timestamp);
        _assertHookClean();
    }

    // -----------------------------------------------------------------------
    // Permit2 signature cannot be replayed (closes the "replay" hypothesis)
    // -----------------------------------------------------------------------

    /// @notice A consumed Permit2 permit/signature cannot be reused: the canonical Permit2 invalidates the
    ///         nonce on first use, so an identical second call reverts. (The router correctly delegates
    ///         nonce management to Permit2; there is no replay surface.)
    function test_permit2SignatureCannotBeReplayed() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 1_000 * WAD;
        address permit2 = address(router.PERMIT2());
        deal(GEM, alice, 2 * amtIn);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(permit2, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(pk, GEM, amtIn, 0, block.timestamp + 1 hours);

        vm.prank(alice);
        router.swapExactInputPermit2(key, true, amtIn, 0, alice, permit, sig);

        // Replay the identical permit + signature: Permit2 already burned nonce 0 => revert.
        vm.prank(alice);
        vm.expectRevert();
        router.swapExactInputPermit2(key, true, amtIn, 0, alice, permit, sig);
    }
}
