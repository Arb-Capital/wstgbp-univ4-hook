#!/usr/bin/env python3
"""Entry point: python3 sim/run_sweep_xaut.py [--config sim/config/sweep_xaut.json]
[--out sim/RESULTS_XAUT.md]"""

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from goldsim.sweep import git_rev, run_sweep  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    here = pathlib.Path(__file__).parent
    ap.add_argument("--config", default=str(here / "config" / "sweep_xaut.json"))
    ap.add_argument("--out", default=str(here / "RESULTS_XAUT.md"))
    args = ap.parse_args()

    with open(args.config) as f:
        cfg = json.load(f)

    regimes = cfg["regimes"]
    missing = [p for r in regimes for p in (r["xau_csv"], r["gbp_csv"]) if not pathlib.Path(p).exists()]
    if missing:
        print("missing data files:\n  " + "\n  ".join(sorted(set(missing))))
        print("see sim/data/README.md for acquisition (make sim-data-gold for the PAXG gold legs + make sim-data-cable for the GBP legs)")
        return 1

    run_sweep(regimes, cfg.get("nav", {}), cfg.get("basis_bps", 50.0), args.out, git_rev())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
