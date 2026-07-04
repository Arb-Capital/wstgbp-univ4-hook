"""Flow agents: the arbitrageur (informed) and organic (uninformed) flow.

The arb agent implements the two loops from the plan's directional convention:
- d > 0 (pool prices WETH rich): sell WETH into the pool, redeem the wstGBP received at
  the wrapper's 25 bps haircut ("redeem side").
- d < 0 (WETH cheap): mint wstGBP free at NAV, sell it into the pool for WETH
  ("mint side").
Profit is valued in wstGBP (~GBP) terms at fair; the agent trades when max profit > 0 and
sizes by golden-section search (profit is concave: linear edge vs convex impact).
"""

from dataclasses import dataclass
import math
import random

from . import feemath
from .pool import Pool, SwapResult
from .costs import Costs

PPM = 1_000_000


@dataclass
class ArbFill:
    side: str  # "redeem" (WETH in) or "mint" (wstGBP in)
    result: SwapResult
    profit_wsg: float
    redeem_notional_wsg: float  # wstGBP redeemed at the wrapper (25 bps revenue base)


class ArbAgent:
    def __init__(self, costs: Costs, fee_fn):
        self.costs = costs
        self.fee_fn = fee_fn  # (is_mint_side, deviation_ppm) -> fee_ppm
        self.total_profit_wsg = 0.0
        self.redeem_notional_total = 0.0
        self.fills = 0
        self.cycles = 0
        self._last_side = None

    # profit of a candidate size, WITHOUT mutating the pool
    def _profit(self, pool: Pool, fair: float, side: str, amount_in: float) -> float:
        if amount_in <= 0:
            return 0.0
        trial = Pool(
            liquidity=pool.liquidity,
            sqrt_price=pool.sqrt_price,
            sqrt_lower=pool.sqrt_lower,
            sqrt_upper=pool.sqrt_upper,
        )
        d = feemath.deviation_ppm(trial.price, fair)
        if side == "redeem":
            fee_ppm = self.fee_fn(False, d)
            r = trial.swap_weth_in(amount_in, fee_ppm, 0)
            # wstGBP out -> redeem at 25 bps haircut; WETH in valued at fair.
            gross = r.amount_out * (1 - self.costs.redeem_bps / 1e4) - r.amount_in * fair
        else:
            fee_ppm = self.fee_fn(True, d)
            r = trial.swap_wsg_in(amount_in, fee_ppm, 0)
            # wstGBP minted at par (free mint); WETH received valued at fair.
            gross = r.amount_out * fair - r.amount_in
        stable_leg = self.costs.stable_leg_bps / 1e4 * (
            r.amount_in * (fair if side == "redeem" else 1.0)
        )
        return gross - stable_leg - self.costs.gas_wsg(fair)

    def _best_size(self, pool: Pool, fair: float, side: str, hi: float) -> tuple[float, float]:
        """Golden-section max of the concave profit on [0, hi]."""
        if hi <= 0:
            return 0.0, 0.0
        lo = 0.0
        inv_phi = (math.sqrt(5) - 1) / 2
        a, b = hi - inv_phi * hi, inv_phi * hi
        fa, fb = self._profit(pool, fair, side, a), self._profit(pool, fair, side, b)
        for _ in range(40):
            if fa < fb:
                lo, a, fa = a, b, fb
                b = lo + inv_phi * (hi - lo)
                fb = self._profit(pool, fair, side, b)
            else:
                hi, b, fb = b, a, fa
                a = lo + (1 - inv_phi) * (hi - lo)
                fa = self._profit(pool, fair, side, a)
        x = (a + b) / 2
        return x, self._profit(pool, fair, side, x)

    def step(self, pool: Pool, fair: float) -> ArbFill | None:
        d = feemath.deviation_ppm(pool.price, fair)
        if d > 0:
            side = "redeem"
            # never push past fair: cap at the size that reaches it (gross of fee headroom x2)
            hi = pool.weth_in_to_reach(fair) * 2.0
        elif d < 0:
            side = "mint"
            hi = pool.wsg_in_to_reach(fair) * 2.0
        else:
            return None

        # Cheap viability precheck: the FIRST unit has the best edge (fee slope < 1 keeps
        # d - fee(d) increasing in d), so if it can't beat the proportional haircuts no size can.
        fee0 = self.fee_fn(side == "mint", d)
        haircuts_ppm = fee0 + self.costs.stable_leg_bps * 100
        if side == "redeem":
            haircuts_ppm += self.costs.redeem_bps * 100
        if abs(d) <= haircuts_ppm:
            return None

        size, profit = self._best_size(pool, fair, side, hi)
        if profit <= 0 or size <= 0:
            return None

        d = feemath.deviation_ppm(pool.price, fair)
        if side == "redeem":
            fee_ppm = self.fee_fn(False, d)
            base = self.fee_fn(False, 0)
            r = pool.swap_weth_in(size, fee_ppm, base)
            redeem_notional = r.amount_out
        else:
            fee_ppm = self.fee_fn(True, d)
            base = self.fee_fn(True, 0)
            r = pool.swap_wsg_in(size, fee_ppm, base)
            redeem_notional = 0.0

        self.total_profit_wsg += profit
        self.redeem_notional_total += redeem_notional
        self.fills += 1
        if self._last_side is not None and self._last_side != side:
            self.cycles += 1
        self._last_side = side
        return ArbFill(side, r, profit, redeem_notional)


class OrganicFlow:
    """Poisson arrivals, lognormal size, 50/50 direction. Sizes in wstGBP notional."""

    def __init__(self, rng: random.Random, per_bar: float, median_wsg: float, sigma: float = 1.0):
        self.rng = rng
        self.per_bar = per_bar
        self.median_wsg = median_wsg
        self.sigma = sigma
        self.fee_paid_wsg = 0.0

    def step(self, pool: Pool, fair: float, fee_fn) -> None:
        n = self._poisson()
        for _ in range(n):
            notional = self.median_wsg * math.exp(self.rng.gauss(0, self.sigma))
            d = feemath.deviation_ppm(pool.price, fair)
            if self.rng.random() < 0.5:
                fee_ppm = fee_fn(True, d)
                r = pool.swap_wsg_in(notional, fee_ppm, fee_fn(True, 0))
                self.fee_paid_wsg += r.fee_paid
            else:
                weth_in = notional / pool.price
                fee_ppm = fee_fn(False, d)
                r = pool.swap_weth_in(weth_in, fee_ppm, fee_fn(False, 0))
                self.fee_paid_wsg += r.fee_paid * fair

    def _poisson(self) -> int:
        lam = self.per_bar
        l_exp, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.rng.random()
            if p <= l_exp:
                return k
            k += 1
