#!/usr/bin/env bash
# tests/fm-lane-refill.test.sh - bin/fm-lane-count.sh, the one owner of what a
# genuinely working lane is (live evidence only, held, metadata-only, paused,
# and finished lanes excluded, live-process occupancy kept separate), and
# bin/fm-lane-refill.sh, the away-mode-only shortage episode and its one
# deduplicated refill cue. Everything is a fixture: snapshot and count
# documents, a synthetic /proc tree, and a send command that only records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="$ROOT/bin/fm-lane-count.sh"
REFILL="$ROOT/bin/fm-lane-refill.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-refill-tests)
NOW=$(date +%s)

snapshot_fixture() {  # <file>
  cat > "$1" <<EOF
{"schema":"fm-fleet-snapshot.v1",
 "tasks":[
  {"id":"s1","kind":"ship","harness":"codex","current_state":{"state":"working","source":"pane"}},
  {"id":"s2","kind":"ship","current_state":{"state":"working","source":"status-log"}},
  {"id":"s3","kind":"scout","current_state":{"state":"paused","source":"pane"}},
  {"id":"vm","kind":"secondmate","current_state":{"state":"unknown","source":"none"}}],
 "secondmate_current":{"records":[
  {"id":"vm","provenance":{"selected":"structured-home","summary_source":"remote-ledger"},
   "freshness":{"status":"fresh","age_seconds":60},"current":{"state":"active_child_work"},
   "active_children":[
     {"id":"r1","state":"working","source":"pane","harness":"agy"},
     {"id":"r2","state":"working","source":"acp","harness":"codex"},
     {"id":"r3","state":"working","source":"run-step","harness":"agy"},
     {"id":"r4","state":"working","source":"status-log","harness":"agy"},
     {"id":"r5","state":"working","source":"pane","harness":"claude"}],
   "holds":[{"id":"r5"}],"decisions_open":[],
   "counts":{"active_children":5,"endpoints":40},
   "lane_target":{"value":8,"source":"lane-capacity"},"lane_occupancy":82,"lane_occupancy_by_tool":{"agy":70,"codex":12}},
  {"id":"ce","provenance":{"selected":"structured-home","summary_source":"remote-ledger-cache"},
   "freshness":{"status":"cached","age_seconds":30000},"current":{"state":"active_child_work"},
   "active_children":[],"holds":[],"decisions_open":[],"counts":{"active_children":0,"endpoints":3},
   "lane_target":{"value":4,"source":"lane-capacity"}},
  {"id":"cut","provenance":{"selected":"structured-home","summary_source":"remote-ledger"},
   "freshness":{"status":"fresh","age_seconds":10},"current":{"state":"active_child_work"},
   "active_children":[{"id":"x1","state":"working","source":"pane"}],"holds":[],"decisions_open":[],
   "counts":{"active_children":9,"endpoints":12},"lane_target":null},
  {"id":"dark","provenance":{"selected":"unknown"}}]}}
EOF
}

test_lane_count_counts_only_genuinely_working_lanes_per_home() {
  local dir out json
  dir="$TMP_ROOT/count"
  mkdir -p "$dir/state"
  snapshot_fixture "$dir/snapshot.json"
  json=$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" "$COUNT" --json --snapshot-file "$dir/snapshot.json") \
    || fail "lane count failed on a valid snapshot"
  [ "$(printf '%s' "$json" | jq -c '.homes[] | select(.home == "self") | [.working, .active, .total]')" = '[1,2,3]' ] \
    || fail "this home's own counts were wrong: $json"
  [ "$(printf '%s' "$json" | jq -c '.homes[] | select(.home == "vm") | [.working, .active, .total, .target, .occupancy, .evidence]')" \
    = '[3,5,40,8,82,"fresh"]' ] \
    || fail "a fresh mate's metadata-only and held lanes were counted as working: $json"
  [ "$(printf '%s' "$json" | jq -r '.homes[] | select(.home == "ce") | .evidence')" = stale ] \
    || fail "a cached summary was not stale"
  [ "$(printf '%s' "$json" | jq -r '.homes[] | select(.home == "cut") | .evidence')" = incomplete ] \
    || fail "a truncated active-children list was not incomplete"
  [ "$(printf '%s' "$json" | jq -c '.homes[] | select(.home == "dark") | [.working, .evidence]')" = '[null,"unknown"]' ] \
    || fail "a home without a structured summary was given counts"
  out=$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" "$COUNT" --snapshot-file "$dir/snapshot.json")
  assert_contains "$out" "vm: working 3 active 5 total 40 target 8 occupancy 82 evidence fresh tools agy=2/70,codex=1/12" "the text line lost a field or its per-tool counts"
  assert_contains "$out" "self: working 1 active 2 total 3 target none occupancy unknown evidence fresh tools codex=1/unknown" "this home's per-tool line was wrong"
  assert_contains "$out" "ce: working 0 active 0 total 3 target 4 occupancy unknown evidence stale tools none" "a home with no working lanes did not report no tools"
  [ "$(printf '%s' "$json" | jq -c '.homes[] | select(.home == "vm") | .working_by_tool')" = '{"agy":2,"codex":1}' ] \
    || fail "per-tool working counts counted held or metadata-only lanes: $json"
  printf '%s\n' "$out" | grep '^vm:' | grep -Eq 'working ([0-9]+)' || fail "the working count is not readable as 'working N'"
  pass "lane count reports genuinely working lanes per home, separately from active, total, target, and occupancy"
}

test_occupancy_counts_live_harness_processes_once_per_worktree() {
  local dir proc uid
  dir="$TMP_ROOT/occupancy"
  proc="$dir/proc"
  uid=$(id -u)
  mkdir -p "$dir/state" "$dir/wt1/sub" "$dir/wt2" "$dir/wt3" "$dir/wt2-other" "$proc"
  fm_write_meta "$dir/state/t1.meta" "kind=scout" "harness=agy" "worktree=$dir/wt1"
  fm_write_meta "$dir/state/t1dup.meta" "kind=scout" "harness=agy" "worktree=$dir/wt1/"
  fm_write_meta "$dir/state/t2.meta" "kind=scout" "harness=codex" "worktree=$dir/wt2"
  fm_write_meta "$dir/state/t3.meta" "kind=ship" "harness=codex" "worktree=$dir/wt3"
  fm_write_meta "$dir/state/mate.meta" "kind=secondmate" "harness=codex" "worktree=$dir/wt3"
  fake_proc() {  # <pid> <comm> <uid> <state> <cwd>
    mkdir -p "$proc/$1"
    printf '%s\n' "$2" > "$proc/$1/comm"
    printf 'Name:\t%s\nState:\t%s (x)\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$4" "$3" "$3" "$3" "$3" > "$proc/$1/status"
    ln -s "$5" "$proc/$1/cwd"
  }
  fake_proc 101 agy "$uid" S "$dir/wt1/sub"
  fake_proc 102 agy "$uid" S "$dir/wt1"
  fake_proc 103 codex "$uid" Z "$dir/wt2"
  fake_proc 104 bash "$uid" S "$dir/wt3"
  fake_proc 105 codex $((uid + 1)) S "$dir/wt2"
  fake_proc 106 codex "$uid" S "$dir/wt2-other"
  [ "$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$proc" "$COUNT" --occupancy)" = 1 ] \
    || fail "occupancy counted a zombie, a foreign user, an unrelated name, a sibling path, or a duplicate: $(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$proc" "$COUNT" --occupancy)"
  fake_proc 107 codex "$uid" R "$dir/wt3"
  [ "$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$proc" "$COUNT" --occupancy)" = 2 ] \
    || fail "a live harness process inside a task worktree was not counted"
  [ "$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$proc" "$COUNT" --occupancy-json)" = '{"total":2,"by_tool":{"agy":1,"codex":1}}' ] \
    || fail "occupancy by tool was wrong: $(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$proc" "$COUNT" --occupancy-json)"
  [ "$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/absent" "$COUNT" --occupancy)" = unknown ] \
    || fail "a host without /proc did not report unknown occupancy"
  pass "occupancy counts each worktree with a live same-user harness process once, and never invents one"
}

# --- refill -----------------------------------------------------------------

refill_home() {  # <name> -> home with a registered mate and an away record
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/vm.meta" "kind=secondmate" "home=/remote/vm"
  cat > "$home/send" <<SH
#!/usr/bin/env bash
printf 'SEND %s\n' "\$*" >> "$home/sends"
SH
  chmod +x "$home/send"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep all lanes full' --keep-full >/dev/null 2>&1 \
    || fail "away entry failed"
  printf '%s\n' "$home"
}

counts() {  # <home> <working> <target> <evidence> <observed-epoch>
  printf '{"schema":"fm-lane-count.v1","homes":[{"home":"self","working":2,"target":null,"evidence":"fresh","observed_epoch":%s},{"home":"vm","working":%s,"target":%s,"evidence":"%s","observed_epoch":%s}]}\n' \
    "$5" "$2" "$3" "$4" "$5" > "$1/counts.json"
}

scan() {  # <home>
  FM_HOME="$1" "$REFILL" scan --counts-file "$1/counts.json"
}

cue() {  # <home> <mate> <episode>
  FM_HOME="$1" FM_LANE_REFILL_SEND_CMD="$1/send" "$REFILL" cue "$2" "$3"
}

sends() { [ -f "$1/sends" ] && grep -c '^SEND ' "$1/sends" || echo 0; }

test_a_sustained_shortage_cues_once_per_episode() {
  local home out t0 episode
  home=$(refill_home sustained)
  t0=$((NOW - 3000))
  counts "$home" 4 8 fresh "$t0"
  [ -z "$(scan "$home")" ] || fail "the first below-target observation cued at once"
  counts "$home" 4 8 fresh $((t0 + 600))
  [ -z "$(scan "$home")" ] || fail "ten minutes below target cued"
  [ -z "$(scan "$home")" ] || fail "a repeated wake on the same observation cued"
  counts "$home" 4 8 fresh $((t0 + 901))
  out=$(scan "$home")
  assert_contains "$out" "lane-refill: vm working 4 of target 8 since" "a shortage over fifteen continuous minutes did not cue"
  [ "$(printf '%s\n' "$out" | grep -c 'lane-refill:')" = 1 ] || fail "one episode emitted more than one cue line"
  episode=${out##* episode }
  counts "$home" 4 8 fresh $((t0 + 1200))
  [ -z "$(scan "$home")" ] || fail "an emitted episode was printed again on the next sweep"
  out=$(cue "$home" vm "$episode")
  assert_contains "$out" "sent: yes" "the cue was not sent"
  [ "$(sends "$home")" = 1 ] || fail "the cue did not send exactly once"
  assert_contains "$(cat "$home/sends")" "SEND vm --fire-and-forget" "the cue did not use the idempotent send"
  assert_contains "$(cat "$home/sends")" "4 genuinely working lanes against your lane target of 8" "the cue did not state the shortage"
  assert_contains "$(cat "$home/sends")" "own existing authorization, capacity, and health gates" "the cue did not defer to the mate's gates"
  out=$(cue "$home" vm "$episode")
  assert_contains "$out" "sent: already" "a repeated cue was not deduplicated"
  [ "$(sends "$home")" = 1 ] || fail "a repeated cue sent twice"
  pass "a shortage held for more than fifteen continuous minutes emits one cue line and sends one cue"
}

test_identity_change_recovery_and_stale_evidence_reset_the_episode() {
  local home out t0 episode
  home=$(refill_home reset)
  t0=$((NOW - 5000))
  counts "$home" 4 8 fresh "$t0"; scan "$home" >/dev/null
  counts "$home" 3 8 fresh $((t0 + 901))
  [ -z "$(scan "$home")" ] || fail "a count identity change kept the old episode's start"
  counts "$home" 3 8 fresh $((t0 + 1802))
  out=$(scan "$home")
  assert_contains "$out" "working 3 of target 8" "the new identity's own sustained episode did not cue"
  episode=${out##* episode }
  counts "$home" 8 8 fresh $((t0 + 1900))
  [ -z "$(scan "$home")" ] || fail "a recovered home cued"
  out=$(cue "$home" vm "$episode")
  [ "$?" -eq 3 ] || fail "a cue for a recovered episode was not refused"
  [ "$(sends "$home")" = 0 ] || fail "a recovered episode was sent"
  counts "$home" 4 8 fresh $((t0 + 2000)); scan "$home" >/dev/null
  counts "$home" 4 8 stale $((t0 + 2500))
  [ -z "$(scan "$home")" ] || fail "stale evidence cued"
  counts "$home" 4 8 fresh $((t0 + 2950))
  [ -z "$(scan "$home")" ] || fail "continuity survived a stale observation"
  counts "$home" 4 8 incomplete $((t0 + 4000))
  [ -z "$(scan "$home")" ] || fail "incomplete evidence cued"
  printf '{"schema":"fm-lane-count.v1","homes":[{"home":"vm","working":0,"target":null,"evidence":"fresh","observed_epoch":%s}]}\n' "$t0" > "$home/counts.json"
  [ -z "$(scan "$home")" ] || fail "a home with no authorized target cued"
  pass "a count identity change, a recovery, stale or incomplete evidence, and a missing target each reset or withhold the cue"
}

test_lost_wake_renotifies_and_leaving_away_clears_everything() {
  local home out t0 episode
  home=$(refill_home renotify)
  t0=$((NOW - 3000))
  counts "$home" 2 8 fresh "$t0"; scan "$home" >/dev/null
  counts "$home" 2 8 fresh $((t0 + 1000))
  out=$(scan "$home")
  episode=${out##* episode }
  [ -n "$episode" ] || fail "the sustained shortage did not emit"
  out=$(FM_HOME="$home" FM_LANE_REFILL_RENOTIFY=0 "$REFILL" scan --counts-file "$home/counts.json")
  assert_contains "$out" "episode $episode" "an emitted but unsent episode was not re-emitted after its renotify bound"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || fail "archive failed"
  [ -z "$(scan "$home")" ] || fail "a scan cued after away mode ended"
  [ ! -e "$home/state/.lane-refill" ] || fail "leaving away mode kept the shortage episodes"
  out=$(cue "$home" vm "$episode")
  [ "$?" -eq 3 ] || fail "a cue was sent after away mode ended"
  [ "$(sends "$home")" = 0 ] || fail "a cue reached the send path after away mode ended"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null 2>&1 || fail "quiet entry failed"
  counts "$home" 0 8 fresh "$t0"; scan "$home" >/dev/null
  counts "$home" 0 8 fresh $((t0 + 2000))
  [ -z "$(scan "$home")" ] || fail "quiet mode cued a refill"
  pass "a lost wake re-emits only after its bound, and leaving away mode or quiet mode cues nothing"
}

test_a_new_away_window_never_continues_an_old_episode() {
  local home t0
  home=$(refill_home new-window)
  t0=$((NOW - 3000))
  counts "$home" 2 8 fresh "$t0"; scan "$home" >/dev/null
  # The captain returns and leaves again with no scan in between.
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || fail "archive failed"
  sleep 1
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep all lanes full' --keep-full >/dev/null 2>&1 \
    || fail "second away entry failed"
  counts "$home" 2 8 fresh $((t0 + 1000))
  [ -z "$(scan "$home")" ] || fail "a new away window continued the previous window's shortage episode"
  counts "$home" 2 8 fresh $((t0 + 1901))
  assert_contains "$(scan "$home")" "lane-refill: vm working 2 of target 8" "the new window's own sustained episode did not cue"
  pass "a new away window starts its own shortage episodes even when no scan ran between windows"
}

test_host_health_line_marks_unknown_fields_and_counts_recent_prs() {
  local dir out now
  dir="$TMP_ROOT/health"
  mkdir -p "$dir/state"
  now=$(date +%s)
  fm_write_meta "$dir/state/t1.meta" "kind=ship" "harness=codex"
  printf 'done [at=%s]: PR https://github.com/o/r/pull/1\n' $((now - 60)) > "$dir/state/t1.status"
  printf 'done [at=%s]: PR https://github.com/o/r/pull/2\n' $((now - 7200)) >> "$dir/state/t1.status"
  fm_write_meta "$dir/state/vm.meta" "kind=secondmate" "home=/remote/vm"
  out=$(FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" "$COUNT" --host-health)
  printf '%s\n' "$out" | grep -Eq '^host-health: load1=[^ ]+ cores=[^ ]+ mem_avail_pct=[^ ]+ prs_last_hour=[^ ]+ prs_unknown_homes=[^ ]+ spawn_gate=[^ ]+$' \
    || fail "the host-health line lost its shape: $out"
  assert_contains "$out" "prs_last_hour=1 " "only the PR created in the last hour must count"
  assert_contains "$out" "prs_unknown_homes=vm " "a mate with no relay log was not named unknown"
  if [ "$(uname -s)" = Linux ]; then
    assert_contains "$out" "load1=unknown" "an unreadable load was not marked unknown"
    assert_contains "$out" "mem_avail_pct=unknown" "an unreadable memory reading was not marked unknown"
  fi
  pass "the host-health line carries load, cores, memory, and PRs created in the last hour, marking unknown fields"
}

test_max_age_reuses_one_fresh_count_per_sweep() {
  local dir out
  dir="$TMP_ROOT/cache"
  mkdir -p "$dir/state"
  printf '{"schema":"fm-lane-count.v1","generated_epoch":%s,"homes":[{"home":"cached"}]}\n' "$(date +%s)" > "$dir/state/.lane-count.json"
  out=$(FM_HOME="$dir" "$COUNT" --json --max-age 240)
  assert_contains "$out" '"home":"cached"' "a fresh stored count was not reused"
  printf '{"schema":"fm-lane-count.v1","generated_epoch":1,"homes":[{"home":"cached"}]}\n' > "$dir/state/.lane-count.json"
  out=$(FM_HOME="$dir" "$COUNT" --json --max-age 240 2>/dev/null)
  assert_not_contains "$out" '"home":"cached"' "an old stored count was reused"
  pass "--max-age reuses a fresh stored count and recounts an old one"
}

test_lane_count_counts_only_genuinely_working_lanes_per_home
test_occupancy_counts_live_harness_processes_once_per_worktree
test_a_sustained_shortage_cues_once_per_episode
test_identity_change_recovery_and_stale_evidence_reset_the_episode
test_lost_wake_renotifies_and_leaving_away_clears_everything
test_a_new_away_window_never_continues_an_old_episode
test_host_health_line_marks_unknown_fields_and_counts_recent_prs
test_max_age_reuses_one_fresh_count_per_sweep
echo "# fm-lane-refill.test.sh: all assertions passed"
