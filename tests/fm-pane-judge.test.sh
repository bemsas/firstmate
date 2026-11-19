#!/usr/bin/env bash
# bin/fm-pane-judge.py behavior, driven through its public subcommands.
#
# The model endpoint is a local loopback stand-in with OpenRouter's catalog and
# chat-completions shapes; it logs every request body so the tests can prove
# what was (and was not) sent. Herdr is a PATH stand-in that logs every call, so
# the exclusion and pane-identity tests can prove which panes were never read.
#   1. Tier-1 gate: only idle-with-unmet-DoD and long-silent-working-without-
#      build-CPU escalate; active builds, declared waits, met DoD, and unknown
#      facts settle without the model; missing old or new snapshot fields are safe.
#   2. Request shape: a byte-stable cached system prefix of at least 512 tokens,
#      a bounded suffix that keeps the newest pane lines, and redaction before send.
#   3. Verdict contract, unchanged-input dedupe, confidence hysteresis, the
#      contradiction filter, and the shell-only PID override.
#   4. Budget: shared lock with atomic reservations under concurrency, the daily
#      spend cap, the per-lane call cap, and fail-closed ledger, credential, and
#      capability uncertainty.
#   5. Collection: Venipak and non-worker metadata are excluded before any pane
#      or repository read, and a pane outside its task worktree is never read.
#   6. Shadow run manifests and the outcome summary's ground-truth rules.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JUDGE="$ROOT/bin/fm-pane-judge.py"
TMP_ROOT=$(fm_test_tmproot fm-pane-judge)
SECRET_KEY='or-test-KEYVALUE-7f3a9c1e5b'

# mksnap KEY=JSON...: print one snapshot line. The base is an idle ship lane
# whose DoD is unmet (two dirty files); dotted keys override nested fields and
# the value DELETE removes a key.
cat > "$TMP_ROOT/mksnap.py" <<'PY'
import json, sys
snap = {'schema': 'fm-pane-judge.snapshot.v1', 'observed_at': 1795000000, 'host': 'desktop', 'home': 'ops-mate',
        'home_path': '/x/home', 'task': 't1', 'kind': 'ship', 'mode': 'no-mistakes', 'harness': 'claude',
        'branch': 'fm/t1', 'base_branch': None, 'pr_url': None, 'last_event': {'verb': 'working', 'at': 1794990000},
        'status_tail': ['working [at=1794990000]: started'],
        'busy': {'state': 'idle', 'event': 'stop', 'source': 'claude-hook', 'ts': 1794999000},
        'agent': {'status': 'idle', 'focused': False, 'seq': 41, 'seq_source': 'herdr_state_change_seq'},
        'pane_reason': None,
        'process': {'shell_pid': 10, 'shell_only': False, 'harness_alive': True, 'foreground': ['claude'],
                    'foreground_pids': [11], 'build_procs': [], 'build_cpu_ticks': 0, 'build_cpu_active': False},
        'pane_tail': ['line %d' % i for i in range(80)], 'pane_sha': 'p0',
        'git': {'head': 'a' * 40, 'dirty_files': 2, 'upstream': None, 'unpushed_commits': None,
                'commits_ahead_of_base': 1, 'base_ref': 'origin/main', 'last_commit_ts': 1794990000},
        'report_exists': False, 'brief_dod': 'Push the branch and open a PR.', 'tool_ring': None,
        'silence_seconds': None}
for arg in sys.argv[1:]:
    path, _, raw = arg.partition('=')
    keys, node = path.split('.'), snap
    for key in keys[:-1]:
        node = node.setdefault(key, {})
    if raw == 'DELETE':
        node.pop(keys[-1], None)
    else:
        node[keys[-1]] = json.loads(raw)
print(json.dumps(snap))
PY

mksnap() { python3 "$TMP_ROOT/mksnap.py" "$@"; }

# The loopback model stand-in. ANSWER_FILE holds the JSON answer content (or
# the word FAIL for an HTTP 500); CATALOG_FILE overrides /models; DELAY slows
# each completion so concurrent reservations overlap.
cat > "$TMP_ROOT/stub.py" <<'PY'
import http.server, json, os, sys, threading, time
port_file, log = sys.argv[1], sys.argv[2]
models = [{'id': m, 'supported_parameters': ['response_format', 'structured_outputs'],
           'pricing': {'prompt': '0.0000001', 'completion': '0.0000005'}}
          for m in ('anthropic/claude-haiku-5.5', 'openai/gpt-5-nano')]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        catalog = os.environ.get('CATALOG_FILE')
        data = json.load(open(catalog)) if catalog and os.path.exists(catalog) else {'data': models}
        self.reply(200, data)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(log, 'a') as fh:
            fh.write(json.dumps({'auth': self.headers.get('Authorization'), 'body': body}) + '\n')
        time.sleep(float(os.environ.get('DELAY', '0')))
        answer = open(os.environ['ANSWER_FILE']).read().strip()
        if answer == 'FAIL':
            return self.reply(500, {'error': {'message': 'boom'}})
        self.reply(200, {'model': body['model'], 'choices': [{'finish_reason': 'stop', 'message': {'content': answer}}],
                         'usage': {'prompt_tokens': 2400, 'completion_tokens': 40, 'cost': 0.0003,
                                   'prompt_tokens_details': {'cached_tokens': 1100}}})
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(port_file, 'w').write(str(server.server_address[1]))
threading.Timer(float(os.environ.get('LIFETIME', '120')), server.shutdown).start()
server.serve_forever()
PY

STUB_PID=''
stub_start() {  # <dir>
  local dir=$1 i
  : > "$dir/requests.jsonl"
  ANSWER_FILE="$dir/answer.json" CATALOG_FILE="$dir/catalog.json" DELAY="${STUB_DELAY:-0}" \
    python3 "$TMP_ROOT/stub.py" "$dir/port" "$dir/requests.jsonl" &
  STUB_PID=$!
  for i in $(seq 1 100); do [ -s "$dir/port" ] && break; sleep 0.05; done
  [ -s "$dir/port" ] || fail "model stand-in did not start"
}
stub_stop() { [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=''; }; }

world() {  # <name> -> echoes a fresh directory with credentials and state
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/pj"
  printf 'OTHER=1\nOPENROUTER_API_KEY=%s\n' "$SECRET_KEY" > "$dir/env"
  printf '%s\n' "$dir"
}

answer() {  # <dir> <label> <confidence> [evidence] | <dir> FAIL
  [ "$2" != FAIL ] || { printf 'FAIL\n' > "$1/answer.json"; return; }
  printf '{"label":"%s","confidence":%s,"evidence":"%s"}\n' "$2" "$3" "${4:-pane shows the agent stopped}" > "$1/answer.json"
}

judge_in() {  # <dir> <judge args...>; snapshots on stdin
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_PANE_JUDGE_STATE_DIR="$dir/pj" FM_PANE_JUDGE_ENV_FILE="$dir/env" \
    FM_PANE_JUDGE_API_BASE="http://127.0.0.1:$(cat "$dir/port" 2>/dev/null || echo 9)" python3 "$JUDGE" "$@"
}

requests() { wc -l < "$1/requests.jsonl" | tr -d ' '; }
verdicts() { cat "$1/home/state/pane-judge-shadow.jsonl" 2>/dev/null; }
last_verdict() { verdicts "$1" | tail -1; }
field() { python3 -c 'import json,sys; v=json.loads(sys.stdin.read()); print(json.dumps(eval(sys.argv[1], {"v": v})))' "$1"; }

gate_of() { python3 "$JUDGE" gate | field 'v["reason"]' | tr -d '"'; }

test_gate_classes() {
  local r
  r=$(mksnap | gate_of); [ "$r" = idle-unmet-dod ] || fail "idle with dirty files escalates (got $r)"
  r=$(mksnap process.build_cpu_active=true | gate_of); [ "$r" = active-build ] || fail "active build settles first (got $r)"
  r=$(mksnap git.dirty_files=0 pr_url='"https://github.com/o/r/pull/7"' | gate_of)
  [ "$r" = idle-dod-met ] || fail "PR plus clean tree is met (got $r)"
  r=$(mksnap git=null | gate_of); [ "$r" = idle-dod-unknown ] || fail "unknown git never infers unmet (got $r)"
  r=$(mksnap git.dirty_files=null git.commits_ahead_of_base=null | gate_of)
  [ "$r" = idle-dod-unknown ] || fail "null git facts stay unknown (got $r)"
  r=$(mksnap last_event='{"verb":"paused","at":1794998990}' | gate_of)
  [ "$r" = declared:paused ] || fail "a declared wait settles (got $r)"
  r=$(mksnap last_event='{"verb":"paused","at":1794990000}' busy.ts=1794999000 | gate_of)
  [ "$r" = idle-unmet-dod ] || fail "a wait the hook proves stale does not settle (got $r)"
  r=$(mksnap kind='"scout"' | gate_of); [ "$r" = idle-unmet-dod ] || fail "idle scout without report escalates (got $r)"
  r=$(mksnap kind='"scout"' report_exists=true | gate_of); [ "$r" = idle-dod-met ] || fail "scout report is met (got $r)"
  r=$(mksnap kind='"secondmate"' | gate_of); [ "$r" = not-a-worker-lane ] || fail "secondmates are never judged (got $r)"
  r=$(mksnap mode='"local-only"' git.dirty_files=0 git.commits_ahead_of_base=2 | gate_of)
  [ "$r" = idle-dod-met ] || fail "clean committed local-only branch is met (got $r)"
  local working=('agent.status="working"' 'busy.state="busy"')
  r=$(mksnap "${working[@]}" silence_seconds=400 | gate_of)
  [ "$r" = silent-working ] || fail "silent working without build CPU escalates (got $r)"
  r=$(mksnap "${working[@]}" silence_seconds=400 process.build_cpu_active=null | gate_of)
  [ "$r" = working ] || fail "unknown build CPU never escalates a working lane (got $r)"
  r=$(mksnap "${working[@]}" silence_seconds=200 | gate_of); [ "$r" = working ] || fail "short silence is working (got $r)"
  r=$(mksnap "${working[@]}" silence_seconds=900 process.build_cpu_active=true | gate_of)
  [ "$r" = active-build ] || fail "a silent build is never classified (got $r)"
  r=$(mksnap agent=DELETE busy=DELETE process=DELETE git=DELETE last_event=DELETE pane_tail=DELETE \
    tool_ring='[{"ts":1,"tool":"Bash","new_field":true}]' completion_seq=7 | gate_of)
  [ "$r" = activity-unknown ] || fail "missing old fields and unknown new fields stay unknown (got $r)"
  pass "Tier-1 gate escalates only the two ambiguity classes and keeps unknowns unknown"
}

test_request_shape_and_redaction() {
  local a b secrets out
  a=$(mksnap | python3 "$JUDGE" render)
  b=$(mksnap task='"other"' pane_tail='["x"]' git.dirty_files=9 | python3 "$JUDGE" render)
  python3 - "$a" "$b" <<'PY' || fail "system prefix is not a stable cached block of at least 512 tokens"
import json, sys
a, b = (json.loads(x) for x in sys.argv[1:3])
sa, sb = a['messages'][0], b['messages'][0]
assert json.dumps(sa, sort_keys=True) == json.dumps(sb, sort_keys=True)
part = sa['content'][0]
assert part['cache_control'] == {'type': 'ephemeral'}
# 512 tokens even at a generous five characters per token.
assert len(part['text']) >= 2560, len(part['text'])
assert a['response_format']['json_schema']['strict'] is True
assert a['response_format']['json_schema']['schema']['properties']['label']['enum'] == [
    'working', 'finished', 'needs-nudge', 'stalled:loop', 'stalled:blocked', 'needs-restart']
assert a['max_tokens'] <= 160 and a['provider']['require_parameters'] is True
# Default thinking would spend the whole output cap before any JSON appears.
assert a['reasoning'] == {'enabled': False}
# require_parameters routes only to providers supporting every sent parameter,
# and the live catalog lists no sampling temperature for either model.
assert set(a) <= {'model', 'messages', 'response_format', 'stream', 'provider', 'max_tokens', 'reasoning'}, sorted(a)
PY
  out=$(mksnap pane_tail="$(python3 -c 'import json; print(json.dumps(["noise %05d " % i + "x" * 150 for i in range(400)]))')" \
    | python3 "$JUDGE" render)
  python3 - "$out" <<'PY' || fail "suffix is not bounded to the newest pane lines"
import json, sys
body = json.loads(sys.argv[1])
suffix = json.loads(body['messages'][1]['content'])
assert len(body["messages"][1]["content"]) <= 4200 + 200, len(body['messages'][1]['content'])
assert suffix['pane_tail'][-1].startswith('noise 00399'), suffix['pane_tail'][-1]
assert not any(l.startswith('noise 00000') for l in suffix['pane_tail'])
PY
  secrets='["token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx", "git remote https://bob:hunter2pass@github.com/o/r",
    "Authorization: Bearer abcdefghijklmnop0123456789", "password = correct-horse-battery", "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "-----BEGIN RSA PRIVATE KEY-----", "MIIEpAIBAAKCAQEA", "-----END RSA PRIVATE KEY-----", "AKIAABCDEFGHIJKLMNOP"]'
  out=$(mksnap pane_tail="$secrets" status_tail='["done: key sk-live-0123456789abcdefghij"]' | python3 "$JUDGE" render)
  for leak in eyJhbGciOiJIUzI1NiJ9 sk-proj-abcdef hunter2pass abcdefghijklmnop0123456789 correct-horse \
    ghp_abcdef MIIEpAIBAAKCAQEA AKIAABCDEFGHIJKLMNOP sk-live-0123; do
    case "$out" in *"$leak"*) fail "redaction leaked $leak into the request" ;; esac
  done
  case "$out" in *'[REDACTED]'*) ;; *) fail "redaction marker missing" ;; esac
  pass "request keeps a byte-stable cached rubric prefix, a bounded newest-first suffix, and redacts secrets"
}

test_verdict_contract_and_dedupe() {
  local dir row
  dir=$(world contract)
  stub_start "$dir"
  answer "$dir" needs-nudge 0.9 "stopped with 2 dirty files; key $SECRET_KEY password=hunter2pass"
  mksnap | judge_in "$dir" judge --shadow >/dev/null || fail "judge failed"
  [ "$(requests "$dir")" = 1 ] || fail "ambiguous lane should cost exactly one call"
  row=$(last_verdict "$dir")
  python3 - "$row" <<'PY' || fail "verdict row does not match the v1 contract"
import json, sys
v = json.loads(sys.argv[1])
assert v['schema'] == 'fm-pane-judge.verdict.v1'
assert set(v) == {'schema', 'ts', 'at', 'task', 'host', 'home', 'home_path', 'lane', 'kind', 'mode', 'seq',
                  'seq_source', 'gate', 'label', 'confidence', 'model_label', 'model_confidence', 'evidence',
                  'filters', 'skip', 'shadow', 'advisory', 'model', 'cost_usd', 'cost_source', 'usage',
                  'input_sha', 'facts'}, sorted(v)
assert v['task'] == 't1' and v['lane'] == 'desktop:ops-mate:t1' and v['seq'] == 41
assert v['seq_source'] == 'herdr_state_change_seq' and v['gate'] == 'idle-unmet-dod'
assert v['label'] == 'needs-nudge' and v['confidence'] == 0.9 and v['filters'] == []
assert v['shadow'] is True and v['advisory'] is True and v['skip'] is None
assert v['model'] == 'anthropic/claude-haiku-5.5' and v['cost_usd'] == 0.0003 and v['cost_source'] == 'reported'
assert v['usage']['cached_tokens'] == 1100
assert '[REDACTED]' in v['evidence'] and 'hunter2pass' not in v['evidence']
PY
  if grep -q "$SECRET_KEY" "$dir/home/state/pane-judge-shadow.jsonl" "$dir/pj/ledger.json"; then
    fail "credential value reached a log"
  fi
  grep -q "\"auth\": \"Bearer $SECRET_KEY\"" "$dir/requests.jsonl" || fail "credential was not sent as the bearer token"
  mksnap | judge_in "$dir" judge --shadow | grep -q '"skip:unchanged":1' || fail "unchanged input is not re-judged"
  [ "$(requests "$dir")" = 1 ] || fail "unchanged input spent another call"
  mksnap pane_sha='"p1"' | judge_in "$dir" judge --shadow >/dev/null
  [ "$(requests "$dir")" = 2 ] || fail "changed pane should be re-judged"
  mksnap | judge_in "$dir" judge >/dev/null 2>&1 && fail "judge without --shadow must refuse"
  stub_stop
  pass "verdict rows follow the v1 contract, stay advisory shadow rows, never log the key, and dedupe unchanged input"
}

test_hysteresis_contradiction_and_pid_override() {
  local dir v
  dir=$(world filters)
  stub_start "$dir"
  answer "$dir" needs-nudge 0.70
  mksnap pane_sha='"a"' | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field '[v["label"], v["filters"]]')
  [ "$v" = '["unknown", ["hysteresis:below-threshold"]]' ] || fail "low confidence must not emit a label ($v)"
  answer "$dir" needs-nudge 0.90
  mksnap pane_sha='"b"' | judge_in "$dir" judge --shadow >/dev/null
  answer "$dir" needs-nudge 0.65
  mksnap pane_sha='"c"' | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field '[v["label"], v["filters"]]')
  [ "$v" = '["needs-nudge", ["hysteresis:held"]]' ] || fail "same label above the hold band is held ($v)"
  answer "$dir" stalled:loop 0.70
  mksnap pane_sha='"d"' | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field 'v["label"]')
  [ "$v" = '"unknown"' ] || fail "a different label needs the entry threshold ($v)"
  answer "$dir" finished 0.95
  mksnap pane_sha='"e"' | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field '[v["label"], v["model_label"], v["filters"]]')
  [ "$v" = '["unknown", "finished", ["contradiction:finished-vs-unmet-dod"]]' ] || fail "finished vs unmet DoD ($v)"
  answer "$dir" needs-restart 0.95
  mksnap pane_sha='"f"' | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field '[v["label"], v["filters"]]')
  [ "$v" = '["unknown", ["contradiction:restart-vs-live-or-unknown-harness"]]' ] || fail "restart vs live harness ($v)"
  mksnap pane_sha='"g"' process.shell_only=null | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field 'v["label"]')
  [ "$v" = '"unknown"' ] || fail "restart with unknown process facts must not emit ($v)"
  answer "$dir" needs-nudge 0.9
  mksnap pane_sha='"h"' process.shell_only=true process.harness_alive=false | judge_in "$dir" judge --shadow >/dev/null
  v=$(last_verdict "$dir" | field '[v["label"], v["model_label"], v["filters"]]')
  [ "$v" = '["needs-restart", "needs-nudge", ["pid-override:shell-only"]]' ] || fail "bare shell cannot take a nudge ($v)"
  answer "$dir" needs-restart 0.99
  mksnap pane_sha='"i"' process.build_cpu_active=true | judge_in "$dir" judge --shadow >/dev/null
  mksnap pane_sha='"j"' agent.status='"working"' busy.state='"busy"' silence_seconds=4000 \
    process.build_cpu_active=true | judge_in "$dir" judge --shadow >/dev/null
  [ "$(requests "$dir")" = 8 ] || fail "an active build must never reach the model"
  verdicts "$dir" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert not [r for r in rows if r["label"] == "needs-restart" and r["facts"]["build_cpu_active"]]
' || fail "restart emitted on an active build"
  stub_stop
  pass "confidence hysteresis, the contradiction filter, and the PID override keep doubtful labels from emitting"
}

test_budget_lock_and_fail_closed() {
  local dir res i calls day pids
  dir=$(world budget)
  STUB_DELAY=2 stub_start "$dir"
  answer "$dir" needs-nudge 0.9
  day=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))')
  res=$(mksnap | python3 "$JUDGE" render | python3 -c 'import sys; b=sys.stdin.read().strip(); print((len(b.encode())+512)*0.2e-6+160*1e-6)')
  python3 - "$dir/pj/ledger.json" "$day" "$res" <<'PY'
import json, sys
path, day, res = sys.argv[1], sys.argv[2], float(sys.argv[3])
json.dump({'days': {day: {'spent_usd': 0.5 - 3.5 * res, 'calls': {'desktop:ops-mate:busy': 40}, 'reserved': {}}}},
          open(path, 'w'))
PY
  pids=''
  for i in 1 2 3 4 5 6 7 8; do
    mksnap task="\"lane$i\"" | judge_in "$dir" judge --shadow >/dev/null &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids
  calls=$(requests "$dir")
  [ "$calls" -le 3 ] && [ "$calls" -ge 1 ] || fail "concurrent judges overspent the shared cap ($calls calls)"
  [ "$(verdicts "$dir" | grep -c '"skip":"daily-spend-cap"')" = $((8 - calls)) ] || fail "every refused lane records the cap"
  python3 - "$dir/pj/ledger.json" "$day" <<'PY' || fail "ledger exceeds the daily cap or keeps reservations"
import json, sys
day = json.load(open(sys.argv[1]))['days'][sys.argv[2]]
assert day['reserved'] == {} and day['spent_usd'] < 0.5, day
PY
  mksnap task='"busy"' | judge_in "$dir" judge --shadow >/dev/null
  last_verdict "$dir" | grep -q '"skip":"lane-call-cap"' || fail "a lane at 40 calls must be refused"
  [ "$(requests "$dir")" = "$calls" ] || fail "a capped lane must not call the model"
  stub_stop
  dir=$(world failclosed)
  stub_start "$dir"
  answer "$dir" needs-nudge 0.9
  printf 'not json' > "$dir/pj/ledger.json"
  mksnap | judge_in "$dir" judge --shadow >/dev/null
  last_verdict "$dir" | grep -q '"skip":"budget-ledger-unreadable"' || fail "unreadable ledger must refuse"
  rm -f "$dir/pj/ledger.json"
  printf 'OPENROUTER_MODEL=x\n' > "$dir/env"
  mksnap pane_sha='"k"' | judge_in "$dir" judge --shadow >/dev/null
  last_verdict "$dir" | grep -q '"skip":"credential-unavailable"' || fail "missing credential must refuse"
  printf 'OPENROUTER_API_KEY=%s\n' "$SECRET_KEY" > "$dir/env"
  printf '{"data":[{"id":"anthropic/claude-haiku-5.5","supported_parameters":["response_format","structured_outputs"],"pricing":{"prompt":"0.000003","completion":"0.000015"}}]}' > "$dir/catalog.json"
  mksnap pane_sha='"l"' | judge_in "$dir" judge --shadow >/dev/null
  last_verdict "$dir" | grep -q '"skip":"capability-unverified:openai/gpt-5-nano"' || fail "unverified catalog must refuse"
  [ "$(requests "$dir")" = 0 ] || fail "fail-closed paths must not call the model"
  rm -f "$dir/catalog.json"
  answer "$dir" FAIL
  mksnap pane_sha='"m"' | judge_in "$dir" judge --shadow >/dev/null
  [ "$(requests "$dir")" = 2 ] || fail "a failed primary call tries the fallback once"
  last_verdict "$dir" | grep -q '"cost_source":"reservation"' || fail "a call without a reported cost keeps its reservation"
  printf 'not json\n' > "$dir/answer.json"
  mksnap pane_sha='"n"' | judge_in "$dir" judge --shadow >/dev/null
  last_verdict "$dir" | grep -q '"cost_source":"reported","cost_usd":0.0006,' ||
    fail "an invalid but billed answer records its reported cost"
  last_verdict "$dir" | grep -q '"label":"unknown"' || fail "an invalid answer must not emit a label"
  stub_stop
  pass "shared lock and atomic reservations hold the daily and per-lane caps and every uncertainty fails closed"
}

fake_herdr() {  # <bin-dir> <log> <worktree-for-pane-cwd>
  mkdir -p "$1"
  cat > "$1/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$2'
case "\$*" in
  *"agent get"*) pane=\${*: -1}; printf '{"result":{"agent":{"pane_id":"%s","agent_status":"idle","cwd":"$3","focused":false,"state_change_seq":5,"completion_seq":77}}}\n' "\$pane" ;;
  *"process-info"*) pane=\${*: -1}; printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":999999,"foreground_process_group_id":999998,"foreground_processes":[{"pid":999998,"name":"claude"}]}}}\n' "\$pane" ;;
  *"pane read"*) printf 'agent output\nAPI_TOKEN=abcd1234efgh\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/herdr"
}

test_collection_exclusion_and_identity() {
  local dir home wt out
  dir=$(world collect)
  home="$dir/fleet"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/ok" "$wt"
  fm_git_init_commit "$wt" >/dev/null 2>&1 || fail "git fixture failed"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:p1\nproject=/p/app\n' "$wt" > "$home/state/ok.meta"
  printf 'kind=ship\nworktree=%s\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:pV\nproject=/p/Venipak-4h\n' "$wt" > "$home/state/v1.meta"
  printf 'kind=ship\nworktree=%s\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:pW\nbranch=fm/veni-recon\n' "$wt" > "$home/state/v2.meta"
  printf 'kind=secondmate\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:pS\n' > "$home/state/mate.meta"
  printf 'kind=ship\nworktree=%s/elsewhere\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:pX\n' "$dir" > "$home/state/moved.meta"
  printf 'done [at=1]: shipped, secret=abc123def456\n' > "$home/state/ok.status"
  fake_herdr "$dir/bin" "$dir/herdr.log" "$wt"
  out=$(PATH="$dir/bin:$PATH" python3 "$JUDGE" collect-local --host desktop --home "fleet=$home")
  grep -q 'w1:pV\|w1:pW\|w1:pS' "$dir/herdr.log" && fail "excluded or non-worker panes were queried"
  grep -q 'pane read w1:pX' "$dir/herdr.log" && fail "a pane outside its task worktree was read"
  grep -q 'pane read w1:p1' "$dir/herdr.log" || fail "the authorized pane was not read"
  printf '%s\n' "$out" | grep -q '"excluded-task":2' || fail "Venipak lanes not reported as excluded"
  printf '%s\n' "$out" | grep -q '"not-a-worker-lane":1' || fail "secondmate not skipped"
  printf '%s\n' "$out" | grep -q '"pane_reason":"pane-identity-mismatch"' || fail "moved pane not refused"
  case "$out" in *abc123def456*|*abcd1234efgh*) fail "collection leaked a secret" ;; esac
  case "$out" in *[Vv]enipak*|*veni-recon*) fail "excluded metadata leaked into snapshots" ;; esac
  printf '%s\n' "$out" | grep '"task":"ok"' | grep -q '"shell_only":false' || fail "process facts missing"
  printf '%s\n' "$out" | grep '"task":"ok"' | grep -q '"seq":77,"seq_source":"completion_seq"' ||
    fail "Herdr completion_seq must outrank state_change_seq"
  pass "collection excludes Venipak and non-worker metadata before any read and never reads a foreign pane"
}

test_shadow_manifests_and_summary() {
  local dir home rc
  dir=$(world shadow)
  home="$dir/main"
  mkdir -p "$home/state" "$home/data"
  printf -- '- ops-mate - Ops. (home: %s/mate; scope: ops; added 2026-11-13)\n- far - Mac. (host: other-mac; home: /x; scope: y)\n- venipak-mate - V. (host: main-ts; home: /v; scope: z)\n' "$dir" > "$home/data/secondmates.md"
  mkdir -p "$dir/mate/state"
  stub_start "$dir"
  answer "$dir" needs-nudge 0.9
  printf '' > "$dir/env"
  FM_HOME="$dir/home" FM_PANE_JUDGE_STATE_DIR="$dir/pj" FM_PANE_JUDGE_ENV_FILE="$dir/env" \
    FM_PANE_JUDGE_API_BASE="http://127.0.0.1:$(cat "$dir/port")" python3 "$JUDGE" shadow \
    --registry "$home/data/secondmates.md" --main-home "$home" --hosts desktop --duration 60 --interval 1 \
    --manifest-dir "$dir/m" >/dev/null && fail "shadow must refuse to start without a credential"
  [ -e "$dir/m/manifest-start.json" ] && fail "a failed preflight must not write a start manifest"
  grep -q '"exit_reason": "preflight-failed"' "$dir/m/manifest-end.json" || fail "preflight failure not recorded"
  printf 'OPENROUTER_API_KEY=%s\n' "$SECRET_KEY" > "$dir/env"
  FM_HOME="$dir/home" FM_PANE_JUDGE_STATE_DIR="$dir/pj" FM_PANE_JUDGE_ENV_FILE="$dir/env" \
    FM_PANE_JUDGE_API_BASE="http://127.0.0.1:$(cat "$dir/port")" python3 "$JUDGE" shadow \
    --registry "$home/data/secondmates.md" --main-home "$home" --hosts desktop --duration 60 --interval 1 \
    --manifest-dir "$dir/m" --max-cycles 1 >/dev/null
  rc=$?
  stub_stop
  [ "$rc" = 0 ] || fail "shadow run failed"
  python3 - "$dir/m" "$home" "$dir" <<'PY' || fail "shadow manifests are incomplete"
import json, sys
m, home, base = sys.argv[1:4]
start = json.load(open(m + '/manifest-start.json'))
end = json.load(open(m + '/manifest-end.json'))
assert start['phase'] == 'start' and start['preflight']['credential'] is True
assert start['homes'] == {'desktop': [['main', home], ['ops-mate', base + '/mate']]}, start['homes']
assert start['script_sha256'] and start['started_at_iso'].endswith('Z') and start['daily_usd_cap'] == 0.5
assert end['exit_reason'] == 'max-cycles' and end['cycles'] == 1
PY
  python3 - "$dir/v.jsonl" "$dir/o.jsonl" <<'PY'
import json, sys
v, o = open(sys.argv[1], 'w'), open(sys.argv[2], 'w')
for i in range(25):
    label = 'needs-nudge' if i < 22 else 'working'
    v.write(json.dumps({'schema': 'fm-pane-judge.verdict.v1', 'lane': 'h:m:t%d' % i, 'ts': 1000,
                        'label': label, 'model_label': label, 'facts': {}}) + '\n')
    if i < 21:
        o.write(json.dumps({'schema': 'fm-pane-judge.outcome.v1', 'lane': 'h:m:t%d' % i, 'ts': 1100,
                            'label': 'needs-nudge', 'labeler': 'vm-build-mate'}) + '\n')
o.write(json.dumps({'schema': 'fm-pane-judge.outcome.v1', 'lane': 'h:m:t22', 'ts': 1100, 'label': 'needs-nudge'}) + '\n')
PY
  printf '{"started_at": 1000, "started_at_iso": "x"}' > "$dir/m/manifest-start.json"
  printf '{"started_at": 1000, "elapsed_seconds": 86400, "exit_reason": "duration-complete"}' > "$dir/m/manifest-end.json"
  python3 "$JUDGE" summary --verdicts "$dir/v.jsonl" --outcomes "$dir/o.jsonl" --manifest-dir "$dir/m" > "$dir/s.json"
  python3 - "$dir/s.json" <<'PY' || fail "summary must not count unlabelled cases as agreement"
import json, sys
s = json.load(open(sys.argv[1]))
assert s['labelled_matches'] == 21 and s['agreement'] == 1.0, s
assert s['unlabelled_confident_verdicts'] == 4 and s['shadow_gate'] == 'pass', s
PY
  python3 "$JUDGE" summary --verdicts "$dir/v.jsonl" --outcomes "$dir/o.jsonl" --manifest-dir "$dir/m" \
    --min-labelled 22 | grep -q '"shadow_gate": "insufficient-ground-truth"' || fail "too few labels must not pass"
  printf '{"started_at": 1000, "elapsed_seconds": 86399}' > "$dir/m/manifest-end.json"
  python3 "$JUDGE" summary --verdicts "$dir/v.jsonl" --outcomes "$dir/o.jsonl" --manifest-dir "$dir/m" \
    | grep -q '"shadow_gate": "not-yet-24h"' || fail "a short audit must not pass"
  printf '{"started_at": 2000, "elapsed_seconds": 90000}' > "$dir/m/manifest-end.json"
  python3 "$JUDGE" summary --verdicts "$dir/v.jsonl" --outcomes "$dir/o.jsonl" --manifest-dir "$dir/m" \
    | grep -q '"shadow_gate": "not-yet-24h"' || fail "another run's completion must not count"
  rm "$dir/m/manifest-end.json"
  python3 "$JUDGE" summary --verdicts "$dir/v.jsonl" --outcomes "$dir/o.jsonl" --manifest-dir "$dir/m" \
    | grep -q '"shadow_gate": "not-yet-24h"' || fail "a run without a completion record must not pass"
  pass "shadow writes start and end manifests only after preflight and the summary counts only labelled outcomes"
}

collect_one() {  # <dir> <home> -> the "ok" lane snapshot
  PATH="$1/bin:$PATH" python3 "$JUDGE" collect-local --host desktop --home "fleet=$2" | grep '"task":"ok"'
}

test_keyed_status_and_browser_artifacts() {
  local dir home wt snap
  dir=$(world artifacts)
  home="$dir/fleet"
  wt="$dir/wt"
  mkdir -p "$home/state"
  fm_git_init_commit "$wt" >/dev/null 2>&1 || fail "git fixture failed"
  mkdir -p "$wt/proof"
  printf 'notes\n' > "$wt/proof/notes.md"
  git -C "$wt" add proof/notes.md
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qm proof
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:p1\n' "$wt" > "$home/state/ok.meta"
  fake_herdr "$dir/bin" "$dir/herdr.log" "$wt"
  # Status: an unkeyed line parses (control), then the owner's keyed wait must win.
  printf 'done [at=100]: https://github.com/o/r/pull/9 ready\n' > "$home/state/ok.status"
  snap=$(collect_one "$dir" "$home")
  printf '%s\n' "$snap" | grep -q '"last_event":{"at":100,"verb":"done"}' || fail "unkeyed status line not parsed"
  printf 'needs-decision [at=200] [key=nm-review]: ask-user findings=review-7\n' >> "$home/state/ok.status"
  snap=$(collect_one "$dir" "$home")
  printf '%s\n' "$snap" | grep -q '"last_event":{"at":200,"verb":"needs-decision"}' || fail "keyed status line not parsed"
  [ "$(printf '%s\n' "$snap" | gate_of)" = declared:needs-decision ] || fail "a keyed declared wait must settle in Tier 1"
  printf 'resolved [key=nm-review] [at=300]: answered\ndone [at=301]: https://github.com/o/r/pull/9 ready\n' >> "$home/state/ok.status"
  # Browser artifacts: untracked Playwright scratch and proof media never count as unmet work.
  mkdir -p "$wt/.playwright-mcp"
  printf 'x\n' > "$wt/.playwright-mcp/page-1.yml"
  printf 'png\n' > "$wt/proof/shot.png"
  snap=$(collect_one "$dir" "$home")
  printf '%s\n' "$snap" | grep -q '"dirty_files":0' || fail "browser artifacts counted as dirty"
  printf '%s\n' "$snap" | grep -q '"ignored_artifacts":2' || fail "ignored artifacts not reported"
  [ "$(printf '%s\n' "$snap" | gate_of)" = idle-dod-met ] || fail "clean PR lane with only artifacts must be met"
  # Counterfactuals: untracked source, an untracked non-media file under proof/, and a tracked proof edit all count.
  printf 'print(1)\n' > "$wt/new_feature.py"
  snap=$(collect_one "$dir" "$home")
  printf '%s\n' "$snap" | grep -q '"dirty_files":1' || fail "untracked source must count"
  [ "$(printf '%s\n' "$snap" | gate_of)" = idle-unmet-dod ] || fail "untracked source keeps DoD unmet"
  rm "$wt/new_feature.py"
  printf '#!/bin/sh\n' > "$wt/proof/capture.sh"
  collect_one "$dir" "$home" | grep -q '"dirty_files":1' || fail "untracked non-media proof file must count"
  rm "$wt/proof/capture.sh"
  printf 'edited\n' >> "$wt/proof/notes.md"
  collect_one "$dir" "$home" | grep -q '"dirty_files":1' || fail "a tracked proof edit must count"
  pass "keyed status lines settle declared waits and only untracked browser and proof media are ignored as dirt"
}

fake_ssh() {  # <bin-dir> <remote-home>: run the remote command locally in a stand-in home
  # <remote-home>/.down makes the transport fail; <remote-home>/.truncate holds a byte
  # count after which the upload stream ends early, as a dropped connection would.
  mkdir -p "$1" "$2"
  cat > "$1/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; *) break ;; esac; done
printf '%s\n' "\$1" >> '$2/.ssh-hosts'
shift
[ ! -e '$2/.down' ] || exit 255
cd '$2' || exit 255
if [ -s '$2/.truncate' ]; then
  head -c "\$(cat '$2/.truncate')" | HOME='$2' bash -c "\$*"
else
  HOME='$2' exec bash -c "\$*"
fi
SH
  chmod +x "$1/ssh"
}

test_shadow_stop_and_publish() {
  local dir home wt pid i rc dest
  dir=$(world publish)
  home="$dir/main"
  wt="$dir/wt"
  dest="$dir/remote/.fm-actuator/verdicts.jsonl"
  mkdir -p "$home/state" "$home/data"
  : > "$home/data/secondmates.md"
  fm_git_init_commit "$wt" >/dev/null 2>&1 || fail "git fixture failed"
  printf 'print(1)\n' > "$wt/unfinished.py"
  for i in 1 2; do
    printf 'kind=ship\nmode=direct-PR\nworktree=%s\nbackend=herdr\nherdr_session=s\nherdr_pane_id=w1:p%s\n' \
      "$wt" "$i" > "$home/state/lane$i.meta"
  done
  fake_herdr "$dir/bin" "$dir/herdr.log" "$wt"
  fake_ssh "$dir/bin" "$dir/remote"
  stub_start "$dir"
  answer "$dir" needs-nudge 0.9
  # Always called in a subshell: exec makes the background pid the judge itself.
  shadow_in() {
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_PANE_JUDGE_ENV_FILE="$dir/env" \
      FM_PANE_JUDGE_API_BASE="http://127.0.0.1:$(cat "$dir/port")" exec python3 "$JUDGE" shadow \
      --registry "$home/data/secondmates.md" --main-home "$home" --hosts desktop --state-dir "$dir/pj" \
      --out "$dir/out.jsonl" "$@"
  }
  ( shadow_in --duration 60 --interval 1 --publish other_host:x --manifest-dir "$dir/m0" ) >/dev/null 2>&1 &&
    fail "an unauthorized publish host must be refused"
  ( shadow_in --duration 600 --interval 300 --manifest-dir "$dir/m1" \
    --publish 'akamai_vm:~/.fm-actuator/verdicts.jsonl' ) > "$dir/run1.out" 2>&1 &
  pid=$!
  for i in $(seq 1 200); do [ -s "$dir/m1/cycles.jsonl" ] && break; sleep 0.05; done
  [ -s "$dir/m1/cycles.jsonl" ] || fail "first cycle never completed"
  kill -TERM "$pid"
  for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && fail "a stop during the interval must end the run promptly"
  wait "$pid"
  grep -q '"exit_reason": "signal-15"' "$dir/m1/manifest-end.json" || { cat "$dir/run1.out" >&2; fail "stop reason not recorded"; }
  [ "$(grep -c 'agent get' "$dir/herdr.log")" = 2 ] || fail "a stop during the interval started another collection"
  # Two judged rows in one cycle mean two publishes, one right after each append.
  python3 - "$dir/m1/cycles.jsonl" <<'PY' || fail "each appended row must be published on its own"
import json, sys
cycle = json.loads(open(sys.argv[1]).readline())
rows = [p['rows'] for p in cycle['publish']]
assert rows == [1, 2] and all(p['status'] == 'ok' for p in cycle['publish']), cycle['publish']
PY
  cmp -s "$dir/out.jsonl" "$dest" || fail "published file differs from the verdict rows"
  [ -e "$dest.lock" ] || fail "remote publish lock missing"
  [ "$(sort -u "$dir/remote/.ssh-hosts")" = akamai_vm ] || fail "publish went to an unexpected host"
  grep -q '"publish": "akamai_vm:.fm-actuator/verdicts.jsonl"' "$dir/m1/manifest-start.json" || fail "publish target not in manifest"
  cp "$dest" "$dir/before.jsonl"
  # Each fresh run below exercises its preflight publish as the upload under test.
  republish() {
    ( shadow_in --duration 60 --interval 1 --max-cycles 1 --manifest-dir "$1" \
      --publish 'akamai_vm:.fm-actuator/verdicts.jsonl' ) >/dev/null 2>&1
  }
  printf '10\n' > "$dir/remote/.truncate"
  republish "$dir/m2"
  rc=$?
  : > "$dir/remote/.truncate"
  [ "$rc" = 1 ] || fail "a truncated upload must fail the publish"
  cmp -s "$dir/before.jsonl" "$dest" || fail "a truncated upload replaced the destination"
  find "$dir/remote/.fm-actuator" -name '*.tmp.*' | grep -q . && fail "a truncated upload left a temporary file"
  touch "$dir/remote/.down"
  republish "$dir/m3"
  rc=$?
  mv "$dir/remote/.down" "$dir/remote/.was-down"
  [ "$rc" = 1 ] || fail "an unreachable host must fail the publish"
  [ -e "$dir/m3/manifest-start.json" ] && fail "a failed first publish must not start the audit"
  cmp -s "$dir/before.jsonl" "$dest" || fail "a failed transport changed the destination"
  printf 'owned by someone else\n' > "$dest"
  republish "$dir/m4"
  rc=$?
  stub_stop
  [ "$rc" = 1 ] || fail "a refused first publish must fail the preflight"
  [ "$(cat "$dest")" = 'owned by someone else' ] || fail "foreign remote content overwritten"
  pass "a stop during the interval starts no new collection and each verdict row mirrors verified and atomically to the authorized host only"
}

fm_test_run test_gate_classes test_request_shape_and_redaction test_verdict_contract_and_dedupe \
  test_hysteresis_contradiction_and_pid_override test_budget_lock_and_fail_closed \
  test_collection_exclusion_and_identity test_shadow_manifests_and_summary \
  test_keyed_status_and_browser_artifacts test_shadow_stop_and_publish
