"""Integer-ppm port of src/weth/lib/FeeMath.sol.

Every quantity is ppm, mirroring the Solidity unit convention (1 bp = 100 ppm).
Semantics are pinned to the contract by sim/tests/feemath_vectors.json, which the
Solidity suite asserts against the library (duplicated as constants there) and
test_feemath.py asserts against this port.
"""

from dataclasses import dataclass

PPM = 1_000_000
EXCESS_CLAMP = 10**30


@dataclass(frozen=True)
class FeeParams:
    base_fee_mint_side: int = 3000
    base_fee_redeem_side: int = 500
    min_fee: int = 200
    max_fee: int = 10_000
    fallback_fee: int = 3000
    deviation_threshold_ppm: int = 1000
    toxicity_slope_ppm: int = 500_000
    surcharge_cap_ppm: int = 6000

    def label(self) -> str:
        return (
            f"slope={self.toxicity_slope_ppm / PPM:g}x "
            f"bases=({self.base_fee_mint_side // 100},{self.base_fee_redeem_side // 100})bps"
        )


def surcharge_ppm(is_mint_side: bool, deviation_ppm: int, p: FeeParams) -> int:
    """Mirror of FeeMath.surchargePpm: integer floor division, same gating."""
    closes = (deviation_ppm > 0 and not is_mint_side) or (deviation_ppm < 0 and is_mint_side)
    if not closes:
        return 0
    a = abs(deviation_ppm)
    if a <= p.deviation_threshold_ppm:
        return 0
    excess = min(a - p.deviation_threshold_ppm, EXCESS_CLAMP)
    s = excess * p.toxicity_slope_ppm // PPM
    return min(s, p.surcharge_cap_ppm)


def swap_fee(is_mint_side: bool, deviation_ppm: int, p: FeeParams) -> int:
    """Mirror of FeeMath.swapFee (clamped base + surcharge)."""
    base = p.base_fee_mint_side if is_mint_side else p.base_fee_redeem_side
    fee = base + surcharge_ppm(is_mint_side, deviation_ppm, p)
    return max(p.min_fee, min(fee, p.max_fee))


def deviation_ppm(pool_price: float, fair_price: float) -> int:
    """Signed ppm deviation of pool vs fair (float inputs; contract uses WAD ints —
    the sub-ppm difference is immaterial to the sim)."""
    return int((pool_price / fair_price - 1.0) * PPM)
