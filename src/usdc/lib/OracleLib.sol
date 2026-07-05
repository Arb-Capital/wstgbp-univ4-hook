// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {Iwsgem} from "../../core/interfaces/Iwsgem.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title OracleLib (wstGBP/USDC venue)
/// @notice Fair-value composition for the wstGBP/USDC venue:
///         `fair (wstGBP per USDC, WAD) = 1 / (GBP/USD × navprice)`, from the Chainlink GBP/USD
///         feed (8 decimals) and the wrapper's WAD tGBP-per-wstGBP NAV (tGBP ≈ GBP at par), plus the
///         pool-side helpers to express slot0 in the same orientation and take a signed ppm deviation.
/// @dev USDC IS ASSUMED TO BE $1.00 — deliberately no USDC/USD feed (venue decision 2026-07-05).
///      A USDC depeg is therefore INVISIBLE to this composition: fair stays put while the pool
///      reprices, the deviation grows, and the toxicity surcharge lands on depeg flow as if it were
///      NAV arb. Mitigation is off-chain (monitoring/check_feeds.sh USDC/USD probe) + the owner
///      pause (flat fallbackFee); see SECURITY_USDC_WSTGBP.md "USDC depeg risk".
///
///      NEVER-REVERT CONTRACT: `fairPriceWad` and the pure helpers are total — any feed failure
///      (call revert, empty/short/garbage return, non-positive or absurd answer, stale round,
///      `navprice() == 0` i.e. pip paused) is reported as a `FallbackReason`, never a revert. Feed
///      calls use raw `staticcall` + length-checked manual decode because `try/catch` does NOT catch
///      return-data decode failures. The wstGBP NAV leg has no on-chain staleness signal (the pip is
///      a manually-poked push oracle); the only trust checks available for it are the zero/absurd
///      bounds here — a documented limitation.
library OracleLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PPM = 1e6;

    /// @dev One USD in the GBP/USD feed's 8-decimal scale: the USDC leg of the composition under the
    ///      USDC = $1.00 assumption (see the depeg note above).
    uint256 internal constant ONE_USD8 = 1e8;

    /// @dev One whole USDC in base units (USDC is 6 decimals; asserted once in the hook constructor).
    ///      This is the ONLY place token decimals enter the venue's math: the pool-price conversion
    ///      folds the 10^(18−6) decimal gap into this constant.
    uint256 internal constant USDC_UNIT = 1e6;

    /// @dev Sanity ceiling on every oracle answer (the 8-dec feed and the WAD NAV alike): anything
    ///      above is treated as feed failure. Also bounds the composition products far below 2^256.
    uint256 internal constant MAX_ANSWER = 1e30;

    /// @dev Returned when the pool price is too extreme to invert (sqrtPriceX96 near MIN_SQRT_PRICE
    ///      squares to zero at Q96): a huge-but-finite sentinel so deviation saturates instead of
    ///      dividing by zero.
    uint256 internal constant EXTREME_PRICE_SENTINEL = type(uint128).max;

    /// @notice Why the composed fair price is untrusted. Order matters: `_readFeed`'s error codes
    ///         (1 call, 2 answer, 3 stale) map directly onto the GBP entries.
    /// @dev NOTE: this venue has a single feed, so the numbering DIVERGES from the WETH venue's
    ///      8-entry enum (there NAV_BAD = 7; here NAV_BAD = 4). Off-chain decoders must use the
    ///      per-venue mapping — see monitoring/dune/README.md.
    enum FallbackReason {
        NONE,
        GBP_FEED_CALL,
        GBP_FEED_ANSWER,
        GBP_FEED_STALE,
        NAV_BAD
    }

    /// @notice Composed fair price, wstGBP-per-USDC in WAD. `reason == NONE` iff the value is
    ///         trustworthy; on any failure returns `(0, reason)`. Never reverts.
    /// @dev A trusted `fairWad` is always ≥ 2: 0 and 1 are reserved as the hook's transient-cache
    ///      sentinels, so a composition that floors below 2 is reported as `NAV_BAD`.
    function fairPriceWad(IAggregatorV3 gbpUsd, address wrapper, uint256 gbpStalenessSec)
        internal
        view
        returns (uint256 fairWad, FallbackReason reason)
    {
        (uint256 g, uint8 errG) = _readFeed(gbpUsd, gbpStalenessSec);
        if (errG != 0) return (0, FallbackReason(errG)); // 1..3 -> GBP_FEED_*

        (bool okNav, bytes memory ret) = wrapper.staticcall(abi.encodeWithSelector(Iwsgem.navprice.selector));
        if (!okNav || ret.length < 32) return (0, FallbackReason.NAV_BAD);
        uint256 nav = abi.decode(ret, (uint256));
        // nav == 0 is the pip's documented paused state (views return 0 rather than revert).
        if (nav == 0 || nav > MAX_ANSWER) return (0, FallbackReason.NAV_BAD);

        // USD-per-wstGBP = (g/1e8 USD-per-GBP) × (N GBP-per-wstGBP); inverting gives wstGBP-per-USD
        // ≈ wstGBP-per-USDC under the $1.00 assumption: fair = 1e8·WAD·WAD / (g·nav). ONE_USD8
        // restores the feed's 8-dec scale; one WAD scales the output. Bounds: the numerator is the
        // constant 1e26·WAD = 1e44; `g·nav ≤ 1e60` — no overflow, and FullMath carries the 512-bit
        // intermediate product.
        fairWad = FullMath.mulDiv(ONE_USD8 * WAD, WAD, g * nav);
        if (fairWad < 2) return (0, FallbackReason.NAV_BAD);
        return (fairWad, FallbackReason.NONE);
    }

    /// @notice Pool spot as wstGBP-per-USDC in WAD from slot0's sqrtPriceX96, orientation-normalized.
    ///         Pure and total over the whole valid sqrt-price range.
    /// @dev sqrtPriceX96 encodes sqrt(currency1/currency0) in RAW BASE UNITS of an 18-dec/6-dec pair,
    ///      so the raw ratio carries a 10^(18−6) factor vs the human price; folding it into
    ///      `USDC_UNIT` (1e6 where the 18/18 WETH venue used WAD) normalizes both branches. When
    ///      wstGBP is currency0 the raw pool price is USDC-per-wstGBP and must be inverted; near
    ///      MIN_SQRT_PRICE the squared Q96 price floors to 0, where inversion would divide by zero —
    ///      return the huge sentinel instead (deviation saturates, fee clamps).
    function poolPriceWstGbpPerUsdcWad(uint160 sqrtPriceX96, bool wstGbpIsCurrency0)
        internal
        pure
        returns (uint256 poolWad)
    {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        if (wstGbpIsCurrency0) {
            if (priceX96 == 0) return EXTREME_PRICE_SENTINEL;
            poolWad = FullMath.mulDiv(USDC_UNIT, FixedPoint96.Q96, priceX96);
        } else {
            poolWad = FullMath.mulDiv(priceX96, USDC_UNIT, FixedPoint96.Q96);
        }
    }

    /// @notice Signed ppm deviation of the pool price from fair: `poolWad/fairWad − 1` in ppm.
    /// @dev Caller guarantees `fairWad ≥ 2` (enforced by `fairPriceWad`). Bounds: `poolWad` is at
    ///      most ~3.4e44 (direct, at max sqrtPrice with the 1e6 numerator) / 2^128 (sentinel), so
    ///      `mulDiv(poolWad, 1e6, 2) ≤ ~1.7e50 << 2^255` — the cast and subtraction cannot overflow,
    ///      and |result| bounds FeeMath's surcharge product.
    function deviationPpm(uint256 poolWad, uint256 fairWad) internal pure returns (int256) {
        return int256(FullMath.mulDiv(poolWad, PPM, fairWad)) - int256(PPM);
    }

    /// @dev Guarded Chainlink read. Error codes: 0 ok, 1 call/decode failure, 2 bad answer
    ///      (non-positive or > MAX_ANSWER), 3 stale (`updatedAt` in the future or older than the
    ///      window). Never reverts.
    function _readFeed(IAggregatorV3 feed, uint256 stalenessSec) private view returns (uint256 price8, uint8 err) {
        (bool ok, bytes memory ret) =
            address(feed).staticcall(abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector));
        if (!ok || ret.length < 160) return (0, 1);
        // Decode as five FULL words: every 32-byte word is a valid uint256/int256, so given the
        // length check this decode is total. Narrow (uint80) types would let a hostile feed revert
        // in this frame via dirty high bits in the ignored roundId/answeredInRound words
        // (`abi.decode` validates value-type ranges) — those words carry no signal used here.
        (, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0 || uint256(answer) > MAX_ANSWER) return (0, 2);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > stalenessSec) return (0, 3);
        return (uint256(answer), 0);
    }
}
