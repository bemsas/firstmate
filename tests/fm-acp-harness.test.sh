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

# Reap only fixture-owned ACP runs even when an assertion fails.
cleanup_acp() {
  local file tid
  for file in "$TMP_ROOT"/*/home/state/*.acp.json; do
    [ -f "$file" ] || continue
    tid=${file##*/}; tid=${tid%.acp.json}
    FM_HOME="${file%/state/*}" python3 -I "$HARNESS" stop "$tid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_acp EXIT

new_world() { # <name> -> sets HOME_DIR WT_DIR PROJ_DIR; FM_HOME and FAKE_DIR exported
  local name=$1
  HOME_DIR="$TMP_ROOT/$name/home"
  PROJ_DIR="$TMP_ROOT/$name/project"
  WT_DIR="$TMP_ROOT/$name/wt"
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  mkdir -p "$TMP_ROOT/$name/fake"
  export FM_HOME="$HOME_DIR" FAKE_DIR="$TMP_ROOT/$name/fake"
  unset FAKE_NO_LOAD FAKE_IGNORE_EOF FAKE_LOAD_FAIL
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

crew_state() {
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-crew-state.sh" "$1"
}

test_acp_current_state() {
  new_world current
  spawn_fake t1 "HANG"
  wait_for 10 "running" state_is t1 running
  local out
  printf 'done [at=1]: premature claim\n' >> "$HOME_DIR/state/t1.status"
  out=$(crew_state t1)
  assert_contains "$out" "state: working" "a live ACP turn must be working from protocol state"
  assert_contains "$out" "source: acp" "ACP must not depend on pane hooks or a validation run"
  h cancel t1
  wait_for 10 "cancelled idle" state_is t1 idle
  wait_for 10 "premature done refusal" grep -q 'report.md is missing' "$HOME_DIR/state/t1.status"
  printf 'resolved [at=1]: premature done withdrawn; missing-report blocker cleared\n' >> "$HOME_DIR/state/t1.status"
  printf 'paused [at=1]: external check pending\n' >> "$HOME_DIR/state/t1.status"
  assert_contains "$(crew_state t1)" "state: paused" "idle ACP must reconcile its declared wait"
  h steer t1 "PERM-OUT"
  wait_for 10 "permission" state_is t1 blocked
  assert_contains "$(crew_state t1)" "state: parked" "a queued permission must be parked even during a turn"
  h answer t1 1 reject
  wait_for 10 "idle after permission" state_is t1 idle
  wait_for 10 "unreported turn block" grep -q 'without a done/failed/blocked status line' "$HOME_DIR/state/t1.status"
  assert_contains "$(crew_state t1)" "state: blocked" "a turn with no terminal declaration is blocked"
  h steer t1 "DONE"
  wait_for 15 "completed exit" state_is t1 exited
  assert_contains "$(crew_state t1)" "state: done" "verified completion must survive process exit"
  cp "$HOME_DIR/state/t1.acp.json" "$TMP_ROOT/completed-state.json"
  python3 - "$HOME_DIR/state/t1.acp.json" <<'CHECK'
import json, sys, time
p = sys.argv[1]
r = json.load(open(p))
r.update(state="starting", pid=None, pid_start=None, agent_pid=None, ready=False, updated_at=int(time.time()))
json.dump(r, open(p, "w"))
CHECK
  assert_contains "$(crew_state t1)" 'state: unknown' "a launch reservation without processes is not proof of work"
  out=$(bash -c '. "$1"; fm_backend_agent_state acp acp:t1' _ "$ROOT/bin/fm-backend.sh")
  assert_equals unreadable "$out" "the adapter must not prove an agent alive from a starting reservation"
  cp "$TMP_ROOT/completed-state.json" "$HOME_DIR/state/t1.acp.json"
  pass "crew-state: ACP running, permission, idle declaration, and completed exit use process/protocol state"
}

test_ship_done_gate() {
  new_world shipgate
  spawn_fake t1 "hello" --no-report-gate
  wait_for 10 "idle" state_is t1 idle
  # Ship spawning remains disabled; prepare the metadata shape for the future pilot.
  sed -i.bak 's/kind=scout/kind=ship/' "$HOME_DIR/state/t1.meta"
  printf 'mode=local-only\nbranch=wt-shipgate\n' >> "$HOME_DIR/state/t1.meta"
  printf 'uncommitted\n' > "$WT_DIR/untracked.txt"
  h steer t1 "NOREPORT"
  wait_for 10 "dirty ship refusal" grep -q 'worktree is dirty' "$HOME_DIR/state/t1.status"
  assert_equals idle "$(h state t1)" "a done claim with dirt must preserve the agent"
  assert_contains "$(crew_state t1)" "state: blocked" "a rejected done must be blocked"
  git -C "$WT_DIR" add untracked.txt
  git -C "$WT_DIR" -c user.name=Test -c user.email=test@example.test commit -qm 'test: save work' || fail 'fixture commit failed'
  h steer t1 "NOREPORT"
  wait_for 15 "ship completion" state_is t1 exited
  assert_equals "done" "$(json_field t1 exit_reason)" "clean shared branch head must pass without a scout report"
  assert_equals "$(git -C "$WT_DIR" rev-parse HEAD)" "$(json_field t1 done_head)" "accepted head must be recorded"
  assert_absent "$HOME_DIR/data/t1/report.md" "ship completion must use its delivery contract instead of a scout report"
  pass "ship gate: dirty work stays alive, committed shared local head exits and records the accepted head"
}

control() {
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-control.sh" "$@"
}

test_control_relaunch() {
  new_world control
  spawn_fake t1 "remember BANANA"
  wait_for 10 "idle" state_is t1 idle
  local session pid out rc=0
  session=$(json_field t1 session_id); pid=$(json_field t1 pid)
  printf 'preserve this\n' > "$WT_DIR/local.txt"
  out=$(control t1 relaunch --model changed 2>&1) && fail "ACP profile change must refuse"
  assert_contains "$out" "profile changes are unsupported" "refusal must explain the preserved profile"
  assert_equals "$pid" "$(json_field t1 pid)" "profile refusal must leave the old harness running"
  out=$(control t1 relaunch --note 'continue after review' 2>&1) || fail "ACP control relaunch failed: $out"
  assert_contains "$out" 'relaunched t1' "the public control path must confirm recovery"
  wait_for 10 "resumed idle" state_is t1 idle
  assert_not_equals "$pid" "$(json_field t1 pid)" "relaunch must wait for a replacement pid, not stale ready=true"
  assert_equals "$session" "$(json_field t1 session_id)" "relaunch must load the saved session"
  assert_equals 'preserve this' "$(cat "$WT_DIR/local.txt")" "relaunch must preserve uncommitted work"
  python3 - "$HOME_DIR/state/t1.events.jsonl" "$WT_DIR" <<'CHECK' || fail 'session/load did not use the recorded worktree'
import json, sys
calls = [json.loads(l)['f'] for l in open(sys.argv[1])]
assert any(f.get('method') == 'session/load' and f['params']['cwd'] == sys.argv[2] for f in calls)
CHECK
  assert_contains "$(cat "$FAKE_DIR/$session.json")" 'continue after review' "the recovery note must reach the loaded conversation"
  h stop t1
  out=$(control t1 relaunch --note 'DONE' 2>&1) || fail "a resumed task that immediately finishes must succeed: $out"
  wait_for 15 "resumed completion" state_is t1 exited
  assert_contains "$out" 'relaunched t1' "auto-exit after a successful resume must not become a launch timeout"
  FAKE_NO_LOAD=1 control t1 relaunch --note 'fresh fallback' >/dev/null || fail 'control fresh-session fallback failed'
  wait_for 10 "fresh idle" state_is t1 idle
  assert_not_equals "$session" "$(json_field t1 session_id)" "loadSession=false must get a fresh session"
  session=$(json_field t1 session_id)
  assert_contains "$(cat "$FAKE_DIR/$session.json")" 'fresh fallback' "fresh session must also receive the note"
  h stop t1
  FAKE_LOAD_FAIL=1 control t1 relaunch > "$TMP_ROOT/load-failure.log" 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "failed session/load must not report a successful relaunch"
  assert_grep 'session/load failed' "$HOME_DIR/state/t1.acp/harness.log" "failed load must retain actionable evidence"
  assert_equals "$WT_DIR" "$(json_field t1 worktree)" "failed relaunch must retain the worktree record"
  pass "control relaunch: load saved session and cwd, preserve work, refuse profile changes, handle no-load and failed-load agents"
}

test_ship_unrecorded_and_pushed_heads() {
  new_world shiphead
  spawn_fake t1 "hello"
  wait_for 10 "idle" state_is t1 idle
  sed -i.bak 's/kind=scout/kind=ship/' "$HOME_DIR/state/t1.meta"
  printf 'mode=local-only\n' >> "$HOME_DIR/state/t1.meta"
  git -C "$WT_DIR" checkout -q --detach
  printf 'new content\n' > "$WT_DIR/content.txt"
  git -C "$WT_DIR" add content.txt
  git -C "$WT_DIR" -c user.name=Test -c user.email=test@example.test commit -qm 'test: detached work' || fail 'fixture commit failed'
  h steer t1 "NOREPORT"
  wait_for 10 "unrecorded head refusal" grep -q 'unreachable outside the worker copy' "$HOME_DIR/state/t1.status"
  assert_equals idle "$(h state t1)" "a clean detached head must not be accepted merely because another branch exists"
  sed -i.bak 's/mode=local-only/mode=no-mistakes/' "$HOME_DIR/state/t1.meta"
  h steer t1 "NOREPORT"
  wait_for 10 "validation handoff refusal" grep -q 'validation handoff, not a completed delivery' "$HOME_DIR/state/t1.status"
  assert_equals idle "$(h state t1)" "a pre-validation done must not terminate a ship agent"
  # Publishing into this fixture's bare remote makes the exact head durable.
  sed -i.bak 's/mode=no-mistakes/mode=direct-PR/' "$HOME_DIR/state/t1.meta"
  git -C "$WT_DIR" push -q origin HEAD:refs/heads/delivery || fail 'fixture push failed'
  h steer t1 "NOREPORT"
  wait_for 15 "pushed head accepted" state_is t1 exited
  assert_equals "$(git -C "$WT_DIR" rev-parse HEAD)" "$(json_field t1 done_head)" "the durable head must be recorded on exit"
  pass "ship gate: a clean unrecorded detached head stays alive; the same head pushed to the fixture remote exits"
}

test_acp_state_failure_and_binding() {
  new_world deadstate
  spawn_fake t1 "HANG"
  wait_for 10 "running" state_is t1 running
  local pid out
  pid=$(json_field t1 pid)
  # Metadata is caller authority: do not resume in a different recorded checkout.
  sed -i.bak "s|^worktree=.*|worktree=$PROJ_DIR|" "$HOME_DIR/state/t1.meta"
  out=$(control t1 relaunch 2>&1) && fail 'mismatched recovery worktree must refuse'
  assert_contains "$out" 'worktree disagree' "a mismatch must be diagnosed before stopping"
  assert_equals "$pid" "$(json_field t1 pid)" "mismatch refusal must preserve the live harness"
  assert_contains "$(crew_state t1)" 'state: unknown' "a mismatched state file must not classify another checkout"
  sed -i.bak "s|^worktree=.*|worktree=$WT_DIR|" "$HOME_DIR/state/t1.meta"
  kill -9 "$(json_field t1 agent_pid)"
  wait_for 15 "agent death" state_is t1 dead
  assert_contains "$(crew_state t1)" 'state: failed' "a dead process must override stale working status"
  assert_equals dead "$(json_field t1 state)" "JSON state must expose the computed process verdict"
  printf '{broken\n' > "$HOME_DIR/state/t1.acp.json"
  assert_contains "$(crew_state t1)" 'state: unknown' "corrupt state is unreadable, never proof of completion"
  pass "ACP state: metadata binding and process death outrank stale status; corrupt state fails closed"
}

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
  assert_equals dead "$(json_field t1 state)" "JSON must not expose stale running after the harness dies"
  assert_contains "$(crew_state t1)" 'state: failed' "a dead harness must override its unfinished turn"
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

test_acp_current_state
test_ship_done_gate
test_control_relaunch
test_ship_unrecorded_and_pushed_heads
test_acp_state_failure_and_binding

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
