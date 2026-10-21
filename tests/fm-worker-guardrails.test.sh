#!/usr/bin/env bash
# Executable policy and generated adapter callback regressions. No real agent,
# credentials, fleet, or shared worktree pool is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-guardrails)
trap fm_test_cleanup EXIT

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib

root, tmp = map(Path, sys.argv[1:])
check = root / "bin/fm-worker-pretool-check.py"
install = root / "bin/fm-worker-guardrails.py"
wt, state = tmp / "work tree", tmp / "state"
(wt / "vendor/basisone").mkdir(parents=True)
(wt / "src").mkdir()
state.mkdir()
(wt / "alias").symlink_to(wt / "vendor/basisone", target_is_directory=True)

def run(payload, expected, *options):
    result = subprocess.run([sys.executable, str(check), "--root", str(wt), *options],
                            input=json.dumps(payload), text=True, capture_output=True)
    assert result.returncode == expected, (payload, result.returncode, result.stderr)
    if expected == 2:
        assert result.stderr.startswith("blocked: ") and "(recommended); (b)" in result.stderr
    return result

for tool in ("Edit", "Write", "write_file", "StrReplaceFile", "Delete", "edit"):
    for path in ("vendor/basisone/a.py", "./vendor/./basisone/a.py",
                 str(wt / "vendor/basisone/new.py"), "alias/a.py"):
        for key in ("file_path", "path", "filePath", "target_file"):
            run({"tool_name": tool, "tool_input": {key: path}}, 2)
    run({"tool_name": tool, "tool_input": {"path": "src/a.py", "content": "vendor/basisone is frozen"}}, 0)
for tool in ("Read", "read_file", "ReadFile"):
    run({"tool_name": tool, "tool_input": {"path": "vendor/basisone/a.py"}}, 0)
for field in ("tool_input", "toolInput"):
    for command in ("git worktree add /tmp/nope", "git -C /tmp worktree remove /tmp/nope",
                    "git -c a=b --no-pager worktree prune", "git worktree move a b",
                    "true && /usr/bin/git worktree prune", "env A=b git worktree add x",
                    "bash -lc 'git worktree remove x'", "sh -c \"bash -c 'git worktree prune'\""):
        run({"tool_name": "Bash", field: {"command": command}}, 2)
for command in ("git worktree list", "git worktree list --porcelain", "git status --short",
                "cat vendor/basisone/a.py", "rg needle vendor/basisone", "git diff -- vendor/basisone"):
    run({"tool_name": "Shell", "tool_input": {"command": command}}, 0)
for command in ("echo x > vendor/basisone/a", "sed -i s/x/y/ vendor/basisone/a",
                "rm -rf vendor", "python3 -c 'open(\"vendor/basisone/a\", \"w\")'",
                "cat vendor/basisone/a\nrm vendor/basisone/b",
                "git diff --output=vendor/basisone/a", "rg --pre='touch x' vendor/basisone"):
    run({"tool_name": "Bash", "tool_input": {"command": command}}, 2)
run({"tool_name": "Bash", "cwd": str(wt / "vendor/basisone"), "tool_input": {"command": "touch a"}}, 2)
run({"tool_name": "Bash", "tool_input": {"cmd": ["git", "worktree", "prune"]}}, 2)
for operation in ("Update File", "Delete File", "Add File"):
    run({"tool_name": "apply_patch", "tool_input": {"patch": f"*** Begin Patch\n*** {operation}: vendor/basisone/a\n*** End Patch"}}, 2)
run({"tool_name": "apply_patch", "tool_input": "*** Begin Patch\n*** Move to: vendor/basisone/a\n*** End Patch"}, 2)
allowed = run({"tool_name": "Write", "tool_input": {"path": "src/a.py"}}, 0, "--cursor")
assert json.loads(allowed.stdout) == {"permission": "allow"}
invalid = subprocess.run([sys.executable, str(check)], input="{", text=True, capture_output=True)
assert invalid.returncode == 2
print("ok - policy blocks edits, patches, shell writes and worktree mutations; permits reads and scoped edits")

# Kimi's hook is globally installed but must be inert outside worker tokens.
home = tmp / "user-home"
config_dir = home / ".kimi-code"
config_dir.mkdir(parents=True)
config = config_dir / "config.toml"
original = '# foreign comment\n[ui]\ntheme = "night"\n'
config.write_text(original)
env = dict(os.environ, HOME=str(home))
installer = root / "bin/fm-kimi-turnend-hook.sh"
subprocess.run([str(installer), "install"], env=env, check=True)
first = config.read_bytes()
subprocess.run([str(installer), "install"], env=env, check=True)
assert config.read_bytes() == first
hook = next(h for h in tomllib.loads(config.read_text())["hooks"] if h["event"] == "PreToolUse")
payload = {"cwd": str(wt), "tool_name": "Write", "tool_input": {"path": "vendor/basisone/a"}}
def kimi_call(expected):
    result = subprocess.run(hook["command"], shell=True, input=json.dumps(payload), text=True, env=env, capture_output=True)
    assert result.returncode == expected, result.stderr
kimi_call(0)
token = "fm.123456abcdef"
(wt / ".fm-kimi-turnend").write_text("token=" + token + "\n")
(config_dir / "fm-turn-end.d" / token).write_text(str(state / "t.turn-ended") + "\n")
kimi_call(2)
subprocess.run([str(installer), "remove"], env=env, check=True)
assert config.read_text() == original
print("ok - Kimi registered workers block; ordinary sessions remain inert; removal restores foreign bytes")

# Install against lifecycle artifacts and execute the resulting registered
# command/callback. Checking source text would only test our own assumptions.
for harness, event, config in (
    ("claude", "PreToolUse", wt / ".claude/settings.local.json"),
    ("gemini", "BeforeTool", state / "t.gemini-settings.json"),
    ("grok", "PreToolUse", wt / ".grok/hooks/fm-worker-guardrails.json"),
    ("cursor", "preToolUse", state / "t.cursor-guardrails/hooks/hooks.json"),
):
    if harness in {"claude", "gemini"}:
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({"hooks": {"Stop": [{"preserve": True}]}}))
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    first = config.read_bytes()
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    assert config.read_bytes() == first
    value = json.loads(first)
    if harness in {"claude", "gemini"}:
        assert value["hooks"]["Stop"] == [{"preserve": True}]
    entry = value["hooks"][event][0]
    command = entry["command"] if harness == "cursor" else entry["hooks"][0]["command"]
    for payload, expected in (({"tool_name": "Write", "tool_input": {"path": "vendor/basisone/x"}}, 2),
                              ({"tool_name": "Bash", "tool_input": {"command": "git worktree prune"}}, 2),
                              ({"tool_name": "Read", "tool_input": {"path": "vendor/basisone/x"}}, 0)):
        result = subprocess.run(command, shell=True, input=json.dumps(payload), text=True, capture_output=True)
        assert result.returncode == expected, (harness, result.stderr)
    print(f"ok - {harness} generated hook executes the shared policy idempotently")

for harness in ("pi", "pi-signed", "omp", "opencode"):
    extension = state / f"t.{'omp' if harness == 'omp' else 'pi'}-ext.ts"
    extension.write_text("export default function (pi: any) {\n}\n")
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    module = wt / ".opencode/plugins/fm-worker-guardrails.js" if harness == "opencode" else extension
    first = module.read_bytes()
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    assert module.read_bytes() == first, f"{harness} repeated install changed the extension"
    subprocess.run(["node", "--input-type=module", "-", str(module), harness], input=r'''
import { pathToFileURL } from 'node:url';
const mod = await import(pathToFileURL(process.argv[2]));
const harness = process.argv[3];
let hook;
if (harness === 'opencode') hook = (await mod.FmWorkerGuardrails())["tool.execute.before"];
else mod.default({on: (name, handler) => { if (name === 'tool_call') hook = handler; }});
if (!hook) throw Error('no tool-call hook registered');
for (const [tool, args, blocked] of [
  ['write', {path: 'vendor/basisone/x'}, true],
  ['bash', {command: 'git worktree prune'}, true],
  ['read', {path: 'vendor/basisone/x'}, false],
  ['write', {path: 'src/x'}, false],
]) {
  let denied = false;
  if (harness === 'opencode') {
    try { await hook({tool}, {args}); } catch { denied = true; }
  } else denied = Boolean((await hook({toolName: tool, input: args}, {})).block);
  if (denied !== blocked) throw Error(`${harness}: unexpected decision for ${tool}`);
}
''', text=True, check=True)
    print(f"ok - {harness} generated native callback executes the shared policy")
PY
pass "worker guardrail executable policy and generated adapter callbacks"
