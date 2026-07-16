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

## Cable (wstGBP/USDC venue) data — Dukascopy

`./fetch_dukascopy.sh` downloads the three cable regime files (GBP/USD 1-minute BID
candles, decoded from `.bi5` LZMA by the stdlib `dukascopy_bi5.py`; no key needed —
Binance cannot supply cable, it delisted GBP pairs in 2023):

| file | window | note |
|---|---|---|
| `gbpusd_gilt_2022.csv` | 2022-08-01 → 2022-11-30 | mini-budget stress; Sep-26 flash low ~1.035 |
| `gbpusd_calm_2024.csv` | 2024-03-01 → 2024-06-30 | cable pinned ~1.25–1.29 (pure ratchet conveyor) |
| `gbpusd_trend_2025.csv` | 2025-01-01 → 2025-05-31 | sustained GBP uptrend ~1.21 → 1.36 (mint side) |

Forex closes Fri ~22:00 → Sun ~22:00 UTC: the regimes pass `max_gap_min: 4320` (72h) so
the loader forward-fills weekends flat — exactly what the frozen on-chain Chainlink feed
reports over a weekend. Manual fallback if Dukascopy is unavailable: HistData.com's free
GBP/USD M1 exports, converted to the same schema at the same paths.

## Gold (XAUT/wstGBP venue) data

**Active source — Binance PAXG/USDT** (`./fetch_binance_gold.sh` = `make sim-data-gold`,
monthly kline zips, no key, no throttle). The sweep config (`sim/config/sweep_xaut.json`)
points at these (GBP legs come from `make sim-data-cable`):

| file | window | note |
|---|---|---|
| `paxgusd_shock_2022.csv` | 2022-08 → 2022-11 | gilt crisis × gold drawdown to ~$1,615; both fair legs stressed (GBP leg: `gbpusd_gilt_2022.csv`) |
| `paxgusd_calm_2024.csv` | 2024-03 → 2024-06 | calm cable × gold +17% then consolidation; the sensitivity anchor. **Contains the real 2024-04-13 weekend squeeze** (PAXG +25% in ~90 min while metal markets were closed — kept deliberately: it IS the venue's weekend-dislocation risk) (GBP leg: `gbpusd_calm_2024.csv`) |
| `paxgusd_rally_2025.csv` | 2025-01 → 2025-05 | gold up ~30%; fair rises (d<0), exercises the mint side (GBP leg: `gbpusd_trend_2025.csv`) |

PAXG is tokenized gold: it tracks spot within ~20–50bps (on-chain redemption arb — held
through 2022–2025), trades 24/7 (matching the Chainlink XAU/USD feed's observed weekend
behavior: ~24h heartbeats with small drift straight through the close, verified on-chain
2026-07-16), and assumes USDT ≈ USD (same class as the chop-2024 constant-GBPUSD
approximation above). **Timestamp-unit trap:** Binance monthly kline zips switched
`open_time` from milliseconds to **microseconds** starting 2025-01; the fetch script
normalizes to ms (the loader auto-detects s/ms only — raw µs make it forward-fill ~1000
synthetic bars per real one and a single regime balloons to ~10 GB). **Checked and rejected**: Binance GBPUSDT for the cable leg — it
depegged ~5% below true cable after Binance's GBP banking rails closed mid-2023 (no fiat
arb), which is why calm-2024 replaced a 2023 window: its cable leg reuses the clean
Dukascopy `gbpusd_calm_2024.csv`.

**Confirmation source — Dukascopy XAU/USD** (`./fetch_dukascopy_gold.sh` =
`make sim-data-gold-xau`):
spot-gold 1m BID candles for windows shock-2022 / range-2023 / rally-2025. Dukascopy
tarpits bulk fetchers per-IP (~25 B/s after a request quota), so the script is resumable —
day files persist in `.dukascopy-cache/` (gitignored) across runs, 404s are marked, slow
requests time out and back off, and a window only decodes once every day is accounted
for. Re-run the sweep against true XAU/USD when the cache completes, as confirmation.
Point-scale trap: XAUUSD candles come in **1e-3** integer points (GBPUSD is 1e-5);
`dukascopy_bi5.py` takes optional `point px_lo px_hi` args — the gold script passes
`1e-3 1000 20000`, and the sanity corridor fails on the first decoded day if the scale
is ever wrong. Dukascopy gold observes the FX weekend close (plus a daily 22:00–23:00
UTC break); the same `max_gap_min: 4320` forward-fill applies.
