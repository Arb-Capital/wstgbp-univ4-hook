-- XAUT/wstGBP hook: |deviation| histogram (5 bps buckets) over the trailing 30d, split by sign
-- and by whether the swap actually PAID a surcharge. Raw-log form;
-- decoded equivalent: <namespace>.XautWstGbpHook_evt_SwapFee.
--
-- VENUE NOTE — token–metal basis (the designed rest state, NOT drift): the XAU/USD feed prices
-- spot gold while the pool trades the token, so this pool RESTS at d ≈ −basis. The basis is
-- small and SIGN-UNSTABLE (~+50bp discount estimated 2026-07-11 ⇒ rest mass below_fair = true;
-- a ~11bp PREMIUM measured 2026-07-16 ⇒ rest mass in the low buckets with below_fair = false):
-- rest mass EITHER side is BY DESIGN. Investigate a REGIME SHIFT (the rest mass migrating
-- buckets or flipping sides ABRUPTLY), never the rest mass itself. The sign split exists
-- exactly to make that distinction visible.
--
-- SURCHARGE CLASSIFICATION IS DIRECTIONAL — |d| > threshold alone is NOT the surcharge condition.
-- The hook (FeeMath.surchargePpm) surcharges only deviation-CLOSING flow: d > 0 is closed by the
-- redeem side (XAUT in, mintSide = false), d < 0 by the mint side (wstGBP in, mintSide = true).
-- At a DISCOUNT rest state (d < 0) that means XAUT-in swaps pay base only while wstGBP-in swaps
-- pay base + surcharge; at a PREMIUM rest state (d > 0, the live 2026-07-16 regime) the sides
-- flip (the sweep winner's threshold, 1000 ppm, sits deliberately BELOW the basis magnitude —
-- DeployXautHook.simParams(); re-sync the constant below if the owner retunes).
--
-- mintSide is topic1 (indexed); deviationPpm is data word [1], SIGNED (two's complement) —
-- decode via varbinary_to_int256.
-- param: {{hook_address}} — the deployed XautWstGbpHook (0x68cF17471aA0Fe54578747C6C7e66795bC8020C0, deployed 2026-07-17)

WITH swaps AS (
    SELECT
        varbinary_to_uint256(topic1) = 1 AS mint_side,
        varbinary_to_int256(varbinary_substring(data, 33, 32)) AS deviation_ppm,
        varbinary_to_uint256(varbinary_substring(data, 65, 32)) = 1 AS fallback_mode
    FROM ethereum.logs
    WHERE contract_address = {{hook_address}}
      AND topic0 = 0x501d5d86a8d484bc563346b877c9f64e27cc283c053aed3dc499e4de6ab3173a
      AND block_time > now() - interval '30' day
)
SELECT
    (abs(deviation_ppm) / 500) * 5 AS abs_deviation_bucket_bps, -- 5-bps-wide buckets (500 ppm)
    deviation_ppm < 0 AS below_fair, -- rest state side = −basis sign (discount ⇒ true, premium ⇒ false)
    (deviation_ppm > 1000 AND NOT mint_side)
        OR (deviation_ppm < -1000 AND mint_side) AS surcharge_paying, -- mirrors FeeMath.surchargePpm
    count(*) AS swaps
FROM swaps
WHERE NOT fallback_mode -- deviation is 0-by-definition in fallback; keep the histogram honest
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
