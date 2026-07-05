# WETH/wstGBP Dynamic-Fee Venue — Production-Readiness Report (2026-07-04)

Scope: `src/weth/` (`WethWstGbpHook`, `FeeMath`, `OracleLib`, `POLCompounder`),
`script/DeployWethHook.s.sol`, `script/InitWethPool.s.sol`, the `test/WethWstGbp*` /
`test/POLCompounder*` suites, `sim/`, `monitoring/`, and the `DEPLOY.md` runbook.
Reviewed at commit `1b03a01` (the commit that introduced the venue), working tree clean.

**"Production-ready" here means: ready to execute the treasury-scale launch path in `DEPLOY.md`.**
It is NOT an audit substitute — the venue is explicitly outside the backstop audit's scope
(`AUDIT_SCOPE.md`) and needs its own external audit before POL scale-up.

## Verdict — GO, with three conditions (updated after the external review below)

1. ~~Decide F-1 before broadcasting~~ — **F-1 APPLIED (2026-07-04, same day).**
   `OracleLib._readFeed` decoded `latestRoundData` returndata as
   `(uint80, int256, uint256, uint256, uint80)`; `abi.decode` validates value types, so a
   hostile/buggy aggregator (the trust scenario the rest of `_readFeed` already defends against —
   e.g. a Chainlink governance-upgraded implementation) returning ≥160 bytes with dirty high bits
   in either `uint80` word reverted the decode **in the hook's frame** — every swap on the pool
   would revert until the feed healed or the owner paused. Fixed by decoding five FULL words
   (total for any ≥160-byte return; the ignored roundId/answeredInRound words carry no signal the
   library uses). Verified red/green: a new `MODE_DIRTY_WORDS` mock mode +
   `test_dirtyUint80WordsStillReadable` regression test **failed against the old decode and passes
   against the fix**; full suite 267/267 after; gas snapshot regenerated (the guarded read got
   ~0.8k gas cheaper). This closes the last residual revert path in the "never brick the pool"
   invariant.
2. **Commit/push before deploying.** The entire venue exists in one unpushed local commit
   (`1b03a01`) plus this readiness pass's uncommitted work (including the F-1 fix). Record the
   deployed rev per `DEPLOY.md` §0. (Deliberately left to the operator.)
3. **Re-run the invariant gate on an authenticated archive RPC at the final commit** (added after
   the external review below): the public-RPC 403 flake means `make test-invariant` at the exact
   deploy rev, with `.env` credentials, is part of the gate — not optional.

Everything else verified clean: no must-fix findings from either reviewer; every suite green on
fresh runs; the deploy/init two-step rehearsed end-to-end on an anvil mainnet fork with 0 ppm init
deviation; live oracle legs healthy today.

## External review follow-ups (2026-07-04, post-pass)

An independent review of this tree returned four findings; dispositions:

| Sev | Finding | Disposition |
|---|---|---|
| Medium | Pool init raceable after hook deploy; runbook only covered the zero-liquidity front-run — nontrivial hostile liquidity at a bad price defeats the dust-swap recovery | **Fixed (runbook)** — DEPLOY.md §3 now: (a) init runs immediately after deploy confirms (Etherscan verify moved after; private-bundle option for a zero-width window); (b) explicit recovery per case: zero-liquidity → dust-swap reprice; nontrivial liquidity off-fair → simulate the exact closing swap and execute profit-bounded (or wait for searchers), fund only under 10 bps; un-normalizable → do NOT fund, use a governance-approved alternate tickSpacing key (the hook accepts any spacing) |
| Medium | Deploy gate not proven on this tree: `WethWstGbpHookInvariants` aborted 7/8 on publicnode HTTP 403 (archive-request limit) in the reviewer's run | **CLOSED (2026-07-04)** — full `make test-invariant` re-run on an authenticated Alchemy RPC against the exact deployed tree: **21/21 invariants passed across all 4 suites** (backstop 4, adapter 3, weth hook 8, compounder 6) in 1117s, zero failures, zero RPC aborts. Gate requirement retained in DEPLOY.md §0 |
| Medium/ops | `src/weth/` remains outside the prior audit scope | **Acknowledged — as designed**, now stated as a conscious checklist item: DEPLOY.md §0 records the risk acceptance (first-party review only ⇒ small capped launch POL; scale-up gated on the venue's own external audit) |
| Low | Deploy rev not commit-clean (many modified/untracked files) | **Acknowledged — operator action** (this repo's assistant is barred from committing). DEPLOY.md §0 now requires a clean `git status` at the recorded rev. Verdict condition 2 |

## Evidence — fresh runs at `1b03a01` (2026-07-04)

| Check | Result |
|---|---|
| `forge build` + `forge fmt --check` | clean (via-IR, solc 0.8.28) |
| `make test` (full fast suite, mainnet fork) | **264/264 passed** in 21.6s, incl. all 9 pre-existing weth suites (**267/267** after this pass's 3 new stateless tests incl. the F-1 regression) |
| `make coverage` (weth `src/`) | `WethWstGbpHook` **100%** all metrics; `FeeMath` **100%**; `OracleLib` **100%**; `POLCompounder` initially 99.40% lines — the one uncovered line (the `_fits` rounding-guard decrement) was closed same-day by extracting it into `_fitLiquidity` (behavior-identical) + white-box `FitHarness` tests, incl. a fuzz pinning why the guard is a no-op in the live flow (forward-computed liquidity always fits round-up charging) → **100% lines/funcs** (30/33 branches, lcov branch artifacts) |
| `make sim-test` | 9/9 passed (incl. the Solidity⇄Python shared-vector cross-pin) |
| `make snapshot-check` | pass (tolerance 1) |
| Gas suite (fresh numbers) | warm overhead **9,664** (target <10k MET: 74,908 vs 65,244 control); cold **66,397** (spec <40k waived, 80k ceiling enforced: 168,339 vs 101,942) |
| `make deploy-weth-hook-dry` (live mainnet state) | pass — pre-flight corridor ok (composed fair 1334.56 wstGBP/WETH), ~2.43M gas est. |
| Anvil fork rehearsal (DEPLOY.md §1, full two-step) | pass — hook deployed at mined address (flag bits `0x20C0` verified in-address), pool initialized at **0 ppm** deviation, re-run of init reverts as designed |
| `monitoring/check_feeds.sh` (live) | ok — ETH/USD age 1204s (<4500), GBP/USD age 46144s (<90000), `navprice()` = 1.0047e18 (nonzero) |
| Feed identity (live `cast`) | `description()` = "ETH / USD" / "GBP / USD", both `decimals() == 8` |
| Params triple-match | `sim/RESULTS.md` == `DeployWethHook.simParams()` == fork-test `_defaultParams()` — all ten fields identical |
| NEW `WethWstGbpHookInvariants` (8 invariants, 64 runs × depth 32) | **8/8 passed** — 2048 handler calls per invariant, zero handler-level reverts, zero ghost violations (~20 min on the public RPC; one campaign was interrupted by a public-RPC 403 mid-setup and re-run clean — infra, not a property) |
| NEW `POLCompounderInvariants` (6 invariants, 32 runs × depth 16) | **6/6 passed** (234s; 512 calls per invariant; 116 compounds attempted, zero unexpected reverts) |
| NEW stateless tests (2) | both pass: `test_stalenessRetuneFlipsFreshFeedIntoFallback`, `test_twoLivePoolsPriceTheirOwnDeviation` |

## New stateful suites (the readiness pass's code deliverable)

The venue previously had NO stateful invariant coverage (the backstop and adapter venues both do).
Added, mirroring the backstop's handler/ghost pattern (`fail_on_revert = false`; handlers never
assert — violations land in ghost counters the invariants surface, so lenient revert handling
cannot mask a violation):

- **`test/WethWstGbpHookInvariants.t.sol`** — a handler drives random interleavings of all four
  swap modes, deviation-closing arb, third-party LP add/remove, oracle drift/breakage/healing on
  all three legs (ETH, GBP, NAV), time warps into staleness, pause toggles, and
  valid-by-construction `setFeeParams` retunes. Oracle state is driven by `vm.etch`ing settable
  feeds over the real Chainlink proxy addresses (journaled EVM state — robust under invariant
  snapshot/restore, unlike `vm.mockCall`). Invariants: (1) every swap's PM-event fee equals an
  independent FeeMath/OracleLib recomputation; (1b) a transient-cache canary proving the hook's
  per-tx fair cache never leaks across transactions; (2) fee ∈ [minFee, maxFee] of the params
  active at swap time; (3) stock-Quoter parity to the wei on every swap + quoter never fails while
  the swap succeeds; (4) funding-pre-validated swaps never revert regardless of oracle state;
  (5) fallback swaps pay exactly `fallbackFee`, nothing priced live off a verifiably bad oracle;
  (6) the hook holds zero tokens; (7) slot0.lpFee stays 0 + PM/hook event coherence.
- **`test/POLCompounderInvariants.t.sol`** — fee accrual (swaps + donations, third-party LP
  coexisting), compounds, owner withdraw/sweep/tolerance, oracle drift/brick/heal. Invariants:
  principal only decreases via owner withdraw; position liquidity always equals the tracked
  expectation (nothing else can move it); compound never touches external balances; a successful
  compound leaves `pendingFees() == (0,0)`; only the two declared reverts ever occur; no PM
  ERC-6909 claims ever stranded.
- **`test/base/SettableFeed.sol`** — the shared etchable feed mock.

Both are picked up by `make test-invariant` and excluded from `make test`/coverage via the
existing `Invariants` name-matching (no Makefile/foundry.toml changes). One test-side gotcha
rediscovered live: handlers calling `PoolSwapTest` need a payable `receive()` (native refund).

## Security review findings (fresh pass, two independent reviewers)

**Hook + libs + deploy scripts** — no must-fix. Verified sound: exact flag/permission composition
(incl. `OVERRIDE_FEE_FLAG` collision-freedom against v4-core sources), transient-slot scheme
(sentinel reservation, `_swapMeta` packing, beforeSwap/afterSwap atomicity incl. reentrancy and
multi-pool), orientation/sign convention independently re-derived, FeeMath totality
(incl. `int256.min` and `EXCESS_CLAMP`), `checkParams` completeness, OracleLib guarded reads and
composition overflow-freedom, pool-price totality at the sqrt-price extremes, manipulation
economics (nothing beyond the documented trade-splitting), deploy script pre-flight/post-asserts
and address table byte-for-byte, `_isqrt`/init-price math over the whole corridor, Ownable2Step.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| F-1 | should-fix | `OracleLib.sol` `_readFeed`: `uint80` decode is a residual revert path (see Verdict) | **Fixed** (2026-07-04) — full-word decode + red/green-verified `test_dirtyUint80WordsStillReadable` |
| F-2 | should-fix (runbook) | Pool-init front-running had no documented recovery | **Fixed** — DEPLOY.md §3 recovery procedure added (dust-swap reprice, re-check <10 bps before funding) |
| F-3 | info | Returndata gas-bomb from a hostile feed (soft DoS) | Registered; resolves together with F-1 if fixed via bounded-copy assembly (optional) |
| F-4 | info | No runtime plausibility corridor on composed fair (mis-scaled feed ⇒ maxFee-clamped miscosting, never blocking) | Accepted for v1; v2 candidate (fifth FallbackReason) |
| F-5 | info | `renounceOwnership` remains one-step (OZ) | Multisig-discipline item; registered |
| F-6 | info | Hook events carry no `poolId`; hostile pools on the same hook could confuse monitoring | Registered — monitoring joins on the adjacent PM `Swap` log (which has it) |
| F-7/F-8 | nit | `paused` slot packing; InitWethPool hardcodes staleness windows | Registered; cosmetic |

**POLCompounder** — no must-fix. Verified sound: unlockCallback gating and full flash-accounting
flow against v4-core (poke/bootstrap, signed-delta availables, settle/take, `CurrencyNotSettled`
backstop), `_fits` rounding vs `Pool.modifyLiquidity` round-up across boundary states,
`_checkExecPrice` on actual fill deltas both orientations, structural rebalance cap (worst case =
wrong-side surplus of fees+dust × tolerance; keeper compromise = timing only, non-amplifying),
withdraw/sweep separation (sweep cannot reach in-pool principal), constructor cross-checks, and a
claim-by-claim cross-check of all six `SECURITY_WETH_WSTGBP.md` sections against their backing
tests (all backed; two doc-nit overstatements noted in the register).

| # | Sev | Finding | Disposition |
|---|---|---|---|
| C-1 | should-fix (runbook) | Migration order funded POL while a hot deployer EOA was owner | **Fixed** — DEPLOY.md appendix reordered: ownership reaches the Safe BEFORE funds move (or deploy with `_owner = Safe`) |
| C-2 | should-fix (docs) | `SECURITY_WETH_WSTGBP.md` had zero compounder coverage | **Fixed** — §7 (custody threat model) added |
| C-3 | info | `setStaleness` unbounded (owner foot-gun, not escalation) | Registered in §7 + ROADMAP (bound it if/when compounder is adopted) |
| C-4 | info | Banned-compounder behavior verified in source (principal recoverable via `take`) but untested | ROADMAP item for compounder adoption |
| C-5 | info | Zero-fill rebalance reverts whole compound (keeper-retry DoS, loses nothing) | Accepted (declared-revert class) |
| C-6 | info | `_fits` unit-decrement loop unbounded for pathological constructor ranges | Accepted (owner-vetted constructor params); loop since extracted to `_fitLiquidity` and unit-covered incl. the lemma that the live flow never enters it |
| C-7/C-8/C-9 | nit | Fee-recirculation wording, "22-test" count (fixed), minor coverage gaps (skip-reason-3 assert, flipped-ordering compounder) | Count fixed in DEPLOY.md; rest registered |

## Why this and not a standard 30 bps pool

The sim (`sim/RESULTS.md`, offline replay: trend-2021 @ 80 gwei and chop-2024 @ 8 gwei, POL 1M
wstGBP, static ±75% range) ran **static-30bps as an explicit baseline. It ranks 10/14 (trend) and
9/14 (chop).** The shipped config (slope 0.5×, bases 30/5) beats it on POL PnL vs a 50/50 HODL
benchmark by **~834 bps in trend** (+572.4 vs −261.3) and **~918 bps in chop** (+3378.3 vs
+2459.8).

- **The toxicity surcharge is the entire edge.** A static fee charges arbitrageurs (informed,
  adverse-selection flow — the flow that costs LPs money) the same as organic flow. This hook
  surcharges only deviation-*closing* flow beyond a 10 bps band, recapturing LVR; the surcharge is
  ~60–70% of total fee revenue at slope ≥ 0.5. Notably, the directional bases *without* the
  surcharge (slope=0 configs) **lose to static 30 bps** — asymmetric bases alone under-tax
  informed flow. So the surcharge isn't an add-on; it's the justification.
- **Directional asymmetry (30/5) is structural, not a tuning whim**: mint side 30 bps = redeem
  side 5 bps + the wrapper's 25 bps redeem leg, making the WETH-pool round trip band-symmetric
  with the backstop venue — neither direction of the arb loop is privileged.
- **The downside is bounded at exactly "a standard 30 bps pool."** Any oracle failure — or an
  owner pause — degrades to a flat 30 bps fee with swaps never blocked. The worst case of this
  hook IS the alternative it's being compared against.
- Honest caveats: the sim is an offline replay with a single-fill arb agent (the 1.0× slope
  configs that rank #1 raw are inflated by exactly the revenue trade-splitting erodes — why 0.5×
  ships); JIT can capture ~8% of a surcharge (bounded by the fee paid, monitored); the ±75% static
  range spent ~29% of the 2021 trend out of range (a POL range-width policy question, not a fee
  question — and the actual treasury bracket is chosen separately, cable-hardened).

## Carried-forward gap register (known, accepted, documented)

| Gap | Status |
|---|---|
| Trade splitting not fee-neutral (slices → schedule integral) | Accepted v1; sim used integral revenue as the conservative case; v2 candidate |
| JIT capture (~8% of a surcharge measured; bounded by the fee paid) | Accepted v1 by design; Dune queries watch fee distribution |
| Cold gas 66,397 vs spec's 40k | Waived with numbers per spec allowance (~35k irreducible oracle proxy reads); 80k ceiling enforced in test |
| Cross-transaction same-block cache behavior untestable in-harness | Mitigated: the new invariant suite's cache canary empirically pins per-tx reset under the fuzzer; true same-block multi-tx remains untestable in foundry |
| NAV leg has no on-chain staleness signal | Off-chain monitoring (`check_feeds.sh` every 15 min + Dune fallback alerts); documented in OracleLib/README |
| `POLCompounder` lcov branches 30/33 (lines/funcs 100%) | Residual lcov branch artifacts; compounder is NOT in the launch path; pre-adoption items in ROADMAP |
| Venue outside the backstop audit scope | External audit required before POL scale-up (unchanged) |

## Pre-deploy checklist (DEPLOY.md §0, status today)

- [x] `make test` green at the rev (264/264) — invariants: backstop suites green per prior runs;
      NEW weth suites green (this report)
- [x] Feed heartbeats/identities re-verified live today (ages 1204s / 46144s inside 4500/90000
      windows; both 8-dec, canonical descriptions)
- [x] `sim/RESULTS.md` == `simParams()` (mechanically re-verified)
- [x] Fork rehearsal end-to-end (anvil): deploy → init at 0 ppm → re-run reverts
- [x] **F-1 applied** (full-word decode; red/green regression test; 267/267 after; snapshot
      regenerated; OracleLib coverage still 100% all metrics; invariant suite re-smoked green)
- [ ] Commit + push `1b03a01` and this pass's work (incl. the F-1 fix); record
      `git rev-parse HEAD` as the deploy rev; tree clean at that rev
- [x] `make test-invariant` green **on an authenticated archive RPC**: 21/21 across all 4 suites,
      run against the exact tree state that deployed (2026-07-04)
- [ ] Risk acceptance recorded: first-party review only until the venue's own audit; launch POL
      small/capped (DEPLOY.md §0)
- [ ] Deployer funded (gas only), keystore + Etherscan key ready; init follows deploy
      immediately (or private bundle) per DEPLOY.md §3
- [ ] After deploy: §5 verification (Quoter probe, `check_feeds.sh`, one small swap each
      direction), §6 monitoring activation (Dune decode submission, hourly fallback alert, cron)
