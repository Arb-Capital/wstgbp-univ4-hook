// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {WstGBPAdapterForkBase} from "../base/WstGBPAdapterForkBase.sol";
import {WstGBPDirectAdapter} from "../../src/adapter/WstGBPDirectAdapter.sol";

/// @notice Feature/parity/hardening suite for the direct aggregator-and-solver adapter. The adapter prices
///         off the same shared {WstGBPWrap} core as the v4 backstop hook, so the four pricing modes match
///         the hook's exactly (buy @ mintcost, sell @ burncost, exact-out rounded up), and its quotes equal
///         both its own execution and the independent {WstGBPQuoter}. Also covers the aggregator-style
///         "plain approve + swap" path (no v4 pool — the thing stock routers can't do against the hook),
///         slippage/deadline/recipient hardening, Permit2, and every wrapper-gated revert.
contract WstGBPDirectAdapterForkTest is WstGBPAdapterForkBase {
    // --- Pricing: buy @ mintcost, sell @ burncost (identical to the hook, via the shared library) ---

    function test_buyExactInput() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_adapterIn(true, amtIn), expectedOut, "adapter output");
        assertEq(_bal(TGBP, address(this)), t0 - amtIn, "exact tGBP spent");
        assertEq(_bal(WST, address(this)), w0 + expectedOut, "wstGBP at mintcost");
        _assertAdapterClean();
    }

    function test_sellExactInput() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * wrapper.burncost() / WAD;
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_adapterIn(false, amtIn), expectedOut, "adapter output");
        assertEq(_bal(WST, address(this)), w0 - amtIn, "exact wstGBP spent");
        assertEq(_bal(TGBP, address(this)), t0 + expectedOut, "tGBP at burncost");
        _assertAdapterClean();
    }

    function test_buyExactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(amtOut * wrapper.mintcost(), WAD);
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_adapterOut(true, amtOut, expectedIn + 10 * WAD), expectedIn, "input spent");
        assertEq(_bal(WST, address(this)), w0 + amtOut, "exact wstGBP out");
        // Adapter computes the exact input and pulls only that — no over-pull, no refund needed.
        assertEq(_bal(TGBP, address(this)), t0 - expectedIn, "tGBP paid (rounded up)");
    }

    function test_sellExactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 expectedIn = _ceil(amtOut * WAD, wrapper.burncost());
        uint256 t0 = _bal(TGBP, address(this));
        uint256 w0 = _bal(WST, address(this));
        assertEq(_adapterOut(false, amtOut, expectedIn + 10 * WAD), expectedIn, "input spent");
        assertEq(_bal(TGBP, address(this)), t0 + amtOut, "exact tGBP out");
        assertEq(_bal(WST, address(this)), w0 - expectedIn, "wstGBP paid (rounded up)");
    }

    function test_roundTripSpreadIsAboutTwentyFiveBps() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 t0 = _bal(TGBP, address(this));
        uint256 wReceived = _adapterIn(true, amtIn);
        _adapterIn(false, wReceived);
        uint256 netLoss = t0 - _bal(TGBP, address(this));
        assertGe(netLoss, amtIn * 20 / 10_000, "spread >= ~20bps");
        assertLe(netLoss, amtIn * 30 / 10_000, "spread <= ~30bps");
    }

    // --- Quotes: adapter view == quoter == execution (all four modes) ---

    function test_adapterQuoteMatchesExecution_exactInput() public {
        uint256 amtIn = 1_000 * WAD;
        assertEq(adapter.quoteExactInput(TGBP, amtIn), quoter.quoteExactInput(true, amtIn), "buy adapter==quoter");
        assertEq(adapter.quoteExactInput(TGBP, amtIn), _adapterIn(true, amtIn), "buy quote==exec");
        assertEq(adapter.quoteExactInput(WST, amtIn), quoter.quoteExactInput(false, amtIn), "sell adapter==quoter");
        assertEq(adapter.quoteExactInput(WST, amtIn), _adapterIn(false, amtIn), "sell quote==exec");
    }

    function test_adapterQuoteMatchesExecution_exactOutput() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 qb = adapter.quoteExactOutput(TGBP, amtOut);
        assertEq(qb, quoter.quoteExactOutput(true, amtOut), "buy adapter==quoter");
        assertEq(_adapterOut(true, amtOut, qb + 10 * WAD), qb, "buy out quote==exec");
        uint256 qs = adapter.quoteExactOutput(WST, amtOut);
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
        deal(TGBP, solver, amtIn);
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();

        vm.startPrank(solver);
        IERC20Minimal(TGBP).approve(address(adapter), amtIn);
        uint256 out = adapter.swapExactInput(TGBP, amtIn, expectedOut, solver, block.timestamp);
        vm.stopPrank();

        assertEq(out, expectedOut, "swap-then-settle output");
        assertEq(_bal(WST, solver), expectedOut, "solver received wstGBP");
        _assertAdapterClean();
    }

    // --- Hardening ---

    function test_minAmountOutEnforced() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = adapter.quoteExactInput(TGBP, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WstGBPDirectAdapter.InsufficientOutput.selector, q, q + 1));
        adapter.swapExactInput(TGBP, amtIn, q + 1, address(this), block.timestamp);
    }

    function test_maxAmountInEnforced() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 q = adapter.quoteExactOutput(TGBP, amtOut);
        vm.expectRevert(abi.encodeWithSelector(WstGBPDirectAdapter.ExcessiveInput.selector, q, q - 1));
        adapter.swapExactOutput(TGBP, amtOut, q - 1, address(this), block.timestamp);
    }

    function test_deadlineEnforced() public {
        vm.expectRevert(WstGBPDirectAdapter.Expired.selector);
        adapter.swapExactInput(TGBP, 1_000 * WAD, 0, address(this), block.timestamp - 1);
    }

    function test_recipientReceivesOutput() public {
        address bob = address(0xB0B);
        uint256 amtIn = 1_000 * WAD;
        uint256 expected = adapter.quoteExactInput(TGBP, amtIn);
        uint256 payerWst = _bal(WST, address(this));
        adapter.swapExactInput(TGBP, amtIn, 0, bob, block.timestamp);
        assertEq(_bal(WST, bob), expected, "recipient got output");
        assertEq(_bal(WST, address(this)), payerWst, "payer got none");
    }

    function test_unsupportedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(WstGBPDirectAdapter.UnsupportedToken.selector, address(0xDEAD)));
        adapter.swapExactInput(address(0xDEAD), 1_000 * WAD, 0, address(this), block.timestamp);
    }

    function test_exactOutputDustStaysBounded() public {
        uint256 amtOut = 1_000 * WAD;
        uint256 maxIn = _ceil(amtOut * wrapper.mintcost(), WAD) + 1;
        _adapterOut(true, amtOut, maxIn);
        // Buy over-mints by at most price-bounded sub-unit dust; the recipient still got exactly amtOut.
        assertLt(_bal(WST, address(adapter)), 1e9, "exact-out buy leaves only sub-unit wstGBP dust");
        assertEq(_bal(TGBP, address(adapter)), 0, "no tGBP retained on a buy");
    }

    // --- Permit2 ---

    function test_permit2ExactInput() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 2_000 * WAD;
        deal(TGBP, alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(TGBP).approve(PERMIT2_ADDR, type(uint256).max);

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), TGBP, amtIn, 0, block.timestamp + 1 hours);

        uint256 expectedOut = adapter.quoteExactInput(TGBP, amtIn);
        vm.prank(alice);
        uint256 out = adapter.swapExactInputPermit2(TGBP, amtIn, expectedOut, alice, permit, sig);
        assertEq(out, expectedOut, "permit2 output");
        assertEq(_bal(WST, alice), expectedOut, "alice got wstGBP");
        _assertAdapterClean();
    }

    function test_permit2TokenMismatchReverts() public {
        uint256 pk = 0xA11CE;
        address alice = vm.addr(pk);
        uint256 amtIn = 2_000 * WAD;
        deal(TGBP, alice, amtIn);
        vm.prank(alice);
        IERC20Minimal(TGBP).approve(PERMIT2_ADDR, type(uint256).max);
        // Sign a permit for WST while routing a tGBP buy: token must match the input currency.
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermitFor(pk, address(adapter), WST, amtIn, 0, block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(WstGBPDirectAdapter.Permit2TokenMismatch.selector);
        adapter.swapExactInputPermit2(TGBP, amtIn, 0, alice, permit, sig);
    }

    // --- Wrapper-gated reverts ---

    function test_buyRevertsWhenMintMarketClosed() public {
        vm.store(ACT, OPEN_MINT, bytes32(type(uint256).max));
        vm.expectRevert();
        _adapterIn(true, 1_000 * WAD);
    }

    function test_sellRevertsWhenWrapperUnderfunded() public {
        deal(TGBP, WST, 1 * WAD);
        uint256 amtIn = 1_000 * WAD;
        uint256 claim = amtIn * wrapper.burncost() / WAD;
        vm.expectRevert(abi.encodeWithSelector(WstGBPDirectAdapter.WrapperUnderfunded.selector, claim, 1 * WAD));
        _adapterIn(false, amtIn);
    }

    function test_sellRevertsWhenRedeemCooldownActive() public {
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(1 days)));
        assertEq(wrapper.cooldown(), 1 days, "cooldown set");
        vm.expectRevert(WstGBPDirectAdapter.RedeemCooldownActive.selector);
        _adapterIn(false, 1_000 * WAD);
        vm.expectRevert(WstGBPDirectAdapter.RedeemCooldownActive.selector);
        _adapterOut(false, 1_000 * WAD, 2_000 * WAD);
        // Buys mint atomically regardless of redemption cooldown.
        assertEq(_adapterIn(true, 1_000 * WAD), 1_000 * WAD * WAD / wrapper.mintcost(), "buy unaffected");
        _assertAdapterClean();
    }

    // --- A donated balance can neither subsidize pricing nor be drained ---

    function test_donatedBalanceIsInert() public {
        deal(TGBP, address(adapter), 100_000 * WAD);
        uint256 amtIn = 1_000 * WAD;
        uint256 expectedOut = amtIn * WAD / wrapper.mintcost();
        assertEq(_adapterIn(true, amtIn), expectedOut, "donation doesn't change price");
        assertGe(_bal(TGBP, address(adapter)), 100_000 * WAD, "tGBP donation not drained");
    }
}
