"""Exercise the protected vendor policy with synthetic tool call records."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def classify(checker, root, name, tool_input):
    payload = {"cwd": str(root), "tool_name": name, "tool_input": tool_input}
    return subprocess.run(
        [sys.executable, "-I", str(checker), "--root", str(root)],
        input=json.dumps(payload), text=True, capture_output=True, timeout=8, check=False,
    ).returncode


def main():
    checker = Path.cwd() / "bin/fm-worker-pretool-check.py"
    with tempfile.TemporaryDirectory(prefix="fm-vendor-policy-") as scratch:
        commercial = Path(scratch) / "fixture"
        commercial.mkdir()
        subprocess.run(["git", "init", "--quiet", str(commercial)], check=True, timeout=8)
        subprocess.run(
            ["git", "-C", str(commercial), "config", "remote.origin.url",
             "https://github.com/bemsas/commercialeye.git"], check=True, timeout=8,
        )
        (commercial / "vendor/basisone").mkdir(parents=True)
        (commercial / "report").mkdir()
        protected = [
            classify(checker, commercial, "Write", {"path": "vendor/basisone/fixture.txt"}),
            classify(checker, commercial, "Edit", {"path": "vendor"}),
        ]
        read = classify(checker, commercial, "Read", {"path": "vendor/basisone/fixture.txt"})
        harmless_report = classify(checker, commercial, "Bash", {
            "command": "cat > report/notes.md <<'REPORT'\nThe reference vendor/basisone is read-only.\nREPORT\n",
        })
        return 0 if protected == [2, 2] and read == 0 and harmless_report == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
