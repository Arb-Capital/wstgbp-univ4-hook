# WETH/wstGBP Dynamic-Fee Venue — Deployment Runbook

Every step to take `src/weth/` from repo to a funded mainnet pool. The flow is deliberately
treasury-shaped: **two script transactions (deploy hook, init pool), then all funding and position
management happens in the Uniswap web UI from the Safe.** No keepers, no seeding scripts, nothing
recurring. The `POLCompounder` is optional automation, not part of launch (see Appendix).

Addresses (verify against README "Key mainnet addresses (WETH/wstGBP venue)"): owner multisig
`0x846a655a4fA13d86B94966DFDf4D9a070e554f7c`; PoolManager `0x0000…8A90`; PositionManager
`0xbD21…ee9e`; feeds ETH/USD `0x5f4e…8419`, GBP/USD `0x5c0A…d4b5`; WETH `0xC02a…6Cc2`;
wstGBP `0x57C3…B7aE`.

## 0. Preconditions

| Env var | Used by | Notes |
|---|---|---|
| `ETH_RPC_URL` | everything | archive/full RPC |
| `ETH_FROM` / `ETH_KEYSTORE` | broadcasts | deployer address + encrypted keystore (forge prompts for the password) |
| `ETHERSCAN_API_KEY` | `verify-weth-hook` (step 3½, after init) | `--verify` on the resumed broadcast |
| `WETH_HOOK` | init | hook address from step 2 |

Checklist:

- [ ] `make test && make test-invariant` green at the deploy commit; record `git rev-parse HEAD`.
      The invariant gate MUST run against an authenticated archive RPC (`.env` `ALCHEMY_API_KEY`
      or `ETH_RPC_URL` — see `.env.example`): the public fallback 403s on archive requests partway
      through long invariant campaigns, which aborts suites without proving anything.
- [ ] Working tree is **clean** at that commit (`git status --porcelain` empty) — never deploy
      from a dirty tree; the recorded rev must BE the deployed code.
- [ ] Risk acceptance, stated consciously: `src/weth/` is first-party-reviewed only (outside the
      backstop audit scope — AUDIT_SCOPE.md). Launch = small, capped POL; **scale-up is gated on
      the venue's own external audit.**
- [ ] Re-verify feed heartbeats/deviations against Chainlink docs **today** (README table has the
      2026-07-04 values: ETH/USD 3600s/0.5%, GBP/USD 86400s/0.15%); retune the staleness windows in
      `DeployWethHook.simParams()` if they changed.
- [ ] `sim/RESULTS.md` recommendation matches `DeployWethHook.simParams()`.
- [ ] Deployer funded with gas ETH only (~0.001 for the hook + a trivial init tx). **No seed funds
      needed by the scripts** — POL comes from the Safe via the UI later.
- [ ] Sepolia is skipped by design (no wstGBP wrapper there); fork rehearsal below is the dress
      rehearsal (spec-blessed).

## 1. Fork rehearsal (both scripts, end to end)

```bash
make deploy-weth-hook-dry            # simulates the hook deploy against live mainnet state
# full two-step rehearsal on a persistent fork (validated 2026-07-04: 0 ppm init deviation):
anvil --fork-url $ETH_RPC_URL --port 8546 &
forge script script/DeployWethHook.s.sol --rpc-url http://localhost:8546 \
  --private-key <anvil key 0> --broadcast          # note the logged hook address
WETH_HOOK=<that address> forge script script/InitWethPool.s.sol \
  --rpc-url http://localhost:8546 --private-key <anvil key 0> --broadcast
```

The deploy script pre-checks the multisig has code, feed decimals, and the OracleLib-composed fair
price inside a plausibility corridor (logged — sanity-check it: ≈ spot ETH/GBP ÷ navprice); then
asserts exact permission bits, immutables, owner = multisig, params read-back. The init script
initializes at that fair price and asserts the on-chain deviation < 10 bps (typically 0).

## 2. Hook deploy — mainnet

```bash
ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… make deploy-weth-hook
```

Record the hook address from the logs and **go straight to step 3** — the deploy target
deliberately does not verify inline, so the terminal is free the moment the tx confirms.
Etherscan verification is step 3½ (`make verify-weth-hook`, race-free). The hook is owned by the
multisig **from construction** — no acceptance step, no deployer-owned window.

## 3. Pool init — mainnet (one cheap tx, no funds)

```bash
WETH_HOOK=<hook> make init-weth-pool-dry      # simulate against the now-deployed hook
WETH_HOOK=<hook> ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… make init-weth-pool
```

Record the logged PoolId and init tick. Re-running reverts (pool already initialized).

**Minimize the init race window.** Initialization is permissionless and the canonical PoolKey is
predictable the moment the hook address is public, so treat deploy→init as one sequence: run
`make init-weth-pool` **immediately** after the deploy tx confirms — do NOT wait for Etherscan
verification (nothing in init depends on it; verify afterwards). For a zero-width window, submit
both txs as a private bundle (e.g. Flashbots Protect RPC as `ETH_RPC_URL` for the two broadcasts).

**If the init tx reverts with pool-already-initialized** (someone front-ran the key): do NOT fund
anything yet. Read slot0 and compare against oracle fair (the script's pre-flight math), then:

- *Pool has zero liquidity* (bare hostile init): the price is free to move — execute a dust swap
  with `sqrtPriceLimitX96` set at the fair target (it walks slot0 to the limit with ~zero amounts),
  re-check deviation < 10 bps, then fund.
- *Pool has nontrivial liquidity at an off-fair price*: the attacker's liquidity is mispriced
  inventory, and the fee schedule is arb-friendly (the linear surcharge takes at most half the
  deviation edge, capped at 60 bps) — but do NOT assume profit; net PnL also depends on gas, the
  amount needed to reach fair, and the path-integral slippage through their range. **Simulate the
  exact closing swap first** (stock Quoter quote at the fair-target `sqrtPriceLimitX96`, compare
  output value at oracle fair) and execute only profit-bounded (`minAmountOut` from the quote) —
  or simply wait for searchers to do it. Either way, fund ONLY once deviation < 10 bps.
- *Pool cannot be normalized* (pathological state): do NOT fund the canonical key. The hook
  accepts any tickSpacing, so with owner/team sign-off initialize an **alternate PoolKey** (same
  currencies + hook, different tickSpacing, e.g. 30) at fair via a modified init run, and record
  the new canonical key in README/monitoring/integrations before any funding.

## 3½. Verify + spot checks (after init is on-chain)

```bash
# resumes the deploy broadcast, verify-only (sends nothing — all txs already mined; forge
# nevertheless wants the deployer wallet to validate the resume, so reuse the deploy env):
ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… ETHERSCAN_API_KEY=… make verify-weth-hook
cast call $WETH_HOOK "owner()(address)"   # 0x846a…4f7c
cast call $WETH_HOOK "paused()(bool)"     # false
```

## 4. Funding via the Uniswap UI (the Safe)

The pool is a standard v4 AMM — the hook has no liquidity callbacks — so position management is
the normal Uniswap web-app flow, executed by the Safe via WalletConnect. The exact call shape the
UI produces (Permit2 allowance + PositionManager `modifyLiquidities`) is pinned by
`test/WethWstGbpPositionManager.t.sol` against the real mainnet PositionManager, including the
treasury bracket below.

1. app.uniswap.org → connect the Safe → New position → v4 → paste both token addresses
   (wstGBP is not on default lists — expect an "unknown token" notice) → select the pool
   (dynamic-fee, hook `= $WETH_HOOK`; expect a caution banner for an unrecognized hook — ours).
2. Enter the range as **min/max prices**. **Chosen bracket (2026-07-04, supersedes the earlier
   $1,400–$10,000 draft): WETH $1,500–$8,000 guaranteed across GBP/USD 1.10–1.45, at current NAV
   (1.0047), efficiency-first — deliberately NOT NAV-extended:**
   - quoted as wstGBP per WETH: **min 1,028 / max 7,270** — snaps to **tickLower −88,920 /
     tickUpper −69,360** (low tick = high wstGBP-per-WETH price; matches
     `test_uiCustomAsymmetricBracketMints`)
   - quoted as WETH per wstGBP (if the UI shows the flipped orientation): **min 0.0001375 / max 0.0009725**
   - ~2.59× full-range efficiency; deposit mix at the 2026-07-04 fair (~1,335) ≈ 18% wstGBP / 82% WETH by value.
   The app snaps to tickSpacing 60 itself.
   **Accepted tradeoff / re-range trigger:** the NAV ratchet (~4%/yr assumed) drifts the bracket's
   USD floor upward — ≈$1,500 today, ≈$1,830 at NAV 1.22 (~5y), ≈$2,217 at NAV 1.49 (~10y). Review
   yearly; re-range (UI: Remove → New position) when the effective floor no longer matches the
   thesis, e.g. once NAV crosses ~1.2. Recompute any new bracket with the same method:
   `P = ETH_USD_bound / cable_bound / NAV`, floor at cable 1.45, ceiling at cable 1.10.
3. **Small test add first** (e.g. 0.1 WETH + matching wstGBP), confirm the position renders and a
   probe swap charges the expected fee, then add the real size. Deposit amounts auto-balance to the
   range ratio in the UI.
4. The position NFT lives in the Safe. Ongoing management is UI buttons: **Collect fees**
   (optionally once or twice a year, re-adding via Increase liquidity — never compounding at all
   costs only ~f²/2 per year, ≈0.5%/yr at a 10% fee APR), **Increase/Remove liquidity** for
   resize/exit. Nothing is time-critical, ever: out-of-range or untouched positions just idle.

## 5. Post-deploy verification

```bash
# stock v4 Quoter parity probe (fee-only hook => exact quotes). NOTE: run AFTER funding —
# an empty pool correctly reverts NotEnoughLiquidity(poolId) on any quote:
cast call 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203 \
  "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))(uint256,uint256)" \
  "(($WSTGBP,$WETH,8388608,60,$WETH_HOOK),true,1000000000000000000,0x)"
monitoring/check_feeds.sh
```

Then one small live swap each direction and confirm the `SwapFee` event decodes with the expected
fee (30 bps mint side / 5 bps redeem side at ~zero deviation).

## 6. Monitoring activation (tiered — the position itself needs NONE of this)

Nothing here protects funds; the hook fails soft to a flat 30 bps pool and no response is ever
time-critical. Monitoring exists for the FEE-POLICY OPERATOR hat (revenue quality: is the
surcharge actually pricing, or has the pool quietly degraded to fallback?). Pick a tier:

- **Fire-and-forget (recommended baseline; ACTIVATED 2026-07-04):** the queries are created on
  Dune (IDs in `monitoring/dune/README.md`), deliberately **unscheduled** (free-tier credit
  policy — the alert costs 0.072 credits/run; schedule it daily (~2 credits/mo) or leave it
  manual). One-time remaining: submit the verified contract for decoding at
  dune.com/contracts/new. Plus the yearly NAV-drift range review from §4. That's the whole
  obligation.
- **Ops-manual (optional, for active fee-policy management):** additionally cron
  `monitoring/check_feeds.sh` (e.g. daily; 15-min only if you're actively tuning) — it watches
  the oracle root cause the on-chain events can't show (a QUIET pool in fallback emits nothing,
  so the Dune alert needs swaps to fire).
  (`compounder_activity.sql` only applies if the optional compounder is ever adopted.)

## 7. Incident procedures (all Safe transactions)

| Incident | Action |
|---|---|
| Oracle degradation (sustained fallback) | Nothing bricks — swaps price at the 30 bps fallback, i.e. the pool degrades to UniV2 behavior. Investigate via `check_feeds.sh`; consider pausing only if fallback pricing itself is exploited. |
| Pause | Hook `setPaused(true)`: swaps continue at `fallbackFee`; POL and positions unaffected. Reversible. |
| Fee retune | Hook `setFeeParams(FeeParams)` — bounds-checked on-chain (≤10% absolute ceiling), full struct emitted for indexers. |
| Fee-model change | Immutable logic: deploy a v2 hook + new pool, move the position via the UI (Remove → New position). |
| Exit | UI: Remove liquidity + Collect. No contract dependencies. |

## Appendix: optional POLCompounder automation

`src/weth/POLCompounder.sol` (fully tested: 23-test fork suite + the `POLCompounderInvariants`
stateful suite) is an automation upgrade for a
future where fee volume justifies keeper-driven compounding: it holds the position directly in the
PoolManager and compounds in one call (poke → oracle-bounded rebalance ± `toleranceBps` vs the same
OracleLib fair the hook uses → add liquidity), with principal structurally unable to leave the pool
during a compound. Migration path — **ownership must reach the Safe BEFORE any funds move** (POL
must never sit under a hot deployer key): prefer deploying with `_owner = the Safe` directly (the
constructor supports it; the Safe then sends the one `setKeeper` tx), or if the deployer does setup,
`transferOwnership(Safe)` + Safe `acceptOwnership()` (selector `0x79ba5097`) first — only then:
Remove liquidity in the UI → transfer the funds from the Safe to the compounder → keeper
`compound()` bootstraps the position. Keeper policy if adopted: compound when
gas < ~150 bps of `compoundable()` value and the pool sits near fair (the rebalance execution-price
bound budgets the hook's own 30 bps mint-side fee inside the 50 bps default tolerance);
`NothingToCompound` / `PriceOutOfBounds` reverts are normal and lose nothing.

---

# wstGBP/USDC Dynamic-Fee Venue — Deployment Runbook (third venue)

Same skeleton as the WETH runbook above; this section records only the deltas and the
venue-specific decisions. Scripts: `script/DeployUsdcHook.s.sol` + `script/InitUsdcPool.s.sol`;
targets: `make deploy-usdc-hook[-dry]`, `make init-usdc-pool[-dry]`, `make verify-usdc-hook`.

## U0. Preconditions (deltas vs §0)

- [ ] `sim/RESULTS_USDC.md` current (`make sim-sweep-usdc`) and its "Recommended starting
      FeeParams" == `DeployUsdcHook.simParams()` (synced 2026-07-05: (30,5)bps bases, thr 1000,
      slope 1.0x, cap 60bps, minFee 50, fallback 3000).
- [ ] GBP/USD feed heartbeat re-verified (86400s / 0.15% ⇒ window 90000s). There is NO second
      Chainlink feed on this venue; USDC is assumed $1.00 (SECURITY_USDC_WSTGBP.md §6 — read the
      depeg section before deploying).
- [ ] `make test` green incl. the `UsdcWstGbp*` suites; `make test-invariant` green.

## U1. Fork rehearsal

```bash
make deploy-usdc-hook-dry     # keyless; asserts feed decimals, USDC decimals==6, fair corridor
                              # (0.4e18–1.0e18 wstGBP/USDC; the 1.0e18 ceiling also rejects an
                              # orientation flip — readiness finding B-1), mining, exact flag
                              # bits 0x20C0
# full two-step rehearsal on a persistent anvil fork (validated 2026-07-05: 0 ppm init
# deviation, pool price 1.3416 USDC/wstGBP vs live burn/mint anchors):
anvil --fork-url $ETH_RPC_URL --gas-limit 3000000000 &   # match foundry.toml gas_limit
# deploy + init against 127.0.0.1:8545 with a funded key, then kill anvil and
# DELETE the rehearsal broadcast/ records (they are not deploy artifacts).
```

## U2–U3½. Deploy → init → verify

Identical flow and rationale to §2–§3½: deploy does NOT verify inline; `init-usdc-pool` must
follow IMMEDIATELY (permissionless init, predictable PoolKey — same front-run window and same
recovery as §3: if front-run at a bad price, DO NOT fund; arb it to fair through the hook's own
fee schedule or abandon the key); `make verify-usdc-hook` afterwards. Init post-asserts deviation
< 1000 ppm vs the single-feed fair. tickSpacing is **1** (near-stable pair — 60 would quantize
range edges to ~60bps steps against a ±12.5bps band).

## U4. Funding via the Uniswap UI (the Safe) — range selection

Mechanics identical to §4 (Permit2 + PositionManager; pinned by
`test/UsdcWstGbpPositionManager.t.sol`, including the tight spacing-1 bracket shape). The range
DECISION is venue-specific and is made at funding time from live fair:

- Coordinate: USDC-per-wstGBP = `GBP/USD × navprice()` (≈ 1.342 at 2026-07-05 values). The NAV
  ratchet drifts it UP ~5%/yr forever; cable moves it both ways.
- Method: bracket = cable envelope × NAV horizon; efficiency by the geometric-mid formula
  `1/(1−(Pa/Pb)^(1/4))` (same convention as the §4 WETH figure).
- **Chosen bracket (2026-07-05, FINAL): USDC-per-wstGBP min 1.20 / max 1.60** (as
  wstGBP-per-USDC: 0.625–0.833) — **ticks −274,501 / −271,624** at spacing 1 (the UI snaps),
  **~14.4× full-range efficiency**, deposit mix ≈ 39% USDC / 61% wstGBP at the 2026-07-05 spot
  (1.3416). Design: 18-month ceiling (cable to 1.485 at end-NAV — above anything since pre-Brexit
  2016) with a 1-year review, and a deliberately TIGHT floor per the operator's stated stance
  (2026-07-05): GBP is judged cheap and a low-side breach — the position parking 100% in wstGBP,
  the appreciating asset, with fees idle until cable recovers above ~1.20 — is explicitly
  acceptable. The floor sits just under the 2025 low (1.21) and ~10% under spot; conservative
  alternatives priced during the decision: 1.15–1.60 ≈ 12.6× (gilt-crash-only floor),
  1.05–1.60 ≈ 10.0× (all-history-safe floor).
- Tighter is more capital-efficient but re-ranges sooner: the ratchet alone consumes ~5%/yr of
  headroom toward the max bound. Yearly review, same trigger logic as §4; additional re-range
  trigger here: a sustained low-side park (cable < 1.20 for months) is a choice point — hold
  wstGBP or re-range down.
- **Small test add first**, probe swap, confirm the fee schedule (mint side = wstGBP in), then
  real size. sim/RESULTS_USDC.md's POL assumption is 250k wstGBP — revisit fee conclusions if
  funding materially differs.

## U5. Migrating out of the static 5bps pool

The predecessor pool's full identity (recomputed and matched against the observed id): poolId
`0xbe0ffd8b92d2610cc4491e5bfcd7f51312c0868183c9b0da577a6f131bf3bb10` = keccak256 of
PoolKey(currency0 = wstGBP `0x57C3…B7aE`, currency1 = USDC `0xA0b8…eB48`, fee 500, tickSpacing 10,
hooks = 0x0). It keeps running the unprotected conveyor as long as it holds LP. Once the hook
pool is funded:

1. UI → Positions → the static 5bps wstGBP/USDC position → **Collect fees**, then **Remove
   liquidity** (full exit).
2. Re-mint into the dynamic-fee pool (U4 bracket) with the recovered tokens.
3. Do NOT leave both funded long-term: routers will fill through whichever quotes better, and
   during surcharge regimes that is the static pool — it would leak exactly the toxic flow the
   hook exists to tax (and its LP eats the ratchet unprotected).

## U6. Monitoring + incidents (deltas vs §6–§7)

- `monitoring/check_feeds.sh` now also probes USDC/USD (advisory depeg alarm, >50bps from $1):
  on alert the runbook is Safe → `setPaused(true)` (flat fallbackFee both directions, swaps never
  blocked; unpause after re-peg). This is the ONLY defense the depeg has — the hook cannot see it.
- Dune: reuse the weth queries by `{{hook_address}}` parameter EXCEPT `fallback_minutes` — reason
  codes renumber (5-entry enum); use `usdc_fallback_minutes.sql`. Submit the hook for decoding.
- All other incident procedures (§7) apply verbatim with the usdc addresses.

---

# XAUT/wstGBP Dynamic-Fee Venue — Deployment Runbook (fourth venue)

Same skeleton as the WETH runbook above; this section records only the deltas and the
venue-specific decisions. Scripts: `script/DeployXautHook.s.sol` + `script/InitXautPool.s.sol`;
targets: `make deploy-xaut-hook[-dry]`, `make init-xaut-pool[-dry]`, `make verify-xaut-hook`.
Status: **BUILT, NOT YET DEPLOYED** — the goldsim sweep + readiness pass gate the deploy (§X0).

## X0. Preconditions (deltas vs §0)

- [ ] `sim/RESULTS_XAUT.md` exists (`make sim-data-cable` + `make sim-data-gold` +
      `make sim-sweep-xaut` — the cable target supplies the shared GBP legs) and its
      "Recommended starting FeeParams" == `DeployXautHook.simParams()` (synced 2026-07-16:
      (50,10)bps bases, thr 1000, slope 1.0x, cap 100bps, minFee 50, fallback 5000, both windows
      90000 — the threshold sits deliberately BELOW the token–metal basis magnitude, see
      `SECURITY_XAUT_WSTGBP.md` §6; the basis is SIGN-UNSTABLE, and production is confirmed by
      the minimax across the UNION of the basis-50 and basis-0 ranking runs (worst rank 7 vs 9
      next-best) — the basis-0 run ALONE picks the thr=3000 sibling (analysis:
      `sim/RESULTS_XAUT_BASIS0.md`; decision: the readiness addendum), plus sensitivity across
      basis {−50..100} bps). Gold leg was PAXG (documented fallback); if the Dukascopy
      true-XAU confirmation re-sweep has landed since, re-check the winner still matches.
- [ ] BOTH feed heartbeats/deviations re-verified against Chainlink docs **today**: XAU/USD
      `0x214e…a0D6` (0.3% / 24h ⇒ window 90000s) and GBP/USD `0x5c0A…d4b5` (0.15% / 24h ⇒ window
      90000s); retune the two staleness windows in `simParams()` if they changed.
- [ ] The token–metal basis section read (hook NatSpec + `SECURITY_XAUT_WSTGBP.md` §6): the pool
      RESTS at d ≈ −basis, and the basis is small and SIGN-UNSTABLE (~+50bp discount estimated
      2026-07-11; ~11bp premium measured 2026-07-16 — rest state may sit either side of zero).
      That is the venue's designed rest state, not drift — it shapes the post-init drift note
      (§X3), the POL bracket (§X4), and the deviation-histogram reading (§X6). **Measure the live
      basis today** (XAUT market price vs the XAU/USD feed answer) and record it in the deploy
      notes.
- [ ] XAUt issuer-surface preflight will run in the deploy script (blocklist `isBlocked` on
      PoolManager/multisig/PositionManager/Permit2 + EIP-1967 impl logged); nothing to do here,
      but if the impl address logged at deploy differs from the one recorded at the readiness
      pass (`0x4C0d2c74A8D26f1E4F5653021c521F5471F9e566`, 2026-07-16), STOP and re-review §8 of
      `SECURITY_XAUT_WSTGBP.md` before proceeding.
- [ ] `make test` green incl. the `XautWstGbp*` suites; `make test-invariant` green (authenticated
      archive RPC, per §0); the venue's own readiness/security pass done at the deploy rev.

## X1. Fork rehearsal

```bash
make deploy-xaut-hook-dry     # keyless; asserts feed decimals (8/8), XAUT decimals == 6, the
                              # two-feed fair corridor (500e18–20_000e18 wstGBP/XAUT — metal fair
                              # sits in the low thousands-e18; FAIR_MIN alone also rejects an
                              # orientation flip, the inverse ≈ 4e14), mining, exact flag bits
                              # 0x20C0
# full two-step rehearsal on a persistent anvil fork:
anvil --fork-url $ETH_RPC_URL --gas-limit 3000000000 &   # match foundry.toml gas_limit
# deploy + init against 127.0.0.1:8545 with a funded key, then kill anvil and
# DELETE the rehearsal broadcast/ records (they are not deploy artifacts).
```

## X2. Hook deploy — mainnet

```bash
ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… make deploy-xaut-hook
```

Identical rationale to §2: record the hook address from the logs, do NOT verify inline, go
straight to §X3. The hook is owned by the multisig from construction — no acceptance step.

## X3. Pool init — mainnet (IMMEDIATELY after deploy)

```bash
XAUT_HOOK=<hook> make init-xaut-pool-dry
XAUT_HOOK=<hook> ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… make init-xaut-pool
```

Same init-race posture and front-run recovery as §3 (permissionless init, predictable PoolKey —
if front-run at a bad price, DO NOT fund; arb it to fair through the hook's own fee schedule or
abandon the key). tickSpacing is **60** (high-vol pair — gold-in-GBP ~37% annualized — with wide
POL brackets, so ~0.6% edge quantization is immaterial; the USDC venue's spacing-1 tight-bracket
rationale does not apply). The script initializes at the **METAL fair**, composed through the
same OracleLib the hook prices with **using the deployed hook's own feed addresses and staleness
windows** (read from the hook, never duplicated — a retuned deploy cannot drift out from under
init), and post-asserts |deviation| < 1000 ppm. It also re-checks the XAUt blocklist for the
PoolManager and multisig. Expect the pool to drift to d ≈ −basis after funding + the first arb —
the designed rest state, NOT a mispriced init (|basis| ≲ 50 bps and sign-unstable: discount ⇒
d < 0, premium ⇒ d > 0 — the live 2026-07-16 measurement was a ~11bp premium); do not "fix" it by
initializing at fair×(1−basis), which would hardcode a basis estimate and break the deviation
assert.

## X3½. Verify + spot checks

```bash
ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… ETHERSCAN_API_KEY=… make verify-xaut-hook
cast call $XAUT_HOOK "owner()(address)"   # 0x846a…4f7c
cast call $XAUT_HOOK "paused()(bool)"     # false
```

Plus `feeParams()` read-back 10/10 == `simParams()` (the deploy script already asserts this
on-chain; re-check by eye).

## X4. Funding via the Uniswap UI (the Safe) — range METHOD (final numbers at launch)

Mechanics identical to §4 (Permit2 + PositionManager via WalletConnect; the exact UI call shape,
incl. the spacing-60 bracket, is pinned by `test/XautWstGbpPositionManager.t.sol`). Unlike §4/§U4
the final numbers are deliberately NOT pre-committed here — gold moves too much between writing
and launch; compute them at funding time from the live fair. The METHOD is decided:

- Coordinate: wstGBP-per-XAUT (metal fair ≈ 2,300–3,100e18 at 2026 prices). The weekly NAV
  ratchet (~9 bps/wk ≈ 5%/yr) LOWERS fair in this coordinate forever; gold-in-GBP vol (~37%
  annualized) moves it both ways.
- Method: **wide geometric bracket, ×/÷ ~1.5 around live fair, biased DOWN-side-wide** in
  wstGBP-per-XAUT terms — the lower bound carries both the permanent ratchet drift and
  gold-downside excursions, so it needs the extra headroom; a gold rally consumes the upper
  bound. Yearly re-range review, same trigger logic as §4 (the ratchet alone eats ~5%/yr of the
  low-side headroom).
- The UI snaps to tickSpacing 60 (~0.6% price steps) — immaterial at this bracket width; take the
  snapped ticks and record them.
- **Immediately before funding, repeat the XAUt blocklist checks** (the deploy/init preflights
  may be hours stale by now; SECURITY §8):

  ```bash
  XAUT=0x68749665FF8D2d112Fa859AA293F07A622782F38
  for a in 0x000000000004444c5dc75cB358380D2e3dE08A90 0x846a655a4fA13d86B94966DFDf4D9a070e554f7c \
           0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e 0x000000000022D473030F116dDEE9F6B43aC78BA3; do
    cast call $XAUT "isBlocked(address)(bool)" $a   # all must be false
  done
  cast storage $XAUT 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc  # impl unchanged?
  ```
- **Small test add first**, probe swap, confirm the fee schedule (mint side = wstGBP in; which
  side reads closing at rest depends on the live basis SIGN — at a discount the redeem side must
  read non-closing and pay base only, at a premium it pays base + a small ramp surcharge), then
  real size per operator sizing. Revisit `sim/RESULTS_XAUT.md`'s fee conclusions if funding
  materially differs from its POL assumption.

## X5. Predecessor migration — NONE (contrast §U5)

There is no pre-existing XAUT/wstGBP pool: nothing is running an unprotected conveyor, so there
is no LP to collect, remove, or re-mint — §U5 has no analogue here. The empty tGBP/XAUt v4 shells
visible on-chain are the WRONG PAIRING (tGBP misses the NAV-ratchet conveyor; pair wstGBP —
ROADMAP decision 2026-07-11) and are ignored, not migrated.

## X6. Monitoring + incidents (deltas vs §6–§7)

- `monitoring/check_feeds.sh` now also probes XAU/USD (window 90000s). Gold closes
  weekends/holidays (+ the 22:00–23:00 UTC daily break): Chainlink usually heartbeats a frozen
  price through the close (flat fair — NOT fallback), but if the feed pauses instead, staleness
  fallback fires — EXPECTED; cross-check against market hours before reacting. More fallback
  minutes than the USDC venue is normal for this venue.
- Dune: the four `monitoring/dune/xaut_*.sql` queries are written but NOT yet created on Dune —
  create them at deploy, set the deploy-date floors (marked TBD in the sources), record the IDs
  in `monitoring/dune/README.md`, and submit the verified hook for decoding. Reason codes
  RENUMBER again (8-entry enum, XAU/USD in the weth numbering's ETH/USD position — still ≠ the
  usdc 5-entry mapping); use `xaut_fallback_minutes.sql`, never another venue's decoder.
  Deviation-histogram mass at d ≈ −basis is the designed rest state, not an incident — and the
  basis is sign-unstable (|·| ≲ 5000 ppm; a ~11bp PREMIUM ⇒ rest mass at small d > 0 was the live
  regime measured 2026-07-16) — investigate regime shifts, not the rest mass.
- All other incident procedures (§7) apply verbatim with the xaut addresses.
