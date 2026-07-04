#!/usr/bin/env python3
"""Entry point: python3 sim/run_sweep.py [--config sim/config/sweep.json] [--out sim/RESULTS.md]"""

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from wethsim.sweep import git_rev, run_sweep  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    here = pathlib.Path(__file__).parent
    ap.add_argument("--config", default=str(here / "config" / "sweep.json"))
    ap.add_argument("--out", default=str(here / "RESULTS.md"))
    args = ap.parse_args()

    with open(args.config) as f:
        cfg = json.load(f)

    regimes = cfg["regimes"]
    missing = [r["csv"] for r in regimes if not pathlib.Path(r["csv"]).exists()]
    if missing:
        print("missing data files:\n  " + "\n  ".join(missing))
        print("see sim/data/README.md for acquisition (sim/data/fetch_binance.sh)")
        return 1

    run_sweep(regimes, cfg.get("nav_apy", 0.04), args.out, git_rev())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
