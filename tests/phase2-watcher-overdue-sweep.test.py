"""Prove a due local check survives a pending recovery wake in an empty home."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


root = Path.cwd()
with tempfile.TemporaryDirectory(prefix="fm-periodic-check-") as path:
    home = Path(path)
    state = home / "state"
    for directory in (state, home / "config", home / "data"):
        directory.mkdir()
    environ = {
        "PATH": os.environ["PATH"], "HOME": str(home), "FM_HOME": str(home),
        "FM_POLL": "1", "FM_SIGNAL_GRACE": "0", "FM_CHECK_INTERVAL": "1", "FM_HEARTBEAT": "999999",
    }
    ran = state / "periodic-check-ran"
    script = state / "fixture.check.sh"
    script.write_text(f"#!/bin/sh\nprintf 'checked\\n' > {shlex.quote(str(ran))}\n")
    script.chmod(0o700)
    register = subprocess.run([str(root / "bin/fm-check-register.sh"), "fixture"], env=environ, capture_output=True, check=False, timeout=10)
    if register.returncode:
        raise SystemExit(1)
    marker = state / ".watcher-down"
    marker.write_text("pending:downtime:fixture.1.aaa\n")
    marker.chmod(0o600)
    (state / ".wake-queue").write_text(f"{int(time.time())}\t1\tcheck\tfixture\tcheck: durable fixture recovery\n")
    result = subprocess.run([str(root / "bin/fm-watch-checkpoint.sh"), "--seconds", "12"], env=environ, capture_output=True, text=True, check=False, timeout=20)
    if ran.is_file() and ran.read_text() == "checked\n" and result.returncode == 0:
        raise SystemExit(0)
    if result.returncode == 0 and "rearm-resurface" in result.stdout and not ran.exists():
        raise SystemExit(10)
    raise SystemExit(1)
