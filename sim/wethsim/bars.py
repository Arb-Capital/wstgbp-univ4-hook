"""Minute-bar loading and the fair-price series.

CSV schema (sim/data/README.md): timestamp,open,high,low,close,volume — UTC epoch
seconds, 1m bars, close used as the reference ETH/GBP price. Gaps <= max_gap_min are
forward-filled; longer gaps raise.

fair(t) = ethgbp(t) / nav(t), nav drifting deterministically at `nav_apy` from 1.0
(the wstGBP rate leg; its intramonth variation is negligible vs ETH's but the drift
matters for mint/redeem cycle economics).
"""

from dataclasses import dataclass
import csv
import pathlib

SECONDS_PER_YEAR = 365 * 24 * 3600


@dataclass
class BarSeries:
    timestamps: list[int]
    ethgbp: list[float]

    def __len__(self) -> int:
        return len(self.timestamps)


def load_csv(path: str | pathlib.Path, max_gap_min: int = 360) -> BarSeries:
    ts: list[int] = []
    px: list[float] = []
    with open(path, newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        if header and header[0].lstrip().isdigit():  # headerless file: first row is data
            _ingest(ts, px, header)
        for row in reader:
            _ingest(ts, px, row)
    if not ts:
        raise ValueError(f"{path}: empty")
    # normalize to strict 60s grid with bounded forward-fill
    out_t, out_p = [ts[0]], [px[0]]
    for t, p in zip(ts[1:], px[1:]):
        gap = t - out_t[-1]
        if gap <= 0:
            continue
        if gap > max_gap_min * 60:
            raise ValueError(f"{t}: gap of {gap}s exceeds {max_gap_min}min")
        while out_t[-1] + 60 < t:  # forward-fill missing minutes
            out_t.append(out_t[-1] + 60)
            out_p.append(out_p[-1])
        out_t.append(t)
        out_p.append(p)
    return BarSeries(out_t, out_p)


def _ingest(ts: list[int], px: list[float], row: list[str]) -> None:
    if not row or not row[0].strip():
        return
    t = int(float(row[0]))
    if t > 10**12:  # milliseconds -> seconds (Binance klines use ms)
        t //= 1000
    ts.append(t)
    px.append(float(row[4]))  # close


class FairSeries:
    def __init__(self, bars: BarSeries, nav_apy: float = 0.04, gbpusd: float | None = None):
        """`gbpusd`: if the ETH leg is USD-denominated (ETHUSDT), divide by this constant
        (or supply pre-composed ETH/GBP bars and leave it None)."""
        self.bars = bars
        self.nav_apy = nav_apy
        self.gbpusd = gbpusd
        self.t0 = bars.timestamps[0]

    def nav(self, i: int) -> float:
        dt = self.bars.timestamps[i] - self.t0
        return (1 + self.nav_apy) ** (dt / SECONDS_PER_YEAR)

    def fair(self, i: int) -> float:
        ethgbp = self.bars.ethgbp[i]
        if self.gbpusd is not None:
            ethgbp = ethgbp / self.gbpusd
        return ethgbp / self.nav(i)
