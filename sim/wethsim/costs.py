"""Arb all-in cost model: pool fee is charged by the pool itself; this holds the rest.

- redeem_bps: the wrapper's structural redeem haircut (25 bps), redeem-side loops only.
- stable_leg_bps: recycling tGBP <-> USD <-> ETH inventory (both loops).
- gas: per-bundle units x regime gwei x ETH price, converted to wstGBP terms at fair.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Costs:
    redeem_bps: float = 25.0
    stable_leg_bps: float = 5.0
    gas_units: int = 350_000
    gas_gwei: float = 8.0

    def gas_wsg(self, fair_wsg_per_weth: float) -> float:
        gas_eth = self.gas_units * self.gas_gwei * 1e-9
        return gas_eth * fair_wsg_per_weth
