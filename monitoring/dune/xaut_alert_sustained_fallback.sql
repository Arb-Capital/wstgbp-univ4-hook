-- ALERT: sustained fallback mode — returns rows iff >50% of swaps in the trailing 60 minutes
-- were fallback-priced AND at least 3 swaps were observed. Schedule hourly with alert-on-results
-- (email/webhook) if/when this venue's flow justifies it. Raw-log form.
--
-- Remember the blind spot: no swaps = no rows here even if the oracle is down; pair with the
-- off-chain monitoring/check_feeds.sh cron (which also carries this venue's XAU/USD probe).
-- GOLD MARKET HOURS: gold closes weekends/holidays (+ the 22:00–23:00 UTC daily break).
-- Chainlink usually heartbeats a frozen price through the close (flat fair — NOT fallback), but
-- if the feed pauses instead, staleness fallback is EXPECTED — cross-check against market hours
-- before reacting to a weekend firing. More fallback minutes than the USDC venue is normal here.
-- param: {{hook_address}} — the deployed XautWstGbpHook (0x68cF17471aA0Fe54578747C6C7e66795bC8020C0, deployed 2026-07-17)

WITH recent AS (
    SELECT varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1 AS fallback_mode
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
      AND block_time > now() - interval '60' minute
)
SELECT
    count(*) AS swaps_last_hour,
    sum(IF(fallback_mode, 1, 0)) AS fallback_swaps,
    round(100.0 * sum(IF(fallback_mode, 1, 0)) / count(*), 1) AS fallback_pct
FROM recent
HAVING count(*) >= 3
   AND sum(IF(fallback_mode, 1, 0)) * 2 > count(*)
