-- tGBP/wstGBP BACKSTOP pool: daily volume, direction split, and implied execution price.
--
-- IMPORTANT: the backstop is a return-delta custom-curve hook — it cancels the AMM leg, so the
-- PoolManager's Swap event logs ZERO amounts (verified on-chain). Real value moves as ERC-20
-- transfers between the PoolManager and the hook: `take` = PM -> hook (swap input),
-- `settle` = hook -> PM (swap output). This query reconstructs volume from those legs.
--
-- Direction from the input leg: tGBP into the hook = BUY wstGBP; wstGBP into the hook = SELL.
-- Implied price (tGBP per wstGBP) = tgbp_volume / wstgbp_volume per direction — this IS the
-- wrapper's mintcost (buys) / burncost (sells) at trade time; the buy-sell gap is the ~25 bps
-- protocol spread.
-- params: {{pool_manager}}, {{hook}}, {{tgbp}}, {{wstgbp}}

WITH legs AS (
    SELECT
        date_trunc('day', evt_block_time) AS day,
        contract_address AS token,
        IF("from" = {{pool_manager}}, 'in', 'out') AS leg, -- PM->hook = input (take), hook->PM = output (settle)
        value
    FROM erc20_ethereum.evt_transfer
    WHERE (("from" = {{pool_manager}} AND "to" = {{hook}}) OR ("from" = {{hook}} AND "to" = {{pool_manager}}))
      AND contract_address IN ({{tgbp}}, {{wstgbp}})
      AND evt_block_time >= TIMESTAMP '2026-06-28' -- backstop deploy date
)
SELECT
    day,
    IF((token = {{tgbp}}) = (leg = 'in'), 'buy wstGBP (tGBP in)', 'sell wstGBP (tGBP out)') AS direction,
    count(*) FILTER (WHERE leg = 'in') AS swaps, -- one take per swap
    sum(value) FILTER (WHERE token = {{tgbp}}) / 1e18 AS tgbp_volume,
    sum(value) FILTER (WHERE token = {{wstgbp}}) / 1e18 AS wstgbp_volume,
    (sum(value) FILTER (WHERE token = {{tgbp}})) * 1.0
        / nullif(sum(value) FILTER (WHERE token = {{wstgbp}}), 0) AS implied_px_tgbp_per_wstgbp
FROM legs
GROUP BY 1, 2
ORDER BY 1 DESC, 2
