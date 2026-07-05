import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim import feemath  # noqa: E402
from wethsim.pool import Pool  # noqa: E402
from cablesim.agents import CableArb  # noqa: E402
from cablesim.costs import CableCosts  # noqa: E402

FAIR = 1.0 / (1.25 * 1.05)  # wstGBP per USDC
STATIC5 = lambda mint, d: 500  # noqa: E731


def _pool(displaced_ppm: int, tvl_wsg: float = 250_000.0) -> Pool:
    price = FAIR * (1 + displaced_ppm / 1e6)
    unit = Pool.make(price, 1.0, 1.10).value_wsg(price)
    return Pool.make(price, tvl_wsg / unit, 1.10)


def _cheap_gas() -> CableCosts:
    return CableCosts(gas_gwei=0.01, eth_usd=3000.0)  # ~$0.001/bundle


def test_redeem_side_fills_and_stops_at_full_loop_breakeven():
    # Pool displaced +30bps (wstGBP cheap — post-ratchet geometry): redeem-side only.
    # The no-loss stop is the FULL-LOOP breakeven: half-band 1250 + stable leg 500 +
    # fee 500 = ~2250 ppm — NOT bare fair (the arb's exit is the wrapper, not the pool).
    pool = _pool(3000)
    arb = CableArb(_cheap_gas(), STATIC5)
    fill = arb.step(pool, FAIR, FAIR)
    assert fill is not None and fill.side == "redeem"
    assert fill.redeem_notional_wsg > 0 and fill.mint_notional_wsg == 0
    d_after = feemath.deviation_ppm(pool.price, FAIR)
    assert 2100 <= d_after <= 2400, d_after  # breakeven +- search slack

    # No further edge at this deviation: the next step declines.
    assert arb.step(pool, FAIR, FAIR) is None

    # Below breakeven (a single 9bps ratchet from rest-at-fair): NO fill — this is the
    # ramp-up behavior the acceptance suite documents.
    shallow = _pool(900)
    assert CableArb(_cheap_gas(), STATIC5).step(shallow, FAIR, FAIR) is None


def test_mint_side_mirrors_below_fair():
    pool = _pool(-3000)  # wstGBP rich: mint + sell
    arb = CableArb(_cheap_gas(), STATIC5)
    fill = arb.step(pool, FAIR, FAIR)
    assert fill is not None and fill.side == "mint"
    assert fill.mint_notional_wsg > 0 and fill.redeem_notional_wsg == 0
    d_after = feemath.deviation_ppm(pool.price, FAIR)
    assert -2400 <= d_after <= -2100

    assert arb.step(pool, FAIR, FAIR) is None


def test_gas_kills_participation():
    # Same +30bps displacement, but gas dwarfs the edge on this pool depth: no fill.
    pool = _pool(3000, tvl_wsg=25_000.0)
    costly = CableCosts(gas_gwei=200.0, eth_usd=3000.0)  # ~$210/bundle
    arb = CableArb(costly, STATIC5)
    assert arb.step(pool, FAIR, FAIR) is None
    assert arb.fills == 0


def test_fee_charged_at_oracle_deviation_profit_at_true():
    # Oracle lags: committed fair says d is inside a high-fee regime while true fair has
    # moved on. The fee must come from the ORACLE deviation.
    pool = _pool(3000)
    seen_fees = []

    def spy_fee(mint, d):
        seen_fees.append((mint, d))
        return 500

    arb = CableArb(_cheap_gas(), spy_fee)
    fair_oracle = FAIR * (1 - 0.0010)  # oracle fair 10bps below true
    pre_price = pool.price
    fill = arb.step(pool, FAIR, fair_oracle)
    assert fill is not None
    # seen_fees ends with (base-fee probe at d=0, preceded by the executed swap's call):
    # the executed swap priced at the PRE-swap pool price vs ORACLE fair — ~10bps more
    # deviation than the same price vs true fair.
    executed_calls = [d for mint, d in seen_fees if not mint and d != 0]
    d_used = executed_calls[-1]
    assert d_used == feemath.deviation_ppm(pre_price, fair_oracle)
    assert d_used > feemath.deviation_ppm(pre_price, FAIR)
