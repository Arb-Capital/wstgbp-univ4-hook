# ROADMAP / TODO — tGBP/wstGBP v4 backstop hook

Durable backlog so nothing is lost across context clears. Keep this in sync as work lands.
See `CLAUDE.md` for the full design; this file is just status + what's left.

Status: `[x]` done · `[ ]` todo · `[~]` partial/in-progress

**Deployed to mainnet 2026-06-28** — hook `0xfE36B48c9c0240991E4CEf006a2445F2ff524888`, router
`0x21734507fDca48A3b4e8C496280b63a37D3bD0C8`, quoter `0x9B409f87aeaADBE912632b1E4de855B6aFCc71Ee`,
adapter `0xBE402d34f31133B1Dc00277f24F8ce2d975CBe23`. Full table in `README.md` / `AUDIT_SCOPE.md` /
`CLAUDE.md`. Remaining: off-chain aggregator/CoW listing (below).

## Decision (2026-06-03): ship the pure backstop, defer the hybrid

Only **one** hook goes to external audit / mainnet, and it is **`WsgemBackstopHook`** (pure backstop,
LP blocked). Rationale: it delivers the full product (infinite depth, tight ~25bps band) with a far
smaller audit surface, and best-execution against any *separate* third-party LP pool is handled at the
routing layer (Uniswap routing / UniswapX + arbitrage pinning a vanilla pool into the band) rather than
inside the hook. The `WstGBPHybridHook` (+ `WstGBPHybridQuoter` + its tests) — fully built, fixed
(M-01/L-01), and fork-validated — was removed from the tree and **preserved in git history at commit
`b7a5c5a`**; revive it only if in-pool LP demand materializes (it would need its own audit). Audit scope
is in `AUDIT_SCOPE.md`. This resolves the P2 item (6) consolidation question below.

## Decision (2026-06-12): monorepo + one generic adapter for non-v4 venues

To expose the same wstGBP `mint`/`redeem` to **CoW Protocol + DEX aggregators (Odos / LI.FI / Paraswap)**,
keep everything in **this repo** (monorepo) restructured around a shared core, and ship **one generic
adapter** rather than a bespoke contract per venue. Layout: `src/core/` (shared `WsgemWrap` lib +
interfaces), `src/v4/` (the hook + router + quoter, moved), `src/adapter/` (`WsgemDirectAdapter`).

Key finding: **"CoW Hooks" are user-attached pre/post *interactions* on an order, not a liquidity source.**
Giving solvers a route through `mint`/`redeem` is [route integration](https://docs.cow.fi/cow-protocol/tutorials/solvers/routes_integration)
(expose a standard swap contract + price discovery, propose on the CoW DAO forum). CoW, Odos, LI.FI, and
Paraswap all want the *same* `approve → swap` contract, so the on-chain artifact is one generic adapter;
v4 was the special case (settle-first + mined flags). Per-aggregator effort is **off-chain listing**.

- [x] **`src/core/WsgemWrap.sol`** — shared library (price, exact-in/out rounding, redeem balance-diff,
      ERC20 transfer), embedded `internal`. Hook + quoter + adapter all source their math here; cross-venue
      parity tests pin adapter == quoter == hook so they can never drift.
- [x] **`src/adapter/WsgemDirectAdapter.sol`** — ownerless, inventory-free, no pool. exact-in/out +
      Permit2 + view quotes; direction from `tokenIn`; same funding/cooldown/redeem-underpaid guards as the
      hook. Standard swap-then-settle — works with stock aggregator executors and CoW solver interactions.
- [x] Restructure into `src/core` + `src/v4` + `src/adapter` (behavior-preserving; 59 v4 tests unchanged).
      Fork base split into `ForkBase` (agnostic) + `WsgemForkBase` (v4) + `WsgemAdapterForkBase`.
- [x] Adapter test suites: `WsgemDirectAdapter.t.sol` (21 — feature/parity/hardening + aggregator-style
      approve+swap + Permit2 + every wrapper-gated revert + same-currency guard), `...Fuzz.t.sol` (6 —
      full-NAV-range parity, exact-out ceiling, round-trip-never-profits), `...Invariants.t.sol` (3 — no
      extraction, bounded dust, quoter==exec). Now **98 tests** total (91 fast + 7 invariant).
- [x] Deploy wiring: `DeployWstGBP.s.sol` also deploys the adapter, asserts its I-02 cached-feed parity, and
      checks it is not ban-listed. `deploy-dry` validated end-to-end on a mainnet fork.
- [~] **Off-chain listing (per venue, no Solidity):** step-by-step playbook now in
      **[`docs/AGGREGATOR_LISTINGS.md`](docs/AGGREGATOR_LISTINGS.md)** (2026-07-03): ParaSwap =
      self-serve `paraswap-dex-lib` PR (templates: `wsteth` constant-price + `lite-psm` caps); Odos =
      Discord request with the info packet; LI.FI = automatic downstream (its exchange list is
      aggregators incl. paraswap/odos — verified via li.quest/v1/tools); CoW = forum proposal
      (`docs/COW_ROUTE_INTEGRATION.md`, drafted). Remaining: execute them. All reuse the *same*
      deployed adapter.
- [ ] **Repo rename** off `-univ4-hook` (e.g. `wstGBP-venues`) — name only, do when convenient.

## Decision (2026-07-03): CoW Hook Store dapp via an owner-bound helper

Second CoW track (complements route integration above, which serves *solvers*): a **Hook Store dapp**
lets CoW Swap *users* attach wrap/unwrap to any order (post-hook "wrap proceeds into wstGBP", pre-hook
"unwrap wstGBP to fund a tGBP sell"). Key mechanics (docs tracked in `CLAUDE.md`): hooks are
`{target, callData, gasLimit}` in appData, executed by the public untrusted **HooksTrampoline** — so the
target must be safe under arbitrary callers, and `WsgemDirectAdapter` cannot be it (pulls from
`msg.sender`; the trampoline holds nothing). Chosen design: **`WsgemHookHelper`**, owner-bound (anyone
may call; funds flow only owner→owner at oracle price, capped by the owner's allowance — bounded
griefing, no extraction) over the CoW-Shed proxy pattern (more moving parts, needs delegatecall helpers
anyway). The web dapp lives in a **separate repo** (ecosystem convention; keeps this repo pure Foundry).

- [x] `src/adapter/WsgemHookHelper.sol` — `wrapAll` (min(balance, allowance) sweep — post-hook proceeds
      vary with surplus), `unwrap` (fixed amount), `unwrapAll`; same sell guards as the adapter via
      `WsgemWrap`; `Wrap`/`Unwrap` events carry owner + executor.
- [x] Tests: `test/adapter/WsgemHookHelper.t.sol` (21 — quoter parity, sweep caps,
      arbitrary-caller-cannot-redirect-or-extract, wrapper-gated + defensive reverts) +
      `WsgemHookHelperFuzz.t.sol` (4 — NAV-range parity + forced-round-trip-never-profits).
- [x] Deploy: `script/DeployHookHelper.s.sol` (plain CREATE + I-02 + ban-list asserts);
      `make deploy-hook-helper[-dry]`. Dry-run validated on a mainnet fork. `AUDIT_SCOPE.md` updated
      (flagged as a post-review scope addition).
- [ ] **Deploy the helper to mainnet** (user-run keystore flow) and record the address here + `CLAUDE.md`.
- [ ] **Hook dapp repo** (`wsgem-cow-hooks` or similar): Vite+TS iframe app on
      `@cowprotocol/hook-dapp-lib` (manifest.json, wrap/unwrap modes via `context.isPreHook`,
      exact-approval flow, quotes off `act`/`pip`), hosted at a stable URL (Vercel).
- [ ] **E2E** via CoW Swap → Hooks → "My Custom Hooks" (paste dapp URL) with small mainnet orders both
      directions (tGBP is mainnet-only).
- [ ] **Hook Store listing PR** to `cowprotocol/cowswap`: `IFRAME` entry in
      `libs/hook-dapp-lib/src/hookDappsRegistry.ts`.
- [~] **Track B route-integration doc** — `docs/COW_ROUTE_INTEGRATION.md` drafted (interface, price
      discovery, gating, gas, compliance + forum-post skeleton); remaining: post it on the CoW DAO forum
      (the solver-side listing item above).

## Done

- [x] **Hook (shipped): `src/v4/WsgemBackstopHook.sol`** (flags `0x888`) — pure backstop, LP blocked,
      ownerless + no capital, exact-in/out both directions, sharing the router + quoter.
      - A `WstGBPHybridHook` (flags `0x88`, best-ex: in-band LP first then backstop) was also built but is
        now **deferred and removed from the tree** (see the Decision note above; preserved at `b7a5c5a`).
- [x] Vendored `src/v4/base/BaseHook.sol` (this periphery pin dropped `BaseHook`).
- [x] `src/core/interfaces/Iwsgem.sol`.
- [x] Settle-first periphery router — `src/v4/periphery/WsgemSwapRouter.sol` (exact-in/out,
      minOut/maxIn/deadline/recipient, surplus refund).
- [x] Quoter — `src/v4/periphery/WsgemQuoter.sol`: backstop quotes + `previewSwap` executability.
      Off-chain formula in `CLAUDE.md`.
- [x] **LP-aware quoter (deferred with the hybrid)** — `src/periphery/WstGBPHybridQuoter.sol` replayed
      v4's `Pool.swap` to the backstop edge + priced the residual at the oracle (exact hybrid blend,
      fuzz-validated). Removed from the tree with the hybrid; preserved at `b7a5c5a`.
- [x] Deploy script — `script/DeployWstGBP.s.sol`: CREATE2-mines the backstop flags `0x888`, pool init
      fee 0 / tickSpacing 1, deploys router + quoter + direct adapter, and asserts the hook's cached
      `act`/`pip` feed proxies equal the wrapper's (I-02).
- [x] Mainnet-fork tests (65 across three suites, all sharing `test/base/WsgemForkBase.sol`):
      `WsgemBackstopHook.t.sol` (50) — pricing, router hardening + Permit2, quoter + `previewSwap`,
      guards, capacity (L-02), cached-feed parity (I-02), swap-first rejection, currency-ordering adaptation;
      `WsgemBackstopHookFuzz.t.sol` (11) — adversarial math fuzzed across the whole oracle price range
      (4-mode quoter==exec, exact-out ceiling/no-overcharge, bounded sub-par over-mint dust, round-trips
      never profit, donated-balance no-subsidy/no-drain, extreme-price/`int128`/zero clean reverts,
      Permit2 replay rejection); `WsgemBackstopHookInvariants.t.sol` (4) — stateful no-extraction /
      hook-never-drained / quoter==exec / no-liquidity invariants (`[profile.default.invariant]`).
      A standalone `WsgemFlippedOrderingHook.t.sol` (3) runs end-to-end buys/sells in the flipped token
      ordering (wsgem = currency0) against mock tokens, proving the hook adapts when the wrapper sorts below
      its underlying. (The hybrid's suite was removed with the hybrid; preserved at `b7a5c5a`.)
- [x] **Pre-deployment security review (2026-06-09, `docs/SECURITY_REVIEW_2026-06-09.md`)** — **ship
      verdict**, no code findings (nothing ≥ Medium; no Solidity changes). Hand-verified all four
      `BeforeSwapDelta` branches, router delta/refund/Permit2 logic, quoter parity, vendored-BaseHook
      drift (none), and the wrapper boundary against `../maseer-one` source + live mainnet state.
      63/63 tests green, 100% coverage (lines/statements/branches/funcs), deploy script fork-dry-run
      clean (mined hook `0x2f51…c888`, flags `0x888`). Doc corrections applied: wstGBP itself is **not**
      a proxy (its `pip`/`act`/`cop` feeds and tGBP are — README trust model), stale test counts, and
      the price-scaled exact-out dust bound.

## Design invariants (do NOT regress without a deliberate decision)

- **Settle-first only.** `beforeSwap` runs before the taker pays, so input must be pre-settled into
  the PoolManager. Stock swap-then-settle routers are unsupported by design.
- **No hook buffer, no owner.** The hook wraps the swap's own tokens; it never holds inventory or
  privileged roles. (We removed an earlier ERC-6909 buffer + owner/sweep on purpose.)
- **No extra hook fee.** The 25bps spread is the wrapper's; the hook is a pass-through.
- currency0 = tGBP, currency1 = wstGBP; flags = `0x888`.

## Backlog (prioritized)

### P1 — Integration layer (needed before bots can use it)

- [x] **Quoting.** `WsgemQuoter` (on-chain, exact, with `previewSwap` executability) + off-chain
      formula documented in `CLAUDE.md`. Tests assert quote == execution for all four modes.
- [x] **Harden `WsgemSwapRouter`**: split into `swapExactInput` (enforces `minAmountOut`) /
      `swapExactOutput` (enforces `maxAmountIn`, refunds surplus); both take `deadline` + `recipient`
      (`address(0)` ⇒ `msg.sender`). Tested: minOut, maxIn, deadline, recipient, surplus refund.
      - [x] Permit2 entrypoints — `swapExactInputPermit2`/`swapExactOutputPermit2` (SignatureTransfer;
            payer signs a `PermitTransferFrom`, no router approval). Fork-tested vs the approval path.
- [x] **Deploy the router (and quoter)** from `script/DeployWstGBP.s.sol`.

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
      in `script/DeployWstGBP.s.sol`.
- [x] **(6) Consolidation — RESOLVED (2026-06-03).** Chose the **pure backstop** (see the Decision note
      at the top). The hybrid hook/quoter/tests were removed from the tree (preserved at `b7a5c5a`); the
      deploy script now deploys only the backstop. Revisit the hybrid only if in-pool LP demand materializes.

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

- [x] Integrator events — `WsgemSwapRouter` emits `Swap(payer, recipient, poolId, zeroForOne,
      amountIn, amountOut)` once per swap (all four entrypoints), beyond the PoolManager's own `Swap`.
- [x] Security review / audit prep pass — done (reports under `~/.claude/plans/`).
      Fixed F1 (`RedeemUnderpaid` + cooldown handling: hybrid sells fall back to LP, backstop reverts;
      router enforces exact-output full delivery). Trust model documented in `README.md` (F4).
- [x] Second deep-dive (charge-only-what's-filled): fixed the hybrid **sub-threshold residual** edges.
      EXACT-IN now refunds the un-wrappable dust (`_backstopExactIn` returns `inConsumed`; `_beforeSwap`
      bills `ammIn + inConsumed`) instead of charging the full input for zero output. EXACT-OUT reverts
      `BackstopResidualTooSmall` instead of clamping the input up to `mintcost`/`WAD` and overcharging
      (which had made the hybrid *worse* than the pure backstop and left ~1 token of locked dust in the
      hook). The hook now keeps no dust on these paths; `WstGBPHybridQuoter` mirrors both (exact-in is a
      lower bound, `quoteExactOutput` reverts, `previewSwap` flags `"residual below wrapper threshold"`).
      Regression tests added to `test/WstGBPHybridHook.t.sol`. Low/info items deferred to external audit:
      hook doesn't pin `fee`/`tickSpacing`, no `beforeInitialize` guard,
      `_edgeSqrtPrice` double-floor, exact-out capacity 1-wei window.
- [x] **Gas-optimization pass (2026-05-31)** — all 58 tests still green, pricing byte-identical
      (`quote == execution` parity + round-trip tests unchanged):
      - Both hooks now read the backstop price **directly off the wrapper's immutable feeds**
        (`act.mintcost(pip.read())` / `act.burncost(pip.read())` / `act.cooldown()`) instead of
        `wrapper.mintcost()`/`burncost()`/`cooldown()`, skipping the wrapper dispatch hop. `act`/`pip`
        are `immutable` in the wrapper, fetched once in each constructor and cached as immutables ⇒
        byte-identical to the wrapper facade (`mint`/`redeem` use the same feeds). New
        `src/core/interfaces/IFeeds.sol`; `Iwsgem` gained `act()`/`pip()` getters; quoters left on the
        facade (off-chain; same value ⇒ parity preserved).
      - Backstop sell-exact-out deduped (was reading `burncost()` twice); hybrid reads the direction's
        cost **once per swap** and threads it into `_edgeSqrtPrice`/`_backstopExactIn`/`_backstopExactOut`
        (now take a `cost` param; `_edgeSqrtPrice` is `pure`).
      - Hybrid `_inNestedSwap` reentrancy guard is now `bool private transient` (EIP-1153) ⇒ the hook
        holds **zero persistent storage**. Required bumping `solc_version` 0.8.26 → **0.8.28** (evm stays
        `cancun`); v4 deps compile fine (forge compiles the one exact-`0.8.26`-pinned dep in its own unit).
      - `via_ir=true` measured a real **-193,800 gas (-1.210%)** whole-suite, all 58 tests green. Since
        fork-test totals are dominated by *unchanged* mainnet external calls, that -1.21% is
        concentrated in our own contract code. **Decision (user):** flipped the default profile to
        `via_ir = true` (slower compiles, always-optimized bytecode). `.gas-snapshot` baseline (58
        entries, committed-able) regenerated at `via_ir=true`.
- [x] **Security-audit fixes (2026-05-31, `SECURITY_AUDIT.md` — since removed from the tree; in git
      history at `7ad0b89`)** — all 62 tests green at the time (58 prior + 4
      new regressions across the 3 findings; each mutation-checked to fail on the pre-fix code):
      - **M-01 (Med):** the hybrid AMM edge now nets out the **full directional swap fee** v4 charges
        (LP fee + any pool protocol fee), not just `key.fee`. `WstGBPHybridHook._beforeSwap` reads
        slot0's `protocolFee`/`lpFee` once, derives the combined `swapFee` (`ProtocolFeeLibrary`), and
        feeds it to `_edgeSqrtPrice` (and threads the already-read `sqrtP` into `_fillAmm`).
        `WstGBPHybridQuoter` mirrors it via a shared `_edgeFor`. Stops the nested AMM consuming LP
        priced worse than the backstop when a protocol fee is enabled. No-op when `protocolFee == 0`.
      - **L-01 (Low):** dynamic-fee (`0x800000`) and `>=100%` fee keys now revert `PoolNotSupported`
        in the hook and quoter (`key.fee >= PIPS`, plus a combined `swapFee >= PIPS` guard) instead of
        underflowing / dividing by zero in the edge math. Normal static fees (5bps, 30bps) unaffected.
      - **L-02 (Low):** `WsgemQuoter.previewSwap` capacity check now uses the **minted** amount
        (`amountIn·1e18/mintcost`), which for an exact-output buy is `>=` the requested output, instead
        of the requested output — closing a false `executable=true` at the capacity boundary.
      - Informational items (I-01..I-05: canonical-PoolKey docs, cached-feed monitoring, `ffi=false`,
        submodule pin, exact-in dust-past-edge) deferred to a follow-up / the external audit.
- [~] **I-04 — pin/record dependency provenance.** No release tag yet ships the required periphery APIs,
      so the audited commits are **documented** in `AUDIT_SCOPE.md` instead: `lib/v4-periphery` at
      `363226d` (heads/main), nested `lib/v4-core` at `v4.0.0` (`59d3ecf5`). Re-pin to a tagged release
      once one supports the APIs. (Repo is now under git, so a future re-pin is straightforward.)
