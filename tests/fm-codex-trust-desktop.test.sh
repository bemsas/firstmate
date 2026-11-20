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
import fcntl
import json
import os
from pathlib import Path
import pty
import shutil
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
                          "hooks": [guard, hook]}]}}), flush=True)
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
    result({"process_info": {"pane_id": "w1:p1", "shell_pid": s["pid"], "foreground_process_group_id": s["pid"],
                             "foreground_processes": [] if s.get("human") else [native]}})
elif intent == "get":
    assert args == ["w1:p1"]
    result({"pane": {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "codex",
                      "terminal_id": "other" if s.get("rebind") else "term_test",
                      "foreground_cwd": s["worktree"], "scroll": {"offset_from_bottom": s.get("scroll", 0)}}})
elif intent == "read":
    assert args == ["w1:p1", "--source", "visible", "--raw"]
    s["reads"] += 1
    mode = s["mode"]
    if mode == "hooks":
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
    assert result.returncode == code and not result.stderr, (result.returncode, result.stdout, result.stderr)
    assert "test-secret-value" not in result.stdout
    if journal.exists() and (journal / "events.jsonl").exists():
        assert "test-secret-value" not in (journal / "events.jsonl").read_text()
    return result.stdout
def fixture():
    return json.loads(state.read_text())
def events():
    return list(map(json.loads, (journal / "events.jsonl").read_text().splitlines()))

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
