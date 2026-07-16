# ROADMAP / TODO — tGBP/wstGBP v4 backstop hook

Durable backlog so nothing is lost across context clears. Keep this in sync as work lands.
See `CLAUDE.md` for the full design; this file is just status + what's left.

Status: `[x]` done · `[ ]` todo · `[~]` partial/in-progress

**Deployed to mainnet 2026-06-28** — hook `0xfE36B48c9c0240991E4CEf006a2445F2ff524888`, router
`0x21734507fDca48A3b4e8C496280b63a37D3bD0C8`, quoter `0x9B409f87aeaADBE912632b1E4de855B6aFCc71Ee`,
adapter `0xBE402d34f31133B1Dc00277f24F8ce2d975CBe23`; hook helper (2026-07-03)
`0x4F93a2E29B0AA75875Ab922d780B6dc59b415B6A`. Full table in `README.md` / `AUDIT_SCOPE.md` /
`CLAUDE.md`. Remaining: off-chain aggregator/CoW listing + the CoW hook dapp (below).

## Track (2026-07-04): WETH/wstGBP dynamic-fee venue (`src/weth/`)

Second, independent hook per the plan in
`~/Insync/brian@brianmcmichael.com/Dropbox/Work/ARB/weth-wstgbp-v4-hook-plan.md`: fee-only
dynamic-fee `WethWstGbpHook` (directional base 30/5 bps + toxicity surcharge vs Chainlink-composed
fair value, never-revert fallback, per-tx transient cache) + keeper-compounded `POLCompounder`
holding the POL position directly in the PoolManager. Owner multisig
`0x846a655a4fA13d86B94966DFDf4D9a070e554f7c` (Ownable2Step; env-free, baked in deploy script).
All quantities ppm. See the README section "WETH/wstGBP dynamic-fee venue".

- [x] Phase 0 scaffold: vendored `IAggregatorV3`, feeds verified (ETH/USD 3600s/0.5%,
  GBP/USD 86400s/0.15%, both 8 dec), README address table + conventions
- [x] Phase 1 `FeeMath` + `OracleLib` + unit suites — 100% all metrics, fuzz bounds
- [x] Phase 2 hook + fork suite (31) + flipped-ordering suite (4) — 100% hook coverage,
  both-oracles-bricked swap completes at fallbackFee
- [x] Phase 3 stock-Quoter parity (exact to the wei, all regimes incl. fallback/paused) + gas
  snapshots — warm 9,664 (<10k target MET); cold 66,397 (spec's <40k **consciously waived**:
  ~35k is irreducible Chainlink+navprice proxy reads; 80k regression ceiling enforced)
- [x] Phase 4 adversarial suite (5) + `SECURITY_WETH_WSTGBP.md` + AUDIT_SCOPE out-of-scope note.
  Notable verified finding: trade splitting is NOT fee-neutral — slices converge to the linear
  schedule's integral (~2x cheaper at the cap); documented as the economic floor, v2 candidate
- [x] Phase 5 Python replay sim (`sim/`, stdlib-only) + sweep → `sim/RESULTS.md`. Recommendation
  = (30,5) bases + slope 0.5x (the working defaults); trend-2021 spent 29% of bars out of the
  ±75% range (POL-width policy note); every slope>0 config beats both baselines in both regimes
- [x] Phase 6 `DeployWethHook.s.sol` (multisig owner from construction; dry-run validated on fork)
  + `InitWethPool.s.sol` (compounder-bootstrap POL seed) + Makefile targets + `DEPLOY.md` runbook
  + `monitoring/dune/*.sql` (real topic0s) + `monitoring/check_feeds.sh` (live-validated)
- [x] Phase 7 `POLCompounder` (direct PoolManager locker, single-unlock compound, oracle-bounded
  rebalance) + fork suite (23) + keeper runbook (`DEPLOY.md` §7)
- [x] Production-readiness pass (2026-07-04, `docs/READINESS_WETH_WSTGBP_2026-07-04.md`): all
  suites re-run green at `1b03a01`, coverage re-verified, deploy+init rehearsed end-to-end on an
  anvil fork (0 ppm init deviation), feeds live-verified, fresh two-reviewer security review
  (no must-fix; the one should-fix — OracleLib uint80-decode residual revert path, F-1 — was
  applied the same day, see the [x] entry below),
  NEW stateful invariant suites `WethWstGbpHookInvariants` (8 invariants, etched settable feeds,
  independent fee mirror + transient-cache canary, stock-quoter parity per swap) and
  `POLCompounderInvariants` (custody/principal/declared-reverts), + 2 stateless edge tests
  (staleness-window retune → fallback; two live pools price their own deviation);
  DEPLOY.md hardened (init-frontrun recovery, compounder migration ownership-before-funds);
  SECURITY_WETH_WSTGBP.md §7 (compounder threat model) added

Decision (2026-07-04, funding UX): POL is funded **via the Uniswap UI** from the treasury Safe
(PositionManager NFT; UI path pinned by `test/WethWstGbpPositionManager.t.sol` against the real
mainnet PosM incl. the chosen treasury bracket ticks −88,920/−69,360). `InitWethPool.s.sol` is init-only
(no funds); `POLCompounder` moved out of the launch path to optional automation (DEPLOY.md
appendix) — the fire-and-forget requirement beat keeper infra; never-compounding drag ≈ 0.5%/yr at
10% fee APR vs the measured fee-policy alpha. Range bounds are GBP-native (cable drift documented
in README); cable-hardened bracket FINALIZED 2026-07-04 at $1,500–$8,000 across cable 1.10–1.45,
efficiency-first (ticks −88,920/−69,360, ~2.59×; NAV-drift re-range trigger in DEPLOY.md §4;
supersedes the $1,400–$10,000 draft — PosM UI-rehearsal test updated to the chosen ticks).

Open (post-implementation):
- [x] OracleLib F-1 should-fix APPLIED (2026-07-04): `latestRoundData` decoded as five full words
      (was `(uint80, …, uint80)` — dirty high bits in the ignored words could revert in the hook's
      frame and brick swaps). Red/green-verified via `MODE_DIRTY_WORDS` +
      `test_dirtyUint80WordsStillReadable`; 267/267 after; snapshot regenerated (read got ~0.8k
      cheaper); coverage still 100% on OracleLib
- [ ] POLCompounder pre-adoption items (only if/when adopted): ban-list recovery fork test
      (banned compounder: compound bricks, withdraw-to-third-party succeeds), bound `setStaleness`
      (nonzero, sane ceiling) or accept as owner foot-gun, flipped-ordering compounder test
- [x] Mainnet deploy 2026-07-04: hook `0xe5F6…E0c0` + pool init (block 25463628, 0 ppm) — DONE.
      NOTE: deployed from an uncommitted tree ahead of the commit gate; the deploy rev must be the
      very next commit (include the new `broadcast/DeployWethHook.s.sol/1/` +
      `broadcast/InitWethPool.s.sol/1/` records, matching repo convention)
- [ ] Post-deploy: ~~verify~~ (DONE 2026-07-04, Etherscan "Pass - Verified"), ~~first funding~~
      (DONE 2026-07-04: NFT #334867, ticks −88,920/−69,360, 745.96 wstGBP + 2.82 WETH, tx
      `0xdb3066…cd704`); remaining: real-size add if the first was a test tranche, custody
      decision (NFT currently on the deployer EOA — transfer to the Safe if treasury POL),
      §6 monitoring fire-and-forget tier (Dune decode + hourly sustained-fallback alert ONLY;
      no cron — the position needs no attention by design), yearly NAV re-range review
- [ ] Aggregator/routing submissions (1inch/Odos/0x/CoW) with the quoter-parity results; confirm
  the Uniswap routing API picks up dynamic-fee hook pools (spec §7). The 1inch leg is drafted:
  `docs/AGGREGATOR_LISTINGS.md` §2 bundles the WETH+USDC hook-whitelist ask (fee-only hooks,
  stock-quoter-exact) into the backstop-adapter outreach (same ask mirrored for Odos §3, comms
  permitting)
- [ ] Announce fee semantics publicly (searchers must be able to model the band)
- [ ] External audit of `src/weth/` before/alongside mainnet POL scale-up (own scope doc TBD;
  see AUDIT_SCOPE.md out-of-scope note + SECURITY_WETH_WSTGBP.md). **Deprioritized 2026-07-11
  (operator stance): not a scale-up gate for now — the venues are serving live MEV flow un-audited;
  revisit when POL is materially larger.**

## Track (2026-07-05): wstGBP/USDC dynamic-fee venue (`src/usdc/`)

Third venue: `UsdcWstGbpHook`, a clone of the WETH venue re-parameterized for the near-stable cable
pair. Motivation (on-chain readout of the existing static 5bps wstGBP/USDC pool `0xbe0f…bb10`,
2026-07-01→05): 15/16 swaps were USDC-in buys exiting via `wstGBP.redeem`; the pool rests at the
burn floor and each weekly NAV ratchet re-arms the conveyor (~11.6bps arb edge vs burn recaptured
at only 5bps). The conveyor is *protocol revenue* (25bps mint+redeem spread per round trip) — the
hook's job is to recapture the residual arb skim into POL without killing the flow.

Key deltas vs `src/weth/` (full plan in the session plan file; design decisions final):
**single-feed fair** `1e8·WAD·WAD/(gbpUsd·navprice)` wstGBP-per-USDC (USDC assumed $1.00 — depeg
invisible on-chain; accepted, monitored off-chain, owner pause is the mitigation); **USDC_UNIT=1e6**
pool-price constant (the entire 6-decimal fix); 9-field `FeeParams` (single staleness window);
5-entry `FallbackReason` (reason codes RENUMBER vs weth — see monitoring/dune/README.md);
tickSpacing 1; **no POLCompounder**; fee params from a NEW cable-vol sim (`sim/cablesim/`,
house-take objective = protocol spread × conveyor volume + pool fees − LP LVR, arb participation
constraint) — the WETH params do NOT transfer. `src/weth/` and `sim/wethsim/` are frozen (deployed
venue): zero edits on this track.

- [x] Phase A0 scaffold: `src/usdc/` tree, vendored `IAggregatorV3`, ROADMAP/CLAUDE pointers
- [x] Phase A1 `OracleLib` (single-feed, 1e6) + `FeeMath` (9-field) + unit suites (recomputed
      oracle vectors; FeeMath pins the SAME `sim/tests/feemath_vectors.json`) — 100% all metrics
- [x] Phase A2 `UsdcWstGbpHook` + `UsdcWstGbpForkBase` + hook fork suite (33) + flipped-ordering
      suite (4) — 100% hook coverage; real-USDC `deal` works via stdStorage
- [x] Phase A3 stock-Quoter parity (8, exact to the wei incl. fallback/paused + cross-regime
      fuzz) + gas suite — warm 9,604 (<10k MET), cold 46,814 (<70k ceiling; one Chainlink chain
      vs weth's two) + COVERAGE_SKIP + snapshot
- [x] Phase A4 adversarial suite (5: splitting integral −45%, push-then-close −15.09 wstGBP, JIT
      ~8% bounded, no-cliff, fallback-consistency) + PosM UI-shape suite (2, incl. the tight
      spacing-1 bracket) + `UsdcWstGbpHookInvariants` (8 invariants green) +
      `SECURITY_USDC_WSTGBP.md` (incl. USDC-depeg accepted-risk §6) + AUDIT_SCOPE note
- [x] Track B cable sim: Dukascopy fetcher + `.bi5` stdlib decoder (3 regimes fetched &
      validated: gilt-2022 low 1.036 ✓), `sim/cablesim/` (weekly NAV *steps*, Chainlink
      0.15%/24h deadband model, house-take objective, conveyor-dead flag, band-edge arb),
      27 sim tests incl. the acceptance anchor (static-5 reproduces the observed conveyor).
      Sweep run 2026-07-05 → `sim/RESULTS_USDC.md` → `simParams()` = **(30,5)bps, thr 1000,
      slope 1.0x, cap 60bps, minFee 50, fallback 3000** (robust worst-case-rank winner, max
      rank 4/74 across all 6 cells; ZERO conveyor-dead configs; LP PnL flips −119→+539 vs the
      static-5 control at >2x house take). Findings: (a) the dynamic equilibrium rests ~53bps
      below fair — beyond every candidate threshold, so the threshold axis is cosmetic here;
      (b) slope 1.0x kept (unlike weth's 0.5x demotion): splitting is gas-bounded at conveyor
      notionals and 0.5x ranks 16–23 in trend-2025; (c) ramp-up: from start-at-fair the
      conveyor arms only once accumulated ratchets exceed ~half-band+stable+fee ≈ 22.5bps;
      (d) at ≥1 gwei the conveyor is gas-marginal on 250k POL (gas table in RESULTS_USDC.md)
- [x] Phase A5 `DeployUsdcHook.s.sol` + `InitUsdcPool.s.sol` (spacing 1; corridor now
      0.4–1.0e18 after readiness finding B-1;
      dry-run green vs live mainnet, fair 0.7454e18; full anvil rehearsal: init deviation
      0 ppm) + Makefile targets + DEPLOY.md USDC section (incl. static-pool LP migration) +
      USER_GUIDE + README section + check_feeds USDC/USD depeg probe (live-validated) +
      `usdc_fallback_minutes.sql` + cross-venue reason-code table. simParams() carries a
      PLACEHOLDER banner until RESULTS_USDC.md lands
- [x] Production-readiness pass (2026-07-05, `docs/READINESS_USDC_WSTGBP_2026-07-05.md`):
      **GO with three conditions** (commit-before-broadcast; invariant gate re-run at the final
      rev if code changes; launch-POL risk acceptance). Fresh evidence: 353/353 fast tests,
      100% coverage on `src/usdc/`, **29/29 invariants across all 5 suites on the authenticated
      Alchemy RPC** (816s, zero aborts), snapshot-check stable, deploy dry-run + full anvil
      rehearsal at 0 ppm incl. the re-run guard (`PoolAlreadyInitialized`), live feeds + USDC peg
      healthy. Two independent reviewers, **zero must-fix**; 3 should-fix applied same-day:
      B-1 corridor tightened to FAIR_MAX 1.0e18 (the 1.5e18 corridor could NOT catch an
      orientation flip on a ~1:1 pair — inverse fair 1.342e18 passed), B-2 U4 efficiency figure
      8×→17×, B-3 check_feeds depeg path alert-contract fix (red/green verified). New this pass:
      production-params smoke tests (`test_productionSimParams*` — the shipped slope-1.0x literals
      proven checkParams-valid + correctly priced + quoter-exact on-chain), full static-pool
      poolId reconstructed and recorded (`0xbe0ffd8b…bf3bb10`, fee 500/spacing 10)
- [x] **Mainnet deploy + init 2026-07-05**: hook `0x09ff2EB94D873C6B4beFdE087362044a2B02e0c0`
      (flags 0x20C0, owner = multisig from construction), poolId
      `0x3413fca9ffa9fa33b15562b6a81e74368f9ec59fb80ea920fe6c6e9651685a5c` (init tick −273,385,
      sqrtPriceX96 91769425572216842075680, **0 ppm** deviation). Post-deploy verification passed
      same day: exact flag bits, all immutables, feeParams 9/9 == simParams, live deviation 0 ppm
      to the wei. Deploy rev `c11ae8e` (+ bracket doc commit); next commit must include the
      `broadcast/DeployUsdcHook.s.sol/1/` + `broadcast/InitUsdcPool.s.sol/1/` records (repo
      convention)
- [~] Post-deploy status (2026-07-05 EOD): ~~POL funding started~~ (NFT #335400, UI-snapped ticks
      −274,418/−271,562 ≈ 1.210–1.610 USDC/wstGBP, ~$8.0k in; final ~$2.1k tranche pending a
      tGBP buy → wrapper mint — mintcost == navprice today, zero premium);
      ~~static-pool migration~~ DONE (`0xbe0ffd8b…bf3bb10` liquidity = 0);
      deploy commit `7b36df7` pushed; ~~Etherscan verify~~ DONE; ~~Dune~~ DONE (decode submitted;
      queries 7893432/7893433/7893434/7893436 — see monitoring/dune/README.md). REMAINING:
      check_feeds cron activation (the depeg alarm IS the pause runbook trigger), finish the
      top-up (tGBP buy → mint → increase #335400); external audit joins `src/weth/`'s
      future scope; first conveyor trade expected only after ~2-3 ratchets (sim ramp-up finding —
      rest-at-fair needs accumulated deviation > half-band+legs before the arb arms)

## Decision (2026-06-03): ship the pure backstop, defer the hybrid

Only **one** hook goes to external audit / mainnet, and it is **`WsgemBackstopHook`** (pure backstop,
LP blocked). Rationale: it delivers the full product (infinite depth, tight ~25bps band) with a far
smaller audit surface, and best-execution against any *separate* third-party LP pool is handled at the
routing layer (Uniswap routing / UniswapX + arbitrage pinning a vanilla pool into the band) rather than
inside the hook. The `WstGBPHybridHook` (+ `WstGBPHybridQuoter` + its tests) — fully built, fixed
(M-01/L-01), and fork-validated — was removed from the tree and **preserved in git history at commit
`b7a5c5a`**; revive it only if in-pool LP demand materializes (it would need its own audit). Audit scope
is in `AUDIT_SCOPE.md`. This resolves the P2 item (6) consolidation question below.

## Decision (2026-06-12): monorepo + one generic adapter for non-v4 venues

To expose the same wstGBP `mint`/`redeem` to **CoW Protocol + DEX aggregators (Odos / LI.FI / Paraswap)**,
keep everything in **this repo** (monorepo) restructured around a shared core, and ship **one generic
adapter** rather than a bespoke contract per venue. Layout: `src/core/` (shared `WsgemWrap` lib +
interfaces), `src/v4/` (the hook + router + quoter, moved), `src/adapter/` (`WsgemDirectAdapter`).

Key finding: **"CoW Hooks" are user-attached pre/post *interactions* on an order, not a liquidity source.**
Giving solvers a route through `mint`/`redeem` is [route integration](https://docs.cow.fi/cow-protocol/tutorials/solvers/routes_integration)
(expose a standard swap contract + price discovery, propose on the CoW DAO forum). CoW, Odos, LI.FI, and
Paraswap all want the *same* `approve → swap` contract, so the on-chain artifact is one generic adapter;
v4 was the special case (settle-first + mined flags). Per-aggregator effort is **off-chain listing**.

- [x] **`src/core/WsgemWrap.sol`** — shared library (price, exact-in/out rounding, redeem balance-diff,
      ERC20 transfer), embedded `internal`. Hook + quoter + adapter all source their math here; cross-venue
      parity tests pin adapter == quoter == hook so they can never drift.
- [x] **`src/adapter/WsgemDirectAdapter.sol`** — ownerless, inventory-free, no pool. exact-in/out +
      Permit2 + view quotes; direction from `tokenIn`; same funding/cooldown/redeem-underpaid guards as the
      hook. Standard swap-then-settle — works with stock aggregator executors and CoW solver interactions.
- [x] Restructure into `src/core` + `src/v4` + `src/adapter` (behavior-preserving; 59 v4 tests unchanged).
      Fork base split into `ForkBase` (agnostic) + `WsgemForkBase` (v4) + `WsgemAdapterForkBase`.
- [x] Adapter test suites: `WsgemDirectAdapter.t.sol` (21 — feature/parity/hardening + aggregator-style
      approve+swap + Permit2 + every wrapper-gated revert + same-currency guard), `...Fuzz.t.sol` (6 —
      full-NAV-range parity, exact-out ceiling, round-trip-never-profits), `...Invariants.t.sol` (3 — no
      extraction, bounded dust, quoter==exec). Now **98 tests** total (91 fast + 7 invariant).
- [x] Deploy wiring: `DeployWstGBP.s.sol` also deploys the adapter, asserts its I-02 cached-feed parity, and
      checks it is not ban-listed. `deploy-dry` validated end-to-end on a mainnet fork.
- [~] **Off-chain listing (per venue, no Solidity):** step-by-step playbook now in
      **[`docs/AGGREGATOR_LISTINGS.md`](docs/AGGREGATOR_LISTINGS.md)** (2026-07-03): ParaSwap =
      self-serve `paraswap-dex-lib` PR — **submitted**: VeloraDEX/paraswap-dex-lib#1204 "Add
      wstGBP" (2026-07-03, awaiting review as of 2026-07-09); 1inch = business-channel request,
      full section added 2026-07-09 (Discord + business-portal support; no self-serve PR for
      Pathfinder sources; the same outreach bundles the WETH/USDC v4 hook-whitelist ask); Odos =
      **deprioritized 2026-07-09** — infra alive (API up, ~$280M/30d volume) but comms dormant
      (their only documented intake is an expired Discord invite; X silent since 2025-12; fallback
      channels in the playbook §3); LI.FI = automatic downstream (its
      exchange list is aggregators incl. paraswap/odos/1inch — verified via li.quest/v1/tools); CoW
      = forum proposal (`docs/COW_ROUTE_INTEGRATION.md`, drafted). Remaining: execute them. All
      reuse the *same* deployed adapter.
- [ ] **Repo rename** off `-univ4-hook` (e.g. `wstGBP-venues`) — name only, do when convenient.

## Decision (2026-07-03): CoW Hook Store dapp via an owner-bound helper

Second CoW track (complements route integration above, which serves *solvers*): a **Hook Store dapp**
lets CoW Swap *users* attach wrap/unwrap to any order (post-hook "wrap proceeds into wstGBP", pre-hook
"unwrap wstGBP to fund a tGBP sell"). Key mechanics (docs tracked in `CLAUDE.md`): hooks are
`{target, callData, gasLimit}` in appData, executed by the public untrusted **HooksTrampoline** — so the
target must be safe under arbitrary callers, and `WsgemDirectAdapter` cannot be it (pulls from
`msg.sender`; the trampoline holds nothing). Chosen design: **`WsgemHookHelper`**, owner-bound (anyone
may call; funds flow only owner→owner at oracle price, capped by the owner's allowance — bounded
griefing, no extraction) over the CoW-Shed proxy pattern (more moving parts, needs delegatecall helpers
anyway). The web dapp lives in a **separate repo** (ecosystem convention; keeps this repo pure Foundry).

- [x] `src/adapter/WsgemHookHelper.sol` — `wrapAll` (min(balance, allowance) sweep — post-hook proceeds
      vary with surplus), `unwrap` (fixed amount), `unwrapAll`; same sell guards as the adapter via
      `WsgemWrap`; `Wrap`/`Unwrap` events carry owner + executor.
- [x] Tests: `test/adapter/WsgemHookHelper.t.sol` (21 — quoter parity, sweep caps,
      arbitrary-caller-cannot-redirect-or-extract, wrapper-gated + defensive reverts) +
      `WsgemHookHelperFuzz.t.sol` (4 — NAV-range parity + forced-round-trip-never-profits).
- [x] Deploy: `script/DeployHookHelper.s.sol` (plain CREATE + I-02 + ban-list asserts);
      `make deploy-hook-helper[-dry]`. Dry-run validated on a mainnet fork. `AUDIT_SCOPE.md` updated
      (flagged as a post-review scope addition).
- [x] **Deployed to mainnet 2026-07-03** — `WsgemHookHelper` at
      `0x4F93a2E29B0AA75875Ab922d780B6dc59b415B6A` (block 25453990, tx
      `0xefbc09e193942a2dc3c35360d95e2339a9601d3ab66b594cb738ec1f924b08d9`, Etherscan-verified).
      Recorded in `CLAUDE.md` / `README.md` / `AUDIT_SCOPE.md`.
- [~] **Hook dapp repo** — `../wsgem-cow-hooks`: Vite+TS iframe app on
      `@cowprotocol/hook-dapp-lib` (manifest.json, wrap/unwrap modes via `context.isPreHook`,
      exact-approval flow, quotes off `act`/`pip`). Built; `src/config.ts` now carries the deployed
      helper address. Remaining: host at a stable URL (Vercel) + absolute manifest image URL.
- [ ] **E2E** via CoW Swap → Hooks → "My Custom Hooks" (paste dapp URL) with small mainnet orders both
      directions (tGBP is mainnet-only).
- [ ] **Hook Store listing PR** to `cowprotocol/cowswap`: `IFRAME` entry in
      `libs/hook-dapp-lib/src/hookDappsRegistry.ts`.
- [~] **Track B route-integration doc** — `docs/COW_ROUTE_INTEGRATION.md` drafted (interface, price
      discovery, gating, gas, compliance + forum-post skeleton); remaining: post it on the CoW DAO forum
      (the solver-side listing item above).

## Decision (2026-07-11): fourth venue — XAUT/wstGBP next, but depth + footprint first

Deep-dive on "what should the fourth v4 pool be to maximize velocity". Objective clarified with the
operator: **adoption / footprint** (wstGBP as money — venues, holders, organic flow, aggregator
presence), with meaningful POL capital available (~$50k–250k+). Verdict in two parts:

**1. Deepen + route before triangulating — velocity today is depth/gas/routing-bound, not
venue-count-bound.** Live reads (2026-07-11): backstop 19 swaps in its first ~2 weeks (£1–£200
notionals, mostly third-party MEV lockers); WETH antenna 42 swaps / ~1,152 wstGBP in week 1
(realized fees 5–90bps, avg ~49bps); USDC antenna 33 swaps / ~1,354 wstGBP in 6 days (avg ~33bps) —
each on ~$10k POL (velocity ≈ 0.15–0.2× TVL/week), i.e. ~3% of the sims' POL assumptions
(250k / 1M wstGBP). The arb bot logs both dynamic venues "venue unpriceable this pass". The USDC
sim already showed the conveyor gas-marginal at ≥1 gwei *even at 250k POL*, and organic flow at
1/hr worth ~20× conveyor-only house take (15,093 vs 724 USD per ~4 months). **Operator stance
(2026-07-11): audits are deprioritized for now** — the venues are already serving live MEV flow
un-audited, and scale-up proceeds at operator risk tolerance (supersedes the WETH track's
audit-before-scale-up gate). That leaves **capital deployment + routing as the only real
constraints**: the aggregator/CoW listings (in flight above) are the zero-capital lever, and depth
begets routing — aggregators only send organic flow through pools that quote competitively.

**2. Venue #4 = XAUT/wstGBP** (Tether Gold `0x68749665FF8D2d112Fa859AA293F07A622782F38`) — the
first on-chain gold/sterling market. Not because "uncorrelated" per se (correlation doesn't create
velocity; pair vol does): gold-in-GBP realized vol ≈ **37% annualized** (2026 H1) ≈ 6× cable, while
gold–crypto correlation is only ~+0.5 — a genuinely *new* deviation-event stream, where a BTC pool
(BTC–ETH corr ~+0.88) would mostly re-trade the WETH antenna's events. Fundamentals (verified
2026-07-11): 6 decimals (the USDC venue's `1e6`-unit pattern reuses directly), **no fee-on-transfer,
no pause** (blacklist + `destroyBlockedFunds`, issuer-upgradeable proxy — same accepted risk class
as USDC); $2.5B mcap, supply ~tripled in 9 months to 707,747 oz; ~$30M mainnet DEX TVL /
$5–10M/day volume incl. XAUt/USDC v4 ($3.6M — the arb-loop leg); routed by 1inch/CoW/Paraswap/Odos;
Chainlink **XAU/USD live** at `0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6` (0.3% dev / 24h
heartbeat, 8 dec). Hook = `src/usdc/` clone with two-feed fair `gbpUsd·nav/xauUsd` (wstGBP =
currency0: `0x57C3…` < `0x6874…`), `XAUT_UNIT = 1e6`.

Rejected for #4: **cbBTC/WBTC** (runner-up — ~10× gold's DEX depth, 30–50% vol, 1h feeds, but
+0.88 ETH-correlated = redundant event stream, zero novelty; keep as #5 candidate); **PAXG**
(token-specific PAXG/USD feed 0.5%/24h is its one edge; loses on global `pause()`, historical
fee-on-transfer machinery — removed today but reintroducible via proxy — and weaker aggregator
presence); **EURC / GBP stables** (EUR/GBP vol 2.3% = no antenna signal; no GBP stable has >$100k
on-chain liquidity — GBPT dead, GBPe mainnet supply 0, Agant GBPA not yet on-chain). Note: empty
**tGBP/XAUt + tGBP/cbBTC v4 shells already exist on-chain** (seen in the arb-bot's discovery
filter) — wrong pairing: tGBP misses the NAV-ratchet conveyor; pair wstGBP.

Named risks the XAUT venue must carry into its sim/security pass:
1. **Token–metal basis**: XAUt trades ~0.5% under Chainlink XAU/USD (the feed prices the metal, not
   the token) — a persistent rest-state "deviation" the fee model must tolerate (analogous to the
   USDC venue's ~53bps band-edge rest state); needs its own sweep (goldsim over XAU/GBP bars;
   Dukascopy has XAU/USD, `sim/cablesim/` infra reuses).
2. **Weekend/holiday stale-fair**: gold closes weekends like FX ⇒ fallback-regime windows (existing
   staleness-fallback design covers this; expect more fallback minutes than the USDC venue).
3. **Feed coarseness**: XAU/USD 0.3%/24h (coarser than ETH/USD 0.5%/1h) ⇒ chunkier deviation signal.
4. **Issuer proxy risk**: upgradeable impl + `destroyBlockedFunds` (accepted, documented — same
   posture as USDC/tGBP issuer trust).

Priority order (adoption objective, capital available):

- [ ] **P0 — footprint (zero capital, zero new audit surface):** execute the listings + CoW dapp
      items already tracked above (ParaSwap PR #1204 follow-through, 1inch outreach, CoW forum post,
      Hook Store dapp hosting/E2E/listing); USDC hook Etherscan verify; Dune dashboards public.
- [ ] **P1 — deepen with available capital:** USDC pool first (14.4× efficiency, cheapest loop,
      conveyor = protocol revenue), then WETH; finish the §U5 static-pool migration if still pending
      (dual-funded pools leak toxic flow to the static 5bps pool). Staged tranches straight toward
      sim scale (~250k wstGBP USDC-side) — no audit gate (operator stance above); the sim fee
      conclusions assume that scale.
- [~] **P2 — build `src/xaut/`** (USDC-venue clone per above + goldsim param sweep + its own
      readiness/security pass). **No hard gate** — the build is ~days on the proven `src/usdc/`
      pattern; sequence it after the P0/P1 capital + listings work is in motion (those dominate
      marginal velocity), goldsim first (the token–metal basis needs its own params). Fund at
      launch per operator sizing. **Progress 2026-07-16:** contracts + tests + scripts + sim
      package BUILT and green (456 tests repo-wide): `src/xaut/` (two-feed fair, 8-entry
      `FallbackReason`, `XAUT_UNIT=1e6`, 10-field `FeeParams`), 111 xaut test/invariant fns
      across 9 suites (gas warm 9,642 / cold 66,105 vs <10k/<80k), `DeployXautHook.s.sol` +
      `InitXautPool.s.sol` (corridor 500e18–20_000e18, spacing 60) + Makefile targets,
      `sim/goldsim/` + `make sim-data-gold`/`sim-sweep-xaut`, DEPLOY.md §X0–§X6 + README venue
      section + Dune `xaut_*.sql` + check_feeds XAU/USD probe. Sweep DONE 2026-07-16
      (`sim/RESULTS_XAUT.md`, PAXG gold leg — Binance µs-timestamp trap fixed in
      `fetch_binance_gold.sh`; Dukascopy true-XAU confirmation re-sweep optional, cache still
      filling): winner bases (50,10) bps / thr 1000 / slope 1.0× / cap 100 bps stamped into
      `simParams()` — threshold deliberately BELOW the ~5000 ppm basis (SECURITY §6 rationale).
      Readiness pass DONE same day (`docs/READINESS_XAUT_WSTGBP_2026-07-16.md`): **GO** with
      four conditions (commit-before-broadcast, invariants at the deploy rev if code moves,
      risk acceptance, PAXG-sweep caveat + optional Dukascopy confirmation re-sweep) — fresh
      456/456 + 47/47 sim + 37/37 invariants + anvil two-step at 0 ppm with the re-run guard.
      REMAINING (operator): commit, then deploy + init + verify + fund per DEPLOY.md §X.
- [ ] **Deferred — external audit** (`src/weth/` + `src/usdc/`, plus `src/xaut/` when built, one
      engagement): not a gate right now (operator stance 2026-07-11); revisit when POL is
      materially larger or third-party LP shows up.

## Done

- [x] **Hook (shipped): `src/v4/WsgemBackstopHook.sol`** (flags `0x888`) — pure backstop, LP blocked,
      ownerless + no capital, exact-in/out both directions, sharing the router + quoter.
      - A `WstGBPHybridHook` (flags `0x88`, best-ex: in-band LP first then backstop) was also built but is
        now **deferred and removed from the tree** (see the Decision note above; preserved at `b7a5c5a`).
- [x] Vendored `src/v4/base/BaseHook.sol` (this periphery pin dropped `BaseHook`).
- [x] `src/core/interfaces/Iwsgem.sol`.
- [x] Settle-first periphery router — `src/v4/periphery/WsgemSwapRouter.sol` (exact-in/out,
      minOut/maxIn/deadline/recipient, surplus refund).
- [x] Quoter — `src/v4/periphery/WsgemQuoter.sol`: backstop quotes + `previewSwap` executability.
      Off-chain formula in `CLAUDE.md`.
- [x] **LP-aware quoter (deferred with the hybrid)** — `src/periphery/WstGBPHybridQuoter.sol` replayed
      v4's `Pool.swap` to the backstop edge + priced the residual at the oracle (exact hybrid blend,
      fuzz-validated). Removed from the tree with the hybrid; preserved at `b7a5c5a`.
- [x] Deploy script — `script/DeployWstGBP.s.sol`: CREATE2-mines the backstop flags `0x888`, pool init
      fee 0 / tickSpacing 1, deploys router + quoter + direct adapter, and asserts the hook's cached
      `act`/`pip` feed proxies equal the wrapper's (I-02).
- [x] Mainnet-fork tests (65 across three suites, all sharing `test/base/WsgemForkBase.sol`):
      `WsgemBackstopHook.t.sol` (50) — pricing, router hardening + Permit2, quoter + `previewSwap`,
      guards, capacity (L-02), cached-feed parity (I-02), swap-first rejection, currency-ordering adaptation;
      `WsgemBackstopHookFuzz.t.sol` (11) — adversarial math fuzzed across the whole oracle price range
      (4-mode quoter==exec, exact-out ceiling/no-overcharge, bounded sub-par over-mint dust, round-trips
      never profit, donated-balance no-subsidy/no-drain, extreme-price/`int128`/zero clean reverts,
      Permit2 replay rejection); `WsgemBackstopHookInvariants.t.sol` (4) — stateful no-extraction /
      hook-never-drained / quoter==exec / no-liquidity invariants (`[profile.default.invariant]`).
      A standalone `WsgemFlippedOrderingHook.t.sol` (3) runs end-to-end buys/sells in the flipped token
      ordering (wsgem = currency0) against mock tokens, proving the hook adapts when the wrapper sorts below
      its underlying. (The hybrid's suite was removed with the hybrid; preserved at `b7a5c5a`.)
- [x] **Pre-deployment security review (2026-06-09, `docs/SECURITY_REVIEW_2026-06-09.md`)** — **ship
      verdict**, no code findings (nothing ≥ Medium; no Solidity changes). Hand-verified all four
      `BeforeSwapDelta` branches, router delta/refund/Permit2 logic, quoter parity, vendored-BaseHook
      drift (none), and the wrapper boundary against `../maseer-one` source + live mainnet state.
      63/63 tests green, 100% coverage (lines/statements/branches/funcs), deploy script fork-dry-run
      clean (mined hook `0x2f51…c888`, flags `0x888`). Doc corrections applied: wstGBP itself is **not**
      a proxy (its `pip`/`act`/`cop` feeds and tGBP are — README trust model), stale test counts, and
      the price-scaled exact-out dust bound.

## Design invariants (do NOT regress without a deliberate decision)

- **Settle-first only.** `beforeSwap` runs before the taker pays, so input must be pre-settled into
  the PoolManager. Stock swap-then-settle routers are unsupported by design.
- **No hook buffer, no owner.** The hook wraps the swap's own tokens; it never holds inventory or
  privileged roles. (We removed an earlier ERC-6909 buffer + owner/sweep on purpose.)
- **No extra hook fee.** The 25bps spread is the wrapper's; the hook is a pass-through.
- currency0 = tGBP, currency1 = wstGBP; flags = `0x888`.

## Backlog (prioritized)

### P1 — Integration layer (needed before bots can use it)

- [x] **Quoting.** `WsgemQuoter` (on-chain, exact, with `previewSwap` executability) + off-chain
      formula documented in `CLAUDE.md`. Tests assert quote == execution for all four modes.
- [x] **Harden `WsgemSwapRouter`**: split into `swapExactInput` (enforces `minAmountOut`) /
      `swapExactOutput` (enforces `maxAmountIn`, refunds surplus); both take `deadline` + `recipient`
      (`address(0)` ⇒ `msg.sender`). Tested: minOut, maxIn, deadline, recipient, surplus refund.
      - [x] Permit2 entrypoints — `swapExactInputPermit2`/`swapExactOutputPermit2` (SignatureTransfer;
            payer signs a `PermitTransferFrom`, no router approval). Fork-tested vs the approval path.
- [x] **Deploy the router (and quoter)** from `script/DeployWstGBP.s.sol`.

### P2 — M2: best-execution across third-party LP + backstop (the "hybrid")

Requirement (clarified by user, 2026-05-30): the pool may hold third-party LP at ANY range
(full-range, wide, narrow). A swap must get **best execution**: consume LP that beats the backstop
edge first, then backstop the remainder at the edge (mintcost for buys / burncost for sells). LP
priced worse than the current edge is never used (the backstop is always ≥ as good), and gets arbed
back into the band by the backstop itself. The comparison is against the *current* (NAV-drifting)
edge, not a fixed band — so it self-corrects as the rate moves out of where LP was placed.

  Example: mintcost 1.0013, burncost 0.9988. Buyer of 100k wstGBP with 30k LP at 1.000–1.0010 fills
  30k from LP then mints 70k at 1.0013. If that LP were at 1.0020 (> mintcost) it's ignored.

- [ ] **Mechanism** (two viable, decide at build):
      (a) settle-first router sets `sqrtPriceLimitX96` = backstop edge; hook backstops the unfilled
          remainder in `afterSwap` (needs afterSwap + afterSwapReturnDelta flags); or
      (b) reentrancy-guarded nested `poolManager.swap` to the edge in `beforeSwap`, then backstop the
          residual.
      Either way: enable LP adds (drop the beforeAddLiquidity revert); **skip the AMM entirely when
      the pool price is already past the edge** (else `Pool.swap` reverts `PriceLimitAlreadyExceeded`
      — check `slot0` first). New flag set ⇒ new mined hook address (immutable ⇒ fresh deploy). With
      LP reserves now in the PoolManager, revisit whether swap-first routing/quoting partially works.
- [x] **Decided (2026-05-30):** *combine* (best execution — fill better-than-edge LP first, then
      backstop the remainder in the same swap) and *charge a pool fee* (LPs earn it on the portion
      they fill).
- [ ] **Mechanism choice:** hook-internal combine via reentrancy-guarded **nested `poolManager.swap`
      in `beforeSwap`** (preferred over router-side combine, so ANY settle-first router gets
      best-ex). The real AMM runs for the in-band portion (so the pool fee accrues to LPs normally),
      bounded at the **fee-adjusted edge**: for the swapper's all-in price to never exceed the
      backstop edge, the AMM price limit must be `mintcost*(1-fee)` (buys) / `burncost/(1-fee)`
      (sells), converted to `sqrtPriceX96`. Then backstop the residual via mint/redeem and combine
      deltas into the outer `BeforeSwapDelta`. Read `slot0` first; if price is already past the edge,
      skip the AMM entirely (nested swap would revert `PriceLimitAlreadyExceeded`).
- [x] **(1)** `src/WstGBPHybridHook.sol` — new hook, flags `0x88` (LP enabled, no add-revert),
      non-zero pool fee, reentrancy-guarded nested-swap combine + fee-adjusted edge.
- [x] **(2)** Exact-input combine + fork tests (`test/WstGBPHybridHook.t.sol`): buy & sell blend
      in-band LP then backstop, beat pure-backstop price, move pool price toward the edge, hook left
      clean. Exact-output reverts (guarded).
- [x] **(3)** Exact-output combine (buy & sell): partial AMM fill + backstop the remaining output,
      input rounded up with surplus refunded by the router. Fork-tested (blended input beats pure
      backstop).
- [x] **(4)** Edge/guard tests for the hybrid (10 hybrid fork tests total): zero-LP ⇒ exact
      pure-backstop price; price past edge ⇒ AMM skipped + out-of-band LP ignored + price unchanged;
      large swap ⇒ deep blend then backstop; LP earns the pool fee (feeGrowth increases);
      market-closed + underfunded reverts. Hybrid now has full test parity with M1 + LP.
- [x] **(5)** Deploy script + quoter for the hybrid — `WstGBPHybridQuoter` (LP-aware, exact: replays
      the AMM to the edge via `StateLibrary` + backstops the residual) is deployed alongside the hybrid
      in `script/DeployWstGBP.s.sol`.
- [x] **(6) Consolidation — RESOLVED (2026-06-03).** Chose the **pure backstop** (see the Decision note
      at the top). The hybrid hook/quoter/tests were removed from the tree (preserved at `b7a5c5a`); the
      deploy script now deploys only the backstop. Revisit the hybrid only if in-pool LP demand materializes.

Design note — "inject mint/redeem at the tick edges": that IS the backstop conceptually (infinite
liquidity at the mintcost/burncost ticks), but v4 can't post infinite liquidity as a static position
(a tick's depth = its `L`), so it must be synthesized by the hook. Alternative mechanism to the
nested swap: let the real outer swap run bounded at the edge (router sets the price limit) and
backstop the overflow in `afterSwap` — simpler hook, but each integrating router must compute/set the
edge, so best-ex is no longer automatic for arbitrary settle-first callers.

### P3 — Test gaps

- [x] `capacity()`-exceeded revert path (`test_buyRevertsWhenCapacityExceeded` + quoter flag).
- [x] Quoter == execution tests (4 modes) + `previewSwap` executability flags.
- [x] Fuzz pricing/rounding across amounts (backstop quoter == execution, hook-clean, dust ≤ 1 wei) +
      hybrid LP-quote == execution fuzz.
- [x] Large-swap blend (`test_lpQuoteMatchesExecution_largeBuy`, `test_largeSwapBlendsDeepThenBackstops`);
      sell depth guarded by `WrapperUnderfunded` + `RedeemUnderpaid`.

### P4 — Nice to have

- [x] Integrator events — `WsgemSwapRouter` emits `Swap(payer, recipient, poolId, zeroForOne,
      amountIn, amountOut)` once per swap (all four entrypoints), beyond the PoolManager's own `Swap`.
- [x] Security review / audit prep pass — done (reports under `~/.claude/plans/`).
      Fixed F1 (`RedeemUnderpaid` + cooldown handling: hybrid sells fall back to LP, backstop reverts;
      router enforces exact-output full delivery). Trust model documented in `README.md` (F4).
- [x] Second deep-dive (charge-only-what's-filled): fixed the hybrid **sub-threshold residual** edges.
      EXACT-IN now refunds the un-wrappable dust (`_backstopExactIn` returns `inConsumed`; `_beforeSwap`
      bills `ammIn + inConsumed`) instead of charging the full input for zero output. EXACT-OUT reverts
      `BackstopResidualTooSmall` instead of clamping the input up to `mintcost`/`WAD` and overcharging
      (which had made the hybrid *worse* than the pure backstop and left ~1 token of locked dust in the
      hook). The hook now keeps no dust on these paths; `WstGBPHybridQuoter` mirrors both (exact-in is a
      lower bound, `quoteExactOutput` reverts, `previewSwap` flags `"residual below wrapper threshold"`).
      Regression tests added to `test/WstGBPHybridHook.t.sol`. Low/info items deferred to external audit:
      hook doesn't pin `fee`/`tickSpacing`, no `beforeInitialize` guard,
      `_edgeSqrtPrice` double-floor, exact-out capacity 1-wei window.
- [x] **Gas-optimization pass (2026-05-31)** — all 58 tests still green, pricing byte-identical
      (`quote == execution` parity + round-trip tests unchanged):
      - Both hooks now read the backstop price **directly off the wrapper's immutable feeds**
        (`act.mintcost(pip.read())` / `act.burncost(pip.read())` / `act.cooldown()`) instead of
        `wrapper.mintcost()`/`burncost()`/`cooldown()`, skipping the wrapper dispatch hop. `act`/`pip`
        are `immutable` in the wrapper, fetched once in each constructor and cached as immutables ⇒
        byte-identical to the wrapper facade (`mint`/`redeem` use the same feeds). New
        `src/core/interfaces/IFeeds.sol`; `Iwsgem` gained `act()`/`pip()` getters; quoters left on the
        facade (off-chain; same value ⇒ parity preserved).
      - Backstop sell-exact-out deduped (was reading `burncost()` twice); hybrid reads the direction's
        cost **once per swap** and threads it into `_edgeSqrtPrice`/`_backstopExactIn`/`_backstopExactOut`
        (now take a `cost` param; `_edgeSqrtPrice` is `pure`).
      - Hybrid `_inNestedSwap` reentrancy guard is now `bool private transient` (EIP-1153) ⇒ the hook
        holds **zero persistent storage**. Required bumping `solc_version` 0.8.26 → **0.8.28** (evm stays
        `cancun`); v4 deps compile fine (forge compiles the one exact-`0.8.26`-pinned dep in its own unit).
      - `via_ir=true` measured a real **-193,800 gas (-1.210%)** whole-suite, all 58 tests green. Since
        fork-test totals are dominated by *unchanged* mainnet external calls, that -1.21% is
        concentrated in our own contract code. **Decision (user):** flipped the default profile to
        `via_ir = true` (slower compiles, always-optimized bytecode). `.gas-snapshot` baseline (58
        entries, committed-able) regenerated at `via_ir=true`.
- [x] **Security-audit fixes (2026-05-31, `SECURITY_AUDIT.md` — since removed from the tree; in git
      history at `7ad0b89`)** — all 62 tests green at the time (58 prior + 4
      new regressions across the 3 findings; each mutation-checked to fail on the pre-fix code):
      - **M-01 (Med):** the hybrid AMM edge now nets out the **full directional swap fee** v4 charges
        (LP fee + any pool protocol fee), not just `key.fee`. `WstGBPHybridHook._beforeSwap` reads
        slot0's `protocolFee`/`lpFee` once, derives the combined `swapFee` (`ProtocolFeeLibrary`), and
        feeds it to `_edgeSqrtPrice` (and threads the already-read `sqrtP` into `_fillAmm`).
        `WstGBPHybridQuoter` mirrors it via a shared `_edgeFor`. Stops the nested AMM consuming LP
        priced worse than the backstop when a protocol fee is enabled. No-op when `protocolFee == 0`.
      - **L-01 (Low):** dynamic-fee (`0x800000`) and `>=100%` fee keys now revert `PoolNotSupported`
        in the hook and quoter (`key.fee >= PIPS`, plus a combined `swapFee >= PIPS` guard) instead of
        underflowing / dividing by zero in the edge math. Normal static fees (5bps, 30bps) unaffected.
      - **L-02 (Low):** `WsgemQuoter.previewSwap` capacity check now uses the **minted** amount
        (`amountIn·1e18/mintcost`), which for an exact-output buy is `>=` the requested output, instead
        of the requested output — closing a false `executable=true` at the capacity boundary.
      - Informational items (I-01..I-05: canonical-PoolKey docs, cached-feed monitoring, `ffi=false`,
        submodule pin, exact-in dust-past-edge) deferred to a follow-up / the external audit.
- [~] **I-04 — pin/record dependency provenance.** No release tag yet ships the required periphery APIs,
      so the audited commits are **documented** in `AUDIT_SCOPE.md` instead: `lib/v4-periphery` at
      `363226d` (heads/main), nested `lib/v4-core` at `v4.0.0` (`59d3ecf5`). Re-pin to a tagged release
      once one supports the APIs. (Repo is now under git, so a future re-pin is straightforward.)
