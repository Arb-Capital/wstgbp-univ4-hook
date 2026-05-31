# tGBP/wstGBP Uniswap v4 Backstop Hook

A Uniswap **v4 hook** that gives a `tGBP/wstGBP` pool effectively **infinite depth inside a tight,
ever-rising ~25bps band** by routing swaps through the wstGBP wrapper's atomic `mint`/`redeem` at the
protocol's own oracle prices: **buys execute at `wstGBP.mintcost()`, sells at `wstGBP.burncost()`**.
The ~25bps spread is the wrapper's own bid/ask (no extra hook fee), and both prices ratchet up as NAV
accrues. The hook is **ownerless and holds no capital** — it wraps the swap's own tokens.

Two variants (pick one per pool):

- **`WstGBPBackstopHook`** — pure backstop, LP blocked. Every swap is `mint`/`redeem`.
- **`WstGBPHybridHook`** — best execution: consume in-band third-party LP first (pool fee to LPs),
  backstop the remainder. With no LP it behaves identically to the pure backstop.

Swaps must be **settle-first** — route via `src/periphery/WstGBPSwapRouter.sol` (or any settle-first
solver/aggregator). Quotes come from `src/periphery/WstGBPQuoter.sol` or the off-chain formula. Full
design lives in [`CLAUDE.md`](CLAUDE.md); the backlog in [`ROADMAP.md`](ROADMAP.md).

---

## ⚠️ Trust model — read before integrating

**The hook adds no trust of its own — and removes none.** It has no owner, no admin, no pause, no
independent oracle, and no price bounds. It is a pure pass-through to the **wstGBP wrapper (MaseerOne)
and its governance**. Anyone swapping through this pool inherits, in full, the trust assumptions of the
Maseer system. The execution price *is* whatever the wrapper's oracle and fee governance say it is at
that block; the hook does not sanity-check it.

### Powers that Maseer governance / the oracle hold over every swap

| Lever | Where | Effect on swaps |
|---|---|---|
| **Oracle price** (`navprice`) | `pip` = MaseerPrice — a single storage slot `poke`d by privileged feeders; `pause()` sets it to 0 | Sets `mintcost`/`burncost`, i.e. the **exact execution price**. No on-chain freshness/staleness guard. Price 0 ⇒ all swaps revert (`InvalidPrice`). |
| **Spread / fees** (`bpsin`, `bpsout`) | `act` = MaseerGate, each settable up to **100%** | Widens/narrows the bid/ask (currently ~25bps). Could make execution arbitrarily unfavorable. |
| **Market open/close** (`mintable`/`burnable`) | `act`, timestamp-gated; `pauseMarket()` closes both | Closed mint ⇒ buys revert; closed burn ⇒ sells revert. |
| **Capacity** (`capacity`) | `act` | Caps total wstGBP supply; shrinking it blocks buys (`ExceedsCap`). |
| **Cooldown** (`cooldown`) | `act` | Non-zero breaks the *atomic* redeem a v4 swap requires. Handled: hybrid sells **fall back to pool liquidity only**, pure-backstop sells **revert** (`RedeemCooldownActive`). Buys are unaffected (mint is always atomic). |
| **Compliance / blacklist** (`cop.pass`) | `cop` = MaseerGuardOZ (`!isBanned`) | Gates every `mint`/`redeem`/`transfer`. Because the hook settles wstGBP to the PoolManager which then `take`s it to the recipient, **the hook, the PoolManager, AND the swap recipient must all stay un-banned** for buys (hook un-banned for every swap). A ban on the hook or the canonical PoolManager bricks the pool. |
| **Wrapper upgrade** | `wstGBP` sits behind `MaseerProxy` (delegatecall), `file(impl)` swaps the implementation with **no timelock** | An implementation change can alter `mint`/`redeem` semantics arbitrarily. The hook's balance-diff and `RedeemUnderpaid` guard are only partial defense. **tGBP itself is also an upgradeable proxy.** |

### What protects the swapper

- **Always pass real slippage bounds.** Quotes are point-in-time and the oracle ratchets up between
  quote and execution. `WstGBPSwapRouter` enforces `minAmountOut` (exact-input), `maxAmountIn`, and
  **full delivery of the exact output** (exact-output) — so a swap reverts rather than ever silently
  delivering less than you agreed to. Never send `minAmountOut = 0`.
- **Pre-flight with the quoter.** `WstGBPQuoter.previewSwap(zeroForOne, amountSpecified)` returns
  `(amountIn, amountOut, executable, reason)` and reports the live blockers: market closed, dust
  threshold, capacity exceeded, wrapper underfunded, or redeem cooldown active.

### What integrators should monitor

- `wstGBP.cooldown()` — must be `0` for backstop sells; non-zero degrades sells to LP-only (hybrid) or
  reverts (backstop).
- `wstGBP.mintable()` / `wstGBP.burnable()` — market open/closed.
- `wstGBP.capacity()` vs `wstGBP.totalSupply()` — remaining buy headroom.
- `wstGBP.mintcost()` / `wstGBP.burncost()` — the live execution price (ratchets; governance/oracle can
  move it).
- `tGBP.balanceOf(wstGBP)` — sell-side funding depth (sells revert `WrapperUnderfunded` past it).
- The **proxy implementation** of `wstGBP` (and `tGBP`) — watch for upgrades.
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
ETH_RPC_URL=<archive-or-full-rpc> forge test -vv     # fork tests; defaults to a public RPC if unset
forge test --match-test test_buyExactInput -vvv      # single test
forge script script/DeployHook.s.sol --rpc-url $ETH_RPC_URL --broadcast --private-key $PK
```

Tests fork mainnet against the **real** wstGBP/tGBP/oracle and the canonical PoolManager (58 tests:
27 pure-backstop + 31 hybrid, including pricing fuzz, capacity, cooldown-fallback, and the hybrid
sub-threshold-residual refund/revert cases). Deploy
with env `HOOK=hybrid` (default) or `HOOK=backstop`; the hook address is CREATE2-mined for its
permission flags and must not be on the tGBP/wstGBP ban list.
