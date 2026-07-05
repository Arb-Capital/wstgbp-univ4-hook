-- WETH/wstGBP hook: per-day fallback-mode activity — distinct minutes with a fallback-priced
-- swap, OracleFallback counts by reason, and the max consecutive-fallback window. Raw-log form.
--
-- OracleFallback(uint8 reason) topic0 = 0xbcb18a4679b96763174578896ce0d13f3639a049ad81eb7c3f96983258ee9bd4
--   reasons: 1-3 ETH feed (call/answer/stale), 4-6 GBP feed, 7 NAV bad, 255 owner-paused
-- SwapFee fallbackMode = data word [2] of
--   0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
--
-- KNOWN BLIND SPOT: both events only emit on swaps — a quiet pool in fallback is invisible
-- on-chain. monitoring/check_feeds.sh watches the root cause (the feeds) off-chain.
-- param: {{hook_address}}

WITH fallback_swaps AS (
    SELECT block_time
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-04' -- deploy date: partition-prunes the full-history scan
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
      AND varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1
),
reasons AS (
    SELECT
        date_trunc('day', block_time) AS day,
        varbinary_to_uint256(varbinary_substring(data, 1, 32)) AS reason,
        count(*) AS occurrences
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-04' -- deploy date: partition-prunes the full-history scan
      AND topic0 = 0xbcb18a4679b96763174578896ce0d13f3639a049ad81eb7c3f96983258ee9bd4
    GROUP BY 1, 2
)
SELECT
    coalesce(f.day, r.day) AS day,
    f.fallback_minutes,
    r.reason,
    r.occurrences
FROM (
    SELECT date_trunc('day', block_time) AS day, count(DISTINCT date_trunc('minute', block_time)) AS fallback_minutes
    FROM fallback_swaps
    GROUP BY 1
) f
FULL OUTER JOIN reasons r ON f.day = r.day
ORDER BY 1 DESC, r.reason
