#!/usr/bin/env bash
# bin/fm-judge-first.sh behavior: every secondmate needs-decision:/blocked: line
# runs through the private judge before the supervisor spends a turn on it.
#
# The judge itself is a local stub (no second opinion, no network, no paid call);
# these tests drive the real hook executable and read its journal and its sends:
#   1. Modes: no config = off, empty or unknown = shadow (journal only, never
#      sends), only the word "on" answers.
#   2. Escalation: no recommendation (including a negated one), every guard rule
#      the backtest found, and every judge failure leave the ordinary wake - the
#      judge is not even asked for the first two classes.
#   3. The regression lines: each guard rule has a case reduced from the real
#      line that slipped past judge.py (force-with-lease, revocation, shared
#      staging migration, run abort, bot protection, a 19-call bundle, a
#      conditional recommendation, a pipeline step skip).
#   4. Dedupe by decision identity: a hold line plus its plain twin get one
#      answer closing both keys; a replay and a re-journaled twin get none;
#      successive rounds stay separate decisions.
#   5. Live sends go through the real fm-send --resolve-key exactly once and are
#      journaled before they are sent.
#   6. The remote-reply adapter hands its newly appended lines to the hook only
#      when config/judge-first exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-judge-first.sh"
TMP_ROOT=$(fm_test_tmproot fm-judge-first)

# A judge stand-in with judge.py's calling contract: card on stdin, one verdict
# JSON line on stdout. STUB_AGREE selects the second opinion (true|false|none),
# STUB_RULES a comma list of rules to hit, STUB_FAIL=1 exits nonzero,
# STUB_SLEEP delays, STUB_POLICY overrides the policy string. Every call is
# counted so a test can prove the judge was (not) asked.
write_judge_stub() { # <dir>
  cat > "$1/judge.py" <<'PY'
import json, os, sys, time
card = json.load(sys.stdin)
if '--record-langfuse' in sys.argv:
    print('{}')
    sys.exit(0)
with open(os.environ['STUB_CALLS'], 'a') as fh:
    fh.write(card['decision_id'] + '\n')
if os.environ.get('STUB_SLEEP'):
    time.sleep(float(os.environ['STUB_SLEEP']))
if os.environ.get('STUB_FAIL') == '1':
    sys.exit(1)
if os.environ.get('STUB_GARBAGE') == '1':
    print('not json')
    sys.exit(0)
rules = [r for r in os.environ.get('STUB_RULES', '').split(',') if r]
verdict = {'auto': not rules, 'chosen': None if rules else card['recommended'], 'rules_hit': rules,
           'policy': os.environ.get('STUB_POLICY', 'recommended-v1'), 'decision_id': card['decision_id']}
agree = os.environ.get('STUB_AGREE', 'true')
if agree != 'none':
    verdict['second_opinion'] = {'agree': agree == 'true', 'model': 'stub'}
print(json.dumps(verdict))
PY
}

# A send stand-in: logs its argv, and proves the journal row was durable first.
write_send_stub() { # <dir>
  cat > "$1/send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_SENDS"
grep -q '"action":"sending"' "$FM_JUDGE_LOG" && printf 'journaled-first\n' >> "$STUB_SENDS"
[ "${STUB_SEND_FAIL:-0}" = 1 ] && { echo 'error: transport down'; exit 1; }
exit 0
SH
  chmod +x "$1/send.sh"
}

new_home() { # <name> -> sets HOME_DIR and the stub env
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/fleet-bridge"
  write_judge_stub "$HOME_DIR/data/fleet-bridge"
  write_send_stub "$HOME_DIR"
  : > "$HOME_DIR/calls"
  : > "$HOME_DIR/sends"
  LOG="$HOME_DIR/data/fleet-bridge/judge-log.jsonl"
}

# run_hook <lines-file> [VAR=value...]: run ingest for secondmate "mate".
run_hook() {
  local lines=$1; shift
  env FM_HOME="$HOME_DIR" FM_SEND_BIN="$HOME_DIR/send.sh" FM_JUDGE_LOG="$LOG" \
    STUB_CALLS="$HOME_DIR/calls" STUB_SENDS="$HOME_DIR/sends" "$@" \
    "$HOOK" ingest mate "$lines" 2>&1
}

line_file() { # <name> <text...>: one line per argument
  local f="$HOME_DIR/$1"; shift
  printf '%s\n' "$@" > "$f"
  printf '%s\n' "$f"
}

journal() { # <python expr over rows>: print it
  python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(eval(sys.argv[2]))' "$LOG" "$1"
}

calls() { wc -l < "$HOME_DIR/calls" | tr -d ' '; }
sends() { grep -vc '^journaled-first$' "$HOME_DIR/sends" | tr -d ' '; }

# Reduced from real lines; each is neutral wording that keeps the structure
# (options, recommendation sentence, the risky phrase) of the line that slipped.
BENIGN='needs-decision [key=clause-policy] [at=1000]: corr=0123456789abcdef Which wording should the summary use for an unknown field? Options: (A, recommended) say "not stated" and keep the field; (B) omit the field. Evidence data/x/report.md'
FORCE_LEASE='needs-decision [at=1000]: PR 12 validation: the pipeline insists on a rebase that rewrites history and would push the branch. Options: (a) explicitly authorise the pipeline'"'"'s rebase + force-with-lease push of THIS branch only; (b) explicitly authorise skipping the rebase step and pushing the merge commit. Recommend (a): parent landed, so it is the normal stack-landing step.'
REVOCATION='needs-decision [key=old-grant-policy] [at=1000]: A reconnect leaves the old OAuth grant alive. Choose cleanup, redesign, or retain and document. Recommend bounded ownership-checked cleanup if revocation is intended, with 404 success. Evidence data/x/diagnosis.md.'
STAGING='needs-decision [key=staging-refresh] [at=1000]: Shared VM staging is 2 migrations behind dev. Refreshing it rebuilds the staging engine and migrates its Postgres. Options: (A, recommended) authorise the documented refresh now; (B) leave staging stale.'
ABORT='needs-decision [at=1000]: PR 15 head has 4 failing tests caused by the pipeline rebase; an earlier run holds the branch. Options: (A) explicitly authorise "no-mistakes axi abort --run R1" (ends monitor only); (B) content-only successor PR. Recommend A.'
BOT='needs-decision [key=scout-turnstile] [at=1000]: The scout reached the sign-up form and a human-verification check appeared. Options: (A, recommended) the captain disables bot protection on the dev instance for the test; (B) the captain clicks the checkbox himself.'
BUNDLE='needs-decision [key=triage-decisions] [at=1000]: Owner calls in data/x/decisions.md. D1 seller identity wording; D2 flip switches; D3 verdict flags; D4 grants; D5 metering mode. Recommendation for each is first in its entry.'
CONDITIONAL='needs-decision [at=1000]: After the abort, new runs are refused. Options: (A) successor PRs per the standing rule; (B) you authorise sync --recover once --check shows nothing unpublished would be discarded. Recommend B if --check is clean, else A.'
SKIPSTEP='blocked [key=docs-scope] [at=1000]: The Document step deleted the final blank line again. Recommend authorize one commit-on-top restore then a run skipping Document ONLY for the documentation lane.'
NOREC='blocked [key=cap-custody] [at=1000]: tests fail after the rebase; the gate refuses a new run. Waiting for direction.'
NEGATED='needs-decision [key=odd-ask] [at=1000]: Options: (A) retry once; (B) stop. I do not recommend either without more data.'
UNKNOWN_LETTER='needs-decision [key=odd-letter] [at=1000]: Options: (A) retry once; (B) stop. Recommend C.'

test_mode_gate() {
  new_home mode
  local lines out
  lines=$(line_file in "$BENIGN")
  out=$(run_hook "$lines")
  [ "$(calls)" = 0 ] && [ ! -s "$LOG" ] || fail "with no config/judge-first the hook did work: $out"
  pass "no config/judge-first: the hook does nothing"

  : > "$HOME_DIR/config/judge-first"
  out=$(run_hook "$lines")
  assert_contains "$out" "mode=shadow" "an empty config should mean shadow"
  assert_equals 1 "$(calls)" "shadow should still ask the judge"
  assert_equals 0 "$(sends)" "shadow must never send"
  assert_equals would-auto "$(journal "rows[-1]['hook']['action']")" "shadow should journal what it would send"
  pass "empty config: shadow journals the would-send verdict and sends nothing"

  new_home mode-unknown
  printf 'ON please\n' > "$HOME_DIR/config/judge-first"
  lines=$(line_file in "$BENIGN")
  out=$(run_hook "$lines")
  assert_contains "$out" "mode=shadow" "an unknown config value should fail safe to shadow"
  assert_equals 0 "$(sends)" "an unknown value must not go live"
  pass "unknown config value: shadow, never live"
}

test_live_answer() {
  new_home live
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local lines out
  lines=$(line_file in "$BENIGN")
  out=$(run_hook "$lines")
  assert_contains "$out" "mode=on" "config 'on' should go live"
  assert_equals 1 "$(sends)" "an auto verdict should send exactly one answer"
  assert_contains "$(cat "$HOME_DIR/sends")" "mate --resolve-key clause-policy judge auto-decided (recommended, Jev agreed): a - say \"not stated\" and keep the field" \
    "the answer should name the key and the taken option"
  assert_contains "$(cat "$HOME_DIR/sends")" journaled-first "the journal row must be durable before the send"
  assert_equals "sending sent" "$(journal "' '.join(r['hook']['action'] for r in rows)")" "the journal should record the send intent and its result"
  assert_equals true "$(journal "'verdict' in rows[0] and 'card' in rows[0] and 'at' in rows[0]" | tr 'T' 't')" "rows must keep judge-log's card/verdict/at shape"
  pass "on: one answer through send with --resolve-key, journaled first"

  out=$(run_hook "$lines")
  assert_equals 1 "$(sends)" "replaying the same lines must not answer twice"
  assert_contains "$out" "deduped=1" "the replay should count as deduped"
  pass "on: a replay of the same lines is deduped, no second answer"
}

test_escalations_do_not_ask_the_judge() {
  new_home noask
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local lines out
  lines=$(line_file in "$NOREC" "$NEGATED" "$UNKNOWN_LETTER")
  out=$(run_hook "$lines")
  assert_contains "$out" "escalate=3" "all three have nothing the judge can take"
  assert_equals 0 "$(calls)" "no-recommendation lines must not reach the judge"
  assert_equals 0 "$(sends)" "no guessing: nothing is sent without a recommendation"
  assert_equals "no_recommendation" "$(journal "sorted({h for r in rows for h in r['verdict']['rules_hit']})" | tr -d "[]' ")" "journal the reason"
  pass "no recommendation (missing, negated, unresolvable) always escalates without a judge call"
}

# One case per guard rule, each reduced from the real line that slipped past
# judge.py's own hard rules in the backtest.
test_guard_rules_from_real_lines() {
  local name line rule
  while IFS='|' read -r name rule; do
    new_home "guard-$name"
    printf 'on\n' > "$HOME_DIR/config/judge-first"
    case "$name" in
      forcelease) line=$FORCE_LEASE ;; revocation) line=$REVOCATION ;; staging) line=$STAGING ;;
      abort) line=$ABORT ;; bot) line=$BOT ;; bundle) line=$BUNDLE ;; conditional) line=$CONDITIONAL ;;
      skipstep) line=$SKIPSTEP ;;
    esac
    lines=$(line_file in "$line")
    run_hook "$lines" >/dev/null
    assert_equals 0 "$(sends)" "$name: a guard-rule line must never be auto-answered"
    assert_equals 0 "$(calls)" "$name: a guard-rule line must not even reach the judge"
    assert_contains "$(journal "rows[-1]['verdict']['rules_hit']")" "$rule" "$name: expected guard rule $rule"
    assert_equals escalate "$(journal "rows[-1]['hook']['action']")" "$name should journal an escalation"
  done <<'EOF'
forcelease|irreversible_destructive
revocation|security_access
staging|shared_state
abort|irreversible_destructive
bot|security_access
bundle|bundle_card
conditional|conditional_recommendation
skipstep|pipeline_bypass
EOF
  pass "each backtest gap has a regression line that escalates: force-with-lease, revocation, shared staging, abort, bot protection, bundle, conditional, step skip"
}

test_guard_rule_variants() {
  new_home variants
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local lines n=0 text
  while IFS= read -r text; do
    n=$((n + 1))
    printf 'needs-decision [key=v%s] [at=%s]: %s\n' "$n" "$((1000 + n * 1000))" "$text"
  done > "$HOME_DIR/variants" <<'EOF'
Options: (A, recommended) rewrite the branch history and push; (B) leave it.
Options: (A, recommended) run git reset --hard on the lane; (B) leave it.
Options: (A, recommended) revoke nothing but announce the revocation window; (B) wait.
Options: (A, recommended) disable the verification step for the dev tenant; (B) keep it.
Options: (A, recommended) apply the migration to the shared staging database; (B) wait.
Options: (A, recommended) set the pricing page copy now; (B) wait.
Options: (A, recommended) publish the seller identity and VAT wording; (B) wait.
Options: (A, recommended) enable the billing portal; (B) wait.
Options: (A, recommended) use the production switch; (B) wait.
Options: (A, recommended) take D1, D2 and D3 as recommended; (B) none.
Recommend either option A or option B, whichever is quicker.
Options: (A, recommended) skip the review step; (B) keep it.
EOF
  lines="$HOME_DIR/variants"
  run_hook "$lines" >/dev/null
  assert_equals 0 "$(sends)" "no variant may be auto-answered"
  assert_equals 12 "$(journal "sum(1 for r in rows if r['hook']['action']=='escalate')")" "every variant should journal an escalation"
  pass "guard rule variants (rewrite history, reset --hard, revocation, disable verification, migration, legal/pricing/billing/production topics, bundles, either-or, step skips) all escalate"
}

test_judge_findings_and_failures_escalate() {
  local case_name expect
  while IFS='|' read -r case_name expect; do
    new_home "judge-$case_name"
    printf 'on\n' > "$HOME_DIR/config/judge-first"
    local lines out
    lines=$(line_file in "$BENIGN")
    case "$case_name" in
      rules) out=$(run_hook "$lines" STUB_RULES=main_production) ;;
      noopinion) out=$(run_hook "$lines" STUB_AGREE=none) ;;
      disagree) out=$(run_hook "$lines" STUB_AGREE=false) ;;
      fail) out=$(run_hook "$lines" STUB_FAIL=1) ;;
      garbage) out=$(run_hook "$lines" STUB_GARBAGE=1) ;;
      policy) out=$(run_hook "$lines" STUB_POLICY=recommended-v9) ;;
      timeout) out=$(run_hook "$lines" STUB_SLEEP=5 FM_JUDGE_FIRST_TIMEOUT=1) ;;
      budget) out=$(run_hook "$lines" FM_JUDGE_FIRST_BUDGET=-1) ;;
      nojudge) out=$(run_hook "$lines" FM_JUDGE_PY="$HOME_DIR/missing.py") ;;
    esac
    assert_equals 0 "$(sends)" "$case_name: nothing may be sent"
    assert_contains "$out" "$expect" "$case_name: unexpected summary"
  done <<'EOF'
rules|escalate=1
noopinion|escalate=1
disagree|escalate=1
fail|error=1
garbage|error=1
policy|error=1
timeout|error=1
budget|error=1
nojudge|error=1
EOF
  new_home judge-noopinion-journal
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  run_hook "$(line_file in "$BENIGN")" STUB_AGREE=none >/dev/null
  assert_contains "$(journal "rows[-1]['verdict']['rules_hit']")" second_opinion_missing "a missing second opinion must be journaled as the reason"
  pass "judge hard-rule hits, missing or negative second opinion, failures, timeouts, unknown policy, and a spent budget all escalate and never send"
}

test_dedupe_by_decision_identity() {
  new_home dedupe
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local a b lines
  a='needs-decision [key=captain-hold-ce-policy-1] [at=5000]: captain hold: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [at=5002] [key=ce-policy]: corr=0123456789abcdef Options: (A, recommended) keep the field as recommended; (B) omit it.'
  lines=$(line_file in "$a" "$b")
  run_hook "$lines" >/dev/null
  assert_equals 1 "$(sends)" "a hold line and its plain twin are one decision with one answer"
  assert_contains "$(cat "$HOME_DIR/sends")" "--resolve-key captain-hold-ce-policy-1 --resolve-key ce-policy" "the one answer must close both keys"
  pass "dedupe: a hold line plus its twin get one answer that closes both keys"

  run_hook "$lines" >/dev/null
  assert_equals 1 "$(sends)" "a replay must not answer again"
  late='needs-decision [at=5060] [key=ce-policy]: Options: (A, recommended) keep the field; (B) omit it.'
  run_hook "$(line_file late "$late")" >/dev/null
  assert_equals 1 "$(sends)" "a straggling twin within the window must not draw a second answer"
  pass "dedupe: a replay and a straggling twin draw no second answer"

  new_home dedupe-rounds
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  a='needs-decision [key=captain-hold-ce-cal-1] [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [key=captain-hold-ce-cal-2] [at=5900]: Options: (A, recommended) drop the cache; (B) keep it.'
  run_hook "$(line_file in "$a" "$b")" >/dev/null
  assert_equals 2 "$(sends)" "successive rounds of one hold are separate decisions"
  pass "dedupe: successive rounds of a key family stay separate decisions"

  new_home dedupe-families
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  a='needs-decision [key=ce-alpha] [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [key=ce-beta] [at=5001]: Options: (A, recommended) keep the field; (B) omit it.'
  run_hook "$(line_file in "$a" "$b")" >/dev/null
  assert_equals 2 "$(sends)" "different key families are different decisions"
  pass "dedupe: different key families are answered separately"

  new_home dedupe-risky-twin
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  a='needs-decision [key=captain-hold-ce-risk-1] [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [key=ce-risk] [at=5001]: Options: (A, recommended) force-with-lease push the branch; (B) leave it.'
  run_hook "$(line_file in "$a" "$b")" >/dev/null
  assert_equals 0 "$(sends)" "a decision is auto only when every line of it is auto"
  pass "dedupe: one risky member escalates the whole decision"

  new_home dedupe-keyless
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  a='needs-decision [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [at=5001]: Options: (A, recommended) keep the field; (B) omit it.'
  run_hook "$(line_file in "$a" "$b")" >/dev/null
  assert_equals 1 "$(sends)" "identical keyless lines are one decision"
  assert_not_contains "$(cat "$HOME_DIR/sends")" "--resolve-key" "a keyless decision has nothing to close"
  pass "dedupe: identical keyless lines are one decision answered without --resolve-key"
}

test_send_failure_leaves_ordinary_wake() {
  new_home sendfail
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local out
  out=$(run_hook "$(line_file in "$BENIGN")" STUB_SEND_FAIL=1); rc=$?
  expect_code 0 "$rc" "a failed send must not fail the hook"
  assert_contains "$out" "error=1" "a failed send is an error, not an auto"
  assert_equals 1 "$(sends)" "a failed send is attempted once and never retried"
  assert_equals send-failed "$(journal "rows[-1]['hook']['action']")" "the failure should be journaled"
  assert_contains "$(journal "rows[-1]['hook']['send']['detail']")" "transport down" "the failure detail should be kept"
  pass "a failed send is journaled once, never retried, and leaves the ordinary wake"
}

test_non_decision_lines_are_ignored() {
  new_home ignore
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local out
  out=$(run_hook "$(line_file in 'working [at=1]: busy' 'done [at=2]: PR https://example.test/pr/1 checks green' 'resolved [key=k] [at=3]: answered: x' 'note: hello')")
  assert_contains "$out" "lines=0" "only needs-decision and blocked lines are judged"
  assert_equals 0 "$(calls)" "other lines never reach the judge"
  pass "working, done, resolved, and note lines are ignored"
}

test_summary() {
  new_home summary
  : > "$HOME_DIR/config/judge-first"
  run_hook "$(line_file in "$BENIGN" "$NOREC")" >/dev/null
  local out
  out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary)
  assert_contains "$out" '"escalate": 1' "summary should count escalations"
  assert_contains "$out" '"would-auto": 1' "summary should count would-send verdicts"
  assert_contains "$out" "clause-policy" "summary should list each would-send decision"
  pass "summary lists a day of shadow verdicts for comparison with the supervisor's answers"
}

# The real fm-send, end to end: the answer reaches the secondmate's durable
# inbox once and the open keyed decision closes in the status log.
test_live_send_through_real_fm_send() {
  new_home e2e
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local fb="$HOME_DIR/fakebin" out
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-mate; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
  fm_write_meta "$HOME_DIR/state/mate.meta" "window=sess:fm-mate" "kind=ship"
  printf '%s\n' "$BENIGN" > "$HOME_DIR/state/mate.status"
  out=$(env PATH="$fb:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_SEND_BIN="$ROOT/bin/fm-send.sh" \
    FM_SEND_SETTLE=0 FM_JUDGE_LOG="$LOG" STUB_CALLS="$HOME_DIR/calls" \
    "$HOOK" ingest mate "$(line_file in "$BENIGN")" 2>&1)
  assert_contains "$out" "auto=1" "the real send should succeed: $out"
  grep -qF 'judge auto-decided (recommended, Jev agreed): a - ' "$HOME_DIR/state/mate.inbox/001.msg" \
    || fail "the answer did not reach the durable inbox"
  [ ! -e "$HOME_DIR/state/mate.inbox/002.msg" ] || fail "the answer was delivered twice"
  sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/mate.status" | grep -qF 'resolved [key=clause-policy]: answered: judge auto-decided' \
    || fail "the keyed decision was not closed:"$'\n'"$(cat "$HOME_DIR/state/mate.status")"
  assert_equals sent "$(journal "rows[-1]['hook']['action']")" "the journal should end at sent"
  pass "live: the real fm-send --resolve-key delivers one answer and closes the decision"
}

test_adapter_wiring() {
  new_home wiring
  local result="$HOME_DIR/result" payload line cursor_hash empty_hash
  line='needs-decision [key=clause-policy] [at=1000]: Options: (A, recommended) keep the field; (B) omit it.'
  payload="$HOME_DIR/payload"
  printf '%s\n' "$line" > "$payload"
  sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
  : > "$HOME_DIR/empty"
  empty_hash=$(sha "$HOME_DIR/empty")
  cursor_hash=$(sha "$payload")
  {
    printf 'schema=fm-remote-delta.v1\nstatus=delta\npath=state/parent-replies.status\n'
    printf 'from_offset=0\nto_offset=%s\n' "$(wc -c < "$payload" | tr -d ' ')"
    printf 'from_prefix_sha256=%s\nto_prefix_sha256=%s\n' "$empty_hash" "$cursor_hash"
    printf 'payload_sha256=%s\npayload_bytes=%s\nreason=\n\n' "$cursor_hash" "$(wc -c < "$payload" | tr -d ' ')"
    cat "$payload"
  } > "$result"
  cat > "$HOME_DIR/data/secondmates.md" <<EOF
- mate - test mate (host: remote-mac; root: $ROOT; home: $HOME_DIR; scope: test; projects: alpha; added 2026-08-02)
EOF
  # Without the config the ingest leaves the hook alone.
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_BIN="$HOME_DIR/send.sh" FM_JUDGE_LOG="$LOG" \
    STUB_CALLS="$HOME_DIR/calls" STUB_SENDS="$HOME_DIR/sends" \
    "$ROOT/bin/fm-procevent-remote-reply.sh" ingest mate "$result" >/dev/null 2>&1 \
    || fail "the adapter ingest failed without the hook"
  grep -qF 'needs-decision [key=clause-policy]' "$HOME_DIR/state/mate.status" || fail "the line was not mirrored"
  assert_equals 0 "$(calls)" "no config: the adapter must not run the hook"

  # With the config, newly appended lines pass through it (shadow here).
  rm -f "$HOME_DIR/state/mate.status" "$HOME_DIR/state/.remote-reply-mirrored-mate"
  rm -rf "$HOME_DIR/state/remote-replies"
  : > "$HOME_DIR/config/judge-first"
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_BIN="$HOME_DIR/send.sh" FM_JUDGE_LOG="$LOG" \
    STUB_CALLS="$HOME_DIR/calls" STUB_SENDS="$HOME_DIR/sends" \
    "$ROOT/bin/fm-procevent-remote-reply.sh" ingest mate "$result" >/dev/null 2>&1 \
    || fail "the adapter ingest failed with the hook enabled"
  assert_equals 1 "$(calls)" "the newly mirrored decision line should reach the judge"
  assert_equals would-auto "$(journal "rows[-1]['hook']['action']")" "shadow should journal the verdict"
  assert_equals 0 "$(sends)" "shadow must not send"

  # A hook that cannot run never fails the ingest.
  rm -f "$HOME_DIR/state/mate.status" "$HOME_DIR/state/.remote-reply-mirrored-mate"
  rm -rf "$HOME_DIR/state/remote-replies"
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_JUDGE_PY="$HOME_DIR/missing.py" \
    "$ROOT/bin/fm-procevent-remote-reply.sh" ingest mate "$result" >/dev/null 2>&1 \
    || fail "a hook that cannot run must not fail the ingest"
  pass "the remote-reply ingest hands new lines to the hook only when config/judge-first exists, and never fails because of it"
}

test_mode_gate
test_live_answer
test_escalations_do_not_ask_the_judge
test_guard_rules_from_real_lines
test_guard_rule_variants
test_judge_findings_and_failures_escalate
test_dedupe_by_decision_identity
test_send_failure_leaves_ordinary_wake
test_non_decision_lines_are_ignored
test_summary
test_live_send_through_real_fm_send
test_adapter_wiring

# Slice 1 parser and final-verdict telemetry regressions.
python3 - "$(dirname "$0")/../bin/fm-judge-first.py" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOK = Path(sys.argv.pop()).resolve()
spec = importlib.util.spec_from_file_location('hook', HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


def synth(body):
    return hook.synthesize({'body': body, 'key': None}, 'mate')


class HookTests(unittest.TestCase):
    def test_numbered_defects_and_trailing_recommendation(self):
        body = ('Defect https://github.com/example/repo/pull/42: (1) production-build '
                'switch; (2) migration probe closes bypasses. Options: '
                '(a) repair the tests (recommended); (b) bypass the pipeline; (c) deploy to production.')
        result = synth(body)
        self.assertEqual(result['card']['recommended'], 'a')
        self.assertEqual([x['value'] for x in result['card']['options']], ['a', 'b', 'c'])
        self.assertEqual(hook.guard_rules(result), [])
        reply = hook.answer_text(result, {})
        self.assertIn('https://github.com/example/repo/pull/42', reply)
        self.assertNotIn('bypass the pipeline', reply)

    def test_recommendation_formats(self):
        for body in ('Options: (A, recommended) repair tests; (B) wait.',
                     'Options: (a) repair tests (recommended - bounded); (b) wait.',
                     'Options: (a) repair tests; (b) wait. Recommend (a).',
                     '(1) repair tests (recommended); (2) wait.'):
            with self.subTest(body=body):
                result = synth(body)
                self.assertEqual(result['card']['recommended'], '1' if body.startswith('(1)') else 'a')
                self.assertEqual(len(result['card']['options']), 2)

    def test_no_recommendation(self):
        for body in ('The gate is blocked. Waiting for direction.',
                     'Options: (a) repair; (b) wait. Do not recommend either.',
                     'Options: (a) repair; (b) wait. Recommend C.',
                     'Options: (a) repair; (b) wait.',
                     'Options: (a) repair (recommended); (b) wait (recommended).'):
            self.assertIsNone(synth(body)['card']['recommended'])

    def test_action_guards(self):
        for action, rule in [('bypass the pipeline', 'pipeline_bypass'),
                             ('skip validation', 'pipeline_bypass'),
                             ('run database migrations', 'shared_state'),
                             ('deploy to production', 'restricted_topic'),
                             ('change billing', 'restricted_topic'),
                             ('git reset --hard', 'irreversible_destructive')]:
            with self.subTest(action=action):
                self.assertIn(rule, hook.guard_rules(synth(f'Options: (a) {action} (recommended); (b) wait.')))
        self.assertEqual(hook.guard_rules(synth('Options: (a) fix the UI (Manage billing only, no purchase links) (recommended); (b) wait.')), [])

    def test_ingest_final_export_and_dedupe(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home/'config').mkdir()
            (home/'config/judge-first').write_text('on')
            judge = home/'judge.py'
            judge.write_text('''import json, os, sys
from pathlib import Path
packet = json.load(sys.stdin)
if '--record-langfuse' in sys.argv:
    if os.environ.get('EXPORT_FAIL'):
        sys.exit(1)
    log = Path(os.environ['FM_JUDGE_LOG'])
    assert log.exists() and log.read_text().strip(), 'export preceded journal'
    with open(os.environ['EXPORTS'], 'a') as f:
        f.write(json.dumps(packet) + '\\n')
    print('{}')
else:
    print(json.dumps({'auto': True, 'chosen': packet['recommended'], 'rules_hit': [],
                      'policy': 'recommended-v1', 'second_opinion': {'agree': not packet['title'].startswith('missing')}}))
''')
            send = home/'send.sh'
            send.write_text('#!/bin/sh\nprintf "sent\\n" >> "$SENDS"\n')
            send.chmod(0o755)
            env = dict(os.environ, FM_HOME=tmp, FM_JUDGE_PY=str(judge),
                       FM_JUDGE_LOG=str(home/'journal'), FM_SEND_BIN=str(send),
                       EXPORTS=str(home/'exports'), SENDS=str(home/'sends'))
            lines = '\n'.join([
                'blocked [key=safe] [at=1]: Options: (a) fix tests (recommended); (b) wait.',
                'blocked [key=none] [at=200]: Waiting for direction.',
                'blocked [key=risky] [at=400]: Options: (a) bypass the pipeline (recommended); (b) wait.',
                'blocked [key=missing] [at=600]: Options: (a) fix tests (recommended); (b) wait.'])
            def ingest():
                return subprocess.run([sys.executable, str(HOOK), 'ingest', 'mate', '-'],
                                      input=lines, env=env, text=True, capture_output=True, check=True)
            result = ingest()
            self.assertIn('auto=1 escalate=3', result.stdout)
            rows = [json.loads(x) for x in (home/'exports').read_text().splitlines()]
            self.assertEqual(len(rows), 4)
            self.assertEqual([r['verdict']['auto'] for r in rows], [True, False, False, False])
            self.assertEqual(rows[-1]['verdict']['rules_hit'], ['second_opinion_missing'])
            self.assertEqual((home/'sends').read_text(), 'sent\n')
            self.assertEqual(len((home/'journal').read_text().splitlines()), 5)
            self.assertIn('deduped=4', ingest().stdout)
            self.assertEqual(len((home/'exports').read_text().splitlines()), 4)
            self.assertEqual((home/'sends').read_text(), 'sent\n')
            # Export failure cannot turn the durable send path into an outage.
            (home/'journal').unlink()
            env['EXPORT_FAIL'] = '1'
            self.assertIn('auto=1 escalate=3', ingest().stdout)
            self.assertEqual((home/'sends').read_text(), 'sent\nsent\n')


unittest.main()
PY
