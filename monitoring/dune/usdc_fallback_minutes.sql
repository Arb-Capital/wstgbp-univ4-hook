-- wstGBP/USDC hook: per-day fallback-mode activity — distinct minutes with a fallback-priced
-- swap, OracleFallback counts by reason, and per-reason occurrences. Raw-log form.
--
-- IDENTICAL event signatures to the WETH venue, but the REASON CODES RENUMBER (single-feed
-- 5-entry enum — see the README reason-code table; do NOT copy the weth mapping):
--   OracleFallback(uint8 reason) topic0 = 0xbcb18a4679b96763174578896ce0d13f3639a049ad81eb7c3f96983258ee9bd4
--   reasons: 1 GBP feed call, 2 GBP feed answer, 3 GBP feed stale, 4 NAV bad, 255 owner-paused
--   (An owner pause is ALSO the depeg runbook — a burst of 255s may mean USDC depeg response,
--   not oracle failure; cross-check monitoring/check_feeds.sh alerts.)
--   COUNTING SEMANTICS MIX: codes 1-4 emit once per TRANSACTION (write-once verdict cache);
--   0xFF emits once per SWAP (the pause path skips the cache) - occurrences are not comparable
--   across that boundary.
-- SwapFee fallbackMode = data word [2] of
--   0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
--
-- KNOWN BLIND SPOT: both events only emit on swaps — a quiet pool in fallback is invisible
-- on-chain. monitoring/check_feeds.sh watches the root cause (the feed + USDC peg) off-chain.
-- param: {{hook_address}} — the deployed UsdcWstGbpHook
-- NOTE: update the block_time floor to the usdc hook's deploy date before saving on Dune.

WITH fallback_swaps AS (
    SELECT block_time
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-05' -- usdc-venue deploy date (update at deploy)
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
      AND varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1
),
reasons AS (
    SELECT
        date_trunc('day', block_time) AS day,
        varbinary_to_uint256(varbinary_substring(data, 1, 32)) AS reason_code,
        CASE varbinary_to_uint256(varbinary_substring(data, 1, 32))
            WHEN 1 THEN 'GBP feed call'
            WHEN 2 THEN 'GBP feed answer'
            WHEN 3 THEN 'GBP feed stale'
            WHEN 4 THEN 'NAV bad (pip paused)'
            WHEN 255 THEN 'owner paused (incl. depeg runbook)'
            ELSE 'unknown'
        END AS reason,
        count(*) AS occurrences
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-05' -- usdc-venue deploy date (update at deploy)
      AND topic0 = 0xbcb18a4679b96763174578896ce0d13f3639a049ad81eb7c3f96983258ee9bd4
    GROUP BY 1, 2
)
SELECT
    coalesce(f.day, r.day) AS day,
    f.fallback_minutes,
    r.reason_code,
    r.reason,
    r.occurrences
FROM (
    SELECT date_trunc('day', block_time) AS day, count(DISTINCT date_trunc('minute', block_time)) AS fallback_minutes
    FROM fallback_swaps
    GROUP BY 1
) f
FULL OUTER JOIN reasons r ON f.day = r.day
ORDER BY 1 DESC, r.reason_code
