# Security Audit Report

Date: 2026-05-31

Scope: first-party code in `src/`, `script/`, tests, deployment configuration, and the integration
boundary with Uniswap v4, Permit2, and the Maseer wstGBP wrapper. Vendored `lib/` code was treated as
trusted upstream, but relevant boundary behavior was reviewed.

Baseline:

- `forge test -vv`: 58 passed, 0 failed.
- `slither` and `aderyn` were not installed locally, so this report is based on manual review plus the
  Foundry fork suite.

## Summary

| ID | Severity | Title | Status |
| --- | --- | --- | --- |
| M-01 | Medium | Hybrid AMM edge ignores Uniswap v4 protocol fees | **Fixed (2026-05-31)** |
| L-01 | Low | Unsupported dynamic or 100% fee pool keys can brick hybrid swaps and quotes | **Fixed (2026-05-31)** |
| L-02 | Low | Backstop preview can false-positive exact-output buys at the capacity boundary | **Fixed (2026-05-31)** |
| I-01 | Informational | Router and quoters trust caller-supplied `PoolKey` values | Open (deferred) |
| I-02 | Informational | Cached feed proxy addresses rely on semantic compatibility | Open (deferred) |
| I-03 | Informational | `ffi = true` is enabled although no first-party test uses `vm.ffi` | Open (deferred) |
| I-04 | Informational | `v4-periphery` is pinned to a commit on `heads/main`, not a release tag | Open (deferred) |
| I-05 | Informational | Hybrid exact-input dust residuals may be filled by the outer AMM past the edge | Open (deferred) |

No critical or high severity implementation bugs were found in the reviewed scope.

**Remediation (2026-05-31):** M-01, L-01, and L-02 are fixed; the informational items are deferred to
a follow-up / the external audit. The fix adds 4 regression tests across the 3 findings (each
mutation-checked to fail on the pre-fix code); the full fork suite is 62 passing. See per-finding "Resolution" notes below and the
`ROADMAP.md` P4 entry.

## Findings

### M-01: Hybrid AMM edge ignores Uniswap v4 protocol fees

Affected code:

- `src/WstGBPHybridHook.sol:137`
- `src/WstGBPHybridHook.sol:258`
- `src/WstGBPHybridHook.sol:260`
- `src/WstGBPHybridHook.sol:261`
- `src/periphery/WstGBPHybridQuoter.sol:124`
- `src/periphery/WstGBPHybridQuoter.sol:340`
- `src/periphery/WstGBPHybridQuoter.sol:342`
- `src/periphery/WstGBPHybridQuoter.sol:343`

The hybrid hook computes its nested AMM edge from `key.fee`, which is the LP fee in the canonical
static-fee pool. Uniswap v4 can also apply a direction-specific protocol fee from pool `slot0`.
`Pool.swap` combines the protocol fee with the LP fee before computing the actual swap step.

If a protocol fee is enabled for the tGBP/wstGBP pool, the hook can continue consuming AMM liquidity
up to an edge that only accounts for the LP fee. The AMM leg can then be worse than the wrapper
backstop by up to the enabled protocol fee, violating the stated best-execution invariant that LP
worse than the backstop edge is never used. The LP-aware quoter simulates protocol fees after using
the same LP-fee-only edge, so quote parity can still hold while the quote itself is worse than the
pure backstop.

Impact is bounded by the v4 max protocol fee, but it affects the main economic invariant and can be
triggered by an external protocol-fee configuration change rather than by this hook's owner, since the
hook is ownerless.

Recommendation:

- Compute the edge from the total swap fee that v4 will apply for the direction, not just `key.fee`.
- Read `protocolFee` and `lpFee` from `poolManager.getSlot0(key.toId())`, derive the directional
  `swapFee` with `ProtocolFeeLibrary.calculateSwapFee`, and pass that value into `_edgeSqrtPrice`.
- Keep the quoter edge calculation byte-for-byte aligned with the hook.
- If dynamic-fee pools remain unsupported, reject them explicitly before edge math.

Fix-ready tests:

- In a fork test, initialize the hybrid pool, set a non-zero protocol fee on the pool using the v4
  protocol fee controller path or direct storage cheat, and add LP near the old LP-fee-only edge.
- Assert that a hybrid exact-input buy and sell never returns less than the pure backstop quote after
  the fix.
- Assert that `WstGBPHybridQuoter` still matches execution after protocol fees are enabled.

**Resolution (2026-05-31):** `WstGBPHybridHook._beforeSwap` reads `protocolFee`/`lpFee` from
`getSlot0` once, derives the directional combined `swapFee` via a new `_swapFee` helper
(`ProtocolFeeLibrary.calculateSwapFee`, byte-identical to the quoter's), and passes that into
`_edgeSqrtPrice` (the already-read `sqrtP` is threaded into `_fillAmm` to avoid a second read).
`WstGBPHybridQuoter` mirrors it through a shared `_edgeFor`, so the quoter edge stays aligned with the
hook. With `protocolFee == 0` the result is byte-identical to the prior `key.fee` path.
Regression: `test_protocolFeeAwareEdge_buy` / `_sell` (`test/WstGBPHybridHook.t.sol`) enable the v4 max
protocol fee via the controller and assert the AMM stops at the protocol-fee-aware edge (prices at the
pure backstop, no overfill) and the LP quote still equals execution; both fail on the pre-fix code.

### L-01: Unsupported dynamic or 100% fee pool keys can brick hybrid swaps and quotes

Affected code:

- `src/WstGBPHybridHook.sol:258`
- `src/WstGBPHybridHook.sol:260`
- `src/WstGBPHybridHook.sol:261`
- `src/periphery/WstGBPHybridQuoter.sol:340`
- `src/periphery/WstGBPHybridQuoter.sol:342`
- `src/periphery/WstGBPHybridQuoter.sol:343`
- `script/DeployHook.s.sol:46`

The deployment script initializes the intended hybrid pool with a static 5 bps fee and tick spacing
60. The hook itself only checks the two currencies, so other tGBP/wstGBP pools can use the same hook
with different fee and tick-spacing settings.

For dynamic-fee pools, `key.fee` is `0x800000`. For a static 100% fee pool, `key.fee` is `1_000_000`.
Both values are accepted at the v4 pool layer in their respective contexts, but the hook/quoter edge
math performs `PIPS - fee`. Dynamic fees underflow, and 100% static fees can divide by zero. This
turns those alternative pools into revert-only paths for the hybrid hook and quoter.

This does not compromise the canonical deploy script's 5 bps pool, but it is a sharp edge because the
router and quoter APIs accept caller-supplied `PoolKey` values.

Recommendation:

- If only one canonical pool is intended, pin the supported `fee` and `tickSpacing` in the hybrid hook
  and quoter, and revert with `PoolNotSupported` for anything else.
- If multiple static-fee pools are intended, explicitly reject `fee >= PIPS` and dynamic-fee keys.
- If dynamic-fee pools should be supported, use the current slot0 LP fee and return/handle LP fee
  overrides consistently.

Fix-ready tests:

- Initialize a tGBP/wstGBP pool with `fee = 0x800000` and the hybrid hook, then assert that swaps and
  quotes revert with a clear project error after the fix.
- Initialize a static `fee = 1_000_000` pool and assert the same explicit rejection.
- For the canonical `fee = 500`, assert behavior is unchanged.

**Resolution (2026-05-31):** chose option "reject dynamic & `>=100%`, allow other static fees" (the
suite uses both 5bps and 30bps pools). `WstGBPHybridHook._beforeSwap` reverts `PoolNotSupported` when
`key.fee >= PIPS` (catches the dynamic flag `0x800000` and `1_000_000`), plus a `swapFee >= PIPS` guard
for the rare case where a near-100% LP fee combined with the max protocol fee sums to `PIPS`.
`WstGBPHybridQuoter` adds a matching `PoolNotSupported` error and the same guards in `_edgeFor`.
Regression: `test_unsupportedFeeKeysRevert` asserts both the dynamic and 100% keys revert on swap and
on all three quoter entrypoints, and that the canonical 5bps pool is unaffected.

### L-02: Backstop preview can false-positive exact-output buys at the capacity boundary

Affected code:

- `src/WstGBPBackstopHook.sol:135`
- `src/WstGBPBackstopHook.sol:137`
- `src/periphery/WstGBPQuoter.sol:49`
- `src/periphery/WstGBPQuoter.sol:77`
- `src/periphery/WstGBPQuoter.sol:92`

For exact-output buys, the backstop hook rounds tGBP input up and calls `wrapper.mint(tgbpIn)`.
The wrapper can mint slightly more wstGBP than the exact requested output, with the surplus dust
remaining in the hook. `WstGBPQuoter.previewSwap` checks capacity with the requested `amountOut`, not
with the actual minted amount implied by rounded-up `amountIn`.

At a tight capacity boundary, `previewSwap` can report `executable = true` even though execution
reverts inside `wrapper.mint` because `totalSupply + mintedAmount > capacity`.

There is no fund loss because the transaction reverts, but integrators can get a false executable
signal.

Recommendation:

- In the buy branch of `_check`, compute the minted amount from `amountIn` using the same wrapper
  formula and use that value for the capacity check.
- Keep exact-input behavior unchanged; for exact-input buys, quoted `amountOut` already equals minted
  output.

Fix-ready tests:

- Pick a buy exact-output amount where `quoteExactOutput(true, amountOut)` mints more than
  `amountOut`.
- Set `capacity = totalSupply + amountOut` on the fork.
- Assert current `previewSwap` reports executable while execution reverts.
- After the fix, assert `previewSwap` returns `executable = false` with `"exceeds capacity"`.

**Resolution (2026-05-31):** `WstGBPQuoter._check` now computes `minted = mulDiv(amountIn, 1e18,
mintcost)` (exactly what `wrapper.mint(amountIn)` produces) and checks capacity against `minted` rather
than the requested `amountOut`; `amountOut` is no longer needed by `_check`. Exact-input is unchanged
(`minted == amountOut`); only exact-output buys at the boundary are affected (the hybrid quoter already
derived its capacity check from the rounded-up input, so it needed no change). Regression:
`test_previewCapacityUsesMintedNotRequestedOutput` drives the NAV sub-par (pip price slot + zero ask
spread, so the rounded-up input mints strictly more than requested), pins capacity at the requested-out
boundary, and asserts the preview flags `"exceeds capacity"` while pre-fix it reported executable.

## Informational

### I-01: Router and quoters trust caller-supplied `PoolKey` values

Affected code:

- `src/periphery/WstGBPSwapRouter.sol:87`
- `src/periphery/WstGBPSwapRouter.sol:105`
- `src/periphery/WstGBPSwapRouter.sol:125`
- `src/periphery/WstGBPSwapRouter.sol:141`
- `src/periphery/WstGBPHybridQuoter.sol:66`
- `src/periphery/WstGBPHybridQuoter.sol:78`
- `src/periphery/WstGBPHybridQuoter.sol:98`

The router and quoters are intentionally generic over `PoolKey`. The hook validates currencies, but
the periphery does not pin the canonical hook address, fee, tick spacing, or initialized pool id.
This is acceptable for low-level periphery, but frontends, bots, and solvers must pin the canonical
pool key off-chain and must not accept arbitrary user- or route-supplied keys without validation.

Recommended test/documentation:

- Add a periphery integration test that passes a wrong hook/fee key and assert the failure mode is
  documented.
- Document the canonical `PoolKey` in deployment output and integration docs.

### I-02: Cached feed proxy addresses rely on semantic compatibility

Affected code:

- `src/WstGBPBackstopHook.sol:62`
- `src/WstGBPBackstopHook.sol:63`
- `src/WstGBPBackstopHook.sol:175`
- `src/WstGBPBackstopHook.sol:180`
- `src/WstGBPHybridHook.sol:79`
- `src/WstGBPHybridHook.sol:80`
- `src/WstGBPHybridHook.sol:270`
- `src/WstGBPHybridHook.sol:275`

The hooks cache `act` and `pip` from the wrapper constructor-time view and then price swaps directly
through those cached feeds. This is acceptable under the Maseer architecture because those values are
immutable proxy addresses; implementation upgrades happen behind the proxies, and upgraded
implementations are required to continue exposing the methods used by the hook.

The residual trust-model risk is semantic compatibility: if an upgraded implementation behind one of
those immutable proxies changes the behavior of `mintcost`, `burncost`, `cooldown`, or `read` while
keeping the same method surface, existing hooks will consume the new semantics immediately. That is
consistent with the documented Maseer governance/proxy trust model and is not a bug in this hook.

Recommended monitoring/test:

- Monitor implementation upgrades behind the wrapper, `act`, and `pip` proxies.
- Add a fork test that asserts `hook.act() == wrapper.act()`, `hook.pip() == wrapper.pip()`, and cached
  proxy-read prices equal the wrapper facade prices at deployment time.

### I-03: `ffi = true` is enabled although no first-party test uses `vm.ffi`

Affected code:

- `foundry.toml:10`

Foundry FFI allows tests/scripts to execute host commands. The first-party test suite does not use
`vm.ffi`, so enabling it by default increases local execution risk for anyone running commands in a
dirty or untrusted checkout.

Recommendation:

- Set `ffi = false` in the default profile.
- If needed for mining or auxiliary scripts later, move it to an explicit profile and document when to
  use that profile.

### I-04: `v4-periphery` is pinned to a commit on `heads/main`, not a release tag

Affected code:

- `.gitmodules:4`
- `.gitmodules:6`
- submodule status: `lib/v4-periphery` at `363226d9e1e2180b67bf6857023dbaad751010c5 (heads/main)`

The checked-out submodule commit is deterministic in git, but the dependency is not tied to a tagged
release in metadata. This makes provenance and future update review harder.

Recommendation:

- Pin `lib/v4-periphery` to a tagged release when one supports the required APIs, or document the
  audited commit explicitly in release notes.
- Keep `foundry.lock` or equivalent dependency metadata in sync.

### I-05: Hybrid exact-input dust residuals may be filled by the outer AMM past the edge

Affected code:

- `src/WstGBPHybridHook.sol:143`
- `src/WstGBPHybridHook.sol:150`
- `src/WstGBPHybridHook.sol:153`
- `src/WstGBPHybridHook.sol:201`
- `src/WstGBPHybridHook.sol:208`

For exact-input hybrid swaps, if the nested AMM consumes liquidity to the edge and the remaining input
is below the wrapper mint/redeem threshold, the hook does not backstop or bill that residual. The
remaining amount is left for the outer swap. If there is liquidity beyond the backstop edge, the outer
swap can consume that sub-threshold residual at a worse-than-backstop AMM price instead of refunding
it.

The economic size is bounded by the wrapper dust threshold, and slippage limits still protect users.
This is consistent with the current comments, but it is a small exception to the simplified invariant
that out-of-band LP is never used.

Recommended test/documentation:

- Add a test with in-band LP up to the edge plus out-of-band LP past the edge, choosing an exact-input
  amount that leaves a sub-threshold residual.
- Assert the maximum possible loss is bounded by the residual and document whether this dust behavior
  is accepted or should instead revert.

## Additional Review Notes

- The pure backstop hook's delta accounting, underfunded redeem guard, cooldown sell rejection, and
  settle-first assumption are covered by the current fork tests.
- The hybrid hook's no-LP parity, LP blend, quote parity, cooldown fallback, and sub-threshold exact
  output behavior are covered by the current fork tests.
- Permit2 usage correctly binds signatures to the router as spender and to `msg.sender` as owner.
- The max approval from hook to wrapper is acceptable under the documented Maseer trust model, but any
  accidental tGBP sent to the hook is exposed to wrapper behavior and has no recovery path.
