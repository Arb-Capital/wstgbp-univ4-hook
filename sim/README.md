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

---

# wstGBP/USDC (cable venue) replay simulation — `cablesim/`

Sibling package for the third venue's fee parameters. Imports wethsim's venue-neutral
core (`feemath`, `pool` — **`sim/wethsim/` itself is frozen**: it backs the deployed WETH
venue's `RESULTS.md`) and owns everything cable-specific. Pool mapping: x = USDC,
y = wstGBP, P = wstGBP per USDC (identical sign structure to the contract).

## Model deltas vs wethsim (each one is a venue decision)

- **NAV is a discrete weekly ratchet** (`cablesim/bars.py::NavStepModel`, default
  9 bps/week ≈ 4.8% APY), not smooth drift: the step IS this venue's flow driver — each
  ratchet drops fair below the pool and re-arms the buy-then-redeem conveyor.
- **Chainlink deadband modeled** (`OracleSeries`: 0.15% deviation / 24h heartbeat): the
  GBP/USD deadband EXCEEDS the wrapper's 12.5 bps half-band, so fees price off the
  committed (oracle) fair while arb profit is real at the live (true) fair.
- **Real wrapper band** (`cablesim/costs.py`): mint at +12.5 bps, redeem at −12.5 bps —
  the 25 bps spread is PROTOCOL revenue, not deadweight.
- **House-take objective** (`cablesim/runner.py`): LP PnL vs 50/50 **plus** protocol band
  revenue (12.5 bps × each wrapper leg + the net-redeemed upstream mint). Configs that
  starve the conveyor (redeem volume < 10% of the static-5 control, or searcher PnL ≤ 0)
  are flagged `conveyor-dead` and rank last unconditionally.
- **Arb sizes to the band edge** (not fair): the no-loss target is
  fair × (1 + half-band + stable leg), so from a start-at-fair pool the conveyor only
  arms once accumulated ratchets exceed ~half-band + stable + fee (≈22.5 bps at static-5).
- **Gas dominates**: conveyor notionals are small; regimes carry era-consistent
  gwei/ETH-price and `RESULTS_USDC.md` includes a gas-sensitivity table.
- Numeraire is USD(C); organic flow axis {0, 1}/hr median 500 wstGBP (0 = the observed
  reality: the live pool's flow is ~pure conveyor).

## Run

```bash
make sim-data-cable    # once: Dukascopy GBP/USD 1m bars (see sim/data/README.md)
make sim-test          # includes the cablesim unit + acceptance suites
make sim-sweep-usdc    # full grid -> sim/RESULTS_USDC.md (multiprocess; tens of minutes)
```

Grid: bases `{(26,1), (30,5), (5,5)}` bps × thresholds `{1000, 1300, 1500, 2000}` ppm ×
slopes `{0.25, 0.5, 1.0}` × caps `{20, 60}` bps + static-5/static-30 baselines, ×
regimes `{gilt-2022, calm-2024, trend-2025}` × organic `{0, 1}`/hr. The acceptance suite
(`tests/test_cablesim_acceptance.py`) pins the static-5 control to the observed live-pool
behavior (one-sided post-ratchet buys, rest at the burn floor, ~25 bps protocol take per
round trip).

## Interpretation notes

- The trade-splitting caveat carries over verbatim from the WETH venue: surcharge revenue
  from single fills is an upper bound (`SECURITY_USDC_WSTGBP.md` §1) — prefer robust rank,
  start conservative, retune from live `SwapFee` telemetry.
- The threshold axis answers the band-geometry question: the pool's legitimate rest states
  are the band edges (±1250 ppm from fair), so `threshold = 1000` arms the surcharge at
  rest while `≥ 1500` arms it only on post-ratchet/post-gap overshoot.
