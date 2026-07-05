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

- **Fire-and-forget (recommended baseline):** submit the (verified) hook ABI to Dune decoding,
  create the committed queries (`monitoring/dune/*.sql`, raw-log-ready), and schedule ONLY
  `alert_sustained_fallback.sql` hourly with alert-on-results — zero-touch; it emails only when
  >50% of a trailing hour's swaps priced in fallback. Plus the yearly NAV-drift range review
  from §4. That's the whole obligation.
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
