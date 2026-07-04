# Historical data for the fee-parameter sweep

CSV schema (headerless or headered): `timestamp,open,high,low,close,volume` — UTC epoch
seconds **or** milliseconds (auto-detected), 1-minute bars, `close` is the reference price.
The loader forward-fills gaps up to 6 hours (the 2021 ETHGBP pair has multi-hour holes) and errors on longer ones.

## Acquisition

`./fetch_binance.sh` downloads both regime files from Binance public data (no key needed):

| file | source | window | note |
|---|---|---|---|
| `ethgbp_trend_2021.csv` | Binance ETHGBP 1m | 2021-02 → 2021-05 | native ETH/GBP; the spec's "2021-style trend" (~×3) |
| `ethusdt_chop_2024.csv` | Binance ETHUSDT 1m | 2024-07 → 2024-10 | ETH ranged ~$2.3–2.8k; divided by constant GBPUSD (sweep.json) since Binance delisted GBP pairs in 2023 |

The constant-GBPUSD approximation for the chop regime is deliberate: GBP/USD annualized
vol is an order of magnitude below ETH's and does not move the *relative* ranking of fee
parameters. To tighten it, supply your own composed ETH/GBP csv (e.g. ETHUSDT ÷ a real
GBP/USD minute series, or a Kraken ETHGBP OHLCVT export) at the same path and remove the
`gbpusd` key from `sim/config/sweep.json`.

CSV files in this directory are gitignored (a few MB each, reproducible via the script);
`RESULTS.md` records each input's sha256 so runs are attributable.
