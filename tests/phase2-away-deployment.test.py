"""Classify exact branch names using only a synthetic deployment map."""
import os
from pathlib import Path
import subprocess
import tempfile


with tempfile.TemporaryDirectory(prefix="away-map-fixture-") as temp:
    Path(temp, "projects.md").write_text(
        "- fixture [no-mistakes-prod-only prod=main] - fixture (added 2026-01-01)\n",
        encoding="utf-8",
    )
    tool = Path.cwd() / "bin/fm-project-mode.sh"
    for branch, expected in (("main", "production"), ("dev", "non-production")):
        observed = subprocess.run(
            ["bash", str(tool), "--production", "fixture", branch],
            capture_output=True, text=True, check=False,
            env=dict(os.environ, FM_DATA_OVERRIDE=temp),
        )
        if observed.returncode != 0:
            raise SystemExit(2)
        if observed.stdout.strip() != expected:
            raise SystemExit(10)
