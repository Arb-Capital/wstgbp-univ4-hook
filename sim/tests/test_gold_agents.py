import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim import feemath  # noqa: E402
from wethsim.pool import Pool  # noqa: E402
from goldsim.agents import GoldArb  # noqa: E402
from goldsim.costs import GoldCosts  # noqa: E402

# Anchor state: gold $2000, cable 1.25, nav 1.05, basis 50 bps.
USD_WSG = 1.25 * 1.05
USD_XAUT = 2000.0 * (1 - 0.005)
FAIR_TRUE = USD_XAUT / USD_WSG  # token-market wstGBP per XAUT
FAIR_ORACLE = 2000.0 / USD_WSG  # metal-priced (what the hook computes)
STATIC5 = lambda mint, d: 500  # noqa: E731

# Full-loop breakeven on this venue: half-band 1250 + cross leg 1500 + fee 500 ppm.
BREAKEVEN_PPM = 1250 + 1500 + 500


def _pool(displaced_ppm: int, tvl_wsg: float = 250_000.0) -> Pool:
    price = FAIR_TRUE * (1 + displaced_ppm / 1e6)
    unit = Pool.make(price, 1.0, 1.50).value_wsg(price)
    return Pool.make(price, tvl_wsg / unit, 1.50)


def _cheap_gas() -> GoldCosts:
    return GoldCosts(gas_gwei=0.01, eth_usd=3000.0)  # ~$0.001/bundle


def test_redeem_side_fills_and_stops_at_full_loop_breakeven():
    # Pool displaced +40bps above TOKEN fair (post-ratchet geometry): redeem-side only.
    # The no-loss stop is the FULL-LOOP breakeven: half-band 1250 + cross leg 1500 +
    # fee 500 = ~3250 ppm — wider than cablesim's 2250 (two recycle hops, not one).
    pool = _pool(4000)
    arb = GoldArb(_cheap_gas(), STATIC5)
    fill = arb.step(pool, FAIR_TRUE, FAIR_TRUE, USD_WSG, USD_XAUT)
    assert fill is not None and fill.side == "redeem"
    assert fill.redeem_notional_wsg > 0 and fill.mint_notional_wsg == 0
    d_after = feemath.deviation_ppm(pool.price, FAIR_TRUE)
    assert BREAKEVEN_PPM - 150 <= d_after <= BREAKEVEN_PPM + 200, d_after

    # No further edge at this deviation: the next step declines.
    assert arb.step(pool, FAIR_TRUE, FAIR_TRUE, USD_WSG, USD_XAUT) is None

    # Below breakeven: NO fill (it takes ~4 accumulated 9bps ratchets to arm from rest).
    shallow = _pool(3000)
    assert GoldArb(_cheap_gas(), STATIC5).step(shallow, FAIR_TRUE, FAIR_TRUE, USD_WSG, USD_XAUT) is None


def test_mint_side_mirrors_below_fair():
    pool = _pool(-4000)  # wstGBP rich (the gold-rally direction): mint + sell
    arb = GoldArb(_cheap_gas(), STATIC5)
    fill = arb.step(pool, FAIR_TRUE, FAIR_TRUE, USD_WSG, USD_XAUT)
    assert fill is not None and fill.side == "mint"
    assert fill.mint_notional_wsg > 0 and fill.redeem_notional_wsg == 0
    d_after = feemath.deviation_ppm(pool.price, FAIR_TRUE)
    assert -BREAKEVEN_PPM - 200 <= d_after <= -BREAKEVEN_PPM + 150, d_after

    assert arb.step(pool, FAIR_TRUE, FAIR_TRUE, USD_WSG, USD_XAUT) is None


def test_gas_kills_participation():
    # Same +40bps displacement, but gas dwarfs the edge on this pool depth: no fill.
    pool = _pool(4000, tvl_wsg=25_000.0)
    costly = GoldCosts(gas_gwei=200.0, eth_usd=3000.0)  # ~$270/bundle
    arb = GoldArb(costly, STATIC5)
    assert arb.step(pool, FAIR_TRUE, FAIR_TRUE, USD_WSG, USD_XAUT) is None
    assert arb.fills == 0


def test_fee_charged_at_oracle_deviation_profit_at_true():
    # The venue's structural state: the hook prices off the METAL feed, whose fair sits
    # (1-basis)^-1 ABOVE token fair — so the pool looks CHEAPER to the hook than to the
    # arb, permanently. The executed fee must come from the ORACLE deviation.
    pool = _pool(4000)
    seen_fees = []

    def spy_fee(mint, d):
        seen_fees.append((mint, d))
        return 500

    arb = GoldArb(_cheap_gas(), spy_fee)
    pre_price = pool.price
    fill = arb.step(pool, FAIR_TRUE, FAIR_ORACLE, USD_WSG, USD_XAUT)
    assert fill is not None
    executed_calls = [d for mint, d in seen_fees if not mint and d != 0]
    d_used = executed_calls[-1]
    assert d_used == feemath.deviation_ppm(pre_price, FAIR_ORACLE)
    # basis geometry: vs the metal fair the same pool price reads ~basis LOWER.
    assert d_used < feemath.deviation_ppm(pre_price, FAIR_TRUE)


def test_redeem_conveyor_is_never_surcharged_at_the_basis_rest_state():
    # DISCOUNT regime (XAUt below the metal feed — the 2026-07-11 estimate): at rest the
    # pool is RICH vs token fair (d_true > 0) but CHEAP vs metal fair
    # (d_oracle ~ d_true - basis < 0): redeem-side flow does not "close" the oracle
    # deviation, so no threshold setting can surcharge the conveyor here — the
    # misclassification lands on the MINT side instead (see the acceptance suite).
    d_true = 4000
    pool = _pool(d_true)
    d_oracle = feemath.deviation_ppm(pool.price, FAIR_ORACLE)
    assert d_oracle < 0  # cheap in the hook's eyes
    p = feemath.FeeParams(deviation_threshold_ppm=1000, toxicity_slope_ppm=1_000_000)
    # redeem side (not mint): d_oracle < 0 => closes=False => base only.
    assert feemath.surcharge_ppm(False, d_oracle, p) == 0
    # a mint-side trade at the same rest state IS surcharged under a low threshold.
    assert feemath.surcharge_ppm(True, d_oracle, p) > 0


def test_premium_regime_flips_the_surcharged_side():
    # PREMIUM regime — the MIRROR, live when measured 2026-07-16 (XAUt ~11bp ABOVE the
    # metal feed): the rest state sits at d_oracle > 0, so the redeem conveyor reads
    # deviation-CLOSING and pays ramp surcharge under a sub-|basis| threshold while
    # resting mint-side flow rides free. Ramp, not cap — the extended basis-sensitivity
    # table (RESULTS_XAUT.md, basis {-50..100}) prices this regime; anchor-cell
    # economics stay flat below basis 0 (SECURITY_XAUT_WSTGBP.md §6).
    premium = 0.0025  # 25bp token premium == negative basis
    rest_price = FAIR_ORACLE * (1 + premium)  # pool at rest == token-market fair
    pool = Pool.make(rest_price, 1.0, 1.50)
    d_oracle = feemath.deviation_ppm(pool.price, FAIR_ORACLE)
    assert d_oracle > 0  # rich in the hook's eyes
    p = feemath.FeeParams(deviation_threshold_ppm=1000, toxicity_slope_ppm=1_000_000)
    # redeem side now closes the positive oracle deviation => ramp surcharge...
    surcharge = feemath.surcharge_ppm(False, d_oracle, p)
    assert 0 < surcharge < p.surcharge_cap_ppm  # ...priced on the ramp, not the cap.
    # mint side opens it => base only.
    assert feemath.surcharge_ppm(True, d_oracle, p) == 0
