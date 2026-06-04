// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WstGBPForkBase} from "./base/WstGBPForkBase.sol";
import {WstGBPBackstopHook} from "../src/WstGBPBackstopHook.sol";
import {WstGBPSwapRouter} from "../src/periphery/WstGBPSwapRouter.sol";
import {WstGBPQuoter} from "../src/periphery/WstGBPQuoter.sol";
import {IwstGBP} from "../src/interfaces/IwstGBP.sol";

/// @notice Stateful (invariant) suite for the pure-backstop hook. A `Handler` drives long, randomly
///         interleaved sequences of the four swap modes through the settle-first router, and the
///         invariants assert the cross-sequence safety properties the stateless tests can't reach:
///
///         1. The actor can never extract value — at a constant oracle price, mark-to-NAV value is
///            non-increasing over ANY sequence (every leg crosses the bid/ask spread, `bc <= nav <= mc`,
///            and all rounding favors the protocol). This is the core anti-MEV / anti-rounding property.
///         2. The ownerless hook is never net-drained and never accumulates more than ~1 wei of exact-out
///            rounding dust per exact-out swap.
///         3. The quoter equals execution for every single swap in the sequence (recorded, not asserted,
///            inside the handler — see the note on `fail_on_revert` below).
///         4. The pool never holds AMM liquidity (LP is permanently blocked).
///
/// @dev The price is held at the live forked NAV for the whole run (no oracle nudging): valuing the
///      actor's position at a moving price would conflate a legitimate NAV-ratchet mark-to-market gain
///      with extraction. Price-as-a-variable parity/round-trip checks live in the stateless fuzz suite.
///
/// @dev `fail_on_revert = false` (configured in foundry.toml) lets random oracle/amount combos that hit a
///      dust/funding/capacity edge be discarded instead of failing the run. Because a failed `assertEq`
///      *inside* a handler is itself a revert (which would be swallowed), the handler NEVER asserts: it
///      records any quoter/execution mismatch into a ghost counter, and `invariant_quoterMatchesExecution`
///      surfaces it. So no real property violation can be masked by the lenient revert handling.
contract WstGBPBackstopHookInvariants is WstGBPForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    Handler internal handler;
    uint256 internal navAtStart;
    uint256 internal initialActorValue;

    function setUp() public override {
        super.setUp();

        // Over-fund the wrapper's tGBP reserves so the sell path is never underfunded, regardless of the
        // random sequence — we want to exercise the math, not the (separately tested) funding guard.
        deal(TGBP, WST, 50_000_000 * WAD);

        handler = new Handler(router, quoter, hook, wrapper, key, TGBP, WST);

        // Endow the actor (the handler): plenty of tGBP, plus a slice of the wstGBP minted in base setUp.
        deal(TGBP, address(handler), 5_000_000 * WAD);
        IERC20Minimal(WST).transfer(address(handler), 200_000 * WAD);

        navAtStart = wrapper.navprice();
        initialActorValue = _actorValue();

        // Fuzz ONLY the four swap actions (router approvals happen in the handler's constructor, so there
        // is no setup method to waste calls on re-approving).
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Handler.buyExactIn.selector;
        selectors[1] = Handler.sellExactIn.selector;
        selectors[2] = Handler.buyExactOut.selector;
        selectors[3] = Handler.sellExactOut.selector;
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
        // Proof sketch (holds for every mode, since bc <= nav <= mc and outputs floor / inputs ceil):
        // each swap's exact change in (t + w*nav) is <= 0; the single floor in the valuation costs < 1
        // wei, so the integer value can never exceed the integer start value. Allow +1 wei of slack.
        assertLe(_actorValue(), initialActorValue + 1, "actor extracted value from the backstop");
    }

    /// @notice The ownerless hook is never net-drained; it only ever accrues <= 1 wei of exact-out dust
    ///         per exact-out swap (buys leave wstGBP dust, sells leave tGBP dust). It never pays out from
    ///         its own balance, so an attacker can neither drain it nor subsidize pricing into it.
    function invariant_hookHoldsOnlyBoundedDust() public view {
        assertLe(IERC20Minimal(WST).balanceOf(address(hook)), handler.exactOutBuys(), "wstGBP dust exceeds bound");
        assertLe(IERC20Minimal(TGBP).balanceOf(address(hook)), handler.exactOutSells(), "tGBP dust exceeds bound");
    }

    /// @notice The quoter matched execution on every swap in the sequence (recorded by the handler).
    function invariant_quoterMatchesExecution() public view {
        assertEq(handler.parityFailures(), 0, "quoter diverged from execution");
    }

    /// @notice The pool holds no AMM liquidity — `beforeAddLiquidity` reverts, so none can ever be added.
    ///         (The hook never calls `PoolManager.mint`, so it also cannot accrue ERC-6909 claims; it only
    ///         `take`s real tokens transiently and settles them within the same lock.)
    function invariant_noLiquidity() public view {
        assertEq(PM.getLiquidity(key.toId()), 0, "pool acquired AMM liquidity");
    }
}

/// @notice Drives bounded, valid swaps through the router and records quoter/execution parity. Holds the
///         actor's tokens and is the sole `targetContract`. Never asserts (see suite note); records
///         mismatches into `parityFailures` for an invariant to surface.
contract Handler is Test {
    WstGBPSwapRouter internal immutable router;
    WstGBPQuoter internal immutable quoter;
    WstGBPBackstopHook internal immutable hook;
    IwstGBP internal immutable wrapper;
    PoolKey internal key;
    address internal immutable tgbp;
    address internal immutable wst;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_AMT = 100_000 * 1e18; // per-swap cap, well within the actor's endowment

    // Ghosts
    uint256 public parityFailures;
    uint256 public exactOutBuys;
    uint256 public exactOutSells;
    uint256 public totalSwaps;

    constructor(
        WstGBPSwapRouter _router,
        WstGBPQuoter _quoter,
        WstGBPBackstopHook _hook,
        IwstGBP _wrapper,
        PoolKey memory _key,
        address _tgbp,
        address _wst
    ) {
        router = _router;
        quoter = _quoter;
        hook = _hook;
        wrapper = _wrapper;
        key = _key;
        tgbp = _tgbp;
        wst = _wst;
        // One-time approvals (setup-only; not a fuzzable action). `approve` needs no balance.
        IERC20Minimal(_tgbp).approve(address(_router), type(uint256).max);
        IERC20Minimal(_wst).approve(address(_router), type(uint256).max);
    }

    function buyExactIn(uint256 amt) public {
        uint256 mc = wrapper.mintcost();
        uint256 bal = IERC20Minimal(tgbp).balanceOf(address(this));
        if (bal < mc + 2) return; // need to clear the wrapper's dust floor (amt >= mintcost)
        amt = bound(amt, mc + 1, _min(bal, MAX_AMT));
        uint256 q = quoter.quoteExactInput(true, amt);
        uint256 out = router.swapExactInput(key, true, amt, 0, address(this), block.timestamp);
        if (out != q) parityFailures++;
        totalSwaps++;
    }

    function sellExactIn(uint256 amt) public {
        uint256 bal = IERC20Minimal(wst).balanceOf(address(this));
        if (bal < WAD) return; // wrapper redeem minimum is 1 wstGBP
        amt = bound(amt, WAD, _min(bal, MAX_AMT));
        uint256 q = quoter.quoteExactInput(false, amt);
        uint256 out = router.swapExactInput(key, false, amt, 0, address(this), block.timestamp);
        if (out != q) parityFailures++;
        totalSwaps++;
    }

    function buyExactOut(uint256 amtOut) public {
        uint256 bal = IERC20Minimal(tgbp).balanceOf(address(this));
        amtOut = bound(amtOut, WAD, MAX_AMT);
        uint256 q = quoter.quoteExactOutput(true, amtOut);
        if (q == 0 || q > bal) return;
        uint256 spent = router.swapExactOutput(key, true, amtOut, q, address(this), block.timestamp);
        if (spent != q) parityFailures++;
        exactOutBuys++;
        totalSwaps++;
    }

    function sellExactOut(uint256 amtOut) public {
        uint256 bal = IERC20Minimal(wst).balanceOf(address(this));
        amtOut = bound(amtOut, WAD, MAX_AMT);
        uint256 wIn = quoter.quoteExactOutput(false, amtOut);
        if (wIn < WAD || wIn > bal) return; // redeem minimum + actor balance
        uint256 spent = router.swapExactOutput(key, false, amtOut, wIn, address(this), block.timestamp);
        if (spent != wIn) parityFailures++;
        exactOutSells++;
        totalSwaps++;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
