# tGBP/wstGBP Uniswap v4 Backstop Hook

A Uniswap **v4 hook** that gives a `tGBP/wstGBP` pool effectively **infinite depth inside a tight,
ever-rising ~25bps band** by routing swaps through the wstGBP wrapper's atomic `mint`/`redeem` at the
protocol's own oracle prices: **buys execute at `wstGBP.mintcost()`, sells at `wstGBP.burncost()`**.
The ~25bps spread is the wrapper's own bid/ask (no extra hook fee), and both prices ratchet up as NAV
accrues. The hook is **ownerless and holds no capital** — it wraps the swap's own tokens.

**`WsgemBackstopHook`** — the pure backstop: LP is blocked (`beforeAddLiquidity` reverts) and every
swap is `mint`/`redeem`. This is the single hook in scope for audit and deployment. Best execution
against any *separate* third-party LP pool is handled at the routing layer (Uniswap routing / UniswapX
+ arbitrage, which pins a vanilla pool inside the band). A `WstGBPHybridHook` variant that consumes
in-band LP inside the same pool was evaluated and **deferred** — it is preserved in git history (see
[`ROADMAP.md`](ROADMAP.md)) and can be revived if in-pool LP demand materializes.

v4 swaps must be **settle-first** — route via `src/v4/periphery/WsgemSwapRouter.sol` (or any settle-first
solver/aggregator). Quotes come from `src/v4/periphery/WsgemQuoter.sol` or the off-chain formula.

**Non-v4 venue (`src/adapter/WsgemDirectAdapter.sol`).** A standalone, ownerless `approve → swap` contract
that calls `wstGBP.mint`/`redeem` **directly** (no pool, no mined flags), with the same prices and guards as
the hook (shared `src/core/WsgemWrap.sol`). It uses ordinary swap-then-settle semantics, so DEX aggregators
(Odos / LI.FI / Paraswap) and CoW Protocol solvers can call it like any swap contract — no settle-first
router needed. `swapExactInput(tokenIn, amountIn, minAmountOut, recipient, deadline)` /
`swapExactOutput(...)` (+ Permit2 variants); `tokenIn == tGBP` buys, `tokenIn == wstGBP` sells. The same
trust model below applies (it is a pure price-taker — pass real slippage bounds). Note: "CoW Hooks" are
user pre/post-interactions, *not* a liquidity source; giving CoW solvers a route is
[route integration](https://docs.cow.fi/cow-protocol/tutorials/solvers/routes_integration) of this adapter.

**CoW-hook target (`src/adapter/WsgemHookHelper.sol`).** The wrap/unwrap target for CoW Swap *user*
hooks (pre/post-interactions executed by the public, untrusted HooksTrampoline). Owner-bound: anyone
may call `wrapAll`/`unwrap`/`unwrapAll(owner, ...)`, but funds move only owner→owner at the
wrapper's oracle prices, capped by the owner's allowance to the helper (`wrapAll` sweeps
`min(balance, allowance)`, since post-hook proceeds vary with surplus). Worst case for an arbitrary
caller is a fair-price forced conversion of the approved amount, delivered to the owner — bounded
griefing, no extraction. Same guards as the adapter via `WsgemWrap`.

Full design lives in [`CLAUDE.md`](CLAUDE.md); the backlog in [`ROADMAP.md`](ROADMAP.md). The audited surface
and scope are in [`AUDIT_SCOPE.md`](AUDIT_SCOPE.md).

---

## ⚠️ Trust model — read before integrating

**The hook adds no trust of its own — and removes none.** It has no owner, no admin, no pause, no
independent oracle, and no price bounds. It is a pure pass-through to the **wstGBP wrapper
and its governance**. Anyone swapping through this pool inherits, in full, the trust assumptions of the
wstGBP wrapper system. The execution price *is* whatever the wrapper's oracle and fee governance say it is
at that block; the hook does not sanity-check it.

### Powers that wstGBP governance / the oracle hold over every swap

| Lever | Where | Effect on swaps |
|---|---|---|
| **Oracle price** (`navprice`) | `pip` = the oracle price feed — a single storage slot `poke`d by privileged feeders; `pause()` sets it to 0 | Sets `mintcost`/`burncost`, i.e. the **exact execution price**. No on-chain freshness/staleness guard. Price 0 ⇒ all swaps revert (`InvalidPrice`). |
| **Spread / fees** (`bpsin`, `bpsout`) | `act` = the market-timing/fee feed, each settable up to **100%** | Widens/narrows the bid/ask (currently ~25bps). Could make execution arbitrarily unfavorable. |
| **Market open/close** (`mintable`/`burnable`) | `act`, timestamp-gated; `pauseMarket()` closes both | Closed mint ⇒ buys revert; closed burn ⇒ sells revert. |
| **Capacity** (`capacity`) | `act` | Caps total wstGBP supply; shrinking it blocks buys (`ExceedsCap`). |
| **Cooldown** (`cooldown`) | `act` | Non-zero breaks the *atomic* redeem a v4 swap requires. Handled: sells **revert** (`RedeemCooldownActive`) rather than burn wstGBP into a deferred payout. Buys are unaffected (mint is always atomic). |
| **Compliance / blacklist** (`cop.pass`) | `cop` = the compliance guard (`!isBanned`) | Gates every `mint`/`redeem`/`transfer`. Because the hook settles wstGBP to the PoolManager which then `take`s it to the recipient, **the hook, the PoolManager, AND the swap recipient must all stay un-banned** for buys (hook un-banned for every swap). A ban on the hook or the canonical PoolManager bricks the pool. |
| **Proxy upgrades** | `pip`, `act`, and `cop` are proxy instances (`file(impl)` swaps the implementation, **no timelock**); **tGBP is an EIP-1967 proxy**. `wstGBP` itself is **not** a proxy — its code and immutable wiring (`gem`/`pip`/`act`/`cop`) are fixed forever | All *pricing, gating, compliance, and underlying-token* behavior can change arbitrarily via the feed/guard/tGBP implementations, but the wrapper's `mint`/`redeem` mechanics cannot. Because the hook and quoter cache the same fixed `act`/`pip` addresses the wrapper reads, they stay price-identical to the wrapper even across feed upgrades. The hook's balance-diff and `RedeemUnderpaid` guard are only partial defense against hostile feed/tGBP implementations. |

### What protects the swapper

- **Always pass real slippage bounds.** Quotes are point-in-time and the oracle ratchets up between
  quote and execution. `WsgemSwapRouter` enforces `minAmountOut` (exact-input), `maxAmountIn`, and
  **full delivery of the exact output** (exact-output) — so a swap reverts rather than ever silently
  delivering less than you agreed to. Never send `minAmountOut = 0`.
- **Pre-flight with the quoter.** `WsgemQuoter.previewSwap(zeroForOne, amountSpecified)` returns
  `(amountIn, amountOut, executable, reason)` and reports the live blockers: market closed, dust
  threshold, capacity exceeded, wrapper underfunded, redeem cooldown active, or oracle paused — rather
  than reverting.
- **Pin the canonical `PoolKey`** (security-audit I-01). The router and quoter are intentionally generic
  over `PoolKey`; the hook validates only the two currencies, not the fee, tick spacing, or hook address.
  Integrators, bots, and frontends must hardcode/validate the canonical key
  (`currency0 = tGBP`, `currency1 = wstGBP`, `fee = 0`, `tickSpacing = 1`,
  `hooks = 0xfE36B48c9c0240991E4CEf006a2445F2ff524888`) and must never route through a user- or
  route-supplied key. The deploy script logs the canonical key.

### What integrators should monitor

- `wstGBP.cooldown()` — must be `0` for sells; non-zero makes sells revert (`RedeemCooldownActive`).
- `wstGBP.mintable()` / `wstGBP.burnable()` — market open/closed.
- `wstGBP.capacity()` vs `wstGBP.totalSupply()` — remaining buy headroom.
- `wstGBP.mintcost()` / `wstGBP.burncost()` — the live execution price (ratchets; governance/oracle can
  move it).
- `tGBP.balanceOf(wstGBP)` — sell-side funding depth (sells revert `WrapperUnderfunded` past it).
- The **proxy implementations** of `pip`/`act`/`cop` (proxy) and `tGBP` (EIP-1967) — watch for
  upgrades. `wstGBP` itself is not upgradeable.
- The **ban list** (`cop` / its guard source) — keep the hook, the PoolManager, and your recipients
  off it.

### Deployed contracts (mainnet)

Deployed 2026-06-28 (the hook helper 2026-07-03). The hook is CREATE2-mined for its permission
flags (`0x888`); all five are ownerless and hold no capital.

| Contract | Address |
|---|---|
| `WsgemBackstopHook` (the hook) | `0xfE36B48c9c0240991E4CEf006a2445F2ff524888` |
| `WsgemSwapRouter` (v4 settle-first router) | `0x21734507fDca48A3b4e8C496280b63a37D3bD0C8` |
| `WsgemQuoter` (backstop quoter) | `0x9B409f87aeaADBE912632b1E4de855B6aFCc71Ee` |
| `WsgemDirectAdapter` (aggregator / CoW adapter) | `0xBE402d34f31133B1Dc00277f24F8ce2d975CBe23` |
| `WsgemHookHelper` (CoW-hook wrap/unwrap target) | `0x4F93a2E29B0AA75875Ab922d780B6dc59b415B6A` |

The pool itself has no address — v4 is a singleton, so it lives inside the PoolManager keyed by
`poolId = keccak256(abi.encode(PoolKey))`:

| Pool | poolId |
|---|---|
| tGBP/wstGBP (fee 0, tickSpacing 1, hook `0xfE36…4888`) | `0xdb21c31f461611ebeeab8af1280c77a82bb81725e1bf9d6093fbbc207a375ce5` |

Swap on v4 through `WsgemSwapRouter` (settle-first); DEX aggregators / CoW solvers route through
`WsgemDirectAdapter` (`approve` + swap); CoW Swap user hooks target `WsgemHookHelper` (owner-bound
wrap/unwrap). Quote off-chain from `wstGBP.mintcost()`/`burncost()` or on-chain via `WsgemQuoter`.

### Key mainnet addresses

| Role | Address |
|---|---|
| tGBP (currency0, proxy) | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` |
| wstGBP (the wrapper, currency1) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| `act` feed (timing/fees/cooldown/capacity) | `0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f` |
| compliance guard `cop` (`!isBanned`) | `0x794cF5948444b14105587455EbE96Caace036d52` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |

`tGBP < wstGBP`, so **currency0 = tGBP, currency1 = wstGBP**; `zeroForOne == true` is a **BUY** of
wstGBP, `false` is a **SELL**. Both tokens are 18 decimals; all prices are WAD (1e18) tGBP-per-wstGBP.

---

## WETH/wstGBP dynamic-fee venue (`src/weth/`) — implemented, pre-deploy

> Non-developer introduction for traders and LPs: **[`docs/USER_GUIDE_WETH_WSTGBP.md`](docs/USER_GUIDE_WETH_WSTGBP.md)**.

A second, independent v4 hook: **`WethWstGbpHook`**, a **fee-only, oracle-aware dynamic-fee hook**
for a WETH/wstGBP pool ("volatility antenna" — converts ETH/GBP volatility into arb flow that routes
through the backstop venue above, while protocol-owned liquidity captures the deviation via fees).
Unlike the backstop it is a *real AMM pool*: LP is allowed, the hook only overrides the LP fee per
swap (`beforeSwap` returns `fee | OVERRIDE_FEE_FLAG`; no custom accounting, so the stock V4 Quoter
quotes it exactly). POL is held by a keeper-compounded `POLCompounder`. Owner (fee params + pause
only; logic immutable): the Arb Capital multisig `0x846a655a4fA13d86B94966DFDf4D9a070e554f7c`.

**Fee model.** `fee = clamp(directionalBase + toxicitySurcharge, minFee, maxFee)`; mint side
(wstGBP-in) base 30 bps, redeem side (WETH-in) base 5 bps (band symmetry: the wrapper redeem leg
carries a structural +25 bps). Surcharge applies only to swaps *closing* a pool-vs-fair deviation
`|d| >` 10 bps: `min(0.5 × (|d| − threshold), 60 bps)`. Oracle failure of any kind degrades to a
flat 30 bps fallback fee — `beforeSwap` never reverts on oracle state.

**Unit convention: everything is ppm.** The v4 lpFee unit is parts-per-million
(`MAX_LP_FEE = 1_000_000`); 1 bp = 100 ppm, so 30 bps = 3000. All fees, deviations, thresholds, and
the surcharge slope in `src/weth/` are ppm — no bps-denominated variable exists in code.

**Fair value composition** (`OracleLib`): `fair (wstGBP per WETH) = (ETH/USD ÷ GBP/USD) ÷ navprice`,
where `navprice()` is the wrapper's WAD tGBP-per-wstGBP NAV. `navprice() == 0` (pip paused) is an
explicit fallback trigger; the wstGBP leg is a manually-poked push oracle with **no on-chain
staleness signal** (documented limitation). The composed fair price is cached in **transient
storage per transaction** (EIP-1153) — multi-hop routes and bundles pay the Chainlink reads once;
deviation is recomputed from live `slot0` on every swap.

### Key mainnet addresses (WETH/wstGBP venue)

Verified on-chain and against the Chainlink reference data directory on 2026-07-04
(`cast call <feed> "description()(string)" / "decimals()(uint8)" / "latestRoundData()..."`).

| Role | Address | Notes |
|---|---|---|
| WETH (currency1) | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 decimals |
| wstGBP (currency0, the wrapper) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` | `0x57C3… < 0xC02a…` ⇒ wstGBP = currency0 |
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | 8 dec; heartbeat **3600s**, deviation **0.5%** → staleness window 4500s |
| Chainlink GBP/USD | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` | 8 dec; heartbeat **86400s**, deviation **0.15%** → staleness window 90000s |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` | singleton |
| v4 Quoter (stock) | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` | quotes this hook exactly (fee-only) |
| Owner multisig | `0x846a655a4fA13d86B94966DFDf4D9a070e554f7c` | `setFeeParams` / `setPaused` via Ownable2Step |

Staleness windows are heartbeat + margin — using the bare heartbeat would false-trigger fallback at
every update boundary. Dependency pins are unchanged from the backstop venue (v4-periphery
`363226d`, vendored v4-core `v4.0.0`); the Chainlink interface is vendored at
`src/weth/interfaces/IAggregatorV3.sol`.

**Gas** (vs an identical hookless static-fee pool, measured in `test/WethWstGbpGas.t.sol`,
2026-07-04): warm swap overhead (fair price cached this tx) **9,664** — meets the <10k target; cold
swap overhead (first swap of the tx) **66,397** — the spec's <40k target is **consciously waived**:
~35k of the cold path is irreducible external reads (two real Chainlink proxy→aggregator chains
≈24k + the wstGBP `navprice()` proxy chain ≈11k) that the target did not budget for. The test
enforces warm <10k and an 80k cold regression ceiling.

**POL is funded via the Uniswap UI, not scripts.** The hook has no liquidity callbacks, so the
pool is a standard v4 AMM: the treasury Safe mints/collects/removes positions through the web app /
canonical PositionManager like any pool (`test/WethWstGbpPositionManager.t.sol` pins the exact UI
call shape against the real mainnet PosM, including the treasury bracket). Launch flow = two script
txs (deploy hook, init pool at oracle fair — no funds move) + UI funding; see `DEPLOY.md`.
Range policy: bounds are **GBP-native and permanent** (the pool's coordinate is wstGBP-per-WETH);
their USD meaning floats with cable and creeps up ~4%/yr with the NAV ratchet. The chosen
cable-hardened treasury bracket (2026-07-04, efficiency-first: WETH $1,500–$8,000 guaranteed
across GBP/USD 1.10–1.45 at current NAV, deliberately not NAV-extended) is ticks
**−88,920 / −69,360** ≈ 1,028–7,270 wstGBP/WETH, ~2.59× full-range capital efficiency; the NAV
ratchet drifts the USD floor upward over the years (≈$2.2k after a decade), so `DEPLOY.md` §4
carries a yearly-review / re-range trigger.

**`POLCompounder`** (`src/weth/POLCompounder.sol`) is **optional automation, not in the launch
path**: a PoolManager-direct locker that compounds fees in one keeper call (poke → oracle-bounded
rebalance vs the same OracleLib fair ± 50 bps, skipped in fallback → add liquidity), principal
structurally unable to leave the pool during a compound. Fully tested; adopt later via the
migration path in `DEPLOY.md`'s appendix if fee volume ever justifies keeper infra (never
compounding at all costs only ~f²/2 ≈ 0.5%/yr at a 10% fee APR).

**Testing & docs**: 102 venue tests across 9 suites (unit ×2, fork, flipped-ordering, quoter
parity, gas, adversarial, PositionManager/UI-path, compounder) — `make test` / `make coverage`
(hook + libs 100% all metrics).
Adversarial/economic notes in [`SECURITY_WETH_WSTGBP.md`](SECURITY_WETH_WSTGBP.md); fee-parameter
sweep + recommendation in [`sim/RESULTS.md`](sim/RESULTS.md) (`make sim-sweep` regenerates);
deployment runbook in [`DEPLOY.md`](DEPLOY.md) (`make deploy-weth-hook[-dry]`,
`make init-weth-pool[-dry]`); Dune monitoring SQL + off-chain feed probe in `monitoring/`.

---

## Build / test

```bash
forge build
forge fmt
ETH_RPC_URL=<archive-or-full-rpc> make test          # fast suites (feature + fuzz); fork — public RPC if unset
make test-invariant                                  # the slow stateful fork invariant suite (~10 min) only
make test-all                                         # everything, incl. the invariant suite (a bare `forge test` also does)
forge test --match-test test_buyExactInput -vvv      # single test
make deploy-dry                                      # simulate the deploy on a mainnet fork (no broadcast, no key)
ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> ETHERSCAN_API_KEY=<key> make deploy   # keystore-signed broadcast + --slow + Etherscan verify
```

### Coverage (requires `lcov` / `genhtml`)

```bash
make coverage      # first-party src coverage summary to the terminal
make gen-report    # + HTML report into docs/coverage-report/ (gitignored)
make serve-report  # serve that report at http://localhost:8000
```

View the report via `make serve-report` rather than opening `index.html` directly: a
Flatpak/Snap browser opens local files through the xdg document portal, which shares only
the single file with the sandbox and so drops the report's CSS/images.

Both run via the `Makefile` and exclude the test suite, deploy script, and vendored
`src/v4/base/BaseHook.sol` so the report reflects only the first-party surface. Set
`ETH_RPC_URL` to an archive/full RPC for a reliable fork (the suite otherwise falls back
to a public RPC).

Tests fork mainnet against the **real** wstGBP/tGBP/oracle and the canonical PoolManager (86 tests across
five suites that share `test/base/WsgemForkBase.sol`). `test/WsgemBackstopHook.t.sol` (66): pricing ×
4, 25bps round-trip, quoter == execution + fuzz, `previewSwap` flags, router hardening + Permit2 matrix
(incl. the inclusive `deadline == now` boundary), LP-add revert, market-closed / underfunded / cooldown /
capacity reverts, cached-feed parity, swap-first-routing rejection, and a red-team pass — paused-oracle
preview, blacklist-bricks-pool (including banned output recipients, a banned payer — sell input gated,
buy input not — and a mid-block ban that proves compliance is re-checked, never cached), the hook applying
no slippage of its own, callback access control, and defensive transfer/redeem/pool-guard coverage.
`test/WsgemBackstopHookFuzz.t.sol` (12): adversarial math fuzzed across the whole oracle price range —
quoter == execution (all four modes), exact-out ceiling with no >1-wei over-charge, bounded
sub-par-NAV over-mint dust, round-trips that can never profit, a donated hook balance that changes no
price and can't be drained, clean reverts at the price/`int128`/zero-amount extremes plus correct
quoter == execution at the arithmetic extremes (mintcost 1 wei / 1e36), and Permit2 replay rejection. `test/WsgemBackstopHookInvariants.t.sol` (4): a stateful handler drives long random
swap sequences and asserts no value extraction, the ownerless hook is never drained, quoter == execution
every swap, and the pool never holds AMM liquidity. `test/WsgemSellFloorStress.t.sol` (2) and
`test/WsgemGasComparison.t.sol` (2) cover the swapper's economics: a multi-actor mass-exit that drains
the wrapper's gem reserve, proving the sell floor is bounded by that reserve, reverts wholesale when short
(no partial fill — sellers must self-fragment), and is asymmetric (buys keep filling while sells are cut
off); and a gas comparison showing the pool route is strictly dearer than a direct `mint`/`redeem` or the
adapter for the identical oracle price. A standalone `test/WsgemFlippedOrderingHook.t.sol` (4)
runs end-to-end buys and sells in the **flipped** token ordering (wsgem = currency0) against mock tokens,
proving the hook adapts when the wrapper sorts below its underlying. `script/DeployWstGBP.s.sol`
CREATE2-mines the hook for its permission flags (`0x888`), initializes the pool (fee 0 / tickSpacing 1),
and deploys the router + quoter + direct adapter; the hook address must not be on the tGBP/wstGBP ban list.
