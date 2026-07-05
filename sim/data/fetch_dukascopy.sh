#!/usr/bin/env bash
# Fetch GBP/USD 1-minute BID candles from Dukascopy's public datafeed for the USDC-venue
# cable sweep (sim/config/sweep_usdc.json). No key needed. Idempotent.
#
#   gilt-2022:  2022-08-01 .. 2022-11-30  (mini-budget stress; Sep-26 flash low ~1.035)
#   calm-2024:  2024-03-01 .. 2024-06-30  (cable pinned ~1.25-1.29; pure ratchet conveyor)
#   trend-2025: 2025-01-01 .. 2025-05-31  (sustained GBP uptrend; exercises the mint side)
#
# Dukascopy URL quirk: the month path segment is 0-INDEXED (00 = January). Weekends and
# holidays 404 or return empty files — both tolerated (forex closes Fri 22:00 -> Sun 22:00
# UTC; the sim loader forward-fills those gaps, max_gap_min 4320 in the regime config).
# Decoding (LZMA .bi5 -> CSV) is stdlib python: sim/data/dukascopy_bi5.py.
set -euo pipefail
cd "$(dirname "$0")"

fetch() { # fetch <OUT.csv> <START YYYY-MM-DD> <END YYYY-MM-DD (inclusive)>
  local out=$1 start=$2 end=$3 tmp d y m m0 dd
  [ -s "$out" ] && { echo "$out exists, skipping"; return; }
  tmp=$(mktemp -d)
  d=$start
  while [[ "$d" < "$end" || "$d" == "$end" ]]; do
    y=${d:0:4} m=${d:5:2} dd=${d:8:2}
    m0=$(printf "%02d" $((10#$m - 1))) # 0-indexed month in the URL
    curl -fsS "https://datafeed.dukascopy.com/datafeed/GBPUSD/$y/$m0/$dd/BID_candles_min_1.bi5" \
      -o "$tmp/$d.bi5" 2>/dev/null || true # 404 on market-closed days
    d=$(date -u -d "$d + 1 day" +%F)
  done
  python3 dukascopy_bi5.py "$tmp" "$out"
  rm -rf "$tmp"
}

fetch gbpusd_gilt_2022.csv 2022-08-01 2022-11-30
fetch gbpusd_calm_2024.csv 2024-03-01 2024-06-30
fetch gbpusd_trend_2025.csv 2025-01-01 2025-05-31
