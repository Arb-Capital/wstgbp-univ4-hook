// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WsgemAdapterForkBase} from "../base/WsgemAdapterForkBase.sol";
import {WsgemHookHelper} from "../../src/adapter/WsgemHookHelper.sol";
import {Iwsgem} from "../../src/core/interfaces/Iwsgem.sol";

/// @notice Feature/parity/hardening suite for the owner-bound CoW-hook helper. The helper prices off the
///         same shared {WsgemWrap} core as the adapter and the v4 hook (wrap @ mintcost, unwrap @
///         burncost), so its execution must equal the independent {WsgemQuoter} and the adapter's quotes.
///         The distinctive surface under test is the trust model: EVERY function is called by an untrusted
///         executor (the CoW HooksTrampoline — simulated here as an arbitrary address), funds move only
///         owner -> owner capped by the owner's allowance, and an arbitrary caller can trigger but never
///         redirect or extract.
contract WsgemHookHelperForkTest is WsgemAdapterForkBase {
    WsgemHookHelper helper;

    /// @dev Stands in for the CoW HooksTrampoline: an arbitrary, fund-less, untrusted executor.
    address constant TRAMPOLINE = address(0x7EA111);

    function setUp() public virtual override {
        super.setUp(); // fork + market open + adapter/quoter deployed + this contract seeded
        helper = new WsgemHookHelper(wrapper);
    }

    /// @dev Approve the helper for exactly `amount` of `token` (the exact-approval flow the dapp uses).
    function _approveHelper(address token, uint256 amount) internal {
        IERC20Minimal(token).approve(address(helper), amount);
    }

    function _assertHelperClean() internal view {
        assertEq(_bal(GEM, address(helper)), 0, "helper holds no gem");
        assertEq(_bal(WSGEM, address(helper)), 0, "helper holds no wsgem");
    }

    // --- Pricing / parity: wrap @ mintcost, unwrap @ burncost, executed by the untrusted trampoline ---

    function test_wrapAllAtMintcost() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = quoter.quoteExactInput(true, amtIn);
        assertEq(q, adapter.quoteExactInput(GEM, amtIn), "quoter==adapter baseline");
        _approveHelper(GEM, amtIn);

        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));
        vm.prank(TRAMPOLINE);
        uint256 out = helper.wrapAll(address(this), q);

        assertEq(out, q, "wrap executes at mintcost, == quoter");
        assertEq(_bal(GEM, address(this)), t0 - amtIn, "exact approved gem swept");
        assertEq(_bal(WSGEM, address(this)), w0 + q, "owner received the wsgem");
        assertEq(_bal(WSGEM, TRAMPOLINE), 0, "executor received nothing");
        _assertHelperClean();
    }

    function test_unwrapAtBurncost() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = quoter.quoteExactInput(false, amtIn);
        assertEq(q, adapter.quoteExactInput(WSGEM, amtIn), "quoter==adapter baseline");
        _approveHelper(WSGEM, amtIn);

        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));
        vm.prank(TRAMPOLINE);
        uint256 out = helper.unwrap(address(this), amtIn, q);

        assertEq(out, q, "unwrap executes at burncost, == quoter");
        assertEq(_bal(WSGEM, address(this)), w0 - amtIn, "exact wsgem spent");
        assertEq(_bal(GEM, address(this)), t0 + q, "owner received the gem");
        assertEq(_bal(GEM, TRAMPOLINE), 0, "executor received nothing");
        _assertHelperClean();
    }

    function test_roundTripSpreadIsAboutTwentyFiveBps() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 t0 = _bal(GEM, address(this));
        _approveHelper(GEM, amtIn);
        uint256 wOut = helper.wrapAll(address(this), 0);
        _approveHelper(WSGEM, wOut);
        helper.unwrap(address(this), wOut, 0);
        uint256 netLoss = t0 - _bal(GEM, address(this));
        assertGe(netLoss, amtIn * 20 / 10_000, "spread >= ~20bps");
        assertLe(netLoss, amtIn * 30 / 10_000, "spread <= ~30bps");
    }

    // --- Sweep semantics: min(balance, allowance) — the allowance is the owner's cap ---

    function test_wrapAllCappedByAllowance() public {
        // Owner holds far more gem than approved; only the approved amount may be swept.
        uint256 approved = 250 * WAD;
        _approveHelper(GEM, approved);
        uint256 t0 = _bal(GEM, address(this));
        assertGt(t0, approved, "owner balance exceeds approval");

        helper.wrapAll(address(this), 0);

        assertEq(_bal(GEM, address(this)), t0 - approved, "sweep stops at the allowance");
        _assertHelperClean();
    }

    function test_wrapAllCappedByBalance() public {
        // Owner approved max but only holds a smaller balance; the sweep takes the whole balance.
        address alice = address(0xA11CE1);
        uint256 balance = 400 * WAD;
        deal(GEM, alice, balance);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(address(helper), type(uint256).max);

        uint256 q = quoter.quoteExactInput(true, balance);
        vm.prank(TRAMPOLINE);
        uint256 out = helper.wrapAll(alice, 0);

        assertEq(out, q, "whole balance wrapped at mintcost");
        assertEq(_bal(GEM, alice), 0, "balance fully swept");
        assertEq(_bal(WSGEM, alice), q, "alice received the wsgem");
        _assertHelperClean();
    }

    function test_unwrapAllSweepsMinOfBalanceAndAllowance() public {
        address alice = address(0xA11CE2);
        uint256 balance = 300 * WAD;
        IERC20Minimal(WSGEM).transfer(alice, balance);

        // Allowance below balance: allowance wins.
        vm.prank(alice);
        IERC20Minimal(WSGEM).approve(address(helper), 100 * WAD);
        uint256 q1 = quoter.quoteExactInput(false, 100 * WAD);
        vm.prank(TRAMPOLINE);
        assertEq(helper.unwrapAll(alice, q1), q1, "allowance-capped unwrap");
        assertEq(_bal(WSGEM, alice), 200 * WAD, "only the allowance was swept");

        // Allowance above balance: balance wins.
        vm.prank(alice);
        IERC20Minimal(WSGEM).approve(address(helper), type(uint256).max);
        uint256 q2 = quoter.quoteExactInput(false, 200 * WAD);
        vm.prank(TRAMPOLINE);
        assertEq(helper.unwrapAll(alice, q2), q2, "balance-capped unwrap");
        assertEq(_bal(WSGEM, alice), 0, "remaining balance fully swept");
        assertEq(_bal(GEM, alice), q1 + q2, "alice received all gem");
        _assertHelperClean();
    }

    // --- Trust model: an arbitrary caller can trigger, but can never redirect or extract ---

    /// @notice The worst an attacker can do with someone else's approval is force a conversion at the fair
    ///         oracle price, delivered to the owner: the attacker's own balances never change, and the
    ///         owner's received value equals the wrapper's own quote exactly (bounded griefing, no theft).
    function test_arbitraryCallerCannotRedirectOrExtract() public {
        address victim = address(0xBADD1E);
        address attacker = address(0xA77AC4);
        uint256 amt = 1_000 * WAD;
        deal(GEM, victim, amt);
        vm.prank(victim);
        IERC20Minimal(GEM).approve(address(helper), amt);

        uint256 q = quoter.quoteExactInput(true, amt);
        vm.prank(attacker);
        helper.wrapAll(victim, 0); // attacker supplies their own (weakest) args

        assertEq(_bal(WSGEM, victim), q, "victim received full fair-price output");
        assertEq(_bal(GEM, victim), 0, "victim's approved gem was converted, not taken");
        assertEq(_bal(GEM, attacker), 0, "attacker gained no gem");
        assertEq(_bal(WSGEM, attacker), 0, "attacker gained no wsgem");
        _assertHelperClean();
    }

    function test_wrapAllEmitsOwnerAndCaller() public {
        uint256 amtIn = 100 * WAD;
        uint256 q = quoter.quoteExactInput(true, amtIn);
        _approveHelper(GEM, amtIn);
        vm.expectEmit(true, true, true, true, address(helper));
        emit WsgemHookHelper.Wrap(address(this), TRAMPOLINE, amtIn, q);
        vm.prank(TRAMPOLINE);
        helper.wrapAll(address(this), q);
    }

    function test_unwrapEmitsOwnerAndCaller() public {
        uint256 amtIn = 100 * WAD;
        uint256 q = quoter.quoteExactInput(false, amtIn);
        _approveHelper(WSGEM, amtIn);
        vm.expectEmit(true, true, true, true, address(helper));
        emit WsgemHookHelper.Unwrap(address(this), TRAMPOLINE, amtIn, q);
        vm.prank(TRAMPOLINE);
        helper.unwrap(address(this), amtIn, q);
    }

    // --- Guards: minAmountOut, nothing-to-convert, dust ---

    function test_wrapAllMinOutEnforced() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = quoter.quoteExactInput(true, amtIn);
        _approveHelper(GEM, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WsgemHookHelper.InsufficientOutput.selector, q, q + 1));
        helper.wrapAll(address(this), q + 1);
    }

    function test_unwrapMinOutEnforced() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = quoter.quoteExactInput(false, amtIn);
        _approveHelper(WSGEM, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WsgemHookHelper.InsufficientOutput.selector, q, q + 1));
        helper.unwrap(address(this), amtIn, q + 1);
    }

    function test_nothingToConvertReverts() public {
        address broke = address(0xB40CE); // no balance, no approval
        vm.expectRevert(WsgemHookHelper.NothingToConvert.selector);
        helper.wrapAll(broke, 0);
        vm.expectRevert(WsgemHookHelper.NothingToConvert.selector);
        helper.unwrapAll(broke, 0);
        vm.expectRevert(WsgemHookHelper.NothingToConvert.selector);
        helper.unwrap(broke, 0, 0);

        // Approval without balance is equally nothing-to-convert (sweep = min(balance, allowance) = 0).
        vm.prank(broke);
        IERC20Minimal(GEM).approve(address(helper), type(uint256).max);
        vm.expectRevert(WsgemHookHelper.NothingToConvert.selector);
        helper.wrapAll(broke, 0);
    }

    /// @notice A sweep below the wrapper's own mint dust threshold (`amt < mintcost`) bubbles the
    ///         wrapper's revert — the helper adds no dust handling of its own.
    function test_wrapBelowMintDustBubbles() public {
        address alice = address(0xA11CE3);
        deal(GEM, alice, wrapper.mintcost() - 1);
        vm.prank(alice);
        IERC20Minimal(GEM).approve(address(helper), type(uint256).max);
        vm.expectRevert();
        helper.wrapAll(alice, 0);
    }

    /// @notice `unwrap` of an unapproved amount fails in the pull (`TransferFailed`), it cannot touch
    ///         other users' funds.
    function test_unwrapWithoutApprovalReverts() public {
        vm.expectRevert(WsgemHookHelper.TransferFailed.selector);
        helper.unwrap(address(this), 1_000 * WAD, 0);
    }

    // --- Wrapper-gated reverts (mirror the adapter's sell-path guards) ---

    function test_wrapRevertsWhenMintMarketClosed() public {
        vm.store(ACT, OPEN_MINT, bytes32(type(uint256).max));
        _approveHelper(GEM, 1_000 * WAD);
        vm.expectRevert();
        helper.wrapAll(address(this), 0);
    }

    function test_unwrapRevertsWhenRedeemCooldownActive() public {
        vm.store(ACT, COOLDOWN_SLOT, bytes32(uint256(1 days)));
        _approveHelper(WSGEM, 1_000 * WAD);
        vm.expectRevert(WsgemHookHelper.RedeemCooldownActive.selector);
        helper.unwrap(address(this), 1_000 * WAD, 0);
        vm.expectRevert(WsgemHookHelper.RedeemCooldownActive.selector);
        helper.unwrapAll(address(this), 0);
    }

    function test_unwrapRevertsWhenWrapperUnderfunded() public {
        deal(GEM, WSGEM, 1 * WAD);
        uint256 amtIn = 1_000 * WAD;
        uint256 claim = amtIn * wrapper.burncost() / WAD;
        _approveHelper(WSGEM, amtIn);
        vm.expectRevert(abi.encodeWithSelector(WsgemHookHelper.WrapperUnderfunded.selector, claim, 1 * WAD));
        helper.unwrap(address(this), amtIn, 0);
    }

    /// @notice A live-NAV 100% redemption fee zeroes `burncost`; the helper must reject the unwrap rather
    ///         than burn the owner's wsgem for nothing (mirrors the adapter/hook sell guard).
    function test_unwrapRevertsWhenBurncostZero() public {
        _setSpreads(0, 10_000);
        assertEq(wrapper.burncost(), 0, "burncost zeroed");
        _approveHelper(WSGEM, 1_000 * WAD);
        vm.expectRevert(WsgemHookHelper.InvalidPrice.selector);
        helper.unwrap(address(this), 1_000 * WAD, 0);

        // Wraps price at mintcost == nav, unaffected by the redemption fee.
        _approveHelper(GEM, 1_000 * WAD);
        assertEq(helper.wrapAll(address(this), 0), 1_000 * WAD * WAD / wrapper.mintcost(), "wrap unaffected");
        _assertHelperClean();
    }

    /// @notice Defensive guard: if the wrapper's redeem ever pays out less than the funded claim (e.g. a
    ///         mid-call cooldown change), the helper reverts `RedeemUnderpaid` rather than settle short.
    ///         Forced by mocking redeem to a no-op while the wrapper stays funded.
    function test_unwrapRevertsWhenRedeemUnderpays() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 claim = quoter.quoteExactInput(false, amtIn);
        _approveHelper(WSGEM, amtIn);
        vm.mockCall(WSGEM, abi.encodeWithSelector(Iwsgem.redeem.selector), abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(WsgemHookHelper.RedeemUnderpaid.selector, claim, 0));
        helper.unwrap(address(this), amtIn, 0);
        vm.clearMockedCalls();
    }

    /// @notice Defensive guard: if delivering the minted wsgem to the owner fails, the wrap reverts
    ///         `TransferFailed` (mock targets only the helper→owner leg; `mint` uses internal accounting).
    function test_wrapRevertsWhenOutputTransferFails() public {
        uint256 amtIn = 1_000 * WAD;
        _approveHelper(GEM, amtIn);
        vm.mockCall(WSGEM, abi.encodeWithSelector(IERC20Minimal.transfer.selector), abi.encode(false));
        vm.expectRevert(WsgemHookHelper.TransferFailed.selector);
        helper.wrapAll(address(this), 0);
        vm.clearMockedCalls();
    }

    /// @notice Defensive guard: if delivering the redeemed gem to the owner fails, the unwrap reverts
    ///         `TransferFailed`. The mock targets only the helper→owner leg (`to == address(this)`), so the
    ///         wrapper's own redeem payout (paid to the helper) still settles.
    function test_unwrapRevertsWhenOutputTransferFails() public {
        uint256 amtIn = 1_000 * WAD;
        uint256 q = quoter.quoteExactInput(false, amtIn);
        _approveHelper(WSGEM, amtIn);
        vm.mockCall(GEM, abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(this), q), abi.encode(false));
        vm.expectRevert(WsgemHookHelper.TransferFailed.selector);
        helper.unwrap(address(this), amtIn, 0);
        vm.clearMockedCalls();
    }
}
