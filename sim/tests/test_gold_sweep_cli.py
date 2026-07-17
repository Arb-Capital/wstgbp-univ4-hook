"""CLI/report-role safety for alternate-basis XAUT sweep runs."""

import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from goldsim.runner import RunConfig  # noqa: E402
from goldsim.sweep import render  # noqa: E402
from run_sweep_xaut import main  # noqa: E402


def _render(out: pathlib.Path, *, analysis_only: bool) -> str:
    render(
        regimes=[],
        nav_cfg={},
        basis_bps=0.0,
        cells={},
        winner="analysis-winner",
        win_cfg=RunConfig(kind="dynamic"),
        gas_rows=[],
        basis_rows=[],
        out_path=str(out),
        git_rev="test",
        analysis_only=analysis_only,
    )
    return out.read_text()


def test_report_role_is_explicit_not_inferred_from_filename(tmp_path):
    analysis = _render(tmp_path / "custom.md", analysis_only=True)
    production = _render(tmp_path / "RESULTS_XAUT_BASIS0.md", analysis_only=False)
    assert "analysis only" in analysis.lower()
    assert "Recommended starting FeeParams" not in analysis
    assert "Recommended starting FeeParams" in production
    assert "analysis only" not in production.lower()


def test_basis_override_cannot_overwrite_canonical_report(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["run_sweep_xaut.py", "--basis-bps", "0"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2
    assert "requires an explicit non-production --out path" in capsys.readouterr().err
