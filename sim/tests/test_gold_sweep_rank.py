"""Winner-selection rules for the goldsim sweep (2026-07-16 review finding).

Exact house-take ties are REAL on this venue — configs whose fee schedules clamp to
max_fee over an identical fill sequence produce bit-identical economics (verified
float-exact at basis 0 in all three organic-0 cells) — and the original
insertion-ordered ranking split such ties by grid order, once deciding the minimax
winner. These tests pin the fixed rules: competition ranks (exact ties share a rank),
dead-last override intact, max-rank ties between configs broken by total house take,
and exact remaining ties broken by config label — never by grid order.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from goldsim.runner import RunResult  # noqa: E402
from goldsim.sweep import _competition_ranks, _pick_winner  # noqa: E402


def _r(label: str, house: float, dead: bool = False) -> RunResult:
    return RunResult(
        label=label,
        house_take_usd=house,
        house_take_bps=0.0,
        pol_pnl_vs_bench_usd=0.0,
        protocol_rev_usd=0.0,
        fees_total_usd=0.0,
        fees_base_usd=0.0,
        fees_surcharge_usd=0.0,
        redeem_vol_wsg=0.0,
        mint_vol_wsg=0.0,
        searcher_pnl_usd=0.0,
        ratchets=0,
        lag_p50_bars=0.0,
        band_p50_ppm=0.0,
        band_p95_ppm=0.0,
        arb_fills=0,
        breach_bars=0,
        organic_fee_usd=0.0,
        conveyor_dead=dead,
    )


def test_exact_ties_share_a_competition_rank():
    # '1224' ranking: three exact ties at 100 all rank 1; the next row ranks 4 (not 2).
    ranked = _competition_ranks([_r("a", 100.0), _r("b", 100.0), _r("c", 50.0), _r("d", 100.0)])
    assert [(rk, r.label) for rk, r in ranked] == [(1, "a"), (1, "b"), (1, "d"), (4, "c")]


def test_dead_ranks_last_even_on_a_house_take_tie():
    ranked = _competition_ranks([_r("dead", 100.0, dead=True), _r("alive", 100.0)])
    assert [(rk, r.label) for rk, r in ranked] == [(1, "alive"), (2, "dead")]


def test_max_rank_ties_break_by_total_house_take_not_grid_order():
    # "first" precedes "second" everywhere (grid order). Binding cell c1: exact tie at 0
    # behind two baseline rows (they hold rank positions but can't win) -> both rank 3.
    # Cell c2: second (100) beats first (50) but both stay <= rank 3, so max ranks TIE
    # at 3 -> the total house take (100 vs 50) must decide, picking "second" despite
    # grid order.
    cells = {
        ("c1", 0.0): [_r("first", 0.0), _r("second", 0.0), _r("baseline: a", 20.0), _r("baseline: b", 10.0)],
        ("c2", 0.0): [_r("first", 50.0), _r("second", 100.0), _r("baseline: a", 200.0)],
    }
    assert _pick_winner(cells) == "second"


def test_exact_objective_ties_break_by_label_not_grid_order():
    forward = {("c1", 0.0): [_r("z-config", 100.0), _r("a-config", 100.0)]}
    reverse = {("c1", 0.0): list(reversed(forward[("c1", 0.0)]))}
    assert _pick_winner(forward) == "a-config"
    assert _pick_winner(reverse) == "a-config"


def test_baselines_hold_rank_positions_but_never_win():
    # A baseline outranking every config still can't be the winner; the best non-baseline
    # config (rank 2 here) is.
    cells = {("c1", 0.0): [_r("baseline: static 5bps (control)", 500.0), _r("cfg", 100.0)]}
    assert _pick_winner(cells) == "cfg"
