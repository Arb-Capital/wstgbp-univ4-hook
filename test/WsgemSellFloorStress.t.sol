// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WsgemForkBase} from "./base/WsgemForkBase.sol";

/// @title WsgemSellFloorStressTest
/// @notice Swapper-economics regression for the backstop's SELL-side floor. The pure-backstop suite proves
///         the floor as single-shot extremes (under-reserved → revert; reserve == claim → full pay), but
///         never as a draining sequence. These tests make the floor's real-world shape explicit and asserted:
///         it is bounded by the wrapper's live gem reserve (NOT "infinite depth" like buys), it tracks that
///         reserve in real time, it reverts ENTIRELY when short (no partial fill — a seller must
///         self-fragment), and it is asymmetric — in a sell-side bank run buyers keep filling while sellers
///         are cut off. Complements `test_sellRevertsWhenWrapperUnderfunded` /
///         `test_sellSucceedsWhenWrapperFundedExactly` in {WsgemBackstopHookForkTest}.
contract WsgemSellFloorStressTest is WsgemForkBase {
    /// @notice Mass-exit narrative: three sellers drain a finite reserve. Reserves fall by exactly the claim
    ///         per exit; the seller who arrives once the reserve is short cannot exit in full (all-or-nothing
    ///         revert) and must self-fragment to the remaining reserve; at zero reserve the sell floor is gone
    ///         while a same-size BUY still mints.
    function test_sellFloorDrainsThenBricksWhileBuysStillWork() public {
        uint256 s = 1_000 * WAD; // one full exit chunk
        uint256 claimFull = quoter.quoteExactInput(false, s); // gem paid for a full chunk == s*burncost/WAD
        uint256 half = s / 2;
        uint256 claimHalf = quoter.quoteExactInput(false, half);

        // Finite reserve: enough for two full exits plus one half exit, and not one wei more.
        // `deal` overwrites the wrapper's gem balance, so the drain is fully deterministic.
        deal(GEM, WSGEM, 2 * claimFull + claimHalf);

        address a = makeAddr("sellerA");
        address b = makeAddr("sellerB");
        address c = makeAddr("sellerC");

        // Each seller holds one full chunk of wsgem (wsgem.transfer is safe: dst != wsgem, none are banned).
        IERC20Minimal(WSGEM).transfer(a, s);
        IERC20Minimal(WSGEM).transfer(b, s);
        IERC20Minimal(WSGEM).transfer(c, s);

        // Seller A exits in full; the reserve falls by exactly one claim (floor depth tracks reserves live).
        assertEq(_sellAs(a, s), claimFull, "A receives the full claim");
        assertEq(_bal(GEM, a), claimFull, "A holds the gem it was paid");
        assertEq(_bal(GEM, WSGEM), claimFull + claimHalf, "reserve down by one claim");

        // Seller B exits in full; the reserve now holds only a half-claim.
        assertEq(_sellAs(b, s), claimFull, "B receives the full claim");
        assertEq(_bal(GEM, WSGEM), claimHalf, "reserve down to a half-claim");

        // Seller C cannot exit in full: the claim exceeds the remaining reserve, so the sell reverts
        // ENTIRELY — the hook never burns wsgem into an underfunded redeem and never partial-fills.
        vm.prank(c);
        IERC20Minimal(WSGEM).approve(address(router), type(uint256).max);
        vm.prank(c);
        vm.expectRevert();
        router.swapExactInput(key, false, s, 0, c, block.timestamp);

        // C must self-fragment: a downsized exit sized to the remaining reserve clears and drains the
        // wrapper to exactly zero.
        vm.prank(c);
        assertEq(router.swapExactInput(key, false, half, 0, c, block.timestamp), claimHalf, "C's downsized exit");
        assertEq(_bal(GEM, WSGEM), 0, "reserve fully drained");

        // ASYMMETRY at zero reserve: the sell floor is gone (C still holds wsgem, but the sell reverts)...
        vm.prank(c);
        vm.expectRevert();
        router.swapExactInput(key, false, half, 0, c, block.timestamp);
        // ...while the BUY side is untouched — capacity (forced to max here) is its only bound, and minting
        // needs no gem reserve. Buyers keep filling through a sell-side run.
        assertGt(_swapIn(true, s), 0, "buys keep working during a sell-side bank run");

        _assertHookClean();
    }

    /// @notice The sell-side depth for a size `s` is exactly its claim (`s*burncost/WAD`): funded to the
    ///         claim the sell drains the reserve to zero; one wei short it reverts wholesale. Pins
    ///         "sell depth == reserve / burncost" across sizes, which the single-shot funding tests never state.
    function test_sellFloorBoundaryIsExactlyClaimAcrossSizes() public {
        _assertSellBoundary(1 * WAD);
        _assertSellBoundary(1_000 * WAD);
        _assertSellBoundary(50_000 * WAD);
    }

    /// @dev Sell `amountIn` wsgem as `seller` through the settle-first router (seller funds the input and
    ///      receives the gem).
    function _sellAs(address seller, uint256 amountIn) internal returns (uint256 out) {
        vm.prank(seller);
        IERC20Minimal(WSGEM).approve(address(router), type(uint256).max);
        vm.prank(seller);
        out = router.swapExactInput(key, false, amountIn, 0, seller, block.timestamp);
    }

    /// @dev Funded to exactly the claim a sell of `s` pays, the sell clears and drains the reserve to zero;
    ///      funded one wei short, the same sell reverts (strict `available < needed`, no partial fill).
    function _assertSellBoundary(uint256 s) internal {
        uint256 claim = quoter.quoteExactInput(false, s);

        deal(GEM, WSGEM, claim); // available == needed
        assertEq(_swapIn(false, s), claim, "funded sell pays the full claim");
        assertEq(_bal(GEM, WSGEM), 0, "drained to exactly zero");

        deal(GEM, WSGEM, claim - 1); // one wei short
        vm.expectRevert();
        _swapIn(false, s);
    }
}
