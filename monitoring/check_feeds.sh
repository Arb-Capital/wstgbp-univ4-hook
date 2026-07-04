#!/usr/bin/env bash
# Off-chain oracle-health probe for the WETH/wstGBP venue — watches the ROOT CAUSE the on-chain
# events can't (SwapFee/OracleFallback only emit on swaps; a quiet pool in fallback is invisible).
# Run from cron (e.g. */15). Exits nonzero + prints an alert line on any failure, so any cron
# mailer / wrapper (see ../../../wstgbp-arb-bot alert patterns) can page on it.
#
#   ETH_RPC_URL=<rpc> ./check_feeds.sh
set -euo pipefail

RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
ETH_USD=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
GBP_USD=0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5
WSTGBP=0x57C3571f10767E49C9d7b60feb6c67804783B7aE
# Same windows the hook enforces (FeeParams defaults): heartbeat + margin.
ETH_WINDOW=4500
GBP_WINDOW=90000

now=$(date -u +%s)
fail=0

check_feed() { # check_feed <name> <address> <window>
  local name=$1 addr=$2 window=$3 out answer updated age
  if ! out=$(cast call "$addr" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$RPC" 2>&1); then
    echo "ALERT: $name latestRoundData reverted: $out"
    fail=1
    return
  fi
  answer=$(echo "$out" | sed -n 2p | awk '{print $1}')
  updated=$(echo "$out" | sed -n 4p | awk '{print $1}')
  age=$((now - updated))
  if [ "${answer:-0}" -le 0 ] 2>/dev/null; then
    echo "ALERT: $name answer non-positive: $answer"
    fail=1
  fi
  # Mirror OracleLib exactly: a FUTURE updatedAt is stale too (the hook treats it as fallback).
  if [ "$age" -lt 0 ]; then
    echo "ALERT: $name updatedAt is ${age#-}s in the future (hook treats this as stale)"
    fail=1
  elif [ "$age" -gt "$window" ]; then
    echo "ALERT: $name stale: updated ${age}s ago (window ${window}s)"
    fail=1
  fi
  echo "ok: $name answer=$answer age=${age}s"
}

check_feed "ETH/USD" "$ETH_USD" "$ETH_WINDOW"
check_feed "GBP/USD" "$GBP_USD" "$GBP_WINDOW"

# The wstGBP NAV leg has NO on-chain staleness signal — the only checks are zero (pip paused)
# and gross-range sanity. NAV divergence beyond that is a governance-relations matter.
nav=$(cast call "$WSTGBP" "navprice()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
if [ "${nav:-0}" = "0" ]; then
  echo "ALERT: wstGBP navprice() == 0 (pip paused) — venue is in fallback pricing"
  fail=1
else
  echo "ok: navprice=$nav"
fi

exit $fail
