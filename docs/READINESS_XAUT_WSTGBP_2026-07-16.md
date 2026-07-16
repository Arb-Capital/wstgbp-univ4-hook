# XAUT/wstGBP Dynamic-Fee Venue — Production-Readiness Report (2026-07-16)

Scope: `src/xaut/` (`XautWstGbpHook`, `FeeMath`, `OracleLib`), `script/DeployXautHook.s.sol`,
`script/InitXautPool.s.sol`, the `test/XautWstGbp*` suites, `sim/goldsim/`, `monitoring/`, and the
`DEPLOY.md` XAUT runbook section (§X0–§X6). Reviewed on the working tree of 2026-07-16 (the venue
is one uncommitted change-set on top of `4a1c43a` — see verdict condition 1).

**"Production-ready" here means: ready to execute the launch path in `DEPLOY.md`'s XAUT section.**
It is NOT an audit substitute — the venue is outside every existing audit scope (`AUDIT_SCOPE.md`
carve-out) and is intended to be audited ALONGSIDE `src/weth/` + `src/usdc/` in the deferred
single-engagement scope.

## Verdict — GO, with four conditions

1. **Commit + push this change-set before broadcasting** (the whole venue is uncommitted work on
   top of `4a1c43a`); record `git rev-parse HEAD` as the deploy rev; tree clean at that rev. (The
   WETH venue's deployed-from-uncommitted-tree lesson, promoted to a hard condition at the USDC
   pass and carried here. Operator action.)
2. **Re-run `make test-invariant` on the authenticated archive RPC at the final commit** if
   anything touching hook/test code changes after this pass (this pass's run — 37/37 across all
   6 suites — was on the build tree; the subsequent changes are the `simParams()` stamp,
   scripts/docs/monitoring text, and sim-side files only, no hook or invariant code, so the run
   remains representative — but the gate belongs to the deploy rev, per DEPLOY.md §X0).
3. **Risk acceptance recorded at launch:** first-party review only until the venue's external
   audit (bundled with the weth/usdc deferred scope); launch POL small/capped; scale-up gated on
   that audit.
4. **Gold-leg data caveat recorded:** the sweep's gold leg is **PAXG/USDT** (Binance), the
   documented fallback source — tokenized gold tracking spot within ~20–50bps, its own basis
   wobble, 24/7 trading (which matches the Chainlink XAU/USD feed's verified weekend behavior
   better than spot-gold bars do). The Dukascopy true-XAU/USD confirmation re-sweep is queued
   (cache still filling under that source's per-IP throttling); if it lands before deploy and
   moves the winner, re-stamp per DEPLOY.md §X0. Fee params are owner-retunable live either way.

## Evidence — fresh runs (2026-07-16, this pass)

| Check | Result |
|---|---|
| `forge build` + `forge fmt --check` | clean (via-IR, solc 0.8.28) |
| `make test` (full fast suite, mainnet fork) | **456/456 passed** (34 suites, all four venues; re-run AFTER the `simParams()` stamp) |
| Production-params smoke at the stamped winner | `test_productionSimParamsBaseFees` + suite: 48/48 in `XautWstGbpHookTest` — shipped literals `checkParams`-valid on-chain, both bases charge at ~zero deviation, production staleness windows accept fresh feeds |
| `make coverage` (`src/xaut/`) | **100% all metrics** — `XautWstGbpHook` 61/61 L, 71/71 S, 11/11 B, 7/7 F; `FeeMath` 21/21, 49/49, 6/6, 3/3; `OracleLib` 28/28, 50/50, 11/11, 4/4 |
| `make sim-test` | **47/47 passed** (33 wethsim/cablesim regression-green + 14 gold: bars/costs/agents + goldsim acceptance incl. rest-at-−basis and conveyor-alive-on-static-5) |
| Gas suite | warm overhead **9,642** (<10k target MET), cold **66,105** (<80k WETH-shaped ceiling — TWO Chainlink proxy chains vs USDC's one); regime-pinned methodology (live gold ~$4k vs fixture $2,625 would otherwise measure the cap-saturated surcharge path); `snapshots/XautWstGbpGasTest.json` regenerated this pass |
| `make test-invariant` (authenticated RPC) | **37/37 across all 6 suites** (backstop 4, adapter 3, weth 8, POL compounder 6, usdc 8, **xaut 8**), 596s, zero failures/RPC aborts |
| `make deploy-xaut-hook-dry` (live mainnet state) | pass WITH the stamped winner params — pre-flight decimals (XAU/USD 8, GBP/USD 8, XAUT 6), composed live fair inside [500e18, 20_000e18], flags 0x20C0 mined, all post-deploy asserts (~2.43M gas est.) |
| Anvil fork rehearsal (full two-step + re-run guard) | pass — deploy at the mined address, **init broadcast at 0 ppm deviation** (tick −356,211; fair 2,946.17 wstGBP/XAUT at live gold ~$3,993 / cable 1.348 / NAV 1.00537), **re-run of init reverts `PoolAlreadyInitialized()` (0x7983c051)**; rehearsal broadcast/cache artifacts deleted |
| `monitoring/check_feeds.sh` (live, incl. the new XAU probe) | all ok — XAU/USD answer $3,992.98 age 1,351s (<90,000), GBP/USD 1.34807 age 3,931s, `navprice()` 1.00537e18 nonzero; ETH/USD + USDC/USD legs (sibling venues) also healthy |
| Feed/token identity (live `cast`) | XAU/USD `0x214e…a0D6` `description()` = "XAU / USD", 8 dec; XAUT `0x6874…2F38` `symbol()` = "XAUt", `decimals()` = 6 |
| Params match | `sim/RESULTS_XAUT.md` "Recommended starting FeeParams" == `DeployXautHook.simParams()` — all ten fields identical (stamped this pass, re-diffed) |
| Empirical XAU/USD weekend-round check | Chainlink XAU/USD **heartbeats THROUGH the weekend close** (~24h cadence, ±0.1% drift; weekend 07-11/12 rounds 8256→8259 on aggregator `0x0e3d…f903`): max observed gap 86,460s vs the 90,000s window ⇒ ~59 min margin — **routine weekend fallback NOT expected**; a late heartbeat degrades fail-soft to the flat `fallbackFee` |
| Frozen-tree invariant | `git diff --stat -- src/weth sim/wethsim` empty — the deployed WETH venue and its sim untouched by this track |

## The sweep and its winner (the pass's headline decision)

`sim/RESULTS_XAUT.md` (goldsim, 108 dynamic configs + static-5/static-30 baselines × 3 regimes
{shock-2022 gilt×gold-drawdown, calm-2024, rally-2025} × organic {0,1}/hr, house-take objective,
conveyor-dead override; basis 50bps on the ranking cells):

- **Winner = (50,10)bps bases, threshold 1000 ppm, slope 1.0×, cap 100bps, minFee 50** — best
  worst-case rank across all six cells (**max rank 7**; next-best 9). The (50,10) wide-edge base
  pair — added to the grid because gold-in-GBP vol ≈ 6× cable — earns its keep everywhere.
- **The threshold sits deliberately BELOW the ~5000 ppm token–metal basis** — the opposite of the
  pre-sweep intuition (the placeholder had pre-widened it to 5000). Why it wins: the redeem
  conveyor reads deviation-*opening* at the rest state and is surcharge-immune under ANY
  threshold (SECURITY §6, asserted on-chain), so a sub-basis threshold converts resting
  mint-side flow into surcharge revenue without starving the conveyor. Priced trade-off: a wider
  mint-side no-arb band (anchor-cell band p50 ~3,900 / p95 ~12,400 ppm) — documented in
  SECURITY §6 consequence 3.
- **Basis fragility: none found** — winner house take stays in a narrow band across basis
  {0, 25, 50, 100} bps and conveyor volume *rises* with the basis (RESULTS basis table). The
  basis being an estimate is therefore not a load-bearing assumption of the param choice.
- **Gas sensitivity:** conveyor volume decays ~1.6× from 0.2 → 25 gwei but never dies (RESULTS
  gas table) — same economics observation as the USDC venue, sharper here because recycling is
  two legs (tGBP → USDC → XAUt).
- **Conveyor alive in all six cells** (zero dead flags for the winner; ~50% of the static-5
  control's redeem volume in the anchor cell).
- Honest caveats carried in the RESULTS file: the single-fill arb agent overstates top-of-ramp
  surcharge revenue (splitting erodes toward the schedule integral — weth-verified mechanism);
  organic-0 house take is negative for ALL configs in calm cells (the winner minimizes the
  bleed; organic flow flips the sign venue-wide).

### Sweep data provenance (condition 4 detail)

Gold leg PAXG/USDT via `sim/data/fetch_binance_gold.sh` (sha256 stamps in RESULTS); GBP legs are
the clean Dukascopy cable CSVs. Checked and REJECTED: Binance GBPUSDT (depegged ~5% after Binance's
GBP rails closed mid-2023). Kept deliberately: the real 2024-04-13 PAXG weekend squeeze (+25% in
~90 min, metal markets closed) in calm-2024 — it IS this venue's weekend-dislocation stress.
**Found the hard way this pass:** Binance monthly kline zips switched timestamps to MICROSECONDS
starting 2025-01 — raw µs made the loader forward-fill ~1000 synthetic bars per real one (~10 GB
per rally-2025 sim job, OOM-killing the sweep and, via systemd-oomd, the operator's terminal).
Fixed in the fetch script (normalize to ms pre-sort) + documented in `sim/data/README.md`;
`goldsim/sweep.py` also gained a worker cap (`GOLDSIM_WORKERS`, default cpu−2).

## Post-pass review findings (2026-07-16, operator review after the param stamp)

| # | Sev | Finding | Disposition |
|---|---|---|---|
| P-1 | high | Documented sim workflow could not reproduce the sweep on a clean checkout: `make sim-data-gold` fetched Dukascopy `xauusd_*` while the active `sweep_xaut.json` points at Binance `paxgusd_*`, so DEPLOY.md §X0's reproduce command failed | **Fixed** — `sim-data-gold` now runs `fetch_binance_gold.sh` (the ACTIVE source); Dukascopy confirmation moved to `sim-data-gold-xau`; DEPLOY.md §X0 reproduce line now also names `sim-data-cable` (the shared GBP legs); `sim/data/README.md` maps both targets |
| P-2 | med | Contract NatSpec contradicted the shipped params: `XautWstGbpHook.sol` and `OracleLib.sol` still said the threshold is "sized above the basis" (the pre-sweep placeholder stance); the user guide's TL;DR also said resting trades pay base only | **Fixed** — both NatSpec blocks and the TL;DR now state the sub-basis threshold + the direction split at rest (XAUT-in base only; wstGBP-in base + surcharge, ~0.9% all-in); comment-only change, `forge build` + full hook suite re-run green |
| P-3 | med | The Dune histogram's `surcharge_regime` used `abs(deviation) > threshold` alone, ignoring swap direction — at the −basis rest state it mislabeled XAUT-in swaps (which pay base only) as surcharge-regime | **Fixed** — the query now decodes `mintSide` (topic1) and computes direction-aware `surcharge_paying = (d > thr AND redeem-side) OR (d < −thr AND mint-side)`, mirroring `FeeMath.surchargePpm`; dune README row updated |

## Carried-forward gap register (known, accepted, documented)

| Gap | Status |
|---|---|
| **Token–metal basis** (pool rests at d ≈ −5000 ppm; feed prices bullion, pool trades XAUt) | The venue's signature risk, resolved BY the sweep rather than assumed away: sub-basis threshold chosen on evidence (above); rest state observable in the `SwapFee` deviation stream; owner retunes on a basis-regime shift; push-then-close at the rest state strictly loses (SECURITY §2/§6, asserted) |
| Weekend/holiday stale-fair + feed coarseness (0.3%/24h ⇒ chunky deviation steps) | Empirical weekend-round check this pass (evidence table): heartbeats continue through the close with ~59 min window margin; late heartbeat ⇒ fail-soft flat fallback; expect more fallback minutes than USDC regardless (monitoring: `xaut_fallback_minutes.sql`) |
| XAUt issuer risk (blacklist + `destroyBlockedFunds`, issuer proxy) | Accepted, same class as USDC's token risk: the fee-only hook never custodies; an issuer blacklist of the PoolManager would strand LP funds venue-wide — shared with every XAUt pool, not a hook defect (SECURITY §8) |
| Trade splitting not fee-neutral | Accepted v1 (weth-verified); slope 1.0× shipped anyway on the sweep's evidence, same reasoning as USDC (gas-bounded at conveyor notionals; SECURITY §1) |
| JIT capture bounded by fee paid | Accepted v1; spacing-60 makes one-spacing JIT ~0.6% wide (SECURITY §3) |
| Fixture params ≠ production params | Mitigated: production-params smoke imports `simParams()` (value-generic; re-run green after the stamp this pass) |
| 8-entry `FallbackReason` renumbers vs USDC's 5-entry | Documented three places incl. the dune README three-venue table; off-chain decoder copy-paste risk only |
| Reason-code misattribution at absurd answers (A-1); events lack poolId (A-2); protocol-fee composition (A-3) | Inherited weth/usdc monitoring caveats, registered unchanged |
| PAXG-sourced sweep (condition 4) | Dukascopy true-XAU confirmation re-sweep queued; params owner-retunable live |
| Venue outside all existing audit scopes | External audit (deferred weth+usdc+xaut single engagement) before POL scale-up; launch POL small/capped |

## Pre-deploy checklist (DEPLOY.md §X0, status today)

- [x] `sim/RESULTS_XAUT.md` exists and its "Recommended starting FeeParams" ==
      `DeployXautHook.simParams()` (10/10 fields, stamped + re-diffed this pass)
- [x] Both feed heartbeats/deviations re-verified live today (XAU/USD 0.3%/24h, GBP/USD
      0.15%/24h ⇒ both windows 90,000s); XAUT `decimals()` = 6 re-verified
- [x] `make test` green at the stamped tree (456/456); sim suite green (47/47); coverage 100%
      on `src/xaut/`
- [x] Fork rehearsal end-to-end (anvil): deploy → init at 0 ppm → re-run reverts
      `PoolAlreadyInitialized()` (0x7983c051); rehearsal artifacts deleted
- [x] `make test-invariant` green on the authenticated archive RPC (37/37 across 6 suites;
      re-run at the final commit if hook/test code changes — verdict condition 2)
- [x] Empirical weekend-round check recorded (routine weekend fallback NOT expected)
- [ ] **Commit + push this change-set**; record `git rev-parse HEAD` as the deploy rev; tree
      clean at that rev (operator action — verdict condition 1)
- [ ] Risk acceptance recorded (verdict conditions 3 + 4)
- [ ] Deployer funded (gas only), keystore + Etherscan key ready; init follows deploy
      IMMEDIATELY per DEPLOY.md §X2 (same init front-run window as the sibling venues)
- [ ] After deploy: §X4 POL funding via the Uniswap UI (wide geometric bracket, down-side-wide —
      NAV ratchet AND a gold rally both consume the lower bound; small test add → probe swap →
      size), §X6 monitoring activation (Dune decode submission, xaut variants + the histogram's
      surcharge classification re-synced this pass to the winner: direction-aware
      `surcharge_paying` mirroring `FeeMath.surchargePpm` at the 1000 ppm threshold),
      Etherscan verify
