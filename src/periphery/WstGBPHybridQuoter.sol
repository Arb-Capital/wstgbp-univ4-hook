// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IwstGBP} from "../interfaces/IwstGBP.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title WstGBPHybridQuoter
/// @notice LP-aware quotes for the {WstGBPHybridHook}: simulates the in-band AMM fill to the
///         fee-adjusted backstop edge, then prices the backstop residual at the wrapper's oracle —
///         the exact blend the hook executes. Unlike {WstGBPQuoter} (backstop-only, a conservative
///         bound when LP is present), this returns the *exact* hybrid output/input including the LP leg.
///
///         Two edge behaviours mirror the hook: (1) on EXACT-INPUT, a residual below the wrapper's
///         mint/redeem threshold is dropped (refunded by the router / filled as bonus output), so
///         `quoteExactInput` is a *lower bound* in that rare case (execution never delivers less);
///         (2) on EXACT-OUTPUT, a sub-threshold residual can't be filled at a fair price, so
///         `quoteExactOutput` reverts `BackstopResidualTooSmall` and `previewSwap` reports it.
///
/// @dev The AMM leg is a pure-view replay of v4's `Pool.swap` loop over live pool state read via
///      `StateLibrary` (slot0, liquidity, tick bitmap, tick net-liquidity), bounded at the same `edge`
///      `sqrtPrice` the hook uses; the backstop leg mirrors `WstGBPHybridHook._backstop*` arithmetic
///      exactly (same `FullMath` rounding, dust thresholds, and exact-out clamps). It assumes a static
///      LP fee (the deployed pools are not dynamic-fee) and honors any pool protocol fee.
///
///      Pool convention: currency0 = tGBP, currency1 = wstGBP. `zeroForOne == true` is a BUY of wstGBP.
///      Quotes are point-in-time (the wrapper's oracle ratchets); pass real slippage bounds on execution.
contract WstGBPHybridQuoter {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PIPS = 1_000_000;
    /// @dev 1e18 << 192, the numerator for converting a WAD tGBP/wstGBP price to sqrtPriceX96.
    uint256 internal constant PRICE_NUMERATOR = uint256(1e18) << 192;

    IwstGBP public immutable wrapper;
    IPoolManager public immutable poolManager;
    address public immutable tgbp;

    /// @dev Mirrors `WstGBPHybridHook`: an exact-output swap whose backstop residual is below the
    ///      wrapper's mint/redeem threshold reverts (it can't be filled at a fair price).
    error BackstopResidualTooSmall();
    /// @dev Mirrors `WstGBPHybridHook`: dynamic-fee / >=100% fee keys are rejected (the edge math
    ///      would underflow / divide by zero).
    error PoolNotSupported();

    constructor(IwstGBP _wrapper, IPoolManager _poolManager) {
        wrapper = _wrapper;
        poolManager = _poolManager;
        tgbp = _wrapper.gem();
    }

    /// @notice Exact-input quote: output for `amountIn` of the input currency.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountIn The exact input (tGBP for a buy, wstGBP for a sell).
    /// @return amountOut Output delivered (wstGBP for a buy, tGBP for a sell).
    function quoteExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        (amountOut,,) = _quoteIn(key, zeroForOne, amountIn);
    }

    /// @notice Exact-output quote: input required for `amountOut` of the output currency.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountOut The exact output (wstGBP for a buy, tGBP for a sell).
    /// @return amountIn Input the caller must provide (tGBP for a buy, wstGBP for a sell).
    function quoteExactOutput(PoolKey calldata key, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (uint256 amountIn)
    {
        bool residualTooSmall;
        (amountIn,,, residualTooSmall) = _quoteOut(key, zeroForOne, amountOut);
        // The hook reverts when the backstop residual is below the wrapper threshold; mirror it so a
        // quote never reports a fillable input for a swap that would revert on execution.
        if (residualTooSmall) revert BackstopResidualTooSmall();
    }

    /// @notice Quote a swap (same `amountSpecified` convention as `PoolManager.swap`) AND report whether
    ///         it would execute against the live wrapper now. The AMM leg never touches the wrapper; only
    ///         the backstop residual is gated, so the wrapper checks apply only when the backstop is used.
    /// @param amountSpecified Negative for exact-input, positive for exact-output.
    /// @return amountIn Input the caller pays.
    /// @return amountOut Output the caller receives.
    /// @return executable True if a swap of this size would succeed at the current block.
    /// @return reason Empty if executable, otherwise a short human-readable cause.
    function previewSwap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, bool executable, string memory reason)
    {
        uint256 backstopMintOut; // wstGBP the backstop mints (buys) — checked against capacity
        uint256 backstopClaim; // tGBP the backstop redeem needs (sells) — checked against funding
        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            (amountOut, backstopMintOut, backstopClaim) = _quoteIn(key, zeroForOne, amountIn);
        } else {
            amountOut = uint256(amountSpecified);
            bool residualTooSmall;
            (amountIn, backstopMintOut, backstopClaim, residualTooSmall) = _quoteOut(key, zeroForOne, amountOut);
            // The hook reverts on a sub-threshold backstop residual; report it gracefully here.
            if (residualTooSmall) return (amountIn, amountOut, false, "residual below wrapper threshold");
        }
        (executable, reason) = _check(zeroForOne, backstopMintOut, backstopClaim);
    }

    /// @dev Exact-input blend + the backstop-leg sizes used for the executability check.
    function _quoteIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 backstopMintOut, uint256 backstopClaim)
    {
        uint160 edge = _edgeFor(key, zeroForOne);
        (uint256 ammIn, uint256 ammOut) = _simulateAmm(key, zeroForOne, -int256(amountIn), edge);
        uint256 residualIn = amountIn - ammIn;
        uint256 backstopOut = _backstopOutForIn(zeroForOne, residualIn);
        amountOut = ammOut + backstopOut;
        if (zeroForOne) backstopMintOut = backstopOut;
        else if (residualIn >= WAD) backstopClaim = FullMath.mulDiv(residualIn, wrapper.burncost(), WAD);
    }

    /// @dev Exact-output blend + the backstop-leg sizes used for the executability check.
    ///      `residualTooSmall` is true when the backstop residual is below the wrapper threshold —
    ///      the hook reverts in that case, so the returned `amountIn` is not a fillable quote.
    function _quoteOut(PoolKey calldata key, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn, uint256 backstopMintOut, uint256 backstopClaim, bool residualTooSmall)
    {
        uint160 edge = _edgeFor(key, zeroForOne);
        (uint256 ammIn, uint256 ammOut) = _simulateAmm(key, zeroForOne, int256(amountOut), edge);
        uint256 residualOut = amountOut - ammOut;
        uint256 backstopIn;
        (backstopIn, residualTooSmall) = _backstopInForOut(zeroForOne, residualOut);
        amountIn = ammIn + backstopIn;
        if (residualOut > 0 && !residualTooSmall) {
            if (zeroForOne) backstopMintOut = FullMath.mulDiv(backstopIn, WAD, wrapper.mintcost());
            else backstopClaim = FullMath.mulDiv(backstopIn, wrapper.burncost(), WAD);
        }
    }

    /// @dev Mirrors the hook/wrapper constraints, applied only to the backstop residual.
    function _check(bool zeroForOne, uint256 backstopMintOut, uint256 backstopClaim)
        internal
        view
        returns (bool, string memory)
    {
        if (zeroForOne) {
            if (backstopMintOut > 0) {
                if (!wrapper.mintable()) return (false, "mint market closed");
                if (wrapper.totalSupply() + backstopMintOut > wrapper.capacity()) return (false, "exceeds capacity");
            }
        } else {
            // Under a redeem cooldown the hook routes sells to an LP-only passthrough (router price
            // limit, no backstop) — a path this edge-bounded quote doesn't model — so flag it.
            if (wrapper.cooldown() != 0) return (false, "redeem cooldown active");
            if (backstopClaim > 0) {
                if (!wrapper.burnable()) return (false, "burn market closed");
                if (IERC20Minimal(tgbp).balanceOf(address(wrapper)) < backstopClaim) {
                    return (false, "wrapper underfunded");
                }
            }
        }
        return (true, "");
    }

    // -----------------------------------------------------------------------
    // AMM leg — pure-view replay of v4 Pool.swap bounded at the backstop edge
    // -----------------------------------------------------------------------

    /// @dev Mutable swap state, kept in memory (passed by reference) to ease stack pressure.
    struct SwapState {
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        int256 remaining; // negative = exact-in, positive = exact-out
    }

    /// @dev Loop-invariant config, bundled so each step takes only two struct refs.
    struct Cfg {
        PoolId id;
        int24 tickSpacing;
        bool zeroForOne;
        bool exactOutput;
        uint160 edge;
        uint24 swapFee;
    }

    /// @dev Returns the input consumed (incl. fee) and output produced by swapping `amountSpecified`
    ///      (negative = exact-in, positive = exact-out) from the current price to at most `edge`.
    function _simulateAmm(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 edge)
        internal
        view
        returns (uint256 ammIn, uint256 ammOut)
    {
        PoolId id = key.toId();
        SwapState memory s;
        Cfg memory cfg;
        cfg.id = id;
        cfg.tickSpacing = key.tickSpacing;
        cfg.zeroForOne = zeroForOne;
        cfg.exactOutput = amountSpecified > 0;
        cfg.edge = edge;
        {
            (uint160 sqrtPrice, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(id);
            // Same gate as the hook's `_fillAmm`: skip the AMM if the price is already at/past the edge.
            if (zeroForOne ? sqrtPrice <= edge : sqrtPrice >= edge) return (0, 0);
            s.sqrtPrice = sqrtPrice;
            s.tick = tick;
            s.liquidity = poolManager.getLiquidity(id);
            s.remaining = amountSpecified;
            cfg.swapFee = _swapFee(protocolFee, lpFee, zeroForOne);
        }

        while (s.remaining != 0 && s.sqrtPrice != edge) {
            (uint256 stepIn, uint256 stepOut) = _swapStep(cfg, s);
            ammIn += stepIn;
            ammOut += stepOut;
        }
    }

    /// @dev One iteration of the v4 swap loop: advances `s` and returns this step's input (incl. fee)
    ///      and output.
    function _swapStep(Cfg memory cfg, SwapState memory s) internal view returns (uint256 stepIn, uint256 stepOut) {
        uint160 sqrtStart = s.sqrtPrice;
        (int24 tickNext, bool initialized) = _nextTick(cfg.id, s.tick, cfg.tickSpacing, cfg.zeroForOne);
        if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
        else if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
        uint160 sqrtNext = TickMath.getSqrtPriceAtTick(tickNext);

        uint256 stepFee;
        (s.sqrtPrice, stepIn, stepOut, stepFee) = SwapMath.computeSwapStep(
            sqrtStart,
            SwapMath.getSqrtPriceTarget(cfg.zeroForOne, sqrtNext, cfg.edge),
            s.liquidity,
            s.remaining,
            cfg.swapFee
        );
        stepIn += stepFee; // total input charged for this step is amountIn + fee

        if (cfg.exactOutput) s.remaining -= int256(stepOut);
        else s.remaining += int256(stepIn);

        if (s.sqrtPrice == sqrtNext) {
            if (initialized) {
                (, int128 liquidityNet) = poolManager.getTickLiquidity(cfg.id, tickNext);
                if (cfg.zeroForOne) liquidityNet = -liquidityNet;
                s.liquidity = LiquidityMath.addDelta(s.liquidity, liquidityNet);
            }
            s.tick = cfg.zeroForOne ? tickNext - 1 : tickNext;
        } else if (s.sqrtPrice != sqrtStart) {
            s.tick = TickMath.getTickAtSqrtPrice(s.sqrtPrice);
        }
    }

    /// @dev Replays `TickBitmap.nextInitializedTickWithinOneWord` against a bitmap word read live.
    function _nextTick(PoolId id, int24 tick, int24 tickSpacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);
            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                compressed += 1;
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 mask = ~((uint256(1) << bitPos) - 1);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    function _swapFee(uint24 protocolFee, uint24 lpFee, bool zeroForOne) internal pure returns (uint24) {
        uint16 pf = zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        return pf == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(pf, lpFee);
    }

    // -----------------------------------------------------------------------
    // Backstop leg — mirrors WstGBPHybridHook._backstop* exactly
    // -----------------------------------------------------------------------

    function _backstopOutForIn(bool zeroForOne, uint256 residualIn) internal view returns (uint256) {
        if (residualIn == 0) return 0;
        if (zeroForOne) {
            uint256 mc = wrapper.mintcost();
            if (residualIn < mc) return 0; // below mint dust threshold: kept as dust, no output
            return FullMath.mulDiv(residualIn, WAD, mc);
        } else {
            if (residualIn < WAD) return 0; // below redeem minimum: kept as dust, no output
            return FullMath.mulDiv(residualIn, wrapper.burncost(), WAD);
        }
    }

    /// @dev Input the backstop needs for `residualOut`, plus a `tooSmall` flag set when that residual
    ///      is below the wrapper threshold — the hook reverts there (no clamp), so the returned input
    ///      is not a fillable quote.
    function _backstopInForOut(bool zeroForOne, uint256 residualOut)
        internal
        view
        returns (uint256 inNeeded, bool tooSmall)
    {
        if (residualOut == 0) return (0, false);
        if (zeroForOne) {
            uint256 mc = wrapper.mintcost();
            uint256 tgbpIn = FullMath.mulDivRoundingUp(residualOut, mc, WAD);
            return (tgbpIn, tgbpIn < mc); // hook reverts when the residual is below the mint threshold
        } else {
            uint256 bc = wrapper.burncost();
            uint256 wIn = FullMath.mulDivRoundingUp(residualOut, WAD, bc);
            return (wIn, wIn < WAD); // hook reverts when the residual is below the redeem minimum
        }
    }

    /// @dev The backstop edge for `key`/direction, netting out the full directional swap fee v4 will
    ///      charge (LP fee + any protocol fee) — identical to the hook. Reverts `PoolNotSupported` for
    ///      dynamic / >=100% fee keys, mirroring `WstGBPHybridHook._beforeSwap`.
    function _edgeFor(PoolKey calldata key, bool zeroForOne) internal view returns (uint160) {
        if (key.fee >= PIPS) revert PoolNotSupported();
        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(key.toId());
        uint24 swapFee = _swapFee(protocolFee, lpFee, zeroForOne);
        if (swapFee >= PIPS) revert PoolNotSupported();
        return _edgeSqrtPrice(zeroForOne, swapFee);
    }

    /// @dev The sqrtPriceX96 backstop edge — identical to `WstGBPHybridHook._edgeSqrtPrice`. `swapFee`
    ///      is the full directional swap fee (LP + protocol fee).
    function _edgeSqrtPrice(bool zeroForOne, uint24 swapFee) internal view returns (uint160) {
        uint256 adj = zeroForOne
            ? FullMath.mulDiv(wrapper.mintcost(), PIPS - swapFee, PIPS)  // mintcost*(1-fee)
            : FullMath.mulDiv(wrapper.burncost(), PIPS, PIPS - swapFee); // burncost/(1-fee)
        uint256 sp = FixedPointMathLib.sqrt(PRICE_NUMERATOR / adj);
        if (sp <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sp);
    }
}
