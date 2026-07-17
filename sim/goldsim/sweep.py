"""Grid execution + RESULTS_XAUT.md rendering for the XAUT (gold) venue.

Grid design notes (venue decisions, 2026-07-15):
- Bases: {(30,5), (26,1), (50,10)} bps mint/redeem. The first two carry the proven
  USDC-venue asymmetry candidates; (50,10) is added because gold-in-GBP vol is ~6x
  cable's — a wider uninformed-flow edge may earn its keep on this venue where it could
  not on a near-stable pair. min_fee = 50 ppm for the whole grid.
- Thresholds: {1000, 3000, 5000, 7000} ppm — THE axis this sweep exists for: the pool
  RESTS at d ≈ -basis (grid designed against the ~5000 ppm discount estimate of
  ROADMAP.md 2026-07-11; live measurement 2026-07-16 puts the basis near zero and
  sign-flipped — see the basis-sensitivity note below), so the threshold must decide
  whether the rest state itself is surcharged (always-on toxicity pricing) or only
  excursions beyond it. Spans below-basis, at-basis and above-basis.
- Slopes {0.25, 0.5, 1.0}x; caps {20, 60, 100} bps (100 added for gilt/gold-shock scale
  dislocations — this pair's p95 deviations run larger than cable's).
- Baselines: static-5 (conveyor-viability control — no live static pool exists for this
  pair, unlike the USDC venue) and static-30.
- Cells: 3 regimes x organic {0, 1}/hr at basis 50 bps. Ranking: house take,
  worst-case rank across all six cells, conveyor-dead override ranks dead configs last;
  ranks are competition-ranked (exact ties share a rank) and max-rank ties between
  configs break by total house take across cells, then config label if still exact,
  never grid order (2026-07-16 review — exact ties are real: max_fee-clamped schedules
  produce bit-identical trajectories).
- Extra vs cablesim: a BASIS-SENSITIVITY table (winner + control across basis
  {-50, -25, 0, 25, 50, 100} bps in the range-2023/organic-0 cell) — the basis is an
  estimate, not a measurement, and it is SIGN-UNSTABLE: the ~+50bp discount estimated
  2026-07-11 had flipped to a ~11bp premium (XAUt ABOVE the metal feed) when measured
  2026-07-16, so the axis spans both signs. The winner must not be fragile either side
  of zero. A full-grid ranking confirmation at basis 0 lives in RESULTS_XAUT_BASIS0.md
  (`make sim-sweep-xaut-basis0`).
"""

from dataclasses import replace
import concurrent.futures as cf
import hashlib
import os
import pathlib
import shlex
import subprocess
import sys

from wethsim import feemath

from .bars import GoldFair, NavStepModel, load_csv
from .costs import GoldCosts
from .runner import RunConfig, RunResult, run

BASE_PAIRS = [(3000, 500), (2600, 100), (5000, 1000)]  # ppm (30,5) (26,1) (50,10) bps
THRESHOLDS = [1000, 3000, 5000, 7000]
SLOPES = [250_000, 500_000, 1_000_000]
CAPS = [2000, 6000, 10_000]
ORGANIC_AXIS = [0.0, 1.0]  # per hour
GAS_SENSITIVITY_GWEI = [0.2, 1.0, 5.0, 25.0]
BASIS_SENSITIVITY_BPS = [-50.0, -25.0, 0.0, 25.0, 50.0, 100.0]
CONVEYOR_DEAD_FRACTION = 0.10

# Each worker rebuilds two multi-month 1m bar series per job; a full-cpu_count pool on a
# loaded desktop tips systemd-oomd's memory-pressure threshold (observed 2026-07-16: it
# kills the WHOLE terminal cgroup, not the sweep). Leave two cores of headroom by
# default; override with GOLDSIM_WORKERS.
WORKERS = int(os.environ.get("GOLDSIM_WORKERS", "0")) or max(1, (os.cpu_count() or 4) - 2)


def grid() -> list[RunConfig]:
    cfgs = []
    for mint, redeem in BASE_PAIRS:
        for thr in THRESHOLDS:
            for slope in SLOPES:
                for cap in CAPS:
                    p = feemath.FeeParams(
                        base_fee_mint_side=mint,
                        base_fee_redeem_side=redeem,
                        min_fee=50,
                        max_fee=10_000,
                        fallback_fee=mint,  # fail-safe: idle the conveyor during outages
                        deviation_threshold_ppm=thr,
                        toxicity_slope_ppm=slope,
                        surcharge_cap_ppm=cap,
                    )
                    cfgs.append(RunConfig(kind="dynamic", params=p))
    cfgs.append(RunConfig(kind="static5"))
    cfgs.append(RunConfig(kind="static30"))
    return cfgs


def _fair_for(regime: dict, nav_cfg: dict, basis_bps: float) -> GoldFair:
    xau = load_csv(regime["xau_csv"], max_gap_min=regime.get("max_gap_min", 4320))
    gbp = load_csv(regime["gbp_csv"], max_gap_min=regime.get("max_gap_min", 4320))
    nav = NavStepModel(
        t0=max(xau.timestamps[0], gbp.timestamps[0]),
        step_bps=nav_cfg.get("step_bps", 9.0),
        period_days=nav_cfg.get("period_days", 7.0),
        phase_days=nav_cfg.get("phase_days", 3.0),
    )
    return GoldFair(xau, gbp, nav, basis_bps=basis_bps)


def _costs_for(regime: dict, gwei: float | None = None) -> GoldCosts:
    return GoldCosts(
        gas_gwei=gwei if gwei is not None else regime.get("gas_gwei", 1.0),
        eth_usd=regime.get("eth_usd", 3000.0),
    )


def _one(args):
    regime, nav_cfg, cfg, organic, gwei, basis_bps = args
    fair = _fair_for(regime, nav_cfg, basis_bps)
    costs = _costs_for(regime, gwei)
    res = run(fair, replace(cfg, organic_per_hour=organic), costs)
    return regime["name"], organic, gwei, basis_bps, res


def run_sweep(
    regimes: list[dict],
    nav_cfg: dict,
    basis_bps: float,
    out_path: str,
    git_rev: str = "",
    analysis_only: bool = False,
) -> None:
    cfgs = grid()
    jobs = [(r, nav_cfg, cfg, organic, None, basis_bps) for r in regimes for organic in ORGANIC_AXIS for cfg in cfgs]

    # cells: (regime, organic) -> [RunResult]
    cells: dict[tuple[str, float], list[RunResult]] = {(r["name"], o): [] for r in regimes for o in ORGANIC_AXIS}
    done = 0
    with cf.ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for regime_name, organic, _, _, res in ex.map(_one, jobs):
            cells[(regime_name, organic)].append(res)
            done += 1
            if done % 25 == 0 or done == len(jobs):
                print(f"grid {done}/{len(jobs)}", file=sys.stderr, flush=True)

    _stamp_conveyor_dead(cells)
    winner = _pick_winner(cells)

    # Sensitivity anchor cell: the calm/range regime (the basis/conveyor isolator) at organic 0.
    anchor = next((r for r in regimes if "calm" in r["name"] or "range" in r["name"]), regimes[0])
    win_cfg = next(c for c in cfgs if _label(c) == winner)
    ctl_cfg = next(c for c in cfgs if c.kind == "static5")

    # Gas sensitivity: the winner + the static5 control across gwei.
    gas_jobs = [(anchor, nav_cfg, c, 0.0, g, basis_bps) for g in GAS_SENSITIVITY_GWEI for c in (win_cfg, ctl_cfg)]
    gas_res: dict[tuple[float, str], RunResult] = {}
    with cf.ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for _, _, gwei, _, res in ex.map(_one, gas_jobs):
            gas_res[(gwei, res.label)] = res
    gas_rows = [(g, gas_res[(g, winner)], gas_res[(g, _label(ctl_cfg))]) for g in GAS_SENSITIVITY_GWEI]

    # Basis sensitivity: same anchor cell, basis swept — the venue-specific fragility check.
    basis_jobs = [(anchor, nav_cfg, c, 0.0, None, b) for b in BASIS_SENSITIVITY_BPS for c in (win_cfg, ctl_cfg)]
    basis_res: dict[tuple[float, str], RunResult] = {}
    with cf.ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for _, _, _, b, res in ex.map(_one, basis_jobs):
            basis_res[(b, res.label)] = res
    basis_rows = [(b, basis_res[(b, winner)], basis_res[(b, _label(ctl_cfg))]) for b in BASIS_SENSITIVITY_BPS]

    render(
        regimes,
        nav_cfg,
        basis_bps,
        cells,
        winner,
        win_cfg,
        gas_rows,
        basis_rows,
        out_path,
        git_rev,
        analysis_only=analysis_only,
    )


def _label(cfg: RunConfig) -> str:
    from .runner import label_for

    return label_for(cfg)


def _stamp_conveyor_dead(cells) -> None:
    """A config is conveyor-dead in a cell when its redeem conveyor volume collapses below
    10% of the static5 control's in the SAME cell, or its searcher loses money on fills —
    either way the parameter set starves protocol revenue."""
    for _, results in cells.items():
        control = next(r for r in results if r.label.startswith("baseline: static 5bps"))
        for r in results:
            if control.redeem_vol_wsg <= 0:
                continue  # no conveyor in this cell at all; nothing to kill
            dead = r.redeem_vol_wsg < CONVEYOR_DEAD_FRACTION * control.redeem_vol_wsg or (
                r.arb_fills > 0 and r.searcher_pnl_usd <= 0
            )
            r.conveyor_dead = dead


def _rank_key(r: RunResult):
    return (1 if r.conveyor_dead else 0, -r.house_take_usd)


def _competition_ranks(results) -> list[tuple[int, RunResult]]:
    """Rows sorted by `_rank_key`, competition-ranked ('1224'): rows whose key is EXACTLY
    equal share a rank of 1 + the number of strictly better rows. Exact ties are real on
    this venue — configs whose fee schedules clamp to max_fee over an identical fill
    sequence produce bit-identical economics (verified float-exact at basis 0) — and the
    previous insertion-ordered ranking let GRID ORDER decide the minimax winner between
    them (review finding 2026-07-16). Returns [(rank, result), ...] in sorted order."""
    rows = sorted(results, key=_rank_key)
    ranked: list[tuple[int, RunResult]] = []
    prev_key: tuple | None = None
    rank = 0
    for i, res in enumerate(rows):
        key = _rank_key(res)
        if key != prev_key:
            rank = i + 1
            prev_key = key
        ranked.append((rank, res))
    return ranked


def _pick_winner(cells) -> str:
    """Minimax competition rank across cells; max-rank ties between configs break by
    TOTAL house take across all cells (the declared secondary objective). If both
    objectives tie exactly, config label is the stable tertiary key — never grid order."""
    ranks: dict[str, int] = {}
    totals: dict[str, float] = {}
    for _, results in cells.items():
        for rank, res in _competition_ranks(results):
            if res.label.startswith("baseline"):
                continue
            ranks[res.label] = max(ranks.get(res.label, 0), rank)
            totals[res.label] = totals.get(res.label, 0.0) + res.house_take_usd
    return min(ranks.items(), key=lambda kv: (kv[1], -totals[kv[0]], kv[0]))[0]


def render(
    regimes,
    nav_cfg,
    basis_bps,
    cells,
    winner,
    win_cfg,
    gas_rows,
    basis_rows,
    out_path,
    git_rev,
    analysis_only=False,
):
    lines = []
    regen = (
        shlex.join(
            ["python3", "sim/run_sweep_xaut.py", "--basis-bps", f"{basis_bps:g}", "--out", str(out_path)]
        )
        if analysis_only
        else "make sim-sweep-xaut"
    )
    lines.append("# XAUT/wstGBP (gold venue) fee-parameter sweep results\n")
    lines.append(f"Generated by `sim/run_sweep_xaut.py` — do not edit by hand; rerun `{regen}`.\n")
    lines.append(f"- git rev: `{git_rev or 'unknown'}`")
    lines.append(
        f"- NAV model: DISCRETE weekly ratchet, {nav_cfg.get('step_bps', 9.0)} bps every "
        f"{nav_cfg.get('period_days', 7.0):g} days (phase {nav_cfg.get('phase_days', 3.0):g}d) — "
        "the conveyor driver, deliberately not smooth drift"
    )
    lines.append(
        "- Oracle model: TWO Chainlink deadbands — XAU/USD 0.3%/24h (the chunky one) and GBP/USD "
        "0.15%/24h — fees price off the COMMITTED values, arb profit off the live bars; NAV is "
        "read live (as on-chain)"
    )
    lines.append(
        f"- TOKEN-METAL BASIS: {basis_bps:g} bps (positive = XAUt BELOW the metal feed) — the pool "
        "RESTS at d ≈ -basis, so the sign decides which side is misclassified at rest (discount: "
        "mint side surcharged; premium: the redeem conveyor pays the ramp). Ranking cells run at "
        "this basis; the winner's fragility across BOTH signs is tabled below. The basis is an "
        "estimate and sign-unstable in live data (~+50bp discount est. 2026-07-11; ~11bp premium "
        "measured 2026-07-16)"
    )
    lines.append(
        f"- POL {int(RunConfig('static5').pol_tvl_wsg):,} wstGBP over a x{RunConfig('static5').range_width:g} "
        "geometric static range; organic flow axis {0, 1}/hr median "
        f"{int(RunConfig('static5').organic_median_wsg)} wstGBP (0 = observed reality: ~pure conveyor)"
    )
    lines.append(
        "- OBJECTIVE: house take (USD) = LP PnL vs rebalanced 50/50 + protocol band revenue "
        "(12.5bps x mint vol + 12.5bps x redeem vol + 12.5bps x net-redeemed upstream mint). "
        "Conveyor-dead configs (redeem vol < 10% of the static-5 control's, or searcher PnL <= 0) "
        "rank LAST unconditionally — the conveyor is protocol revenue, not a leak to plug."
    )
    for r in regimes:
        lines.append(
            f"- regime **{r['name']}**: XAU `{r['xau_csv']}` (sha256 `{_sha256(r['xau_csv'])[:16]}…`), "
            f"GBP `{r['gbp_csv']}` (sha256 `{_sha256(r['gbp_csv'])[:16]}…`), gas "
            f"{r.get('gas_gwei', 1.0)} gwei @ ETH ${r.get('eth_usd', 3000.0):,.0f}"
        )
    lines.append("")

    ranks: dict[str, dict[str, int]] = {}
    for (regime_name, organic), results in sorted(cells.items()):
        cell = f"{regime_name} / organic {organic:g}/hr"
        ranked = _competition_ranks(results)
        for rank, res in ranked:
            ranks.setdefault(res.label, {})[cell] = rank
        lines.append(f"## Cell: {cell}\n")
        lines.append(
            "| # | config | house take (USD) | (bps of TVL) | LP PnL vs 50/50 | protocol rev | "
            "fees base / surcharge | redeem vol (wsg) | mint vol (wsg) | searcher PnL | "
            "ratchets | lag p50 (bars) | band p50/p95 (ppm) | fills | breach | dead |"
        )
        lines.append("|---|" + "---|" * 15)
        for rank, res in ranked:
            lines.append(
                f"| {rank} | {res.label} | {res.house_take_usd:,.0f} | {res.house_take_bps:,.1f} | "
                f"{res.pol_pnl_vs_bench_usd:,.0f} | {res.protocol_rev_usd:,.0f} | "
                f"{res.fees_base_usd:,.0f} / {res.fees_surcharge_usd:,.0f} | "
                f"{res.redeem_vol_wsg:,.0f} | {res.mint_vol_wsg:,.0f} | {res.searcher_pnl_usd:,.0f} | "
                f"{res.ratchets} | {res.lag_p50_bars:g} | {res.band_p50_ppm:,.0f} / {res.band_p95_ppm:,.0f} | "
                f"{res.arb_fills} | {res.breach_bars} | {'DEAD' if res.conveyor_dead else ''} |"
            )
        lines.append("")

    lines.append("## Cross-cell robustness (rank per cell; lower is better; dead ranks last)\n")
    lines.append(
        "Ranks are COMPETITION ranks ('1224'): rows with bit-identical (dead, house take) keys "
        "share a rank — exact ties are real here (max_fee-clamped schedules produce identical "
        "trajectories), and letting grid order split them once decided a winner (2026-07-16 "
        "review). Winner = min of max rank; max-rank ties break by total house take across cells; "
        "an exact tie on both objectives breaks lexicographically by config label."
    )
    cell_names = [f"{rn} / organic {o:g}/hr" for (rn, o) in sorted(cells.keys())]
    lines.append("| config | " + " | ".join(cell_names) + " | max rank |")
    lines.append("|---|" + "---|" * (len(cell_names) + 1))
    robust = sorted(ranks.items(), key=lambda kv: max(kv[1].values()))
    for label, per in robust:
        cells_str = " | ".join(str(per.get(c, "-")) for c in cell_names)
        lines.append(f"| {label} | {cells_str} | {max(per.values())} |")
    lines.append("")

    anchor_name = cell_names[0].split(" / ")[0] if cell_names else "?"
    lines.append("## Gas sensitivity (range regime, organic 0; winner vs static-5 control)\n")
    lines.append(
        "The arb-participation constraint is gas-sensitive at conveyor notionals (the recycle"
        " route is two legs on this venue) — this table shows where the conveyor dies as gas rises."
    )
    lines.append(
        "| gwei | winner house take | winner redeem vol | winner lag p50 | static5 house take | static5 redeem vol |"
    )
    lines.append("|---|---|---|---|---|---|")
    for gwei, w, c in gas_rows:
        lines.append(
            f"| {gwei:g} | {w.house_take_usd:,.0f} | {w.redeem_vol_wsg:,.0f} | {w.lag_p50_bars:g} | "
            f"{c.house_take_usd:,.0f} | {c.redeem_vol_wsg:,.0f} |"
        )
    lines.append("")

    lines.append("## Basis sensitivity (range regime, organic 0; winner vs static-5 control)\n")
    lines.append(
        "The token-metal basis is an ESTIMATE and SIGN-UNSTABLE (~+50 bps discount estimated"
        " 2026-07-11; ~11 bps premium measured 2026-07-16 — the feed prices the metal, the pool"
        " trades the token). Negative rows model the premium regime, where the rest state flips"
        " to d > 0 and the redeem conveyor pays ramp surcharge. The winner must not be fragile"
        " either side of zero: watch for the conveyor dying or house take inverting as the"
        " rest-state deviation crosses the threshold."
    )
    lines.append(
        "| basis (bps) | winner house take | winner redeem vol | winner fees base/surcharge | "
        "static5 house take | static5 redeem vol |"
    )
    lines.append("|---|---|---|---|---|---|")
    for b, w, c in basis_rows:
        lines.append(
            f"| {b:g} | {w.house_take_usd:,.0f} | {w.redeem_vol_wsg:,.0f} | "
            f"{w.fees_base_usd:,.0f} / {w.fees_surcharge_usd:,.0f} | "
            f"{c.house_take_usd:,.0f} | {c.redeem_vol_wsg:,.0f} |"
        )
    lines.append("")

    p = win_cfg.params
    if analysis_only:
        lines.append("## This run's winner (analysis only — NOT the production stamp)\n")
        lines.append("Winner by worst-case cross-cell competition rank (ties break by total house take,")
        lines.append("then config label if still exact):")
        lines.append(f"**{winner}**. This file is the alternate-basis regime leg of a TWO-REGIME")
        lines.append("decision: production params are stamped from the design-anchor run")
        lines.append("(`sim/RESULTS_XAUT.md`) and confirmed by the same minimax objective across the UNION")
        lines.append("of both runs' cells — this run's winner alone does NOT feed")
        lines.append("`DeployXautHook.simParams()` (two-regime record:")
        lines.append("`docs/READINESS_XAUT_WSTGBP_2026-07-16.md`, review-response addendum).\n")
    else:
        lines.append("## Recommended starting FeeParams (10-field XAUT-venue shape)\n")
        lines.append("Winner by worst-case cross-cell competition rank (ties break by total house take,")
        lines.append("then config label if still exact):")
        lines.append(f"**{winner}**. Review the tables before")
        lines.append("adopting — the block below feeds `script/DeployXautHook.s.sol::simParams()`, which the")
        lines.append("production-params smoke tests import directly (no duplicated constants; the fork fixture")
        lines.append("deliberately keeps separate working defaults).\n")
    lines.append("```")
    lines.append(f"baseFeeMintSide       = {p.base_fee_mint_side}")
    lines.append(f"baseFeeRedeemSide     = {p.base_fee_redeem_side}")
    lines.append(f"minFee                = {p.min_fee}")
    lines.append(f"maxFee                = {p.max_fee}")
    lines.append(f"fallbackFee           = {p.fallback_fee}   // = mint-side base: fail-safe idles the conveyor")
    lines.append(f"deviationThresholdPpm = {p.deviation_threshold_ppm}")
    lines.append(f"toxicitySlopePpm      = {p.toxicity_slope_ppm}")
    lines.append(f"surchargeCapPpm       = {p.surcharge_cap_ppm}")
    lines.append("xauUsdStalenessSec    = 90000  // 86400s heartbeat + margin (feed-derived, not swept)")
    lines.append("gbpUsdStalenessSec    = 90000  // 86400s heartbeat + margin (feed-derived, not swept)")
    lines.append("```\n")
    lines.append("Carried-over caveat (verified on the WETH venue, SECURITY_XAUT_WSTGBP.md §1): the")
    lines.append("single-fill arb agent pays top-of-ramp surcharges that a splitting searcher erodes")
    lines.append("toward the schedule integral — surcharge revenue above is an upper bound; prefer")
    lines.append("the robust rank over raw house take, and start conservative (owner can retune).")
    lines.append(f"(Anchor cell for both sensitivity tables: {anchor_name} / organic 0.)")
    lines.append("")

    pathlib.Path(out_path).write_text("\n".join(lines))
    print(f"wrote {out_path}")


def _sha256(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_rev() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return ""
