import math
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim.pool import Pool  # noqa: E402


def wide(price: float, L: float) -> Pool:
    return Pool.make(price, L, width=100.0)


def test_hand_computed_wsg_in_no_fee():
    # P = 4 (wsg per WETH), L = 1000: sell 100 wsg -> s: 2 -> 2.1,
    # WETH out = L*(1/2 - 1/2.1) = 23.80952...
    p = wide(4.0, 1000.0)
    r = p.swap_wsg_in(100.0, 0, 0)
    assert r.amount_out == pytest.approx(1000.0 * (1 / 2 - 1 / 2.1), rel=1e-12)
    assert p.price == pytest.approx(2.1**2, rel=1e-12)
    assert not r.partial


def test_hand_computed_weth_in_no_fee():
    # P = 4, L = 1000: sell 10 WETH -> 1/s: 0.5 -> 0.51 => s' = 1/0.51,
    # wsg out = L*(2 - 1/0.51... ) = L*(s - s') = 1000*(2 - 1.960784) = 39.2157...
    p = wide(4.0, 1000.0)
    r = p.swap_weth_in(10.0, 0, 0)
    s_new = 1000.0 * 2.0 / (1000.0 + 10.0 * 2.0)
    assert p.sqrt_price == pytest.approx(s_new, rel=1e-12)
    assert r.amount_out == pytest.approx(1000.0 * (2.0 - s_new), rel=1e-12)


def test_fee_taken_on_input():
    p0 = wide(4.0, 1000.0)
    r0 = p0.swap_wsg_in(100.0, 0, 0)
    p1 = wide(4.0, 1000.0)
    r1 = p1.swap_wsg_in(100.0, 30_000, 30_000)  # 3%
    assert r1.fee_paid == pytest.approx(3.0, rel=1e-12)
    # net input of the fee'd swap equals a no-fee swap of 97
    p2 = wide(4.0, 1000.0)
    r2 = p2.swap_wsg_in(97.0, 0, 0)
    assert r1.amount_out == pytest.approx(r2.amount_out, rel=1e-12)
    assert r0.amount_out > r1.amount_out


def test_range_edge_clamps_partial():
    p = Pool.make(4.0, 1000.0, width=1.02)  # very narrow
    r = p.swap_wsg_in(10_000.0, 0, 0)
    assert r.partial
    assert p.sqrt_price == pytest.approx(p.sqrt_upper)
    assert r.amount_in < 10_000.0
    assert not p.in_range()


def test_sizing_helpers_roundtrip():
    p = wide(4.0, 1000.0)
    dy = p.wsg_in_to_reach(4.5)
    p.swap_wsg_in(dy, 0, 0)
    assert p.price == pytest.approx(4.5, rel=1e-9)
    dx = p.weth_in_to_reach(4.0)
    p.swap_weth_in(dx, 0, 0)
    assert p.price == pytest.approx(4.0, rel=1e-9)


def test_value_and_reserves_consistent():
    p = Pool.make(2000.0, 5000.0, width=1.75)
    weth, wsg = p.reserves()
    assert weth > 0 and wsg > 0
    # at the range center the two sides are ~equal in value
    assert weth * 2000.0 == pytest.approx(wsg, rel=1e-9)
    assert p.value_wsg(2000.0) == pytest.approx(weth * 2000.0 + wsg, rel=1e-12)
