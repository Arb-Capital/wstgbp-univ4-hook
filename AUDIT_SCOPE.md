# Audit Scope — tGBP/wstGBP Uniswap v4 Backstop Hook

Prepared 2026-06-03. This document defines the surface for external audit. One hook is in scope:
**`WstGBPBackstopHook`** (pure backstop, LP blocked). A hybrid variant was evaluated and deferred (see
"Out of scope" below).

## What the system does

A Uniswap v4 hook that gives a `tGBP/wstGBP` pool effectively unlimited depth inside a tight, ever-rising
~25bps band by routing every swap through the wstGBP wrapper's (MaseerOne) atomic `mint`/`redeem` at the
protocol's own oracle prices: buys at `wstGBP.mintcost()`, sells at `wstGBP.burncost()`. The hook is
**ownerless, holds no capital, and takes no fee of its own** — it wraps the swap's own tokens. The ~25bps
spread is the wrapper's, captured by the wstGBP protocol. Full design: [`CLAUDE.md`](CLAUDE.md). Trust
model (the wstGBP/MaseerOne governance powers a swapper inherits): [`README.md`](README.md).

## In scope

| File | Role |
|---|---|
| `src/WstGBPBackstopHook.sol` | The hook — custom-curve `beforeSwap` returning a `BeforeSwapDelta`; blocks LP via `beforeAddLiquidity` revert |
| `src/base/BaseHook.sol` | Vendored base (periphery `main` dropped `src/utils/BaseHook.sol`) |
| `src/interfaces/IwstGBP.sol` | wstGBP wrapper interface |
| `src/interfaces/IMaseerFeeds.sol` | The wrapper's two immutable price-feed interfaces (`act`/`pip`), read directly by the hook |
| `src/periphery/WstGBPSwapRouter.sol` | Settle-first router (exact-in/out, slippage/deadline/recipient, surplus refund, Permit2 entrypoints) |
| `src/periphery/WstGBPQuoter.sol` | Backstop quoter + `previewSwap` executability |
| `script/DeployHook.s.sol` | CREATE2 mine + deploy (hook + router + quoter), pool init, I-02 feed-proxy assertion |
| `test/base/WstGBPForkBase.sol` | Shared mainnet-fork scaffolding (deploy/seed, slot constants, swap/quote/sign helpers) for the test suites |
| `test/WstGBPBackstopHook.t.sol` | Mainnet-fork test suite — feature/regression/red-team (48 tests) |
| `test/WstGBPBackstopHookFuzz.t.sol` | Adversarial math/attack-vector fuzz across the oracle price range (11 tests) |
| `test/WstGBPBackstopHookInvariants.t.sol` | Stateful invariants: no value extraction, hook never drained, quoter==exec, no liquidity (4 tests) |
| `foundry.toml`, `remappings.txt` | Build/toolchain config |

## Out of scope

- **Vendored dependencies** under `lib/` (Uniswap v4 core/periphery, forge-std, Permit2) — treated as
  trusted upstream; the integration boundary with them is in scope.
- **The wstGBP wrapper / MaseerOne system and its governance** (`../maseer-one`, the `act`/`pip`/`cop`
  proxies). The hook is a pure pass-through to it; its trust assumptions are inherited, not mitigated
  (see the README trust model). Out of scope as a target; relevant to the boundary review.
- **The deferred `WstGBPHybridHook`** (+ `WstGBPHybridQuoter` + hybrid tests). Built, fixed
  (M-01/L-01), fork-validated, then removed from the tree on 2026-06-03 and **preserved in git history at
  commit `b7a5c5a`**. Not deployed; not in this audit. If revived, it needs its own audit.

## Design properties an auditor should confirm

- **Settle-first only.** `beforeSwap` runs before the taker pays, so the input must already be in the
  PoolManager. The hook `take`s it, `mint`/`redeem`s, and `settle`s the output — no inventory, no
  `unlock`. Stock swap-then-settle routers revert (documented; `test_swapFirstRoutingIsUnsupported`).
- **Ownerless, no capital, no extra fee.** No admin/pause/sweep; only transient sub-unit dust mid-swap.
- **Currency convention** (constructor-enforced): currency0 = tGBP, currency1 = wstGBP, so
  `zeroForOne == true` is a BUY, `false` a SELL. Both 18 decimals; prices WAD.
- **Exact-output rounds input up** (`mulDivRoundingUp`); the wrapper over-delivers by price-bounded dust
  kept in the hook (≤ 1 wei at NAV ≥ 1; bounded by `WAD/mintcost` wei at sub-par NAV —
  `testFuzz_subParNavMintsAtLeastRequested`). Harmless: never credited to anyone, no recovery path —
  economically nil.
- **Sells pre-check wrapper funding** (`WrapperUnderfunded`) and assert full payout (`RedeemUnderpaid`),
  because `wstGBP.redeem` returns an id (not an amount) and can underpay; non-zero `cooldown()` makes the
  redeem non-atomic, so sells revert (`RedeemCooldownActive`).

## Prior security review

A first-party review (`SECURITY_AUDIT.md`, 2026-05-31 — removed from the tree with the hybrid deferral;
in git history at `7ad0b89`) found no critical/high issues. A later pre-deployment review
(2026-06-09, [`docs/SECURITY_REVIEW_2026-06-09.md`](docs/SECURITY_REVIEW_2026-06-09.md)) re-verified the
full surface with a ship verdict and doc-only findings. Status of findings relevant to the in-scope
backstop:

| ID | Sev | Applies to | Status |
|---|---|---|---|
| L-02 | Low | Backstop quoter | **Fixed** — capacity check uses the minted amount, not requested output |
| I-01 | Info | Router/quoter | **Documented** — they trust the caller `PoolKey`; integrators must pin the canonical key (README "What protects the swapper") |
| I-02 | Info | Hook | **Hardened** — deploy-time assertion that the hook's cached `act`/`pip` proxies equal the wrapper's, plus `test_cachedFeedsMatchWrapper` |
| I-03 | Info | Toolchain | **Fixed** — `ffi = false` in the default foundry profile |
| I-04 | Info | Dependencies | **Documented** — see provenance below (no release tag yet ships the required periphery APIs) |
| M-01, L-01, I-05 | Med/Low/Info | Hybrid only | N/A — hybrid is out of scope (fixes preserved at `b7a5c5a`) |

## Red-team review (2026-06-03)

A second, adversarial pass over the in-scope backstop surface. **No critical or high code-level issues.**
What it verified to be safe (so an external audit can move fast): the hook's `BeforeSwapDelta` accounting
nets to zero in all four buy/sell × exact-in/out branches; every rounding step favors the protocol (the
swapper is never over-credited; sub-wei dust accrues to the hook); the Permit2 *and* approval router paths
hard-bind `payer == msg.sender`, so a third party cannot drive a victim's signed transfer (`payer` is never
caller-supplied); `unlockCallback` is only reachable via the router's own `unlock`; the redeem path is
robust to wrapper misbehavior (balance-diff + `RedeemUnderpaid`); and reentrancy is contained by the v4
lock plus the `onlyPoolManager` guard and the hook's statelessness.

The dominant residual risks are **trust/centralization in the wstGBP wrapper** and the **design property
that the hook applies no slippage of its own** — both inherent and documented in detail in the
[`README.md`](README.md) trust model (oracle pause/move, fees to 100%, blacklist kill-switch on the hook or
PoolManager, sell-side funding dependence, feed/compliance/tGBP proxy upgrades — the wrapper itself is not
upgradeable, but its `pip`/`act`/`cop` feeds and tGBP are proxies). No code change can remove them;
mitigation is the caller's slippage bounds (canonical router) plus operational monitoring of the ban list,
market gates, and proxy implementations.

Changes from this pass (no swap-execution behavior changed):
- **Quoter:** `previewSwap` now reports `(executable=false, "oracle paused")` when the oracle NAV is 0,
  instead of reverting on a divide-by-zero in the quote math (`WstGBPQuoter`).
- **Hook NatSpec:** an explicit "slippage is the caller's responsibility" warning on the contract and
  `_beforeSwap` (recorded *decision*: keep the hook a pure price-taker; slippage belongs at the routing
  layer).
- **Tests (+4 ⇒ 33):** paused-oracle preview; blacklist-bricks-pool (hook/PoolManager banned via the `cop`
  gate); hook-applies-no-slippage (bounded swap reverts, unbounded executes at the moved price);
  hook callbacks reject non-PoolManager callers (the reentrancy barrier). A hostile-token reentrancy
  *harness* was considered and judged disproportionate — the real tGBP/wstGBP cannot exercise a transfer
  callback, and the protections (onlyPoolManager + zero-net accounting) are covered by the callback-guard
  test and the existing "hook stays clean" assertions.

## Dependency provenance (I-04)

The audited commits (no top-level lockfile beyond submodule pins):

- `lib/v4-periphery` @ `363226d9e1e2180b67bf6857023dbaad751010c5` (the "Permissioned Pools" `main`).
- nested `lib/v4-core` @ `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (`v4.0.0-12-g59d3ecf5`).
- `lib/forge-std` @ `v1.16.1`. Permit2 via the periphery's pin.

## Toolchain

- solc **0.8.28**, `evm_version = cancun` (EIP-1153 transient storage for v4 flash accounting),
  `via_ir = true`, `optimizer_runs = 800`.

## Mainnet addresses (the live system the hook prices off)

| Thing | Address |
|---|---|
| tGBP (currency0, proxy) | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` |
| wstGBP / MaseerOne (currency1) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| MaseerGate `act` (timing/fees/cooldown/capacity) | `0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f` |
| MaseerGuardOZ `cop` (compliance) | `0x794cF5948444b14105587455EbE96Caace036d52` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |

Canonical pool key: `currency0 = tGBP`, `currency1 = wstGBP`, `fee = 0`, `tickSpacing = 1`,
`hooks = <CREATE2-mined hook, flags 0x888>`.

## Build / test

```bash
forge build
ETH_RPC_URL=<archive-or-full-rpc> make test          # 59 fast fork tests (feature + fuzz); public RPC if unset
make test-invariant                                  # the 4 stateful fork invariants only (~10 min)
make test-all                                         # all 63 (a bare `forge test -vv` also runs the slow suite)
```

Tests fork mainnet against the real wstGBP/tGBP/oracle and the canonical PoolManager; the hook is
CREATE2-mined and deployed on the fork, and the MaseerGate is forced open via `vm.store` for
determinism. Coverage: pricing × 4, 25bps round-trip, quoter == execution (4 modes + fuzz),
`previewSwap` flags, router hardening (minOut / maxIn / deadline / recipient / surplus refund, Permit2),
LP-add revert, market-closed / underfunded / cooldown / capacity reverts, cached-feed parity (I-02),
capacity-uses-minted-amount (L-02), swap-first-routing rejection, and the red-team additions (paused-oracle
preview, blacklist-bricks-pool, no-hook-slippage, callback access control).
