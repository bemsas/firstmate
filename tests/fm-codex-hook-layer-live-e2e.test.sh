#!/usr/bin/env bash
# Installed Codex hook discovery and enforcement, with a loopback Responses
# fixture, no credentials or provider tokens. Runs by default when installed.
# The fake Git executable makes a failing guard harmless to any real worktree.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex python3
CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$TMP_ROOT" "$CODEX_VERSION" <<'PY'
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import tomllib

root, tmp = map(Path, sys.argv[1:3])
version = sys.argv[3]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("worker", root / "bin/fm-codex-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
wt, state, original = tmp / "work tree", tmp / "state", tmp / "original"
(wt / "vendor/basisone").mkdir(parents=True)
state.mkdir()
original.mkdir()
# A FIFO rather than a credential file: any accidental auth read would hang.
# The real Codex uses the local provider and requires no authentication.
os.mkfifo(original / "auth.json")
(original / "AGENTS.md").write_text("Use only this test fixture.\n")
(original / "rules").mkdir()
(original / "rules/test.rules").write_text('prefix_rule(pattern=["fake"], decision="forbidden")\n')
(original / "hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [
    {"type": "command", "command": "touch unrelated-hook-ran"}]}]}}))
(wt / ".codex").mkdir()
(wt / ".codex/hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [
    {"type": "command", "command": "touch project-hook-ran"}]}]}}))
(original / "config.toml").write_text('approval_policy="never"\nsandbox_mode="danger-full-access"\n'
    + '[projects.' + json.dumps(str(wt)) + ']\ntrust_level="trusted"\n')
env = dict(os.environ, CODEX_HOME=str(original))
subprocess.run([sys.executable, str(root / "bin/fm-codex-worker.py"), "prepare", str(wt), str(state), "t"],
               env=env, check=True, timeout=10)
home = state / "t.codex-home"
assert (home / "auth.json").is_symlink()
assert os.readlink(home / "auth.json") == str(original / "auth.json")
assert (home / "rules").is_symlink()
assert (home / "AGENTS.md").is_symlink()
# Setup was proven not to read the FIFO. The vendor itself may read login
# state even for a local provider, so replace only this fixture's FIFO now.
(original / "auth.json").unlink()
(original / "auth.json").write_text("{}\n")
assert not (wt / "unrelated-hook-ran").exists()
fakegit = wt / "fake/git"
fakegit.parent.mkdir()
fakegit.write_text('#!/bin/sh\nprintf reached > "' + str(wt / 'git-ran') + '"\n')
fakegit.chmod(0o700)

# The fixture chooses tool calls rather than relying on a model to obey a
# negative test prompt. Every call still traverses the real Codex hook engine.
calls = [
    ("exec_command", {"cmd": "printf ordinary > ordinary.txt", "workdir": str(wt)}),
    ("exec_command", {"cmd": "printf forbidden > vendor/basisone/proof.txt", "workdir": str(wt)}),
    ("exec_command", {"cmd": str(fakegit) + " worktree prune", "workdir": str(wt)}),
    ("exec_command", {"cmd": "printf after > after.txt", "workdir": str(wt)}),
]
requests = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(body)
        n = len(requests)
        if n <= len(calls):
            name, args = calls[n-1]
            item = {"id": f"fc_{n}", "type": "function_call", "name": name,
                    "call_id": f"call_{n}", "arguments": json.dumps(args)}
        else:
            item = {"id": "msg_done", "type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": "DONE"}]}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        events = [
            ("response.created", {"response": {"id": f"resp_{n}"}}),
            ("response.output_item.done", {"output_index": 0, "item": item}),
            ("response.completed", {"response": {"id": f"resp_{n}", "output": [item],
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}}),
        ]
        for event, data in events:
            self.wfile.write(("event: " + event + "\ndata: " + json.dumps({"type": event, **data}) + "\n\n").encode())
            self.wfile.flush()

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
args = [sys.executable, str(root / "bin/fm-codex-worker.py"), "launch", str(home), str(wt),
        "codex", "exec", "--skip-git-repo-check", "--ephemeral", "--json",
        "--dangerously-bypass-approvals-and-sandbox", "-c", 'model_provider="fixture"', "-c",
        f'model_providers.fixture={{name="fixture",base_url="http://127.0.0.1:{server.server_port}",wire_api="responses",supports_websockets=false}}',
        "-c", 'model="fixture"', "-c", 'model_reasoning_effort="low"', "Run the local fixture."]
try:
    result = subprocess.run(args, cwd=wt, env=env, text=True, capture_output=True, timeout=60)
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
assert result.returncode == 0, (version, result.stderr)
assert len(requests) == len(calls) + 1, (version, len(requests), result.stderr)
assert (wt / "ordinary.txt").read_text() == "ordinary", (version, result.stderr)
assert (wt / "after.txt").read_text() == "after", (version, result.stderr)
assert not (wt / "vendor/basisone/proof.txt").exists(), (version, "protected write executed")
assert not (wt / "git-ran").exists(), (version, "worktree administration reached fake Git")
assert not (wt / "unrelated-hook-ran").exists(), (version, "unrelated hook ran")
outputs = {i["call_id"]: i["output"] for request in requests for i in request.get("input", [])
           if i.get("type") == "function_call_output"}
assert "blocked by PreToolUse hook" in outputs["call_2"], outputs
assert "blocked by PreToolUse hook" in outputs["call_3"], outputs
config = tomllib.loads((home / "config.toml").read_text())
assert config["approval_policy"] == "never"
assert config["sandbox_mode"] == "danger-full-access"
assert not (wt / "project-hook-ran").exists(), (version, "unrelated project hook ran")
listed = worker.discover("codex", str(wt), home)["data"][0]["hooks"]
foreign = [h for h in listed if h["sourcePath"] == str(wt / ".codex/hooks.json")]
assert len(foreign) == 1 and foreign[0]["trustStatus"] == "untrusted", (version, listed)
assert len(config["hooks"]["state"]) == 1
assert next(iter(config["hooks"]["state"])).startswith(str(home / "hooks.json"))
print(f"ok - {version}: generated guard trusted; ordinary commands run before and after denied calls")
print(f"ok - {version}: vendor write and worktree administration blocked by real PreToolUse")
print(f"ok - {version}: unrelated hook untrusted; auth symlink never opened by setup; safety settings preserved")
worker.remove(home)
assert not home.exists()
assert (original / "auth.json").is_file()
assert (original / "rules/test.rules").exists()
print(f"ok - {version}: private home removed without touching auth or rule targets")
PY
echo '# all fm-codex-hook-layer-live-e2e tests passed'
