"""Single-run loop for the XAUT venue: bar -> organic flow -> conveyor arb -> record.

THE OBJECTIVE is cablesim's house take, carried over verbatim (the conveyor exists here
exactly as on the USDC venue — the NAV ratchet lowers fair in wstGBP-per-XAUT terms and
re-arms the buy-then-redeem loop): house = LP (POL) + the wstGBP protocol:

    house_take_usd = (pol_value - bench_value)                      # LP leg vs 50/50
                   + 12.5bps * (mint_vol + redeem_vol)              # per-fill, at fill price
                   + 12.5bps * max(0, redeem_vol - mint_vol)        # upstream mint of the
                                                                    # net-redeemed inventory

A parameter set that kills the conveyor kills protocol revenue: the sweep flags such
configs `conveyor-dead` and ranks them last unconditionally.

NUMERAIRE (the structural delta vs cablesim): USD, but through the explicit legs —
usd_per_wsg = gbpusd*nav and usd_per_xaut = xau*(1-basis). The 50/50 benchmark rebalances
between two RISKY assets here (gold and NAV-anchored sterling), where cablesim's quote
side was flat $1; and the pool's x-token fee bucket is valued at the gold price, not at
par. Fees at oracle deviation (metal-priced — includes the basis rest state), economics
at true (token-market) fair. Telemetry includes per-ratchet conveyor response lag.
"""

from dataclasses import dataclass
import random

from wethsim import feemath
from wethsim.pool import Pool

from .agents import GoldArb, OrganicFlow
from .bars import GoldFair
from .costs import GoldCosts

PPM = 1_000_000


@dataclass(frozen=True)
class RunConfig:
    kind: str  # "dynamic" | "static5" | "static30"
    params: feemath.FeeParams = feemath.FeeParams()
    pol_tvl_wsg: float = 250_000.0
    range_width: float = 1.50  # +-~22% geometric: gold-in-GBP ~37% ann. vol over a regime
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
    if cfg.kind == "static5":  # conveyor-viability control (no live static pool for this pair)
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
    return {"static5": "baseline: static 5bps (control)", "static30": "baseline: static 30bps"}[cfg.kind]


def run(gold: GoldFair, cfg: RunConfig, costs: GoldCosts) -> RunResult:
    rng = random.Random(cfg.seed)
    fair0 = gold.fair_true(0)
    unit_value = Pool.make(fair0, 1.0, cfg.range_width).value_wsg(fair0)
    pool = Pool.make(fair0, cfg.pol_tvl_wsg / unit_value, cfg.range_width)

    fee_fn = fee_fn_for(cfg)
    arb = GoldArb(costs, fee_fn)
    organic = OrganicFlow(rng, cfg.organic_per_hour / 60.0, cfg.organic_median_wsg)

    v0_usd = pool.value_wsg(fair0) * gold.usd_per_wsg(0)
    bench = v0_usd
    prev_wsg_usd = gold.usd_per_wsg(0)
    prev_xaut_usd = gold.usd_per_xaut(0)
    abs_dev_samples: list[int] = []
    protocol_rev = 0.0
    lags: list[int] = []
    pending_ratchet_i: int | None = None
    ratchet_set = set(gold.ratchet_indices)

    n = len(gold)
    for i in range(n):
        fair_t = gold.fair_true(i)
        fair_o = gold.fair_oracle(i)
        usd_wsg = gold.usd_per_wsg(i)
        usd_xaut = gold.usd_per_xaut(i)
        # Continuously-rebalanced 50/50 benchmark in USD — BOTH legs are risky here
        # (cablesim's quote half was flat $1.00).
        bench *= 0.5 * (usd_wsg / prev_wsg_usd) + 0.5 * (usd_xaut / prev_xaut_usd)
        prev_wsg_usd, prev_xaut_usd = usd_wsg, usd_xaut

        if i in ratchet_set:
            pending_ratchet_i = i

        organic.step(pool, fair_o, fee_fn)
        fill = arb.step(pool, fair_t, fair_o, usd_wsg, usd_xaut)
        if fill is not None:
            # Protocol band revenue at fill-time prices (usd_per_wsg = the NAV-anchored
            # USD price of one wstGBP).
            protocol_rev += fill.redeem_notional_wsg * usd_wsg * costs.burn_haircut_bps / 1e4
            protocol_rev += fill.mint_notional_wsg * usd_wsg * costs.mint_premium_bps / 1e4
            if fill.side == "redeem" and pending_ratchet_i is not None:
                lags.append(i - pending_ratchet_i)
                pending_ratchet_i = None

        if not pool.in_range():
            pool.breach_bars += 1
        if i % 10 == 0:
            abs_dev_samples.append(abs(feemath.deviation_ppm(pool.price, fair_t)))

    fair_end = gold.fair_true(n - 1)
    usd_per_wsg_end = gold.usd_per_wsg(n - 1)
    usd_per_xaut_end = gold.usd_per_xaut(n - 1)
    # Upstream-mint term: net-redeemed inventory was minted at some point (the LP seeded
    # it via the wrapper) — credit its mint leg once, at end price.
    net_redeemed = max(0.0, arb.redeem_notional_total - arb.mint_notional_total)
    protocol_rev += net_redeemed * usd_per_wsg_end * costs.mint_premium_bps / 1e4

    # Pool fee accounting: fees_weth is the x-token (XAUT) fee bucket — valued at the
    # GOLD price (cablesim valued its x bucket at $1 face) — fees_wsg the y-token
    # (wstGBP) bucket at the NAV-anchored price.
    fees_total = pool.fees_weth * usd_per_xaut_end + pool.fees_wsg * usd_per_wsg_end
    fees_base = pool.fees_weth_base * usd_per_xaut_end + pool.fees_wsg_base * usd_per_wsg_end
    pol_value = pool.value_wsg(fair_end) * usd_per_wsg_end

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
        ratchets=len(gold.ratchet_indices),
        lag_p50_bars=lag_p50,
        band_p50_ppm=p50,
        band_p95_ppm=p95,
        arb_fills=arb.fills,
        breach_bars=pool.breach_bars,
        organic_fee_usd=organic.fee_paid_wsg * usd_per_wsg_end,
    )
