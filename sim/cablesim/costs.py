"""Arb all-in cost model for the USDC venue: pool fee is charged by the pool itself;
this holds the wrapper band, the tGBP<->USDC leg, and gas.

Unlike the WETH sim's asymmetric free-mint/25bps-redeem shorthand, the real band is
modeled: mint at nav*(1 + mint_premium), redeem at nav*(1 - burn_haircut), 12.5 bps each
side (the wrapper's 25 bps total spread — which is PROTOCOL revenue, counted by the
house-take objective, not a deadweight cost).

Gas: per-bundle units x gwei x ETH price in USD (USDC numeraire; gwei and eth_usd are
regime knobs — small-notional stable-pair arb is gas-dominated, see the sensitivity
section of RESULTS_USDC.md).
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class CableCosts:
    mint_premium_bps: float = 12.5
    burn_haircut_bps: float = 12.5
    stable_leg_bps: float = 5.0  # tGBP <-> USDC recycling leg (adapter/aggregator route)
    gas_units: int = 350_000
    gas_gwei: float = 1.0
    eth_usd: float = 3000.0

    def gas_usd(self) -> float:
        return self.gas_units * self.gas_gwei * 1e-9 * self.eth_usd

    # USD(C) value of one wstGBP through each wrapper leg, given fair (wstGBP per USDC):
    # 1/fair = gbpusd * nav = the NAV-anchored USD price of one wstGBP.
    def mint_cost_usd(self, fair_true: float) -> float:
        return (1.0 / fair_true) * (1 + self.mint_premium_bps / 1e4)

    def burn_value_usd(self, fair_true: float) -> float:
        return (1.0 / fair_true) * (1 - self.burn_haircut_bps / 1e4)
