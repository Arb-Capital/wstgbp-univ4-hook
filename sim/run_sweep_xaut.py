#!/usr/bin/env python3
"""Entry point: python3 sim/run_sweep_xaut.py [--config sim/config/sweep_xaut.json]
[--out sim/RESULTS_XAUT.md] [--basis-bps N]

--basis-bps overrides the config's ranking basis (bps; negative = XAUt premium over the
metal feed) — used by `make sim-sweep-xaut-basis0`, the full-grid ranking confirmation at
basis 0 (the live 2026-07-16 regime is a small premium, outside the original ranking
assumption of a 50bp discount)."""

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
    ap.add_argument("--basis-bps", type=float, default=None, help="override the config's ranking basis (bps)")
    args = ap.parse_args()

    default_out = here / "RESULTS_XAUT.md"
    if args.basis_bps is not None and pathlib.Path(args.out).resolve() == default_out.resolve():
        ap.error("--basis-bps is analysis-only and requires an explicit non-production --out path")

    with open(args.config) as f:
        cfg = json.load(f)

    regimes = cfg["regimes"]
    missing = [p for r in regimes for p in (r["xau_csv"], r["gbp_csv"]) if not pathlib.Path(p).exists()]
    if missing:
        print("missing data files:\n  " + "\n  ".join(sorted(set(missing))))
        print("see sim/data/README.md for acquisition (make sim-data-gold for the PAXG gold legs + make sim-data-cable for the GBP legs)")
        return 1

    basis = args.basis_bps if args.basis_bps is not None else cfg.get("basis_bps", 50.0)
    run_sweep(
        regimes,
        cfg.get("nav", {}),
        basis,
        args.out,
        git_rev(),
        analysis_only=args.basis_bps is not None,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
