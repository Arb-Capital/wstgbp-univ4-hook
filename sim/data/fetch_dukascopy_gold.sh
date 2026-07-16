#!/usr/bin/env bash
# Fetch XAU/USD (spot gold) 1-minute BID candles from Dukascopy's public datafeed for the
# XAUT-venue gold sweep (sim/config/sweep_xaut.json), plus the one GBP/USD window the cable
# fetcher doesn't cover. No key needed. Idempotent AND resumable: day files persist in
# sim/data/.dukascopy-cache/<window>/ (gitignored), so an interrupted or throttled run
# picks up where it left off — Dukascopy tarpits bulk fetchers after a request quota
# (~25 B/s shaping observed after ~70 requests), so this script times out slow requests,
# backs off, and only decodes a window once every day is accounted for.
#
#   shock-2022: 2022-08-01 .. 2022-11-30  (gilt crisis x gold drawdown to ~$1,615 — both
#               fair legs stressed at once; GBP leg reuses gbpusd_gilt_2022.csv)
#   range-2023: 2023-05-01 .. 2023-09-30  (gold pinned ~$1,900-1,980; isolates the ratchet
#               conveyor + token-metal basis rest state; GBP leg fetched below)
#   rally-2025: 2025-01-01 .. 2025-05-31  (gold up ~30%; fair rises, d<0 — exercises the
#               mint side against the basis rest state; GBP leg reuses gbpusd_trend_2025.csv)
#
# Dukascopy URL quirk: the month path segment is 0-INDEXED (00 = January). Weekends and
# holidays 404 (recorded as .404 markers so they are not refetched; the sim loader
# forward-fills the gaps, max_gap_min 4320). Decoding is sim/data/dukascopy_bi5.py; XAUUSD
# prices come in 1e-3 integer points (vs GBPUSD's 1e-5) with a (1000, 20000) sanity
# corridor — a wrong point scale fails the corridor on the first decoded day.
set -euo pipefail
cd "$(dirname "$0")"

INCOMPLETE=0
CONSEC_SLOW=0

fetch() { # fetch <INSTRUMENT> <OUT.csv> <START> <END inclusive> [point px_lo px_hi]
  local inst=$1 out=$2 start=$3 end=$4 cache d y m m0 dd missing
  shift 4
  [ -s "$out" ] && { echo "$out exists, skipping"; return; }
  cache=".dukascopy-cache/${out%.csv}"
  mkdir -p "$cache"
  d=$start
  missing=0
  while [[ "$d" < "$end" || "$d" == "$end" ]]; do
    if [ ! -e "$cache/$d.bi5" ] && [ ! -e "$cache/$d.404" ]; then
      y=${d:0:4} m=${d:5:2} dd=${d:8:2}
      m0=$(printf "%02d" $((10#$m - 1))) # 0-indexed month in the URL
      local t0 rc
      t0=$SECONDS
      rc=0
      curl -fsS --max-time 25 \
        "https://datafeed.dukascopy.com/datafeed/$inst/$y/$m0/$dd/BID_candles_min_1.bi5" \
        -o "$cache/$d.bi5.part" 2>/dev/null || rc=$?
      if [ "$rc" -eq 0 ]; then
        mv "$cache/$d.bi5.part" "$cache/$d.bi5"
      elif [ "$rc" -eq 22 ]; then
        touch "$cache/$d.404" # market-closed day: don't refetch
        rm -f "$cache/$d.bi5.part"
      else
        rm -f "$cache/$d.bi5.part" # timeout/network: retry on the next run
        missing=$((missing + 1))
      fi
      # Tarpit detection: three consecutive slow/failed requests => quota exhausted;
      # cool off LONG before continuing (empirically the quota does not decay while it
      # keeps being poked — 5-min cooloffs made zero progress for hours on 2026-07-16).
      if [ $((SECONDS - t0)) -ge 15 ]; then
        CONSEC_SLOW=$((CONSEC_SLOW + 1))
        if [ "$CONSEC_SLOW" -ge 3 ]; then
          echo "  throttled by dukascopy — cooling off 45 min ($out at $d)"
          sleep 2700
          CONSEC_SLOW=0
        fi
      else
        CONSEC_SLOW=0
      fi
      sleep 0.4 # gentle pacing — stay under the request quota
    fi
    d=$(date -u -d "$d + 1 day" +%F)
  done
  if [ "$missing" -gt 0 ]; then
    echo "$out: $missing day(s) still missing — rerun to resume (window NOT decoded)"
    INCOMPLETE=1
    return
  fi
  python3 dukascopy_bi5.py "$cache" "$out" "$@"
}

fetch XAUUSD xauusd_shock_2022.csv 2022-08-01 2022-11-30 1e-3 1000 20000
fetch XAUUSD xauusd_range_2023.csv 2023-05-01 2023-09-30 1e-3 1000 20000
fetch XAUUSD xauusd_rally_2025.csv 2025-01-01 2025-05-31 1e-3 1000 20000
# GBP leg for range-2023 (default GBPUSD decode params; other GBP legs come from
# fetch_dukascopy.sh's cable windows).
fetch GBPUSD gbpusd_range_2023.csv 2023-05-01 2023-09-30

exit $INCOMPLETE
