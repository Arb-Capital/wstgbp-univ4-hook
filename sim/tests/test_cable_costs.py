import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from cablesim.costs import CableCosts  # noqa: E402


def test_band_is_exactly_25bps_wide():
    c = CableCosts()
    fair = 1.0 / (1.27 * 1.05)  # wstGBP per USDC at cable 1.27, NAV 1.05
    mint = c.mint_cost_usd(fair)
    burn = c.burn_value_usd(fair)
    nav_usd = 1.0 / fair
    assert abs(mint / nav_usd - 1.00125) < 1e-12  # +12.5 bps
    assert abs(burn / nav_usd - 0.99875) < 1e-12  # -12.5 bps
    assert abs((mint - burn) / nav_usd - 0.0025) < 1e-12  # 25 bps total spread
    # A gross round trip through the wrapper never profits: mint cost > burn value.
    assert mint > burn


def test_gas_usd():
    c = CableCosts(gas_units=350_000, gas_gwei=10.0, eth_usd=1300.0)
    assert abs(c.gas_usd() - 350_000 * 10 * 1e-9 * 1300) < 1e-12  # $4.55
