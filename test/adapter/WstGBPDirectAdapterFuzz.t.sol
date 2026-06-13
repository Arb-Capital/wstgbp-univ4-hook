// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WstGBPAdapterForkBase} from "../base/WstGBPAdapterForkBase.sol";

/// @notice Adversarial math/attack-vector fuzz for the direct adapter, mirroring the v4 hook's fuzz suite:
///         the adapter's quote == its execution == the independent {WstGBPQuoter} across the WHOLE oracle
///         price range (NAV driven 0.01–100 WAD via `vm.store`), exact-output is the fair ceiling with no
///         over-charge, and a buy→sell round-trip can never profit (the wrapper's ~25bps spread always
///         costs the taker). The wrapper is over-funded and the actor over-dealt so parity is never masked
///         by a funding/capacity edge.
contract WstGBPDirectAdapterFuzzTest is WstGBPAdapterForkBase {
    uint256 internal constant NAV_LO = 0.01e18;
    uint256 internal constant NAV_HI = 100e18;
    uint256 internal constant BUY_CAP = 100_000 * 1e18; // tGBP in
    uint256 internal constant SELL_CAP = 300_000 * 1e18; // wstGBP in (< the ~495k minted in setUp)

    function setUp() public override {
        super.setUp();
        // Ample balances so the parity sweep is never bounded by the actor's funds or the wrapper's tGBP
        // reserves at high NAV. Dealing tGBP touches neither price (oracle-driven) nor wstGBP supply.
        deal(TGBP, address(this), 500_000_000 * WAD);
        deal(TGBP, WST, 5_000_000_000 * WAD);
    }

    // --- Quote == execution across the whole price range (all four modes) ---

    function testFuzz_buyExactInParity(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, wrapper.mintcost(), BUY_CAP); // >= mint dust threshold
        uint256 q = adapter.quoteExactInput(TGBP, amtIn);
        assertEq(q, quoter.quoteExactInput(true, amtIn), "adapter==quoter");
        assertEq(_adapterIn(true, amtIn), q, "exec==quote");
    }

    function testFuzz_sellExactInParity(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, WAD, SELL_CAP); // >= redeem minimum (1 wstGBP)
        uint256 q = adapter.quoteExactInput(WST, amtIn);
        assertEq(q, quoter.quoteExactInput(false, amtIn), "adapter==quoter");
        assertEq(_adapterIn(false, amtIn), q, "exec==quote");
    }

    function testFuzz_buyExactOutParity(uint256 nav, uint256 amtOut) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtOut = bound(amtOut, WAD, BUY_CAP);
        uint256 q = adapter.quoteExactOutput(TGBP, amtOut);
        assertEq(q, quoter.quoteExactOutput(true, amtOut), "adapter==quoter");
        assertEq(_adapterOut(true, amtOut, q + 10 * WAD), q, "exec==quote");
    }

    function testFuzz_sellExactOutParity(uint256 nav, uint256 amtOut) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        // Bound the tGBP output so the implied wstGBP input (≈ amtOut/burncost) stays within both the
        // redeem minimum (1 wstGBP) and the actor's ~495k holdings across the whole NAV range.
        uint256 bc = wrapper.burncost();
        amtOut = bound(amtOut, bc, SELL_CAP * bc / WAD);
        uint256 q = adapter.quoteExactOutput(WST, amtOut);
        assertEq(q, quoter.quoteExactOutput(false, amtOut), "adapter==quoter");
        assertEq(_adapterOut(false, amtOut, q + 10 * WAD), q, "exec==quote");
    }

    // --- A buy→sell round-trip can never profit (the spread always costs the taker) ---

    function testFuzz_roundTripNeverProfits(uint256 nav, uint256 amtIn) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtIn = bound(amtIn, wrapper.mintcost(), BUY_CAP);
        uint256 t0 = _bal(TGBP, address(this));
        uint256 wOut = _adapterIn(true, amtIn);
        if (wOut == 0) return; // sub-dust rounded to zero output; nothing to sell back
        _adapterIn(false, wOut);
        assertLe(_bal(TGBP, address(this)), t0, "round-trip cannot increase tGBP");
    }

    // --- Exact-output never over-charges beyond a 1-wei ceiling vs the exact-input inverse ---

    function testFuzz_exactOutBuyNoOvercharge(uint256 nav, uint256 amtOut) public {
        _setNav(bound(nav, NAV_LO, NAV_HI));
        amtOut = bound(amtOut, WAD, BUY_CAP);
        uint256 inExact = adapter.quoteExactOutput(TGBP, amtOut); // ceil(amtOut * mintcost / WAD)
        // The wstGBP actually delivered for `inExact` tGBP is >= amtOut and over-delivers only by bounded
        // dust; charging one wei less would under-deliver.
        uint256 deliveredFor = adapter.quoteExactInput(TGBP, inExact);
        assertGe(deliveredFor, amtOut, "exact-out input covers the requested output");
        if (inExact > 0) {
            uint256 deliveredForLess = adapter.quoteExactInput(TGBP, inExact - 1);
            assertLt(deliveredForLess, amtOut, "one wei less input would under-deliver (input is the fair ceiling)");
        }
    }
}
