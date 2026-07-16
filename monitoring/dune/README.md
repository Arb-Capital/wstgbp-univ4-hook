# Dune queries — created 2026-07-04 (hook `0xe5F6…E0c0`)

All created as public, saved (non-temp), parameterized on `{{hook_address}}` (default = the
deployed hook). **None are scheduled** — free-tier credit policy: index everything, schedule
nothing; run on demand. Measured cost: the alert query = **0.072 credits/run** on the free engine
(daily schedule ≈ 2 credits/month, hourly ≈ 52, every-15-min ≈ 207 — vs the 2,500/month quota).

| Query | Dune ID | Source |
|---|---|---|
| Sustained fallback alert (alert-on-results shape) | [7887581](https://dune.com/queries/7887581) | `alert_sustained_fallback.sql` |
| Daily fees by direction | [7887582](https://dune.com/queries/7887582) | `swapfee_by_direction.sql` |
| Deviation histogram (30d) | [7887584](https://dune.com/queries/7887584) | `deviation_histogram.sql` |
| Fallback minutes + reasons by day | [7887586](https://dune.com/queries/7887586) | `fallback_minutes.sql` |
| Mint/redeem cycles per day | [7887587](https://dune.com/queries/7887587) | `mint_redeem_cycles.sql` |

`compounder_activity.sql` intentionally not created (POLCompounder not adopted).

## wstGBP/USDC venue — created 2026-07-05 (hook `0x09ff…e0c0`, poolId `0x3413…5a5c`)

Same posture as the weth set: public, saved (non-temp), parameterized on `{{hook_address}}`
(default = the deployed UsdcWstGbpHook), **none scheduled** (free-tier credit policy; the daily
query cost 0.08 credits on its validation run). Contract decoding submitted 2026-07-05.

| Query | Dune ID | Source |
|---|---|---|
| Daily fees by direction (redeem = USDC in; deploy-date floor 2026-07-05) | [7893432](https://dune.com/queries/7893432) | `usdc_swapfee_by_direction.sql` |
| Deviation histogram (30d; note the band-edge rest state — mass away from zero is design) | [7893433](https://dune.com/queries/7893433) | `usdc_deviation_histogram.sql` |
| Sustained fallback alert (alert-on-results shape) | [7893434](https://dune.com/queries/7893434) | `usdc_alert_sustained_fallback.sql` |
| Fallback minutes + reasons by day (**usdc 5-entry reason mapping**) | [7893436](https://dune.com/queries/7893436) | `usdc_fallback_minutes.sql` |

Every deployed usdc query has its own source file above, byte-identical to what is saved on Dune
(the repo files are the source of truth — mirror edits to Dune, per the top of this README).
The usdc hook emits the SAME event signatures as the weth hook (`SwapFee`, `OracleFallback` —
identical topic0s); the first three differ from their weth counterparts only in the default
`{{hook_address}}`, plus per query: the daily-fees query's deploy-date floor (2026-07-05) and
"USDC in" direction label, and the histogram's band-edge venue note. The histogram and alert
carry no date floor by design — their trailing 30-day/60-minute windows already partition-prune.
`fallback_minutes` is the real divergence — reason codes RENUMBER between venues (table below);
never point the weth reason decoder at the usdc hook or vice versa.

**Cross-venue `OracleFallback` reason codes — do NOT copy-paste decoders across venues:**

| code | weth venue (8-entry enum) | usdc venue (5-entry enum) | xaut venue (8-entry enum) |
|---|---|---|---|
| 1 | ETH feed call | GBP feed call | XAU feed call |
| 2 | ETH feed answer | GBP feed answer | XAU feed answer |
| 3 | ETH feed stale | GBP feed stale | XAU feed stale |
| 4 | GBP feed call | NAV bad (pip paused) | GBP feed call |
| 5 | GBP feed answer | — | GBP feed answer |
| 6 | GBP feed stale | — | GBP feed stale |
| 7 | NAV bad (pip paused) | — | NAV bad (pip paused) |
| 255 | owner paused | owner paused (also the USDC-depeg runbook) | owner paused |

(The xaut column is structurally the weth numbering with XAU/USD in the ETH/USD position — two
feeds again — but it is still a DIFFERENT venue enum and still ≠ the usdc 5-entry mapping.)

## XAUT/wstGBP venue — prepared 2026-07-16 (NOT yet deployed; hook + poolId TBD)

Same posture as the other two dynamic-fee sets: public, saved (non-temp), parameterized on
`{{hook_address}}` (default = the deployed XautWstGbpHook), none scheduled. The four `xaut_*.sql`
sources below are written ahead of the deploy; **nothing exists on Dune yet** — at deploy, create
them from these files, set the deploy-date floors (marked TBD in the sources), record the Dune IDs
here, and submit the verified hook for decoding (DEPLOY.md §X6).

| Query | Dune ID | Source |
|---|---|---|
| Daily fees by direction (redeem = XAUT in; deploy-date floor TBD) | TBD at deploy | `xaut_swapfee_by_direction.sql` |
| Deviation histogram (30d; sign-split + direction-aware `surcharge_paying` — mass at d ≈ −5000 ppm is the token–metal basis rest state, BY DESIGN; at rest XAUT-in pays base only, wstGBP-in pays base + surcharge under the sub-basis threshold) | TBD at deploy | `xaut_deviation_histogram.sql` |
| Sustained fallback alert (alert-on-results shape; gold-market-hours caveat) | TBD at deploy | `xaut_alert_sustained_fallback.sql` |
| Fallback minutes + reasons by day (**xaut 8-entry reason mapping**) | TBD at deploy | `xaut_fallback_minutes.sql` |

The xaut hook emits the SAME event signatures (`SwapFee`, `OracleFallback` — identical topic0s) as
the weth and usdc hooks. Venue-specific: mint side = wstGBP-in (currency0 in), redeem = XAUT-in;
the histogram is sign-split because the venue's signature is the **token–metal basis** — XAUt
trades ~0.5% below the XAU/USD metal feed, so the pool RESTS at d ≈ −5000 ppm (design, not drift;
at rest the redeem conveyor reads non-closing and is never surcharged — watch for regime shifts,
not the rest mass); and expect MORE fallback minutes than the usdc venue — gold closes
weekends/holidays, and a paused feed over the close means expected staleness fallback (a
frozen-but-heartbeating feed just means flat fair). Reason codes RENUMBER again (table above);
never point another venue's reason decoder at the xaut hook.

## Backstop venue queries (added 2026-07-05, hook `0xfE36…4888`, poolId `0xdb21…5ce5`)

| Query | Dune ID | Source |
|---|---|---|
| Daily volume + implied mint/redeem price | [7887621](https://dune.com/queries/7887621) | `backstop_daily_volume.sql` |
| Flow attribution (router vs other lockers vs adapter) | [7887623](https://dune.com/queries/7887623) | `backstop_flow_attribution.sql` |

**Key gotcha (validated on-chain):** the backstop is a return-delta hook that cancels the AMM leg,
so the PoolManager `Swap` event logs **zero amounts** — volume must be reconstructed from the
ERC-20 transfer legs between the PoolManager and the hook (`take` = PM→hook input, `settle` =
hook→PM output). The weth venue does NOT have this issue (real AMM; PM event amounts are real).
Validation runs (2026-07-05): implied sell price 1.00153 (06-30) → 1.00219 (07-05) = live
`burncost` ratcheting, ~25 bps under NAV 1.0047 ✓; all pool flow so far via third-party lockers
(no router usage yet; adapter unused). Costs: daily-volume ≈ 0.5 credits/run, flow-attribution
≈ 2.2 (transfer-table join) — on-demand only.

One-time remaining step (free, enables decoded tables `<ns>.WethWstGbpHook_evt_SwapFee` etc.):
submit the contract for decoding at <https://dune.com/contracts/new> — address
`0xe5F619EC8Af334Fb54CcEcf6802378cd2100E0c0`, Ethereum; the ABI auto-fetches from Etherscan
(contract is verified). Decoding usually lands within ~a day; the raw-log queries above work
regardless.

The SQL here is the source of truth — if you edit a file, mirror the edit to the Dune query,
and if you edit on Dune, mirror back here in the same sitting.

**Consistency audit (2026-07-05):** every deployed query diffed against its repo source.
Result: weth 7887582/7887584/7887586/7887587 and backstop 7887621/7887623 (their on-Dune v2
edits had been mirrored back) byte-identical; 7887581 had comment-only drift (an older draft of
the scheduling note was live) — re-synced from the repo file; all four usdc queries created
2026-07-05 directly from their `usdc_*.sql` sources.
