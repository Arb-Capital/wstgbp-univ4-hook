# wstGBP/USDC Dynamic-Fee Hook — Adversarial & Economic Security Notes

Companion to the adversarial suite (`test/UsdcWstGbpAdversarial.t.sol`); each section is the
written half of a scenario the suite executes. Numbers quoted are from the suite run of 2026-07-05
(fixture: fair ≈ 0.761905 wstGBP/USDC, POL L = 5e17 over ±5580 ticks at spacing 1, WETH-venue
default `FeeParams` — production params come from `sim/RESULTS_USDC.md` and are owner-retunable).

Scope covered here: `src/usdc/UsdcWstGbpHook.sol`, `src/usdc/lib/FeeMath.sol`,
`src/usdc/lib/OracleLib.sol`. There is **no POLCompounder in this venue** (launch decision: POL is
funded and managed via the Uniswap UI / PositionManager, as on the WETH venue). Gas numbers live in
the README venue section (warm overhead 9,604; cold 46,814 — one Chainlink chain, not two).
Stateful coverage: `test/UsdcWstGbpHookInvariants.t.sol` fuzzes random interleavings of swaps,
oracle drift/breakage, LP churn, pause, and retunes against ghost-recorded invariants (fee ==
independent recomputation, stock-quoter parity, never-revert, no custody).

The venue's economic purpose frames every section below: the existing STATIC 5bps wstGBP/USDC pool
demonstrably runs a **buy-then-redeem conveyor** (weekly NAV ratchet leaves the pool below the new
burn floor; arbs buy wstGBP cheap and exit via `wstGBP.redeem`; the protocol earns the 25bps
mint+redeem spread per round trip, the LP eats the gap). This hook does not try to stop that
conveyor — it is protocol revenue — it recaptures the residual arb skim into POL via the toxicity
surcharge. `d > 0` (pool prices USDC rich / wstGBP cheap) is the post-ratchet state, closed by
USDC-in flow that pays redeem-side base + surcharge.

## 1. Trade splitting — NOT neutral (inherited WETH-venue finding, re-verified here)

**Test:** `test_tradeSplittingConvergesToScheduleIntegral`.

Splitting a deviation-closing trade reduces the surcharge paid. Closing a ~1% deviation in one swap
paid the pre-swap fee (5000 ppm) on the whole amount (fee value 14.28 USDC); the same amount in ten
slices paid a declining schedule (5000 → 510 ppm, 7.86 USDC — 45% less). Same mechanism as the WETH
venue: `beforeSwap` prices the whole swap at the **current** deviation and only the fair price is
cached — each slice re-reads live slot0, so the slice total converges from above to the **integral
of the linear fee schedule**, while a single swap pays a rectangle at the schedule's top.

Why this stands in v1 (all WETH-venue arguments carry, one is stronger here):

- The integral is the economically meaningful floor; no slicing strategy beats it (asserted: slice
  total ≥ midpoint integral within tolerance; single-swap premium < 2×, the linear-ramp bound).
- The premium above the floor is paid only by unsophisticated flow — and on THIS venue the
  splitting bound is **gas-dominated**: observed conveyor notionals are small (~$1k), so per-slice
  gas eats the splitting advantage almost immediately. The cable sim's parameter derivation uses
  the sliced (integral) revenue as the conservative case regardless.
- Charging the integrated fee exactly would require computing the post-swap price inside
  `beforeSwap` — more surface, wrong across tick crossings; a v2 candidate, deliberately not in v1.

## 2. Push-then-close manipulation is self-defeating

**Test:** `test_pushThenCloseStrictlyLoses`.

Deviation input pairs Chainlink GBP/USD + the wrapper NAV (not intra-block manipulable) against
pool spot (manipulable only by swapping). A manipulator pushing the pool off fair pays the
directional base fee on opening flow (asserted: exactly base, no surcharge) plus price impact
against POL; the deviation it creates **arms the surcharge for whoever closes**, including its own
accomplice (asserted: closing leg paid > base). Measured: the pair's combined fair-valued PnL for a
push-to-+1%-and-close round trip is **−15.09 wstGBP** — strictly negative and larger than the
entire closing-leg fee (no fee "redirection" could fund it). Size only scales the loss.

Residual (accepted): pushing the pool can force third parties to pay a surcharge they otherwise
wouldn't — a griefing vector that costs the griefer base fee + impact per push and earns them
nothing. POL is the beneficiary.

## 3. JIT liquidity around surcharged swaps — quantified, unmitigated in v1

**Test:** `test_jitLiquidityCaptureQuantified`.

A JIT LP minting a tight position spanning the closing move (10× POL liquidity, ~120 ticks — at
spacing 1 a "one-spacing" position would be a degenerate 1-tick sliver, so the realistic JIT shape
is modeled instead) around a surcharged closing swap and burning immediately after captured
**0.88 wstGBP of the 10.78 wstGBP total fee value** (~8%), net of the adverse-selection inventory
it absorbed. Assertion: JIT capture is bounded by the fee the swap actually paid (it dilutes POL's
share of a fixed fee; it cannot extract beyond it).

No v1 mitigation, by design: the surcharge itself shrinks the JIT edge — the flow JIT most wants to
farm is exactly the flow that pays the surcharge, and the JIT position eats the adverse selection
of the move it straddles. On this venue the absolute JIT prize is additionally tiny (conveyor
notionals are small). Monitoring tracks fee distribution; material JIT share ⇒ v2 mitigations.

## 4. No fee cliff at the threshold boundary

**Test:** `test_noFeeCliffAtThresholdBoundary`; unit-level `test_thresholdContinuity` in
`test/UsdcWstGbpFeeMath.t.sol`.

The surcharge is linear **from zero** at the threshold (`slope × (|d| − threshold)`), so a bundle
that walks the deviation across the boundary finds no discontinuity to sandwich (asserted both
sides of the boundary, on-chain). One venue-specific note: the pool's *legitimate resting states*
are the wrapper band edges (±1250 ppm from NAV-anchored fair), so where the threshold sits relative
to the half-band decides whether resting-state closing flow is surcharged at all — that is a
parameter (sim-derived), not a mechanism property; the no-cliff property holds at any threshold.

## 5. Oracle fallback under load — one verdict per transaction

**Test:** `test_fallbackConsistentUnderLoadWithinTransaction`; the full failure taxonomy is covered
per-cause in `test/UsdcWstGbpHook.t.sol` (feed reverting / garbage / stale / absurd,
`navprice() == 0`, everything broken simultaneously).

A flapping oracle mid-bundle cannot produce inconsistent pricing or a revert: the transaction's
first oracle verdict (fair price or fallback) is cached in transient storage and rules every swap
in that transaction; `OracleFallback` emits once per transaction with the causal reason. Design
invariant #1 (never brick the pool) is enforced by construction — `_beforeSwap` has no
oracle-dependent revert path — and fuzzed (`testFuzz_swapNeverRevertsOnOracleState`).

Decode totality (the WETH venue's F-1 fix, carried over from day one): `_readFeed` decodes
`latestRoundData` returndata as five FULL 32-byte words, never as narrow `uint80` types
(regression: `test_dirtyUint80WordsStillReadable` in `test/UsdcWstGbpOracleLib.t.sol`).

**Reason-code renumbering (off-chain decoder hazard):** this venue's `FallbackReason` has 5 entries
(1..3 = GBP feed call/answer/stale, 4 = NAV_BAD, 0xFF = paused) vs the WETH venue's 8 (there
NAV_BAD = 7). Dune queries and any `OracleFallback` decoder MUST use the per-venue mapping — see
`monitoring/dune/README.md`. Copy-pasting the WETH decoding misattributes every failure.

Known limitation (documented in `OracleLib` NatSpec): the wstGBP NAV leg is a manually-poked push
oracle with **no on-chain staleness signal**. A stale-but-nonzero NAV cannot be detected on-chain;
the GBP/USD leg carries a staleness window, and NAV divergence is an off-chain monitoring concern
(`monitoring/check_feeds.sh`).

## 6. USDC depeg risk — ACCEPTED, with off-chain mitigation (venue decision 2026-07-05)

**No test can cover this: it is invisible to the contract by construction.**

The fair composition assumes USDC = $1.00 — there is deliberately no USDC/USD feed (one less trust
input and cold oracle read; the composition `1e8·WAD²/(g·nav)` is single-feed). The consequence:

- A USDC depeg does not move the hook's fair price. The market reprices the pool, the measured
  deviation grows, and the toxicity surcharge **misclassifies the resulting flow** — during a USDC
  crash (pool's wstGBP-per-USDC spot falls vs unmoved fair, d < 0), wstGBP-in flow reads as
  "informed closing" and is surcharged, while USDC-in flow dumping the depegging asset on the LP
  reads as "opening" and pays base only. The fee schedule leans the wrong way exactly when the LP
  most needs protection.
- Fees were never the real defense anyway: **LPs hold USDC inventory risk during a depeg
  regardless of any fee schedule** (as in every USDC pool). The surcharge misfire worsens the edge
  by at most `maxFee`; the inventory loss dominates by orders of magnitude.

Mitigation (operational, not contractual):

1. `monitoring/check_feeds.sh` carries an advisory **USDC/USD probe** against Chainlink
   `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6`, alerting when |answer − $1| > 50bps. This is the
   depeg alarm the hook itself cannot raise.
2. On alert, the owner multisig calls `setPaused(true)`: every swap then pays the flat
   `fallbackFee` in both directions — no misclassification, swaps never blocked, LPs can exit.
3. Recovery: unpause after re-peg (pause changes pricing only; it is freely reversible).

The 2023 SVB depeg (USDC to $0.87 over a weekend) is the calibration scenario: a multisig pause is
hours-scale, the misfire window is bounded by monitoring latency + signer latency, and the marginal
damage of the misfire over that window is `≤ maxFee` on the flow that happened to close toward the
stale fair. Documented as accepted; revisit (add the USDC/USD feed — the OracleLib composition
slot exists structurally, it is the WETH venue's two-feed shape) if this venue's POL scales to
where hours-scale misfires are material.

## 7. Governance surface

`Ownable2Step` multisig (`0x846a655a4fA13d86B94966DFDf4D9a070e554f7c`, owner from construction —
no deployer window) can only: `setFeeParams` (bounds-checked: fees clamped within
[minFee, maxFee], `maxFee ≤ 10%` absolute ceiling — the owner cannot set a confiscatory fee) and
`setPaused` (pause **changes pricing to fallbackFee, never blocks swaps**). No upgradeability, no
capital custody, no other admin surface. Worst-case malicious owner: fees pinned at 10% in both
directions — LPs and routers observe `FeeParamsSet`/`PausedSet` events and route around the pool.

Single-feed trust surface: this venue's whole Chainlink dependence is ONE feed (GBP/USD,
86400s heartbeat / 0.15% deviation) plus the wrapper's NAV — narrower than the WETH venue's two
feeds. The staleness window (`gbpUsdStalenessSec`, default 90_000 = heartbeat + margin) lives in
`FeeParams` and is owner-retunable; a retune can flip an unchanged feed fresh↔stale (covered:
`test_stalenessRetuneFlipsFreshFeedIntoFallback`).
