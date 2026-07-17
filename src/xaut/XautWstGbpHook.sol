// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseHook} from "../v4/base/BaseHook.sol";
import {Iwsgem} from "../core/interfaces/Iwsgem.sol";
import {FeeMath} from "./lib/FeeMath.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

/// @title XautWstGbpHook
/// @notice Fee-only, oracle-aware dynamic-fee hook for a XAUT/wstGBP v4 pool — the first on-chain
///         gold/sterling market. The pool is a normal AMM (LP welcome); the hook's only power is
///         choosing each swap's LP fee: a directional base plus a toxicity surcharge that only
///         deviation-closing ("informed") flow pays, computed against the two-feed fair value
///         `(XAU/USD ÷ GBP/USD) ÷ wstGBP.navprice()` (wstGBP-per-XAUT — see the basis note below).
///
/// @dev DESIGN INVARIANTS, in priority order (identical to the WETH and USDC venues):
///      1. NEVER BRICK THE POOL — `beforeSwap` has no oracle-dependent revert path: every failure
///         (feed revert/garbage/stale/absurd, `navprice() == 0` i.e. pip paused, composition
///         underflow) degrades to `fallbackFee` in both directions, with `OracleFallback` emitted on
///         the transaction's first failing read.
///      2. STAY ROUTER-QUOTABLE — fee-only: `ZERO_DELTA` from beforeSwap, no return-delta permission
///         bits, no custom accounting, so the stock V4 Quoter simulates this hook exactly.
///
///      Sign convention (see also `FeeMath` NatSpec): `d = pool(wstGBP-per-XAUT)/fair − 1` in ppm.
///
///      | deviation | pool state                     | closing flow        | surcharge payer       |
///      |-----------|--------------------------------|---------------------|-----------------------|
///      | d > 0     | XAUT priced rich (wstGBP cheap)| sell XAUT into pool | redeem side (XAUT in) |
///      | d < 0     | XAUT priced cheap (wstGBP rich)| sell wstGBP in      | mint side (wstGBP in) |
///
///      `d > 0` is the post-NAV-ratchet state (the ratchet lowers fair; the pool lags rich in XAUT
///      terms) — the buy-then-redeem conveyor arb pays redeem-side base + surcharge. A gold rally
///      raises fair (d < 0) and the mint side closes.
///
///      Both `isMintSide` and the pool price are normalized through `wstGbpIsCurrency0` (derived from
///      the token addresses, never assumed), so `FeeMath` never sees a raw `zeroForOne`.
///
///      TOKEN–METAL BASIS (accepted risk, venue decision 2026-07-11): XAU/USD prices spot gold, not
///      the XAUt token — so the pool RESTS at d ≈ −basis rather than 0, where basis is the
///      token–metal gap. The basis is small and SIGN-UNSTABLE: a ~+50bp discount was estimated
///      2026-07-11; a ~11bp PREMIUM (XAUt above the feed) was measured 2026-07-16. Discount regime
///      (rest d < 0): the redeem side reads non-closing (surcharge-immune under ANY threshold), the
///      mint side reads closing — the goldsim sweep (sim/RESULTS_XAUT.md, 2026-07-16) deliberately
///      shipped a threshold BELOW the basis magnitude, so resting mint-side flow pays base + ramp
///      surcharge by design (priced), not by accident. Premium regime (rest d > 0): the surcharged
///      side flips to the redeem conveyor — ramp-bounded, and anchor-cell economics stay flat.
///      The basis-sensitivity table there bounds the cost of BOTH regimes (basis {−50..+100} bps;
///      full-grid ranking confirmation at basis 0 in RESULTS_XAUT_BASIS0.md), and the owner can
///      retune `FeeParams` if the regime moves; see SECURITY_XAUT_WSTGBP.md "token–metal basis".
///
///      Gold also closes weekends/holidays: the XAU/USD feed heartbeats through the close on a
///      near-frozen price, so a weekend is ordinary priced deviation against a flat fair — NOT a
///      fallback state (fallback needs a stale/broken feed, not a quiet one).
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
///      immutable: no upgradeability, no other admin surface, no EMA state (the `SwapFee` event
///      stream carries everything an off-chain monitor needs).
contract XautWstGbpHook is BaseHook, Ownable2Step {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------- immutables

    IAggregatorV3 public immutable xauUsdFeed;
    IAggregatorV3 public immutable gbpUsdFeed;
    Iwsgem public immutable wrapper; // the wstGBP token IS the wrapper
    address public immutable xaut;
    Currency public immutable currency0; // min(wstGBP, XAUT) — v4 canonical ordering
    Currency public immutable currency1; // max(wstGBP, XAUT)
    /// @dev Derived from addresses (`address(wrapper) < xaut`), never caller-supplied: a swap's input
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
    /// @dev Reason codes follow THIS venue's 8-entry `OracleLib.FallbackReason` (1..3 XAU feed,
    ///      4..6 GBP feed, 7 NAV_BAD, 0xFF paused) — structurally the WETH venue's numbering, but
    ///      they RENUMBER vs the USDC venue's 5-entry enum; see monitoring/dune/README.md.
    event OracleFallback(uint8 reason);
    /// @notice Full params emitted for off-chain indexing on every change (and once at construction).
    event FeeParamsSet(FeeMath.FeeParams params);
    event PausedSet(bool paused);

    error NotDynamicFee();
    error PoolNotSupported();
    error IdenticalCurrencies();
    error BadFeedDecimals();
    error BadQuoteDecimals();

    // ---------------------------------------------------------------- construction

    constructor(
        IPoolManager _poolManager,
        IAggregatorV3 _xauUsd,
        IAggregatorV3 _gbpUsd,
        Iwsgem _wrapper,
        address _xaut,
        FeeMath.FeeParams memory _params,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        // Feed and quote-token scales are asserted once here, never per swap: the composition assumes
        // both feeds share the 8-dec scale (it cancels in their ratio) and XAUT_UNIT assumes the
        // 6-dec quote token. Deliberately NOT asserted: a live navprice() — the pip may be paused at
        // deploy time and the hook must still deploy.
        if (_xauUsd.decimals() != 8 || _gbpUsd.decimals() != 8) revert BadFeedDecimals();
        address _wstGbp = address(_wrapper);
        // Identical-currencies before the quote-decimals check: the wrapper is 18-dec, so the
        // reverse order would mask this error behind BadQuoteDecimals.
        if (_wstGbp == _xaut) revert IdenticalCurrencies();
        if (IERC20Metadata(_xaut).decimals() != 6) revert BadQuoteDecimals();
        FeeMath.checkParams(_params);

        xauUsdFeed = _xauUsd;
        gbpUsdFeed = _gbpUsd;
        wrapper = _wrapper;
        xaut = _xaut;
        bool _w0 = _wstGbp < _xaut;
        wstGbpIsCurrency0 = _w0;
        (currency0, currency1) =
            _w0 ? (Currency.wrap(_wstGbp), Currency.wrap(_xaut)) : (Currency.wrap(_xaut), Currency.wrap(_wstGbp));
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
                    xauUsdFeed, gbpUsdFeed, address(wrapper), p.xauUsdStalenessSec, p.gbpUsdStalenessSec
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
                    OracleLib.poolPriceWstGbpPerXautWad(sqrtPriceX96, wstGbpIsCurrency0), fairWad
                );
                fee = FeeMath.swapFee(isMintSide, d, p);
            }
        }

        _swapMeta = uint256(fee) | (isMintSide ? 1 << 24 : 0) | (fallbackMode ? 1 << 25 : 0);
        _swapDeviation = d;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Events only — no EMA state by design (documented in the README): it would cost an SSTORE
    ///      per swap against the warm-gas budget and has no v1 consumer; the `SwapFee` event stream
    ///      carries everything an off-chain monitor needs.
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
