// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {MaseerForkBase} from "../base/MaseerForkBase.sol";
import {WstGBPDirectAdapter} from "../../src/adapter/WstGBPDirectAdapter.sol";
import {WstGBPQuoter} from "../../src/v4/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../../src/core/interfaces/IwstGBP.sol";

/// @notice Stateful (invariant) suite for the direct adapter — the analogue of the v4 hook's invariant
///         suite, but driving plain approve+swap calls instead of the settle-first router. An
///         `AdapterHandler` runs long, randomly interleaved sequences of the four swap modes and the
///         invariants assert the cross-sequence safety properties:
///
///         1. The actor can never extract value — at a constant oracle price, mark-to-NAV value is
///            non-increasing over ANY sequence (every leg crosses the bid/ask spread, `bc <= nav <= mc`,
///            and all rounding favors the protocol).
///         2. The ownerless adapter is never net-drained and only ever accrues <= 1 wei of exact-out
///            rounding dust per exact-out swap (buys leave wstGBP dust, sells leave tGBP dust).
///         3. The quoter equals execution for every single swap (recorded into a ghost, surfaced by an
///            invariant — the handler never asserts, since `fail_on_revert = false` would swallow it).
///
/// @dev Price is held at the live forked NAV for the whole run (see the v4 suite note); price-as-variable
///      parity/round-trip checks live in the stateless fuzz suite. There is no pool-liquidity invariant
///      here because the adapter never touches a Uniswap pool.
contract WstGBPDirectAdapterInvariants is MaseerForkBase {
    AdapterHandler internal handler;
    WstGBPDirectAdapter internal adapter;
    WstGBPQuoter internal quoter;
    uint256 internal navAtStart;
    uint256 internal initialActorValue;

    function setUp() public override {
        super.setUp();

        adapter = new WstGBPDirectAdapter(wrapper);
        quoter = new WstGBPQuoter(wrapper);

        // Mint a working stock of wstGBP into this test contract, then over-fund the wrapper's tGBP
        // reserves so the sell path is never underfunded across any random sequence.
        _seedWst(1_000_000 * WAD, 500_000 * WAD);
        deal(TGBP, WST, 50_000_000 * WAD);

        handler = new AdapterHandler(adapter, quoter, wrapper, TGBP, WST);

        // Endow the actor (the handler): plenty of tGBP, plus a slice of the minted wstGBP.
        deal(TGBP, address(handler), 5_000_000 * WAD);
        IERC20Minimal(WST).transfer(address(handler), 200_000 * WAD);

        navAtStart = wrapper.navprice();
        initialActorValue = _actorValue();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = AdapterHandler.buyExactIn.selector;
        selectors[1] = AdapterHandler.sellExactIn.selector;
        selectors[2] = AdapterHandler.buyExactOut.selector;
        selectors[3] = AdapterHandler.sellExactOut.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Actor's whole position valued in tGBP at the (constant) start NAV.
    function _actorValue() internal view returns (uint256) {
        uint256 t = IERC20Minimal(TGBP).balanceOf(address(handler));
        uint256 w = IERC20Minimal(WST).balanceOf(address(handler));
        return t + FullMath.mulDiv(w, navAtStart, WAD);
    }

    /// @notice No value extraction: at constant NAV the actor's mark-to-NAV value only ever decreases.
    function invariant_noValueExtraction() public view {
        assertLe(_actorValue(), initialActorValue + 1, "actor extracted value from the adapter");
    }

    /// @notice The ownerless adapter is never net-drained; it only accrues <= 1 wei of exact-out dust per
    ///         exact-out swap. It never pays out from its own balance, so it can be neither drained nor
    ///         used to subsidize pricing.
    function invariant_adapterHoldsOnlyBoundedDust() public view {
        assertLe(IERC20Minimal(WST).balanceOf(address(adapter)), handler.exactOutBuys(), "wstGBP dust exceeds bound");
        assertLe(IERC20Minimal(TGBP).balanceOf(address(adapter)), handler.exactOutSells(), "tGBP dust exceeds bound");
    }

    /// @notice The quoter matched execution on every swap in the sequence (recorded by the handler).
    function invariant_quoterMatchesExecution() public view {
        assertEq(handler.parityFailures(), 0, "quoter diverged from execution");
    }
}

/// @notice Drives bounded, valid swaps through the adapter and records quoter/execution parity. Holds the
///         actor's tokens and is the sole `targetContract`. Never asserts; records mismatches into
///         `parityFailures` for an invariant to surface.
contract AdapterHandler is Test {
    WstGBPDirectAdapter internal immutable adapter;
    WstGBPQuoter internal immutable quoter;
    IwstGBP internal immutable wrapper;
    address internal immutable tgbp;
    address internal immutable wst;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_AMT = 100_000 * 1e18; // per-swap cap, well within the actor's endowment

    // Ghosts
    uint256 public parityFailures;
    uint256 public exactOutBuys;
    uint256 public exactOutSells;
    uint256 public totalSwaps;

    constructor(WstGBPDirectAdapter _adapter, WstGBPQuoter _quoter, IwstGBP _wrapper, address _tgbp, address _wst) {
        adapter = _adapter;
        quoter = _quoter;
        wrapper = _wrapper;
        tgbp = _tgbp;
        wst = _wst;
        IERC20Minimal(_tgbp).approve(address(_adapter), type(uint256).max);
        IERC20Minimal(_wst).approve(address(_adapter), type(uint256).max);
    }

    function buyExactIn(uint256 amt) public {
        uint256 mc = wrapper.mintcost();
        uint256 bal = IERC20Minimal(tgbp).balanceOf(address(this));
        if (bal < mc + 2) return; // need to clear the wrapper's dust floor (amt >= mintcost)
        amt = bound(amt, mc + 1, _min(bal, MAX_AMT));
        uint256 q = adapter.quoteExactInput(tgbp, amt);
        uint256 out = adapter.swapExactInput(tgbp, amt, 0, address(this), block.timestamp);
        if (out != q) parityFailures++;
        totalSwaps++;
    }

    function sellExactIn(uint256 amt) public {
        uint256 bal = IERC20Minimal(wst).balanceOf(address(this));
        if (bal < WAD) return; // wrapper redeem minimum is 1 wstGBP
        amt = bound(amt, WAD, _min(bal, MAX_AMT));
        uint256 q = adapter.quoteExactInput(wst, amt);
        uint256 out = adapter.swapExactInput(wst, amt, 0, address(this), block.timestamp);
        if (out != q) parityFailures++;
        totalSwaps++;
    }

    function buyExactOut(uint256 amtOut) public {
        uint256 bal = IERC20Minimal(tgbp).balanceOf(address(this));
        amtOut = bound(amtOut, WAD, MAX_AMT);
        uint256 q = adapter.quoteExactOutput(tgbp, amtOut);
        if (q == 0 || q > bal) return;
        uint256 spent = adapter.swapExactOutput(tgbp, amtOut, q, address(this), block.timestamp);
        if (spent != q) parityFailures++;
        exactOutBuys++;
        totalSwaps++;
    }

    function sellExactOut(uint256 amtOut) public {
        uint256 bal = IERC20Minimal(wst).balanceOf(address(this));
        amtOut = bound(amtOut, WAD, MAX_AMT);
        uint256 wIn = adapter.quoteExactOutput(wst, amtOut);
        if (wIn < WAD || wIn > bal) return; // redeem minimum + actor balance
        uint256 spent = adapter.swapExactOutput(wst, amtOut, wIn, address(this), block.timestamp);
        if (spent != wIn) parityFailures++;
        exactOutSells++;
        totalSwaps++;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
