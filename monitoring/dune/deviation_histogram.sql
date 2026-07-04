-- WETH/wstGBP hook: |deviation| histogram (5 bps buckets) over the trailing 30d, split by
-- whether the surcharge regime was active (|d| > 10 bps threshold). Raw-log form; decoded
-- equivalent: <namespace>.WethWstGbpHook_evt_SwapFee.
--
-- deviationPpm is data word [1], SIGNED (two's complement) — decode via varbinary_to_int256.
-- param: {{hook_address}}

WITH swaps AS (
    SELECT
        varbinary_to_int256(varbinary_substring(data, 33, 32)) AS deviation_ppm,
        varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1 AS fallback_mode
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
      AND block_time > now() - interval '30' day
)
SELECT
    (abs(deviation_ppm) / 500) * 5 AS abs_deviation_bucket_bps, -- 5-bps-wide buckets (500 ppm)
    abs(deviation_ppm) > 1000 AS surcharge_regime,
    count(*) AS swaps
FROM swaps
WHERE NOT fallback_mode -- deviation is 0-by-definition in fallback; keep the histogram honest
GROUP BY 1, 2
ORDER BY 1, 2
