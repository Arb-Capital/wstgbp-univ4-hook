// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {WsgemAdapterForkBase} from "../base/WsgemAdapterForkBase.sol";
import {WsgemDirectAdapter} from "../../src/adapter/WsgemDirectAdapter.sol";
import {Iwsgem} from "../../src/core/interfaces/Iwsgem.sol";

/// @notice Feature/parity/hardening suite for the direct aggregator-and-solver adapter. The adapter prices
///         off the same shared {WsgemWrap} core as the v4 backstop hook, so the four pricing modes match
///         the hook's exactly (buy @ mintcost, sell @ burncost, exact-out rounded up), and its quotes equal
///         both its own execution and the independent {WsgemQuoter}. Also covers the aggregator-style
///         "plain approve + swap" path (no v4 pool — the thing stock routers can't do against the hook),
///         slippage/deadline/recipient hardening, Permit2, and every wrapper-gated revert.
contract WsgemDirectAdapterForkTest is WsgemAdapterForkBase {
    // --- Pricing: buy @ mintcost, sell @ burncost (identical to the hook, via the shared library) ---

    function test_buyExactInput() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));
        assertEq(_adapterIn(true, amtIn), expectedOut, "adapter output");
        assertEq(_bal(GEM, address(this)), t0 - amtIn, "exact gem spent");
        assertEq(_bal(WSGEM, address(this)), w0 + expectedOut, "wsgem at mintcost");
        _assertAdapterClean();
    }

    function test_sellExactInput() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * wrapper.burncost() / WAD;
        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));
        assertEq(_adapterIn(false, amtIn), expectedOut, "adapter output");
        assertEq(_bal(WSGEM, address(this)), w0 - amtIn, "exact wsgem spent");
        assertEq(_bal(GEM, address(this)), t0 + expectedOut, "gem at burncost");
        _assertAdapterClean();
    }

    function test_buyExactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(amtOut * wrapper.mintcost(), WAD);
        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));
        assertEq(_adapterOut(true, amtOut, expectedIn + 10 * WAD), expectedIn, "input spent");
        assertEq(_bal(WSGEM, address(this)), w0 + amtOut, "exact wsgem out");
        // Adapter computes the exact input and pulls only that — no over-pull, no refund needed.
        assertEq(_bal(GEM, address(this)), t0 - expectedIn, "gem paid (rounded up)");
    }

    function test_sellExactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(amtOut * WAD, wrapper.burncost());
        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));
        assertEq(_adapterOut(false, amtOut, expectedIn + 10 * WAD), expectedIn, "input spent");
        assertEq(_bal(GEM, address(this)), t0 + amtOut, "exact gem out");
        assertEq(_bal(WSGEM, address(this)), w0 - expectedIn, "wsgem paid (rounded up)");
    }

    function test_roundTripSpreadIsAboutTwentyFiveBps() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 t0 = _bal(GEM, address(this));
        uint256 wReceived = _adapterIn(true, amtIn);
        _adapterIn(false, wReceived);
        uint256 netLoss = t0 - _bal(GEM, address(this));
        assertGe(netLoss, amtIn * 20 / 10_000, "spread >= ~20bps");
        assertLe(netLoss, amtIn * 30 / 10_000, "spread <= ~30bps");
    }

    // --- Quotes: adapter view == quoter == execution (all four modes) ---

    function test_adapterQuoteMatchesExecution_exactInput() public {
        uint256 amtIn = 1_000 * WAD;
        assertEq(adapter.quoteExactInput(GEM, amtIn), quoter.quoteExactInput(true, amtIn), "buy adapter==quoter");
        assertEq(adapter.quoteExactInput(GEM, amtIn), _adapterIn(true, amtIn), "buy quote==exec");
        assertEq(adapter.quoteExactInput(WSGEM, amtIn), quoter.quoteExactInput(false, amtIn), "sell adapter==quoter");
        assertEq(adapter.quoteExactInput(WSGEM, amtIn), _adapterIn(false, amtIn), "sell quote==exec");
    }

    function test_adapterQuoteMatchesExecution_exactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 qb = adapter.quoteExactOutput(GEM, amtOut);
        assertEq(qb, quoter.quoteExactOutput(true, amtOut), "buy adapter==quoter");
        assertEq(_adapterOut(true, amtOut, qb + 10 * WAD), qb, "buy out quote==exec");
        uint256 qs = adapter.quoteExactOutput(WSGEM, amtOut);
        assertEq(qs, quoter.quoteExactOutput(false, amtOut), "sell adapter==quoter");
        assertEq(_adapterOut(false, amtOut, qs + 10 * WAD), qs, "sell out quote==exec");
    }

    // --- Aggregator-style settlement: plain approve + swap, no v4 pool, no settle-first router ---

    function test_aggregatorStyleApproveAndSwap() public {
        // Exactly how an Odos/Paraswap/LI.FI executor or a CoW solver interaction settles: the actor holds
        // the input, approves the adapter, and calls a standard swap. (Stock swap-then-settle routers
        // revert against the v4 hook; the adapter exists precisely so they don't have to settle-first.)
        address solver = address(0x5012E7);
        uint256 amtIn = 5_000 * WAD;
        deal(GEM, solver, amtIn);
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();

        vm.startPrank(solver);
        IERC20Minimal(GEM).approve(address(adapter), amtIn);
        uint256 out = adapter.swapExactInput(GEM, amtIn, expectedOut, solver, block.timestamp);
        vm.stopPrank();

        assertEq(out, expectedOut, "swap-then-settle output");
        assertEq(_bal(WSGEM, solver), expectedOut, "solver received wsgem");
        _assertAdapterClean();
    }

    // --- Hardening ---

    function test_minAmountOutEnforced() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = adapter.quoteExactInput(GEM, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.InsufficientOutput.selector, q, q + 1));
        adapter.swapExactInput(GEM, amtIn, q + 1, address(this), block.timestamp);
    }

    function test_maxAmountInEnforced() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 q = adapter.quoteExactOutput(GEM, amtOut);
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.ExcessiveInput.selector, q, q - 1));
        adapter.swapExactOutput(GEM, amtOut, q - 1, address(this), block.timestamp);
    }

    /// @notice The slippage bounds guard the SELL direction too, not just buys: an exact-in sell honours
    ///         `minAmountOut` and an exact-out sell honours `maxAmountIn` (the buy-side branches above and
    ///         these sell-side ones are distinct code paths in `_swap`).
    function test_sellMinAmountOutEnforced() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = adapter.quoteExactInput(WSGEM, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.InsufficientOutput.selector, q, q + 1));
        adapter.swapExactInput(WSGEM, amtIn, q + 1, address(this), block.timestamp);
    }

    function test_sellMaxAmountInEnforced() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 q = adapter.quoteExactOutput(WSGEM, amtOut);
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.ExcessiveInput.selector, q, q - 1));
        adapter.swapExactOutput(WSGEM, amtOut, q - 1, address(this), block.timestamp);
    }

    /// @notice An approval-based swap from a payer who never approved the adapter reverts `TransferFailed`
    ///         (the input `transferFrom` fails; the adapter's low-level call captures the failure rather than
    ///         bubbling the token's own revert). Mirrors the router's `transferFrom`-fail guard.
    function test_revertsWhenInputTransferFromFails() public {
        address carol = address(0xCA401); // funded but has NOT approved the adapter
        deal(GEM, carol, 1_000 * WAD);
        vm.prank(carol);
        vm.expectRevert(WsgemDirectAdapter.TransferFailed.selector);
        adapter.swapExactInput(GEM, 1_000 * WAD, 0, carol, block.timestamp);
    }

    function test_deadlineEnforced() public {
        vm.expectRevert(WsgemDirectAdapter.Expired.selector);
        adapter.swapExactInput(GEM, 1_000 * WAD, 0, address(this), block.timestamp - 1);
    }

    function test_recipientReceivesOutput() public {
        address bob = address(0xB0B);
        uint256 amtIn = 1_000 * WAD;
        uint256 expected = adapter.quoteExactInput(GEM, amtIn);
        uint256 payerWsgem = _bal(WSGEM, address(this));
        adapter.swapExactInput(GEM, amtIn, 0, bob, block.timestamp);
        assertEq(_bal(WSGEM, bob), expected, "recipient got output");
        assertEq(_bal(WSGEM, address(this)), payerWsgem, "payer got none");
    }

    function test_unsupportedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.UnsupportedToken.selector, address(0xDEAD)));
        adapter.swapExactInput(address(0xDEAD), 1_000 * WAD, 0, address(this), block.timestamp);
    }

    function test_exactOutputDustStaysBounded() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 maxIn = _ceil(amtOut * wrapper.mintcost(), WAD) + 1;
        _adapterOut(true, amtOut, maxIn);
        // Buy over-mints by at most price-bounded sub-unit dust; the recipient still got exactly amtOut.
        assertLt(_bal(WSGEM, address(adapter)), 1e9, "exact-out buy leaves only sub-unit wsgem dust");
        assertEq(_bal(GEM, address(adapter)), 0, "no gem retained on a buy");
    }

    // --- Permit2 ---

    function test_permit2ExactInput() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 2_000 * WAD;
        deal(GEM, alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(PERMIT2_ADDR, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), GEM, amtIn, 0, block.timestamp + 1 hours);

        uint256 expectedOut = adapter.quoteExactInput(GEM, amtIn);
        vm.prank(alice);
        uint256 out = adapter.swapExactInputPermit2(GEM, amtIn, expectedOut, alice, permit, sig);
        assertEq(out, expectedOut, "permit2 output");
        assertEq(_bal(WSGEM, alice), expectedOut, "alice got wsgem");
        _assertAdapterClean();
    }

    function test_permit2SellExactInput() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 2_000 * WAD;
        IERC20Minimal(WSGEM).transfer(alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(WSGEM).approve(PERMIT2_ADDR, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), WSGEM, amtIn, 0, block.timestamp + 1 hours);

        uint256 expectedOut = adapter.quoteExactInput(WSGEM, amtIn);
        vm.prank(alice);
        uint256 out = adapter.swapExactInputPermit2(WSGEM, amtIn, expectedOut, alice, permit, sig);
        assertEq(out, expectedOut, "permit2 sell output");
        assertEq(_bal(GEM, alice), expectedOut, "alice got gem");
        assertEq(_bal(WSGEM, alice), 0, "alice spent exact wsgem");
        _assertAdapterClean();
    }

    function test_permit2TokenMismatchReverts() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 2_000 * WAD;
        deal(GEM, alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(PERMIT2_ADDR, type(uint256).max);
        // Sign a permit for WSGEM while routing a gem buy: token must match the input currency.
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), WSGEM, amtIn, 0, block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(WsgemDirectAdapter.Permit2TokenMismatch.selector);
        adapter.swapExactInputPermit2(GEM, amtIn, 0, alice, permit, sig);
    }

    /// @notice Exact-output buy funded via Permit2: the payer signs a `PermitTransferFrom` for `maxAmountIn`
    ///         and the adapter pulls only the computed exact input (rounded up), delivering exactly `amountOut`.
    function test_permit2ExactOutput() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtOut = 2_000 * WAD;
        uint256 expectedIn = adapter.quoteExactOutput(GEM, amtOut);
        uint256 maxIn = expectedIn + 10 * WAD;
        deal(GEM, alice, maxIn);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(PERMIT2_ADDR, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), GEM, maxIn, 0, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 spent = adapter.swapExactOutputPermit2(GEM, amtOut, maxIn, alice, permit, sig);
        assertEq(spent, expectedIn, "pulled exactly the computed input");
        assertEq(_bal(WSGEM, alice), amtOut, "alice got exact output");
        assertEq(_bal(GEM, alice), maxIn - expectedIn, "only the exact input was pulled");
        _assertAdapterClean();
    }

    function test_permit2SellExactOutput() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtOut = 2_000 * WAD;
        uint256 expectedIn = adapter.quoteExactOutput(WSGEM, amtOut);
        uint256 maxIn = expectedIn + 10 * WAD;
        IERC20Minimal(WSGEM).transfer(alice, maxIn);
        vm.prank(alice);
        IERC20Minimal(WSGEM).approve(PERMIT2_ADDR, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), WSGEM, maxIn, 0, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 spent = adapter.swapExactOutputPermit2(WSGEM, amtOut, maxIn, alice, permit, sig);
        assertEq(spent, expectedIn, "pulled exactly the computed wsgem input");
        assertEq(_bal(GEM, alice), amtOut, "alice got exact gem");
        assertEq(_bal(WSGEM, alice), maxIn - expectedIn, "only the exact wsgem input was pulled");
        assertLe(_bal(GEM, address(adapter)), (wrapper.burncost() / WAD) + 1, "sell exact-output gem dust bounded");
        assertEq(_bal(WSGEM, address(adapter)), 0, "no wsgem retained on a sell");
    }

    // --- Wrapper-gated reverts ---

    function test_buyRevertsWhenMintMarketClosed() public {
        vm.store(ACT, OPEN_MINT, bytes32(type(uint256).max));
        vm.expectRevert();
        _adapterIn(true, 1_000 * WAD);
    }

    function test_buyRevertsWhenCapacityExceeded() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 minted = adapter.quoteExactInput(GEM, amtIn);
        vm.store(ACT, CAPACITY_SLOT, bytes32(wrapper.totalSupply() + minted - 1));
        vm.expectRevert();
        _adapterIn(true, amtIn);
    }

    function test_buyToExactlyCapacitySucceeds() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 minted = adapter.quoteExactInput(GEM, amtIn);
        vm.store(ACT, CAPACITY_SLOT, bytes32(wrapper.totalSupply() + minted));

        uint256 out = _adapterIn(true, amtIn);

        assertEq(out, minted, "minted exactly to the capacity ceiling");
        assertEq(wrapper.totalSupply(), wrapper.capacity(), "supply now sits at capacity");
        _assertAdapterClean();
    }

    function test_sellRevertsWhenWrapperUnderfunded() public {
        deal(GEM, WSGEM, 1 * WAD);
        uint256 amtIn = 1_000 * WAD;
        uint256 claim = amtIn * wrapper.burncost() / WAD;
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.WrapperUnderfunded.selector, claim, 1 * WAD));
        _adapterIn(false, amtIn);
    }

    function test_sellRevertsWhenRedeemCooldownActive() public {
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(1 days)));
        assertEq(wrapper.cooldown(), 1 days, "cooldown set");
        vm.expectRevert(WsgemDirectAdapter.RedeemCooldownActive.selector);
        _adapterIn(false, 1_000 * WAD);
        vm.expectRevert(WsgemDirectAdapter.RedeemCooldownActive.selector);
        _adapterOut(false, 1_000 * WAD, 2_000 * WAD);
        // Buys mint atomically regardless of redemption cooldown.
        assertEq(_adapterIn(true, 1_000 * WAD), 1_000 * WAD * WAD / wrapper.mintcost(), "buy unaffected");
        _assertAdapterClean();
    }

    /// @notice A live-NAV 100% redemption fee (`bpsout == 10_000`) zeroes `burncost` while the wrapper's
    ///         `redeem` (which only guards `nav == 0`) would still burn the seller's wsgem for 0 gem. The
    ///         adapter must revert `InvalidPrice` for both exact-in and exact-out sells; buys (mintcost ==
    ///         nav) are unaffected. Mirrors the hook so the two venues stay behaviorally identical.
    function test_sellRevertsWhenBurncostZero() public {
        _setSpreads(0, 10_000); // 100% bid spread => burncost == 0; 0 ask spread => mintcost == nav
        assertEq(wrapper.burncost(), 0, "burncost zeroed");
        assertGt(wrapper.mintcost(), 0, "mintcost still live");

        vm.expectRevert(WsgemDirectAdapter.InvalidPrice.selector);
        _adapterIn(false, 1_000 * WAD);
        vm.expectRevert(WsgemDirectAdapter.InvalidPrice.selector);
        _adapterOut(false, 1_000 * WAD, 2_000 * WAD);

        // Buys price at mintcost == nav, unaffected by the redemption fee.
        assertEq(_adapterIn(true, 1_000 * WAD), 1_000 * WAD * WAD / wrapper.mintcost(), "buy unaffected");
        _assertAdapterClean();
    }

    // --- Defensive reverts: mirror the hook's adversarial coverage (forced via mocked wrapper/token) ---

    /// @notice Defensive guard: if `wrapper.mint` ever returns fewer wsgem than the requested exact output
    ///         (it cannot under correct rounding, but a misbehaving wrapper could), the adapter reverts
    ///         `InsufficientOutput` rather than under-deliver. The gem pulled in is rolled back with the revert.
    function test_buyRevertsWhenMintUnderDelivers() public {
        uint256 amtOut = 1_000 * WAD;
        vm.mockCall(WSGEM, abi.encodeWithSelector(Iwsgem.mint.selector), abi.encode(amtOut - 1));
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.InsufficientOutput.selector, amtOut - 1, amtOut));
        adapter.swapExactOutput(GEM, amtOut, type(uint256).max, address(this), block.timestamp);
        vm.clearMockedCalls();
    }

    /// @notice Defensive guard: if delivering the minted wsgem to the recipient fails, the buy reverts
    ///         `TransferFailed`. Forced by mocking the wsgem `transfer` to return false; `wrapper.mint` is
    ///         unaffected (it mints via internal accounting, not `transfer`), so only the final leg fails.
    function test_buyRevertsWhenOutputTransferFails() public {
        vm.mockCall(WSGEM, abi.encodeWithSelector(IERC20Minimal.transfer.selector), abi.encode(false));
        vm.expectRevert(WsgemDirectAdapter.TransferFailed.selector);
        _adapterIn(true, 1_000 * WAD);
        vm.clearMockedCalls();
    }

    /// @notice Defensive guard: if delivering the redeemed gem to the recipient fails, the sell reverts
    ///         `TransferFailed`. The mock targets only the adapter→recipient leg (`to == address(this)`,
    ///         `amount == amtOut`) so the wrapper's own redeem payout (paid to the adapter) still settles.
    function test_sellRevertsWhenOutputTransferFails() public {
        uint256 amtOut = 1_000 * WAD;
        vm.mockCall(
            GEM, abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(this), amtOut), abi.encode(false)
        );
        vm.expectRevert(WsgemDirectAdapter.TransferFailed.selector);
        adapter.swapExactOutput(WSGEM, amtOut, type(uint256).max, address(this), block.timestamp);
        vm.clearMockedCalls();
    }

    /// @notice Defensive guard: if the wrapper's redeem ever pays out less than the funded claim (e.g. a
    ///         mid-call cooldown change), the adapter reverts `RedeemUnderpaid` for both sell directions
    ///         rather than settle short. Forced by mocking redeem to a no-op (returns an id but moves no gem)
    ///         while the wrapper stays funded, so the balance diff measures 0. Mirrors the hook.
    function test_sellRevertsWhenRedeemUnderpays() public {
        vm.mockCall(WSGEM, abi.encodeWithSelector(Iwsgem.redeem.selector), abi.encode(uint256(1)));
        uint256 amtIn = 1_000 * WAD;
        uint256 claimIn = adapter.quoteExactInput(WSGEM, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.RedeemUnderpaid.selector, claimIn, 0));
        adapter.swapExactInput(WSGEM, amtIn, 0, address(this), block.timestamp);
        vm.expectRevert(); // RedeemUnderpaid (exact-out)
        adapter.swapExactOutput(WSGEM, 1_000 * WAD, type(uint256).max, address(this), block.timestamp);
        vm.clearMockedCalls();
    }

    // --- A donated balance can neither subsidize pricing nor be drained ---

    function test_donatedBalanceIsInert() public {
        deal(GEM, address(adapter), 100_000 * WAD);
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        assertEq(_adapterIn(true, amtIn), expectedOut, "donation doesn't change price");
        assertGe(_bal(GEM, address(adapter)), 100_000 * WAD, "gem donation not drained");
    }

    // --- Additional edge cases: boundaries, untested gate paths, and documented-but-unasserted behavior ---

    /// @notice `recipient == address(0)` is documented to route the output to `msg.sender`. Every other test
    ///         passes an explicit recipient, so the default mapping (`_to`) is never asserted on its own.
    function test_recipientZeroRoutesToSender() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expected = adapter.quoteExactInput(GEM, amtIn);
        uint256 w0 = _bal(WSGEM, address(this));
        uint256 out = adapter.swapExactInput(GEM, amtIn, 0, address(0), block.timestamp);
        assertEq(out, expected, "output amount");
        assertEq(_bal(WSGEM, address(this)) - w0, expected, "address(0) routed output to msg.sender");
    }

    /// @notice The adapter has no `burnable()` pre-check — a sell when the burn market is closed must revert
    ///         because `wrapper.redeem` itself reverts. Proven here at execution (the suite otherwise only
    ///         gates sells via cooldown / underfunding / burncost==0). Buys are unaffected by the burn gate.
    function test_sellRevertsWhenBurnMarketClosed() public {
        vm.store(ACT, OPEN_BURN, bytes32(type(uint256).max)); // burnable() => false
        assertFalse(wrapper.burnable(), "burn market closed");
        vm.expectRevert();
        _adapterIn(false, 1_000 * WAD);
        assertGt(_adapterIn(true, 1_000 * WAD), 0, "buy unaffected by the burn gate");
    }

    /// @notice At a paused oracle (`pip.read() == 0`) both costs are zero: a buy divides by the zero mintcost
    ///         inside `wrapper.mint` and a sell hits the adapter's `InvalidPrice` guard (burncost == 0). The
    ///         suite only covered the paused oracle via `previewSwap`; this asserts the execution paths revert.
    function test_swapRevertsWhenOraclePaused() public {
        _setNav(0);
        vm.expectRevert(); // buy: wrapper.mint divides by the zero mintcost
        _adapterIn(true, 1_000 * WAD);
        vm.expectRevert(WsgemDirectAdapter.InvalidPrice.selector); // sell: burncost == 0
        _adapterIn(false, 1_000 * WAD);
    }

    /// @notice The exact-output sell path has its OWN `_requireWrapperFunded(claim)` call (distinct from the
    ///         exact-in path covered by `test_sellRevertsWhenWrapperUnderfunded`); drive it under-reserved.
    function test_sellExactOutputRevertsWhenUnderfunded() public {
        deal(GEM, WSGEM, 1 * WAD);
        uint256 amtOut = 1_000 * WAD;
        uint256 wIn = _ceil(amtOut * WAD, wrapper.burncost());
        uint256 claim = wIn * wrapper.burncost() / WAD; // == the adapter's computed claim (>= amtOut)
        vm.expectRevert(abi.encodeWithSelector(WsgemDirectAdapter.WrapperUnderfunded.selector, claim, 1 * WAD));
        _adapterOut(false, amtOut, type(uint256).max);
    }

    /// @notice The wrapper's dust floors (mint needs `amt >= mintcost`, redeem needs `amt >= 1e18`) make a
    ///         zero-amount swap revert; `_pull` no-ops on a zero amount, so the wrapper is the backstop. The
    ///         v4 hook asserts this (`test_zeroAmountSwapsRevert`); the adapter should match.
    function test_zeroAmountSwapsRevert() public {
        vm.expectRevert(); // buy: mint(0) below the dust threshold
        _adapterIn(true, 0);
        vm.expectRevert(); // sell: redeem(0) below the 1-wsgem minimum
        _adapterIn(false, 0);
    }

    /// @notice Funding boundary: with the wrapper holding gem EXACTLY equal to the redeem claim, the sell
    ///         must succeed and pay the full claim — the guard is `available < needed` (strict), so equality
    ///         passes. The underfunded tests only ever probe `available << claim`.
    function test_sellSucceedsWhenWrapperFundedExactly() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 claim = amtIn * wrapper.burncost() / WAD;
        deal(GEM, WSGEM, claim); // available == needed
        uint256 t0 = _bal(GEM, address(this));
        uint256 out = _adapterIn(false, amtIn);
        assertEq(out, claim, "received the full claim at the funding boundary");
        assertEq(_bal(GEM, address(this)) - t0, claim, "payer received full claim");
        assertEq(_bal(GEM, WSGEM), 0, "wrapper drained to exactly zero");
        _assertAdapterClean();
    }

    /// @notice The adapter emits `Swap(payer, recipient, buy, amountIn, amountOut)` once per swap; no test
    ///         asserted its topics/values before.
    function test_swapEmitsEvent() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = adapter.quoteExactInput(GEM, amtIn);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit WsgemDirectAdapter.Swap(address(this), address(this), true, amtIn, expectedOut);
        _adapterIn(true, amtIn);
    }

    // --- Permit2 expiry & replay ---

    /// @notice A Permit2 entrypoint enforces the deadline via `ensure(permit.deadline)` — a distinct argument
    ///         source from the plain entrypoints' `deadline`. A past `permit.deadline` reverts `Expired`.
    function test_permit2RevertsWhenExpired() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 1_000 * WAD;
        deal(GEM, alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(PERMIT2_ADDR, type(uint256).max);
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), GEM, amtIn, 0, block.timestamp - 1); // already expired
        vm.prank(alice);
        vm.expectRevert(WsgemDirectAdapter.Expired.selector);
        adapter.swapExactInputPermit2(GEM, amtIn, 0, alice, permit, sig);
    }

    /// @notice A signed Permit2 permit is single-use: replaying the same (nonce 0) permit reverts inside
    ///         Permit2 (the nonce bit is already spent). Mirrors the v4 suite's replay guard.
    function test_permit2CannotBeReplayed() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 1_000 * WAD;
        deal(GEM, alice, 2 * amtIn);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(PERMIT2_ADDR, type(uint256).max);
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), GEM, amtIn, 0, block.timestamp + 1 hours);
        vm.prank(alice);
        adapter.swapExactInputPermit2(GEM, amtIn, 0, alice, permit, sig);
        vm.prank(alice);
        vm.expectRevert(); // Permit2 InvalidNonce — the signature can't be replayed
        adapter.swapExactInputPermit2(GEM, amtIn, 0, alice, permit, sig);
    }

    // --- Constructor guard: a wrapper that names itself as its own underlying is rejected ---

    /// @notice The adapter resolves direction from `tokenIn` by matching `gem` first, so a wrapper whose
    ///         `gem() == address(wrapper)` would make sells unreachable. The constructor rejects it.
    function test_constructorRejectsIdenticalCurrencies() public {
        SelfGemWrapper bad = new SelfGemWrapper();
        vm.expectRevert(WsgemDirectAdapter.IdenticalCurrencies.selector);
        new WsgemDirectAdapter(Iwsgem(address(bad)));
    }
}

/// @dev Wrapper stub whose `gem()` returns its own address — the degenerate same-currency case the adapter
///      (and quoter/hook) reject. The constructor only reads `gem()` before the guard fires, so nothing else
///      is implemented.
contract SelfGemWrapper {
    function gem() external view returns (address) {
        return address(this);
    }
}
