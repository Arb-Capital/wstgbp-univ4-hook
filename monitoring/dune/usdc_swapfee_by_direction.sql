-- wstGBP/USDC hook: daily swap count + fee stats by direction (mint side = wstGBP in).
-- RAW-LOG FORM so it works from block one, before Dune decodes the ABI. Decoded-table
-- equivalent after ABI submission: <namespace>.UsdcWstGbpHook_evt_SwapFee.
--
-- event SwapFee(bool indexed mintSide, uint24 fee, int256 deviationPpm, bool fallbackMode)
-- topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
-- topic1 = mintSide; data words: [0] fee ppm, [1] deviationPpm (int), [2] fallbackMode
--
-- param: {{hook_address}} — the deployed UsdcWstGbpHook

SELECT
    date_trunc('day', block_time) AS day,
    IF(varbinary_to_uint256(topic1) = 1, 'mint (wstGBP in)', 'redeem (USDC in)') AS direction,
    count(*) AS swaps,
    avg(varbinary_to_uint256(varbinary_substring(data, 1, 32))) AS avg_fee_ppm,
    max(varbinary_to_uint256(varbinary_substring(data, 1, 32))) AS max_fee_ppm,
    approx_percentile(CAST(varbinary_to_uint256(varbinary_substring(data, 1, 32)) AS double), 0.5) AS p50_fee_ppm,
    sum(IF(varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1, 1, 0)) AS fallback_swaps
FROM ethereum.logs
WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-05' -- deploy date: partition-prunes the full-history scan
  AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
GROUP BY 1, 2
ORDER BY 1 DESC, 2
