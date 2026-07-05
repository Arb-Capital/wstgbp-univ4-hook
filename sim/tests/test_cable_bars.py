import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim.bars import BarSeries, load_csv  # noqa: E402
from cablesim.bars import DAY, CableFair, NavStepModel, OracleSeries  # noqa: E402

T0 = 1_700_000_000


def _flat_bars(n: int, px: float = 1.25, t0: int = T0) -> BarSeries:
    return BarSeries([t0 + 60 * i for i in range(n)], [px] * n)


# ---------------------------------------------------------------- nav steps


def test_nav_steps_exact_powers():
    m = NavStepModel(t0=T0, step_bps=9.0, period_days=7.0, phase_days=3.0)
    first = T0 + 3 * DAY
    assert m.nav(T0) == 1.0
    assert m.nav(first - 1) == 1.0
    assert m.nav(first) == 1.0009  # exactly one step, exactly at the instant
    assert m.nav(first + 7 * DAY - 1) == 1.0009
    assert m.nav(first + 7 * DAY) == 1.0009**2
    # k steps => (1+step)^k exactly
    assert m.nav(first + 26 * 7 * DAY) == 1.0009**27


def test_nav_step_indices_recorded():
    # 15 days of bars, phase 3d, period 7d => ratchets at day 3 and day 10.
    bars = _flat_bars(15 * 24 * 60)
    fair = CableFair(bars)
    assert len(fair.ratchet_indices) == 2
    i1, i2 = fair.ratchet_indices
    assert bars.timestamps[i1] >= T0 + 3 * DAY > bars.timestamps[i1 - 1]
    assert bars.timestamps[i2] >= T0 + 10 * DAY > bars.timestamps[i2 - 1]


def test_ratchet_lowers_fair_discretely():
    bars = _flat_bars(5 * 24 * 60)  # constant cable across the day-3 ratchet
    fair = CableFair(bars)
    i = fair.ratchet_indices[0]
    before, after = fair.fair_true(i - 1), fair.fair_true(i)
    # fair = 1/(g*nav): the step lowers fair by exactly the nav factor.
    assert after < before
    assert abs(after * 1.0009 - before) < 1e-15


# ---------------------------------------------------------------- oracle deadband


def test_oracle_commits_on_deviation_only():
    px = [1.25] * 10 + [1.2510] * 10 + [1.2520] * 10  # +8bps, then +16bps from start
    bars = BarSeries([T0 + 60 * i for i in range(30)], px)
    o = OracleSeries(bars, deviation=0.0015, heartbeat=DAY)
    assert o.committed[9] == 1.25
    assert o.committed[15] == 1.25  # +8bps: inside the 15bps deadband
    assert o.committed[25] == 1.2520  # +16bps: committed


def test_oracle_commits_on_heartbeat():
    n = 25 * 60  # 25 hours of flat-ish drift below the deadband
    px = [1.25 * (1 + 0.0000001 * i) for i in range(n)]
    bars = BarSeries([T0 + 60 * i for i in range(n)], px)
    o = OracleSeries(bars, deviation=0.0015, heartbeat=DAY)
    assert o.committed[23 * 60] == 1.25  # still the first commit before 24h
    assert o.committed[24 * 60 + 1] != 1.25  # heartbeat forced a refresh


def test_fee_series_uses_oracle_fair_and_live_nav():
    px = [1.25] * 10 + [1.2510] * 10  # +8bps: inside deadband
    bars = BarSeries([T0 + 60 * i for i in range(20)], px)
    fair = CableFair(bars)
    # oracle fair stays anchored to the committed 1.25 while true fair moved
    assert fair.fair_oracle(15) == fair.fair_oracle(0)
    assert fair.fair_true(15) != fair.fair_true(0)


# ---------------------------------------------------------------- weekend gaps


def test_weekend_gap_forward_fills_at_72h(tmp_path):
    # Friday close .. Sunday reopen: a 48h hole must load under max_gap_min=4320.
    rows = [(T0 + 60 * i, 1.25) for i in range(10)]
    reopen = rows[-1][0] + 48 * 3600
    rows += [(reopen + 60 * i, 1.26) for i in range(10)]
    csv = tmp_path / "gap.csv"
    csv.write_text("\n".join(f"{t},{p},{p},{p},{p},1" for t, p in rows) + "\n")

    bars = load_csv(csv, max_gap_min=4320)
    # filled to a strict 60s grid: the hole is forward-filled flat at 1.25
    idx_mid = 10 + (48 * 3600 // 60) // 2
    assert bars.ethgbp[idx_mid] == 1.25
    assert bars.timestamps[-1] - bars.timestamps[0] == (len(bars.timestamps) - 1) * 60

    # ...and the default 6h cap would refuse the same file (the wethsim default is not
    # forex-aware; regimes must pass max_gap_min explicitly).
    try:
        load_csv(csv)  # default max_gap_min=360
        raised = False
    except ValueError:
        raised = True
    assert raised
