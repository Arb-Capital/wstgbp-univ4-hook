# goldsim: XAUT/wstGBP (gold/sterling) venue replay sim — imports wethsim's venue-neutral
# core (feemath, pool) and cablesim's NavStepModel/OracleSeries, and owns everything
# gold-specific (two-feed fair, token-metal basis, explicit two-leg USD numeraire).
# sim/wethsim/ is FROZEN (it backs the deployed WETH venue's RESULTS.md); no edits there,
# and no edits to cablesim (it backs the deployed USDC venue's RESULTS_USDC.md).
