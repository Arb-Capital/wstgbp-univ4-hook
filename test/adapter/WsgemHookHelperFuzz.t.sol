// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WsgemAdapterForkBase} from "../base/WsgemAdapterForkBase.sol";
import {WsgemHookHelper} from "../../src/adapter/WsgemHookHelper.sol";

/// @notice Adversarial fuzz for the owner-bound CoW-hook helper, mirroring the adapter's fuzz suite:
///         wrap/unwrap execution equals the independent {WsgemQuoter} across the WHOLE oracle price range
///         (NAV driven 0.01–100 WAD via `vm.store`), always with an untrusted third-party executor, and a
///         forced wrap→unwrap round-trip can never profit anyone — the owner only ever pays the wrapper's
///         ~25bps spread, and the executor's balances never move.
contract WsgemHookHelperFuzzTest is WsgemAdapterForkBase {
    WsgemHookHelper helper;

    address constant TRAMPOLINE = address(0x7EA111);

    uint256 internal constant NAV_LO = 0.01e18;
    uint256 internal constant NAV_HI = 100e18;
    uint256 internal constant WRAP_CAP = 100_000 * 1e18; // gem in
    uint256 internal constant UNWRAP_CAP = 300_000 * 1e18; // wsgem in (< the ~495k minted in setUp)

    function setUp() public override {
        super.setUp();
        helper = new WsgemHookHelper(wrapper);
        // Ample balances so the parity sweep is never bounded by the owner's funds or the wrapper's gem
        // reserves at high NAV (matches the adapter fuzz suite).
        deal(GEM, address(this), 500_000_000 * WAD);
        deal(GEM, WSGEM, 5_000_000_000 * WAD);
    }

    // --- Execution == quoter across the whole price range, via the untrusted executor ---

    function testFuzz_wrapAllParity(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, wrapper.mintcost(), WRAP_CAP); // >= mint dust threshold
        IERC20Minimal(GEM).approve(address(helper), amtIn); // exact approval = the sweep cap
        uint256 q = quoter.quoteExactInput(true, amtIn);
        uint256 w0 = _bal(WSGEM, address(this));

        vm.prank(TRAMPOLINE);
        uint256 out = helper.wrapAll(address(this), q);

        assertEq(out, q, "wrap exec == quoter");
        assertEq(_bal(WSGEM, address(this)), w0 + q, "owner received exactly the quote");
        assertEq(_bal(GEM, address(helper)), 0, "helper retains no gem");
        assertEq(_bal(WSGEM, address(helper)), 0, "helper retains no wsgem");
    }

    function testFuzz_unwrapParity(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, WAD, UNWRAP_CAP); // >= redeem minimum (1 wsgem)
        IERC20Minimal(WSGEM).approve(address(helper), amtIn);
        uint256 q = quoter.quoteExactInput(false, amtIn);
        uint256 t0 = _bal(GEM, address(this));

        vm.prank(TRAMPOLINE);
        uint256 out = helper.unwrap(address(this), amtIn, q);

        assertEq(out, q, "unwrap exec == quoter");
        assertEq(_bal(GEM, address(this)), t0 + q, "owner received exactly the quote");
        assertEq(_bal(GEM, address(helper)), 0, "helper retains no gem");
        assertEq(_bal(WSGEM, address(helper)), 0, "helper retains no wsgem");
    }

    function testFuzz_unwrapAllParity(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, WAD, UNWRAP_CAP);
        IERC20Minimal(WSGEM).approve(address(helper), amtIn); // allowance caps the sweep below balance
        uint256 q = quoter.quoteExactInput(false, amtIn);

        vm.prank(TRAMPOLINE);
        assertEq(helper.unwrapAll(address(this), q), q, "allowance-capped sweep exec == quoter");
    }

    // --- A forced wrap→unwrap round-trip can never profit anyone ---

    function testFuzz_forcedRoundTripNeverProfits(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, wrapper.mintcost(), WRAP_CAP);
        uint256 t0 = _bal(GEM, address(this));
        uint256 w0 = _bal(WSGEM, address(this));

        IERC20Minimal(GEM).approve(address(helper), amtIn);
        vm.prank(TRAMPOLINE);
        uint256 wOut = helper.wrapAll(address(this), 0);

        IERC20Minimal(WSGEM).approve(address(helper), wOut);
        vm.prank(TRAMPOLINE);
        helper.unwrapAll(address(this), 0);

        assertLe(_bal(GEM, address(this)), t0, "round-trip cannot increase the owner's gem");
        assertEq(_bal(WSGEM, address(this)), w0, "owner's wsgem is back to the start");
        assertEq(_bal(GEM, TRAMPOLINE), 0, "executor extracted no gem");
        assertEq(_bal(WSGEM, TRAMPOLINE), 0, "executor extracted no wsgem");
    }
}
