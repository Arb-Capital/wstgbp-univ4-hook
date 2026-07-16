import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim.bars import BarSeries  # noqa: E402
from cablesim.bars import DAY, NavStepModel  # noqa: E402
from goldsim.bars import GoldFair, compose  # noqa: E402

T0 = 1_700_000_000


def _flat(n: int, px: float, t0: int = T0) -> BarSeries:
    return BarSeries([t0 + 60 * i for i in range(n)], [px] * n)


# ---------------------------------------------------------------- compose


def test_compose_trims_to_overlap_index_aligned():
    xau = _flat(100, 2000.0, t0=T0 + 600)  # starts 10 minutes late
    gbp = _flat(100, 1.25, t0=T0)  # ends 10 minutes early
    x, g = compose(xau, gbp)
    assert x.timestamps == g.timestamps
    assert x.timestamps[0] == T0 + 600
    assert x.timestamps[-1] == T0 + 99 * 60
    assert len(x) == 90


def test_compose_rejects_misaligned_grid():
    xau = _flat(10, 2000.0, t0=T0 + 30)  # off the minute grid
    gbp = _flat(10, 1.25, t0=T0)
    with pytest.raises(ValueError):
        compose(xau, gbp)


def test_compose_rejects_disjoint_windows():
    xau = _flat(10, 2000.0, t0=T0)
    gbp = _flat(10, 1.25, t0=T0 + DAY)
    with pytest.raises(ValueError):
        compose(xau, gbp)


# ---------------------------------------------------------------- fair / basis / numeraire


def test_basis_applies_to_true_series_only():
    n = 24 * 60
    gold = GoldFair(_flat(n, 2000.0), _flat(n, 1.25), NavStepModel(t0=T0), basis_bps=50.0)
    # oracle fair is METAL-priced (no basis): 2000/(1.25*1) at nav 1.
    assert gold.fair_oracle(0) == pytest.approx(2000.0 / 1.25)
    # true fair is TOKEN-priced: exactly (1 - basis) below the oracle fair.
    assert gold.fair_true(0) == pytest.approx(gold.fair_oracle(0) * (1 - 0.005))
    # the venue's rest state: a pool trading AT token fair reads d ~ -basis to the hook.
    assert (gold.fair_true(0) / gold.fair_oracle(0) - 1.0) * 1e6 == pytest.approx(-5000.0)


def test_numeraire_legs_are_consistent():
    n = 24 * 60
    gold = GoldFair(_flat(n, 2000.0), _flat(n, 1.25), NavStepModel(t0=T0), basis_bps=50.0)
    for i in (0, n // 2, n - 1):
        assert gold.usd_per_wsg(i) == pytest.approx(1.25 * gold.nav(i))
        assert gold.usd_per_xaut(i) == pytest.approx(2000.0 * 0.995)
        # fair_true == usd_per_xaut / usd_per_wsg by construction — the invariant that
        # makes cablesim's band-edge target formulas carry over verbatim.
        assert gold.fair_true(i) == pytest.approx(gold.usd_per_xaut(i) / gold.usd_per_wsg(i))


# ---------------------------------------------------------------- two independent deadbands


def test_deadbands_commit_independently():
    n = 12 * 60
    k = 6 * 60
    xau_px = [2000.0] * k + [2000.0 * 1.002] * (n - k)  # +0.2% — inside XAU's 0.3% band
    gbp_px = [1.25] * k + [1.25 * 1.002] * (n - k)  # +0.2% — outside GBP's 0.15% band
    xau = BarSeries([T0 + 60 * i for i in range(n)], xau_px)
    gbp = BarSeries([T0 + 60 * i for i in range(n)], gbp_px)
    gold = GoldFair(xau, gbp, NavStepModel(t0=T0), basis_bps=0.0)
    # GBP committed; XAU still frozen at its last commit.
    assert gold.gbp_oracle.committed[k] == pytest.approx(1.25 * 1.002)
    assert gold.xau_oracle.committed[k] == pytest.approx(2000.0)
    # fair_oracle moved by the GBP leg only (down — the sign trap: g up => fair down).
    assert gold.fair_oracle(k) == pytest.approx(2000.0 / (1.25 * 1.002))
    # true fair saw both legs move.
    assert gold.fair_true(k) == pytest.approx(2000.0 * 1.002 / (1.25 * 1.002))


def test_xau_deadband_commits_past_threshold():
    n = 4 * 60
    k = 2 * 60
    xau_px = [2000.0] * k + [2000.0 * 1.0035] * (n - k)  # +0.35% — outside 0.3%
    xau = BarSeries([T0 + 60 * i for i in range(n)], xau_px)
    gbp = _flat(n, 1.25)
    gold = GoldFair(xau, gbp, NavStepModel(t0=T0), basis_bps=0.0)
    assert gold.xau_oracle.committed[k] == pytest.approx(2000.0 * 1.0035)
    # sign trap, other leg: xau up => fair UP.
    assert gold.fair_oracle(k) > gold.fair_oracle(0)


# ---------------------------------------------------------------- ratchet plumbing


def test_ratchet_indices_and_fair_step():
    n = 15 * 24 * 60  # ratchets at day 3 and day 10
    gold = GoldFair(_flat(n, 2000.0), _flat(n, 1.25), NavStepModel(t0=T0), basis_bps=50.0)
    assert len(gold.ratchet_indices) == 2
    i = gold.ratchet_indices[0]
    # nav in the denominator of BOTH fairs: one step lowers each by exactly the factor.
    assert gold.fair_true(i) * 1.0009 == pytest.approx(gold.fair_true(i - 1))
    assert gold.fair_oracle(i) * 1.0009 == pytest.approx(gold.fair_oracle(i - 1))
    # and RAISES the NAV-anchored USD leg of wstGBP.
    assert gold.usd_per_wsg(i) == pytest.approx(gold.usd_per_wsg(i - 1) * 1.0009)
