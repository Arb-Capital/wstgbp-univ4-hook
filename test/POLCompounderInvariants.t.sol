// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";

import {WethWstGbpForkBase} from "./base/WethWstGbpForkBase.sol";
import {SettableFeed} from "./base/SettableFeed.sol";
import {POLCompounder} from "../src/weth/POLCompounder.sol";
import {WethWstGbpHook} from "../src/weth/WethWstGbpHook.sol";
import {OracleLib} from "../src/weth/lib/OracleLib.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";

/// @notice Stateful (invariant) suite for {POLCompounder}. A handler interleaves fee accrual
///         (swaps + donations, with third-party LP coexisting — the fixture POL stays in place),
///         deviation-closing arb, oracle drift/breakage/healing, keeper compounds, and owner
///         withdraw/sweep/tolerance actions, and the invariants assert the custody properties:
///
///         1. Position principal only ever decreases through an owner withdraw — a compound can
///            never shrink it, and nothing but the compounder can touch its position (tracked
///            ghost == on-chain position liquidity at all times).
///         2. `compound()` never moves third-party funds (it spends only poked fees + own dust).
///         3. A successful compound harvests fully: `pendingFees()` is zero afterwards.
///         4. `compound()`/`withdrawLiquidity()` only ever revert with their two DECLARED reverts
///            (`NothingToCompound`, `PriceOutOfBounds`) — anything else is a violation.
///         5. The compounder never strands value as PM ERC-6909 claims.
///
/// @dev Kept as its own suite (not folded into {WethWstGbpHookInvariants}) because the compounder
///      has LEGITIMATE reverts that would pollute that suite's never-revert ghost, and its
///      rebalance-mid-unlock flow would force the fee mirror to model mid-lock slot0. Reduced
///      runs/depth: every compound is gas-heavy and the property space is smaller.
///      Oracle driving matches the hook suite: `vm.etch`ed {SettableFeed}s (journaled EVM state).
///
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 16
contract POLCompounderInvariants is WethWstGbpForkBase {
    using StateLibrary for IPoolManager;

    POLCompounder internal comp;
    CompounderHandler internal handler;

    function setUp() public override {
        super.setUp();

        // Etched settable feeds (see WethWstGbpHookInvariants NatSpec for the why + etch pitfall).
        vm.clearMockedCalls();
        SettableFeed impl = new SettableFeed();
        vm.etch(ETH_USD_FEED, address(impl).code);
        vm.etch(GBP_USD_FEED, address(impl).code);
        SettableFeed(ETH_USD_FEED).setReverting(false);
        SettableFeed(GBP_USD_FEED).setReverting(false);
        SettableFeed(ETH_USD_FEED).set(ETH_USD_ANSWER, block.timestamp);
        SettableFeed(GBP_USD_FEED).set(GBP_USD_ANSWER, block.timestamp);

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

        handler = new CompounderHandler(PM, key, comp, hook, swapRouter, new PoolDonateTest(PM), owner, address(this));

        vm.startPrank(owner);
        comp.setKeeper(address(this), true); // bootstrap keeper
        comp.setKeeper(address(handler), true);
        vm.stopPrank();

        // Bootstrap: seed the compounder and mint the initial position (the documented path).
        IERC20Minimal(WSGEM).transfer(address(comp), 20_000 * WAD);
        deal(WETH, address(comp), 10 * WAD);
        comp.compound();
        handler.syncTrackedLiquidity();

        // Endow the actor for fee-generating flow.
        IERC20Minimal(WSGEM).transfer(address(handler), 100_000 * WAD);
        deal(WETH, address(handler), 200 * WAD);

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = CompounderHandler.accrueViaSwaps.selector;
        selectors[1] = CompounderHandler.accrueViaSwaps.selector;
        selectors[2] = CompounderHandler.accrueViaSwaps.selector;
        selectors[3] = CompounderHandler.arbToFair.selector;
        selectors[4] = CompounderHandler.arbToFair.selector;
        selectors[5] = CompounderHandler.donateFees.selector;
        selectors[6] = CompounderHandler.driftEthUsd.selector;
        selectors[7] = CompounderHandler.brickOracle.selector;
        selectors[8] = CompounderHandler.healOracle.selector;
        selectors[9] = CompounderHandler.compoundAction.selector;
        selectors[10] = CompounderHandler.compoundAction.selector;
        selectors[11] = CompounderHandler.compoundAction.selector;
        selectors[12] = CompounderHandler.withdrawSome.selector;
        selectors[13] = CompounderHandler.ownerHousekeeping.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice A compound can never shrink the position (only owner withdraws may).
    function invariant_principalOnlyDecreasesViaWithdraw() public view {
        assertEq(handler.principalViolations(), 0, "compound shrank the position");
    }

    /// @notice On-chain position liquidity always equals the handler's tracked expectation —
    ///         no path other than compound (+) and owner withdraw (−) ever moved it.
    function invariant_principalTracked() public view {
        assertEq(
            PM.getPositionLiquidity(comp.poolId(), comp.positionKey()),
            handler.trackedLiquidity(),
            "position liquidity moved outside compound/withdraw"
        );
    }

    /// @notice `compound()` spends only the compounder's own fees/dust — never third-party funds.
    function invariant_compoundPullsNoExternalFunds() public view {
        assertEq(handler.externalPullViolations(), 0, "compound moved external balances");
    }

    /// @notice A successful compound leaves no un-harvested fees behind.
    function invariant_compoundHarvestsFully() public view {
        assertEq(handler.harvestResidueViolations(), 0, "pendingFees nonzero after compound");
    }

    /// @notice Keeper/owner paths only revert with their declared reverts.
    function invariant_onlyDeclaredReverts() public view {
        assertEq(handler.unexpectedCompoundReverts(), 0, "compound reverted unexpectedly");
        assertEq(handler.unexpectedWithdrawReverts(), 0, "withdraw reverted unexpectedly");
    }

    /// @notice The compounder never mints PM ERC-6909 claims — no value can strand there.
    function invariant_noDanglingPmClaims() public view {
        assertEq(
            IERC6909Claims(address(PM)).balanceOf(address(comp), uint256(uint160(Currency.unwrap(key.currency0)))),
            0,
            "dangling currency0 claims"
        );
        assertEq(
            IERC6909Claims(address(PM)).balanceOf(address(comp), uint256(uint160(Currency.unwrap(key.currency1)))),
            0,
            "dangling currency1 claims"
        );
    }
}

/// @notice Drives the compounder's world and records custody violations into ghosts (never asserts).
contract CompounderHandler is Test {
    using StateLibrary for IPoolManager;

    bytes32 internal constant PRICE_SLOT = keccak256("maseer.price.price");
    uint256 internal constant WAD = 1e18;
    int256 internal constant ETH_ANCHOR = 2500e8;
    int256 internal constant GBP_ANCHOR = 1.25e8;
    uint256 internal constant NAV_ANCHOR = 1.05e18;

    IPoolManager internal immutable pm;
    POLCompounder internal immutable comp;
    WethWstGbpHook internal immutable hook;
    PoolSwapTest internal immutable swapRouter;
    PoolDonateTest internal immutable donateRouter;
    address internal immutable owner;
    address internal immutable deployer; // the test contract (fixture POL holder)
    address internal immutable wsgem;
    address internal immutable weth;
    address internal immutable pip;
    bool internal immutable wstGbpIsC0;
    PoolKey internal key;
    PoolId internal poolId;
    SettableFeed internal ethFeed;
    SettableFeed internal gbpFeed;

    // ---- violation ghosts ----
    uint256 public principalViolations;
    uint256 public externalPullViolations;
    uint256 public harvestResidueViolations;
    uint256 public unexpectedCompoundReverts;
    uint256 public unexpectedWithdrawReverts;
    // ---- state ghost / telemetry ----
    uint128 public trackedLiquidity;
    uint256 public benignCompoundReverts;
    uint256 public compoundsSucceeded;
    int256 internal lastEthAnswer = ETH_ANCHOR;

    /// @dev PoolSwapTest refunds leftover native balance to msg.sender (the documented gotcha).
    receive() external payable {}

    constructor(
        IPoolManager _pm,
        PoolKey memory _key,
        POLCompounder _comp,
        WethWstGbpHook _hook,
        PoolSwapTest _swapRouter,
        PoolDonateTest _donateRouter,
        address _owner,
        address _deployer
    ) {
        pm = _pm;
        key = _key;
        poolId = _key.toId();
        comp = _comp;
        hook = _hook;
        swapRouter = _swapRouter;
        donateRouter = _donateRouter;
        owner = _owner;
        deployer = _deployer;
        wsgem = address(_hook.wrapper());
        weth = _hook.weth();
        pip = _hook.wrapper().pip();
        wstGbpIsC0 = _hook.wstGbpIsCurrency0();
        ethFeed = SettableFeed(address(_hook.ethUsdFeed()));
        gbpFeed = SettableFeed(address(_hook.gbpUsdFeed()));
        IERC20Minimal(wsgem).approve(address(_swapRouter), type(uint256).max);
        IERC20Minimal(weth).approve(address(_swapRouter), type(uint256).max);
        IERC20Minimal(wsgem).approve(address(_donateRouter), type(uint256).max);
        IERC20Minimal(weth).approve(address(_donateRouter), type(uint256).max);
    }

    function syncTrackedLiquidity() external {
        trackedLiquidity = pm.getPositionLiquidity(poolId, comp.positionKey());
    }

    // ================================================================ world actions

    /// @dev A round of fee-generating flow (one leg each way, sizes bounded well inside funding).
    function accrueViaSwaps(uint256 seed) public {
        uint256 wsgIn = bound(seed, 10 * WAD, 500 * WAD);
        uint256 wethIn = bound(seed >> 128, WAD / 200, WAD / 4);
        if (IERC20Minimal(wsgem).balanceOf(address(this)) >= wsgIn) _try_swap(wstGbpIsC0, -int256(wsgIn));
        if (IERC20Minimal(weth).balanceOf(address(this)) >= wethIn) _try_swap(!wstGbpIsC0, -int256(wethIn));
    }

    function arbToFair() public {
        (uint256 fair, OracleLib.FallbackReason reason) = OracleLib.fairPriceWad(
            IAggregatorV3(address(ethFeed)),
            IAggregatorV3(address(gbpFeed)),
            wsgem,
            comp.ethUsdStalenessSec(),
            comp.gbpUsdStalenessSec()
        );
        if (reason != OracleLib.FallbackReason.NONE) return;
        uint160 target = _fairSqrtPriceX96(fair);
        (uint160 sqrtNow,,,) = pm.getSlot0(poolId);
        uint128 liq = pm.getLiquidity(poolId);
        if (liq == 0 || sqrtNow == 0 || target == 0 || sqrtNow > type(uint128).max || target > type(uint128).max) {
            return;
        }
        if (target > sqrtNow) {
            uint256 amtIn = _min(FullMath.mulDiv(liq, target - sqrtNow, FixedPoint96.Q96), 5 * WAD);
            if (amtIn > 0 && IERC20Minimal(weth).balanceOf(address(this)) >= amtIn) _try_swap(false, -int256(amtIn));
        } else if (target < sqrtNow) {
            uint256 amtIn =
                _min(FullMath.mulDiv(uint256(liq) << 96, sqrtNow - target, uint256(target) * sqrtNow), 10_000 * WAD);
            if (amtIn > 0 && IERC20Minimal(wsgem).balanceOf(address(this)) >= amtIn) _try_swap(true, -int256(amtIn));
        }
    }

    /// @dev Direct fee-growth injection (accrues to ALL in-range liquidity incl. the POL position).
    function donateFees(uint256 a0, uint256 a1) public {
        a0 = bound(a0, 0, 50 * WAD); // currency0 (wstGBP for the real pair)
        a1 = bound(a1, 0, WAD / 50); // currency1 (WETH)
        if (a0 == 0 && a1 == 0) return;
        try donateRouter.donate(key, a0, a1, "") {} catch {} // zero-liquidity edge: skip
    }

    function driftEthUsd(uint256 ppm) public {
        ppm = bound(ppm, 0, 60_000); // ±3%
        bool up = ppm & 1 == 1;
        uint256 mag = ppm / 2 > 30_000 ? 30_000 : ppm / 2;
        lastEthAnswer = ETH_ANCHOR * int256(up ? 1_000_000 + mag : 1_000_000 - mag) / 1_000_000;
        ethFeed.set(lastEthAnswer, block.timestamp);
    }

    function brickOracle(uint8 mode) public {
        mode = uint8(bound(mode, 0, 2));
        if (mode == 0) ethFeed.setReverting(true);
        else if (mode == 1) gbpFeed.set(GBP_ANCHOR, 1); // stale
        else vm.store(pip, PRICE_SLOT, bytes32(0)); // pip paused
    }

    function healOracle() public {
        ethFeed.setReverting(false);
        gbpFeed.setReverting(false);
        ethFeed.set(lastEthAnswer, block.timestamp);
        gbpFeed.set(GBP_ANCHOR, block.timestamp);
        vm.store(pip, PRICE_SLOT, bytes32(NAV_ANCHOR));
    }

    // ================================================================ compounder actions

    function compoundAction() public {
        (uint256 c0, uint256 c1) = comp.compoundable();
        if (c0 == 0 && c1 == 0) return;

        uint128 preLiq = pm.getPositionLiquidity(poolId, comp.positionKey());
        uint256[4] memory pre = _externalBalances();

        try comp.compound() returns (uint128) {
            compoundsSucceeded++;
            uint128 postLiq = pm.getPositionLiquidity(poolId, comp.positionKey());
            if (postLiq < preLiq) principalViolations++;
            (uint256 p0, uint256 p1) = comp.pendingFees();
            if (p0 != 0 || p1 != 0) harvestResidueViolations++;
            uint256[4] memory post = _externalBalances();
            for (uint256 i = 0; i < 4; i++) {
                if (post[i] != pre[i]) {
                    externalPullViolations++;
                    break;
                }
            }
            trackedLiquidity = postLiq;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == POLCompounder.NothingToCompound.selector || sel == POLCompounder.PriceOutOfBounds.selector) {
                benignCompoundReverts++;
            } else {
                unexpectedCompoundReverts++;
            }
        }
    }

    function withdrawSome(uint256 l) public {
        uint128 posLiq = pm.getPositionLiquidity(poolId, comp.positionKey());
        if (posLiq == 0) return;
        uint128 amount = uint128(bound(l, 1, posLiq));
        vm.prank(owner);
        try comp.withdrawLiquidity(amount, 0, 0, owner) returns (uint256, uint256) {
            trackedLiquidity = pm.getPositionLiquidity(poolId, comp.positionKey());
        } catch {
            unexpectedWithdrawReverts++; // zero mins: no declared revert is reachable
        }
    }

    /// @dev Owner dust sweep + tolerance retune folded into one low-weight action.
    function ownerHousekeeping(uint256 seed) public {
        vm.startPrank(owner);
        comp.sweep(wsgem, owner);
        comp.sweep(weth, owner);
        comp.setToleranceBps(uint16(bound(seed, 0, 500)));
        vm.stopPrank();
    }

    // ================================================================ helpers

    function _try_swap(bool zeroForOne, int256 amountSpecified) internal {
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {} // swap-level properties are the hook suite's job
    }

    /// @dev Balances `compound()` must never touch: the actor's and the owner's, both tokens.
    function _externalBalances() internal view returns (uint256[4] memory b) {
        b[0] = IERC20Minimal(wsgem).balanceOf(address(this));
        b[1] = IERC20Minimal(weth).balanceOf(address(this));
        b[2] = IERC20Minimal(wsgem).balanceOf(owner);
        b[3] = IERC20Minimal(weth).balanceOf(owner);
    }

    function _fairSqrtPriceX96(uint256 fairWad) internal view returns (uint160) {
        uint256 ratioX192 = wstGbpIsC0 ? (WAD << 192) / fairWad : ((fairWad << 96) / WAD) << 96;
        return uint160(_isqrt(ratioX192));
    }

    function _isqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 n;
        while (xx > 1) {
            xx >>= 1;
            ++n;
        }
        r = 1 << (n / 2 + 1);
        for (uint256 i = 0; i < 8; ++i) {
            r = (r + x / r) / 2;
        }
        if (r > x / r) r = x / r;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
