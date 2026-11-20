#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Linux ]; then
  printf 'skip: desktop trust requires Linux procfs\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-codex-trust-desktop)
trap fm_test_cleanup EXIT

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import base64
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import time

root, lab = map(Path, sys.argv[1:])
main, ops, mate, remote = (lab / name for name in ("main", "ops", "mate", "remote"))
for home in (main, ops, mate, remote):
    for name in ("data", "state", "projects"):
        (home / name).mkdir(parents=True)
registry = main / "data/secondmates.md"
registry.write_text(f"- mate - local (home: {mate}; scope: tasks; projects: sample; added 2026-11-20)\n"
                    f"- remote - remote (host: remote; root: /code; home: {remote}; scope: tasks; "
                    "projects: sample; added 2026-11-20)\n"
                    "- venipak-mate - excluded (host: other; root: /code; home: /data; scope: business; "
                    "projects: siunta; added 2026-11-20)\n")
project = mate / "projects/sample"
project.mkdir()
def git(directory, *args):
    return subprocess.run(["git", "-C", directory, *args], capture_output=True, text=True, check=True).stdout
git(project, "init", "-q")
git(project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "commit", "-qm", "fixture", "--allow-empty")
wt = lab / "pooled/worktree"
wt.parent.mkdir()
git(project, "worktree", "add", "-q", "--detach", wt)
hookfile = project / ".codex/hooks.json"
hookfile.parent.mkdir()
hookfile.write_text("{}")
project_registry = mate / "data/projects.md"
project_registry.write_text("- sample [local-only] - fixture\n")
private = mate / "state/work.codex-home"
private.mkdir()
(private / "hooks.json").write_text("{}")
state = lab / "state.json"
source = lab / "codex.c"
source.write_text(r'''
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--version")) {
        puts("codex-cli 0.171.0");
        return 0;
    }
    if (argc > 2 && !strcmp(argv[argc - 1], "app-server")) {
        execlp("python3", "python3", getenv("FM_TRUST_RPC"), (char *)0);
        return 2;
    }
    for (;;) pause();
}
''')
codex = lab / "codex"
subprocess.run(["cc", "-o", codex, source], check=True)
herdr = lab / "herdr"
rpc = lab / "rpc.py"
rpc.write_text('''
import json, os, sys
from pathlib import Path
file = Path(os.environ["FM_TRUST_FIXTURE"])
for request in map(json.loads, sys.stdin):
    if request["method"] == "initialize":
        print('{"id": 1, "result": {}}', flush=True)
    if request["method"] == "hooks/list":
        s = json.loads(file.read_text())
        key = s["origin"] + ":session_start:0:0"
        if s.get("unsafe_key"):
            key += ":test-secret-value"
        hook = {"key": key, "sourcePath": s["origin"], "source": s.get("source", "project"),
                "handlerType": "command", "enabled": True, "isManaged": False, "pluginId": None,
                "eventName": "sessionStart", "currentHash": "sha256:" + "a" * 64,
                "trustStatus": "trusted" if s["mode"] == "cleared" else "untrusted",
                "command": "echo --token test-secret-value"}
        guard = {"key": s["private"] + "/hooks.json:pre_tool_use:0:0", "enabled": True,
                 "source": "user", "trustStatus": "trusted"}
        assert os.environ["CODEX_HOME"] == s["private"]
        assert request["params"]["cwds"] == [s["worktree"]]
        print(json.dumps({"id": 2, "result": {"data": [{"cwd": s["worktree"], "errors": [], "warnings": [],
                          "hooks": [guard, hook] + [
                              dict(hook, key=s["origin"] + f":session_start:0:{index}")
                              for index in range(1, s.get("hook_total", 1))
                          ]}]}}), flush=True)
''')
herdr.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ["FM_TRUST_FIXTURE"])
s = json.loads(state.read_text())
def save():
    state.write_text(json.dumps(s))
def result(value):
    print(json.dumps({"result": value}))
session, name, act, *rest = sys.argv[1:]
assert session == "--session" and name == "default"
if act == "status":
    print(json.dumps({"client": {"version": "0.9.5"}, "server": {"version": s.get("server", "0.9.5"),
                       "running": True, "compatible": True}}))
    sys.exit()
intent, *args = rest
if intent == "process-info":
    assert args == ["--pane", "w1:p1"]
    native = {"name": "codex", "pid": s["pid"], "cwd": s["worktree"]}
    result({"type": "pane_process_info", "process_info": {
        "pane_id": "w1:p1", "shell_pid": s["pid"], "foreground_process_group_id": s.get("pgid", s["pid"]),
        "foreground_processes": s.get("foreground", [] if s.get("human") else [native])}})
elif intent == "get":
    assert args == ["w1:p1"]
    result({"pane": {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": s.get("tab_id", "w1:t1"),
                      "agent": s.get("agent", "codex"), "agent_status": s.get("agent_status", "working"),
                      "terminal_id": "other" if s.get("rebind") else "term_test",
                      "foreground_cwd": s["worktree"], "scroll": {"offset_from_bottom": s.get("scroll", 0)}}})
elif intent == "read":
    assert args == ["w1:p1", "--source", "visible", "--raw"]
    s["reads"] += 1
    mode = s["mode"]
    if mode == "hooks" and "screen" in s:
        sys.stdout.write(s["screen"] if s["selection"] == 1 else s["screen_after_down"])
    elif mode == "hooks":
        n = s.get("count", "1 hook is")
        print("  Hooks need review\\n  " + n + " new or changed.\\n"
              "  Hooks can run outside the sandbox after you trust them.\\n")
        options = ["Review hooks", "Trust all and continue", "Continue without trusting (hooks won't run)"]
        for n, option in enumerate(options, 1):
            marker = "› " if n == s["selection"] or s.get("ambiguous") else "  "
            print(f"{marker}{n}. {option}")
        print("\\n  Press enter to confirm or esc to go back")
    elif mode == "folder":
        print("  Folder access\\n  " + s.get("visible_path", s["worktree"]) + "\\n\\n"
              "  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. "
              "Folder settings can run code\\n  automatically, even without a model request. Continue only if "
              "you trust these files. Your trust decision will be saved.\\n\\n"
              "› 1. Trust and continue\\n  2. Back to Agent Command Center\\n\\n  enter continue · esc back")
    else:
        print("User mentioned Hooks need review in chat.\\n› Enter a prompt")
    if s.get("race_read"):
        s["rebind"] = True
    save()
elif intent == "send-keys":
    assert args[0] == "w1:p1"
    key = args[1]
    audit = Path(s["audit"]).read_text().splitlines()
    attempt = json.loads(audit[-1])
    assert attempt["phase"] == "keypress-attempt" and attempt["key"] == key
    s["keys"].append(key)
    if key == "down":
        s["selection"] = 2
        if s.get("race_after_down"):
            s["mode"] = "cleared"
    elif key == "enter":
        assert s["mode"] == "folder" or s["mode"] == "hooks" and s["selection"] == 2
        s["mode"] = "hooks" if s["mode"] == "folder" and s.get("then_hooks") else "cleared"
    save()
    if s.get("uncertain_send"):
        sys.exit(1)
else:
    raise AssertionError(intent)
''')
herdr.chmod(0o700)
meta = mate / "state/work.meta"
record = dict(window="default:w1:p1", endpoint_task_id="work", worktree=wt, project=project,
              harness="codex", kind="ship", backend="herdr", herdr_session="default", herdr_workspace_id="w1",
              herdr_tab_id="w1:t1", herdr_pane_id="w1:p1", spawn_gen="gen-1")
def write_meta(path, values):
    path.write_text("".join(f"{k}={v}\n" for k, v in values.items()))
write_meta(meta, record)
write_meta(remote / "state/work.meta", record)
args = [root / "bin/fm-codex-trust-desktop.py", "--main-home", main, "--ops-home", ops,
        "--herdr-bin", herdr, "--codex-bin", codex]
env = dict(os.environ, FM_TRUST_FIXTURE=str(state), FM_TRUST_RPC=str(rpc))
worker_env = dict(env, FM_TASK_ID="work", FM_TASK_INBOX=str(mate / "state/work.inbox"),
                  CODEX_HOME=str(private), HERDR_PANE_ID="w1:p1")
time.sleep(0.06)  # Separate source ctime from the kernel's process-start tick.
pid, terminal = pty.fork()
if pid == 0:
    os.chdir(wt)
    os.execve(codex, [str(codex)], worker_env)
journal = main / "state/codex-trust-desktop"
def reset(mode="hooks", **overrides):
    if journal.exists():
        shutil.rmtree(journal)
    write_meta(meta, record)
    state.write_text(json.dumps(dict(dict(mode=mode, pid=pid, worktree=str(wt), private=str(private),
                                          origin=str(hookfile), audit=str(journal / "events.jsonl"),
                                          keys=[], reads=0, selection=1), **overrides)))
def run(mode="apply", code=0, *, task=True):
    command = [*args, "--" + mode, *(["--task", "mate/work"] if task else [])]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=25)
    expected_codes = code if isinstance(code, tuple) else (code,)
    assert result.returncode in expected_codes and not result.stderr, (result.returncode, result.stdout, result.stderr)
    assert "test-secret-value" not in result.stdout
    if journal.exists() and (journal / "events.jsonl").exists():
        assert "test-secret-value" not in (journal / "events.jsonl").read_text()
    return result.stdout
def fixture():
    return json.loads(state.read_text())
def events():
    return list(map(json.loads, (journal / "events.jsonl").read_text().splitlines()))

@contextmanager
def foreground_shell(background=False):
    bash = shutil.which("bash")
    shell_pid, shell_terminal = pty.fork()
    if shell_pid == 0:
        os.close(terminal)
        os.chdir(wt)
        script = 'printf "ready\\n"; read -r'
        if background:
            script = 'set -m; "$1" & printf "%s\\n" "$!"; read -r'
        os.execve(bash, [bash, "--noprofile", "--norc", "-c", script, "_", str(codex)], worker_env)
    child_pid = None
    try:
        assert select.select([shell_terminal], [], [], 5)[0], "fixture shell did not start"
        ready = os.read(shell_terminal, 1024).strip()
        if background:
            child_pid = int(ready)
        proc = Path(f"/proc/{shell_pid}")
        assert os.tcgetpgrp(shell_terminal) == shell_pid
        for _ in range(100):
            if (proc / "stat").read_text().rsplit(") ", 1)[1].startswith("S "):
                break
            time.sleep(0.01)
        else:
            raise AssertionError("fixture shell did not settle into its terminal read")
        if background:
            assert os.getpgid(child_pid) == child_pid != shell_pid
        else:
            assert ready == b"ready"
        yield dict(pid=shell_pid, agent=None, agent_status="unknown",
                   foreground=[dict(pid=shell_pid, name="bash", argv0=bash, cwd=str(wt))])
    finally:
        if child_pid is not None:
            try:
                os.kill(child_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        os.close(shell_terminal)
        os.waitpid(shell_pid, 0)

try:
    for _ in range(100):
        if Path(f"/proc/{pid}/exe").resolve() == codex:
            break
        time.sleep(0.01)
    else:
        raise AssertionError("fixture foreground worker did not start")

    reset()
    dry = json.loads(run("dry-run"))
    assert dry["planned_keys"] == ["down", "enter"] and dry["hook_names"] == ["sessionStart"]
    assert not journal.exists() and fixture()["keys"] == []
    assert run(task=False) == "" and fixture()["keys"] == ["down", "enter"]
    assert run() == "" and fixture()["keys"] == ["down", "enter"]
    log = events()
    assert [r["phase"] for r in log] == ["keypress-attempt", "keypress-observed"] * 2
    assert all(r["worktree"] == str(wt) and r["lane"] == "default:w1:p1" and r["at"].endswith("+00:00")
               and r["hook_keys"] == [str(hookfile) + ":session_start:0:0"] for r in log)
    assert log[-1]["result"].endswith("exact hook hashes trusted")
    print("ok - local registry and pooled Git worker resolve; native hooks order and durable audit are idempotent")

    # Preserve Herdr's captured CRLF, SGR, and viewport padding in the replay.
    native = base64.b64decode(
        (root / "tests/fixtures/codex-0.171.0-herdr-0.9.5-hooks.ansi.b64").read_bytes()
    ).decode()
    plain, sgr_count = re.subn(r"\x1b\[[0-9;:]*m", "", native)
    assert sgr_count and plain.count("enter confirm · esc skip") == 1
    legacy = "Press enter to confirm or esc to go back"
    legacy_styled = re.sub(r"enter\x1b\[0m.*?esc\x1b\[0m\x1b\[2m skip", legacy, native)
    assert legacy_styled.count(legacy) == 1 and "\x1b[" in legacy_styled
    variants = {
        "captured": native,
        "footer only": plain,
        "SGR only": legacy_styled,
        "neither": plain.replace("enter confirm · esc skip", legacy),
    }
    recognized = {}
    for name, screen in variants.items():
        reset(screen=screen, hook_total=5)
        out = run("dry-run", code=(0, 2))
        plan = json.loads(out) if out else {}
        recognized[name] = plan.get("reason", plan.get("phase", "idle"))
        if plan.get("phase") == "dry-run":
            assert plan["dialog"] == "hooks" and plan["planned_keys"] == ["down", "enter"]
            assert len(plan["hook_keys"]) == 5
        assert not journal.exists() and fixture()["keys"] == []
    assert set(recognized.values()) == {"dry-run"}, recognized

    # The fixture simulates the selected row moving after Down.
    after_down = native.replace("› 1. Review hooks", "  1. Review hooks").replace(
        "  2. Trust all and continue", "› 2. Trust all and continue"
    )
    reset(screen=native, screen_after_down=after_down, hook_total=5)
    assert run() == "" and fixture()["keys"] == ["down", "enter"]
    assert len(events()[-1]["hook_keys"]) == 5
    assert events()[-1]["result"].endswith("exact hook hashes trusted")

    for screen in ("Assistant quoted this menu:\n" + native,
                   native.replace("› 1. Review hooks", "› Review hooks"),
                   native[:native.index("  3. Continue")],
                   "\x1b[2J" + native):
        reset(screen=screen, hook_total=5)
        assert run(code=2) and fixture()["keys"] == []
    print("ok - captured native hook viewport and independent style/footer variants; quoted and clipped menus refuse")

    reset("folder")
    assert json.loads(run("dry-run"))["planned_keys"] == ["enter"]
    assert run() == "" and fixture()["keys"] == ["enter"] and events()[0]["hook_keys"] == []
    reset("folder", then_hooks=True)
    assert run() == "" and fixture()["keys"] == ["enter"]
    assert run() == "" and fixture()["keys"] == ["enter", "down", "enter"]
    reset("folder", visible_path="/unapproved")
    assert "folder dialog" in run(code=2) and fixture()["keys"] == []
    reset("cleared")
    assert run("dry-run") == "" and fixture()["keys"] == []
    print("ok - exact folder and selected option are required; ordinary chat is idle")

    with foreground_shell() as retired:
        reset(**retired)
        assert run("dry-run") == "" and not journal.exists()
        assert run(task=False) == "" and events() == []
        assert fixture()["keys"] == [] and fixture()["reads"] == 0
        for overrides in (dict(agent="codex"), dict(agent_status="working"), dict(tab_id="w1:t2"),
                          dict(pgid=pid), dict(foreground=[]),
                          dict(foreground=[dict(retired["foreground"][0], cwd=str(project))])):
            reset(**(retired | overrides))
            assert run(code=2) and fixture()["keys"] == [] and fixture()["reads"] == 0
    with foreground_shell(background=True) as backgrounded:
        reset(**backgrounded)
        assert run(code=2) and fixture()["keys"] == [] and fixture()["reads"] == 0
    for overrides in ({}, dict(foreground=[dict(retired["foreground"][0], pid=pid)])):
        reset(agent=None, agent_status="unknown", **overrides)
        assert run(code=2) and fixture()["keys"] == [] and fixture()["reads"] == 0
    print("ok - retired shell is quiet; mismatched, ambiguous and backgrounded workers refuse before capture")

    for overrides in (dict(ambiguous=True), dict(selection=2), dict(count="2 hooks are"),
                      dict(source="user", origin="/outside/test-secret-value"), dict(unsafe_key=True)):
        reset(**overrides)
        assert run(code=2) and fixture()["keys"] == []
        assert run() == ""
        assert len(events()) == 1 and events()[0]["phase"] == "refusal"
    print("ok - malformed, preselected, mismatched and foreign hooks refuse once without logging secrets")

    for overrides in (dict(human=True), dict(scroll=1), dict(server="9.9.9")):
        reset(**overrides)
        assert run(code=2) and fixture()["keys"] == [] and fixture()["reads"] == 0
    reset()
    git(lab, "init", "-q")
    write_meta(meta, dict(record, worktree=lab))
    assert "not linked" in run(code=2) and fixture()["reads"] == 0
    reset()
    project_registry.write_text("- sample-other [local-only] - fixture\n")
    assert "unregistered" in run(code=2) and fixture()["reads"] == 0
    project_registry.write_text("- sample [local-only] - fixture\n")
    reset()
    write_meta(meta, dict(record, project=mate / "projects/siunta"))
    assert "registered projects" in run(code=2) and fixture()["reads"] == 0
    reset()
    duplicate = ops / "state/duplicate.meta"
    write_meta(duplicate, dict(record, kind="secondmate"))
    assert "multiple fleet task records" in run(code=2) and fixture()["reads"] == 0
    duplicate.unlink()
    print("ok - missing identity, unsupported version, invalid linkage, excluded and duplicate endpoints never capture")

    reset(race_read=True)
    assert "changed while reading" in run(code=2) and fixture()["keys"] == []
    for overrides in (dict(race_after_down=True), dict(uncertain_send=True)):
        reset(**overrides)
        assert "outcome uncertain" in run(code=2)
        assert run() == "" and fixture()["keys"] == ["down"]
        assert len(events()) == 3 and events()[1]["result"] == "uncertain"
    reset()
    journal.mkdir(mode=0o700)
    lock = journal / "lock"
    lock.touch(mode=0o600)
    with lock.open("rb") as locked:
        fcntl.flock(locked, fcntl.LOCK_EX)
        assert run() == "" and fixture()["reads"] == 0
    reset()
    hookfile.write_text('{"changed": true}')
    assert "changed after" in run(code=2) and fixture()["keys"] == []
    print("ok - viewport, provenance and delivery races stop input; concurrent invocation does not inspect or press")
finally:
    os.close(terminal)  # Closing this isolated PTY hangs up only the fixture worker.
    os.waitpid(pid, 0)
PY
