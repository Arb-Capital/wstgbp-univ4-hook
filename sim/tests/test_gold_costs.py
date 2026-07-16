import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from goldsim.costs import GoldCosts  # noqa: E402


def test_gas_usd():
    c = GoldCosts(gas_units=450_000, gas_gwei=2.0, eth_usd=3000.0)
    assert c.gas_usd() == pytest.approx(450_000 * 2.0 * 1e-9 * 3000.0)  # $2.70/bundle


def test_wrapper_band_legs_take_explicit_usd_per_wsg():
    # usd_per_wsg = gbpusd * nav — NOT 1/fair (the quote token here is gold, not $1).
    c = GoldCosts()
    usd_per_wsg = 1.25 * 1.05
    assert c.mint_cost_usd(usd_per_wsg) == pytest.approx(usd_per_wsg * (1 + 12.5 / 1e4))
    assert c.burn_value_usd(usd_per_wsg) == pytest.approx(usd_per_wsg * (1 - 12.5 / 1e4))
    # 25 bps total protocol spread between the two legs.
    spread = c.mint_cost_usd(usd_per_wsg) - c.burn_value_usd(usd_per_wsg)
    assert spread == pytest.approx(usd_per_wsg * 25 / 1e4)


def test_cross_leg_is_wider_than_cablesims_stable_leg():
    # tGBP <-> XAUT recycles through TWO hops (stable adapter + XAUt/USDC pool); the
    # default must reflect that (cablesim's single stable hop was 5 bps).
    assert GoldCosts().cross_leg_bps > 5.0
