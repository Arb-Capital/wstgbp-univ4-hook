// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseHook} from "../v4/base/BaseHook.sol";
import {Iwsgem} from "../core/interfaces/Iwsgem.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title WethWstGbpHook
/// @notice Fee-only, oracle-aware dynamic-fee hook for a WETH/wstGBP v4 pool. The pool is a normal
///         AMM (LP welcome); the hook's only power is choosing each swap's LP fee: a directional base
///         (mint side — wstGBP in — pays the redeem side's base + the wrapper's structural 25 bps
///         redeem leg) plus a toxicity surcharge that only deviation-closing ("informed") flow pays,
///         computed against a Chainlink-composed fair value
///         `(ETH/USD ÷ GBP/USD) ÷ wstGBP.navprice()`.
///
/// @dev DESIGN INVARIANTS, in priority order:
///      1. NEVER BRICK THE POOL — `beforeSwap` has no oracle-dependent revert path: every failure
///         (feed revert/garbage/stale/absurd, `navprice() == 0` i.e. pip paused, composition
///         underflow) degrades to `fallbackFee` in both directions, with `OracleFallback` emitted on
///         the transaction's first failing read.
///      2. STAY ROUTER-QUOTABLE — fee-only: `ZERO_DELTA` from beforeSwap, no return-delta permission
///         bits, no custom accounting, so the stock V4 Quoter simulates this hook exactly.
///
///      Sign convention (see also `FeeMath` NatSpec): `d = pool(wstGBP-per-WETH)/fair − 1` in ppm.
///
///      | deviation | pool state          | closing flow        | surcharge payer          |
///      |-----------|---------------------|---------------------|--------------------------|
///      | d > 0     | WETH priced rich    | sell WETH into pool | redeem side (WETH in)    |
///      | d < 0     | WETH priced cheap   | sell wstGBP in      | mint side (wstGBP in)    |
///
///      Both `isMintSide` and the pool price are normalized through `wstGbpIsCurrency0` (derived from
///      the token addresses, never assumed), so `FeeMath` never sees a raw `zeroForOne`.
///
///      CACHING — the composed fair price is cached in transient storage, i.e. PER TRANSACTION (not
///      per block): multi-hop routes and bundles pay the two Chainlink reads + NAV read once. The
///      deviation is recomputed from live slot0 on every swap — required so N small swaps closing a
///      deviation each see the shrunk remainder (trade-splitting neutrality). A fallback verdict is
///      cached the same way (oracle state cannot improve intra-transaction). A quote via the stock
///      Quoter runs in its own transaction context with an empty cache, recomputing from the same
///      persistent state — quote == execution at the same block by construction.
///
///      MANIPULATION — the deviation input pairs Chainlink (not intra-block manipulable) against pool
///      spot (manipulable only by swapping). Pushing the pool off fair pays the base fee into POL and
///      arms the surcharge for whoever closes; the manipulation is self-defeating (adversarial suite
///      covers this).
///
///      GOVERNANCE — `Ownable2Step` multisig may retune `FeeParams` (bounds-checked, ≤ 10% absolute
///      fee ceiling) and pause (pause ⇒ `fallbackFee` both directions, oracle untouched). Logic is
///      immutable: no upgradeability, no other admin surface, no EMA state (deferred by design — the
///      `SwapFee` event stream carries everything an off-chain monitor needs).
contract WethWstGbpHook is BaseHook, Ownable2Step {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------- immutables

    IAggregatorV3 public immutable ethUsdFeed;
    IAggregatorV3 public immutable gbpUsdFeed;
    Iwsgem public immutable wrapper; // the wstGBP token IS the wrapper
    address public immutable weth;
    Currency public immutable currency0; // min(wstGBP, WETH) — v4 canonical ordering
    Currency public immutable currency1; // max(wstGBP, WETH)
    /// @dev Derived from addresses (`address(wrapper) < weth`), never caller-supplied: a swap's input
    ///      is wstGBP (mint side) iff `zeroForOne == wstGbpIsCurrency0`.
    bool public immutable wstGbpIsCurrency0;

    // ---------------------------------------------------------------- storage

    /// @notice Current fee parameters — ten packed uint24s, exactly one slot. All values ppm.
    FeeMath.FeeParams public feeParams;

    /// @notice Owner kill-switch: while true every swap pays `fallbackFee` and no oracle is read.
    bool public paused;

    // ---------------------------------------------------------------- transient

    /// @dev Per-transaction fair-price cache: 0 = unset, FAIR_CACHE_FALLBACK (1) = oracle failed this
    ///      transaction, else the trusted fairWad (guaranteed ≥ 2 by OracleLib).
    uint256 private transient _fairCache;
    /// @dev beforeSwap → afterSwap handoff: fee (bits 0..23) | isMintSide (bit 24) | fallback (bit 25).
    uint256 private transient _swapMeta;
    /// @dev beforeSwap → afterSwap handoff: the swap's signed deviation (0 in fallback/paused modes).
    int256 private transient _swapDeviation;

    uint256 private constant FAIR_CACHE_FALLBACK = 1;
    /// @dev `OracleFallback` reason emitted when the owner pause (not an oracle failure) forces
    ///      fallback pricing; distinct from every `OracleLib.FallbackReason` value.
    uint8 public constant REASON_PAUSED = 0xFF;

    // ---------------------------------------------------------------- events / errors

    /// @notice Emitted once per swap from afterSwap (adjacent to the PoolManager's own Swap log).
    event SwapFee(bool indexed mintSide, uint24 fee, int256 deviationPpm, bool fallbackMode);
    /// @notice Emitted on the first failing oracle read of a transaction (and on every paused swap).
    event OracleFallback(uint8 reason);
    /// @notice Full params emitted for off-chain indexing on every change (and once at construction).
    event FeeParamsSet(FeeMath.FeeParams params);
    event PausedSet(bool paused);

    error NotDynamicFee();
    error PoolNotSupported();
    error IdenticalCurrencies();
    error BadFeedDecimals();

    // ---------------------------------------------------------------- construction

    constructor(
        IPoolManager _poolManager,
        IAggregatorV3 _ethUsd,
        IAggregatorV3 _gbpUsd,
        Iwsgem _wrapper,
        address _weth,
        FeeMath.FeeParams memory _params,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        // Feed scale is asserted once here, never per swap. Deliberately NOT asserted: a live
        // navprice() — the pip may be paused at deploy time and the hook must still deploy.
        if (_ethUsd.decimals() != 8 || _gbpUsd.decimals() != 8) revert BadFeedDecimals();
        address _wstGbp = address(_wrapper);
        if (_wstGbp == _weth) revert IdenticalCurrencies();
        FeeMath.checkParams(_params);

        ethUsdFeed = _ethUsd;
        gbpUsdFeed = _gbpUsd;
        wrapper = _wrapper;
        weth = _weth;
        bool _w0 = _wstGbp < _weth;
        wstGbpIsCurrency0 = _w0;
        (currency0, currency1) =
            _w0 ? (Currency.wrap(_wstGbp), Currency.wrap(_weth)) : (Currency.wrap(_weth), Currency.wrap(_wstGbp));
        feeParams = _params;
        emit FeeParamsSet(_params);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // dynamic-fee + currency validation
            afterInitialize: false,
            beforeAddLiquidity: false, // real AMM pool — LP is welcome
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // the fee override
            afterSwap: true, // event emission only
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // fee-only: MUST stay false for router-quotability
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- hook callbacks

    /// @dev Any tickSpacing is acceptable (fee logic is per-poolId via getSlot0; the pair-level fair
    ///      price is shared correctly across keys). `key.hooks == this` is guaranteed by the
    ///      PoolManager callback path.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1)
        ) revert PoolNotSupported();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev No revert path exists past BaseHook's onlyPoolManager gate — see invariant 1.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        FeeMath.FeeParams memory p = feeParams;
        bool isMintSide = params.zeroForOne == wstGbpIsCurrency0;

        uint24 fee;
        int256 d;
        bool fallbackMode;

        if (paused) {
            fee = p.fallbackFee;
            fallbackMode = true;
            emit OracleFallback(REASON_PAUSED);
        } else {
            uint256 fairWad = _fairCache;
            if (fairWad == 0) {
                OracleLib.FallbackReason reason;
                (fairWad, reason) = OracleLib.fairPriceWad(
                    ethUsdFeed, gbpUsdFeed, address(wrapper), p.ethUsdStalenessSec, p.gbpUsdStalenessSec
                );
                if (reason != OracleLib.FallbackReason.NONE) {
                    // Oracle state cannot improve intra-transaction: cache the verdict, emit once.
                    fairWad = FAIR_CACHE_FALLBACK;
                    emit OracleFallback(uint8(reason));
                }
                _fairCache = fairWad;
            }

            if (fairWad == FAIR_CACHE_FALLBACK) {
                fee = p.fallbackFee;
                fallbackMode = true;
            } else {
                // Live slot0 every swap (only the fair price is cached): each slice of a split trade
                // must see the deviation it actually closes.
                (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
                d = OracleLib.deviationPpm(
                    OracleLib.poolPriceWstGbpPerWethWad(sqrtPriceX96, wstGbpIsCurrency0), fairWad
                );
                fee = FeeMath.swapFee(isMintSide, d, p);
            }
        }

        _swapMeta = uint256(fee) | (isMintSide ? 1 << 24 : 0) | (fallbackMode ? 1 << 25 : 0);
        _swapDeviation = d;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Events only — the EMA the spec sketched is deferred by design (documented in the README):
    ///      it has no v1 consumer (fallback mode stays dumb), would cost an SSTORE per swap against
    ///      the warm-gas budget, and a future EMA ships in a v2 hook since logic is immutable.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 meta = _swapMeta;
        emit SwapFee((meta >> 24) & 1 == 1, uint24(meta), _swapDeviation, (meta >> 25) & 1 == 1);
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------- admin (multisig)

    /// @notice Replace the fee parameters. Bounds-checked by `FeeMath.checkParams`; the full struct is
    ///         emitted for off-chain indexing.
    function setFeeParams(FeeMath.FeeParams calldata p) external onlyOwner {
        FeeMath.checkParams(p);
        feeParams = p;
        emit FeeParamsSet(p);
    }

    /// @notice Pause ⇒ every swap pays `fallbackFee` (both directions), no oracle reads. Swaps are
    ///         never blocked — pausing changes pricing, not availability.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }
}
