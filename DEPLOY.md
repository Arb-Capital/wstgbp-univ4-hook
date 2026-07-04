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
| `ETHERSCAN_API_KEY` | hook deploy | `--verify` |
| `WETH_HOOK` | init | hook address from step 2 |

Checklist:

- [ ] `make test && make test-invariant` green at the deploy commit; record `git rev-parse HEAD`.
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
ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… ETHERSCAN_API_KEY=… make deploy-weth-hook
```

Record the hook address; confirm Etherscan verification. The hook is owned by the multisig **from
construction** — no acceptance step, no deployer-owned window. Spot checks:

```bash
cast call $WETH_HOOK "owner()(address)"   # 0x846a…4f7c
cast call $WETH_HOOK "paused()(bool)"     # false
```

## 3. Pool init — mainnet (one cheap tx, no funds)

```bash
WETH_HOOK=<hook> make init-weth-pool-dry      # simulate against the now-deployed hook
WETH_HOOK=<hook> ETH_RPC_URL=… ETH_FROM=… ETH_KEYSTORE=… make init-weth-pool
```

Record the logged PoolId and init tick. Re-running reverts (pool already initialized).

## 4. Funding via the Uniswap UI (the Safe)

The pool is a standard v4 AMM — the hook has no liquidity callbacks — so position management is
the normal Uniswap web-app flow, executed by the Safe via WalletConnect. The exact call shape the
UI produces (Permit2 allowance + PositionManager `modifyLiquidities`) is pinned by
`test/WethWstGbpPositionManager.t.sol` against the real mainnet PositionManager, including the
treasury bracket below.

1. app.uniswap.org → connect the Safe → New position → v4 → paste both token addresses
   (wstGBP is not on default lists — expect an "unknown token" notice) → select the pool
   (dynamic-fee, hook `= $WETH_HOOK`; expect a caution banner for an unrecognized hook — ours).
2. Enter the range as **min/max prices**. For the cable-hardened treasury bracket
   (WETH $1,400–$10,000 guaranteed across GBP/USD 1.10–1.45; recompute per README if you change it):
   - quoted as wstGBP per WETH: **min 961 / max 9,048** (ticks −68,640 / −91,140 after snapping)
   - quoted as WETH per wstGBP (if the UI shows the flipped orientation): **min 0.0001105 / max 0.0010406**
   The app snaps to tickSpacing 60 itself.
3. **Small test add first** (e.g. 0.1 WETH + matching wstGBP), confirm the position renders and a
   probe swap charges the expected fee, then add the real size. Deposit amounts auto-balance to the
   range ratio in the UI.
4. The position NFT lives in the Safe. Ongoing management is UI buttons: **Collect fees**
   (optionally once or twice a year, re-adding via Increase liquidity — never compounding at all
   costs only ~f²/2 per year, ≈0.5%/yr at a 10% fee APR), **Increase/Remove liquidity** for
   resize/exit. Nothing is time-critical, ever: out-of-range or untouched positions just idle.

## 5. Post-deploy verification

```bash
# stock v4 Quoter parity probe (fee-only hook => exact quotes):
cast call 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203 \
  "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))(uint256,uint256)" \
  "(($WSTGBP,$WETH,8388608,60,$WETH_HOOK),true,1000000000000000000,0x)"
monitoring/check_feeds.sh
```

Then one small live swap each direction and confirm the `SwapFee` event decodes with the expected
fee (30 bps mint side / 5 bps redeem side at ~zero deviation).

## 6. Monitoring activation

1. Submit the hook ABI to Dune decoding; the committed queries in `monitoring/dune/*.sql` run in
   raw-log form immediately (real topic0 hashes baked in).
2. Create the queries; schedule `alert_sustained_fallback.sql` hourly with alert-on-results.
3. Cron `monitoring/check_feeds.sh` every 15 min with a mailer — it watches the oracle root cause
   the on-chain events can't (a quiet pool in fallback emits nothing).
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

`src/weth/POLCompounder.sol` (fully tested, 22-test fork suite) is an automation upgrade for a
future where fee volume justifies keeper-driven compounding: it holds the position directly in the
PoolManager and compounds in one call (poke → oracle-bounded rebalance ± `toleranceBps` vs the same
OracleLib fair the hook uses → add liquidity), with principal structurally unable to leave the pool
during a compound. Migration path: Remove liquidity in the UI → deploy a compounder over the chosen
range (constructor takes the PoolKey + ticks; owner = deployer for setup) → allowlist a keeper →
transfer the funds in → `compound()` bootstraps the position → Ownable2Step transfer to the Safe
(which must `acceptOwnership()`, selector `0x79ba5097`). Keeper policy if adopted: compound when
gas < ~150 bps of `compoundable()` value and the pool sits near fair (the rebalance execution-price
bound budgets the hook's own 30 bps mint-side fee inside the 50 bps default tolerance);
`NothingToCompound` / `PriceOutOfBounds` reverts are normal and lose nothing.
