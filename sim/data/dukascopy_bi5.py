#!/usr/bin/env python3
"""Decode Dukascopy .bi5 1-minute candle files into the sim's CSV schema.

Usage: python3 dukascopy_bi5.py <dir-of-bi5-files> <out.csv>

Input files must be named YYYY-MM-DD.bi5 (the fetch script does this) and contain
LZMA-compressed rows of the Dukascopy minute-candle format: big-endian
(int32 seconds-from-day-start, int32 open, int32 close, int32 low, int32 high,
float32 volume), prices in 1e-5 points for GBPUSD.

Output schema matches sim/data/README.md: timestamp,open,high,low,close,volume —
UTC epoch seconds, close is the reference price. Stdlib only (lzma + struct).
"""

import lzma
import pathlib
import struct
import sys
from datetime import datetime, timezone

POINT = 1e-5  # GBPUSD price scale
ROW = struct.Struct(">iiiiif")  # sec_offset, open, close, low, high, volume
# Sanity corridor: cable has never left (0.9, 2.2) in the covered eras; a struct/scale
# bug lands orders of magnitude outside instantly.
PX_LO, PX_HI = 0.9, 2.2


def decode_day(path: pathlib.Path) -> list[tuple[int, float, float, float, float, float]]:
    raw = path.read_bytes()
    if not raw:  # weekends/holidays produce empty files
        return []
    data = lzma.decompress(raw)
    if len(data) % ROW.size != 0:
        raise ValueError(f"{path}: {len(data)} bytes is not a multiple of {ROW.size}")
    day = datetime.strptime(path.stem, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    day_epoch = int(day.timestamp())
    rows = []
    for off in range(0, len(data), ROW.size):
        sec, o, c, lo, hi, vol = ROW.unpack_from(data, off)
        o, c, lo, hi = (x * POINT for x in (o, c, lo, hi))
        for px in (o, c, lo, hi):
            if not (PX_LO < px < PX_HI):
                raise ValueError(f"{path}@{sec}: price {px} outside sanity corridor")
        rows.append((day_epoch + sec, o, hi, lo, c, vol))
    return rows


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])
    rows: list[tuple[int, float, float, float, float, float]] = []
    files = sorted(src.glob("*.bi5"))
    if not files:
        print(f"no .bi5 files in {src}")
        return 1
    empty = 0
    for f in files:
        day_rows = decode_day(f)
        if not day_rows:
            empty += 1
        rows.extend(day_rows)
    rows.sort(key=lambda r: r[0])
    with open(out, "w") as fh:
        for r in rows:
            fh.write(f"{r[0]},{r[1]:.5f},{r[2]:.5f},{r[3]:.5f},{r[4]:.5f},{r[5]:.2f}\n")
    print(f"wrote {out} ({len(rows)} bars from {len(files)} files; {empty} empty days)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
