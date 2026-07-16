// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FeeMath (XAUT/wstGBP venue)
/// @notice Pure fee computation for the XAUT/wstGBP dynamic-fee hook: a directional base fee plus a
///         toxicity surcharge that only informed flow pays, clamped to `[minFee, maxFee]`.
/// @dev UNIT CONVENTION: every quantity here is **ppm** (parts-per-million), the v4 lpFee unit
///      (`LPFeeLibrary.MAX_LP_FEE = 1_000_000` = 100%; 1 bp = 100 ppm, so 30 bps = 3000). Deviation
///      is ppm of price; the slope is a dimensionless multiplier scaled by 1e6 (500_000 = 0.5 fee-ppm
///      per deviation-ppm). No bps-denominated variable exists in this venue's code.
///
///      Direction / sign convention (mirrored in the hook's NatSpec and the test suites):
///      `deviationPpm = pool(wstGBP-per-XAUT) / fair − 1`, so
///      - `d > 0` — the pool prices XAUT *rich* (wstGBP cheap); the closing flow sells XAUT — buys
///        wstGBP — and the redeem side pays. This is the post-NAV-ratchet conveyor state (and the
///        token–metal basis rest state: XAUt trades below the metal feed, so the pool sits at
///        d ≈ −basis — see the hook NatSpec).
///      - `d < 0` — the pool prices XAUT *cheap* (wstGBP rich); the closing flow sells wstGBP
///        (mint side pays). A gold rally raises fair and lands here too.
///      Flow pushing the pool away from fair value, or trading inside the threshold band, pays base only.
///
///      This venue's `FeeParams` has TEN fields (two oracle feeds ⇒ two staleness windows), the WETH
///      venue's shape with the XAU/USD window in the ETH/USD position; `swapFee`/`surchargePpm`
///      semantics are byte-identical across all three dynamic-fee venues and pinned by the same
///      shared sim vector table (`sim/tests/feemath_vectors.json`).
///
///      Every function is total for arbitrary inputs (including `int256.min` deviation): no code path
///      can revert except `checkParams`, which exists to revert. The hook relies on this for its
///      never-revert guarantee; validity of the params themselves is enforced once at
///      construction/`setFeeParams` time via `checkParams`, never per swap.
library FeeMath {
    uint256 internal constant PPM = 1e6;

    /// @notice Absolute ceiling on `maxFee`: 10% (100_000 ppm). Far below v4's `MAX_LP_FEE` and below
    ///         `OVERRIDE_FEE_FLAG` (0x400000), so a clamped fee can never collide with the flag bits.
    uint24 internal constant MAX_FEE_CEILING = 100_000;

    /// @dev Excess deviation beyond this is economically indistinguishable (any nonzero slope already
    ///      saturates every admissible cap at 1e30 ppm of excess); clamping here keeps the surcharge
    ///      product overflow-free for arbitrary `int256` deviations without changing any result.
    uint256 private constant EXCESS_CLAMP = 1e30;

    /// @notice All ten fields are uint24 => 240 bits => exactly one storage slot in the hook.
    ///         Fees/threshold/cap in ppm; slope ppm-scaled multiplier; staleness in seconds
    ///         (uint24 max ≈ 194 days — ample for two 24h-heartbeat feed windows).
    struct FeeParams {
        uint24 baseFeeMintSide; // wstGBP-in base fee
        uint24 baseFeeRedeemSide; // XAUT-in base fee
        uint24 minFee; // clamp floor
        uint24 maxFee; // clamp ceiling (hard cap 100_000)
        uint24 fallbackFee; // oracle-failure / paused fee, both directions
        uint24 deviationThresholdPpm; // surcharge-free band around fair
        uint24 toxicitySlopePpm; // fee-ppm per deviation-ppm × 1e6 (500_000 = 0.5×)
        uint24 surchargeCapPpm; // surcharge ceiling
        uint24 xauUsdStalenessSec; // XAU/USD window (90_000 = 86400s heartbeat + margin)
        uint24 gbpUsdStalenessSec; // GBP/USD window (90_000 = 86400s heartbeat + margin)
    }

    error FeeParamsOutOfBounds();

    /// @notice The per-swap LP fee (ppm): directional base + toxicity surcharge, clamped.
    /// @param isMintSide true when the swap's input currency is wstGBP (mint side), false for XAUT in.
    /// @param deviationPpm signed pool-vs-fair deviation per the sign convention above.
    function swapFee(bool isMintSide, int256 deviationPpm, FeeParams memory p) internal pure returns (uint24) {
        uint256 fee = (isMintSide ? p.baseFeeMintSide : p.baseFeeRedeemSide) + surchargePpm(isMintSide, deviationPpm, p);
        if (fee < p.minFee) fee = p.minFee;
        if (fee > p.maxFee) fee = p.maxFee;
        // maxFee ≤ MAX_FEE_CEILING < 2^24 (checkParams), so the cast cannot truncate for valid params;
        // for pathological unvalidated params the clamp above still bounds fee to p.maxFee < 2^24.
        return uint24(fee);
    }

    /// @notice The surcharge component alone (ppm). Zero for uninformed flow (not closing the
    ///         deviation) and inside the threshold band; linear in excess deviation above it, capped.
    function surchargePpm(bool isMintSide, int256 deviationPpm, FeeParams memory p) internal pure returns (uint256) {
        // Informed flow trades toward fair value: d > 0 is closed by selling XAUT (redeem side),
        // d < 0 by selling wstGBP (mint side). d == 0 has nothing to close.
        bool closes = deviationPpm > 0 ? !isMintSide : (deviationPpm < 0 && isMintSide);
        if (!closes) return 0;

        uint256 a;
        unchecked {
            // Total for int256.min: unchecked negation yields 2^255, a huge magnitude that (correctly)
            // saturates the cap below.
            a = deviationPpm > 0 ? uint256(deviationPpm) : uint256(-deviationPpm);
        }
        if (a <= p.deviationThresholdPpm) return 0;

        uint256 excess = a - p.deviationThresholdPpm;
        // Overflow-free by construction: with any nonzero slope, 1e30 ppm of excess already yields a
        // surcharge ≥ 1e24, saturating every admissible cap (< 2^24), so clamping the excess never
        // changes the result; with slope 0 the product is 0 either way.
        if (excess > EXCESS_CLAMP) excess = EXCESS_CLAMP;
        uint256 s = excess * p.toxicitySlopePpm / PPM;
        return s > p.surchargeCapPpm ? p.surchargeCapPpm : s;
    }

    /// @notice Shared validity gate for constructor and `setFeeParams`. Reverts `FeeParamsOutOfBounds`.
    /// @dev Bounds: `0 < minFee ≤ {bases, fallbackFee} ≤ maxFee ≤ 100_000` (10% absolute ceiling),
    ///      `surchargeCapPpm ≤ maxFee`, `deviationThresholdPpm ≤ 100_000`, both staleness windows
    ///      nonzero. The two bases are independently settable (asymmetric responsiveness is a
    ///      legitimate policy choice) — no mint-vs-redeem ordering is enforced.
    function checkParams(FeeParams memory p) internal pure {
        if (
            p.minFee == 0 || p.maxFee > MAX_FEE_CEILING || p.minFee > p.baseFeeMintSide || p.baseFeeMintSide > p.maxFee
                || p.minFee > p.baseFeeRedeemSide || p.baseFeeRedeemSide > p.maxFee || p.minFee > p.fallbackFee
                || p.fallbackFee > p.maxFee || p.surchargeCapPpm > p.maxFee || p.deviationThresholdPpm > 100_000
                || p.xauUsdStalenessSec == 0 || p.gbpUsdStalenessSec == 0
        ) revert FeeParamsOutOfBounds();
    }
}
