# CLAUDE.md — tGBP/wstGBP Uniswap V4 Backstop Hook

## What this is

A Uniswap **v4 hook** that turns a `tGBP/wstGBP` pool into an effectively **infinite-depth market
with a tight, ever-rising ~25bps band**, by routing swaps through wstGBP's atomic mint/redeem at the
protocol's own oracle prices:

- **Buy wstGBP** (pay tGBP) executes at `wstGBP.mintcost()` — the hook calls `wstGBP.mint`.
- **Sell wstGBP** (receive tGBP) executes at `wstGBP.burncost()` — the hook calls `wstGBP.redeem`.
- `burncost` sits ~25bps below `mintcost`; that spread is the bid/ask and is captured by the wstGBP
  protocol itself, **not** this hook (no extra hook fee). Both prices ratchet up as NAV accrues.

Status: **`WsgemBackstopHook` is the single hook in scope** (fork-tested) — pure backstop, LP blocked.
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
| wstGBP (the wrapper, currency1) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| `act` feed (market timing/fees) | `0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f` |
| compliance guard `cop` (`!isBanned`) | `0x794cF5948444b14105587455EbE96Caace036d52` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| v4 PositionManager / Quoter / StateView | `0xbd21…ee9e` / `0x52f0…1203` / `0x7ffe…7227` |

tGBP `0x27f6…` < wstGBP `0x57C3…`, so in the pool **currency0 = tGBP, currency1 = wstGBP**, and
`zeroForOne == true` is a **BUY** of wstGBP, `false` is a **SELL**. Both tokens are 18 decimals;
all prices are WAD (1e18) tGBP-per-wstGBP.

### Deployed system (mainnet, 2026-06-28)

CREATE2-mined hook (flags `0x888`); all five ownerless and hold no capital. First four deployed by
`script/DeployWstGBP.s.sol`; the hook helper on 2026-07-03 by `script/DeployHookHelper.s.sol` (plain
CREATE, Etherscan-verified).

| Contract | Address |
|---|---|
| `WsgemBackstopHook` (the hook) | `0xfE36B48c9c0240991E4CEf006a2445F2ff524888` |
| `WsgemSwapRouter` (v4 settle-first router) | `0x21734507fDca48A3b4e8C496280b63a37D3bD0C8` |
| `WsgemQuoter` (backstop quoter) | `0x9B409f87aeaADBE912632b1E4de855B6aFCc71Ee` |
| `WsgemDirectAdapter` (aggregator / CoW adapter) | `0xBE402d34f31133B1Dc00277f24F8ce2d975CBe23` |
| `WsgemHookHelper` (CoW-hook wrap/unwrap target) | `0x4F93a2E29B0AA75875Ab922d780B6dc59b415B6A` |

The pool is initialized in the PoolManager (v4 singleton — no pool address); `poolId` =
`0xdb21c31f461611ebeeab8af1280c77a82bb81725e1bf9d6093fbbc207a375ce5` (`keccak256(abi.encode(PoolKey))`
over currency0=tGBP, currency1=wstGBP, fee 0, tickSpacing 1, hook above), started at `sqrtPriceX96 = 1:1`.

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
- `mintable()/burnable()` are **time-gated** by governance slots in the `act` feed (`block.timestamp`
  between open/halt). `capacity()` caps total wstGBP supply. `cooldown()` is 0 on this deployment.
- **Compliance is a blacklist, permissive by default.** Every `mint`/`redeem`/`transfer`/
  `transferFrom`/`approve` is gated by `cop.pass(party) == !isBanned(party)`. So the hook,
  PoolManager, routers, and every swapper only need to **not be on the ban list** — no allowlisting.
  One quirk: `wstGBP.transfer` reverts if `dst == wstGBP` itself; the hook only ever transfers to
  the PoolManager, so this is fine.

## Repo layout — two venues over one shared core

As of 2026-06-12 the repo holds **two swap venues** over the same wstGBP `mint`/`redeem`, sharing one core:

- **`src/core/`** — venue-agnostic shared code. `WsgemWrap.sol` (the lockstep-critical library: `price`,
  `quoteIn`/`quoteOut` exact rounding, `redeem` balance-diff safety, non-standard-ERC20 `transfer` — all
  `internal`, embedded into each venue), plus `interfaces/Iwsgem.sol` and `interfaces/IFeeds.sol`.
- **`src/v4/`** — the Uniswap v4 venue: `WsgemBackstopHook.sol`, `base/BaseHook.sol` (vendored),
  `periphery/WsgemSwapRouter.sol` (settle-first router), `periphery/WsgemQuoter.sol`. The hook's helper
  bodies delegate to `WsgemWrap`; `_beforeSwap` is unchanged.
- **`src/adapter/`** — the non-v4 venue: `WsgemDirectAdapter.sol`, a standalone ownerless `approve → swap`
  contract that calls `wstGBP.mint`/`redeem` **directly** (no pool, no mined flags) for DEX aggregators
  (Odos / LI.FI / Paraswap) and CoW Protocol solvers. Standard swap-then-settle semantics, exact-in/out +
  Permit2 + view quotes, direction inferred from `tokenIn`. Same rounding/redeem-safety/funding/cooldown
  guards as the hook (via `WsgemWrap`); cross-venue parity tests pin adapter == quoter == hook math.
  Also holds `WsgemHookHelper.sol` (2026-07-03) — the owner-bound wrap/unwrap target for CoW hooks (below).

**Why an adapter and not "a CoW hook":** CoW Hooks are user-attached pre/post *interactions* on an order,
**not** a liquidity source solvers route through. To give solvers a route you expose a normal swap contract
+ price discovery and propose it for [route integration](https://docs.cow.fi/cow-protocol/tutorials/solvers/routes_integration);
the same standard `approve → swap` adapter also satisfies Odos/LI.FI/Paraswap. v4 was the special case
(settle-first + mined flags); everything else just calls the adapter. Per-aggregator work is off-chain
**listing**, not new Solidity. Monorepo + one generic adapter was the chosen design (see [`ROADMAP.md`](ROADMAP.md)).

### CoW hooks (the user-facing track) — reference docs + mechanics

Distinct from solver route integration: a **Hook Store dapp** lets CoW Swap *users* attach wrap/unwrap
actions to their orders. Reference docs (verified 2026-07-03):

- Concepts: <https://docs.cow.fi/cow-protocol/concepts/order-types/cow-hooks> — pre-hooks run before
  settlement pulls the sell token; post-hooks after proceeds reach receivers. **Weak guarantee**: solver
  social consensus only; an order can fill even if its hook reverted — design so a skipped hook loses nothing.
- Mechanics: <https://docs.cow.fi/cow-protocol/reference/core/intents/hooks> — hooks are
  `{target, callData, gasLimit}` in the order's appData, executed via the **HooksTrampoline**, which is
  public and untrusted (anyone can call it, and hook callData is public) — a hook target must be safe
  under arbitrary callers/args. This is why `WsgemDirectAdapter` can't be a target (pulls from
  `msg.sender`; the trampoline holds no funds) and why `WsgemHookHelper` is owner-bound: anyone may
  trigger it, but funds flow only owner→owner at oracle price, capped by the owner's allowance
  (`wrapAll` sweeps `min(balance, allowance)` — post-hook proceeds vary with surplus, so the amount
  resolves at execution time).
- Building a hook dapp: <https://docs.cow.fi/cow-protocol/tutorials/hook-dapp> — iframe web app on
  `@cowprotocol/hook-dapp-lib` (`initCoWHookDapp` → context `{chainId, account, orderParams, isPreHook,
  hookToEdit}` → `actions.addHook`), plus a `manifest.json` (id = keccak256 of name, descriptions,
  image, `conditions.supportedNetworks` / optional `position`). Hosted externally at its own URL;
  testable unlisted via CoW Swap → Hooks → "My Custom Hooks" (paste the URL).
- Hook Store overview: <https://cowswap.mintlify.app/cow-swap/hooks/hook-store>; **listing** = PR to
  `cowprotocol/cowswap` adding a `type: 'IFRAME'` entry to `libs/hook-dapp-lib/src/hookDappsRegistry.ts`
  (see the bleu entries there for the shape; their dapps live in the standalone `bleu/cow-hooks-dapps`
  repo, deployed on Vercel — our dapp likewise lives in its own repo, not here).
- CoW Shed (`cowdao-grants/cow-shed`): the per-user proxy pattern for fund-moving hooks (EIP-712-signed
  calls, supports delegatecall). Evaluated and **not** used — the owner-bound helper is simpler (one
  approval, EOA-friendly, no proxy deploy) with the same bounded-griefing worst case.

The helper is deployed at `0x4F93a2E29B0AA75875Ab922d780B6dc59b415B6A` (2026-07-03, verified;
redeploy with `make deploy-hook-helper`, dry: `make deploy-hook-helper-dry`); remaining open items
(dapp repo, E2E, Hook Store listing) in [`ROADMAP.md`](ROADMAP.md) ("Decision (2026-07-03)").

## The hook design (the important part)

Files (v4 venue): `src/v4/WsgemBackstopHook.sol` (the hook), `src/v4/base/BaseHook.sol` (vendored base),
`src/core/interfaces/Iwsgem.sol`, `src/core/interfaces/IFeeds.sol` (the wrapper's cached price feeds),
`src/v4/periphery/WsgemSwapRouter.sol` (settle-first router), `src/v4/periphery/WsgemQuoter.sol` (quoter),
`src/core/WsgemWrap.sol` (shared math/redeem core).

`WsgemBackstopHook` is a **return-delta custom-curve hook**. Its **backstop** core: `beforeSwap`
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

- **Use `src/v4/periphery/WsgemSwapRouter.sol`** (or any settle-first solver/aggregator integration):
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
tickSpacing 1. `script/DeployWstGBP.s.sol` mines + deploys the hook plus the router + quoter + direct
adapter, and asserts the hook's cached `act`/`pip` feed proxies match the wrapper's (I-02). The hook is ownerless and holds
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
- **On-chain backstop quoter** `src/v4/periphery/WsgemQuoter.sol` — `quoteExactInput`/`quoteExactOutput`
  return the exact backstop price, and `previewSwap(zeroForOne, amountSpecified)` also returns
  `(executable, reason)` (checks market open, dust thresholds, buy capacity, sell funding, redeem
  cooldown).

Execute via `src/v4/periphery/WsgemSwapRouter.sol` (settle-first):
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
# RPC via optional .env (see .env.example): ETH_RPC_URL > ALCHEMY_API_KEY (composed Alchemy URL) >
# public fallback — honored by make targets AND direct forge runs (forge auto-loads .env; ForkBase)
make test-invariant                                       # the slow stateful fork invariant suite (~10 min) only
make test-all                                             # everything, including the invariant suite
forge test --match-test test_buyExactInput -vvv           # single test
make coverage                                             # first-party src coverage (excludes the slow invariant suite)
make gen-report                                           # + HTML report → docs/coverage-report/ (gitignored); needs lcov/genhtml
make serve-report                                         # serve report at localhost:8000 (Flatpak/Snap browsers can't load file:// CSS via the doc portal)
make deploy-dry                                           # simulate the deploy on a mainnet fork (no broadcast, no key)
ETH_RPC_URL=<rpc> ETH_FROM=<deployer> ETH_KEYSTORE=<keystore.json> ETHERSCAN_API_KEY=<key> make deploy   # broadcast + --slow + Etherscan verify (keystore-signed)
```

Tests fork mainnet and run against the **real** wstGBP/tGBP/oracle and the canonical PoolManager; the
hook is mined+deployed on the fork. The market gate (`act`) is forced open via
`vm.store(act, keccak256("maseer.gate.mint.open"), 0)` etc. for determinism. The shared fork
scaffolding (mine/deploy/init/seed, slot constants, swap/quote/sign helpers, plus `_setNav`/`_setSpreads`
for driving the oracle) lives in the concrete `test/base/WstGBPFixture.sol` (over the generic `ForkBase`),
reached by the three v4 suites via `WsgemForkBase`. 74 tests across three suites (plus a standalone
flipped-ordering e2e suite, below):
- `test/WsgemBackstopHook.t.sol` (59) — the pure-backstop hook + router + quoter: pricing × 4, 25bps
  round-trip, quoter == execution (4 modes + fuzz), `previewSwap` flags, router hardening (minOut /
  maxIn / deadline / recipient / surplus refund, Permit2), LP-add revert, market-closed + underfunded
  + cooldown + capacity reverts, swap-first routing reverting, **L-02** capacity-uses-minted-amount,
  **I-02** cached-feed-proxies-match-wrapper for both the hook (`test_cachedFeedsMatchWrapper`) and the
  quoter (`test_quoterCachedFeedsMatchWrapper`), red-team regressions, and defensive coverage for pool
  guards, redeem/transfer failures, router auth, and preview branches.
- `test/WsgemBackstopHookFuzz.t.sol` (11) — adversarial math/attack-vector fuzz: quoter == execution
  for all four modes across the **whole** oracle price range (NAV driven 0.01–100 WAD via `vm.store`),
  exact-out input is the fair ceiling with no >1-wei over-charge, sub-par-NAV over-mint stays bounded
  dust, buy→sell / sell→buy round-trips can never profit, a donated hook balance changes no price and
  can't be drained, extreme-price/`int128`/zero-amount inputs revert cleanly, and Permit2 signatures
  can't be replayed.
- `test/WsgemBackstopHookInvariants.t.sol` (4) — stateful suite: a `Handler` drives long random
  sequences of the four swap modes (constant NAV) and the invariants assert no value extraction, the
  ownerless hook is never drained / holds only bounded exact-out dust, quoter == execution on every
  swap, and the pool never acquires AMM liquidity. Config: `[profile.default.invariant]` runs 64 /
  depth 32 / `fail_on_revert = false` (the handler records any parity mismatch into a ghost the
  invariant surfaces, so lenient revert handling can't mask a violation).
- `test/WsgemFlippedOrderingHook.t.sol` (4) — end-to-end buys/sells in the **flipped** token ordering
  (wsgem = currency0, gem = currency1) against etched mock tokens, proving the hook adapts when the wrapper
  sorts below its underlying (the real tGBP/wstGBP pair never does). Standalone: own mocks, does not share
  `WstGBPFixture`.

## Dependencies / toolchain

- `lib/v4-periphery` @ `363226d` (the "Permissioned Pools" main; **note it no longer ships
  `src/utils/BaseHook.sol`**, which is why we vendor `src/v4/base/BaseHook.sol`) with nested
  `lib/v4-core` @ `v4.0.0` (`59d3ecf5`). Imports use the `@uniswap/v4-core/...` prefix
  (see `remappings.txt`).
- solc **0.8.28**, `evm_version = cancun` (v4 flash accounting needs EIP-1153 transient storage; the
  toolchain was standardized on 0.8.28 during the gas-opt pass). `via_ir = true` by default (~1.2% lower
  runtime gas on the fork suite; the `viair` profile is kept as an explicit alias).

## Gotchas

- Periphery `main` dropped `BaseHook` from `src/` — don't `import` it from periphery; use the
  vendored `src/v4/base/BaseHook.sol`.
- `wstGBP.redeem` returns an **id, not an amount**, and can underpay — always balance-diff and
  pre-check funding.
- v4 `PoolSwapTest` refunds leftover native balance to `msg.sender`; test/integrator contracts that
  call it need a payable `receive()`.
- Swaps must be settle-first (input paid before `swap`). Stock swap-first routers revert on `take`;
  route via `WsgemSwapRouter` or a settle-first solver/aggregator integration.
- The PoolManager `Swap` event logs ZERO amounts for the backstop (return-delta hook cancels the
  AMM leg) — reconstruct volume from PM↔hook ERC-20 transfer legs (see `monitoring/dune/README.md`).
  The weth venue's PM Swap amounts are real (fee-only hook, actual AMM).

## Second venue: WETH/wstGBP dynamic-fee hook (`src/weth/`) — DEPLOYED 2026-07-04

**Mainnet:** hook `0xe5F619EC8Af334Fb54CcEcf6802378cd2100E0c0` (flags `0x20C0`, owner = multisig);
poolId `0xaa4aebc5147167353ad9ac16d1fcb87e12aef62d9bd870d4bf5762cce166c920` (initialized block
25463628, tx `0xdaa9cab6…a64905`, tick −71,818, 0 ppm deviation). POL funding + Etherscan verify +
monitoring activation pending at deploy time; deploy ran from an uncommitted tree — the deploy rev
MUST be the next commit.

A separate product sharing the repo: **`WethWstGbpHook`**, a fee-only dynamic-fee hook for a
WETH/wstGBP pool ("volatility antenna" feeding arb flow into the backstop venue), plus
**`POLCompounder`** (keeper-compounded POL held directly in the PoolManager as its own locker).
Spec: `~/Insync/brian@brianmcmichael.com/Dropbox/Work/ARB/weth-wstgbp-v4-hook-plan.md`.

Key facts (full detail: README venue section, `SECURITY_WETH_WSTGBP.md`, `DEPLOY.md`, `sim/`):

- **Real AMM pool** (dynamic-fee flag, LP welcome), unlike the backstop. Hook only overrides the
  LP fee per swap: directional base (mint side wstGBP-in 30 bps = redeem side WETH-in 5 bps + the
  wrapper's 25 bps redeem leg) + toxicity surcharge on deviation-closing flow
  (`min(0.5×(|d|−10bps), 60bps)`), vs fair = `(ETH/USD ÷ GBP/USD) ÷ navprice()`. **All units ppm.**
- **Never reverts on oracle state** (raw-staticcall reads; `navprice()==0` = pip paused = fallback
  trigger; per-feed staleness windows 4500s/90000s); fallback = flat 30 bps. Fair price cached in
  **transient storage per transaction**; deviation recomputed from live slot0 every swap.
- **Fee-only ⇒ stock v4 Quoter is exact** (parity suite proves to the wei, all regimes). Fee
  observation in tests: the PM `Swap` event's `fee` field (slot0.lpFee stays 0 — trap).
- Owner (hook + compounder): Arb Capital multisig `0x846a655a4fA13d86B94966DFDf4D9a070e554f7c`
  (Ownable2Step; hook owner assigned at construction — no transfer step). Admin = `setFeeParams`
  (bounds-checked, ≤10% ceiling) + `setPaused` (changes pricing, never blocks swaps).
- Verified economic finding: **trade splitting is not fee-neutral** — slices converge to the
  linear schedule's integral (single swap pays the top-of-ramp premium). Documented, accepted for
  v1, factored into the sim recommendation (slope 0.5× not 1.0×).
- Gas: warm overhead 9,664 (<10k target met); cold 66,397 (spec's 40k waived — ~35k is
  irreducible oracle proxy reads; 80k regression ceiling in the gas test).
- Deploy: `make deploy-weth-hook[-dry]` → verify → `make init-weth-pool[-dry]` (**init-only**: pool
  created at oracle fair, no funds move) → **POL funded via the Uniswap UI from the Safe**
  (standard PositionManager NFT; `test/WethWstGbpPositionManager.t.sol` pins the UI call shape).
  `POLCompounder` is optional automation, NOT in the launch path (migration recipe in `DEPLOY.md`
  appendix). Range decision (2026-07-04, FINAL — supersedes the $1.4k–$10k draft): cable-hardened
  WETH **$1,500–$8,000** across cable 1.10–1.45 at current NAV, efficiency-first (deliberately not
  NAV-extended) = **ticks −88,920/−69,360** (1,028–7,270 wstGBP/WETH, ~2.59× full-range
  efficiency); NAV ratchet drifts the USD floor up (~$2.2k at 10y) — yearly review + re-range
  trigger documented in `DEPLOY.md` §4. Runbook `DEPLOY.md`; monitoring `monitoring/`.
- Out of the backstop audit's scope (AUDIT_SCOPE.md notes it); needs its own audit before POL
  scale-up. Sim harness: `sim/` (stdlib Python; `make sim-test` / `make sim-sweep`;
  `make sim-data` fetches Binance bars). Coverage note: gas suite excluded from `make coverage`
  (optimizer-off build breaks gas asserts — `COVERAGE_SKIP` in the Makefile).
- **Production-readiness pass done 2026-07-04** (`docs/READINESS_WETH_WSTGBP_2026-07-04.md`):
  everything re-run green, deploy+init rehearsed on anvil, fresh security review (no must-fix;
  the one should-fix — OracleLib uint80-decode revert path, F-1 — was APPLIED same day:
  `_readFeed` now decodes five full words; regression `test_dirtyUint80WordsStillReadable`).
  Stateful suites now exist: `test/WethWstGbpHookInvariants.t.sol` (8 invariants; etched
  `SettableFeed`s over the Chainlink proxies, independent FeeMath/OracleLib fee mirror per swap +
  transient-cache canary, stock-quoter parity per swap) and `test/POLCompounderInvariants.t.sol`
  (custody/principal; runs=32/depth=16 inline) — both under `make test-invariant`, excluded from
  `make test`/coverage by the `Invariants` name match. Handlers need a payable `receive()`
  (PoolSwapTest native refund — the documented gotcha).

## Third venue: wstGBP/USDC dynamic-fee hook (`src/usdc/`) — READINESS: GO 2026-07-05 (pre-deploy)

`UsdcWstGbpHook`: clone of the WETH venue for the near-stable cable pair (full track + findings in
`ROADMAP.md`; conveyor economics: the existing static 5bps pool `0xbe0f…bb10` drains via
buy-then-redeem arb each NAV ratchet — the hook recaptures the skim while keeping the 25bps/round-trip
protocol spread flowing; the sim objective is **house take** = LP PnL + protocol band revenue with a
conveyor-alive constraint). Deltas vs weth: **single-feed** fair `1e8·WAD²/(gbpUsd·nav)` wstGBP-per-USDC
(USDC assumed $1.00; depeg invisible — `check_feeds.sh` USDC/USD probe + owner pause is the defense,
`SECURITY_USDC_WSTGBP.md` §6), `USDC_UNIT = 1e6` pool-price constant (the whole 6-dec fix; constructor
asserts `USDC.decimals()==6`), 9-field `FeeParams`, 5-entry `FallbackReason` (codes RENUMBER vs weth —
table in `monitoring/dune/README.md`), tickSpacing 1, no POLCompounder. Status: all suites green
(unit + 35-test fork (incl. production-params smoke) + flipped + quoter parity + gas warm 9,604/cold 46,814 + adversarial + PosM +
8 invariants), 100% coverage on `src/usdc/`; deploy/init scripts rehearsed on anvil (0 ppm init);
`simParams()` = the `sim/RESULTS_USDC.md` winner ((30,5)bps, thr 1000, slope **1.0x**, cap 60bps,
minFee 50 — slope 1.0 kept, unlike weth's 0.5 demotion: splitting is gas-bounded at conveyor
notionals). Sim: `sim/cablesim/` over Dukascopy cable bars (`make sim-data-cable`, `make
sim-sweep-usdc`; weekly NAV *steps*, Chainlink 0.15%/24h deadband model). Readiness pass DONE 2026-07-05 (`docs/READINESS_USDC_WSTGBP_2026-07-05.md`): **GO** — 29/29
invariants on the authenticated RPC, two-reviewer security pass zero must-fix (3 should-fix
applied same-day, notably the FAIR_MAX 1.0e18 orientation-catching corridor). Remaining
(user-executed): commit/push FIRST (verdict condition), deploy/init/verify/POL-fund, migrate the
static pool's LP (full poolId `0xbe0ffd8b…bf3bb10` in DEPLOY.md §U5).
**`src/weth/` and `sim/wethsim/` are frozen — zero edits on this track.** Sign trap for tests:
raising GBP/USD *lowers* fair ⇒ d > 0.

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
