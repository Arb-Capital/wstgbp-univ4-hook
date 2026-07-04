# WETH/wstGBP replay simulation (spec Phase 5)

Offline sweep of the dynamic-fee hook's `FeeParams` over historical ETH/GBP paths, to pick
launch parameters. Pure-Python (stdlib only — no requirements to install; pytest to run
the tests).

## Model

- **Pool** (`wethsim/pool.py`): one static concentrated-liquidity range (±75% geometric,
  the POL policy) — *exact* in-range Uniswap math on virtual reserves; range edges clamp
  fills and are counted as breach bars. POL 1,000,000 wstGBP.
- **Fee** (`wethsim/feemath.py`): integer-ppm port of `src/weth/lib/FeeMath.sol`,
  cross-pinned by `tests/feemath_vectors.json` ⇄ `test_sharedSimVectors` (Solidity).
- **Arb agent** (`wethsim/agents.py`): trades when the first-unit edge beats
  fee + 25 bps redeem leg (redeem side only) + 5 bps stable leg + regime gas; sizes by
  golden-section on the concave profit. Mirrors the two loops of the spec's directional
  convention.
- **Organic flow**: Poisson 6/hr, lognormal median 2,000 wstGBP, 50/50 direction.
- **Fair**: bar close ÷ deterministic NAV drift (4% APY).
- **Baselines** (`wethsim/runner.py`): static 30 bps V2-style; Curve-Twocrypto
  approximation = flat 26 bps with 50% of fee revenue haircut from POL PnL (the spec's
  crude leakage proxy).

## Run

```bash
sim/data/fetch_binance.sh   # once; see sim/data/README.md
make sim-test               # pytest: fee-vector cross-pin + exact pool-math vectors
make sim-sweep              # full grid -> sim/RESULTS.md (~minutes, multiprocess)
```

Grid: `toxicitySlope ∈ {0, 0.25, 0.5, 1.0}` × base pairs `{(30,5), (25,10), (20,5)}` bps
+ 2 baselines, × regimes `{trend-2021, chop-2024}`. Output table columns and the
cross-regime robustness ranking are described in `RESULTS.md` itself.

## Interpretation notes

- POL PnL is measured against a continuously-rebalanced 50/50 benchmark, in wstGBP terms.
- The sim charges each swap the fee at its **pre-swap** deviation. Sophisticated searchers
  split (see `SECURITY_WETH_WSTGBP.md` §1), so surcharge revenue realized here from the
  arb agent's few large fills is an upper bound; treat slope conclusions directionally and
  prefer robust-rank over single-regime winners.
