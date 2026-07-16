#!/usr/bin/env bash
# FALLBACK gold-leg data for the XAUT-venue sweep, from Binance public data
# (data.binance.vision, monthly 1m kline zips — no key, no throttle).
#
# Why a fallback exists: Dukascopy (the primary XAU/USD source, fetch_dukascopy_gold.sh)
# tarpits bulk fetchers per-IP after a request quota; its day-file cache resumes across
# runs, but a full first fetch can take many hours. This script substitutes:
#
#   PAXG/USDT  -> the gold leg. PAXG is tokenized gold: tracks spot within ~±20-50bps
#                 with its own basis wobble (2022 minute liquidity is thin — some
#                 bid/ask bounce becomes fake vol). Acceptable for RELATIVE fee-parameter
#                 ranking; RESULTS_XAUT.md stamps the csv sha256s so runs are
#                 attributable. Re-run the sweep on true XAU/USD when the Dukascopy
#                 fetch completes, as confirmation.
#   GBP/USDT   -> the range-2023 cable leg (Binance delisted GBP pairs late 2023, but
#                 the archive covers 2023-05..09; if the last month is partial the
#                 goldsim compose() just trims the regime window to the overlap).
#
# Bonus fidelity note: PAXG trades 24/7, which matches the observed weekend behavior of
# the Chainlink XAU/USD feed (it heartbeats THROUGH the weekend close with small answer
# drift — verified on-chain 2026-07-16), whereas Dukascopy spot-gold bars freeze over
# the FX close. USDT ≈ USD is assumed (same class as cablesim's documented
# approximations). Output CSVs land next to this script, matching sim/config/
# sweep_xaut.json. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

fetch() { # fetch <SYMBOL> <OUT.csv> <month...>
  local sym=$1 out=$2 tmp
  shift 2
  [ -s "$out" ] && { echo "$out exists, skipping"; return; }
  tmp=$(mktemp -d)
  for m in "$@"; do
    echo "fetching $sym $m"
    curl -fsS "https://data.binance.vision/data/spot/monthly/klines/$sym/1m/$sym-1m-$m.zip" \
      -o "$tmp/$m.zip"
    unzip -qo "$tmp/$m.zip" -d "$tmp"
  done
  # Binance kline CSV: open_time,open,high,low,close,volume,... -> keep the first six columns.
  # TIMESTAMP UNIT TRAP: monthly zips switched open_time from MILLISECONDS to MICROSECONDS
  # starting 2025-01. The sim loader auto-detects s vs ms only — fed raw microseconds it
  # sees 60,000s "gaps" between bars, forward-fills 999 synthetic bars per real one, and a
  # single regime balloons to ~10 GB (found the hard way 2026-07-16). Normalize to ms
  # BEFORE the sort so a window straddling the format change still orders chronologically.
  # LC_ALL=C + an explicit comma-delimited key: under a grouping locale, plain `sort -n` folds the
  # CSV comma into the number and scrambles the order.
  cat "$tmp"/$sym-1m-*.csv \
    | awk -F, 'BEGIN{OFS=","}{if ($1+0 >= 1e15) $1 = sprintf("%.0f", $1/1000); print}' \
    | LC_ALL=C sort -t, -k1,1n \
    | awk -F, 'BEGIN{OFS=","}{print $1,$2,$3,$4,$5,$6}' > "$out"
  rm -rf "$tmp"
  echo "wrote $out ($(wc -l < "$out") bars)"
}

fetch PAXGUSDT paxgusd_shock_2022.csv 2022-08 2022-09 2022-10 2022-11
fetch PAXGUSDT paxgusd_calm_2024.csv 2024-03 2024-04 2024-05 2024-06
fetch PAXGUSDT paxgusd_rally_2025.csv 2025-01 2025-02 2025-03 2025-04 2025-05
