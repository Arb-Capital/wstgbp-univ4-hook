"""Acceptance anchor: the static-5 control on a synthetic constant-cable series must
reproduce the OBSERVED behavior of the live wstGBP/USDC 5bps pool (July 2026 readout):
one-sided USDC-in buys after each NAV ratchet, pool resting pinned near the burn floor,
protocol earning ~25bps per conveyor round trip."""

import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim import feemath  # noqa: E402
from wethsim.bars import BarSeries  # noqa: E402
from cablesim.bars import CableFair, NavStepModel  # noqa: E402
from cablesim.costs import CableCosts  # noqa: E402
from cablesim.runner import RunConfig, fee_fn_for, run  # noqa: E402
from cablesim.agents import CableArb  # noqa: E402
from wethsim.pool import Pool  # noqa: E402

T0 = 1_700_000_000
WEEKS = 6


def _six_week_conveyor() -> CableFair:
    n = WEEKS * 7 * 24 * 60
    bars = BarSeries([T0 + 60 * i for i in range(n)], [1.25] * n)
    return CableFair(bars, NavStepModel(t0=T0, step_bps=9.0, period_days=7.0, phase_days=3.0))


def test_static5_reproduces_the_observed_conveyor():
    cable = _six_week_conveyor()
    # Cheap-gas regime: the observed pool's 16 fills averaged ~$70 — only rational when
    # per-bundle gas is negligible. (At 1 gwei the conveyor on this depth is already
    # marginal and skips weeks — that regime is the sweep's gas-sensitivity table.)
    costs = CableCosts(gas_gwei=0.1, eth_usd=3000.0)
    cfg = RunConfig(kind="static5", organic_per_hour=0.0)
    r = run(cable, cfg, costs)

    # (a) All flow is USDC-in conveyor buys (the observed 15/16 pattern, idealized to
    #     16/16 with no organic flow and no cable moves). From a start-at-fair pool the
    #     conveyor arms once accumulated ratchets exceed the full-loop breakeven
    #     (~2250 ppm), i.e. from ratchet 3 — then answers weekly.
    assert r.ratchets == WEEKS
    assert r.arb_fills >= r.ratchets - 2
    assert r.mint_vol_wsg == 0.0, "no mint-side flow in a pure ratchet regime"
    assert r.redeem_vol_wsg > 0.0

    # (b) The pool rests pinned near the burn floor (the observed +0.6bps-above-burn
    #     state, net of the modeled fee + stable legs): p50 |deviation| within
    #     [half-band, half-band + fee + stable-leg + slack].
    assert 1250 <= r.band_p50_ppm <= 3000, r.band_p50_ppm

    # (c) Once armed, every ratchet is answered promptly (constant cable, cheap gas):
    #     p50 lag ≈ 0 bars (the first two unarmed ratchets carry the ramp-up lag).
    assert not math.isnan(r.lag_p50_bars)
    assert r.lag_p50_bars <= 5

    # (d) Protocol take ≈ 25bps x redeemed volume (12.5 redeem leg + 12.5 upstream mint).
    usd_per_wsg = 1.25 * 1.0009**WEEKS
    expected = r.redeem_vol_wsg * usd_per_wsg * 25 / 1e4
    assert abs(r.protocol_rev_usd - expected) / expected < 0.01

    # (e) The arb kept a positive skim (the live pool's ~11.6bps edge vs burn, here net of
    #     the modeled legs) — the conveyor is alive.
    assert r.searcher_pnl_usd > 0


def test_dynamic_fee_recaptures_skim_without_killing_conveyor():
    """The venue thesis end-to-end: vs static-5, a WETH-style dynamic config with an
    above-half-band threshold takes MORE house revenue while the conveyor keeps running."""
    cable = _six_week_conveyor()
    costs = CableCosts(gas_gwei=0.1, eth_usd=3000.0)

    static = run(cable, RunConfig(kind="static5", organic_per_hour=0.0), costs)
    p = feemath.FeeParams(
        base_fee_mint_side=3000,
        base_fee_redeem_side=500,
        min_fee=50,
        max_fee=10_000,
        fallback_fee=3000,
        deviation_threshold_ppm=1500,
        toxicity_slope_ppm=500_000,
        surcharge_cap_ppm=2000,
    )
    dyn = run(cable, RunConfig(kind="dynamic", params=p, organic_per_hour=0.0), costs)

    assert dyn.redeem_vol_wsg > 0.5 * static.redeem_vol_wsg, "conveyor still alive"
    assert dyn.house_take_usd > static.house_take_usd, "surcharge recaptures the skim"
    assert dyn.searcher_pnl_usd < static.searcher_pnl_usd, "the skim came from the arb"
    assert dyn.searcher_pnl_usd > 0 or dyn.arb_fills == 0
