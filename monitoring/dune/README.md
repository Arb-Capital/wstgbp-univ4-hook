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

## wstGBP/USDC venue (added 2026-07-05; hook address TBD at deploy)

The usdc hook emits the SAME event signatures as the weth hook (`SwapFee`, `OracleFallback` —
identical topic0s), so `swapfee_by_direction.sql`, `deviation_histogram.sql`, and
`alert_sustained_fallback.sql` are reused AS-IS by saving a second Dune query with
`{{hook_address}}` = the usdc hook and the `block_time` floor moved to its deploy date
("redeem" direction reads "USDC in"). `fallback_minutes.sql` is the exception — it decodes reason
codes, which RENUMBER between venues; use `usdc_fallback_minutes.sql` instead. Submit the usdc
hook for contract decoding at dune.com/contracts/new after deploy.

**Cross-venue `OracleFallback` reason codes — do NOT copy-paste decoders across venues:**

| code | weth venue (8-entry enum) | usdc venue (5-entry enum) |
|---|---|---|
| 1 | ETH feed call | GBP feed call |
| 2 | ETH feed answer | GBP feed answer |
| 3 | ETH feed stale | GBP feed stale |
| 4 | GBP feed call | NAV bad (pip paused) |
| 5 | GBP feed answer | — |
| 6 | GBP feed stale | — |
| 7 | NAV bad (pip paused) | — |
| 255 | owner paused | owner paused (also the USDC-depeg runbook) |

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

The SQL here is the source of truth — if you edit a file, mirror the edit to the Dune query.
