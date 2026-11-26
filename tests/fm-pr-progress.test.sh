#!/usr/bin/env bash
# tests/fm-pr-progress.test.sh - bin/fm-pr-progress.sh: newly created PRs per
# home read only from local status records, and the alarm for busy lanes with
# no new PR for a full continuous hour, with one deduplicated stop-and-diagnose
# cue per episode. Status logs, lane counts, the clock, and the send command
# are fixtures; no forge is read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROGRESS="$ROOT/bin/fm-pr-progress.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-progress-tests)
T0=1790000000

make_home() {  # <name> -> home with one local ship and two second mates
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/ship-1.meta" "kind=ship" "harness=codex"
  fm_write_meta "$home/state/vm.meta" "kind=secondmate" "home=/remote/vm"
  fm_write_meta "$home/state/ce.meta" "kind=secondmate" "home=/remote/ce"
  : > "$home/state/ship-1.status"
  : > "$home/state/vm.status"
  : > "$home/state/ce.status"
  cat > "$home/send" <<SH
#!/usr/bin/env bash
printf 'SEND %s\n' "\$*" >> "$home/sends"
SH
  chmod +x "$home/send"
  printf '%s\n' "$home"
}

progress() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" FM_PR_PROGRESS_NOW="$now" FM_PR_PROGRESS_SEND_CMD="$home/send" "$PROGRESS" "$@"
}

counts() {  # <home> <observed> <home:working:evidence>...
  local home=$1 observed=$2 rows='' spec h w e
  shift 2
  for spec in "$@"; do
    IFS=: read -r h w e <<EOF
$spec
EOF
    rows="$rows${rows:+,}{\"home\":\"$h\",\"working\":$w,\"evidence\":\"$e\",\"observed_epoch\":$observed}"
  done
  printf '{"schema":"fm-lane-count.v1","homes":[%s]}\n' "$rows" > "$home/counts.json"
}

scan() {  # <home> <now>
  progress "$1" "$2" scan --counts-file "$1/counts.json"
}

sends() { [ -f "$1/sends" ] && grep -c '^SEND ' "$1/sends" || echo 0; }

test_count_reads_first_stamped_appearance_per_home() {
  local home out json
  home=$(make_home count)
  {
    printf 'done [at=%s]: PR https://github.com/o/a/pull/1\n' $((T0 - 7200))
    printf 'done [at=%s]: PR https://github.com/o/a/pull/1 again\n' $((T0 - 60))
    printf 'done [at=%s]: PR https://github.com/o/a/pull/2\n' $((T0 - 60))
    printf 'done: PR https://github.com/o/a/pull/3 with no stamp\n'
  } >> "$home/state/ship-1.status"
  printf 'done [key=child-pr-c1] [at=%s]: child c1 PR ready: https://gitlab.example.com/g/p/-/merge_requests/4\n' $((T0 - 30)) >> "$home/state/vm.status"
  rm -f "$home/state/ce.status"
  out=$(progress "$home" "$T0" count)
  assert_contains "$out" "self: prs 1 since $((T0 - 3600))" "a PR first seen two hours ago, or one without a stamp, was counted as new"
  assert_contains "$out" "vm: prs 1 since" "a mate's relayed child PR was not counted"
  assert_contains "$out" "ce: prs unknown since" "a mate with no relay log was not unknown"
  json=$(progress "$home" "$T0" count --since $((T0 - 10000)) --json)
  [ "$(printf '%s' "$json" | jq -c '[.homes[] | [.home, .count]]')" = '[["self",2],["ce",null],["vm",1]]' ] \
    || fail "--since did not widen the window or unknown was not null: $json"
  pass "count takes each PR's earliest stamped status line per home and reports a missing log as unknown"
}

test_busy_hour_without_a_pr_alarms_once_and_cues_once() {
  local home out episode
  home=$(make_home alarm)
  counts "$home" "$T0" vm:3:fresh
  [ -z "$(scan "$home" "$T0")" ] || fail "the first busy observation alarmed"
  counts "$home" $((T0 + 1800)) vm:3:fresh
  [ -z "$(scan "$home" $((T0 + 1800)))" ] || fail "half an hour without a PR alarmed"
  counts "$home" $((T0 + 3600)) vm:2:fresh
  out=$(scan "$home" $((T0 + 3600)))
  assert_contains "$out" "no-pr-progress: vm busy 2 lanes and no new PR since" "a busy hour without a PR did not alarm"
  assert_contains "$out" "(cue: bin/fm-pr-progress.sh cue vm " "the alarm did not name its cue command"
  episode=$(printf '%s\n' "$out" | sed -n 's/.* episode \([^ ]*\) (cue.*/\1/p')
  [ -n "$episode" ] || fail "the alarm named no episode: $out"
  counts "$home" $((T0 + 3900)) vm:2:fresh
  [ -z "$(scan "$home" $((T0 + 3900)))" ] || fail "a repeated wake re-alarmed the same episode"
  out=$(progress "$home" $((T0 + 3900)) cue vm "$episode")
  assert_contains "$out" "sent: yes" "the cue was not sent"
  assert_contains "$(cat "$home/sends")" "Stop spawning new work now and diagnose" "the cue did not say to stop spawning and diagnose"
  assert_contains "$(cat "$home/sends")" "Do not exit, destroy, or reshuffle any worker" "the cue did not protect the workers"
  out=$(progress "$home" $((T0 + 3900)) cue vm "$episode")
  assert_contains "$out" "sent: already" "a repeated cue was not deduplicated"
  [ "$(sends "$home")" = 1 ] || fail "the cue was sent more than once"
  out=$(progress "$home" $((T0 + 3900)) cue self "self-1")
  assert_contains "$out" "sent: no" "this home was cued as if it were a mate"
  pass "a full busy hour with no new PR alarms once, and its stop-and-diagnose cue is sent once"
}

test_a_real_pr_recovery_and_stale_or_unknown_data_reset_the_hour() {
  local home
  home=$(make_home reset)
  counts "$home" "$T0" vm:3:fresh; scan "$home" "$T0" >/dev/null
  printf 'done [at=%s]: child c2 done: PR https://github.com/o/b/pull/9\n' $((T0 + 3000)) >> "$home/state/vm.status"
  counts "$home" $((T0 + 3600)) vm:3:fresh
  [ -z "$(scan "$home" $((T0 + 3600)))" ] || fail "a PR created inside the hour did not reset it"
  counts "$home" $((T0 + 6599)) vm:3:fresh
  [ -z "$(scan "$home" $((T0 + 6599)))" ] || fail "the hour did not restart at the new PR"
  counts "$home" $((T0 + 6600)) vm:3:fresh
  assert_contains "$(scan "$home" $((T0 + 6600)))" "no-pr-progress: vm" "a full hour after the last PR did not alarm"
  home=$(make_home recover)
  counts "$home" "$T0" vm:3:fresh; scan "$home" "$T0" >/dev/null
  counts "$home" $((T0 + 1800)) vm:0:fresh; scan "$home" $((T0 + 1800)) >/dev/null
  counts "$home" $((T0 + 3700)) vm:3:fresh
  [ -z "$(scan "$home" $((T0 + 3700)))" ] || fail "an idle observation did not reset the busy hour"
  counts "$home" $((T0 + 4000)) vm:3:stale; scan "$home" $((T0 + 4000)) >/dev/null
  counts "$home" $((T0 + 7400)) vm:3:fresh
  [ -z "$(scan "$home" $((T0 + 7400)))" ] || fail "stale evidence did not break the busy hour"
  rm -f "$home/state/vm.status"
  counts "$home" $((T0 + 7500)) vm:3:fresh; scan "$home" $((T0 + 7500)) >/dev/null
  counts "$home" $((T0 + 11200)) vm:3:fresh
  [ -z "$(scan "$home" $((T0 + 11200)))" ] || fail "unknown PR telemetry was treated as proof of no PR"
  pass "a real PR, an idle home, stale evidence, and unknown telemetry each reset the hour or withhold the alarm"
}

test_homes_are_tracked_independently() {
  local home out
  home=$(make_home multi)
  counts "$home" "$T0" self:2:fresh vm:3:fresh ce:1:fresh
  scan "$home" "$T0" >/dev/null
  printf 'done [at=%s]: child c3 PR ready: https://github.com/o/c/pull/5\n' $((T0 + 100)) >> "$home/state/ce.status"
  counts "$home" $((T0 + 3600)) self:2:fresh vm:3:fresh ce:1:fresh
  out=$(scan "$home" $((T0 + 3600)))
  assert_contains "$out" "no-pr-progress: self busy 2 lanes" "this home's own busy hour did not alarm"
  assert_contains "$out" "no-pr-progress: vm busy 3 lanes" "the second mate's busy hour did not alarm"
  assert_not_contains "$out" "no-pr-progress: ce" "a home that created a PR alarmed"
  [ "$(printf '%s\n' "$out" | grep -c 'no-pr-progress:')" = 2 ] || fail "the alarm lines were not one per affected home: $out"
  pass "each home's busy hour and PR evidence is tracked on its own"
}

test_count_reads_first_stamped_appearance_per_home
test_busy_hour_without_a_pr_alarms_once_and_cues_once
test_a_real_pr_recovery_and_stale_or_unknown_data_reset_the_hour
test_homes_are_tracked_independently
echo "# fm-pr-progress.test.sh: all assertions passed"
