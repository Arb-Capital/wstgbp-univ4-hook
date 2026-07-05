"""Grid execution + RESULTS_USDC.md rendering for the USDC (cable) venue.

Grid design notes (venue decisions, 2026-07-05):
- Bases: {(26,1), (30,5), (5,5)} bps mint/redeem. The first two keep the WETH venue's
  +25bps asymmetry with 1bps and 5bps USDC-in sides; the symmetric (5,5) is deliberately
  included because the +25bps rationale must RE-EARN its keep here — this wrapper's loops
  are cost-symmetric (mint +12.5 / burn -12.5), so only the redeem-dominant ratchet flow
  can justify asymmetry. min_fee = 50 ppm for the whole grid (the 100 ppm base would
  violate checkParams against the WETH default min of 200).
- Thresholds: {1000, 1300, 1500, 2000} ppm — spans always-on (arms at the pool's
  LEGITIMATE rest states, the band edges at ±1250 ppm), just-past-half-band, and
  post-ratchet-only. This axis answers the band-geometry question.
- Slopes {0.25, 0.5, 1.0}x; caps {20, 60} bps (20 sized to the ~10bps ratchet + 15bps
  oracle deadband scale; 60 for gilt-style dislocations).
- Baselines: static-5 (the LIVE pool — the acceptance anchor and the conveyor-dead
  reference) and static-30.
- Cells: 3 regimes x organic {0, 1}/hr. Ranking: house take, worst-case rank across all
  six cells (never-bad beats sometimes-great), with the conveyor-dead override ranking
  dead configs last unconditionally.
"""

from dataclasses import replace
import concurrent.futures as cf
import hashlib
import pathlib
import subprocess
import subprocess

from wethsim import feemath

from .bars import CableFair, NavStepModel, load_csv
from .costs import CableCosts
from .runner import RunConfig, RunResult, run

BASE_PAIRS = [(2600, 100), (3000, 500), (500, 500)]  # ppm (26,1) (30,5) (5,5) bps
THRESHOLDS = [1000, 1300, 1500, 2000]
SLOPES = [250_000, 500_000, 1_000_000]
CAPS = [2000, 6000]
ORGANIC_AXIS = [0.0, 1.0]  # per hour
GAS_SENSITIVITY_GWEI = [0.2, 1.0, 5.0, 25.0]
CONVEYOR_DEAD_FRACTION = 0.10


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


def _fair_for(regime: dict, nav_cfg: dict) -> CableFair:
    bars = load_csv(regime["csv"], max_gap_min=regime.get("max_gap_min", 4320))
    nav = NavStepModel(
        t0=bars.timestamps[0],
        step_bps=nav_cfg.get("step_bps", 9.0),
        period_days=nav_cfg.get("period_days", 7.0),
        phase_days=nav_cfg.get("phase_days", 3.0),
    )
    return CableFair(bars, nav)


def _costs_for(regime: dict, gwei: float | None = None) -> CableCosts:
    return CableCosts(
        gas_gwei=gwei if gwei is not None else regime.get("gas_gwei", 1.0),
        eth_usd=regime.get("eth_usd", 3000.0),
    )


def _one(args):
    regime, nav_cfg, cfg, organic, gwei = args
    fair = _fair_for(regime, nav_cfg)
    costs = _costs_for(regime, gwei)
    res = run(fair, replace(cfg, organic_per_hour=organic), costs)
    return regime["name"], organic, gwei, res


def run_sweep(regimes: list[dict], nav_cfg: dict, out_path: str, git_rev: str = "") -> None:
    cfgs = grid()
    jobs = [(r, nav_cfg, cfg, organic, None) for r in regimes for organic in ORGANIC_AXIS for cfg in cfgs]

    # cells: (regime, organic) -> [RunResult]
    cells: dict[tuple[str, float], list[RunResult]] = {(r["name"], o): [] for r in regimes for o in ORGANIC_AXIS}
    with cf.ProcessPoolExecutor() as ex:
        for regime_name, organic, _, res in ex.map(_one, jobs):
            cells[(regime_name, organic)].append(res)

    _stamp_conveyor_dead(cells)
    winner = _pick_winner(cells)

    # Gas sensitivity: the winner + the static5 control in calm-2024/organic 0 across gwei.
    gas_rows: list[tuple[float, RunResult, RunResult]] = []
    calm = next((r for r in regimes if "calm" in r["name"]), regimes[0])
    win_cfg = next(c for c in cfgs if _label(c) == winner)
    ctl_cfg = next(c for c in cfgs if c.kind == "static5")
    gas_jobs = [(calm, nav_cfg, c, 0.0, g) for g in GAS_SENSITIVITY_GWEI for c in (win_cfg, ctl_cfg)]
    gas_res: dict[tuple[float, str], RunResult] = {}
    with cf.ProcessPoolExecutor() as ex:
        for _, _, gwei, res in ex.map(_one, gas_jobs):
            gas_res[(gwei, res.label)] = res
    for g in GAS_SENSITIVITY_GWEI:
        gas_rows.append((g, gas_res[(g, winner)], gas_res[(g, _label(ctl_cfg))]))

    render(regimes, nav_cfg, cells, winner, win_cfg, gas_rows, out_path, git_rev)


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


def _pick_winner(cells) -> str:
    ranks: dict[str, int] = {}
    for _, results in cells.items():
        rows = sorted(results, key=_rank_key)
        for i, res in enumerate(rows):
            if res.label.startswith("baseline"):
                continue
            ranks[res.label] = max(ranks.get(res.label, 0), i + 1)
    return min(ranks.items(), key=lambda kv: kv[1])[0]


def render(regimes, nav_cfg, cells, winner, win_cfg, gas_rows, out_path, git_rev):
    lines = []
    lines.append("# wstGBP/USDC (cable venue) fee-parameter sweep results\n")
    lines.append("Generated by `sim/run_sweep_usdc.py` — do not edit by hand; rerun `make sim-sweep-usdc`.\n")
    lines.append(f"- git rev: `{git_rev or 'unknown'}`")
    lines.append(
        f"- NAV model: DISCRETE weekly ratchet, {nav_cfg.get('step_bps', 9.0)} bps every "
        f"{nav_cfg.get('period_days', 7.0):g} days (phase {nav_cfg.get('phase_days', 3.0):g}d) — "
        "the conveyor driver, deliberately not smooth drift"
    )
    lines.append(
        "- Oracle model: Chainlink GBP/USD deadband (0.15% deviation / 24h heartbeat) — fees price "
        "off the COMMITTED value, arb profit off the live bar; NAV is read live (as on-chain)"
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
        digest = _sha256(r["csv"])
        lines.append(
            f"- regime **{r['name']}**: `{r['csv']}` (sha256 `{digest[:16]}…`), gas "
            f"{r.get('gas_gwei', 1.0)} gwei @ ETH ${r.get('eth_usd', 3000.0):,.0f}"
        )
    lines.append("")

    ranks: dict[str, dict[str, int]] = {}
    for (regime_name, organic), results in sorted(cells.items()):
        cell = f"{regime_name} / organic {organic:g}/hr"
        rows = sorted(results, key=_rank_key)
        for i, res in enumerate(rows):
            ranks.setdefault(res.label, {})[cell] = i + 1
        lines.append(f"## Cell: {cell}\n")
        lines.append(
            "| # | config | house take (USD) | (bps of TVL) | LP PnL vs 50/50 | protocol rev | "
            "fees base / surcharge | redeem vol (wsg) | mint vol (wsg) | searcher PnL | "
            "ratchets | lag p50 (bars) | band p50/p95 (ppm) | fills | breach | dead |"
        )
        lines.append("|---|" + "---|" * 15)
        for i, res in enumerate(rows):
            lines.append(
                f"| {i + 1} | {res.label} | {res.house_take_usd:,.0f} | {res.house_take_bps:,.1f} | "
                f"{res.pol_pnl_vs_bench_usd:,.0f} | {res.protocol_rev_usd:,.0f} | "
                f"{res.fees_base_usd:,.0f} / {res.fees_surcharge_usd:,.0f} | "
                f"{res.redeem_vol_wsg:,.0f} | {res.mint_vol_wsg:,.0f} | {res.searcher_pnl_usd:,.0f} | "
                f"{res.ratchets} | {res.lag_p50_bars:g} | {res.band_p50_ppm:,.0f} / {res.band_p95_ppm:,.0f} | "
                f"{res.arb_fills} | {res.breach_bars} | {'DEAD' if res.conveyor_dead else ''} |"
            )
        lines.append("")

    lines.append("## Cross-cell robustness (rank per cell; lower is better; dead ranks last)\n")
    cell_names = [f"{rn} / organic {o:g}/hr" for (rn, o) in sorted(cells.keys())]
    lines.append("| config | " + " | ".join(cell_names) + " | max rank |")
    lines.append("|---|" + "---|" * (len(cell_names) + 1))
    robust = sorted(ranks.items(), key=lambda kv: max(kv[1].values()))
    for label, per in robust:
        cells_str = " | ".join(str(per.get(c, "-")) for c in cell_names)
        lines.append(f"| {label} | {cells_str} | {max(per.values())} |")
    lines.append("")

    lines.append("## Gas sensitivity (calm-2024, organic 0; winner vs static-5 control)\n")
    lines.append(
        "The arb-participation constraint is gas-dominated at this venue's small conveyor"
        " notionals — this table shows where the conveyor dies as gas rises."
    )
    lines.append("| gwei | winner house take | winner redeem vol | winner lag p50 | static5 house take | static5 redeem vol |")
    lines.append("|---|---|---|---|---|---|")
    for gwei, w, c in gas_rows:
        lines.append(
            f"| {gwei:g} | {w.house_take_usd:,.0f} | {w.redeem_vol_wsg:,.0f} | {w.lag_p50_bars:g} | "
            f"{c.house_take_usd:,.0f} | {c.redeem_vol_wsg:,.0f} |"
        )
    lines.append("")

    p = win_cfg.params
    lines.append("## Recommended starting FeeParams (9-field USDC-venue shape)\n")
    lines.append(f"Winner by worst-case cross-cell rank: **{winner}**. Review the tables before")
    lines.append("adopting — the block below feeds `script/DeployUsdcHook.s.sol::simParams()` and is")
    lines.append("duplicated in that venue's test constants.\n")
    lines.append("```")
    lines.append(f"baseFeeMintSide       = {p.base_fee_mint_side}")
    lines.append(f"baseFeeRedeemSide     = {p.base_fee_redeem_side}")
    lines.append(f"minFee                = {p.min_fee}")
    lines.append(f"maxFee                = {p.max_fee}")
    lines.append(f"fallbackFee           = {p.fallback_fee}   // = mint-side base: fail-safe idles the conveyor")
    lines.append(f"deviationThresholdPpm = {p.deviation_threshold_ppm}")
    lines.append(f"toxicitySlopePpm      = {p.toxicity_slope_ppm}")
    lines.append(f"surchargeCapPpm       = {p.surcharge_cap_ppm}")
    lines.append("gbpUsdStalenessSec    = 90000  // 86400s heartbeat + margin (feed-derived, not swept)")
    lines.append("```\n")
    lines.append("Carried-over caveat (verified on the WETH venue, SECURITY_USDC_WSTGBP.md §1): the")
    lines.append("single-fill arb agent pays top-of-ramp surcharges that a splitting searcher erodes")
    lines.append("toward the schedule integral — surcharge revenue above is an upper bound; prefer")
    lines.append("the robust rank over raw house take, and start conservative (owner can retune).")
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
