"""Arb all-in cost model for the XAUT venue: pool fee is charged by the pool itself;
this holds the wrapper band, the tGBP<->XAUT recycling legs, and gas.

The wrapper band is modeled as on the USDC venue: mint at nav*(1 + mint_premium), redeem
at nav*(1 - burn_haircut), 12.5 bps each side (the 25 bps total spread is PROTOCOL
revenue, counted by the house-take objective, not a deadweight cost).

The recycling leg is LONGER here than cablesim's single stable hop: tGBP <-> XAUT routes
tGBP <-> USDC (adapter/aggregator, ~5 bps) then USDC <-> XAUt (the ~$3.6M XAUt/USDC v4
pool, ~10 bps incl. impact at conveyor notionals) — `cross_leg_bps` bundles both, and the
extra swap also shows up in `gas_units` (450k vs the USDC venue's 350k bundle).

Gas: per-bundle units x gwei x ETH price in USD (USD numeraire; gwei and eth_usd are
regime knobs — conveyor-notional arb is gas-sensitive, see the sensitivity section of
RESULTS_XAUT.md).
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class GoldCosts:
    mint_premium_bps: float = 12.5
    burn_haircut_bps: float = 12.5
    cross_leg_bps: float = 15.0  # tGBP <-> XAUT recycling: stable hop + XAUt/USDC pool leg
    gas_units: int = 450_000
    gas_gwei: float = 1.0
    eth_usd: float = 3000.0

    def gas_usd(self) -> float:
        return self.gas_units * self.gas_gwei * 1e-9 * self.eth_usd

    # USD value of one wstGBP through each wrapper leg. Unlike cablesim these take the
    # explicit NAV-anchored leg (usd_per_wsg = gbpusd * nav) rather than deriving it from
    # fair — on this venue 1/fair is NOT a USD price (the quote token is gold, not $1).
    def mint_cost_usd(self, usd_per_wsg: float) -> float:
        return usd_per_wsg * (1 + self.mint_premium_bps / 1e4)

    def burn_value_usd(self, usd_per_wsg: float) -> float:
        return usd_per_wsg * (1 - self.burn_haircut_bps / 1e4)
