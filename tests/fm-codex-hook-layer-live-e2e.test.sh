#!/usr/bin/env bash
# Installed Codex hook discovery and enforcement, with a loopback Responses
# fixture, no credentials or provider tokens. Runs by default when installed.
# The fake Git executable makes a failing guard harmless to any real worktree.
# It also replays the Stop-output cases against the installed app-server.
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

test_installed_codex_accepts_the_stop_wrapper_and_rejects_invalid_output() {
  python3 - "$ROOT" "$TMP_ROOT/stop-parser" "$CODEX_VERSION" <<'PY'
import http.server
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time

root, lab, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
lab.mkdir()
wrapper = json.loads((root / '.codex/hooks.json').read_text())['hooks']['Stop'][0]['hooks'][0]['command']
emitter = lab / 'emit.py'
emitter.write_text('''import json,sys
mode=sys.argv[1]
active=json.load(sys.stdin).get('stop_hook_active',False)
outputs={
 'empty': ('','',0), 'json': ('{}\\n','',0),
 'mixed': ('diagnostic\\n{}\\n','',0), 'syntax': ('{','',0),
 'schema': ('{"continue":"yes"}','',0), 'two-objects': ('{}\\n{}','',0),
 'stderr': ('{}\\n','diagnostic\\n',0), 'error': ('','fixture error\\n',7)}
if mode=='continue':
 out,err,code=('', 'fixture continuation\\n', 2) if not active else ('{}\\n','',0)
else: out,err,code=outputs[mode]
sys.stdout.write(out);sys.stderr.write(err);sys.exit(code)
''')
primary = lab / 'primary'
for name in ['bin', 'state', 'docs', '.codex']:
    (primary / name).mkdir(parents=True, exist_ok=True)
(primary / 'AGENTS.md').write_text('Isolated Stop parser fixture.\n')
(primary / '.codex/hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [
    {'type': 'command', 'command': 'fm-turnend-guard.sh'}]}]}}))
for name in ['fm-turnend-guard.sh', 'fm-operational-input.sh', 'fm-supervision-instructions.sh',
             'fm-harness.sh', 'fm-primary-scope-lib.sh', 'fm-supervision-lib.sh',
             'fm-supervision-engine-lib.sh', 'fm-wake-lib.sh', 'fm-path-lib.sh',
             'fm-hook-host-lib.sh', 'fm-session-lock-lib.sh', 'fm-cursor-lib.sh',
             'fm-hermes-process-lib.sh', 'fm-timeout-lib.sh']:
    shutil.copy2(root / 'bin' / name, primary / 'bin' / name)
shutil.copytree(root / 'docs/supervision-protocols', primary / 'docs/supervision-protocols')
subprocess.run(['git', 'init', '-q', str(primary)], check=True)

class Responses(http.server.BaseHTTPRequestHandler):
    requests = 0

    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        Responses.requests += 1
        message = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant',
                   'status': 'completed', 'phase': 'final_answer', 'content': [
                       {'type': 'output_text', 'text': 'fixture complete', 'annotations': []}]}
        events = [
            {'type': 'response.created', 'response': {'id': 'resp_fixture', 'status': 'in_progress', 'output': []}},
            {'type': 'response.output_item.added', 'output_index': 0,
             'item': {**message, 'status': 'in_progress', 'content': []}},
            {'type': 'response.output_item.done', 'output_index': 0, 'item': message},
            {'type': 'response.completed', 'response': {'id': 'resp_fixture', 'status': 'completed',
             'output': [message], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}},
        ]
        data = ''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n'
                       for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Responses)
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()

def check(mode, expected):
    case = lab / mode
    case.mkdir()
    fixture_home = case / 'login'
    fixture_home.mkdir()
    (fixture_home / '.bash_profile').write_text(':\n')
    (fixture_home / '.bash_logout').write_text("printf '\\033[H\\033[2J\\033[3J'\n")
    codex_data = case / 'codex'
    codex_data.mkdir()
    command = wrapper if mode.startswith('wrapper-') else shlex.join([sys.executable, str(emitter), mode])
    (codex_data / 'hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [
        {'type': 'command', 'command': command, 'timeout': 10}]}]}}))
    (codex_data / 'config.toml').write_text(f'''model="fixture"
model_provider="fixture"
[model_providers.fixture]
name="Loopback Stop fixture"
base_url="http://127.0.0.1:{server.server_port}/v1"
wire_api="responses"
requires_openai_auth=false
[features]
hooks=true
shell_snapshot=false
[analytics]
enabled=false
''')
    # Keep the inherited PATH, but no operator config, tokens, hook startup
    # overrides, or fleet paths enter the child app-server or its hooks.
    env = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL', 'DISABLE_AUTOUPDATER'] if key in os.environ}
    env.update({'HOME': str(fixture_home), 'CODEX_HOME': str(codex_data),
                'SHELL': '/bin/sh', 'TMPDIR': str(lab), 'OTEL_SDK_DISABLED': 'true'})
    cwd = primary if mode in ['wrapper-idle', 'wrapper-block'] else case
    (primary / 'state/task.meta').unlink(missing_ok=True)
    if mode == 'wrapper-block':
        (primary / 'state/task.meta').touch()
    notifications = []
    messages = queue.Queue()
    deadline = time.monotonic() + 40
    before = Responses.requests
    with (case / 'stderr').open('w') as stderr:
        process = subprocess.Popen(['codex', 'app-server', '--stdio'], cwd=case, env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
        def read_lines():
            for line in process.stdout:
                messages.put(json.loads(line))
            messages.put(None)
        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        def send(message):
            process.stdin.write(json.dumps(message) + '\n')
            process.stdin.flush()
        def receive():
            message = messages.get(timeout=max(0.1, deadline - time.monotonic()))
            assert message is not None, 'app-server exited before its hook verdict'
            notifications.append(message)
            return message
        def rpc(number, method, params):
            send({'id': number, 'method': method, 'params': params})
            while True:
                message = receive()
                if message.get('id') == number:
                    assert 'error' not in message, message
                    return message['result']
        try:
            rpc(1, 'initialize', {'clientInfo': {'name': 'isolated-stop-test', 'version': '1'},
                                 'capabilities': {'experimentalApi': True}})
            send({'method': 'initialized'})
            listed = rpc(2, 'hooks/list', {'cwds': [str(case)]})
            hooks = [hook for entry in listed['data'] for hook in entry['hooks']
                     if hook['eventName'] == 'stop' and hook['sourcePath'] == str(codex_data / 'hooks.json')]
            assert len(hooks) == 1, listed
            hook = hooks[0]
            thread = rpc(3, 'thread/start', {'cwd': str(cwd), 'model': 'fixture', 'modelProvider': 'fixture',
                'approvalPolicy': 'never', 'sandbox': 'read-only', 'ephemeral': True,
                'config': {'hooks.state': {hook['key']: {'trusted_hash': hook['currentHash']}}}})
            rpc(4, 'turn/start', {'threadId': thread['thread']['id'],
                                 'input': [{'type': 'text', 'text': 'fixture', 'text_elements': []}]})
            while receive().get('method') != 'turn/completed':
                pass
            runs = [message['params']['run'] for message in notifications
                    if message.get('method') == 'hook/completed' and message['params']['run']['eventName'] == 'stop']
            assert [run['status'] for run in runs] == expected, (mode, runs)
            assert Responses.requests - before == len(expected), (mode, Responses.requests - before)
            if mode in ['mixed', 'syntax', 'schema', 'two-objects']:
                assert runs[0]['entries'] == [{'kind': 'error', 'text': 'hook returned invalid stop hook JSON output'}], runs
            if mode == 'error':
                assert runs[0]['entries'] == [{'kind': 'error', 'text': 'hook exited with code 7'}], runs
            if mode == 'wrapper-block':
                assert any('TURN WOULD END BLIND' in entry['text'] for entry in runs[0]['entries']), runs
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            reader.join(timeout=1)

try:
    for mode in ['empty', 'json', 'stderr', 'wrapper-noop', 'wrapper-idle']:
        check(mode, ['completed'])
    for mode in ['mixed', 'syntax', 'schema', 'two-objects', 'error']:
        check(mode, ['failed'])
    for mode in ['continue', 'wrapper-block']:
        check(mode, ['blocked', 'completed'])
    print(f'ok - codex {version}: Stop parser checked 12 isolated cases with clean wrapper JSON and bounded continuation')
except Exception as error:
    raise SystemExit(f'not ok - codex {version}: isolated Stop parser failed: {error!r}') from error
finally:
    server.shutdown()
    server.server_close()
    server_thread.join()
PY
  local status=$?
  [ "$status" -eq 0 ] || fail "codex $CODEX_VERSION: installed Stop parser regression failed"
}

# Upstream's Stop-output parser guard, kept beside this fork's worker-guard replay.
test_installed_codex_accepts_the_stop_wrapper_and_rejects_invalid_output || exit 1
echo '# all fm-codex-hook-layer-live-e2e tests passed'
