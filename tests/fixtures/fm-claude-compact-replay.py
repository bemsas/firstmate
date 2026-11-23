#!/usr/bin/env python3
"""Replay synthetic Eve inputs with installed Claude and a deterministic loopback model."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import threading
import time
import uuid

TARGET = "Recover the approved Eve screens into Open Design (eve-recovery). Reuse the agreed one-frame design. Leave idle lanes idle."
REFILL = "OLD-LANE-REFILL: fill 15-20 lanes"
JUDGE = "JUDGE-RECOMMENDATION: sign off now"
LINK = "https://design.example.invalid/eve/approved-one-frame"
NEXT = "POST-COMPACT-PROBE: report the existing target, decision source, blocker and authorized next step."
UNRELATED_COMPACT = "SYNTHETIC UNRELATED COMPACT CONTEXT"


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, text=True, **kwargs)


def setup(root, code, fixed):
    root.mkdir()
    for name in ("bin", "state", "data", "config", "standins", "claude-config", "os-home"):
        (root / name).mkdir()
    (root / "claude-config" / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True, "theme": "dark",
        "customApiKeyResponses": {"approved": ["compact-fixture-only"], "rejected": []},
        "projects": {str(root): {"hasTrustDialogAccepted": True}},
    }))
    (root / "AGENTS.md").write_text("# Synthetic compact fixture\n")
    env = {
        "HOME": str(root / "os-home"), "PATH": f"{root / 'standins'}:{os.environ['PATH']}",
        "FM_HOME": str(root), "FM_ROOT_OVERRIDE": str(root), "TERM": "xterm-256color",
        "CLAUDE_CONFIG_DIR": str(root / "claude-config"), "DISABLE_AUTOUPDATER": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "ANTHROPIC_API_KEY": "sk-ant-compact-fixture-only",
        "CLAUDE_CODE_MAX_RETRIES": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    for name in ("gh", "gh-axi", "treehouse"):
        standin = root / "standins" / name
        standin.write_text("#!/usr/bin/env bash\nexit 1\n")
        standin.chmod(0o700)
    run(["git", "init", "-qb", "main", root], env=env)
    run(["git", "-C", root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
         "commit", "-qm", "Fixture", "--allow-empty"], env=env)
    if fixed:
        (root / "config" / "claude-compact-resume").touch()
    tasks = code / "bin" / "fm-tasks-axi.sh"
    holds = code / "bin" / "fm-captain-hold.sh"
    for args in (
        [holds, "hold", "eve-design", "--title", "Reuse the approved Eve design", "--reason", "Confirm design"],
        [holds, "hold", "eve-signoff", "--title", "Eve sign-off", "--reason", "Sign off after review"],
        [tasks, "add", "eve-review-fix", "Codex review fix round"],
        [tasks, "add", "eve-recovery", "Recover approved Eve screens into Open Design", "--blocked-by", "eve-review-fix", "--blocked-by", "eve-design"],
        [tasks, "block", "eve-signoff", "--by", "eve-review-fix"],
        [tasks, "start", "eve-review-fix"],
    ):
        run(args, env=env, cwd=root, stdout=subprocess.DEVNULL)
    decision = root / "decision.txt"
    decision.write_text(f"Reuse the agreed one-frame design at {LINK}.\n")
    run([holds, "answer", "eve-design", "--decision-file", decision], env=env, cwd=root, stdout=subprocess.DEVNULL)
    (root / "data" / "captain.md").write_text("# Synthetic memory\n" + "old fleet inventory \u00e9\n" * 4500)
    (root / "data" / "session-progress.md").write_text(f"# Synthetic progress\n{JUDGE}\nEve sign-off ready (obsolete).\n")
    (root / "state" / "turn-context.alerts").write_text(REFILL + "\n" + JUDGE + "\n")
    (root / "state" / "eve-review-fix.status").write_text("working [at=1795353600]: Codex review still open\n")
    return env


def finish_review(root, code, env):
    run([code / "bin/fm-tasks-axi.sh", "done", "eve-review-fix"],
        env=env, cwd=root, stdout=subprocess.DEVNULL)


def payload(root, session, source):
    return json.dumps({"hook_event_name": "SessionStart", "session_id": session,
                       "transcript_path": str(root / "claude-config" / "projects" / "synthetic" / (session + ".jsonl")), "source": source, "model": "offline"})


def fake(root, code, env):
    session = str(uuid.uuid4())
    transcript = Path(json.loads(payload(root, session, "compact"))["transcript_path"])
    transcript.parent.mkdir(parents=True)
    transcript.write_text(json.dumps({
        "type": "user", "origin": {"kind": "human"}, "uuid": str(uuid.uuid4()),
        "sessionId": session, "timestamp": "2026-11-22T13:08:12.000Z",
        "message": {"content": TARGET},
    }) + "\n")
    claude = root / "standins" / "claude"
    claude.symlink_to(shutil.which("bash"))
    hook = code / "bin" / "fm-sessionstart-run.sh"
    run([claude, "-c", """
      export CLAUDE_PID=$$
      printf '%s' "$2" | "$1" > "$4/fake-startup.txt"
      printf '%s' "$3" | "$1" > "$4/fake-compact.txt"
      :
    """, "_", hook, payload(root, session, "startup"), payload(root, session, "compact"), root],
        env={**env, "CLAUDE_CODE_SESSION_ID": session}, cwd=root)
    output = (root / "fake-compact.txt").read_bytes()
    print(f"fake compact: {len(output)} bytes, task offset {output.find(b'eve-recovery')}, first 2048 at {root / 'fake-preview.txt'}", flush=True)
    (root / "fake-preview.txt").write_bytes(output[:2048])


def events(message):
    last_input = message.get("messages", [{}])[-1].get("content", "")
    text = ("<summary>Synthetic compact fixture summary.</summary>"
            if isinstance(last_input, str) and "CRITICAL: Respond with TEXT ONLY" in last_input
            else "FIXTURE-REPLY: preserve synthetic Eve task evidence exactly as supplied.")
    model = message.get("model", "claude-sonnet-4-6")
    usage = {"input_tokens": 3000, "output_tokens": 10}
    reply = {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
             "content": [{"type": "text", "text": text}], "model": model, "stop_reason": "end_turn",
             "stop_sequence": None, "usage": usage}
    if not message.get("stream"):
        return "application/json", json.dumps(reply).encode()
    start = {**reply, "content": [], "usage": {"input_tokens": 3000, "output_tokens": 0}, "stop_reason": None}
    sequence = [
        {"type": "message_start", "message": start},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 10}},
        {"type": "message_stop"},
    ]
    return "text/event-stream", "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in sequence).encode()


def live(root, code, env, claude, fixed):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("content-length", "0")))
            if self.path.startswith("/v1/messages") and "count_tokens" not in self.path:
                with (root / "requests.jsonl").open("ab") as log:
                    log.write(body.replace(b"\n", b" ") + b"\n")
                mime, data = events(json.loads(body))
            else:
                mime, data = "application/json", b'{"input_tokens":3000}'
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {**env, "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}"}
        settings = root / "settings.json"
        hook = shlex.quote(str(code / "bin" / "fm-sessionstart-run.sh"))
        precompact = shlex.quote(str(code / "bin" / "fm-precompact-handoff.py"))
        settings.write_text(json.dumps({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command":
                f"tee {shlex.quote(str(root))}/payload.last | {hook} | tee {shlex.quote(str(root))}/hook.last", "timeout": 90}]}] +
            ([{"matcher": "compact", "hooks": [{"type": "command",
                "command": f"printf '%s\\n' {shlex.quote(UNRELATED_COMPACT)}"}]}] if fixed else
             [{"matcher": "compact", "hooks": [{"type": "command",
                "command": f"cat {shlex.quote(str(root))}/data/session-progress.md {shlex.quote(str(root))}/state/turn-context.alerts"}]}]),
            "PreCompact": [{"hooks": [{"type": "command", "command": f"{precompact} precompact"}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": f"{precompact} inject"}]}],
        }}))
        cli = [claude, "--model", "claude-sonnet-4-6", "--tools", "", "--strict-mcp-config",
               "--setting-sources", "project", "--settings", settings, "--debug-file", root / "claude.debug"]
        socket = root / "tmux.sock"
        tmux = ["tmux", "-S", socket, "-f", "/dev/null"]
        try:
            run(tmux + ["new-session", "-d", "-s", "fixture", "-c", root, "-x", "160", "-y", "42",
                        shlex.join(["env", "-i", *[f"{key}={value}" for key, value in env.items()], *map(str, cli)])])
            def panel():
                return run(tmux + ["capture-pane", "-pt", "fixture", "-S", "-180"], capture_output=True).stdout

            def until(description, check, seconds=35):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if check():
                        return
                    pane = panel()
                    if any(label in pane.lower() for label in ("trust this folder", "trust this project", "choose the text style", "press enter to continue")):
                        run(tmux + ["send-keys", "-t", "fixture", "Enter"])
                        time.sleep(1)
                    elif "custom api key" in pane.lower() and "yes" in pane.lower():
                        run(tmux + ["send-keys", "-t", "fixture", "Up", "Enter"])
                        time.sleep(1)
                    time.sleep(0.25)
                raise RuntimeError(f"{description} failed\n{panel()}")

            def send(line):
                run(tmux + ["send-keys", "-lt", "fixture", line])
                time.sleep(0.25)
                run(tmux + ["send-keys", "-t", "fixture", "Enter"])

            until("initial startup", lambda: (root / "state" / ".session-start-complete").exists())
            time.sleep(1)
            send(TARGET)
            until("first reply", lambda: "FIXTURE-REPLY" in panel())
            run(["bash", "-c", '. "$1"; fm_wake_append check stale-refill "OLD-LANE-REFILL: fill 15-20 lanes"',
                 "_", code / "bin/fm-wake-lib.sh"], env=env, cwd=root, stdout=subprocess.DEVNULL)
            time.sleep(1)
            send("/compact")
            def compact_output():
                try:
                    return json.loads((root / "payload.last").read_text()).get("source") == "compact" and (root / "hook.last").stat().st_size > 0
                except (OSError, ValueError):
                    return False
            until("ordinary compact hook", compact_output, 50)
            until("completed compact", lambda: "Compacted (ctrl+o" in panel())
            send(NEXT)
            hits = []
            def after_request():
                for line in reversed((root / "requests.jsonl").read_text().splitlines()):
                    req = json.loads(line)
                    msgs = json.dumps(req.get("messages", []), ensure_ascii=False)
                    if NEXT in msgs:
                        hits.append(req)
                        return True
                return False
            until("post-compact API request", after_request)
            (root / "postcompact-request.json").write_text(json.dumps(hits[0], ensure_ascii=False, indent=2) + "\n")
            return hits[0]
        finally:
            try:
                (root / "pane.txt").write_text(panel())
            except subprocess.CalledProcessError:
                pass
            subprocess.run(tmux + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server.shutdown()


def verify_delivery(root, request, fixed, closed_review):
    hook = (root / "hook.last").read_text()
    blocks = [part.get("text", "") for msg in request["messages"] if isinstance(msg.get("content"), list)
              for part in msg["content"]]
    compact = [block for block in blocks if "SessionStart:compact hook success:" in block]
    assert not request.get("tools"), "tools reached the offline provider"
    if fixed:
        transcript, = (root / "claude-config" / "projects").glob("*/*.jsonl")
        observer = Path(__file__).resolve().parents[2] / "bin/fm-precompact-handoff.py"
        observed = run([observer, "observe-compact", "--home", root, "--transcript", transcript],
                       env={**os.environ, "CLAUDE_CONFIG_DIR": str(root / "claude-config"),
                            "FM_STATE_OVERRIDE": str(root / "state")}, capture_output=True)
        print(observed.stdout.strip())
        assert json.loads(observed.stdout)["delivery"] == "observed", "native compact attachment was not verified"
        page_blocks = [block for block in compact if hook.strip() in block]
        assert len(page_blocks) == 1, "the complete page did not arrive exactly once"
        assert sum(UNRELATED_COMPACT in block for block in compact) == 1, "the unrelated hook did not co-fire"
        assert len(hook.encode("utf-8")) <= 1660, "page exceeded the byte budget"
        assert "persisted-output" not in page_blocks[0], "Claude spilled the compact page"
        assert TARGET in hook and LINK in hook and "Captain decision tasks-axi:eve-design" in hook
        assert REFILL not in hook and JUDGE not in hook, "untrusted notes entered the page"
        assert "Durable wake records pending." in hook and "bin/fm-wake-drain.sh" in hook
        if closed_review:
            signoff = "- eve-signoff [queued]: captain hold; verify readiness before asking"
        else:
            signoff = "- eve-signoff [queued]: captain hold gated; blocked by eve-review-fix"
        assert hook.count(signoff) == 1, "the exact review dependency did not govern the sign-off row"
    else:
        previews = [block for block in compact if "RE-EMIT CUE" in block]
        assert len(previews) == 1 and "Full output saved to:" in previews[0], "baseline did not spill"
        assert "eve-recovery" not in previews[0] and "eve-recovery" in hook, "baseline did not hide the task row"
        assert any(REFILL in block and JUDGE in block for block in compact), "conflicting compact replay did not arrive"
    print(f"hook={len(hook.encode('utf-8'))} bytes; compact context blocks="
          f"{[len(block.encode('utf-8')) for block in compact]}; request=postcompact-request.json", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("fake", "live"))
    parser.add_argument("code", type=lambda x: Path(x).resolve())
    parser.add_argument("fixture", type=lambda x: Path(x).resolve(), help="a fresh directory path to create")
    parser.add_argument("--fixed", action="store_true")
    parser.add_argument("--close-review", action="store_true")
    parser.add_argument("--claude", default=shutil.which("claude"))
    args = parser.parse_args()
    env = setup(args.fixture, args.code, args.fixed)
    if args.close_review:
        finish_review(args.fixture, args.code, env)
    if args.mode == "fake":
        fake(args.fixture, args.code, env)
    else:
        request = live(args.fixture, args.code, env, args.claude, args.fixed)
        verify_delivery(args.fixture, request, args.fixed, args.close_review)


if __name__ == "__main__":
    main()
