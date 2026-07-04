import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from wethsim import feemath  # noqa: E402


def test_shared_vectors():
    path = pathlib.Path(__file__).parent / "feemath_vectors.json"
    vectors = json.loads(path.read_text())["vectors"]
    assert len(vectors) >= 20
    for v in vectors:
        p = feemath.FeeParams(**v["params"])
        got = feemath.swap_fee(v["mint"], v["d"], p)
        assert got == v["fee"], f"vector {v}: got {got}"


def test_fee_always_within_bounds():
    p = feemath.FeeParams()
    for d in [-(10**30), -123456, -1001, -1000, -1, 0, 1, 999, 1000, 1001, 654321, 10**30]:
        for mint in (True, False):
            fee = feemath.swap_fee(mint, d, p)
            assert p.min_fee <= fee <= p.max_fee


def test_deviation_sign_convention():
    # d > 0: pool prices WETH rich (more wstGBP per WETH than fair)
    assert feemath.deviation_ppm(2020.0, 2000.0) == 10_000
    assert feemath.deviation_ppm(1980.0, 2000.0) == -10_000
