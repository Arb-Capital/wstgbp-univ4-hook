# tGBP/wstGBP Uniswap v4 Backstop Hook

A Uniswap **v4 hook** that gives a `tGBP/wstGBP` pool effectively **infinite depth inside a tight,
ever-rising ~25bps band** by routing swaps through the wstGBP wrapper's atomic `mint`/`redeem` at the
protocol's own oracle prices: **buys execute at `wstGBP.mintcost()`, sells at `wstGBP.burncost()`**.
The ~25bps spread is the wrapper's own bid/ask (no extra hook fee), and both prices ratchet up as NAV
accrues. The hook is **ownerless and holds no capital** — it wraps the swap's own tokens.

**`WstGBPBackstopHook`** — the pure backstop: LP is blocked (`beforeAddLiquidity` reverts) and every
swap is `mint`/`redeem`. This is the single hook in scope for audit and deployment. Best execution
against any *separate* third-party LP pool is handled at the routing layer (Uniswap routing / UniswapX
+ arbitrage, which pins a vanilla pool inside the band). A `WstGBPHybridHook` variant that consumes
in-band LP inside the same pool was evaluated and **deferred** — it is preserved in git history (see
[`ROADMAP.md`](ROADMAP.md)) and can be revived if in-pool LP demand materializes.

Swaps must be **settle-first** — route via `src/periphery/WstGBPSwapRouter.sol` (or any settle-first
solver/aggregator). Quotes come from `src/periphery/WstGBPQuoter.sol` or the off-chain formula. Full
design lives in [`CLAUDE.md`](CLAUDE.md); the backlog in [`ROADMAP.md`](ROADMAP.md). The audited surface
and scope are in [`AUDIT_SCOPE.md`](AUDIT_SCOPE.md).

---

## ⚠️ Trust model — read before integrating

**The hook adds no trust of its own — and removes none.** It has no owner, no admin, no pause, no
independent oracle, and no price bounds. It is a pure pass-through to the **wstGBP wrapper (MaseerOne)
and its governance**. Anyone swapping through this pool inherits, in full, the trust assumptions of the
wstGBP wrapper system. The execution price *is* whatever the wrapper's oracle and fee governance say it is
at that block; the hook does not sanity-check it.

### Powers that wstGBP governance / the oracle hold over every swap

| Lever | Where | Effect on swaps |
|---|---|---|
| **Oracle price** (`navprice`) | `pip` = MaseerPrice — a single storage slot `poke`d by privileged feeders; `pause()` sets it to 0 | Sets `mintcost`/`burncost`, i.e. the **exact execution price**. No on-chain freshness/staleness guard. Price 0 ⇒ all swaps revert (`InvalidPrice`). |
| **Spread / fees** (`bpsin`, `bpsout`) | `act` = MaseerGate, each settable up to **100%** | Widens/narrows the bid/ask (currently ~25bps). Could make execution arbitrarily unfavorable. |
| **Market open/close** (`mintable`/`burnable`) | `act`, timestamp-gated; `pauseMarket()` closes both | Closed mint ⇒ buys revert; closed burn ⇒ sells revert. |
| **Capacity** (`capacity`) | `act` | Caps total wstGBP supply; shrinking it blocks buys (`ExceedsCap`). |
| **Cooldown** (`cooldown`) | `act` | Non-zero breaks the *atomic* redeem a v4 swap requires. Handled: sells **revert** (`RedeemCooldownActive`) rather than burn wstGBP into a deferred payout. Buys are unaffected (mint is always atomic). |
| **Compliance / blacklist** (`cop.pass`) | `cop` = MaseerGuardOZ (`!isBanned`) | Gates every `mint`/`redeem`/`transfer`. Because the hook settles wstGBP to the PoolManager which then `take`s it to the recipient, **the hook, the PoolManager, AND the swap recipient must all stay un-banned** for buys (hook un-banned for every swap). A ban on the hook or the canonical PoolManager bricks the pool. |
| **Proxy upgrades** | `pip`, `act`, and `cop` are `MaseerProxy` instances (`file(impl)` swaps the implementation, **no timelock**); **tGBP is an EIP-1967 proxy**. `wstGBP` (MaseerOne) itself is **not** a proxy — its code and immutable wiring (`gem`/`pip`/`act`/`cop`) are fixed forever | All *pricing, gating, compliance, and underlying-token* behavior can change arbitrarily via the feed/guard/tGBP implementations, but the wrapper's `mint`/`redeem` mechanics cannot. Because the hook and quoter cache the same fixed `act`/`pip` addresses the wrapper reads, they stay price-identical to the wrapper even across feed upgrades. The hook's balance-diff and `RedeemUnderpaid` guard are only partial defense against hostile feed/tGBP implementations. |

### What protects the swapper

- **Always pass real slippage bounds.** Quotes are point-in-time and the oracle ratchets up between
  quote and execution. `WstGBPSwapRouter` enforces `minAmountOut` (exact-input), `maxAmountIn`, and
  **full delivery of the exact output** (exact-output) — so a swap reverts rather than ever silently
  delivering less than you agreed to. Never send `minAmountOut = 0`.
- **Pre-flight with the quoter.** `WstGBPQuoter.previewSwap(zeroForOne, amountSpecified)` returns
  `(amountIn, amountOut, executable, reason)` and reports the live blockers: market closed, dust
  threshold, capacity exceeded, wrapper underfunded, redeem cooldown active, or oracle paused — rather
  than reverting.
- **Pin the canonical `PoolKey`** (security-audit I-01). The router and quoter are intentionally generic
  over `PoolKey`; the hook validates only the two currencies, not the fee, tick spacing, or hook address.
  Integrators, bots, and frontends must hardcode/validate the canonical key
  (`currency0 = tGBP`, `currency1 = wstGBP`, `fee = 0`, `tickSpacing = 1`, `hooks = <deployed hook>`) and
  must never route through a user- or route-supplied key. The deploy script logs the canonical key.

### What integrators should monitor

- `wstGBP.cooldown()` — must be `0` for sells; non-zero makes sells revert (`RedeemCooldownActive`).
- `wstGBP.mintable()` / `wstGBP.burnable()` — market open/closed.
- `wstGBP.capacity()` vs `wstGBP.totalSupply()` — remaining buy headroom.
- `wstGBP.mintcost()` / `wstGBP.burncost()` — the live execution price (ratchets; governance/oracle can
  move it).
- `tGBP.balanceOf(wstGBP)` — sell-side funding depth (sells revert `WrapperUnderfunded` past it).
- The **proxy implementations** of `pip`/`act`/`cop` (MaseerProxy) and `tGBP` (EIP-1967) — watch for
  upgrades. `wstGBP` itself is not upgradeable.
- The **ban list** (`cop` / its guard source) — keep the hook, the PoolManager, and your recipients
  off it.

### Key mainnet addresses

| Role | Address |
|---|---|
| tGBP (currency0, proxy) | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` |
| wstGBP / MaseerOne (currency1) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| MaseerGate `act` (timing/fees/cooldown/capacity) | `0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f` |
| MaseerGuardOZ `cop` (compliance) | `0x794cF5948444b14105587455EbE96Caace036d52` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |

`tGBP < wstGBP`, so **currency0 = tGBP, currency1 = wstGBP**; `zeroForOne == true` is a **BUY** of
wstGBP, `false` is a **SELL**. Both tokens are 18 decimals; all prices are WAD (1e18) tGBP-per-wstGBP.

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
ETH_RPC_URL=<rpc> PK=<key> ETHERSCAN_API_KEY=<key> make deploy   # broadcast + --slow + Etherscan verify
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
`src/base/BaseHook.sol` so the report reflects only the first-party surface. Set
`ETH_RPC_URL` to an archive/full RPC for a reliable fork (the suite otherwise falls back
to a public RPC).

Tests fork mainnet against the **real** wstGBP/tGBP/oracle and the canonical PoolManager (63 tests across
three suites that share `test/base/WstGBPForkBase.sol`). `test/WstGBPBackstopHook.t.sol` (48): pricing ×
4, 25bps round-trip, quoter == execution + fuzz, `previewSwap` flags, router hardening + Permit2, LP-add
revert, market-closed / underfunded / cooldown / capacity reverts, cached-feed parity,
swap-first-routing rejection, and a red-team pass — paused-oracle preview, blacklist-bricks-pool, the
hook applying no slippage of its own, callback access control, and defensive transfer/redeem/pool-guard
coverage. `test/WstGBPBackstopHookFuzz.t.sol` (11): adversarial math fuzzed across the whole oracle price
range — quoter == execution (all four modes), exact-out ceiling with no >1-wei over-charge, bounded
sub-par-NAV over-mint dust, round-trips that can never profit, a donated hook balance that changes no
price and can't be drained, clean reverts at the price/`int128`/zero-amount extremes, and Permit2
replay rejection. `test/WstGBPBackstopHookInvariants.t.sol` (4): a stateful handler drives long random
swap sequences and asserts no value extraction, the ownerless hook is never drained, quoter == execution
every swap, and the pool never holds AMM liquidity. `script/DeployHook.s.sol`
CREATE2-mines the hook for its permission flags (`0x888`), initializes the pool (fee 0 / tickSpacing 1),
and deploys the router + quoter; the hook address must not be on the tGBP/wstGBP ban list.
