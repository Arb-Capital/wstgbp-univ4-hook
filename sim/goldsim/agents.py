"""Flow agents for the XAUT venue: the conveyor arbitrageur (informed) plus wethsim's
OrganicFlow (uninformed), reused unchanged.

Pool mapping (wethsim.pool is venue-neutral exact CL math; x = base, y = quote,
P = quote-per-base): here **x = XAUT, y = wstGBP, P = wstGBP per XAUT** — identical sign
structure to the contract: d = pool/fair - 1; d > 0 (XAUT rich / wstGBP cheap, the
post-ratchet state) is closed by selling XAUT (`swap_weth_in` = x-in, redeem side);
d < 0 by selling wstGBP (`swap_wsg_in` = y-in, mint side).

The two loops:
- redeem loop (d > 0): buy wstGBP with XAUT in the pool, redeem at burncost
  (nav*(1-12.5bps)), recycle tGBP -> XAUT through the cross leg.
- mint loop (d < 0): XAUT -> tGBP (cross leg), mint at mintcost (nav*(1+12.5bps)),
  sell the wstGBP into the pool for XAUT.

Fee charged at ORACLE deviation (the hook prices off the metal feed — at the basis rest
state that is ≈ -basis even when the pool sits exactly at token-market fair); profit real
at TRUE (token-market) fair; sizes by golden-section with the upper bracket at the
wrapper BAND EDGE. The band-edge targets are the same formulas as cablesim because
`fair_true` is already token-market: P*_redeem = fair/((1-hb)(1-cl)),
P*_mint = fair/((1+mp)(1+cl)).

Numeraire: USD, via the EXPLICIT legs (usd_per_wsg = gbpusd*nav for wstGBP,
usd_per_xaut = xau*(1-basis) for XAUT) — the structural difference vs cablesim, where
amount_in of the quote token was already dollars.
"""

from dataclasses import dataclass
import math

from wethsim import feemath
from wethsim.agents import OrganicFlow  # noqa: F401  (re-exported for the runner)
from wethsim.pool import Pool, SwapResult

from .costs import GoldCosts

PPM = 1_000_000


@dataclass
class ArbFill:
    side: str  # "redeem" (XAUT in) or "mint" (wstGBP in)
    result: SwapResult
    profit_usd: float
    redeem_notional_wsg: float  # wstGBP redeemed at the wrapper this fill
    mint_notional_wsg: float  # wstGBP minted at the wrapper this fill


class GoldArb:
    def __init__(self, costs: GoldCosts, fee_fn):
        self.costs = costs
        self.fee_fn = fee_fn  # (is_mint_side, deviation_ppm) -> fee_ppm
        self.total_profit_usd = 0.0
        self.redeem_notional_total = 0.0
        self.mint_notional_total = 0.0
        self.fills = 0
        self.cycles = 0
        self._last_side = None

    # profit of a candidate size in USD, WITHOUT mutating the pool
    def _profit(
        self,
        pool: Pool,
        fair_oracle: float,
        usd_per_wsg: float,
        usd_per_xaut: float,
        side: str,
        amount_in: float,
    ) -> float:
        if amount_in <= 0:
            return 0.0
        trial = Pool(
            liquidity=pool.liquidity,
            sqrt_price=pool.sqrt_price,
            sqrt_lower=pool.sqrt_lower,
            sqrt_upper=pool.sqrt_upper,
        )
        d = feemath.deviation_ppm(trial.price, fair_oracle)
        cl = 1 - self.costs.cross_leg_bps / 1e4
        if side == "redeem":
            fee_ppm = self.fee_fn(False, d)
            r = trial.swap_weth_in(amount_in, fee_ppm, 0)  # XAUT in, wstGBP out
            gross = r.amount_out * self.costs.burn_value_usd(usd_per_wsg) * cl - r.amount_in * usd_per_xaut
        else:
            fee_ppm = self.fee_fn(True, d)
            r = trial.swap_wsg_in(amount_in, fee_ppm, 0)  # wstGBP in, XAUT out
            gross = r.amount_out * usd_per_xaut - r.amount_in * self.costs.mint_cost_usd(usd_per_wsg) / cl
        return gross - self.costs.gas_usd()

    def _best_size(
        self,
        pool: Pool,
        fair_oracle: float,
        usd_per_wsg: float,
        usd_per_xaut: float,
        side: str,
        hi: float,
    ) -> tuple[float, float]:
        """Golden-section max of the concave profit on [0, hi]."""
        if hi <= 0:
            return 0.0, 0.0
        lo = 0.0
        inv_phi = (math.sqrt(5) - 1) / 2
        a, b = hi - inv_phi * hi, inv_phi * hi
        fa = self._profit(pool, fair_oracle, usd_per_wsg, usd_per_xaut, side, a)
        fb = self._profit(pool, fair_oracle, usd_per_wsg, usd_per_xaut, side, b)
        for _ in range(40):
            if fa < fb:
                lo, a, fa = a, b, fb
                b = lo + inv_phi * (hi - lo)
                fb = self._profit(pool, fair_oracle, usd_per_wsg, usd_per_xaut, side, b)
            else:
                hi, b, fb = b, a, fa
                a = lo + (1 - inv_phi) * (hi - lo)
                fa = self._profit(pool, fair_oracle, usd_per_wsg, usd_per_xaut, side, a)
        x = (a + b) / 2
        return x, self._profit(pool, fair_oracle, usd_per_wsg, usd_per_xaut, side, x)

    def step(
        self,
        pool: Pool,
        fair_true: float,
        fair_oracle: float,
        usd_per_wsg: float,
        usd_per_xaut: float,
    ) -> ArbFill | None:
        d_true = feemath.deviation_ppm(pool.price, fair_true)
        hb = self.costs.burn_haircut_bps * 100  # ppm
        mp = self.costs.mint_premium_bps * 100
        cl = self.costs.cross_leg_bps * 100
        if d_true > 0:
            side = "redeem"
            # No-loss target: P where marginal XAUT buys exactly break even through redeem
            # + recycle, i.e. P_target = fair/((1-hb)(1-cl)) — the BAND EDGE + leg, not
            # fair (fair_true is token-market, so the same formula as cablesim). x2
            # fee/gas headroom on the bracket.
            target = fair_true / ((1 - hb / 1e6) * (1 - cl / 1e6))
            hi = pool.weth_in_to_reach(target) * 2.0
        elif d_true < 0:
            side = "mint"
            target = fair_true / ((1 + mp / 1e6) * (1 + cl / 1e6))
            hi = pool.wsg_in_to_reach(target) * 2.0
        else:
            return None

        # Cheap viability precheck against the FULL loop haircut (band leg + cross leg +
        # the fee at the current ORACLE deviation): the first unit has the best edge.
        d_oracle = feemath.deviation_ppm(pool.price, fair_oracle)
        fee0 = self.fee_fn(side == "mint", d_oracle)
        haircuts_ppm = fee0 + cl + (hb if side == "redeem" else mp)
        if abs(d_true) <= haircuts_ppm:
            return None

        size, profit = self._best_size(pool, fair_oracle, usd_per_wsg, usd_per_xaut, side, hi)
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
