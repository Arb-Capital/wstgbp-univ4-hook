"""Single-run loop for the USDC venue: bar -> organic flow -> conveyor arb -> record.

THE OBJECTIVE CHANGES vs wethsim (the venue decision that motivates this package): the
house = LP (POL) + the wstGBP protocol. Every completed conveyor round trip pays the
protocol the wrapper band (12.5 bps on mint + 12.5 bps on redeem), so the metric is

    house_take_usd = (pol_value - bench_value)                      # LP leg vs 50/50
                   + 12.5bps * (mint_vol + redeem_vol)              # per-fill, at fill price
                   + 12.5bps * max(0, redeem_vol - mint_vol)        # upstream mint of the
                                                                    # net-redeemed inventory

The third term makes a pure-conveyor run (all buys exit via redeem, inventory originally
minted) equal exactly 25 bps x redeemed volume with no double counting when the arb both
mints and redeems in-sim. A parameter set that kills the conveyor kills protocol revenue:
the sweep flags such configs `conveyor-dead` and ranks them last unconditionally.

Numeraire: USD(C). All fair/oracle plumbing per cablesim.bars (fees at oracle deviation,
economics at true fair). Telemetry includes per-ratchet conveyor response lag.
"""

from dataclasses import dataclass
import random

from wethsim import feemath
from wethsim.pool import Pool

from .agents import CableArb, OrganicFlow
from .bars import CableFair
from .costs import CableCosts

PPM = 1_000_000


@dataclass(frozen=True)
class RunConfig:
    kind: str  # "dynamic" | "static5" | "static30"
    params: feemath.FeeParams = feemath.FeeParams()
    pol_tvl_wsg: float = 250_000.0
    range_width: float = 1.10  # +-~10% geometric: gilt-2022 cable excursion + ~1y nav drift
    organic_per_hour: float = 0.0  # honest default: observed flow is ~pure conveyor
    organic_median_wsg: float = 500.0
    seed: int = 1


@dataclass
class RunResult:
    label: str
    house_take_usd: float
    house_take_bps: float  # of initial POL TVL (USD)
    pol_pnl_vs_bench_usd: float
    protocol_rev_usd: float
    fees_total_usd: float
    fees_base_usd: float
    fees_surcharge_usd: float
    redeem_vol_wsg: float
    mint_vol_wsg: float
    searcher_pnl_usd: float
    ratchets: int
    lag_p50_bars: float  # bars from a nav ratchet to the first subsequent redeem fill
    band_p50_ppm: float
    band_p95_ppm: float
    arb_fills: int
    breach_bars: int
    organic_fee_usd: float
    conveyor_dead: bool = False  # stamped by the sweep vs the static5 control


def fee_fn_for(cfg: RunConfig):
    if cfg.kind == "dynamic":
        return lambda mint, d: feemath.swap_fee(mint, d, cfg.params)
    if cfg.kind == "static5":  # the LIVE pool's tier — the acceptance-anchor control
        return lambda mint, d: 500
    if cfg.kind == "static30":
        return lambda mint, d: 3000
    raise ValueError(cfg.kind)


def label_for(cfg: RunConfig) -> str:
    if cfg.kind == "dynamic":
        p = cfg.params
        return (
            f"bases=({p.base_fee_mint_side / 100:g},{p.base_fee_redeem_side / 100:g})bps "
            f"thr={p.deviation_threshold_ppm} slope={p.toxicity_slope_ppm / PPM:g}x "
            f"cap={p.surcharge_cap_ppm / 100:g}bps"
        )
    return {"static5": "baseline: static 5bps (live pool)", "static30": "baseline: static 30bps"}[cfg.kind]


def run(cable: CableFair, cfg: RunConfig, costs: CableCosts) -> RunResult:
    rng = random.Random(cfg.seed)
    fair0 = cable.fair_true(0)
    unit_value = Pool.make(fair0, 1.0, cfg.range_width).value_wsg(fair0)
    pool = Pool.make(fair0, cfg.pol_tvl_wsg / unit_value, cfg.range_width)

    fee_fn = fee_fn_for(cfg)
    arb = CableArb(costs, fee_fn)
    organic = OrganicFlow(rng, cfg.organic_per_hour / 60.0, cfg.organic_median_wsg)

    v0_usd = pool.value_wsg(fair0) / fair0
    bench = v0_usd
    prev_fair = fair0
    abs_dev_samples: list[int] = []
    protocol_rev = 0.0
    lags: list[int] = []
    pending_ratchet_i: int | None = None
    ratchet_set = set(cable.ratchet_indices)

    n = len(cable)
    for i in range(n):
        fair_t = cable.fair_true(i)
        fair_o = cable.fair_oracle(i)
        # Continuously-rebalanced 50/50 benchmark in USD: wstGBP's USD price is 1/fair.
        bench *= 0.5 * (prev_fair / fair_t) + 0.5
        prev_fair = fair_t

        if i in ratchet_set:
            pending_ratchet_i = i

        organic.step(pool, fair_o, fee_fn)
        fill = arb.step(pool, fair_t, fair_o)
        if fill is not None:
            # Protocol band revenue at fill-time prices (1/fair = USD per wstGBP at NAV).
            protocol_rev += fill.redeem_notional_wsg * (1.0 / fair_t) * costs.burn_haircut_bps / 1e4
            protocol_rev += fill.mint_notional_wsg * (1.0 / fair_t) * costs.mint_premium_bps / 1e4
            if fill.side == "redeem" and pending_ratchet_i is not None:
                lags.append(i - pending_ratchet_i)
                pending_ratchet_i = None

        if not pool.in_range():
            pool.breach_bars += 1
        if i % 10 == 0:
            abs_dev_samples.append(abs(feemath.deviation_ppm(pool.price, fair_t)))

    fair_end = cable.fair_true(n - 1)
    usd_per_wsg_end = 1.0 / fair_end
    # Upstream-mint term: net-redeemed inventory was minted at some point (the LP seeded
    # it via the wrapper) — credit its mint leg once, at end price.
    net_redeemed = max(0.0, arb.redeem_notional_total - arb.mint_notional_total)
    protocol_rev += net_redeemed * usd_per_wsg_end * costs.mint_premium_bps / 1e4

    # Pool fee accounting: fees_weth is the x-token (USDC) fee bucket, fees_wsg the
    # y-token (wstGBP) bucket — value both in USD.
    fees_total = pool.fees_weth + pool.fees_wsg * usd_per_wsg_end
    fees_base = pool.fees_weth_base + pool.fees_wsg_base * usd_per_wsg_end
    pol_value = pool.value_wsg(fair_end) / fair_end

    abs_dev_samples.sort()
    p50 = abs_dev_samples[len(abs_dev_samples) // 2] if abs_dev_samples else 0
    p95 = abs_dev_samples[int(len(abs_dev_samples) * 0.95)] if abs_dev_samples else 0
    lags.sort()
    lag_p50 = lags[len(lags) // 2] if lags else float("nan")

    pol_pnl = pol_value - bench
    house = pol_pnl + protocol_rev
    return RunResult(
        label=label_for(cfg),
        house_take_usd=house,
        house_take_bps=house / v0_usd * 1e4,
        pol_pnl_vs_bench_usd=pol_pnl,
        protocol_rev_usd=protocol_rev,
        fees_total_usd=fees_total,
        fees_base_usd=fees_base,
        fees_surcharge_usd=fees_total - fees_base,
        redeem_vol_wsg=arb.redeem_notional_total,
        mint_vol_wsg=arb.mint_notional_total,
        searcher_pnl_usd=arb.total_profit_usd,
        ratchets=len(cable.ratchet_indices),
        lag_p50_bars=lag_p50,
        band_p50_ppm=p50,
        band_p95_ppm=p95,
        arb_fills=arb.fills,
        breach_bars=pool.breach_bars,
        organic_fee_usd=organic.fee_paid_wsg * usd_per_wsg_end,
    )
