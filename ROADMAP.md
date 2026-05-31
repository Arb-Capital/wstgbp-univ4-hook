# ROADMAP / TODO — tGBP/wstGBP v4 backstop hook

Durable backlog so nothing is lost across context clears. Keep this in sync as work lands.
See `CLAUDE.md` for the full design; this file is just status + what's left.

Status: `[x]` done · `[ ]` todo · `[~]` partial/in-progress

## Done

- [x] **Two hook variants** (user wants to keep both / choose later), both ownerless + no capital,
      exact-in/out both directions, sharing the router + quoter:
      - `src/WstGBPBackstopHook.sol` (flags `0x888`) — pure backstop, LP blocked.
      - `src/WstGBPHybridHook.sol` (flags `0x88`) — best execution: in-band LP first (real AMM, fee
        to LPs), backstop the rest; with no LP it equals the pure backstop.
- [x] Vendored `src/base/BaseHook.sol` (this periphery pin dropped `BaseHook`).
- [x] `src/interfaces/IwstGBP.sol`.
- [x] Settle-first periphery router — `src/periphery/WstGBPSwapRouter.sol` (exact-in/out,
      minOut/maxIn/deadline/recipient, surplus refund).
- [x] Quoter — `src/periphery/WstGBPQuoter.sol`: backstop quotes + `previewSwap` executability.
      Off-chain formula in `CLAUDE.md`.
- [x] **LP-aware quoter** — `src/periphery/WstGBPHybridQuoter.sol`: replays v4's `Pool.swap` over live
      pool state (`StateLibrary`) to the backstop edge + prices the residual at the oracle ⇒ the
      *exact* hybrid blend. Validated `quote == execution` for all four modes + 512 fuzz swaps.
- [x] Deploy script — `script/DeployHook.s.sol` (mines flags `0x88`, CREATE2, pool init fee 5bps /
      tickSpacing 60, deploys router + quoter).
- [x] Mainnet-fork tests (27): `test/WstGBPBackstopHook.t.sol` (17 — pricing, router hardening,
      quoter, guards) + `test/WstGBPHybridHook.t.sol` (10 — LP blend, no-LP parity, guards).

## Design invariants (do NOT regress without a deliberate decision)

- **Settle-first only.** `beforeSwap` runs before the taker pays, so input must be pre-settled into
  the PoolManager. Stock swap-then-settle routers are unsupported by design.
- **No hook buffer, no owner.** The hook wraps the swap's own tokens; it never holds inventory or
  privileged roles. (We removed an earlier ERC-6909 buffer + owner/sweep on purpose.)
- **No extra hook fee.** The 25bps spread is the wrapper's; the hook is a pass-through.
- currency0 = tGBP, currency1 = wstGBP; flags = `0x888`.

## Backlog (prioritized)

### P1 — Integration layer (needed before bots can use it)

- [x] **Quoting.** `WstGBPQuoter` (on-chain, exact, with `previewSwap` executability) + off-chain
      formula documented in `CLAUDE.md`. Tests assert quote == execution for all four modes.
- [x] **Harden `WstGBPSwapRouter`**: split into `swapExactInput` (enforces `minAmountOut`) /
      `swapExactOutput` (enforces `maxAmountIn`, refunds surplus); both take `deadline` + `recipient`
      (`address(0)` ⇒ `msg.sender`). Tested: minOut, maxIn, deadline, recipient, surplus refund.
      - [ ] Permit2 entrypoint still deferred (only if an end-user/aggregator flow needs it).
- [x] **Deploy the router (and quoter)** from `script/DeployHook.s.sol`.

### P2 — M2: best-execution across third-party LP + backstop (the "hybrid")

Requirement (clarified by user, 2026-05-30): the pool may hold third-party LP at ANY range
(full-range, wide, narrow). A swap must get **best execution**: consume LP that beats the backstop
edge first, then backstop the remainder at the edge (mintcost for buys / burncost for sells). LP
priced worse than the current edge is never used (the backstop is always ≥ as good), and gets arbed
back into the band by the backstop itself. The comparison is against the *current* (NAV-drifting)
edge, not a fixed band — so it self-corrects as the rate moves out of where LP was placed.

  Example: mintcost 1.0013, burncost 0.9988. Buyer of 100k wstGBP with 30k LP at 1.000–1.0010 fills
  30k from LP then mints 70k at 1.0013. If that LP were at 1.0020 (> mintcost) it's ignored.

- [ ] **Mechanism** (two viable, decide at build):
      (a) settle-first router sets `sqrtPriceLimitX96` = backstop edge; hook backstops the unfilled
          remainder in `afterSwap` (needs afterSwap + afterSwapReturnDelta flags); or
      (b) reentrancy-guarded nested `poolManager.swap` to the edge in `beforeSwap`, then backstop the
          residual.
      Either way: enable LP adds (drop the beforeAddLiquidity revert); **skip the AMM entirely when
      the pool price is already past the edge** (else `Pool.swap` reverts `PriceLimitAlreadyExceeded`
      — check `slot0` first). New flag set ⇒ new mined hook address (immutable ⇒ fresh deploy). With
      LP reserves now in the PoolManager, revisit whether swap-first routing/quoting partially works.
- [x] **Decided (2026-05-30):** *combine* (best execution — fill better-than-edge LP first, then
      backstop the remainder in the same swap) and *charge a pool fee* (LPs earn it on the portion
      they fill).
- [ ] **Mechanism choice:** hook-internal combine via reentrancy-guarded **nested `poolManager.swap`
      in `beforeSwap`** (preferred over router-side combine, so ANY settle-first router gets
      best-ex). The real AMM runs for the in-band portion (so the pool fee accrues to LPs normally),
      bounded at the **fee-adjusted edge**: for the swapper's all-in price to never exceed the
      backstop edge, the AMM price limit must be `mintcost*(1-fee)` (buys) / `burncost/(1-fee)`
      (sells), converted to `sqrtPriceX96`. Then backstop the residual via mint/redeem and combine
      deltas into the outer `BeforeSwapDelta`. Read `slot0` first; if price is already past the edge,
      skip the AMM entirely (nested swap would revert `PriceLimitAlreadyExceeded`).
- [x] **(1)** `src/WstGBPHybridHook.sol` — new hook, flags `0x88` (LP enabled, no add-revert),
      non-zero pool fee, reentrancy-guarded nested-swap combine + fee-adjusted edge.
- [x] **(2)** Exact-input combine + fork tests (`test/WstGBPHybridHook.t.sol`): buy & sell blend
      in-band LP then backstop, beat pure-backstop price, move pool price toward the edge, hook left
      clean. Exact-output reverts (guarded).
- [x] **(3)** Exact-output combine (buy & sell): partial AMM fill + backstop the remaining output,
      input rounded up with surplus refunded by the router. Fork-tested (blended input beats pure
      backstop).
- [x] **(4)** Edge/guard tests for the hybrid (10 hybrid fork tests total): zero-LP ⇒ exact
      pure-backstop price; price past edge ⇒ AMM skipped + out-of-band LP ignored + price unchanged;
      large swap ⇒ deep blend then backstop; LP earns the pool fee (feeGrowth increases);
      market-closed + underfunded reverts. Hybrid now has full test parity with M1 + LP.
- [x] **(5)** Deploy script + quoter for the hybrid — `WstGBPHybridQuoter` (LP-aware, exact: replays
      the AMM to the edge via `StateLibrary` + backstops the residual) is deployed alongside the hybrid
      in `script/DeployHook.s.sol`.
- [~] **(6) Consolidation — deferred.** The hybrid subsumes the backstop (no-LP ⇒ identical), so one
      hook is viable, BUT the user wants to keep BOTH to evaluate. So both are kept; the deploy script
      selects via env `HOOK=hybrid|backstop`. Revisit retiring the backstop once a variant is chosen.

Design note — "inject mint/redeem at the tick edges": that IS the backstop conceptually (infinite
liquidity at the mintcost/burncost ticks), but v4 can't post infinite liquidity as a static position
(a tick's depth = its `L`), so it must be synthesized by the hook. Alternative mechanism to the
nested swap: let the real outer swap run bounded at the edge (router sets the price limit) and
backstop the overflow in `afterSwap` — simpler hook, but each integrating router must compute/set the
edge, so best-ex is no longer automatic for arbitrary settle-first callers.

### P3 — Test gaps

- [x] `capacity()`-exceeded revert path (`test_buyRevertsWhenCapacityExceeded` + quoter flag).
- [x] Quoter == execution tests (4 modes) + `previewSwap` executability flags.
- [x] Fuzz pricing/rounding across amounts (backstop quoter == execution, hook-clean, dust ≤ 1 wei) +
      hybrid LP-quote == execution fuzz.
- [x] Large-swap blend (`test_lpQuoteMatchesExecution_largeBuy`, `test_largeSwapBlendsDeepThenBackstops`);
      sell depth guarded by `WrapperUnderfunded` + `RedeemUnderpaid`.

### P4 — Nice to have

- [ ] Integrator events (the PoolManager emits `Swap`; consider router-level events).
- [x] Security review / audit prep pass — done (report: `~/.claude/plans/please-deep-dive-this-...md`).
      Fixed F1 (`RedeemUnderpaid` + cooldown handling: hybrid sells fall back to LP, backstop reverts;
      router enforces exact-output full delivery). Trust model documented in `README.md` (F4).
- [ ] Pin `lib/v4-core` / `lib/v4-periphery` to tagged releases in `.gitmodules` (currently
      periphery `363226d`, core `v4.0.0`). Note: working dir is not a git repo here.
