#!/usr/bin/env bash
# Captain-status age guard: lib classification and fm-guard warning on main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-captain-status-age-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-status-age)

write_captain_status() {  # <home> <updated-iso>
  local home=$1 updated=$2 dir
  dir="$home/data/secondbrain/status"
  mkdir -p "$dir"
  jq -cn --arg updated "$updated" '{schema:"captain-status.v1",updated:$updated,headline:"test"}' \
    > "$dir/captain-status.json"
}

iso_hours_ago() {  # <hours>
  date -u -d "@$(($(date +%s) - $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${1}H" +%Y-%m-%dT%H:%M:%SZ
}

test_lib_absent_and_fresh() {
  local home=$TMP_ROOT/lib-absent
  mkdir -p "$home/data"
  FM_HOME="$home" fm_captain_status_is_stale && fail "absent file reported stale"
  write_captain_status "$home" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  FM_HOME="$home" fm_captain_status_is_stale && fail "fresh file reported stale"
  pass "captain-status age lib stays silent for absent and fresh files"
}

test_lib_stale_threshold() {
  local home=$TMP_ROOT/lib-stale
  write_captain_status "$home" "$(iso_hours_ago 2)"
  FM_HOME="$home" FM_CAPTAIN_STATUS_MAX_AGE_SECS=2700 fm_captain_status_is_stale \
    || fail "two-hour-old file did not read stale at 45-minute threshold"
  FM_HOME="$home" FM_CAPTAIN_STATUS_MAX_AGE_SECS=999999 fm_captain_status_is_stale \
    && fail "two-hour-old file read stale under a huge threshold"
  pass "captain-status age lib honors the configured threshold"
}

run_guard_main() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="${2:-$1/non-git-root}" FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_warns_main_when_stale() {
  local home=$TMP_ROOT/guard-stale out
  home="$TMP_ROOT/guard-stale-home"
  mkdir -p "$home/non-git-root"
  write_captain_status "$home" "$(iso_hours_ago 2)"
  out=$(run_guard_main "$home")
  assert_contains "$out" "WARNING: captain-status.json is" "guard did not warn on stale captain-status"
  assert_contains "$out" "threshold 45 minutes" "guard warning did not name the threshold"
  pass "fm-guard warns main when captain-status.json is stale"
}

test_guard_silent_when_fresh_or_absent() {
  local home=$TMP_ROOT/guard-fresh out
  home="$TMP_ROOT/guard-fresh-home"
  mkdir -p "$home/non-git-root"
  out=$(run_guard_main "$home")
  assert_not_contains "$out" "captain-status.json" "guard warned with no captain-status file"
  write_captain_status "$home" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out=$(run_guard_main "$home")
  assert_not_contains "$out" "WARNING: captain-status.json" "guard warned on a fresh captain-status file"
  pass "fm-guard stays silent for absent or fresh captain-status"
}

test_lib_absent_and_fresh
test_lib_stale_threshold
test_guard_warns_main_when_stale
test_guard_silent_when_fresh_or_absent
