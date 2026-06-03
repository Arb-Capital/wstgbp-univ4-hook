# CLAUDE.md — tGBP/wstGBP Uniswap V4 Backstop Hook

## What this is

A Uniswap **v4 hook** that turns a `tGBP/wstGBP` pool into an effectively **infinite-depth market
with a tight, ever-rising ~25bps band**, by routing swaps through wstGBP's atomic mint/redeem at the
protocol's own oracle prices:

- **Buy wstGBP** (pay tGBP) executes at `wstGBP.mintcost()` — the hook calls `wstGBP.mint`.
- **Sell wstGBP** (receive tGBP) executes at `wstGBP.burncost()` — the hook calls `wstGBP.redeem`.
- `burncost` sits ~25bps below `mintcost`; that spread is the bid/ask and is captured by the wstGBP
  protocol itself, **not** this hook (no extra hook fee). Both prices ratchet up as NAV accrues.

Status: **two hook variants, both fork-tested** (choose one per pool):
- **`WstGBPBackstopHook`** — pure backstop, LP blocked. Buys at `mintcost`, sells at `burncost`,
  infinite depth via wstGBP mint/redeem.
- **`WstGBPHybridHook`** — best execution: consume in-band third-party LP first (pool fee to LPs),
  backstop the rest; with no LP it behaves identically to the pure backstop.

Both are ownerless, hold no capital, and share the settle-first router + quoter. Open work (an
LP-aware quoter, etc.) is tracked in **[`ROADMAP.md`](ROADMAP.md)** (the durable backlog).

## Mainnet addresses

| Thing | Address |
|---|---|
| tGBP (currency0) | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` (proxy; impl `0x94321D80d3C5cdaC63B75F723AE64Ca7F94bE547`) |
| wstGBP / MaseerOne (currency1) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| MaseerGate `act` (market timing/fees) | `0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f` |
| MaseerGuardOZ `cop` (compliance) | `0x794cF5948444b14105587455EbE96Caace036d52` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| v4 PositionManager / Quoter / StateView | `0xbd21…ee9e` / `0x52f0…1203` / `0x7ffe…7227` |

tGBP `0x27f6…` < wstGBP `0x57C3…`, so in the pool **currency0 = tGBP, currency1 = wstGBP**, and
`zeroForOne == true` is a **BUY** of wstGBP, `false` is a **SELL**. Both tokens are 18 decimals;
all prices are WAD (1e18) tGBP-per-wstGBP.

## wstGBP wrapper mechanics (reference source: `../maseer-one/src`, read-only)

- `mint(uint256 amtTgbpIn) returns (uint256 wstOut)` — pulls `amtTgbpIn` tGBP from `msg.sender`
  (needs prior tGBP approval to wstGBP), mints `wstOut = amtTgbpIn * 1e18 / mintcost()` to
  `msg.sender`. Reverts if `!mintable()`, `amtTgbpIn < mintcost()` (dust), or
  `totalSupply + wstOut > capacity()`.
- `redeem(uint256 amtWstIn) returns (uint256 id)` — burns `amtWstIn` wstGBP from `msg.sender`;
  because this deployment has `cooldown() == 0` it **atomically** transfers
  `tGBP = amtWstIn * burncost() / 1e18` back in the same call — **but only up to the wrapper's
  current tGBP balance** (can underpay), and it **returns the redemption id, not the tGBP amount**
  (measure tGBP received by balance diff). Reverts if `!burnable()` or `amtWstIn < 1e18`.
- `mintcost()` / `burncost()` / `navprice()` — WAD prices; live from the oracle, ratchet weekly.
- `mintable()/burnable()` are **time-gated** by governance slots in MaseerGate (`block.timestamp`
  between open/halt). `capacity()` caps total wstGBP supply. `cooldown()` is 0 on this deployment.
- **Compliance is a blacklist, permissive by default.** Every `mint`/`redeem`/`transfer`/
  `transferFrom`/`approve` is gated by `cop.pass(party) == !isBanned(party)`. So the hook,
  PoolManager, routers, and every swapper only need to **not be on the ban list** — no allowlisting.
  One quirk: `wstGBP.transfer` reverts if `dst == wstGBP` itself; the hook only ever transfers to
  the PoolManager, so this is fine.

## The hook design (the important part)

Files: `src/WstGBPBackstopHook.sol` (pure backstop), `src/WstGBPHybridHook.sol` (best-ex with LP),
`src/base/BaseHook.sol` (vendored base), `src/interfaces/IwstGBP.sol`,
`src/periphery/WstGBPSwapRouter.sol` (settle-first router), `src/periphery/WstGBPQuoter.sol` (quoter).

Both are **return-delta custom-curve hooks**. The shared **backstop** core: `beforeSwap` returns a
`BeforeSwapDelta` whose specified leg cancels the swap (AMM bypassed), `take`s the input from the
PoolManager, calls `wstGBP.mint`/`redeem`, and `settle`s the output — wrapping the swap's own tokens
at `mintcost` (buys) / `burncost` (sells), read live each swap, exact-in and exact-out.

`WstGBPHybridHook` adds, before that backstop, a reentrancy-guarded **nested `poolManager.swap`**
bounded at the fee-adjusted edge (`mintcost*(1-fee)` buys / `burncost/(1-fee)` sells) so any in-band
LP fills through the real AMM (pool fee to LPs); it then backstops only the residual and combines
both into one delta. The `fee` in that edge is the **full directional swap fee v4 charges** — the LP
fee combined with any pool protocol fee (read from `slot0`, M-01 fix) — so the AMM never fills past
the true backstop edge even when a protocol fee is enabled. With no in-range LP it fills nothing and
equals the pure backstop. LP priced worse than the current edge is never used (the backstop is always
≥ as good) and is arbed back into the band. Dynamic-fee and ≥100% fee pool keys are rejected
(`PoolNotSupported`, L-01 fix). `WstGBPBackstopHook` simply blocks LP (`beforeAddLiquidity` reverts)
and always backstops the full amount.

### Routing: how the input reaches the hook (this is the crux)

`beforeSwap` runs *inside* `PoolManager.swap`, before the taker has paid. So the input must already
be in the PoolManager when the hook runs: swaps must be **settle-first** (pay the input, then swap).
The hook holds **no capital and has no owner** — it simply `take`s the input the router pre-paid,
wraps/unwraps it via the wrapper, and settles the output.

- **Use `src/periphery/WstGBPSwapRouter.sol`** (or any settle-first solver/aggregator integration):
  it settles the input, swaps, and refunds unused input (exact-output uses a `maxAmountIn` bound).
  Depth is bounded only by `capacity()` (buys) and the wrapper's own tGBP reserves (sells).
- **Stock "swap-then-settle" routers are not supported** — they pay input *after* `swap()` returns,
  so the hook's `take` finds nothing and reverts (`test_swapFirstRoutingIsUnsupported` documents
  this). Supporting them would require the hook to front capital, which is deliberately omitted.

### Settlement — the backstop leg (currency0 = tGBP, currency1 = wstGBP)

The in-band LP leg is an ordinary (nested) AMM swap, fee to LPs. The **backstop** leg (the residual
after the AMM, or the whole swap when there's no LP) settles per case:

| Swap | take (input from PM) | wrapper call | settle (to PM) | BeforeSwapDelta(spec, unspec) |
|---|---|---|---|---|
| Buy exact-in | tGBP `in` | `mint(in)` → `out` | wstGBP `out` | `(+in, -out)` |
| Buy exact-out | tGBP `ceil(out·mintcost/1e18)` | `mint(in)` (≥out; dust kept) | wstGBP `out` | `(-out, +in)` |
| Sell exact-in | wstGBP `in` | `redeem(in)` → `recv` | tGBP `recv` | `(+in, -recv)` |
| Sell exact-out | wstGBP `ceil(out·1e18/burncost)` | `redeem(in)` (≥out; dust kept) | tGBP `out` | `(-out, +in)` |

- Exact-output rounds the input **up** (`FullMath.mulDivRoundingUp`); the wrapper over-delivers by at
  most ~1 wei, which stays in the hook as harmless dust (no recovery function — economically nil).
- Sells pre-check `tGBP.balanceOf(wstGBP) >= claim` and revert `WrapperUnderfunded` rather than
  burn wstGBP into an underfunded redeem (redeem burns first, then pays).
- Settlement order to pay PM: `sync(currency) → transfer → settle()`. `take` needs no sync. The hook
  operates directly on the PoolManager inside the existing swap lock (no nested `unlock`).

### Permissions / deployment

Flag bits encode the permissions, so the address must be **mined** (CREATE2). Hybrid:
`beforeSwap` + `beforeSwapReturnDelta` = **`0x88`** (LP allowed), pool fee 5bps / tickSpacing 60.
Backstop: those plus `beforeAddLiquidity` (revert) = **`0x888`**, pool fee 0 / tickSpacing 1.
`script/DeployHook.s.sol` mines + deploys either via env `HOOK=hybrid` (default) or `HOOK=backstop`,
plus the router + quoter. Both hooks are ownerless and hold no capital. Ensure the hook address is
not on the tGBP ban list.

## Integration: quoting & swapping

The **backstop** price is the wrapper's oracle price (not pool state) — a pure read. It is **exact on
a no-LP pool**, and a **conservative bound** when in-band LP is present (real execution is then at
least as good; for the **exact hybrid blend** use `WstGBPHybridQuoter`, below). The stock v4
`Quoter` is swap-first and **reverts** on this hook, so use one of:

- **Off-chain formula** (live values from `wstGBP.mintcost()` / `burncost()`, both WAD):
  - buy exact-in: `wstGBP_out = tGBP_in * 1e18 / mintcost`
  - sell exact-in: `tGBP_out = wstGBP_in * burncost / 1e18`
  - buy exact-out: `tGBP_in = ceil(wstGBP_out * mintcost / 1e18)`
  - sell exact-out: `wstGBP_in = ceil(tGBP_out * 1e18 / burncost)`
- **On-chain backstop quoter** `src/periphery/WstGBPQuoter.sol` — `quoteExactInput`/`quoteExactOutput`
  return the backstop price (exact with no LP; a ceiling on buy cost / floor on sell proceeds when LP
  is present), and `previewSwap(zeroForOne, amountSpecified)` also returns `(executable, reason)`
  (checks market open, dust thresholds, buy capacity, sell funding, redeem cooldown).
- **On-chain LP-aware quoter** `src/periphery/WstGBPHybridQuoter.sol` — for the hybrid hook:
  `quoteExactInput(key, …)` / `quoteExactOutput(key, …)` return the **exact** blended price by
  replaying v4's `Pool.swap` over live pool state (`StateLibrary`) to the backstop edge, then pricing
  the residual at the oracle. Fork-validated `quote == execution` for all four modes (+ fuzz). Takes a
  `PoolKey` and the PoolManager; assumes a static LP fee (deployed pools aren't dynamic-fee).
  `previewSwap(key, zeroForOne, amountSpecified)` adds `(executable, reason)` — the wrapper checks
  (market open, capacity, funding, cooldown) apply **only to the backstop residual**, so a swap fully
  filled by LP is executable even with the wrapper market closed.

Execute via `src/periphery/WstGBPSwapRouter.sol` (settle-first):
`swapExactInput(key, zeroForOne, amountIn, minAmountOut, recipient, deadline)` and
`swapExactOutput(key, zeroForOne, amountOut, maxAmountIn, recipient, deadline)`. Quotes are
point-in-time (the oracle ratchets up), so always pass real slippage bounds. `recipient == address(0)`
means `msg.sender`; exact-output refunds unused input to the payer and **enforces full delivery** of
the requested output. There are also `swapExactInputPermit2`/`swapExactOutputPermit2` variants that
fund the swap via a Permit2 SignatureTransfer (the payer signs a `PermitTransferFrom` and approves the
canonical Permit2 instead of this router; the deadline is the permit's). The router emits a
`Swap(payer, recipient, poolId, zeroForOne, amountIn, amountOut)` event per swap.

## Build / test / deploy

```bash
forge build
forge fmt
ETH_RPC_URL=<archive-or-full-rpc> forge test -vv          # fork tests; defaults to a public RPC if unset
forge test --match-test test_buyExactInput -vvv           # single test
forge script script/DeployHook.s.sol --rpc-url $ETH_RPC_URL --broadcast --private-key $PK
```

Tests fork mainnet and run against the **real** wstGBP/tGBP/oracle and the canonical PoolManager; the
hook is mined+deployed on the fork. The MaseerGate is forced open via
`vm.store(act, keccak256("maseer.gate.mint.open"), 0)` etc. for determinism. Two suites (62 tests):
- `test/WstGBPBackstopHook.t.sol` (28) — the pure-backstop hook + router + quoter: pricing × 4, 25bps
  round-trip, quoter == execution (4 modes + fuzz), `previewSwap` flags, router hardening (minOut /
  maxIn / deadline / recipient / surplus refund, Permit2), LP-add revert, market-closed + underfunded
  + cooldown + capacity reverts, swap-first routing reverting, **L-02** capacity-uses-minted-amount.
- `test/WstGBPHybridHook.t.sol` (34) — the hybrid with real LP: buy/sell × exact-in/out blend LP then
  backstop and beat the pure-backstop price; no-LP ⇒ exact backstop; price-past-edge ⇒ AMM skipped +
  out-of-band LP ignored; large swap; LP earns the fee; cooldown LP-only fallback; LP-quote ==
  execution (4 modes + fuzz); the **sub-threshold residual** edges (exact-in dust refunded not
  charged; exact-out residual reverts `BackstopResidualTooSmall`; quoter parity); and **M-01**
  protocol-fee-aware edge (buy/sell) + **L-01** dynamic/≥100%-fee rejection.

## Dependencies / toolchain

- `lib/v4-periphery` @ `363226d` (the "Permissioned Pools" main; **note it no longer ships
  `src/utils/BaseHook.sol`**, which is why we vendor `src/base/BaseHook.sol`) with nested
  `lib/v4-core` @ `v4.0.0` (`59d3ecf5`). Imports use the `@uniswap/v4-core/...` prefix
  (see `remappings.txt`).
- solc **0.8.28**, `evm_version = cancun` (v4 flash accounting needs EIP-1153 transient storage; the
  hybrid hook's reentrancy guard is a `transient` state var, which needs 0.8.28). `via_ir = true` by
  default (~1.2% lower runtime gas on the fork suite; the `viair` profile is kept as an explicit alias).

## Gotchas

- Periphery `main` dropped `BaseHook` from `src/` — don't `import` it from periphery; use the
  vendored `src/base/BaseHook.sol`.
- `wstGBP.redeem` returns an **id, not an amount**, and can underpay — always balance-diff and
  pre-check funding.
- **Hybrid sub-threshold residual:** in `WstGBPHybridHook`, a backstop residual below the wrapper's
  mint/redeem threshold (`< mintcost` for buys / `< 1 wstGBP` for sells) can't be wrapped. Exact-input
  **refunds** it (bills only the AMM-filled leg, `ammIn + inConsumed`); exact-output **reverts**
  `BackstopResidualTooSmall` (it never clamps the input up to overcharge, so the hybrid is never worse
  than the pure backstop and the hook keeps no dust). `WstGBPHybridQuoter` mirrors both: the exact-in
  quote is a *lower bound* there, and `quoteExactOutput` reverts / `previewSwap` flags it
  (`"residual below wrapper threshold"`).
- v4 `PoolSwapTest` refunds leftover native balance to `msg.sender`; test/integrator contracts that
  call it need a payable `receive()`.
- Swaps must be settle-first (input paid before `swap`). Stock swap-first routers revert on `take`;
  route via `WstGBPSwapRouter` or a settle-first solver/aggregator integration.

## Roadmap / open work

Tracked in **[`ROADMAP.md`](ROADMAP.md)** — keep it current across sessions. Done: both hooks,
settle-first router with slippage/deadline/recipient + exact-output full-delivery, the backstop quoter,
the **LP-aware `WstGBPHybridQuoter`** (exact hybrid blend, fork-validated), deploy wiring, a security
review pass (F1 redeem-validation + cooldown fallback fixed; F2/F3 hybrid sub-threshold-residual edges
fixed — exact-in refunds, exact-out reverts `BackstopResidualTooSmall`, no dust capture, quoter mirrors;
trust model in `README.md`), test hardening (capacity, pricing fuzz, LP-quote==execution fuzz), the
hybrid `previewSwap`, Permit2 router entrypoints, and router `Swap` events. Open headlines:

- **Hardening:** pin submodule tags (needs a git repo). An external audit is the real gate before
  mainnet.
