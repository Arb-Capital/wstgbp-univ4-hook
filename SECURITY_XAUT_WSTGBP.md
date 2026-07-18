# XAUT/wstGBP Dynamic-Fee Hook — Adversarial & Economic Security Notes

Companion to the adversarial suite (`test/XautWstGbpAdversarial.t.sol`, 6 tests); each section is
the written half of a scenario the suite executes (two sections — §7's market-microstructure half
and §8 — have no executable half by nature; they say so). Numbers quoted are from the suite run of
2026-07-16 (fixture: fair = exactly 2000e18 wstGBP/XAUT — gold $2,625, GBP/USD $1.25, NAV 1.05 —
POL L = 9e15 over ±5580 ticks at spacing 60, WETH-venue default `FeeParams` as working test
params). Production params come from the goldsim sweep (`sim/RESULTS_XAUT.md`, 2026-07-16) via
`DeployXautHook.simParams()`: bases (50,10) bps, threshold 1000 ppm, slope 1.0×, cap 100 bps —
the threshold sits deliberately BELOW the token–metal basis (§6 explains why that won);
owner-retunable either way.

Scope covered here: `src/xaut/XautWstGbpHook.sol`, `src/xaut/lib/FeeMath.sol`,
`src/xaut/lib/OracleLib.sol`. There is **no POLCompounder in this venue** (same launch decision as
the USDC venue: POL is funded and managed via the Uniswap UI / PositionManager). Gas: warm
overhead 9,642; cold 66,105 against the WETH-shaped 80k ceiling — TWO Chainlink proxy→aggregator
chains, not the USDC venue's one (`test/XautWstGbpGas.t.sol`). Stateful coverage:
`test/XautWstGbpHookInvariants.t.sol` (8 invariants) fuzzes random interleavings of swaps, oracle
drift/breakage on all three legs, LP churn, pause, and retunes against ghost-recorded invariants
(fee == independent recomputation, stock-quoter parity, never-revert, no custody).

Status: **DEPLOYED mainnet 2026-07-17** — hook `0x68cF17471aA0Fe54578747C6C7e66795bC8020C0`,
poolId `0xcc06806357a71e7af630dce38d74ee16ed8bf1e0055bc66789d7de4dedef8d8a` (init at 0 ppm vs the
metal fair; XAUt proxy implementation in force at deploy:
`0x4C0d2c74A8D26f1E4F5653021c521F5471F9e566`, logged in the deploy record).

The venue's economic frame differs from the USDC venue's in one structural way that shapes §§4, 6
and 7: this is the first on-chain gold/sterling market (gold-in-GBP realized vol ~37% annualized ≈
6× cable), and its fair price is composed from a feed that prices **spot bullion, not the XAUt
token** — the token trades at a small, **sign-unstable** basis to the metal (~+50bp discount
estimated 2026-07-11; ~11bp premium — token ABOVE the feed — measured 2026-07-16). The
buy-then-redeem conveyor (weekly NAV ratchet; protocol earns the 25bps mint+redeem spread per
round trip) exists here too. In the discount regime the rest state reads as
*non*-deviation-closing to the hook, so the USDC venue's skim-recapture-by-surcharge mechanism
does **not** operate at rest — the conveyor's toll is the redeem-side base fee, and the surcharge
earns its keep on genuine deviation events. In the premium regime the surcharged side flips to the
conveyor (ramp-bounded; economics verified flat). §6 is the full account.

## 1. Trade splitting — NOT neutral (inherited WETH/USDC-venue finding, re-verified here)

**Test:** `test_tradeSplittingConvergesToScheduleIntegral`.

Splitting a deviation-closing trade reduces the surcharge paid. Closing a ~1% deviation in one
swap paid the pre-swap fee (5000 ppm) on the whole amount (fee value 0.0050 XAUT ≈ $13 at the
fixture's $2,625 gold); the same amount in ten slices paid a declining schedule (5000 → 510 ppm,
0.0028 XAUT ≈ $7 — 45% less). Same mechanism as the other venues: `beforeSwap` prices the whole
swap at the **current** deviation and only the fair price is cached — each slice re-reads live
slot0, so the slice total converges from above to the **integral of the linear fee schedule**,
while a single swap pays a rectangle at the schedule's top.

Why this stands in v1 (all prior-venue arguments carry):

- The integral is the economically meaningful floor; no slicing strategy beats it (asserted: slice
  total ≥ midpoint integral within tolerance; single-swap premium < 2×, the linear-ramp bound).
- The premium above the floor is paid only by unsophisticated flow — and the splitting bound is
  **gas-dominated**: a full 1%-of-POL realignment here is ~1 XAUT (~$2,600), so each of the ten
  slices is a ~$260 swap and per-slice mainnet gas eats the ~$6 splitting advantage almost
  immediately. The goldsim parameter derivation uses the sliced (integral) revenue as the
  conservative case regardless.
- Charging the integrated fee exactly would require computing the post-swap price inside
  `beforeSwap` — more surface, wrong across tick crossings; a v2 candidate, deliberately not in v1.

## 2. Push-then-close manipulation is self-defeating

**Test:** `test_pushThenCloseStrictlyLoses` (and re-run at the basis rest state — the adversary's
best case, since the surcharge is already armed there — inside
`test_basisRestState_thresholdSizing`, §6).

Deviation input pairs Chainlink XAU/USD + GBP/USD + the wrapper NAV (none intra-block manipulable)
against pool spot (manipulable only by swapping). A manipulator pushing the pool off fair pays the
directional base fee on opening flow (asserted: exactly base, no surcharge) plus price impact
against POL; the deviation it creates **arms the surcharge for whoever closes**, including its own
accomplice (asserted: closing leg paid > base). Measured: the pair's combined fair-valued PnL for
a push-to-+1%-and-close round trip is **−15.85 wstGBP** — strictly negative and larger than the
entire closing-leg fee (no fee "redirection" could fund it); at the basis rest state the same
round trip loses **−18.90 wstGBP** (valued at the pool's own rest price — the level the token
actually trades). Size only scales the loss (an argument from the fee/impact structure — the
executed check runs one representative size).

Residual (accepted): pushing the pool can force third parties to pay a surcharge they otherwise
wouldn't — a griefing vector that costs the griefer base fee + impact per push and earns them
nothing. POL is the beneficiary.

## 3. JIT liquidity around surcharged swaps — quantified, unmitigated in v1

**Test:** `test_jitLiquidityCaptureQuantified`.

A JIT LP minting a tight position spanning the closing move (10× POL liquidity, 180 ticks — at
spacing 60 the tightest legal position is already 60 ticks, so three spacings is the realistic JIT
shape that keeps a ~1% ≈ 100-tick move covered from anywhere inside the current spacing) around a
surcharged closing swap and burning immediately after captured **0.81 wstGBP of the 9.94 wstGBP
total fee value** (~8%), net of the adverse-selection inventory it absorbed. Assertion: JIT
capture is bounded by the fee the swap actually paid (it dilutes POL's share of a fixed fee; it
cannot extract beyond it).

No v1 mitigation, by design: the surcharge itself shrinks the JIT edge — the flow JIT most wants
to farm is exactly the flow that pays the surcharge, and the JIT position eats the adverse
selection of the move it straddles. Monitoring tracks fee distribution; material JIT share ⇒ v2
mitigations.

## 4. No fee cliff at the threshold boundary

**Test:** `test_noFeeCliffAtThresholdBoundary`; unit-level `test_thresholdContinuity` in
`test/XautWstGbpFeeMath.t.sol`.

The surcharge is linear **from zero** at the threshold (`slope × (|d| − threshold)`), so a bundle
that walks the deviation across the boundary finds no discontinuity to sandwich (asserted both
sides of the boundary, on-chain). The venue-specific note is sharper here than on the USDC venue:
the pool's *legitimate resting state* is not the wrapper band edge (±1250 ppm) but d ≈ −basis
(§6), whose sign is unstable. At the design-point discount it is ~−5000 ppm and threshold
placement decides whether resting mint-side flow is surcharged; at a premium it is positive and
the same decision applies to resting redeem-side flow instead. That is a parameter (sim-derived),
not a mechanism property; the no-cliff property holds at any threshold. It also defuses §7's
chunky feed steps: a single XAU/USD commit can jump |d| by ~3000 ppm, but what it jumps onto is a
ramp, never a cliff.

## 5. Oracle fallback under load — one verdict per transaction

**Test:** `test_fallbackConsistentUnderLoadWithinTransaction`; the failure taxonomy is covered
per-cause across two levels: hook-level in `test/XautWstGbpHook.t.sol` (per feed × {revert, short
returndata, zero, negative, absurd, stale, future-timestamped} — `test_xauFeed*FallsBack` /
`test_gbpFeed*FallsBack` — plus `navprice() == 0`, both-feeds-broken read-order precedence
`test_bothFeedsBrokenXauReasonWins`, and everything broken simultaneously
`test_allOraclesBrokenSwapStillCompletes`) and unit-level in `test/XautWstGbpOracleLib.t.sol`
(additionally garbage returns, feeds with no code, per-feed staleness boundaries
`test_stalenessBoundaryPerFeed`/`test_stalenessWindowsArePerFeed`, and the sub-sentinel composition
floor `test_compositionFlooringToSubSentinelIsNavBad`); the hook-level never-revert fuzz spans the
absurd range (`testFuzz_swapNeverRevertsOnOracleState`).

A flapping oracle mid-bundle cannot produce inconsistent pricing or a revert: the transaction's
first oracle verdict (fair price or fallback) is cached in transient storage and rules every swap
in that transaction; `OracleFallback` emits once per transaction with the causal reason (asserted
by `test_fallbackVerdictCachedWithinTransaction`). Exception, by design: while the owner PAUSE is
active the event emits per swap with reason 0xFF (the pause path never touches the cache) — an
off-chain counter mixing per-tx (codes 1–7) and per-swap (0xFF) semantics must account for that.
Design invariant #1 (never brick the pool) is enforced by construction — `_beforeSwap` has no
oracle-dependent revert path — and fuzzed.

Decode totality (the WETH venue's F-1 fix, carried over from day one): `_readFeed` decodes
`latestRoundData` returndata as five FULL 32-byte words, never as narrow `uint80` types
(regression: `test_dirtyUint80WordsStillReadable` in `test/XautWstGbpOracleLib.t.sol`).

**Reason-code renumbering (off-chain decoder hazard, now three-way):** this venue's
`FallbackReason` has 8 entries — 1..3 XAU feed {call, answer, stale}, 4..6 GBP feed, 7 NAV_BAD,
0xFF paused. That is *structurally* the WETH venue's numbering with XAU/USD in the ETH/USD
position — so a copy-pasted WETH decoder produces plausible-looking output that mislabels every
code-1..3 failure as "ETH feed" — and it renumbers outright vs the USDC venue's 5-entry enum
(there GBP is 1..3 and NAV_BAD = 4; here GBP is 4..6 and NAV_BAD = 7). Dune queries and any
`OracleFallback` decoder MUST use the per-venue mapping — the cross-venue table lives in
`monitoring/dune/README.md` (this venue's column lands with its deploy-time monitoring set). Read
order is XAU first, so when both feeds are down the XAU reason wins (asserted at both levels).

Known limitation (documented in `OracleLib` NatSpec): the wstGBP NAV leg is a manually-poked push
oracle with **no on-chain staleness signal**. A stale-but-nonzero NAV cannot be detected on-chain;
both Chainlink legs carry staleness windows, and NAV divergence is an off-chain monitoring concern
(`monitoring/check_feeds.sh`).

## 6. Token–metal basis — ACCEPTED, with structural mitigation (venue decision 2026-07-11)

**Test:** `test_basisRestState_thresholdSizing` — the basis itself is a market fact outside the
contract and no test can cover it; what IS executable is the fee behavior at the rest state, and
that test pins all three on-chain claims below.

The fact: Chainlink XAU/USD prices **spot bullion** while the pool trades the *token*, so the
hook's fair is metal-priced and the pool **rests at d ≈ −basis, not d ≈ 0**, even when it sits
exactly at token-market fair. The basis (custody/redemption friction) is small and
**sign-unstable**: ~+50bp (≈5000 ppm) discount estimated at the venue decision (2026-07-11), but
a ~11bp **premium** — XAUt ABOVE the feed (XAUT $3,985.12 vs XAU/USD $3,980.58; XAUT/PAXG ≈
+28bp) — measured live 2026-07-16. Treat the sign as a regime, not a constant. This is the
venue's signature risk. In the DISCOUNT regime (basis > 0, rest d < 0) it has four verified
consequences:

1. **The conveyor is surcharge-immune at rest.** At d < 0, XAUT-in (redeem-side) flow reads as
   deviation-*opening* — so the post-NAV-ratchet buy-then-redeem arb, which the USDC venue's
   surcharge recaptures, pays the redeem-side **base only** here, and **no threshold setting can
   change that** (asserted: the redeem-side opener pays exactly base at the rest state). The
   recapture stance on this venue is the base-fee asymmetry, not the surcharge; the surcharge's
   job is genuine deviation events (gold/cable moves), of which this pair has ~6× cable's supply.
2. **Resting mint-side flow is misclassified by an undersized threshold.** At d ≈ −5000, wstGBP-in
   flow reads as deviation-*closing*. A threshold below the basis surcharges every resting
   mint-side trade — a misclassification tax on uninformed flow (asserted: at threshold 1000 the
   resting mint side pays ~4,990 ppm = base 3000 + ~0.5×(4976−1000) of ramp — the ramp, not the
   cap). A threshold above the basis does not (asserted: retuned to 6000 ppm via `setFeeParams`,
   the same flow pays exactly base — and the clean rest-state goldsim run shows surcharge exactly
   0).
3. **An undersized threshold widens the mint-side no-arb band.** The clamping arb (the mint-side
   loop that corrects a pool wandering too deep below fair) is itself surcharged, so it waits
   until the deviation covers cap-saturated surcharge + mint base + wrapper half-band + cross-leg
   costs ≈ 6000 + 3000 + 1250 + 1500 = **~11,750 ppm** (at thr 1000 / slope 1.0× / cap 6000)
   before acting — the pool can wander much deeper below fair before arbitrage corrects, degrading
   price quality. Verified in goldsim: p95 |d| ~9,800 ppm with the low threshold vs ~7,000 clamped
   with a high one; at the shipped winner (thr 1000 / slope 1.0× / cap 10000) the observed anchor-
   cell band is p50 ~3,900 / p95 ~12,400 ppm (`sim/RESULTS_XAUT.md`).
4. **In a gold rally the surcharge over-fires by ~the basis.** d_true < 0 is the mint-side loop's
   *legitimate* closing regime, but the hook measures d_oracle ≈ d_true − 5000 — the closing flow
   is overcharged by roughly the basis's worth of ramp. Bounded by the cap; priced into the sweep.

In the PREMIUM regime (basis < 0, rest d > 0 — the live regime measured 2026-07-16) the
misclassification flips sides: resting *redeem-side* (conveyor) flow reads deviation-closing and
pays base + ramp surcharge once |d| exceeds the threshold, while resting mint-side flow rides
free (`sim/tests/test_gold_agents.py::test_premium_regime_flips_the_surcharged_side` pins the
flip). At observed premium magnitudes the surcharge is ramp-priced — ~1bp at an 11bp premium
under the shipped thr 1000 / slope 1.0× — nowhere near the cap. The extended basis-sensitivity
table (`sim/RESULTS_XAUT.md`, basis {−50, −25, 0, 25, 50, 100} bps) shows anchor-cell economics
are FLAT below basis 0: house take −365 (basis −50) vs −360 (basis 0) vs −356 (the +50 design
point), conveyor alive at ~4× the dead threshold. The premium regime costs protocol revenue
(~−17% vs the +50bp-discount cell) and widens the band (p50 ~7.6k vs ~3.9k ppm) but breaks
nothing structurally. A full-grid ranking run at basis 0 lives in `sim/RESULTS_XAUT_BASIS0.md`
(`make sim-sweep-xaut-basis0`). Taken alone it selects the shipped config's thr=3000 sibling
(worst rank 6 vs the shipped config's 7 — an advantage worth $12–122 in the organic-0 bleed
cells, against $1.3k–3.3k per organic-1 cell in the shipped config's favor). But the basis is a
sign-unstable REGIME, and the same minimax objective applied across the union of both ranking
runs' cells selects the shipped config UNIQUELY (worst rank 7; next-best 9; the thr=3000
sibling unions at 39 via its discount-regime shock-cell collapse) — so `simParams()` stands
confirmed by the rule at the regime level, with the single-regime divergence disclosed
(readiness addendum, 2026-07-16; the ranking itself is competition-ranked with a declared
total-house-take tie-break and stable config-label tertiary key — exact-tie ranks previously
fell to grid order).

The rest state arms no manipulation edge: push-then-close run at the basis rest state — on the
undersized threshold, the adversary's best case — still strictly loses (−18.90 wstGBP,
rest-valued; loss exceeds the closing-leg fee — asserted, §2).

Mitigation (structural, not reactive):

1. The threshold-vs-basis axis was **resolved by the goldsim sweep, not by intuition** — and the
   sweep chose the opposite of the naive fix (`sim/RESULTS_XAUT.md`, 2026-07-16): the winner's
   threshold (1000 ppm) sits BELOW the basis, accepting consequences 2–4 as priced trade-offs.
   Why that wins: in the discount regime the conveyor is surcharge-immune at rest under any
   threshold (consequence 1), so a sub-basis threshold converts the resting mint side into
   surcharge revenue without starving the venue's protocol-revenue engine — and in the premium
   regime the conveyor's resting surcharge is ramp-bounded and the anchor-cell economics stay
   flat (the premium paragraph above) — and it out-ranked every above-basis config in ALL six
   regime×organic cells (worst-case rank 7 vs 9+). The basis-sensitivity table (extended to basis
   {−50, −25, 0, 25, 50, 100} bps after the 2026-07-16 sign-flip measurement) shows the winner is
   not fragile in the basis estimate — either side of zero: house take stays in a narrow band,
   conveyor volume rises with the basis and survives its absence, and the premium rows are flat
   vs basis 0.
2. The owner retunes `FeeParams` if the basis regime shifts (a persistent change in either
   direction shows up directly in the `SwapFee` event stream's deviation field — the rest state
   is observable).
3. Full-loop context for the band arithmetic: the conveyor's breakeven here is ≈ 3,250 ppm
   (wrapper half-band 1250 + cross-leg ~1500 + redeem base fee) — recycling is tGBP → USDC → XAUt,
   **two** legs, vs the USDC venue's one (cost model: `sim/goldsim/costs.py`).

## 7. Weekend/holiday stale-fair + feed coarseness

**Executable half:** the staleness/fallback machinery of §5 (per-feed windows, stale → fallback,
never-revert); the market-calendar behavior itself is empirical — the venue deployed 2026-07-17
(a Friday), so the first live weekend round is the check.

Gold observes the FX market calendar: closed weekends, plus a daily 22:00–23:00 UTC break — unlike
the USDC venue's 24/7 crypto-native quote leg, this venue's dominant feed freezes for ~49 hours
every week. Two possible feed behaviors, both handled:

- **Chainlink keeps heartbeating a frozen price through the close** (the typical, observed
  behavior): fair is stale-but-fresh-looking; on-chain pool spot can drift with off-market gold
  trading, so a weekend adds **incremental deviation around the −basis rest state — not a
  fallback state** (under the 2026-07-11 discount estimate the rest state sat at |d| ≈ 5000 ppm
  against the 1000 ppm threshold, so §6's resting fee split persisted through the close; at the
  small live basis measured 2026-07-16 the rest state may sit inside the band until weekend drift
  accumulates) — and Monday's reopen gap is a legitimate deviation event the surcharge is *for*.
- **The feed pauses instead**: `updatedAt` ages past the 90,000s window (24h heartbeat + margin)
  and every swap prices at the flat `fallbackFee` until the feed resumes — degraded pricing, never
  blocked swaps (`test_xauFeedStaleFallsBack`, `testFuzz_swapNeverRevertsOnOracleState`).

Coarseness (the deviation-step texture, distinct from staleness): XAU/USD commits on a **0.3%**
deviation or 24h heartbeat — twice the GBP/USD leg's 0.15% — so fair moves in chunky ≥3000 ppm
steps when gold drifts, and up to ~3000 ppm of measured |d| at any moment is feed-deadband noise
stacked on top of the (sign-unstable, |·| ≲ 5000 ppm) basis rest state (§6). Threshold sizing
must budget for deadband + basis together; the goldsim bars model reproduces both Chainlink
deadbands, and §4's no-cliff property guarantees a single feed commit that jumps |d| across the
threshold lands on a ramp, not a step.

## 8. XAUt issuer surface — ACCEPTED (same posture as the USDC venue's issuer trust)

**No test can cover this: it is a trust decision about the quote token, not hook behavior.** The
hook's own custody exposure is nil by construction — it is fee-only and never holds a wei of
either token (`invariant_hookHoldsNoTokens` in `test/XautWstGbpHookInvariants.t.sol`).

XAUT (Tether Gold, 6 decimals — asserted in the constructor, the `XAUT_UNIT = 1e6` contract) has
no fee-on-transfer and no global pause, but its issuer can **blacklist addresses**, call
**`destroyBlockedFunds`** on blacklisted balances, and **upgrade the token implementation**
(issuer-controlled proxy). This is the same risk class the USDC venue accepts on USDC (blacklist +
upgradeable proxy), and the same class every XAUt holder bears anywhere:

- LPs hold XAUt inventory; an issuer action against the PoolManager's balance or a hostile
  upgrade is a pair-wide event no fee schedule can defend against — exactly as a USDC blacklisting
  would be on that venue. Fees were never the defense; inventory exposure is the LP's, as in every
  XAUt pool.
- The hook keeps working regardless: it reads feeds and overrides fees; it neither sends nor
  receives XAUt. If token-level behavior changes in a way that degrades the pool, the owner's
  `setPaused(true)` flattens pricing while LPs exit (pause changes pricing, never blocks swaps).

Made executable at the deployment edges (2026-07-16 review): `DeployXautHook` pre-flight requires
`!isBlocked(...)` for the PoolManager, multisig, PositionManager and Permit2, and logs the XAUt
proxy implementation in force (EIP-1967 slot) into the deploy record before it deploys and
initializes; recovery-only `InitXautPool` re-checks the blocklist immediately before init, and
DEPLOY.md §X repeats the check before POL funding.

Accepted for v1; revisit only if issuer-risk posture changes repo-wide (it would implicate the
USDC venue equally).

## 9. Governance surface

`Ownable2Step` multisig (`0x846a655a4fA13d86B94966DFDf4D9a070e554f7c`, owner from construction —
no deployer window) can only: `setFeeParams` (bounds-checked: fees clamped within
[minFee, maxFee], `maxFee ≤ 10%` absolute ceiling — the owner cannot set a confiscatory fee) and
`setPaused` (pause **changes pricing to fallbackFee, never blocks swaps**). No upgradeability, no
capital custody, no other admin surface. Worst-case malicious owner: fees pinned at 10% in both
directions — LPs and routers observe `FeeParamsSet`/`PausedSet` events and route around the pool.

Two-feed trust surface: this venue's Chainlink dependence is TWO feeds (XAU/USD 0.3%/24h +
GBP/USD 0.15%/24h) plus the wrapper's NAV — the WETH venue's shape, wider than the USDC venue's
one. Each feed carries its own staleness window (`xauUsdStalenessSec` / `gbpUsdStalenessSec`,
default 90,000 = heartbeat + margin) in `FeeParams`, independently owner-retunable; a retune can
flip an unchanged feed from fresh to stale — and symmetrically back — (the fresh→stale direction
is the covered one, per feed: `test_xauStalenessRetuneFlipsFreshFeedIntoFallback` and
`test_gbpStalenessRetuneFlipsFreshFeedIntoFallback`).
