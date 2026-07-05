// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {WethWstGbpForkBase} from "./base/WethWstGbpForkBase.sol";
import {POLCompounder} from "../src/weth/POLCompounder.sol";
import {OracleLib} from "../src/weth/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";

/// @dev Always-false transfer token for the sweep failure branch.
contract FalseToken {
    function balanceOf(address) external pure returns (uint256) {
        return 1e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Phase 7 fork suite: the POLCompounder as the pool's SOLE liquidity (the fixture's base POL
///         is removed in setUp so every fee/donation accrues to the compounder — deterministic
///         accounting). Bootstrap = fund + compound(); fees accrue via real swaps or donate().
contract POLCompounderTest is WethWstGbpForkBase {
    using StateLibrary for IPoolManager;

    POLCompounder comp;
    PoolDonateTest donateRouter;

    // Ratio-matched 50/50 seed at the fixture fair (1904.7619 wstGBP/WETH): the geometric-symmetric
    // range wants equal value per side at its center, so the bootstrap leaves ~zero dust.
    uint256 constant SEED_WSG = 100_000 * 1e18;
    uint256 constant SEED_WETH = 52.5 * 1e18;
    uint256 constant Q96 = 2 ** 96;

    function setUp() public override {
        super.setUp();
        _addLiquidity(-1e22); // remove the fixture POL: the compounder becomes the only LP

        comp = new POLCompounder(
            PM,
            key,
            tickLower,
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );
        vm.prank(owner);
        comp.setKeeper(address(this), true);

        donateRouter = new PoolDonateTest(PM);
        IERC20Minimal(WSGEM).approve(address(donateRouter), type(uint256).max);
        IERC20Minimal(WETH).approve(address(donateRouter), type(uint256).max);

        // Bootstrap: fund the compounder, first compound mints the initial position.
        IERC20Minimal(WSGEM).transfer(address(comp), SEED_WSG);
        IERC20Minimal(WETH).transfer(address(comp), SEED_WETH);
        uint128 minted = comp.compound();
        assertGt(minted, 0, "bootstrap minted the position");
    }

    function _positionLiquidity() internal view returns (uint128) {
        return PM.getPositionLiquidity(comp.poolId(), comp.positionKey());
    }

    /// @dev Arb the pool back to oracle fair (what searchers do continuously in production; the
    ///      keeper compounds when the pool sits at fair). Direction per orientation: raising sqrtP
    ///      needs WETH (currency1) in, lowering it needs wstGBP in.
    function _closeToFair() internal {
        uint160 target = _fairSqrtPriceX96(_fairWad());
        (uint160 sqrtNow,,,) = _slot0();
        uint128 liq = PM.getLiquidity(key.toId());
        if (target > sqrtNow) {
            uint256 wethIn = uint256(liq) * (target - sqrtNow) / Q96;
            if (wethIn > 0) _swap(false, -int256(wethIn));
        } else if (target < sqrtNow) {
            uint256 wsgIn = (uint256(liq) << 96) * (sqrtNow - target) / (uint256(target) * sqrtNow);
            if (wsgIn > 0) _swap(true, -int256(wsgIn));
        }
    }

    // ---------------------------------------------------------------- spec test 1: accrue + compound

    function test_accrueFeesThenCompound() public {
        uint128 liqBefore = _positionLiquidity();

        // Real swap flow both directions accrues fees to the (sole-LP) position; arbs then close
        // the pool back to fair, which is when a keeper compounds.
        _swap(true, -int256(2_000 * WAD));
        _swap(false, -int256(WAD));
        _closeToFair();
        (uint256 f0, uint256 f1) = comp.pendingFees();
        assertTrue(f0 > 0 || f1 > 0, "fees pending");
        (uint256 c0, uint256 c1) = comp.compoundable();
        assertGe(c0, f0);
        assertGe(c1, f1);

        uint128 added = comp.compound();
        assertGt(added, 0, "liquidity grew");
        assertGt(_positionLiquidity(), liqBefore);

        (f0, f1) = comp.pendingFees();
        assertEq(f0, 0, "fees swept");
        assertEq(f1, 0);
        // Dust is bounded: worth less than 0.5% of what was just compounded.
        uint256 dust0 = _bal(WSGEM, address(comp));
        uint256 dust1 = _bal(WETH, address(comp));
        assertLt(dust0 + dust1 * 2000, (c0 + c1 * 2000) / 200, "dust bounded");
    }

    function test_compoundNothingAccruedReverts() public {
        // Drain the bootstrap dust so there is genuinely nothing to work with.
        vm.startPrank(owner);
        comp.sweep(WSGEM, owner);
        comp.sweep(WETH, owner);
        vm.stopPrank();
        vm.expectRevert(POLCompounder.NothingToCompound.selector);
        comp.compound();
    }

    function test_dustCarriesOverIntoNextCompound() public {
        // A fee-scale one-sided remainder becomes dust after the first compound...
        IERC20Minimal(WSGEM).transfer(address(comp), 100 * 1e18);
        _swap(true, -int256(5_000 * WAD));
        _closeToFair();
        comp.compound();
        uint256 dust0 = _bal(WSGEM, address(comp));
        uint256 dust1 = _bal(WETH, address(comp));

        // ...and is counted (and consumed) by the next one.
        _swap(false, -int256(2 * WAD));
        _closeToFair();
        (uint256 f0, uint256 f1) = comp.pendingFees();
        (uint256 c0, uint256 c1) = comp.compoundable();
        assertEq(c0, f0 + dust0, "dust counted in compoundable");
        assertEq(c1, f1 + dust1);
        comp.compound();
    }

    // ---------------------------------------------------------------- spec test 2: sandwich

    function test_sandwichOutOfBoundsReverts() public {
        // A dominant wstGBP surplus (outweighing any bootstrap WETH dust) forces the rebalance to
        // SELL wstGBP...
        IERC20Minimal(WSGEM).transfer(address(comp), 2_000 * 1e18);
        // ...and the attacker pushes poolWad ~2% ABOVE fair — the adverse direction for a wstGBP
        // seller (paying more wstGBP per WETH than fair + tolerance allows).
        _swap(true, -int256(4_000 * WAD));

        vm.expectRevert(POLCompounder.PriceOutOfBounds.selector);
        comp.compound();
    }

    function test_inBoundsRebalanceSucceeds() public {
        // NOTE the tolerance budget: a wstGBP-selling rebalance's execution price includes the
        // hook's own mint-side base fee (30 bps), leaving ~20 bps of the 50 bps default for drift
        // + impact. Fee-scale surpluses (tiny impact) and a near-fair pool fit comfortably; this is
        // also why the keeper should compound when the pool sits at fair (runbook).
        IERC20Minimal(WSGEM).transfer(address(comp), 600 * 1e18);
        _swap(true, -int256(100 * WAD)); // ~5 bps drift

        vm.recordLogs();
        uint128 added = comp.compound();
        assertGt(added, 0);
        // The rebalance swap executed (RebalanceSwap emitted) and no bound reverted.
        bool sawRebalance;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("RebalanceSwap(bool,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(comp) && logs[i].topics[0] == sig) sawRebalance = true;
        }
        assertTrue(sawRebalance, "rebalance executed within bounds");
    }

    function test_fallbackModeSkipsRebalanceButCompounds() public {
        // Both-sided funds with a wstGBP surplus: the balanced portion compounds even though the
        // oracle is down; the surplus must NOT be traded (no oracle bound available).
        IERC20Minimal(WSGEM).transfer(address(comp), 20_000 * 1e18);
        IERC20Minimal(WETH).transfer(address(comp), 5 * 1e18);
        _brickFeed(ETH_USD_FEED);

        vm.recordLogs();
        uint128 added = comp.compound();
        assertGt(added, 0, "balanced portion still compounds");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSkip;
        bool sawRebalance;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(comp)) continue;
            if (logs[i].topics[0] == keccak256("RebalanceSkipped(uint8)")) {
                assertEq(abi.decode(logs[i].data, (uint8)), 1, "skip reason: oracle fallback");
                sawSkip = true;
            }
            if (logs[i].topics[0] == keccak256("RebalanceSwap(bool,uint256,uint256)")) sawRebalance = true;
        }
        assertTrue(sawSkip, "skip emitted");
        assertFalse(sawRebalance, "never trades without an oracle bound");
        assertGt(_bal(WSGEM, address(comp)), 0, "one-sided remainder carried as dust");
    }

    /// @notice The `_fitLiquidity` rounding guard, exercised directly (via {FitHarness}): an
    ///         over-promising liquidity is decremented to the largest value whose ROUND-UP amounts
    ///         fit the availables. Unreachable through `compound()` itself — an L computed by
    ///         `getLiquidityForAmounts` from the same availables at the same price always fits by
    ///         the libraries' rounding directions (pinned by the fuzz below); the guard is
    ///         defense-in-depth against that lemma drifting under a library change.
    function test_fitLiquidityDecrementsOverPromisedInput() public {
        FitHarness h = _fitHarness();
        (uint160 sqrtP,,,) = _slot0();
        uint256 a0 = 1_000 * WAD;
        uint256 a1 = a0 * SEED_WETH / SEED_WSG;
        uint128 honest =
            LiquidityAmounts.getLiquidityForAmounts(sqrtP, comp.sqrtLowerX96(), comp.sqrtUpperX96(), a0, a1);
        assertGt(honest, 0, "availables fund a position");

        // Feed the guard a deliberately over-promising L: it must land exactly on the largest
        // fitting value — which is the honest L (round-up amounts at honest+k exceed an available).
        uint128 fitted = h.exposedFitLiquidity(sqrtP, honest + 3, a0, a1);
        assertLt(fitted, honest + 3, "guard decremented");
        assertTrue(h.exposedFits(sqrtP, fitted, a0, a1), "landed value fits");
        assertFalse(h.exposedFits(sqrtP, fitted + 1, a0, a1), "landed value is the largest fitting one");

        // Degenerate input: nothing fits at all => clamps to zero (compound would then revert
        // NothingToCompound rather than attempt an unsettleable add).
        assertEq(h.exposedFitLiquidity(sqrtP, 5, 0, 0), 0, "unfundable input clamps to zero");
    }

    /// @notice Pins the lemma that makes the guard a no-op in the real flow: for ANY availables,
    ///         the liquidity `getLiquidityForAmounts` computes from them already fits its own
    ///         round-up charging at the same price.
    function testFuzz_forwardLiquidityAlwaysFits(uint256 a0, uint256 a1) public {
        FitHarness h = _fitHarness();
        (uint160 sqrtP,,,) = _slot0();
        a0 = bound(a0, 0, 1e30);
        a1 = bound(a1, 0, 1e30);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(sqrtP, comp.sqrtLowerX96(), comp.sqrtUpperX96(), a0, a1);
        if (l == 0) return;
        assertTrue(h.exposedFits(sqrtP, l, a0, a1), "forward-computed L fits round-up charging");
        assertEq(h.exposedFitLiquidity(sqrtP, l, a0, a1), l, "guard is a no-op on honest input");
    }

    function _fitHarness() internal returns (FitHarness) {
        return new FitHarness(
            PM,
            key,
            tickLower,
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );
    }

    // ---------------------------------------------------------------- spec test 3: idle drag

    /// @dev Threshold-triggered compounding drag vs the analytic estimate feeAPR^2/(2N): donate the
    ///      period's fee then compound, N periods — exactly the (1+f/N)^N vs e^f comparison. With
    ///      f = 20% APR and N = 12 the analytic drag is ~0.20%; assert within [0.5x, 2x].
    function test_idleDragWithinAnalyticEstimate() public {
        uint256 f = 0.2e18; // 20% fee APR (WAD)
        uint256 n = 12;
        // Start clean: bootstrap dust would otherwise be folded into the first compound and inflate
        // realized growth beyond the pure donation stream being measured.
        vm.startPrank(owner);
        comp.sweep(WSGEM, owner);
        comp.sweep(WETH, owner);
        vm.stopPrank();
        uint128 liq0 = _positionLiquidity();

        for (uint256 i = 0; i < n; i++) {
            // Period fee = V * f/N, donated 50/50 in value at the (unchanged) pool price.
            uint256 vWsg = _positionValueWsg();
            uint256 periodFee = vWsg * f / 1e18 / n;
            uint256 wsgHalf = periodFee / 2;
            uint256 wethHalf = periodFee / 2 * WAD / _poolPriceWsgPerWeth();
            donateRouter.donate(key, wsgHalf, wethHalf, "");
            comp.compound();
        }

        // Realized growth vs continuous compounding e^f (donation price never moved).
        uint256 realized = uint256(_positionLiquidity()) * 1e18 / liq0; // value ∝ L at fixed price
        uint256 continuous = 1221402758160169833; // e^0.2 WAD
        uint256 drag = continuous - realized; // WAD growth shortfall
        uint256 analytic = uint256(f) * f / 1e18 / (2 * n) * continuous / 1e18; // f^2/(2N)*e^f
        emit log_named_uint("realized growth (wad)", realized);
        emit log_named_uint("drag (wad)", drag);
        emit log_named_uint("analytic drag (wad)", analytic);
        assertLt(drag, 2 * analytic, "drag < 2x analytic");
        assertGt(drag, analytic / 2, "drag > 0.5x analytic");
    }

    function _positionValueWsg() internal view returns (uint256) {
        // Position amounts (wstGBP = currency0, WETH = currency1) valued at the pool price.
        (uint160 sqrtP,,,) = _slot0();
        uint128 l = _positionLiquidity();
        uint256 wsg = SqrtPriceMath.getAmount0Delta(sqrtP, comp.sqrtUpperX96(), l, false);
        uint256 weth = SqrtPriceMath.getAmount1Delta(comp.sqrtLowerX96(), sqrtP, l, false);
        return wsg + weth * _poolPriceWsgPerWeth() / 1e18;
    }

    function _poolPriceWsgPerWeth() internal view returns (uint256) {
        (uint160 sqrtP,,,) = _slot0();
        return OracleLib.poolPriceWstGbpPerWethWad(sqrtP, true);
    }

    // ---------------------------------------------------------------- hardening

    function test_constructorRejectsInvalidRange() public {
        vm.expectRevert(POLCompounder.InvalidRange.selector);
        new POLCompounder(
            PM,
            key,
            tickUpper,
            tickLower,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        ); // inverted

        vm.expectRevert(POLCompounder.InvalidRange.selector);
        new POLCompounder(
            PM,
            key,
            tickLower + 1, // off-spacing
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );
    }

    function test_constructorRejectsMismatchedKey() public {
        // Wrong currencies (tGBP instead of wstGBP).
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(GEM < WETH ? GEM : WETH);
        bad.currency1 = Currency.wrap(GEM < WETH ? WETH : GEM);
        vm.expectRevert(POLCompounder.PoolKeyMismatch.selector);
        new POLCompounder(
            PM,
            bad,
            tickLower,
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );

        // Static fee instead of the dynamic flag.
        bad = key;
        bad.fee = 3000;
        vm.expectRevert(POLCompounder.PoolKeyMismatch.selector);
        new POLCompounder(
            PM,
            bad,
            tickLower,
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );

        // A hook wired to different feeds than the compounder was given.
        bad = key;
        address fakeEth = makeAddr("other eth feed");
        vm.expectRevert(POLCompounder.PoolKeyMismatch.selector);
        new POLCompounder(
            PM, bad, tickLower, tickUpper, IAggregatorV3(fakeEth), IAggregatorV3(GBP_USD_FEED), wrapper, WETH, owner
        );

        // A key whose hook is not a WethWstGbpHook at all (no getters to answer).
        bad = key;
        bad.hooks = IHooks(makeAddr("not a hook"));
        vm.expectRevert();
        new POLCompounder(
            PM,
            bad,
            tickLower,
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );

        // A PoolManager that isn't the one the hook is bound to.
        vm.expectRevert(POLCompounder.PoolKeyMismatch.selector);
        new POLCompounder(
            IPoolManager(makeAddr("other pm")),
            key,
            tickLower,
            tickUpper,
            IAggregatorV3(ETH_USD_FEED),
            IAggregatorV3(GBP_USD_FEED),
            wrapper,
            WETH,
            owner
        );
    }

    function test_poolKeyView() public view {
        assertEq(keccak256(abi.encode(comp.poolKey())), keccak256(abi.encode(key)), "reconstructed key matches");
    }

    function test_sweepRevertsOnFailingToken() public {
        FalseToken bad = new FalseToken();
        vm.prank(owner);
        vm.expectRevert(POLCompounder.TransferFailed.selector);
        comp.sweep(address(bad), owner);
    }

    function test_sandwichOtherDirectionAlsoBounded() public {
        // WETH-dominant surplus forces the rebalance to SELL WETH; the attacker depresses poolWad
        // (sells WETH into the pool) so the sale receives too few wstGBP per WETH.
        IERC20Minimal(WETH).transfer(address(comp), 2 * 1e18);
        _swap(false, -int256(2 * WAD));

        vm.expectRevert(POLCompounder.PriceOutOfBounds.selector);
        comp.compound();
    }

    function test_compoundOnlyKeeper() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(POLCompounder.NotKeeper.selector);
        comp.compound();
    }

    function test_keeperLifecycle() public {
        address k = makeAddr("keeper2");
        vm.prank(owner);
        comp.setKeeper(k, true);
        assertTrue(comp.isKeeper(k));
        vm.prank(owner);
        comp.setKeeper(k, false);
        assertFalse(comp.isKeeper(k));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        comp.setKeeper(k, true);
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(POLCompounder.NotPoolManager.selector);
        comp.unlockCallback("");
    }

    function test_toleranceBounds() public {
        vm.prank(owner);
        comp.setToleranceBps(500);
        assertEq(comp.toleranceBps(), 500);
        vm.prank(owner);
        vm.expectRevert(POLCompounder.ToleranceTooHigh.selector);
        comp.setToleranceBps(501);
    }

    function test_setStaleness() public {
        vm.prank(owner);
        comp.setStaleness(1000, 2000);
        assertEq(comp.ethUsdStalenessSec(), 1000);
        assertEq(comp.gbpUsdStalenessSec(), 2000);
    }

    function test_withdrawLiquidityFullReturnsPrincipalPlusFees() public {
        _swap(true, -int256(5_000 * WAD)); // accrue some fees
        address to = makeAddr("treasury");
        vm.prank(owner);
        (uint256 a0, uint256 a1) = comp.withdrawLiquidity(type(uint128).max, 0, 0, to);
        assertEq(_positionLiquidity(), 0, "position emptied");
        assertEq(_bal(WSGEM, to), a0);
        assertEq(_bal(WETH, to), a1);
        // Position value (plus retained dust) recovers >=99% of the fair-valued seed.
        uint256 fair = _fairWad();
        uint256 recovered = a0 + a1 * fair / WAD + _bal(WSGEM, address(comp)) + _bal(WETH, address(comp)) * fair / WAD;
        assertGt(recovered, (SEED_WSG + SEED_WETH * fair / WAD) * 99 / 100, "principal recovered");
    }

    function test_withdrawPartialAndSlippage() public {
        uint128 half = _positionLiquidity() / 2;
        vm.prank(owner);
        (uint256 a0,) = comp.withdrawLiquidity(half, 0, 0, owner);
        assertGt(a0, 0);
        assertGt(_positionLiquidity(), 0, "half remains");

        vm.prank(owner);
        vm.expectRevert(POLCompounder.WithdrawSlippage.selector);
        comp.withdrawLiquidity(1000, type(uint256).max, 0, owner);
    }

    function test_withdrawOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        comp.withdrawLiquidity(1, 0, 0, address(this));
    }

    function test_sweepOnlyOwnerAndFullBalance() public {
        uint256 dustBefore = _bal(WSGEM, address(comp)); // any bootstrap remainder
        IERC20Minimal(WSGEM).transfer(address(comp), 123e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        comp.sweep(WSGEM, address(this));

        address to = makeAddr("sink");
        vm.prank(owner);
        comp.sweep(WSGEM, to);
        assertEq(_bal(WSGEM, to), dustBefore + 123e18, "full balance swept");
        assertEq(_bal(WSGEM, address(comp)), 0);
    }

    function test_twoStepOwnership() public {
        address next = makeAddr("next owner");
        vm.prank(owner);
        comp.transferOwnership(next);
        assertEq(comp.owner(), owner);
        vm.prank(next);
        comp.acceptOwnership();
        assertEq(comp.owner(), next);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Random trade flow then compound: only declared reverts, dust bounded, liquidity grows.
    function testFuzz_randomFlowThenCompound(uint256 wsgIn, uint256 wethIn, bool order) public {
        wsgIn = bound(wsgIn, WAD, 20_000 * WAD);
        wethIn = bound(wethIn, WAD / 100, 10 * WAD);
        if (order) {
            _swap(true, -int256(wsgIn));
            _swap(false, -int256(wethIn));
        } else {
            _swap(false, -int256(wethIn));
            _swap(true, -int256(wsgIn));
        }
        uint128 before = _positionLiquidity();
        try comp.compound() returns (uint128 added) {
            assertGt(added, 0);
            assertEq(_positionLiquidity(), before + added);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == POLCompounder.NothingToCompound.selector || sel == POLCompounder.PriceOutOfBounds.selector,
                "only declared reverts"
            );
        }
    }
}

/// @dev White-box harness exposing the internal rounding-guard pair for direct unit coverage
///     (`_fitLiquidity`'s decrement is unreachable through `compound()` — see the tests above).
contract FitHarness is POLCompounder {
    constructor(
        IPoolManager pm,
        PoolKey memory key,
        int24 tickLower_,
        int24 tickUpper_,
        IAggregatorV3 ethUsd,
        IAggregatorV3 gbpUsd,
        Iwsgem wrapper_,
        address weth_,
        address owner_
    ) POLCompounder(pm, key, tickLower_, tickUpper_, ethUsd, gbpUsd, wrapper_, weth_, owner_) {}

    function exposedFitLiquidity(uint160 sqrtP, uint128 l, uint256 a0, uint256 a1) external view returns (uint128) {
        return _fitLiquidity(sqrtP, l, a0, a1);
    }

    function exposedFits(uint160 sqrtP, uint128 l, uint256 a0, uint256 a1) external view returns (bool) {
        return _fits(sqrtP, l, a0, a1);
    }
}
