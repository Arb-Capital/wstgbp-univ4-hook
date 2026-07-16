"""Acceptance anchors for the gold venue, mirroring test_cablesim_acceptance:

(1) the static-5 control on a synthetic constant-price series must run the same
    ratchet conveyor the USDC venue's live pool shows — surviving the token-metal basis
    rest state (the conveyor's economics are token-market; the basis only moves what the
    HOOK sees);
(2) the threshold axis must behave as designed around the basis: at rest the redeem
    conveyor can never be surcharged (it reads as non-closing to the metal-priced hook),
    while mint-side organic flow IS surcharged iff the threshold sits below the basis —
    the misclassification the sweep's threshold axis exists to price;
(3) a gold rally exercises the mint-side loop end-to-end.
"""

import math
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim import feemath  # noqa: E402
from wethsim.bars import BarSeries  # noqa: E402
from cablesim.bars import NavStepModel  # noqa: E402
from goldsim.bars import GoldFair  # noqa: E402
from goldsim.costs import GoldCosts  # noqa: E402
from goldsim.runner import RunConfig, run  # noqa: E402

T0 = 1_700_000_000
WEEKS = 6


def _series(px_xau, px_gbp=1.25, weeks=WEEKS) -> tuple[BarSeries, BarSeries]:
    n = weeks * 7 * 24 * 60
    xau = [px_xau(i / n) if callable(px_xau) else px_xau for i in range(n)]
    ts = [T0 + 60 * i for i in range(n)]
    return BarSeries(ts, xau), BarSeries(ts, [px_gbp] * n)


def _gold(px_xau=2000.0, basis_bps=50.0, weeks=WEEKS) -> GoldFair:
    xau, gbp = _series(px_xau, weeks=weeks)
    return GoldFair(xau, gbp, NavStepModel(t0=T0, step_bps=9.0, period_days=7.0, phase_days=3.0), basis_bps=basis_bps)


def _params(thr: int) -> feemath.FeeParams:
    return feemath.FeeParams(
        base_fee_mint_side=3000,
        base_fee_redeem_side=500,
        min_fee=50,
        max_fee=10_000,
        fallback_fee=3000,
        deviation_threshold_ppm=thr,
        toxicity_slope_ppm=1_000_000,
        surcharge_cap_ppm=6000,
    )


def test_static5_conveyor_survives_the_basis_rest_state():
    gold = _gold()
    # Very-cheap-gas regime: this venue's x1.5 static range holds ~4x less virtual depth
    # than cablesim's x1.10, so the first armed ratchet's excess (~350 ppm over the
    # ~3250 ppm full-loop breakeven) is only worth a few cents — at 0.1 gwei it would
    # not clear the bundle and the conveyor skips a week (that regime is the sweep's
    # gas-sensitivity table, not this anchor).
    costs = GoldCosts(gas_gwei=0.01, eth_usd=3000.0)
    r = run(gold, RunConfig(kind="static5", organic_per_hour=0.0), costs)

    # (a) Pure redeem-side conveyor: from a start-at-token-fair pool it arms once
    #     accumulated ratchets clear the full-loop breakeven (~3250 ppm: half-band 1250 +
    #     cross leg 1500 + fee 500 — wider than cable's 2250, so it arms from ratchet 4)
    #     and then answers weekly.
    assert r.ratchets == WEEKS
    assert r.arb_fills >= r.ratchets - 3
    assert r.mint_vol_wsg == 0.0, "no mint-side flow in a pure ratchet regime"
    assert r.redeem_vol_wsg > 0.0

    # (b) The pool rests between token fair and one ratchet past the full-loop breakeven
    #     vs TOKEN fair (the pre-fill peak is ~4150 ppm) — the basis does not enter the
    #     conveyor's own economics.
    assert 1250 <= r.band_p50_ppm <= 3700, r.band_p50_ppm
    assert r.band_p95_ppm <= 4400, r.band_p95_ppm

    # (c) Once armed, ratchets are answered promptly (constant prices, cheap gas).
    assert not math.isnan(r.lag_p50_bars)
    assert r.lag_p50_bars <= 5

    # (d) Protocol take ~ 25bps x redeemed volume (12.5 redeem leg + 12.5 upstream mint).
    usd_per_wsg_end = 1.25 * 1.0009**WEEKS
    expected = r.redeem_vol_wsg * usd_per_wsg_end * 25 / 1e4
    assert abs(r.protocol_rev_usd - expected) / expected < 0.01

    # (e) The arb kept a positive skim — the conveyor is alive.
    assert r.searcher_pnl_usd > 0

    # (f) Objective identity.
    assert r.house_take_usd == pytest.approx(r.pol_pnl_vs_bench_usd + r.protocol_rev_usd)


def test_threshold_vs_basis_prices_the_rest_state_misclassification():
    """Organic (uninformed) flow at the basis rest state: its mint-side half reads as
    deviation-closing to the metal-priced hook (d_oracle ~ -basis), so a threshold BELOW
    the basis surcharges it and a threshold ABOVE does not. Setup isolates the rest
    state: no ratchets (step 0), flat prices, TINY organic sizes (median 10 wstGBP —
    ~8 ppm of price impact each, random-walk sigma ~250 ppm over the window) so the pool
    genuinely hovers at token fair and d_oracle stays pinned in a narrow band around
    -5000 ppm. (With larger organic sizes the walk itself becomes the story: an
    undersized threshold also surcharges the CLAMPING arb on the mint side, widening the
    no-arb band to ~cap+threshold+loop and letting the pool wander — the sweep prices
    that effect through house take; this anchor isolates the pure rest state.)"""
    costs = GoldCosts(gas_gwei=0.1, eth_usd=3000.0)

    def _rest() -> GoldFair:
        xau, gbp = _series(2000.0, weeks=2)
        return GoldFair(xau, gbp, NavStepModel(t0=T0, step_bps=0.0), basis_bps=50.0)

    flow = dict(organic_per_hour=2.0, organic_median_wsg=10.0, seed=7)
    low = run(_rest(), RunConfig(kind="dynamic", params=_params(1000), **flow), costs)
    high = run(_rest(), RunConfig(kind="dynamic", params=_params(7000), **flow), costs)

    # Same seed, same flow: the low threshold taxes every resting mint-side trade
    # (~4000 ppm of surcharge at d_oracle ~ -5000); the high threshold — sitting above
    # basis + walk-width — collects NOTHING.
    assert low.fees_surcharge_usd > 0
    assert high.fees_surcharge_usd == pytest.approx(0.0, abs=1e-9)

    # And the ratchet conveyor itself survives a LOW threshold: at rest the redeem side
    # is never deviation-closing in oracle terms (d_oracle < 0), so no threshold setting
    # can surcharge it — redeem volume matches the static-5 control's.
    costs_cheap = GoldCosts(gas_gwei=0.01, eth_usd=3000.0)
    static = run(_gold(), RunConfig(kind="static5", organic_per_hour=0.0), costs_cheap)
    dyn = run(_gold(), RunConfig(kind="dynamic", params=_params(1000), organic_per_hour=0.0), costs_cheap)
    assert dyn.redeem_vol_wsg > 0.5 * static.redeem_vol_wsg


def test_gold_rally_exercises_the_mint_side():
    # Gold +10% over the window: fair_true rises through the ratchet steps, the pool goes
    # wstGBP-rich (d_true < 0) and the mint loop must fire.
    gold = _gold(px_xau=lambda f: 2000.0 * (1 + 0.10 * f))
    costs = GoldCosts(gas_gwei=0.1, eth_usd=3000.0)
    r = run(gold, RunConfig(kind="static5", organic_per_hour=0.0), costs)
    assert r.mint_vol_wsg > 0.0, "rally must drive mint-side fills"
    assert r.searcher_pnl_usd > 0


def test_benchmark_holds_both_risky_legs():
    # Flat prices: nav ratchets lift the wstGBP USD leg ~5.4bps/week-average; a 50/50
    # bench must end above start but below a 100% wstGBP position. Gold +10%: the bench
    # must capture ~half the gold move. (cablesim's quote leg was flat $1 — this guards
    # the two-risky-legs rewrite.)
    costs = GoldCosts(gas_gwei=0.1, eth_usd=3000.0)
    flat = run(_gold(), RunConfig(kind="static5", organic_per_hour=0.0), costs)
    rally = run(
        _gold(px_xau=lambda f: 2000.0 * (1 + 0.10 * f)),
        RunConfig(kind="static5", organic_per_hour=0.0),
        costs,
    )
    # pol_pnl = pol_value - bench; in the rally the bench rises ~5% while a static range
    # holding both legs converges to the underperforming side — LP PnL vs bench must be
    # clearly NEGATIVE (impermanent loss vs 50/50), where the flat run is ~breakeven.
    assert abs(flat.pol_pnl_vs_bench_usd) < 0.02 * 250_000 * 1.3125  # within 2% of TVL
    assert rally.pol_pnl_vs_bench_usd < flat.pol_pnl_vs_bench_usd
