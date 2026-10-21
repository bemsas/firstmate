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
import shutil
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
run({"tool_name": "Write", "tool_input": {"path": "src/example", "content": "*** Update File: vendor/basisone/a"}}, 0)
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
    ("devin", "PreToolUse", state / "t.devin-config.json"),
):
    if harness in {"claude", "gemini", "devin"}:
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({"hooks": {"Stop": [{"preserve": True}]}}))
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    first = config.read_bytes()
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    assert config.read_bytes() == first
    value = json.loads(first)
    if harness in {"claude", "gemini", "devin"}:
        assert value["hooks"]["Stop"] == [{"preserve": True}]
    entry = value["hooks"][event][0]
    command = entry["command"] if harness == "cursor" else entry["hooks"][0]["command"]
    for payload, expected in (({"tool_name": "Write", "tool_input": {"path": "vendor/basisone/x"}}, 2),
                              ({"tool_name": "Bash", "tool_input": {"command": "git worktree prune"}}, 2),
                              ({"tool_name": "Read", "tool_input": {"path": "vendor/basisone/x"}}, 0)):
        result = subprocess.run(command, shell=True, input=json.dumps(payload), text=True, capture_output=True)
        assert result.returncode == expected, (harness, result.stderr)
    unavailable = subprocess.run(command, shell=True, input='{}', text=True,
                                 env=dict(os.environ, PATH="/nonexistent"), capture_output=True)
    assert unavailable.returncode == 2, f"{harness} evaluator failure must block"
    print(f"ok - {harness} generated hook executes the shared policy idempotently")

# Codex's private home preserves configuration, never opens auth, and grants
# no trust until the real vendor has identified the generated hook.
codex_source = tmp / "codex source"
codex_source.mkdir()
os.mkfifo(codex_source / "auth.json")
(codex_source / "rules").mkdir()
(codex_source / "rules/local.rules").write_text("# preserved rule\n")
(codex_source / "AGENTS.md").write_text("Preserved user instructions.\n")
source_config = '\n'.join([
    'approval_policy="on-request"', 'sandbox_mode="workspace-write"',
    'model_auto_compact_token_limit=10000', 'model_instructions_file="instructions.txt"',
    '[sandbox_workspace_write]', 'network_access=false', 'writable_roots=["/scoped"]',
    '[features]', 'hooks=false', 'shell_tool=false',
    '[hooks.state."unrelated"]', 'trusted_hash="old"',
    '[mcp_servers.docs]', 'command="docs"',
]) + "\n"
(codex_source / "config.toml").write_text(source_config)
worker = root / "bin/fm-codex-worker.py"
codex_env = dict(os.environ, CODEX_HOME=str(codex_source))
private = state / "codex.codex-home"
for _ in range(2):
    result = subprocess.run([sys.executable, str(worker), "prepare", str(wt), str(state), "codex"],
                            env=codex_env, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    config = tomllib.loads((private / "config.toml").read_text())
    assert config["approval_policy"] == "on-request"
    assert config["sandbox_mode"] == "workspace-write"
    assert config["model_auto_compact_token_limit"] == 10000
    assert config["model_instructions_file"] == str(codex_source / "instructions.txt")
    assert config["sandbox_workspace_write"] == {"network_access": False, "writable_roots": ["/scoped"]}
    assert config["features"] == {"hooks": True, "shell_tool": False}
    assert config["mcp_servers"]["docs"] == {"command": "docs"}
    assert config["hooks"] == {}
    assert (private / "auth.json").is_symlink()
    assert os.readlink(private / "auth.json") == str(codex_source / "auth.json")
    assert (private.stat().st_mode & 0o777) == 0o700
    assert ((private / "config.toml").stat().st_mode & 0o777) == 0o600
    command = json.loads((private / "hooks.json").read_text())["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
    for cmd, expected in (("git worktree prune", 2), ("git status --short", 0)):
        result = subprocess.run(command, shell=True, input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
                                text=True, capture_output=True)
        assert result.returncode == expected, result.stderr
    (private / "runtime-owned").write_text("retire on reprepare")
assert (codex_source / "config.toml").read_text() == source_config
# Invalid vendor discovery must fail before trust publication or worker exec.
fake_codex = tmp / "codex-protocol"
fake_codex.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ["CODEX_HOME"])
if "app-server" not in sys.argv:
    (home / "worker-executed").touch()
    sys.exit(0)
path = home / "hooks.json"
command = json.loads(path.read_text())["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "initialize":
        print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
    elif msg.get("method") == "hooks/list":
        hook = {"key": str(path) + ":pre_tool_use:0:0", "eventName": "preToolUse",
                "handlerType": "command", "command": command, "matcher": ".*", "async": False,
                "timeoutSec": 10, "enabled": True, "isManaged": False, "source": "user",
                "sourcePath": str(path), "pluginId": None, "currentHash": "sha256:" + "a" * 64}
        if os.environ["FM_BAD_HOOK"] == "command":
            hook["command"] = "touch unexpected"
        else:
            hook["currentHash"] = "invalid"
        print(json.dumps({"id": msg["id"], "result": {"data": [{"errors": [], "hooks": [hook]}]}}), flush=True)
""")
fake_codex.chmod(0o700)
for bad in ("command", "hash"):
    result = subprocess.run([sys.executable, str(worker), "launch", str(private), str(wt), str(fake_codex)],
                            env=dict(codex_env, FM_BAD_HOOK=bad), text=True, capture_output=True, timeout=10)
    assert result.returncode != 0, bad
    assert "state" not in tomllib.loads((private / "config.toml").read_text())["hooks"]
    assert not (private / "worker-executed").exists()
subprocess.run([sys.executable, str(worker), "remove", str(private)], check=True)
assert not private.exists()
assert (codex_source / "auth.json").is_fifo()
assert (codex_source / "rules/local.rules").exists()
for secret_config in ('[mcp_servers.private]\nargs=["--api-key", "fixture-sensitive-value"]\n',
                      '[mcp_servers.private.http_headers]\nAuthorization="fixture-sensitive-value"\n',
                      '[model_providers.private]\nexperimental_bearer_token="fixture-sensitive-value"\n',
                      '[mcp_servers.private]\nurl="https://user:fixture-sensitive-value@example.invalid"\n'):
    (codex_source / "config.toml").write_text(secret_config)
    result = subprocess.run([sys.executable, str(worker), "prepare", str(wt), str(state), "codex"],
                            env=codex_env, text=True, capture_output=True)
    assert result.returncode != 0
    assert "fixture-sensitive-value" not in result.stdout + result.stderr
    assert not private.exists()
# A nested source home must never be removed while regenerating the target.
nested = private / "original"
nested.mkdir(parents=True)
(nested / "config.toml").write_text('approval_policy="never"\n')
result = subprocess.run([sys.executable, str(worker), "prepare", str(wt), str(state), "codex"],
                        env=dict(os.environ, CODEX_HOME=str(nested)), text=True, capture_output=True)
assert result.returncode != 0
assert (nested / "config.toml").exists()
subprocess.run([sys.executable, str(worker), "remove", str(private)], check=True)
print("ok - Codex private setup preserves safety, references auth without reading, refuses inline secrets, cleans up links")

poly_hooks = wt / ".polytoken/hooks.json"
poly_hooks.parent.mkdir()
poly_hooks.write_text('[{"name":"fm-busy-stop","event":"stop","handler":{"bash":"/unused"}}]')
for _ in range(2):
    subprocess.run([sys.executable, str(install), "polytoken", str(wt), str(state), "t"], check=True)
poly = json.loads(poly_hooks.read_text())
assert len(poly) == 2 and poly[0]["name"] == "fm-busy-stop"
for name, args, expected in (("file_edit_search_replace", {"path": "vendor/basisone/a"}, 2),
                             ("shell", {"command": "git worktree prune"}, 2),
                             ("file_read", {"path": "vendor/basisone/a"}, 0)):
    result = subprocess.run([poly[1]["handler"]["bash"]], input=json.dumps({"tool_name": name, "input": args}),
                            text=True, capture_output=True)
    assert result.returncode == expected, result.stderr
    if expected == 0:
        assert json.loads(result.stdout) == {"outcome": "allow"}
print("ok - Polytoken no-argv handler blocks edits and worktree mutations, preserves lifecycle hooks")

node = shutil.which("node")
if not node or subprocess.run([node, "--experimental-strip-types", "-e", ""], capture_output=True).returncode:
    print("skip - generated native callbacks require Node with TypeScript stripping")
    sys.exit(0)

for harness in ("pi", "pi-signed", "omp", "opencode"):
    extension = state / f"t.{'omp' if harness == 'omp' else 'pi'}-ext.ts"
    extension.write_text("export default function (pi: any) {\n}\n")
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    module = wt / ".opencode/plugins/fm-worker-guardrails.js" if harness == "opencode" else extension
    first = module.read_bytes()
    subprocess.run([sys.executable, str(install), harness, str(wt), str(state), "t"], check=True)
    assert module.read_bytes() == first, f"{harness} repeated install changed the extension"
    subprocess.run([node, "--experimental-strip-types", "--input-type=module", "-", str(module), harness], input=r'''
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

subprocess.run([node, "--experimental-strip-types", "--input-type=module", "-", str(root)], input=r'''
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const mod = await import(pathToFileURL(root + '/bin/fm-commandcode-mod.ts'));
let hooks;
mod.default({addFlag: () => {}, on: () => {}, hooks: h => { hooks = h; },
  getFlag: name => name === 'fmWriter' ? root + '/bin/fm-busy-event.sh' : 'test'});
for (const [toolName, input, blocked] of [
  ['write', {path: 'vendor/basisone/x'}, true],
  ['shell_command', {command: 'git worktree prune'}, true],
  ['read', {path: 'vendor/basisone/x'}, false],
]) {
  const result = await hooks.beforeToolCall({toolName, input}, {cwd: root});
  if (Boolean(result?.block) !== blocked) throw Error('Command Code unexpected tool decision');
}
''', text=True, check=True)
print("ok - Command Code mutating hook blocks through its existing per-process mod")
PY
pass "worker guardrail executable policy and generated adapter callbacks"
