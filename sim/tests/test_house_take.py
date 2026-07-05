import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim.bars import BarSeries  # noqa: E402
from cablesim.bars import CableFair, NavStepModel  # noqa: E402
from cablesim.costs import CableCosts  # noqa: E402
from cablesim.runner import RunConfig, run  # noqa: E402

T0 = 1_700_000_000


def _flat_fair(n_bars: int) -> CableFair:
    bars = BarSeries([T0 + 60 * i for i in range(n_bars)], [1.25] * n_bars)
    # phase far in the future: NO ratchets — isolates the accounting from the conveyor.
    return CableFair(bars, NavStepModel(t0=T0, phase_days=10_000.0))


def test_house_take_zero_when_nothing_happens():
    r = run(_flat_fair(100), RunConfig(kind="static5", organic_per_hour=0.0), CableCosts())
    assert r.arb_fills == 0
    assert r.redeem_vol_wsg == 0 and r.mint_vol_wsg == 0
    assert r.protocol_rev_usd == 0.0
    assert abs(r.house_take_usd) < 1e-6  # pool untouched, bench = pol exactly
    assert r.ratchets == 0


def test_pure_conveyor_protocol_rev_is_25bps_of_redeemed_volume():
    # Constant cable, organic 0, static-5: the only flow is the conveyor. From a
    # start-at-fair pool the conveyor arms once accumulated ratchets exceed the full-loop
    # breakeven (~2250 ppm = half-band + stable leg + fee), i.e. from ratchet 3 of the
    # 9bps steps. Protocol revenue must equal
    #   12.5bps x redeem_vol   (redeem leg, at fill price)
    # + 12.5bps x redeem_vol   (upstream mint of the net-redeemed inventory, at end price)
    # = 25bps x redeem_vol within the tiny fill-vs-end price drift.
    n = 4 * 7 * 24 * 60  # 4 weeks: ratchets at days 3, 10, 17, 24
    bars = BarSeries([T0 + 60 * i for i in range(n)], [1.25] * n)
    cable = CableFair(bars, NavStepModel(t0=T0, step_bps=9.0, phase_days=3.0))
    costs = CableCosts(gas_gwei=0.01)
    r = run(cable, RunConfig(kind="static5", organic_per_hour=0.0), costs)

    assert r.ratchets == 4
    assert r.arb_fills >= 1
    assert r.mint_vol_wsg == 0 and r.redeem_vol_wsg > 0
    usd_per_wsg = 1.25 * 1.0009**4  # end price (post-steps NAV)
    expected = r.redeem_vol_wsg * usd_per_wsg * 25 / 1e4
    assert abs(r.protocol_rev_usd - expected) / expected < 0.01

    # House take = LP PnL + protocol rev, coherently.
    assert abs(r.house_take_usd - (r.pol_pnl_vs_bench_usd + r.protocol_rev_usd)) < 1e-9


def test_balanced_churn_pays_band_on_both_legs_without_upstream_term():
    # Force one mint fill then one redeem fill via cable moves (no ratchet): protocol rev
    # = 12.5bps x mint_vol + 12.5bps x redeem_vol + 12.5bps x max(0, redeem - mint).
    n = 3 * 24 * 60
    third = n // 3
    px = [1.25] * third + [1.2560] * third + [1.2440] * (n - 2 * third)  # -/+ ~50bps legs
    bars = BarSeries([T0 + 60 * i for i in range(n)], px)
    cable = CableFair(bars, NavStepModel(t0=T0, phase_days=10_000.0))
    costs = CableCosts(gas_gwei=0.01)
    r = run(cable, RunConfig(kind="static5", organic_per_hour=0.0), costs)

    assert r.mint_vol_wsg > 0 and r.redeem_vol_wsg > 0
    lo = (r.mint_vol_wsg + r.redeem_vol_wsg) * 12.5 / 1e4 * 0.9 / cable.fair_true(n - 1)
    hi = (r.mint_vol_wsg + r.redeem_vol_wsg + max(0.0, r.redeem_vol_wsg - r.mint_vol_wsg)) * 12.5 / 1e4 * 1.1 / cable.fair_true(n - 1)
    assert lo <= r.protocol_rev_usd <= hi
