#!/usr/bin/env bash
# Fetch the sweep's historical minute bars from Binance public data (data.binance.vision).
#
#   trend-2021: native ETHGBP 1m bars, 2021-02..2021-05 (ETH/GBP ~x3 — the spec's trend regime)
#   chop-2024:  ETHUSDT 1m bars, 2024-07..2024-10 (Binance delisted GBP pairs in 2023; the sim
#               divides by a constant GBPUSD from sweep.toml — documented approximation)
#
# Output CSVs land next to this script, matching sim/config/sweep.toml. Idempotent.
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
  # Binance kline CSV: open_time(ms),open,high,low,close,volume,... -> keep the first six columns.
  # LC_ALL=C + an explicit comma-delimited key: under a grouping locale, plain `sort -n` folds the
  # CSV comma into the number and scrambles the order.
  cat "$tmp"/$sym-1m-*.csv | LC_ALL=C sort -t, -k1,1n \
    | awk -F, 'BEGIN{OFS=","}{print $1,$2,$3,$4,$5,$6}' > "$out"
  rm -rf "$tmp"
  echo "wrote $out ($(wc -l < "$out") bars)"
}

fetch ETHGBP ethgbp_trend_2021.csv 2021-02 2021-03 2021-04 2021-05
fetch ETHUSDT ethusdt_chop_2024.csv 2024-07 2024-08 2024-09 2024-10
