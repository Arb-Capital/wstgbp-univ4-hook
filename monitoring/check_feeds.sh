#!/usr/bin/env bash
# Off-chain oracle-health probe for the WETH/wstGBP, wstGBP/USDC AND XAUT/wstGBP venues —
# watches the ROOT CAUSE the on-chain events can't (SwapFee/OracleFallback only emit on swaps; a
# quiet pool in fallback is invisible). One script serves all three venues: GBP/USD + navprice
# are shared inputs; ETH/USD is weth-only; XAU/USD is xaut-only; USDC/USD is an ADVISORY depeg
# probe for the usdc venue (which reads no USDC feed on-chain — a depeg is invisible to that
# hook by design, SECURITY_USDC_WSTGBP.md §6; the runbook on alert is the owner pause).
# Run from cron (e.g. */15). Exits nonzero + prints an alert line on any failure, so any cron
# mailer / wrapper (see ../../../wstgbp-arb-bot alert patterns) can page on it.
#
#   ETH_RPC_URL=<rpc> ./check_feeds.sh
set -euo pipefail

RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
ETH_USD=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419   # weth venue only
GBP_USD=0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5   # both venues
USDC_USD=0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6  # usdc venue, advisory (off-chain only)
XAU_USD=0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6   # xaut venue only
WSTGBP=0x57C3571f10767E49C9d7b60feb6c67804783B7aE
# Same windows the hooks enforce (FeeParams defaults): heartbeat + margin.
ETH_WINDOW=4500
GBP_WINDOW=90000
USDC_WINDOW=90000
XAU_WINDOW=90000
# Depeg alarm threshold: |USDC/USD - $1| > 50 bps (8-dec feed: outside [0.995e8, 1.005e8]).
USDC_DEPEG_LO=99500000
USDC_DEPEG_HI=100500000

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
check_feed "USDC/USD" "$USDC_USD" "$USDC_WINDOW"
# Gold closes weekends/holidays (+ a 22:00-23:00 UTC daily break): Chainlink usually heartbeats a
# frozen price through the close, but if it pauses instead, an XAU/USD staleness alert here is
# EXPECTED (the xaut hook prices at fallbackFee by design) — cross-check against market hours
# before reacting.
check_feed "XAU/USD" "$XAU_USD" "$XAU_WINDOW"

# USDC depeg (usdc venue): the hook assumes USDC = $1.00 and cannot see a depeg on-chain.
# On alert: owner pause runbook (SECURITY_USDC_WSTGBP.md §6) — flat fallbackFee, swaps never blocked.
# Guarded like check_feed (set -e must not silently abort the alert contract on an RPC hiccup),
# and non-integer/garbage answers ALERT rather than being swallowed.
if ! usdc_answer=$(cast call "$USDC_USD" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$RPC" 2>&1 | sed -n 2p | awk '{print $1}'); then
  echo "ALERT: USDC/USD depeg probe call failed — peg state UNKNOWN; check manually"
  fail=1
elif ! [[ "${usdc_answer:-}" =~ ^[0-9]+$ ]]; then
  echo "ALERT: USDC/USD depeg probe returned garbage ('$usdc_answer') — peg state UNKNOWN; check manually"
  fail=1
elif [ "$usdc_answer" -lt "$USDC_DEPEG_LO" ] || [ "$usdc_answer" -gt "$USDC_DEPEG_HI" ]; then
  echo "ALERT: USDC/USD depeg: answer=$usdc_answer (>50bps from \$1) — usdc-venue hook cannot see this; consider setPaused(true)"
  fail=1
else
  echo "ok: USDC/USD peg answer=$usdc_answer"
fi

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
