#!/usr/bin/env bash
# Behavior tests for bin/fm-cost-ledger.sh: per-task cost and quality rows and query.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-cost-ledger)
LEDGER="$ROOT/bin/fm-cost-ledger.sh"
NOW=$(date +%s)
START=$((NOW - 3600))

make_case() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config"
  : > "$d/home/config/cost-ledger"
  fm_write_meta "$d/home/state/task.meta" \
    "window=firstmate:fm-task" \
    "endpoint_task_id=task" \
    "worktree=$d/wt" \
    "project=$d/project" \
    "kind=ship" \
    "mode=local-only" \
    "harness=cursor" \
    "model=default" \
    "effort=high" \
    "spawn_gen=s$NOW.1.abc"
  printf '%s\n' "$d"
}

in_home() {
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$1/home" \
    FM_STATE_OVERRIDE="$1/home/state" FM_DATA_OVERRIDE="$1/home/data" \
    FM_CONFIG_OVERRIDE="$1/home/config" "$LEDGER" "${@:2}"
}

test_record_and_query() {
  local d out line
  d=$(make_case record-query)
  {
    printf 'working [at=%s]: setup\n' "$START"
    printf 'needs-decision [at=%s]: pick a\n' "$((START + 10))"
    printf 'resolved [at=%s]: pick a\n' "$((START + 20))"
    printf 'done [at=%s]: ready branch\n' "$((START + 100))"
    printf 'done [at=%s]: still ready\n' "$((START + 110))"
  } > "$d/home/state/task.status"
  out=$(in_home "$d" record task) || fail "record failed: $out"
  assert_contains "$out" "recorded task" "record should succeed"
  assert_present "$d/home/data/cost-ledger.jsonl" "ledger file missing"
  line=$(tail -1 "$d/home/data/cost-ledger.jsonl")
  jq -e --argjson rework 1 '
    .v == 1 and .task == "task" and .harness == "cursor" and .outcome == "done"
    and .quality.rework == $rework and .quality.needs_decision == 1
    and .spend.worker == "unknown"
  ' <<< "$line" >/dev/null || fail "bad record: $line"
  out=$(in_home "$d" query --harness cursor --json) || fail "query failed"
  jq -e '.schema == "fm-cost-ledger-query.v1" and (.records | length) == 1 and (.by_harness.cursor.tasks == 1)' \
    <<< "$out" >/dev/null || fail "bad query json: $out"
  out=$(in_home "$d" record task) || fail "repeat record failed"
  assert_equals 1 "$(wc -l < "$d/home/data/cost-ledger.jsonl" | tr -d ' ')" "duplicate record appended"
  pass "record captures quality metrics and query filters by harness"
}

test_disabled_without_flag() {
  local d
  d=$(make_case disabled)
  rm -f "$d/home/config/cost-ledger"
  in_home "$d" record task >/dev/null || fail "disabled record should exit 0"
  assert_absent "$d/home/data/cost-ledger.jsonl" "disabled recording wrote data"
  pass "recording stays off without config/cost-ledger"
}

test_record_and_query
test_disabled_without_flag
