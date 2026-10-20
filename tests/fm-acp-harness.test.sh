#!/usr/bin/env bash
# Behavior tests for bin/fm-acp-harness.py and the pilot `--backend acp` spawn path.
#
# A scripted ACP agent (tests/assets/fm-acp-fake-agent.py) stands in for OpenCode, so these
# pin the harness's own contract with real processes: permission policy, queueing and
# answers, cancel, exit-on-done with no leftover process, resume through session/load, the
# cost cap, and the spawn/teardown hand-off. Whether a real agent speaks the protocol this
# way is recorded in data/fm-acp-pilot/report.md from live runs, not asserted here.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HARNESS="$ROOT/bin/fm-acp-harness.py"
FAKE_AGENT="$ROOT/tests/assets/fm-acp-fake-agent.py"
TMP_ROOT=$(fm_test_tmproot fm-acp-harness)

new_world() { # <name> -> sets HOME_DIR WT_DIR PROJ_DIR; FM_HOME and FAKE_DIR exported
  local name=$1
  HOME_DIR="$TMP_ROOT/$name/home"
  PROJ_DIR="$TMP_ROOT/$name/project"
  WT_DIR="$TMP_ROOT/$name/wt"
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  mkdir -p "$TMP_ROOT/$name/fake"
  export FM_HOME="$HOME_DIR" FAKE_DIR="$TMP_ROOT/$name/fake"
  unset FAKE_NO_LOAD FAKE_IGNORE_EOF
}

h() { python3 -I "$HARNESS" "$@"; }

wait_for() { # <seconds> <description> <command...>
  local secs=$1 what=$2 i
  shift 2
  for ((i = 0; i < secs * 10; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "timed out waiting for $what"
}

state_is() { [ "$(h state "$1" 2>/dev/null)" = "$2" ]; }
json_field() { h state "$1" --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2"; }
spawn_fake() { # <id> <brief-text> [extra spawn args...]
  local id=$1 brief=$2
  shift 2
  printf '%s\n' "$brief" > "$TMP_ROOT/brief-$id.md"
  h spawn "$id" "$PROJ_DIR" --brief "$TMP_ROOT/brief-$id.md" --worktree "$WT_DIR" \
    --agent-cmd "python3 $FAKE_AGENT" "$@" >/dev/null
}
group_gone() { ! kill -0 -- "-$1" 2>/dev/null; }

test_permission_policy_and_queue() {
  new_world perm
  spawn_fake t1 "PERM-IN please"
  wait_for 10 "first turn to end" state_is t1 idle
  assert_grep "auto-allowed edit: write notes.txt" "$HOME_DIR/state/t1.acp/harness.log" "an edit inside the worktree must be answered without the supervisor"
  assert_no_grep "needs-decision" "$HOME_DIR/state/t1.status" "an in-worktree edit must not queue a decision"
  assert_present "$HOME_DIR/state/t1.turn-ended" "a stopReason must touch the turn-ended marker the watcher reads"
  assert_grep "working [at=" "$HOME_DIR/state/t1.status" "a turn start must write a working status line"
  h steer t1 "PERM-OUT now"
  wait_for 10 "the outside-worktree edit to queue" state_is t1 blocked
  assert_contains "$(h permissions t1)" "/etc/hosts-copy" "the queued request must be listed"
  assert_grep "needs-decision [key=acp-perm-1]" "$HOME_DIR/state/t1.status" "a queued request must open a keyed decision"
  h answer t1 1 reject
  wait_for 10 "the turn to finish after the answer" state_is t1 idle
  assert_grep "resolved [key=acp-perm-1]" "$HOME_DIR/state/t1.status" "an answer must close its keyed decision"
  assert_contains "$(h tail t1 -n 80)" "perm-out outcome selected:reject" "the agent must receive the reject choice"
  h stop t1
  pass "permissions: edits inside the worktree auto-allow, others queue behind a keyed decision, an answer reaches the agent"
}

test_cancel_returns_cancelled_and_answers_pending() {
  new_world cancel
  spawn_fake t1 "hello"
  wait_for 10 "idle" state_is t1 idle
  h steer t1 "HANG"
  wait_for 10 "running" state_is t1 running
  h cancel t1
  wait_for 10 "idle after cancel" state_is t1 idle
  assert_equals cancelled "$(json_field t1 stop_reason)" "a cancelled turn must end with stopReason cancelled"
  h steer t1 "PERM-OUT then cancel"
  wait_for 10 "queued permission" state_is t1 blocked
  h cancel t1
  wait_for 10 "idle after cancelling a queued permission" state_is t1 idle
  assert_contains "$(h tail t1 -n 80)" "perm-out outcome cancelled" "a pending permission must be answered cancelled when its turn is cancelled"
  assert_grep "permission 1 cancelled with the turn" "$HOME_DIR/state/t1.status" "the cancelled request must close its decision"
  h stop t1
  pass "cancel: stopReason cancelled, and pending permission requests are answered cancelled"
}

test_done_exits_with_nothing_left() {
  new_world "done"
  spawn_fake t1 "DONE please"
  wait_for 15 "the harness to exit after done" state_is t1 exited
  assert_equals "done" "$(json_field t1 exit_reason)" "a done status plus report must end the run"
  assert_equals False "$(json_field t1 leftover_processes)" "the state file must record no leftover process"
  local pgid child
  pgid=$(json_field t1 agent_pgid)
  child=$(cat "$FAKE_DIR/child.pid")
  group_gone "$pgid" || fail "the agent's process group is still alive after done"
  ! kill -0 "$child" 2>/dev/null || fail "the agent's tool child survived the harness exit"
  ! kill -0 "$(json_field t1 pid)" 2>/dev/null || fail "the harness process is still alive"
  assert_present "$WT_DIR" "the worktree must stay for landing and teardown"
  h stop t1 || fail "stop must be idempotent on an exited task"
  pass "exit: done plus report closes the agent group and the harness, leaving only the worktree and state files"
}

test_done_without_report_stays_up() {
  new_world noreport
  spawn_fake t1 "idle brief"
  wait_for 10 "idle" state_is t1 idle
  h steer t1 "NOREPORT"
  wait_for 10 "the missing-report block" grep -q "report.md is missing" "$HOME_DIR/state/t1.status"
  wait_for 10 "idle again" state_is t1 idle
  h stop t1
  pass "exit gate: a done line without the scout report does not end the run"
}

test_kill_then_resume_loads_the_session() {
  new_world resume
  spawn_fake t1 "remember BANANA"
  wait_for 10 "idle" state_is t1 idle
  h steer t1 "HANG"
  wait_for 10 "running" state_is t1 running
  local pid pgid session
  pid=$(json_field t1 pid) pgid=$(json_field t1 agent_pgid) session=$(json_field t1 session_id)
  kill -9 "$pid"
  kill -9 -- "-$pgid"
  wait_for 10 "dead state" state_is t1 dead
  h resume t1 >/dev/null
  wait_for 10 "resumed run to idle" state_is t1 idle
  assert_equals "$session" "$(json_field t1 session_id)" "resume must keep the saved session id"
  assert_grep '"replay": true' "$HOME_DIR/state/t1.events.jsonl" "session/load must replay history as flagged replay events"
  assert_contains "$(h tail t1 -n 200)" "session/load" "the resumed run must call session/load"
  h stop t1
  pass "resume: a killed run restarts and session/load restores the saved session"
}

test_resume_without_load_support_starts_fresh() {
  new_world fresh
  spawn_fake t1 "first brief"
  wait_for 10 "idle" state_is t1 idle
  h stop t1
  FAKE_NO_LOAD=1 h resume t1 >/dev/null
  wait_for 10 "fresh session idle" state_is t1 idle
  assert_not_equals "" "$(json_field t1 session_id)" "a fresh session id must be recorded"
  assert_grep "cannot session/load" "$HOME_DIR/state/t1.acp/harness.log" "the fallback must be logged"
  h stop t1
  pass "resume: an agent without loadSession gets a fresh session in the same worktree"
}

test_cost_cap_stops_the_run() {
  new_world cost
  spawn_fake t1 "COST please" --max-cost 0
  wait_for 15 "exit on cost" state_is t1 exited
  assert_equals cost-cap "$(json_field t1 exit_reason)" "a reported cost above the cap must stop the run"
  assert_grep "above the cap" "$HOME_DIR/state/t1.status" "the cap must report a failed status"
  pass "cost cap: a nonzero reported cost stops a --max-cost 0 run"
}

test_agent_that_ignores_eof_is_killed() {
  new_world eof
  FAKE_IGNORE_EOF=1 spawn_fake t1 "hello"
  wait_for 10 "idle" state_is t1 idle
  local pgid
  pgid=$(json_field t1 agent_pgid)
  h stop t1
  group_gone "$pgid" || fail "an agent that ignores EOF must be terminated through its process group"
  assert_equals False "$(json_field t1 leftover_processes)" "stop must leave nothing behind"
  pass "stop: EOF first, then SIGTERM to the group for an agent that ignores EOF"
}

test_large_command_lists_are_shortened_in_the_log() {
  new_world volume
  spawn_fake t1 "BIGCMDS"
  wait_for 10 "idle" state_is t1 idle
  assert_grep '"count": 500' "$HOME_DIR/state/t1.events.jsonl" "available_commands_update must be logged as a count"
  assert_no_grep '"name": "c499"' "$HOME_DIR/state/t1.events.jsonl" "the command list itself must not be stored"
  h stop t1
  pass "event log: the agent's command list is stored as a count"
}

test_spawn_and_teardown_through_fm_spawn() {
  new_world spawn
  local fakebin out brief
  fakebin=$(fm_fakebin "$TMP_ROOT/spawn")
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\$1" in
  get) printf '%s\n' '$WT_DIR' ;;
  return) exit 0 ;;
  *) exit 0 ;;
esac
SH
  cat > "$fakebin/opencode" <<SH
#!/usr/bin/env bash
exec python3 '$FAKE_AGENT'
SH
  chmod +x "$fakebin/treehouse" "$fakebin/opencode"
  mkdir -p "$HOME_DIR/data/sc1"
  cat > "$HOME_DIR/data/sc1/brief.md" <<EOF
# Task
## Captain's intent
DONE as soon as you can.

## Firstmate spec
Write the report.
EOF
  spawn_env() {
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
  }

  out=$(spawn_env sc1 "$PROJ_DIR" --scout --harness opencode --backend acp) && fail "acp spawn without --model must refuse"
  assert_contains "$out" "requires an explicit --model" "missing --model must name the requirement"
  out=$(spawn_env sc1 "$PROJ_DIR" --harness opencode --model m --mode local-only --yolo off --backend acp) && fail "acp ship spawn must refuse"
  assert_contains "$out" "scout-only pilot" "a ship spawn on acp must refuse"
  printf 'acp\n' > "$HOME_DIR/config/backend"
  out=$(spawn_env sc1 "$PROJ_DIR" --scout --harness opencode --model m) && fail "config/backend=acp must not select the pilot"
  assert_contains "$out" "explicit --backend acp" "the pilot must not be selectable from config"
  rm -f "$HOME_DIR/config/backend"
  assert_absent "$HOME_DIR/state/sc1.meta" "a refused acp spawn must leave no task record"

  out=$(spawn_env sc1 "$PROJ_DIR" --scout --harness opencode --model fake/free --backend acp) || fail "acp scout spawn failed: $out"
  assert_contains "$out" "window=acp:sc1" "spawn must report the acp endpoint"
  assert_grep "backend=acp" "$HOME_DIR/state/sc1.meta" "meta must record backend=acp"
  assert_grep "window=acp:sc1" "$HOME_DIR/state/sc1.meta" "meta must record the acp window"
  assert_grep "kind=scout" "$HOME_DIR/state/sc1.meta" "meta must record kind=scout"
  wait_for 15 "the scout to finish" state_is sc1 exited
  assert_grep "done [at=" "$HOME_DIR/state/sc1.status" "the scout's done line must reach the status file"
  assert_present "$HOME_DIR/data/sc1/launch-brief.md" "the rendered launch brief must be the first prompt source"
  assert_grep "FIRSTMATE_OP: v1 launch-brief" "$HOME_DIR/state/sc1.events.jsonl" "the first prompt must carry the launch-brief envelope"

  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" complete sc1 --none >/dev/null 2>&1 \
    || fail "the scout's captain-call completion gate could not be passed"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" sc1 2>&1) || fail "teardown of a finished acp scout failed: $out"
  assert_absent "$HOME_DIR/state/sc1.meta" "teardown must remove the task record"
  pass "fm-spawn --backend acp: refuses non-scout and implicit use, spawns a scout, and fm-teardown cleans it up"

  # A live acp scout is steered and read through the ordinary fm-send / fm-peek / fm-crew-state.
  mkdir -p "$HOME_DIR/data/sc2"
  cat > "$HOME_DIR/data/sc2/brief.md" <<EOF
# Task
## Captain's intent
Wait for a steer.

## Firstmate spec
Stay idle until steered.
EOF
  out=$(spawn_env sc2 "$PROJ_DIR" --scout --harness opencode --model fake/free --backend acp) || fail "second acp scout spawn failed: $out"
  wait_for 10 "second scout idle" state_is sc2 idle
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-send.sh" sc2 "DONE: please finish" 2>&1) \
    || fail "fm-send to an acp scout failed: $out"
  wait_for 10 "the steer to start a turn" grep -q '"turn": 2' "$HOME_DIR/state/sc2.acp.json"
  assert_present "$HOME_DIR/state/sc2.inbox" "fm-send must still write the durable steering record"
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-peek.sh" sc2 20 2>&1) || fail "fm-peek of an acp scout failed: $out"
  assert_contains "$out" "session/prompt" "fm-peek must show the event view"
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-crew-state.sh" sc2 2>&1) || true
  assert_not_contains "$out" "unknown backend" "fm-crew-state must accept an acp record"
  h stop sc2
  pass "fm-send, fm-peek, and fm-crew-state accept a live acp scout"
}

test_permission_policy_and_queue
test_cancel_returns_cancelled_and_answers_pending
test_done_exits_with_nothing_left
test_done_without_report_stays_up
test_kill_then_resume_loads_the_session
test_resume_without_load_support_starts_fresh
test_cost_cap_stops_the_run
test_agent_that_ignores_eof_is_killed
test_large_command_lists_are_shortened_in_the_log
test_spawn_and_teardown_through_fm_spawn

echo "# all fm-acp-harness tests passed"
