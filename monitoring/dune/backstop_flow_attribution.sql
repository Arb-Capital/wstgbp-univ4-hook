-- tGBP/wstGBP BACKSTOP venue: WHO routes the flow.
--   * v4 pool swaps attributed by the PoolManager `sender` (the locker): our settle-first
--     WsgemSwapRouter vs any other locker (third-party settle-first integrations / MEV bots).
--     NOTE: the PM Swap event logs ZERO amounts for this return-delta hook, so volume is joined
--     from the tGBP transfer leg between PM and hook per tx (caveat: a tx with multiple backstop
--     swaps attributes its combined tGBP volume to each row — rare, monitoring-grade).
--   * plus the NON-pool venue: WsgemDirectAdapter direct mint/redeem (its own Swap event —
--     that flow never touches the pool).
-- Adapter event: Swap(address indexed payer, address indexed recipient, bool buy,
--                     uint256 amountIn, uint256 amountOut)
--   topic0 = 0x03e874ff0400af332019e3388ba3ec252559e9e6b33b393b1335aaf4755384e3
-- params: {{pool_id}}, {{router}}, {{adapter}}, {{pool_manager}}, {{hook}}, {{tgbp}}

WITH pool_swaps AS (
    SELECT
        evt_tx_hash,
        date_trunc('day', evt_block_time) AS day,
        IF(sender = {{router}}, 'v4 pool via WsgemSwapRouter', 'v4 pool via other locker') AS route
    FROM uniswap_v4_ethereum.poolmanager_evt_swap
    WHERE id = {{pool_id}}
      AND evt_block_date >= DATE '2026-06-28' -- backstop deploy date (partition prune)
),
tgbp_legs AS (
    SELECT evt_tx_hash, sum(value) AS tgbp
    FROM erc20_ethereum.evt_transfer
    WHERE contract_address = {{tgbp}}
      AND (("from" = {{pool_manager}} AND "to" = {{hook}}) OR ("from" = {{hook}} AND "to" = {{pool_manager}}))
      AND evt_block_time >= TIMESTAMP '2026-06-28'
    GROUP BY 1
),
pool_flow AS (
    SELECT s.day, s.route, count(*) AS swaps, sum(coalesce(l.tgbp, 0)) / 1e18 AS tgbp_volume
    FROM pool_swaps s
    LEFT JOIN tgbp_legs l ON l.evt_tx_hash = s.evt_tx_hash
    GROUP BY 1, 2
),
adapter_flow AS (
    SELECT
        date_trunc('day', block_time) AS day,
        'direct adapter (no pool)' AS route,
        count(*) AS swaps,
        sum(IF(varbinary_to_uint256(varbinary_substring(data, 1, 32)) = 1,
               varbinary_to_uint256(varbinary_substring(data, 33, 32)),
               varbinary_to_uint256(varbinary_substring(data, 65, 32)))) / 1e18 AS tgbp_volume
    FROM ethereum.logs
    WHERE contract_address = {{adapter}}
      AND block_time >= TIMESTAMP '2026-06-28'
      AND topic0 = 0x03e874ff0400af332019e3388ba3ec252559e9e6b33b393b1335aaf4755384e3
    GROUP BY 1
)
SELECT * FROM pool_flow
UNION ALL
SELECT * FROM adapter_flow
ORDER BY day DESC, route
