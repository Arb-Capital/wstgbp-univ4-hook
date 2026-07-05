# WETH/wstGBP Dynamic-Fee Hook — Adversarial & Economic Security Notes

Companion to the Phase 4 adversarial suite (`test/WethWstGbpAdversarial.t.sol`); each section is the
written half of a scenario the suite executes. Numbers quoted are from the suite run of 2026-07-04
(fixture: fair ≈ 1904.76 wstGBP/WETH, POL L = 1e22 over ±5580 ticks, default `FeeParams`).

Scope covered here: `src/weth/WethWstGbpHook.sol`, `src/weth/lib/FeeMath.sol`,
`src/weth/lib/OracleLib.sol`, and (§7) `src/weth/POLCompounder.sol`. Gas numbers and the cold-path
waiver live in the README venue section. Stateful coverage: `test/WethWstGbpHookInvariants.t.sol`
and `test/POLCompounderInvariants.t.sol` (added 2026-07-04) fuzz random interleavings of swaps,
oracle drift/breakage, LP churn, pause, retunes, compounds, and withdrawals against ghost-recorded
invariants (fee == independent recomputation, stock-quoter parity, never-revert, no custody;
compounder principal/custody properties).

## 1. Trade splitting — verified NOT neutral, and why that is acceptable

**Test:** `test_tradeSplittingConvergesToScheduleIntegral`.

The spec hypothesized splitting-neutrality and instructed "verify with a test, don't assume." The
verification result: splitting a deviation-closing trade **reduces** the surcharge paid. Closing a
~1% deviation in one swap paid the pre-swap fee (5050 ppm) on the whole amount (fee value
5.83e15 WETH wei); the same amount in ten slices paid a declining schedule (5050 → 515 ppm,
3.21e15 wei — 45% less).

This is inherent to the design: `beforeSwap` prices the whole swap at the **current** deviation, and
only the fair price is cached — each slice re-reads live slot0. So the slice total converges (from
above) to the **integral of the linear fee schedule** over the deviation being closed, while a
single swap pays a rectangle at the schedule's top.

Why this stands in v1:

- The **integral is the economically meaningful floor** — it is the fee schedule doing exactly what
  it says, applied continuously. No slicing strategy can beat it (asserted: slice total ≥ midpoint
  integral within tolerance; single-swap premium < 2×, the linear-ramp bound).
- The premium above the floor is only paid by **unsophisticated flow**; sophisticated searchers
  split, and their per-slice gas (~75k warm, see README) bounds the depth of splitting long before
  the floor is reached for realistic sizes.
- Sizing the surcharge in the Phase 5 replay sim uses the **sliced (integral) revenue** as the
  conservative case; the toxicity slope tuned there is therefore net of this effect.
- Charging the integrated fee exactly would require computing the post-swap price inside
  `beforeSwap` (estimable from liquidity + amount, but wrong across initialized-tick crossings and
  more surface to audit). Recorded as a v2 candidate, deliberately not in v1.

## 2. Push-then-close manipulation is self-defeating

**Test:** `test_pushThenCloseStrictlyLoses`.

Deviation input pairs Chainlink + the wrapper NAV (not intra-block manipulable) against pool spot
(manipulable only by swapping). A manipulator pushing the pool off fair pays the directional base
fee on opening flow (asserted: exactly base, no surcharge — surcharge only applies to closing flow)
plus price impact against POL; the deviation it creates **arms the surcharge for whoever closes**,
including its own accomplice (asserted: closing leg paid > base). Measured: the pair's combined
fair-valued PnL for a push-to-+1%-and-close round trip is **−15.09 wstGBP** — strictly negative and
larger than the entire closing-leg fee (so there is no fee "redirection" that could fund it). The
manipulation transfers value to POL and to the wstGBP protocol; there is no profitable variant, and
size only scales the loss.

Residual (accepted): pushing the pool can force *third parties* to pay a surcharge they otherwise
wouldn't — a griefing vector that costs the griefer base fee + impact per push and earns them
nothing. POL is the beneficiary.

## 3. JIT liquidity around surcharged swaps — quantified, unmitigated in v1

**Test:** `test_jitLiquidityCaptureQuantified`.

A JIT LP minting a one-spacing-wide position (10× POL liquidity) around a surcharged closing swap
and burning immediately after captured **0.90 wstGBP of the 10.99 wstGBP total fee value** (~8%) in
the measured scenario, net of the adverse-selection inventory it absorbed. Assertion: JIT capture is
bounded by the fee the swap actually paid (it dilutes POL's share of a fixed fee; it cannot extract
beyond it).

No v1 mitigation, by design (spec §Phase 4): the surcharge itself shrinks the JIT edge — the flow
JIT most wants to farm (large, informed, deviation-closing) is exactly the flow that pays the
surcharge, and the JIT position eats the adverse selection of the price move it straddles.
Monitoring (Phase 6 Dune queries) tracks fee distribution; if the JIT share becomes material,
mitigations (e.g. `beforeAddLiquidity` time locks) belong to a v2 hook.

## 4. No fee cliff at the threshold boundary

**Test:** `test_noFeeCliffAtThresholdBoundary`; unit-level `test_thresholdContinuity` in
`test/WethWstGbpFeeMath.t.sol`.

The surcharge is linear **from zero** at the threshold (`slope × (|d| − threshold)`), so a bundle
that walks the deviation across the boundary finds no discontinuity to sandwich: one ppm past the
threshold the surcharge is floor(0.5) = 0; the on-chain fee just past the threshold is bounded by
`base + (d − threshold)` (asserted), and once a swap crosses back under, the next swap pays exactly
base (asserted). There is no regime edge where reordering transactions inside a block manufactures
a fee jump.

## 5. Oracle fallback under load — one verdict per transaction

**Test:** `test_fallbackConsistentUnderLoadWithinTransaction`; the full failure taxonomy is covered
per-cause in `test/WethWstGbpHook.t.sol` (each feed reverting / garbage / stale / absurd, `navprice()
== 0`, both feeds bricked simultaneously).

A flapping oracle mid-bundle cannot produce inconsistent pricing or a revert: the transaction's
first oracle verdict (fair price or fallback) is cached in transient storage and rules every swap in
that transaction; `OracleFallback` emits once per transaction with the causal reason. Design
invariant #1 (never brick the pool) is enforced by construction — `_beforeSwap` has no
oracle-dependent revert path — and fuzzed (`testFuzz_swapNeverRevertsOnOracleState`).

Decode totality (F-1 fix, 2026-07-04): `_readFeed` decodes `latestRoundData` returndata as five
FULL 32-byte words, never as narrow `uint80` types — `abi.decode` validates value-type ranges, so
narrow types would have let a hostile/upgraded aggregator revert in the hook's own frame via dirty
high bits in the ignored roundId/answeredInRound words (regression:
`test_dirtyUint80WordsStillReadable`, red/green-verified against the old decode).

Known limitation (documented in `OracleLib` NatSpec and the README): the wstGBP NAV leg is a
manually-poked push oracle with **no on-chain staleness signal**. A stale-but-nonzero NAV cannot be
detected on-chain; the Chainlink legs carry per-feed staleness windows, and NAV divergence is an
off-chain monitoring concern (`monitoring/check_feeds.sh`, Phase 6).

## 6. Governance surface

`Ownable2Step` multisig (`0x846a655a4fA13d86B94966DFDf4D9a070e554f7c`) can only:
`setFeeParams` (bounds-checked: fees clamped within [minFee, maxFee], `maxFee ≤ 10%` absolute
ceiling — the owner cannot set a confiscatory fee) and `setPaused` (pause **changes pricing to
fallbackFee, never blocks swaps**). No upgradeability, no capital custody, no other admin surface.
Worst-case malicious owner: fees pinned at 10% in both directions — LPs and routers observe
`FeeParamsSet`/`PausedSet` events and route around the pool.

## 7. POLCompounder — custody threat model

**Tests:** `test/POLCompounder.t.sol` (23) + `test/POLCompounderInvariants.t.sol` (stateful).
Unlike the fee-only hook, the compounder CUSTODIES the POL principal (directly in the PoolManager
as its own locker), so its threat model is distinct:

- **Structural cap on the rebalance.** `compound()` never removes principal — the poke credits
  only accrued fees, and the availables are fees + held dust. A compromised or malicious keeper
  controls *timing only*; the worst case per compound is the wrong-side surplus of (fees + dust)
  executed at `toleranceBps` (default 50, hard cap 500) off oracle fair. Repeats don't amplify:
  each compound consumes the surplus, the next is `NothingToCompound`.
- **Sandwich defense = execution-price bound.** `_checkExecPrice` bounds what was actually
  paid/received (v4 partial fills report consumed amounts) against the same OracleLib fair the hook
  uses, both directions; an out-of-bounds fill reverts the whole compound (keeper retries). In
  oracle fallback the rebalance is skipped entirely — the compounder never trades without an oracle
  bound. Residual nuance: the *liquidity add* itself is not oracle-bounded; fees added at a
  manipulated spot lose ~`d²/8` of the compounded amount on reversion — second-order, bounded by
  the fees themselves, and pushing the pool costs the attacker fees into POL.
- **Owner surface.** `withdrawLiquidity` (slippage floors, atomic unwind on breach),
  `sweep` (own ERC-20 balances only — in-pool principal and un-poked fees are structurally
  unreachable), `setKeeper`, `setToleranceBps` (≤ 500), `setStaleness`. NOTE: `setStaleness` is
  NOT bounds-checked (unlike the hook's params) — `0` windows force permanent rebalance-skip,
  huge windows let the bound track a stale fair; an owner-misconfiguration foot-gun, not an
  escalation (the owner can withdraw everything anyway).
- **Migration ordering.** Ownership must reach the Safe BEFORE funds move (see the DEPLOY.md
  appendix) — the original runbook draft had a window where POL sat under the deployer EOA.
- **Ban-list exposure.** The compounder holds/transfers wstGBP, so if banned: `compound()` bricks
  (its own transfers fail `cop.pass`) and held wstGBP dust is stuck, but **principal + fees remain
  recoverable** — `withdrawLiquidity` pays out via `PoolManager.take` directly to any unbanned
  `to`, with the compounder never a transfer party. (Recovery path verified against the wrapper
  source; a dedicated fork test is on the roadmap.)
- **No strandable value in the PM.** The compounder never mints ERC-6909 claims; every unlock
  settles both currencies to zero delta (asserted by the invariant suite).
