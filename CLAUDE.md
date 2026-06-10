# CLAUDE.md — tGBP/wstGBP Uniswap V4 Backstop Hook

## What this is

A Uniswap **v4 hook** that turns a `tGBP/wstGBP` pool into an effectively **infinite-depth market
with a tight, ever-rising ~25bps band**, by routing swaps through wstGBP's atomic mint/redeem at the
protocol's own oracle prices:

- **Buy wstGBP** (pay tGBP) executes at `wstGBP.mintcost()` — the hook calls `wstGBP.mint`.
- **Sell wstGBP** (receive tGBP) executes at `wstGBP.burncost()` — the hook calls `wstGBP.redeem`.
- `burncost` sits ~25bps below `mintcost`; that spread is the bid/ask and is captured by the wstGBP
  protocol itself, **not** this hook (no extra hook fee). Both prices ratchet up as NAV accrues.

Status: **`WstGBPBackstopHook` is the single hook in scope** (fork-tested) — pure backstop, LP blocked.
Buys at `mintcost`, sells at `burncost`, infinite depth via wstGBP mint/redeem. It is ownerless, holds
no capital, and ships with the settle-first router + backstop quoter.

**Decision (2026-06-03):** ship the pure backstop for external audit and deployment. A `WstGBPHybridHook`
variant (consume in-band third-party LP first, pool fee to LPs, backstop the rest; identical to the pure
backstop with no LP) was built and evaluated, then **deferred** — its extra surface (nested
`poolManager.swap`, transient reentrancy guard, fee-adjusted edge math, sub-threshold residual paths)
isn't worth the larger audit when best-execution against any *separate* vanilla LP pool can be handled at
the routing layer (Uniswap routing / UniswapX + arbitrage). The fully-fixed hybrid (incl. its M-01/L-01
fixes) is preserved in git history at commit `b7a5c5a`; revive it only if in-pool LP demand materializes.
Audit scope is in **[`AUDIT_SCOPE.md`](AUDIT_SCOPE.md)**; the durable backlog in **[`ROADMAP.md`](ROADMAP.md)**.

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

Files (in scope): `src/WstGBPBackstopHook.sol` (the hook), `src/base/BaseHook.sol` (vendored base),
`src/interfaces/IwstGBP.sol`, `src/interfaces/IMaseerFeeds.sol` (the wrapper's cached price feeds),
`src/periphery/WstGBPSwapRouter.sol` (settle-first router), `src/periphery/WstGBPQuoter.sol` (quoter).

`WstGBPBackstopHook` is a **return-delta custom-curve hook**. Its **backstop** core: `beforeSwap`
returns a `BeforeSwapDelta` whose specified leg cancels the swap (AMM bypassed), `take`s the input from
the PoolManager, calls `wstGBP.mint`/`redeem`, and `settle`s the output — wrapping the swap's own tokens
at `mintcost` (buys) / `burncost` (sells), read live each swap, exact-in and exact-out. It blocks LP
(`beforeAddLiquidity` reverts) and always backstops the full amount.

**Deferred — the hybrid (in git history at `b7a5c5a`, not in the tree):** `WstGBPHybridHook` added,
before the backstop, a reentrancy-guarded nested `poolManager.swap` bounded at the fee-adjusted edge so
in-band LP fills through the real AMM, then backstopped the residual; with no LP it equalled the pure
backstop. It carried the M-01 (protocol-fee-aware edge) and L-01 (dynamic/≥100% fee rejection) fixes and
its own `WstGBPHybridQuoter`. Not audited/deployed — see the decision note above.

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

- Exact-output rounds the input **up** (`FullMath.mulDivRoundingUp`); the wrapper over-delivers by
  price-bounded dust (≤ 1 wei at NAV ≥ 1; up to `1e18/mintcost` wei at sub-par NAV), which stays in
  the hook as harmless dust (no recovery function — economically nil).
- Sells pre-check `tGBP.balanceOf(wstGBP) >= claim` and revert `WrapperUnderfunded` rather than
  burn wstGBP into an underfunded redeem (redeem burns first, then pays).
- Settlement order to pay PM: `sync(currency) → transfer → settle()`. `take` needs no sync. The hook
  operates directly on the PoolManager inside the existing swap lock (no nested `unlock`).

### Permissions / deployment

Flag bits encode the permissions, so the address must be **mined** (CREATE2). Backstop:
`beforeSwap` + `beforeSwapReturnDelta` + `beforeAddLiquidity` (revert) = **`0x888`**, pool fee 0 /
tickSpacing 1. `script/DeployHook.s.sol` mines + deploys the hook plus the router + quoter, and asserts
the hook's cached `act`/`pip` feed proxies match the wrapper's (I-02). The hook is ownerless and holds
no capital. Ensure the hook address is not on the tGBP ban list.

## Integration: quoting & swapping

The **backstop** price is the wrapper's oracle price (not pool state) — a pure read, and **exact** for
this pool (LP is blocked, so there is no AMM leg to blend). The stock v4 `Quoter` is swap-first and
**reverts** on this hook, so use one of:

- **Off-chain formula** (live values from `wstGBP.mintcost()` / `burncost()`, both WAD):
  - buy exact-in: `wstGBP_out = tGBP_in * 1e18 / mintcost`
  - sell exact-in: `tGBP_out = wstGBP_in * burncost / 1e18`
  - buy exact-out: `tGBP_in = ceil(wstGBP_out * mintcost / 1e18)`
  - sell exact-out: `wstGBP_in = ceil(tGBP_out * 1e18 / burncost)`
- **On-chain backstop quoter** `src/periphery/WstGBPQuoter.sol` — `quoteExactInput`/`quoteExactOutput`
  return the exact backstop price, and `previewSwap(zeroForOne, amountSpecified)` also returns
  `(executable, reason)` (checks market open, dust thresholds, buy capacity, sell funding, redeem
  cooldown).

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
ETH_RPC_URL=<archive-or-full-rpc> make test               # fast suites (feature + fuzz); fork — public RPC if unset
make test-invariant                                       # the slow stateful fork invariant suite (~10 min) only
make test-all                                             # everything, including the invariant suite
forge test --match-test test_buyExactInput -vvv           # single test
make coverage                                             # first-party src coverage (excludes the slow invariant suite)
make gen-report                                           # + HTML report → docs/coverage-report/ (gitignored); needs lcov/genhtml
make serve-report                                         # serve report at localhost:8000 (Flatpak/Snap browsers can't load file:// CSS via the doc portal)
make deploy-dry                                           # simulate the deploy on a mainnet fork (no broadcast, no key)
ETH_RPC_URL=<rpc> PK=<key> ETHERSCAN_API_KEY=<key> make deploy   # broadcast + --slow + Etherscan verify
```

Tests fork mainnet and run against the **real** wstGBP/tGBP/oracle and the canonical PoolManager; the
hook is mined+deployed on the fork. The MaseerGate is forced open via
`vm.store(act, keccak256("maseer.gate.mint.open"), 0)` etc. for determinism. The shared fork
scaffolding (mine/deploy/init/seed, slot constants, swap/quote/sign helpers, plus `_setNav`/`_setSpreads`
for driving the oracle) lives in `test/base/WstGBPForkBase.sol`; all three suites inherit it. 63 tests
across three suites:
- `test/WstGBPBackstopHook.t.sol` (48) — the pure-backstop hook + router + quoter: pricing × 4, 25bps
  round-trip, quoter == execution (4 modes + fuzz), `previewSwap` flags, router hardening (minOut /
  maxIn / deadline / recipient / surplus refund, Permit2), LP-add revert, market-closed + underfunded
  + cooldown + capacity reverts, swap-first routing reverting, **L-02** capacity-uses-minted-amount,
  **I-02** cached-feed-proxies-match-wrapper for both the hook (`test_cachedFeedsMatchWrapper`) and the
  quoter (`test_quoterCachedFeedsMatchWrapper`), red-team regressions, and defensive coverage for pool
  guards, redeem/transfer failures, router auth, and preview branches.
- `test/WstGBPBackstopHookFuzz.t.sol` (11) — adversarial math/attack-vector fuzz: quoter == execution
  for all four modes across the **whole** oracle price range (NAV driven 0.01–100 WAD via `vm.store`),
  exact-out input is the fair ceiling with no >1-wei over-charge, sub-par-NAV over-mint stays bounded
  dust, buy→sell / sell→buy round-trips can never profit, a donated hook balance changes no price and
  can't be drained, extreme-price/`int128`/zero-amount inputs revert cleanly, and Permit2 signatures
  can't be replayed.
- `test/WstGBPBackstopHookInvariants.t.sol` (4) — stateful suite: a `Handler` drives long random
  sequences of the four swap modes (constant NAV) and the invariants assert no value extraction, the
  ownerless hook is never drained / holds only bounded exact-out dust, quoter == execution on every
  swap, and the pool never acquires AMM liquidity. Config: `[profile.default.invariant]` runs 64 /
  depth 32 / `fail_on_revert = false` (the handler records any parity mismatch into a ghost the
  invariant surfaces, so lenient revert handling can't mask a violation).

## Dependencies / toolchain

- `lib/v4-periphery` @ `363226d` (the "Permissioned Pools" main; **note it no longer ships
  `src/utils/BaseHook.sol`**, which is why we vendor `src/base/BaseHook.sol`) with nested
  `lib/v4-core` @ `v4.0.0` (`59d3ecf5`). Imports use the `@uniswap/v4-core/...` prefix
  (see `remappings.txt`).
- solc **0.8.28**, `evm_version = cancun` (v4 flash accounting needs EIP-1153 transient storage; the
  toolchain was standardized on 0.8.28 during the gas-opt pass). `via_ir = true` by default (~1.2% lower
  runtime gas on the fork suite; the `viair` profile is kept as an explicit alias).

## Gotchas

- Periphery `main` dropped `BaseHook` from `src/` — don't `import` it from periphery; use the
  vendored `src/base/BaseHook.sol`.
- `wstGBP.redeem` returns an **id, not an amount**, and can underpay — always balance-diff and
  pre-check funding.
- v4 `PoolSwapTest` refunds leftover native balance to `msg.sender`; test/integrator contracts that
  call it need a payable `receive()`.
- Swaps must be settle-first (input paid before `swap`). Stock swap-first routers revert on `take`;
  route via `WstGBPSwapRouter` or a settle-first solver/aggregator integration.

## Roadmap / open work

Tracked in **[`ROADMAP.md`](ROADMAP.md)** — keep it current across sessions. Done: the backstop hook,
settle-first router with slippage/deadline/recipient + exact-output full-delivery, the backstop quoter +
`previewSwap`, Permit2 router entrypoints, router `Swap` events, deploy wiring (with the I-02 feed-proxy
assertion), a security-review + audit-fix pass (L-02 capacity; I-02 cached-feed regression test; I-03
`ffi=false`; M-01/L-01 fixed in the now-deferred hybrid), test hardening (capacity, pricing fuzz,
cached-feed parity), and a pre-deployment security review (2026-06-09,
`docs/SECURITY_REVIEW_2026-06-09.md` — **ship verdict**, no code findings, doc-only corrections; notably
wstGBP itself is NOT a proxy — only its `pip`/`act`/`cop` feeds and tGBP are). The hybrid was evaluated
and **deferred** (preserved at `b7a5c5a`). Open headlines:

- **Audit:** the backstop surface is in **[`AUDIT_SCOPE.md`](AUDIT_SCOPE.md)**. An external audit is the
  real gate before mainnet.
- **Hardening (deferred informational):** I-01 (canonical-PoolKey docs — done in `README.md`), I-04 (pin
  submodule tags / record the audited commit — documented in `AUDIT_SCOPE.md`).
