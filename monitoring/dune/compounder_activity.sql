-- POLCompounder: compound history — amounts folded in, liquidity added, dust carried, plus
-- rebalance skips (reason 1 = oracle fallback, 2 = dust epsilon, 3 = no pool liquidity).
-- Pair with a "no Compounded event in 30d while pendingFees() is material" keeper alert
-- (DEPLOY.md keeper runbook). Raw-log form.
--
-- Compounded(uint256,uint256,uint128,uint256,uint256)
--   topic0 = 0xf1795a888904052bce5fd755226af6a2e63a15a085f537378f14cbf0e0ec53d1
-- RebalanceSkipped(uint8)
--   topic0 = 0x9430cfc91a5880648dd0209cdd5e9a4d2504fd53d7e50760c105c05f9cbbc48f
-- param: {{compounder_address}}

SELECT
    block_time,
    tx_hash,
    'compound' AS kind,
    varbinary_to_uint256(varbinary_substring(data, 1, 32)) / 1e18 AS amount0_wstgbp,
    varbinary_to_uint256(varbinary_substring(data, 33, 32)) / 1e18 AS amount1_weth,
    varbinary_to_uint256(varbinary_substring(data, 65, 32)) AS liquidity_added,
    varbinary_to_uint256(varbinary_substring(data, 97, 32)) / 1e18 AS dust0_wstgbp,
    varbinary_to_uint256(varbinary_substring(data, 129, 32)) / 1e18 AS dust1_weth,
    NULL AS skip_reason
FROM ethereum.logs
WHERE contract_address = {{compounder_address}}
  AND topic0 = 0xf1795a888904052bce5fd755226af6a2e63a15a085f537378f14cbf0e0ec53d1

UNION ALL

SELECT
    block_time,
    tx_hash,
    'rebalance skipped' AS kind,
    NULL, NULL, NULL, NULL, NULL,
    varbinary_to_uint256(varbinary_substring(data, 1, 32)) AS skip_reason
FROM ethereum.logs
WHERE contract_address = {{compounder_address}}
  AND topic0 = 0x9430cfc91a5880648dd0209cdd5e9a4d2504fd53d7e50760c105c05f9cbbc48f

ORDER BY block_time DESC
