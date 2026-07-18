-- XAUT/wstGBP hook: per-day fallback-mode activity — distinct minutes with a fallback-priced
-- swap, OracleFallback counts by reason, and per-reason occurrences. Raw-log form.
--
-- IDENTICAL event signatures to the WETH and USDC venues, but the REASON CODES are PER-VENUE
-- (this venue: 8-entry two-feed enum — structurally the WETH numbering with XAU/USD in the
-- ETH/USD position; it still RENUMBERS vs the USDC 5-entry enum. See the README reason-code
-- table; do NOT copy another venue's mapping):
--   OracleFallback(uint8 reason) topic0 = 0xbcb18a4679b96763174578896ce0d13f3639a049ad81eb7c3f96983258ee9bd4
--   reasons: 1 XAU feed call, 2 XAU feed answer, 3 XAU feed stale, 4 GBP feed call,
--            5 GBP feed answer, 6 GBP feed stale, 7 NAV bad, 255 owner-paused
--   COUNTING SEMANTICS MIX: codes 1-7 emit once per TRANSACTION (write-once verdict cache);
--   0xFF emits once per SWAP (the pause path skips the cache) - occurrences are not comparable
--   across that boundary.
--   GOLD MARKET HOURS: 'XAU feed stale' (3) bursts over weekends/holidays are EXPECTED if
--   Chainlink pauses through the close — cross-check market hours before treating them as an
--   incident; more fallback minutes than the USDC venue is normal here.
-- SwapFee fallbackMode = data word [2] of
--   0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
--
-- KNOWN BLIND SPOT: both events only emit on swaps — a quiet pool in fallback is invisible
-- on-chain. monitoring/check_feeds.sh watches the root cause (the feeds + NAV) off-chain.
-- param: {{hook_address}} — the deployed XautWstGbpHook (0x68cF17471aA0Fe54578747C6C7e66795bC8020C0, deployed 2026-07-17)

WITH fallback_swaps AS (
    SELECT block_time
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-17' -- xaut-venue deploy date (block 25555342)
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
      AND varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1
),
reasons AS (
    SELECT
        date_trunc('day', block_time) AS day,
        varbinary_to_uint256(varbinary_substring(data, 1, 32)) AS reason_code,
        CASE varbinary_to_uint256(varbinary_substring(data, 1, 32))
            WHEN 1 THEN 'XAU feed call'
            WHEN 2 THEN 'XAU feed answer'
            WHEN 3 THEN 'XAU feed stale (weekend/holiday close is the expected cause)'
            WHEN 4 THEN 'GBP feed call'
            WHEN 5 THEN 'GBP feed answer'
            WHEN 6 THEN 'GBP feed stale'
            WHEN 7 THEN 'NAV bad (pip paused)'
            WHEN 255 THEN 'owner paused'
            ELSE 'unknown'
        END AS reason,
        count(*) AS occurrences
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-17' -- xaut-venue deploy date (block 25555342)
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
