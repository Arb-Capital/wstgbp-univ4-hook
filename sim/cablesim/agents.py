"""Flow agents for the USDC venue: the conveyor arbitrageur (informed) plus wethsim's
OrganicFlow (uninformed), reused unchanged.

Pool mapping (wethsim.pool is venue-neutral exact CL math; x = base, y = quote,
P = quote-per-base): here **x = USDC, y = wstGBP, P = wstGBP per USDC** — identical sign
structure to the contract: d = pool/fair - 1; d > 0 (USDC rich / wstGBP cheap, the
post-ratchet state) is closed by selling USDC (`swap_weth_in` = x-in, redeem side);
d < 0 by selling wstGBP (`swap_wsg_in` = y-in, mint side).

The two loops:
- redeem loop (d > 0): buy wstGBP with USDC in the pool, redeem at burncost
  (nav*(1-12.5bps)), recycle tGBP -> USDC at the stable-leg haircut.
- mint loop (d < 0): USDC -> tGBP (stable leg), mint at mintcost (nav*(1+12.5bps)),
  sell the wstGBP into the pool for USDC.

Fee charged at ORACLE deviation (the hook prices off Chainlink); profit real at TRUE
fair; sizes by golden-section (concave: linear edge vs convex impact), with the upper
bracket at the wrapper BAND EDGE (not fair — the arb's no-loss target is the edge).
Everything is USD(C)-denominated: on this venue the numeraire is the dollar.
"""

from dataclasses import dataclass
import math

from wethsim import feemath
from wethsim.agents import OrganicFlow  # noqa: F401  (re-exported for the runner)
from wethsim.pool import Pool, SwapResult

from .costs import CableCosts

PPM = 1_000_000


@dataclass
class ArbFill:
    side: str  # "redeem" (USDC in) or "mint" (wstGBP in)
    result: SwapResult
    profit_usd: float
    redeem_notional_wsg: float  # wstGBP redeemed at the wrapper this fill
    mint_notional_wsg: float  # wstGBP minted at the wrapper this fill


class CableArb:
    def __init__(self, costs: CableCosts, fee_fn):
        self.costs = costs
        self.fee_fn = fee_fn  # (is_mint_side, deviation_ppm) -> fee_ppm
        self.total_profit_usd = 0.0
        self.redeem_notional_total = 0.0
        self.mint_notional_total = 0.0
        self.fills = 0
        self.cycles = 0
        self._last_side = None

    # profit of a candidate size in USD, WITHOUT mutating the pool
    def _profit(self, pool: Pool, fair_true: float, fair_oracle: float, side: str, amount_in: float) -> float:
        if amount_in <= 0:
            return 0.0
        trial = Pool(
            liquidity=pool.liquidity,
            sqrt_price=pool.sqrt_price,
            sqrt_lower=pool.sqrt_lower,
            sqrt_upper=pool.sqrt_upper,
        )
        d = feemath.deviation_ppm(trial.price, fair_oracle)
        sl = 1 - self.costs.stable_leg_bps / 1e4
        if side == "redeem":
            fee_ppm = self.fee_fn(False, d)
            r = trial.swap_weth_in(amount_in, fee_ppm, 0)  # USDC in, wstGBP out
            gross = r.amount_out * self.costs.burn_value_usd(fair_true) * sl - r.amount_in
        else:
            fee_ppm = self.fee_fn(True, d)
            r = trial.swap_wsg_in(amount_in, fee_ppm, 0)  # wstGBP in, USDC out
            gross = r.amount_out - r.amount_in * self.costs.mint_cost_usd(fair_true) / sl
        return gross - self.costs.gas_usd()

    def _best_size(self, pool: Pool, fair_true: float, fair_oracle: float, side: str, hi: float) -> tuple[float, float]:
        """Golden-section max of the concave profit on [0, hi]."""
        if hi <= 0:
            return 0.0, 0.0
        lo = 0.0
        inv_phi = (math.sqrt(5) - 1) / 2
        a, b = hi - inv_phi * hi, inv_phi * hi
        fa = self._profit(pool, fair_true, fair_oracle, side, a)
        fb = self._profit(pool, fair_true, fair_oracle, side, b)
        for _ in range(40):
            if fa < fb:
                lo, a, fa = a, b, fb
                b = lo + inv_phi * (hi - lo)
                fb = self._profit(pool, fair_true, fair_oracle, side, b)
            else:
                hi, b, fb = b, a, fa
                a = lo + (1 - inv_phi) * (hi - lo)
                fa = self._profit(pool, fair_true, fair_oracle, side, a)
        x = (a + b) / 2
        return x, self._profit(pool, fair_true, fair_oracle, side, x)

    def step(self, pool: Pool, fair_true: float, fair_oracle: float) -> ArbFill | None:
        d_true = feemath.deviation_ppm(pool.price, fair_true)
        hb = self.costs.burn_haircut_bps * 100  # ppm
        mp = self.costs.mint_premium_bps * 100
        sl = self.costs.stable_leg_bps * 100
        if d_true > 0:
            side = "redeem"
            # No-loss target: P where marginal USDC buys exactly break even through redeem,
            # i.e. P_target = fair/((1-hb)(1-sl)) ~ fair*(1+hb+sl) — the BAND EDGE + leg,
            # not fair. x2 fee/gas headroom on the bracket.
            target = fair_true / ((1 - hb / 1e6) * (1 - sl / 1e6))
            hi = pool.weth_in_to_reach(target) * 2.0
        elif d_true < 0:
            side = "mint"
            target = fair_true / ((1 + mp / 1e6) * (1 + sl / 1e6))
            hi = pool.wsg_in_to_reach(target) * 2.0
        else:
            return None

        # Cheap viability precheck against the FULL loop haircut (band leg + stable leg +
        # the fee at the current ORACLE deviation): the first unit has the best edge.
        d_oracle = feemath.deviation_ppm(pool.price, fair_oracle)
        fee0 = self.fee_fn(side == "mint", d_oracle)
        haircuts_ppm = fee0 + sl + (hb if side == "redeem" else mp)
        if abs(d_true) <= haircuts_ppm:
            return None

        size, profit = self._best_size(pool, fair_true, fair_oracle, side, hi)
        if profit <= 0 or size <= 0:
            return None

        d_oracle = feemath.deviation_ppm(pool.price, fair_oracle)
        if side == "redeem":
            fee_ppm = self.fee_fn(False, d_oracle)
            base = self.fee_fn(False, 0)
            r = pool.swap_weth_in(size, fee_ppm, base)
            redeem_notional, mint_notional = r.amount_out, 0.0
        else:
            fee_ppm = self.fee_fn(True, d_oracle)
            base = self.fee_fn(True, 0)
            r = pool.swap_wsg_in(size, fee_ppm, base)
            redeem_notional, mint_notional = 0.0, r.amount_in

        self.total_profit_usd += profit
        self.redeem_notional_total += redeem_notional
        self.mint_notional_total += mint_notional
        self.fills += 1
        if self._last_side is not None and self._last_side != side:
            self.cycles += 1
        self._last_side = side
        return ArbFill(side, r, profit, redeem_notional, mint_notional)
