#!/usr/bin/env bash
# Behavior tests for the deterministic wake router prototype:
# bin/fm-wake-route.sh (classify, route, replay) over bin/fm-wake-router-lib.sh.
# Live-path cases drive the public CLI against a stand-in drain, merge, and
# teardown so every acknowledgement and action the router issues is recorded
# and asserted; one case runs the real bin/fm-wake-drain.sh end to end.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROUTE="$ROOT/bin/fm-wake-route.sh"
T=$(fm_test_tmproot fm-wake-route)
TAB=$(printf '\t')

# new_home <name>: an isolated home with stand-in drain, merge, teardown, and
# crew-state programs. Sets HOME_DIR, STATE, CONFIG, BIN.
new_home() {
  HOME_DIR="$T/$1"
  STATE="$HOME_DIR/state"
  CONFIG="$HOME_DIR/config"
  BIN="$HOME_DIR/bin"
  mkdir -p "$STATE" "$CONFIG" "$BIN" "$HOME_DIR/data"
  chmod 700 "$STATE"
  : > "$STATE/.wake-queue"
  cat > "$BIN/drain" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --ack-through ]; then
  printf '%s\n' "$*" >> "$STUB_DIR/ack.log"
  exit "${STUB_ACK_RC:-0}"
fi
cat "$STUB_DIR/transcript"
exit "${STUB_DRAIN_RC:-0}"
SH
  cat > "$BIN/merge" <<'SH'
#!/usr/bin/env bash
printf 'merge %s\n' "$*" >> "$STUB_DIR/actions.log"
[ "${STUB_MERGE_RC:-0}" -eq 0 ] || { echo "fm-pr-merge.sh: refusing: check 'ci' is red at head"; exit "$STUB_MERGE_RC"; }
echo "merged"
SH
  cat > "$BIN/teardown" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s\n' "$*" >> "$STUB_DIR/actions.log"
exit "${STUB_TEARDOWN_RC:-0}"
SH
  cat > "$BIN/crew" <<'SH'
#!/usr/bin/env bash
cat "$FM_STATE_OVERRIDE/$1.crew" 2>/dev/null
SH
  chmod +x "$BIN"/*
  : > "$HOME_DIR/ack.log"
  : > "$HOME_DIR/actions.log"
}

route() {  # <args...>: run the router in the current home; sets OUT and RC.
  RC=0
  OUT=$(STUB_DIR=$HOME_DIR FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    FM_WAKE_ROUTE_DRAIN_BIN="$BIN/drain" FM_WAKE_ROUTE_MERGE_BIN="$BIN/merge" \
    FM_WAKE_ROUTE_TEARDOWN_BIN="$BIN/teardown" FM_CREW_STATE_BIN="$BIN/crew" \
    "$ROUTE" "$@" 2>&1) || RC=$?
}

ack_line() {  # <through>
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation 7.1.abc\n' "$1"
}

row() {  # <seq> <kind> <key> <payload>
  printf '1700000000\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

annotation() {  # <status-key> <event>
  printf 'wake annotation: latest wake-EVENT observed at drain, not current state: %s: %s\n' "$1" "$2"
}

ship_meta() {  # <task> [extra k=v...]
  local task=$1
  shift
  fm_write_meta "$STATE/$task.meta" "window=firstmate:fm-$task" kind=ship mode=no-mistakes yolo=on "$@"
}

test_replay_shape_corpus_matches_every_expected_class() {
  local out rc=0
  out=$("$ROUTE" replay "$ROOT/tests/fixtures/wake-router-shapes.tsv" 2>&1) || rc=$?
  expect_code 0 "$rc" "shape replay"
  assert_contains "$out" "mismatches=0" "every documented shape routes to its expected class"
  assert_not_contains "$out" "MISMATCH" "no shape mismatches"
  assert_contains "$out" "SUMMARY${TAB}rows=" "summary line reports the split"
  pass "replay: documented wake-shape corpus routes every row to its expected class"
}

test_replay_session_corpus_reports_split() {
  local out rc=0
  out=$("$ROUTE" replay "$ROOT/tests/fixtures/wake-router-session.tsv" 2>&1) || rc=$?
  expect_code 0 "$rc" "session replay"
  assert_contains "$out" "auto-ack=" "auto-ack share reported"
  assert_contains "$out" "auto-act=" "auto-act share reported"
  assert_contains "$out" "needs-llm=" "needs-llm share reported"
  pass "replay: modeled session corpus reports a per-class share with no mismatch"
}

test_replay_reports_mismatch_and_fails() {
  local corpus="$T/bad.tsv" out rc=0
  printf 'bad\tsrc\tauto-ack\tsignal\tt.status\tsignal: t.status\tneeds-decision: pick one\tkind=ship\t-\t-\n' > "$corpus"
  out=$("$ROUTE" replay "$corpus" 2>&1) || rc=$?
  expect_code 1 "$rc" "a mismatching corpus fails"
  assert_contains "$out" "MISMATCH" "mismatch is named"
  pass "replay: a row whose verdict differs from its expected class fails the replay"
}

test_route_off_without_config_passes_drain_through() {
  new_home off
  { row 1 signal t.status "signal: t.status"; ack_line 1; echo "SOMETHING UNKNOWN"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "off router keeps the drain status"
  assert_equals "$(cat "$HOME_DIR/transcript")" "$OUT" "off router prints the drain transcript byte-for-byte"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "off router must never acknowledge"
  pass "route: without config/wake-router the router steps aside entirely"
}

test_route_steps_aside_in_away_mode() {
  new_home afk
  printf 'live\n' > "$CONFIG/wake-router"
  : > "$STATE/.afk"
  { row 1 signal t.status "signal: t.status"; annotation t.status "paused: waiting on CI"; ack_line 1; } > "$HOME_DIR/transcript"
  ship_meta t
  route route --execute
  assert_equals "$(cat "$HOME_DIR/transcript")" "$OUT" "away mode passes the transcript through"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "away mode must never acknowledge"
  pass "route: away or quiet mode leaves triage to its own owner"
}

test_route_shadow_logs_but_never_acts_or_acks() {
  new_home shadow
  printf 'auto-merge\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1
    annotation t.status "done [at=1700000000]: PR https://github.com/o/r/pull/7 checks green"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "shadow exit"
  assert_equals "$(cat "$HOME_DIR/transcript")" "$OUT" "shadow prints the transcript unchanged"
  [ ! -s "$HOME_DIR/actions.log" ] || fail "shadow must never run an action"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "shadow must never acknowledge"
  assert_grep "${TAB}shadow${TAB}1${TAB}signal${TAB}auto-act${TAB}merge t https://github.com/o/r/pull/7" "$STATE/.wake-router.log" \
    "shadow records the verdict it would have taken"
  pass "route: shadow mode records verdicts without acting or acknowledging"
}

test_route_live_all_routed_acks_without_supervisor() {
  new_home allrouted
  printf 'live\n' > "$CONFIG/wake-router"
  ship_meta t
  printf 'state: working · source: run-step · running\n' > "$STATE/u.crew"
  ship_meta u
  { row 4 signal t.status "signal: t.status"; row 5 stale firstmate:fm-u "stale: firstmate:fm-u"; ack_line 5
    annotation t.status "paused [at=1700000000]: waiting on upstream CI"
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else."; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "fully routed batch exits 0"
  assert_contains "$OUT" "no supervisor turn needed" "routed batch says no turn is needed"
  assert_equals "--ack-through 5 --recovery-generation 7.1.abc" "$(cat "$HOME_DIR/ack.log")" \
    "router runs the drain's own acknowledgement exactly once"
  pass "route: a fully routed batch is acknowledged with the drain's own command and wakes nobody"
}

test_route_live_presents_only_needs_llm_rows() {
  new_home mixed
  printf 'live\n' > "$CONFIG/wake-router"
  ship_meta t
  ship_meta d
  { row 1 signal t.status "signal: t.status"; row 2 signal d.status "signal: d.status"; ack_line 2
    annotation t.status "paused: waiting on upstream CI"
    annotation d.status "needs-decision [key=scope]: widen the fix?"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 10 "$RC" "a needs-llm batch exits 10"
  assert_contains "$OUT" "$(row 2 signal d.status "signal: d.status")" "needs-llm row presented verbatim"
  assert_contains "$OUT" "d.status: needs-decision [key=scope]: widen the fix?" "its annotation is presented"
  assert_not_contains "$OUT" "$(row 1 signal t.status "signal: t.status")" "auto-ack row is not presented"
  assert_contains "$OUT" "WAKE ROUTER ROUTED: row 1 signal auto-ack" "routed row is summarized in one line"
  assert_contains "$OUT" "$(ack_line 2)" "the unchanged acknowledgement covers every row"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "router must not acknowledge a batch the supervisor still owns"
  pass "route: a mixed batch presents only needs-llm rows plus one-line routed summaries"
}

test_route_live_merge_runs_guarded_script_and_reports_outcome_once() {
  new_home merge
  printf 'live\nauto-merge\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1
    annotation t.status "done [at=1700000000]: PR https://github.com/o/r/pull/7 checks green"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "merged batch is fully routed"
  assert_equals "merge t https://github.com/o/r/pull/7" "$(cat "$HOME_DIR/actions.log")" "merge goes through the guarded merge script"
  assert_grep "merged https://github.com/o/r/pull/7 (t)" "$STATE/.wake-router-outcomes" "captain outcome is recorded"
  ship_meta d
  : > "$HOME_DIR/ack.log"
  { row 2 signal d.status "signal: d.status"; ack_line 2; annotation d.status "failed: tests red"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 10 "$RC" "next decision wakes the supervisor"
  assert_contains "$OUT" "WAKE ROUTER OUTCOMES" "outcomes section presented"
  assert_contains "$OUT" "merged https://github.com/o/r/pull/7 (t)" "the merge outcome reaches the supervisor"
  route route --execute
  assert_not_contains "$OUT" "merged https://github.com/o/r/pull/7 (t)" "an outcome is presented once"
  pass "route: auto-merge runs the guarded merge script and owes the captain one batched outcome"
}

test_route_live_refused_action_becomes_needs_llm() {
  new_home refused
  printf 'live\nauto-merge\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1
    annotation t.status "done [at=1700000000]: PR https://github.com/o/r/pull/7 checks green"; } > "$HOME_DIR/transcript"
  STUB_MERGE_RC=1 route route --execute
  expect_code 10 "$RC" "a refused merge reaches the supervisor"
  assert_contains "$OUT" "auto-act merge refused (exit 1)" "refusal is named"
  assert_contains "$OUT" "check 'ci' is red at head" "refusal detail is carried"
  assert_contains "$OUT" "$(row 1 signal t.status "signal: t.status")" "the row itself is presented"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "refused action must not be acknowledged by the router"
  [ ! -s "$STATE/.wake-router-outcomes" ] || fail "a refused merge must not claim an outcome"
  pass "route: a guard refusal turns the auto-act row into a needs-llm row"
}

test_route_live_cleanup_with_queued_backlog_escalates() {
  new_home cleanup
  printf 'live\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 3 check merged-t-x "check: merge landed: t https://github.com/o/r/pull/7"; ack_line 3; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "cleanup with an empty backlog is fully routed"
  assert_equals "teardown t" "$(cat "$HOME_DIR/actions.log")" "cleanup goes through guarded teardown"
  : > "$HOME_DIR/ack.log"
  : > "$HOME_DIR/actions.log"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n- next-task: do the next thing\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  route route --execute
  expect_code 10 "$RC" "queued work after cleanup needs the supervisor"
  assert_contains "$OUT" "queued work must be re-evaluated" "the follow-up is named"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "supervisor owns the acknowledgement"
  pass "route: merge-landed cleanup is scripted, and queued backlog work still reaches the supervisor"
}

test_route_unknown_drain_line_forces_supervisor() {
  new_home forcing
  printf 'live\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1; annotation t.status "paused: waiting"
    echo "OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):"
    echo "t key=scope needs-decision: widen?"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 10 "$RC" "an unowned section wakes the supervisor"
  assert_contains "$OUT" "OPEN DECISIONS (still open" "section header presented verbatim"
  assert_contains "$OUT" "t key=scope needs-decision: widen?" "section body presented verbatim"
  [ ! -s "$HOME_DIR/ack.log" ] || fail "router must not acknowledge past an unowned section"
  pass "route: any drain line the router does not own is presented and forces a supervisor turn"
}

test_route_drain_failure_presents_raw_transcript() {
  new_home drainfail
  printf 'live\n' > "$CONFIG/wake-router"
  { row 1 signal t.status "signal: t.status"; ack_line 1; echo "wake drain: something went wrong"; } > "$HOME_DIR/transcript"
  STUB_DRAIN_RC=1 route route --execute
  expect_code 10 "$RC" "a failed drain is handed to the supervisor"
  assert_equals "$(cat "$HOME_DIR/transcript")" "$OUT" "the raw transcript is presented unchanged"
  pass "route: a drain failure presents the raw transcript rather than routing it"
}

test_route_failed_ack_presents_whole_batch() {
  new_home ackfail
  printf 'live\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1; annotation t.status "paused: waiting"; } > "$HOME_DIR/transcript"
  STUB_ACK_RC=1 route route --execute
  expect_code 10 "$RC" "a failed acknowledgement wakes the supervisor"
  assert_contains "$OUT" "$(row 1 signal t.status "signal: t.status")" "the whole batch is presented"
  pass "route: a failed router acknowledgement hands the whole batch to the supervisor"
}

test_route_outcome_backstop_coverage() {
  local line="done [at=1700000000]: PR https://github.com/o/r/pull/7 checks green"
  new_home backstop
  printf 'live\nauto-merge\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1; annotation t.status "$line"
    echo "STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):"
    echo "t $line"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "a backstop item decided by a routed row is covered"
  new_home backstop2
  printf 'live\n' > "$CONFIG/wake-router"
  ship_meta t
  { row 1 signal t.status "signal: t.status"; ack_line 1; annotation t.status "paused: waiting"
    echo "STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):"
    echo "other done: PR https://github.com/o/r/pull/9"; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 10 "$RC" "an uncovered backstop item wakes the supervisor"
  assert_contains "$OUT" "other done: PR https://github.com/o/r/pull/9" "uncovered item presented"
  pass "route: an outcome-backstop item is covered only by a routed row deciding on that exact event"
}

test_heartbeat_fingerprint_is_two_phase() {
  new_home heartbeat
  printf 'live\n' > "$CONFIG/wake-router"
  printf 'working: step one\n' > "$STATE/t.status"
  ship_meta t
  printf '1700000000\t9\theartbeat\theartbeat\theartbeat\n' > "$STATE/.wake-queue"
  { row 9 heartbeat heartbeat heartbeat; ack_line 9; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 10 "$RC" "first heartbeat is a fleet review"
  assert_present "$STATE/.wake-router-heartbeat.pending" "presented fingerprint is pending"
  route route --execute
  expect_code 10 "$RC" "a re-presented, unacknowledged heartbeat is still a review"
  : > "$STATE/.wake-queue"
  { row 10 heartbeat heartbeat heartbeat; ack_line 10; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 0 "$RC" "after acknowledgement an unchanged fleet heartbeat is routed"
  printf 'blocked: credentials\n' >> "$STATE/t.status"
  { row 11 heartbeat heartbeat heartbeat; ack_line 11; } > "$HOME_DIR/transcript"
  route route --execute
  expect_code 10 "$RC" "a changed fleet makes the heartbeat a review again"
  pass "route: a heartbeat is skipped only when the fleet is unchanged since an acknowledged review"
}

test_classify_real_drain_transcript() {
  local out state="$T/real/state"
  mkdir -p "$state"
  chmod 700 "$state"
  printf 'paused [at=1700000000]: waiting on upstream CI\n' > "$state/t.status"
  fm_write_meta "$state/t.meta" "window=firstmate:fm-t" kind=ship mode=no-mistakes yolo=on
  append_wake "$state" signal t.status "signal: t.status"
  append_wake "$state" check merged-gone-x "check: merge landed: gone https://github.com/o/r/pull/8"
  out=$(FM_HOME="$T/real" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" 2>&1 \
    | FM_HOME="$T/real" FM_STATE_OVERRIDE="$state" "$ROUTE" classify)
  assert_contains "$out" "1${TAB}signal${TAB}auto-ack${TAB}none${TAB}worker declared a wait (paused:)" \
    "the real annotation drives the signal verdict"
  assert_contains "$out" "2${TAB}check${TAB}auto-ack${TAB}none${TAB}merge landed for a task already cleaned up" \
    "a merge for a task with no record is acknowledged"
  # This fixture home runs no watcher, so the drain's own liveness warning is a
  # line the router does not own: the batch must still reach the supervisor.
  assert_contains "$out" "BATCH${TAB}needs-llm${TAB}drain printed" "watcher warning forces the supervisor"
  pass "classify: a real bin/fm-wake-drain.sh transcript is parsed and routed"
}

fm_test_run \
  test_replay_shape_corpus_matches_every_expected_class \
  test_replay_session_corpus_reports_split \
  test_replay_reports_mismatch_and_fails \
  test_route_off_without_config_passes_drain_through \
  test_route_steps_aside_in_away_mode \
  test_route_shadow_logs_but_never_acts_or_acks \
  test_route_live_all_routed_acks_without_supervisor \
  test_route_live_presents_only_needs_llm_rows \
  test_route_live_merge_runs_guarded_script_and_reports_outcome_once \
  test_route_live_refused_action_becomes_needs_llm \
  test_route_live_cleanup_with_queued_backlog_escalates \
  test_route_unknown_drain_line_forces_supervisor \
  test_route_drain_failure_presents_raw_transcript \
  test_route_failed_ack_presents_whole_batch \
  test_route_outcome_backstop_coverage \
  test_heartbeat_fingerprint_is_two_phase \
  test_classify_real_drain_transcript
