"""Single-run loop: bar -> organic flow -> arb -> record; plus run metrics."""

from dataclasses import dataclass, field
import math
import random

from . import feemath
from .agents import ArbAgent, OrganicFlow
from .bars import FairSeries
from .costs import Costs
from .pool import Pool

PPM = 1_000_000


@dataclass(frozen=True)
class RunConfig:
    kind: str  # "dynamic" | "static30" | "curve50"
    params: feemath.FeeParams = feemath.FeeParams()
    pol_tvl_wsg: float = 1_000_000.0
    range_width: float = 1.75
    organic_per_hour: float = 6.0
    organic_median_wsg: float = 2_000.0
    seed: int = 1


@dataclass
class RunResult:
    label: str
    pol_pnl_vs_bench_bps: float
    fees_total_wsg: float
    fees_base_wsg: float
    fees_surcharge_wsg: float
    redemption_revenue_wsg: float
    searcher_profit_wsg: float
    band_p50_ppm: float
    band_p95_ppm: float
    cycles: int
    arb_fills: int
    breach_bars: int
    organic_fee_wsg: float


def fee_fn_for(cfg: RunConfig):
    if cfg.kind == "dynamic":
        return lambda mint, d: feemath.swap_fee(mint, d, cfg.params)
    if cfg.kind == "static30":
        return lambda mint, d: 3000
    if cfg.kind == "curve50":
        return lambda mint, d: 2600
    raise ValueError(cfg.kind)


def label_for(cfg: RunConfig) -> str:
    if cfg.kind == "dynamic":
        return cfg.params.label()
    return {"static30": "baseline: static 30bps", "curve50": "baseline: curve-approx 26bps/50%leak"}[cfg.kind]


def run(fair_series: FairSeries, cfg: RunConfig, costs: Costs) -> RunResult:
    rng = random.Random(cfg.seed)
    fair0 = fair_series.fair(0)
    # L from target TVL: probe with L=1 and rescale (avoids hand-deriving the width factor).
    unit_value = Pool.make(fair0, 1.0, cfg.range_width).value_wsg(fair0)
    pool = Pool.make(fair0, cfg.pol_tvl_wsg / unit_value, cfg.range_width)

    fee_fn = fee_fn_for(cfg)
    arb = ArbAgent(costs, fee_fn)
    organic = OrganicFlow(rng, cfg.organic_per_hour / 60.0, cfg.organic_median_wsg)

    v0 = pool.value_wsg(fair0)
    bench = v0
    prev_fair = fair0
    abs_dev_samples: list[int] = []

    n = len(fair_series.bars)
    for i in range(n):
        fair = fair_series.fair(i)
        bench *= 0.5 * (fair / prev_fair) + 0.5  # continuously rebalanced 50/50
        prev_fair = fair

        organic.step(pool, fair, fee_fn)
        arb.step(pool, fair)

        if not pool.in_range():
            pool.breach_bars += 1
        if i % 10 == 0:  # sample the realized band
            abs_dev_samples.append(abs(feemath.deviation_ppm(pool.price, fair)))

    fair_end = fair_series.fair(n - 1)
    fees_total = pool.fees_wsg + pool.fees_weth * fair_end
    fees_base = pool.fees_wsg_base + pool.fees_weth_base * fair_end
    pol_value = pool.value_wsg(fair_end)
    if cfg.kind == "curve50":  # the spec's 50% fee-leakage haircut
        pol_value -= fees_total * 0.5

    abs_dev_samples.sort()
    p50 = abs_dev_samples[len(abs_dev_samples) // 2] if abs_dev_samples else 0
    p95 = abs_dev_samples[int(len(abs_dev_samples) * 0.95)] if abs_dev_samples else 0

    redemption_rev = _redeem_revenue(arb, costs)
    return RunResult(
        label=label_for(cfg),
        pol_pnl_vs_bench_bps=(pol_value - bench) / bench * 1e4,
        fees_total_wsg=fees_total,
        fees_base_wsg=fees_base,
        fees_surcharge_wsg=fees_total - fees_base,
        redemption_revenue_wsg=redemption_rev,
        searcher_profit_wsg=arb.total_profit_wsg,
        band_p50_ppm=p50,
        band_p95_ppm=p95,
        cycles=arb.cycles,
        arb_fills=arb.fills,
        breach_bars=pool.breach_bars,
        organic_fee_wsg=organic.fee_paid_wsg,
    )


def _redeem_revenue(arb: ArbAgent, costs: Costs) -> float:
    return arb.redeem_notional_total * costs.redeem_bps / 1e4
