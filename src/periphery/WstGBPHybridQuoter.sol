// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IwstGBP} from "../interfaces/IwstGBP.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
        uint160 edge = _edgeSqrtPrice(zeroForOne, key.fee);
        (uint256 ammIn, uint256 ammOut) = _simulateAmm(key, zeroForOne, -int256(amountIn), edge);
        amountOut = ammOut + _backstopOutForIn(zeroForOne, amountIn - ammIn);
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
        uint160 edge = _edgeSqrtPrice(zeroForOne, key.fee);
        (uint256 ammIn, uint256 ammOut) = _simulateAmm(key, zeroForOne, int256(amountOut), edge);
        amountIn = ammIn + _backstopInForOut(zeroForOne, amountOut - ammOut);
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

    function _backstopInForOut(bool zeroForOne, uint256 residualOut) internal view returns (uint256) {
        if (residualOut == 0) return 0;
        if (zeroForOne) {
            uint256 mc = wrapper.mintcost();
            uint256 tgbpIn = FullMath.mulDivRoundingUp(residualOut, mc, WAD);
            if (tgbpIn < mc) tgbpIn = mc; // hook clamps sub-unit residual up to the mint threshold
            return tgbpIn;
        } else {
            uint256 bc = wrapper.burncost();
            uint256 wIn = FullMath.mulDivRoundingUp(residualOut, WAD, bc);
            if (wIn < WAD) wIn = WAD; // hook clamps sub-unit residual up to the redeem minimum
            return wIn;
        }
    }

    /// @dev The sqrtPriceX96 backstop edge — identical to `WstGBPHybridHook._edgeSqrtPrice`.
    function _edgeSqrtPrice(bool zeroForOne, uint24 fee) internal view returns (uint160) {
        uint256 adj = zeroForOne
            ? FullMath.mulDiv(wrapper.mintcost(), PIPS - fee, PIPS)  // mintcost*(1-fee)
            : FullMath.mulDiv(wrapper.burncost(), PIPS, PIPS - fee); // burncost/(1-fee)
        uint256 sp = FixedPointMathLib.sqrt(PRICE_NUMERATOR / adj);
        if (sp <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sp);
    }
}
