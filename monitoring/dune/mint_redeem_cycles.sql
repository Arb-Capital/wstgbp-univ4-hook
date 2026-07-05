-- WETH/wstGBP hook: mint/redeem cycle count — direction flips per day in the SwapFee stream,
-- ordered by (block, log index). Each flip is half an oscillation harvested by POL. Raw-log form.
-- param: {{hook_address}}

WITH ordered AS (
    SELECT
        date_trunc('day', block_time) AS day,
        varbinary_to_uint256(topic1) AS mint_side,
        lag(varbinary_to_uint256(topic1)) OVER (ORDER BY block_number, index) AS prev_side
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND block_time >= TIMESTAMP '2026-07-04' -- deploy date: partition-prunes the full-history scan
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
)
SELECT
    day,
    count(*) AS swaps,
    sum(IF(prev_side IS NOT NULL AND mint_side != prev_side, 1, 0)) AS direction_flips
FROM ordered
GROUP BY 1
ORDER BY 1 DESC
