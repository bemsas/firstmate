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
#   4. Dedupe by decision identity: a numbered line plus its plain twin get one
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

test_unheld_destructive_decisions() {
  new_home destructive
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local out
  cat > "$HOME_DIR/in" <<'EOF'
needs-decision [key=ce-polish-1639-discard] [at=1000]: Options: (A, recommended) proceed; (B) wait.
needs-decision [key=context-only] [at=1001]: DiScArDiNg abandoned edits is on the table. Options: (A, recommended) proceed; (B) wait.
needs-decision [key=confirm-flag] [at=1002]: Options: (A, recommended) apply --force; (B) wait.
needs-decision [key=cleanup-choice] [at=1003]: Options: (A, recommended) wait; (B) start Teardown.
needs-decision [key=cleanup_FORCE] [at=1004]: Options: (A, recommended) proceed; (B) wait.
needs-decision [key=ordinary-forceful-wording] [at=1005]: Options: (A, recommended) keep the discardable label; (B) omit it.
EOF
  out=$(run_hook "$HOME_DIR/in")
  assert_contains "$out" 'auto=1 escalate=5' "only the ordinary unheld decision may be auto-answered"
  assert_equals 1 "$(calls)" "only the ordinary unheld decision may reach the judge"
  assert_equals 'mate:ordinary-forceful-wording' "$(cat "$HOME_DIR/calls")" "the judge must only see the control"
  assert_equals 1 "$(sends)" "only the ordinary unheld decision may be sent"
  assert_contains "$(cat "$HOME_DIR/sends")" '--resolve-key ordinary-forceful-wording' "the sender must only close the control"
  assert_equals 5 "$(journal "sum(r['hook']['action'] == 'escalate' and r['verdict']['rules_hit'] == ['irreversible_destructive'] for r in rows)")" \
    "every destructive case must journal the existing escalation reason"
  pass "unheld destructive decisions escalate before a judge opinion or send; ordinary wording still auto-answers"
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
  a='needs-decision [key=ce-policy-1] [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [at=5002] [key=ce-policy]: corr=0123456789abcdef Options: (A, recommended) keep the field as recommended; (B) omit it.'
  lines=$(line_file in "$a" "$b")
  run_hook "$lines" >/dev/null
  assert_equals 1 "$(sends)" "two lines of one decision get one answer"
  assert_contains "$(cat "$HOME_DIR/sends")" "--resolve-key ce-policy-1 --resolve-key ce-policy" "the one answer must close both keys"
  pass "dedupe: a numbered line plus its plain twin get one answer that closes both keys"

  run_hook "$lines" >/dev/null
  assert_equals 1 "$(sends)" "a replay must not answer again"
  late='needs-decision [at=5060] [key=ce-policy]: Options: (A, recommended) keep the field; (B) omit it.'
  run_hook "$(line_file late "$late")" >/dev/null
  assert_equals 1 "$(sends)" "a straggling twin within the window must not draw a second answer"
  pass "dedupe: a replay and a straggling twin draw no second answer"

  new_home dedupe-rounds
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  a='needs-decision [key=ce-cal-1] [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
  b='needs-decision [key=ce-cal-2] [at=5900]: Options: (A, recommended) drop the cache; (B) keep it.'
  run_hook "$(line_file in "$a" "$b")" >/dev/null
  assert_equals 2 "$(sends)" "successive rounds of one decision family are separate decisions"
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
  a='needs-decision [key=ce-risk-1] [at=5000]: Options: (A, recommended) keep the field; (B) omit it.'
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

test_captain_holds_are_never_answered() {
  new_home holds
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  local ans
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add held-one "synthetic hold" --kind ship --repo x >/dev/null \
    || fail "setup: could not create synthetic hold"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" hold held-one --reason "synthetic captain call" >/dev/null 2>&1
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" open held-one || fail "setup: the synthetic task is not an open captain hold"
  run_hook "$(line_file in 'needs-decision [key=held-one] [at=1000]: Options: (A, recommended) keep the field; (B) omit it.')" >/dev/null
  assert_equals 0 "$(sends)" "a judge pick must never answer an open captain-held task"
  assert_equals 0 "$(calls)" "a captain hold is not even put to the judge"
  assert_contains "$(journal "rows[-1]['verdict']['rules_hit']")" captain_hold "the escalation reason should be journaled"
  assert_equals escalate "$(journal "rows[-1]['hook']['action']")" "a held decision escalates"
  run_hook "$(line_file in2 'needs-decision [key=captain-hold-x-1] [at=2000]: Options: (A, recommended) keep the field; (B) omit it.')" >/dev/null
  assert_equals 0 "$(sends)" "a captain-hold- key is never answered"
  run_hook "$(line_file in2-twin 'needs-decision [key=x] [at=2010]: Options: (A, recommended) keep the field; (B) omit it.')" >/dev/null
  assert_equals 0 "$(sends)" "a later plain twin of a captain hold is never answered"
  run_hook "$(line_file in3 'needs-decision [key=plain-ask] [at=3000]: captain call: Options: (A, recommended) keep the field; (B) omit it.')" >/dev/null
  assert_equals 0 "$(sends)" "captain call wording is never answered"
  run_hook "$(line_file in4 'needs-decision [key=plain-ask-2] [at=4000]: Options: (A, recommended) keep the field; (B) omit it.')" >/dev/null
  assert_equals 1 "$(sends)" "an ordinary unheld decision is still answered"
  ans="$HOME_DIR/answer.txt"; printf 'a\n' > "$ans"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" answer held-one --decision-file "$ans" >/dev/null 2>&1 || fail "the human answer path was refused"
  if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" open held-one; then fail "the human answer did not close the hold"; fi
  pass "captain holds: a judge pick is never sent for a held task, a captain-hold- key or captain-call wording; ordinary decisions and the human answer path still work"
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
  assert_contains "$out" '"confirmed_human_reversals": null' "omitted answer evidence is unknown"
  assert_contains "$out" '"reversal_source": null' "omitted answer evidence has no source"
  printf '\n  \n' > "$HOME_DIR/empty-reversals.jsonl"
  out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary --reversals "$HOME_DIR/empty-reversals.jsonl")
  assert_contains "$out" '"confirmed_human_reversals": 0' "supplied empty evidence establishes a reported zero"
  assert_contains "$out" '"reversal_source": "operator-attested"' "summary must identify the input provenance"
  pass "summary lists a day of shadow verdicts for comparison with the supervisor's answers"
}

test_summary_human_reversals() {
  new_home reversals
  local receipts="$HOME_DIR/reversals.jsonl" out before bad_receipt rc=0
  python3 - "$HOME_DIR" "$LOG" "$receipts" <<'PY'
import copy, json, sys
from pathlib import Path

home, journal, receipts = map(Path, sys.argv[1:])
rows, answers = [], []
def fixture(i, *, mode="on", action="sent", proof=True):
    corr = f"{i:016x}"
    occurrence = {"key": "reused-key", "at": i * 1000, "corr": f"{i + 20:016x}",
                  "opening_sha256": f"{i:064x}"}
    send = {"home": str(home), "task": "mate", "delivery_corr": corr, "decisions": [occurrence]}
    evidence = {"ok": True, "exit": 0}
    if proof:
        evidence.update(delivery_corr=corr, openings=[[occurrence["key"], occurrence["opening_sha256"]]])
    rows.append({"at": 10000 + i, "hook": {"name": "judge-first", "mode": mode, "action": action,
                 "secondmate": "mate", "key": "reused-key", "send": evidence, "auto_send": send}})
    receipt = {"schema": "fm-judge-reversal.v1", "event_id": f"answer:{i}", "actor": "captain",
               "at": 20000, "outcome": "reversed", "unchanged_premises": True,
               "auto_send": {**send, "decision": occurrence}}
    del receipt["auto_send"]["decisions"]
    answers.append(copy.deepcopy(receipt))
    return answers[-1]

valid = fixture(1)
answers.append(copy.deepcopy(valid))
answers.append(dict(valid, event_id="duplicate-label"))
different = fixture(2)
different["auto_send"]["decision"] = valid["auto_send"]["decision"]
fixture(3, mode="shadow", action="would-auto")
fixture(4, proof=False)
fixture(5)["actor"] = "unknown"
fixture(6)["unchanged_premises"] = False
fixture(7)["auto_send"]["home"] = "/other/home"
fixture(8)["auto_send"]["task"] = "other-mate"
fixture(9)["auto_send"]["decision"]["corr"] = "fedcba9876543210"
fixture(10)["auto_send"]["decision"]["opening_sha256"] = "a" * 64
fixture(11)["at"] = 1
conflicting = fixture(12)
answers.append(dict(conflicting, actor="agent"))
fixture(13)
rows.append(copy.deepcopy(rows[-1]))
for i, conflict in enumerate(({"outcome": "upheld"}, {"actor": "agent"}, {"unchanged_premises": False}), 14):
    original = fixture(i)
    answers.append(dict(original, **conflict, event_id=f"conflict:{i}"))
cluster = fixture(17)
answers.append(dict(cluster, event_id="cluster:upheld", outcome="upheld"))
for i in (1, 2):
    sibling = copy.deepcopy(cluster)
    sibling["event_id"] = f"cluster:sibling-{i}"
    decision = sibling["auto_send"]["decision"]
    decision.update(key=f"cluster-key-{i}", opening_sha256=f"{i + 70:064x}")
    rows[-1]["hook"]["auto_send"]["decisions"].append(decision)
    rows[-1]["hook"]["send"]["openings"].append([decision["key"], decision["opening_sha256"]])
    answers.extend((sibling, copy.deepcopy(sibling)))
journal.write_text("".join(json.dumps(r) + "\n" for r in rows))
receipts.write_text("".join(json.dumps(r) + "\n" for r in answers))
PY
  before=$(cksum < "$LOG")$(cksum < "$receipts")
  out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary --reversals "$receipts")
  assert_contains "$out" '"confirmed_human_reversals": 3' "only unconflicted exact occurrences may count"
  assert_contains "$out" '"reversal_source": "operator-attested"' "receipt provenance must be visible"
  assert_contains "$out" '"live_sends_without_reversal_linkage": 1' "older live sends without evidence must be visible"
  out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary --since 10017 --reversals "$receipts")
  assert_contains "$out" '"confirmed_human_reversals": 2' "conflicting evidence for one decision may not suppress its cluster siblings"
  out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary --since 10018 --reversals "$receipts")
  assert_contains "$out" '"confirmed_human_reversals": 0' "since must apply to the sent event"
  assert_equals "$before" "$(cksum < "$LOG")$(cksum < "$receipts")" "summary mutated evidence"
  assert_equals 0 "$(calls)" "summary called the judge"
  assert_equals 0 "$(sends)" "summary sent an answer"
  printf '17\n' >> "$LOG"
  out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary --reversals "$receipts")
  assert_contains "$out" '"confirmed_human_reversals": 3' "reporting must tolerate a malformed legacy journal row"
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  run_hook "$(line_file malformed "$BENIGN")" >/dev/null
  assert_equals 0 "$(sends)" "summary tolerance accidentally changed ingest's behavior on the same malformed row"
  for bad_receipt in 'not-valid-json' '{"event_id":"incomplete"}'; do
    cp "$receipts" "$HOME_DIR/invalid-reversals.jsonl"
    printf '\n%s\n' "$bad_receipt" >> "$HOME_DIR/invalid-reversals.jsonl"
    rc=0
    out=$(env FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary \
      --reversals "$HOME_DIR/invalid-reversals.jsonl" 2>&1) || rc=$?
    expect_code 2 "$rc" "nonblank malformed receipts must refuse the report"
    assert_contains "$out" "malformed answer receipt on line" "receipt failure should identify the line"
    assert_not_contains "$out" "confirmed_human_reversals" "an invalid input produced a partial reversal report"
  done
  pass "summary counts exact operator-attested human reversals once and excludes unlinked, shadow and ambiguous events"
}

# The real fm-send, end to end: the answer reaches the secondmate's durable
# inbox once and the open keyed decision closes in the status log.
test_live_send_through_real_fm_send() {
  new_home e2e
  printf 'on\n' > "$HOME_DIR/config/judge-first"
  local fb="$HOME_DIR/fakebin" out corr stale current opening
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
  fm_write_secondmate_meta "$HOME_DIR/state/mate.meta" "$HOME_DIR" "sess:fm-mate"
  opening=${BENIGN/corr=0123456789abcdef /}
  printf '%s\n' "$opening" > "$HOME_DIR/state/mate.status"
  out=$(env PATH="$fb:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_SEND_BIN="$ROOT/bin/fm-send.sh" \
    FM_SEND_SETTLE=0 FM_JUDGE_LOG="$LOG" STUB_CALLS="$HOME_DIR/calls" \
    "$HOOK" ingest mate "$(line_file in "$opening")" 2>&1)
  assert_contains "$out" "auto=1" "the real send should succeed: $out"
  grep -qF 'judge auto-decided (recommended, Jev agreed): a - ' "$HOME_DIR/state/mate.inbox/001.msg" \
    || fail "the answer did not reach the durable inbox"
  [ ! -e "$HOME_DIR/state/mate.inbox/002.msg" ] || fail "the answer was delivered twice"
  sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/mate.status" | grep -qF 'resolved [key=clause-policy]: answered: judge auto-decided' \
    || fail "the keyed decision was not closed:"$'\n'"$(cat "$HOME_DIR/state/mate.status")"
  assert_equals sent "$(journal "rows[-1]['hook']['action']")" "the journal should end at sent"
  corr=$(journal "rows[-1]['hook']['auto_send']['delivery_corr']") || fail "native fm-send supplied no correlation"
  grep -Eq '^delivered_epoch=[0-9]+$' "$HOME_DIR/state/pending-replies/$corr" \
    || fail "correlation lacks delivery proof"
  assert_equals None "$(journal "rows[-1]['hook']['auto_send']['decisions'][0]['corr']")" \
    "a newly raised decision must join without inventing an original correlation"
  python3 - "$LOG" "$HOME_DIR/reversal.jsonl" <<'PY'
import json, sys
from pathlib import Path

row = json.loads(Path(sys.argv[1]).read_text().splitlines()[-1])
identity = row["hook"]["auto_send"]
identity["decision"], = identity.pop("decisions")
Path(sys.argv[2]).write_text(json.dumps({"schema": "fm-judge-reversal.v1", "event_id": "human:fixture-1",
    "actor": "captain", "at": row["at"] + 1, "outcome": "reversed", "unchanged_premises": True,
    "auto_send": identity}) + "\n")
PY
  out=$(FM_HOME="$HOME_DIR" FM_JUDGE_LOG="$LOG" "$HOOK" summary --reversals "$HOME_DIR/reversal.jsonl")
  assert_contains "$out" '"confirmed_human_reversals": 1' "summary failed to join the native fm-send receipt"
  if command -v tasks-axi >/dev/null 2>&1; then
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" hold clause-policy --title "Hold the exact policy choice" \
      --reason "Wait for the captain's selection" >/dev/null || fail "could not register a same-key captain hold"
    printf '%s\n' "$BENIGN" > "$HOME_DIR/state/mate.status"
    out=$(env PATH="$fb:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_SEND_SETTLE=0 \
      "$ROOT/bin/fm-send.sh" mate --resolve-key clause-policy "agent recommends option A" 2>&1) \
      && fail "a generic same-key send answered a captain hold"
    assert_contains "$out" "names a captain hold" "same-key send did not explain its refusal"
    [ ! -e "$HOME_DIR/state/mate.inbox/002.msg" ] || fail "the generic answer reached the worker"
    env PATH="$fb:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_SEND_SETTLE=0 \
      "$ROOT/bin/fm-send.sh" mate --captain-answer --resolve-key clause-policy "I choose option B." >/dev/null \
      || fail "the human answer could not use the existing keyed route"
    out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" show clause-policy --full)
    assert_contains "$out" "state: done" "the authorized answer did not close the same-key hold"
    assert_contains "$out" "I choose option B." "the authorized answer lost its actual words"
    assert_not_contains "$out" "agent recommends option A" "an ordinary recommendation was recorded as approval"
  fi
  stale=${BENIGN/at=1000/at=2000}
  current=${BENIGN/at=1000/at=3000}
  printf '%s\n' "$current" >> "$HOME_DIR/state/mate.status"
  out=$(env PATH="$fb:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_SEND_BIN="$ROOT/bin/fm-send.sh" \
    FM_SEND_SETTLE=0 FM_JUDGE_LOG="$LOG" STUB_CALLS="$HOME_DIR/calls" \
    "$HOOK" ingest mate "$(line_file in-stale "$stale")" 2>&1)
  assert_contains "$out" "auto=1" "the report instrumentation changed existing key-based send behavior"
  assert_equals "[]" "$(journal "rows[-1]['hook']['auto_send']['decisions']")" \
    "a key reused by a different open occurrence was linked to the old opening"
  pass "live: real fm-send links exact delivered occurrences and refuses to report a reused key as proof"
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
test_unheld_destructive_decisions
test_guard_rule_variants
test_judge_findings_and_failures_escalate
test_dedupe_by_decision_identity
test_captain_holds_are_never_answered
test_send_failure_leaves_ordinary_wake
test_non_decision_lines_are_ignored
test_summary
test_summary_human_reversals
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
            (home/'data').mkdir()  # the hold check needs a readable data dir; no backlog = no holds
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
