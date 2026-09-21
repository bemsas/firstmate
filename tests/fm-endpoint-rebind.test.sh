#!/usr/bin/env bash
# bin/fm-endpoint-rebind.sh - restored-endpoint reconciliation.
#
# A terminal endpoint restored after a machine reboot keeps its recorded
# identity and loses its working directory (docs/verification/runtime-backends.md
# "Restored endpoints keep their identity and lose their directory"). These
# tests pin what firstmate does about that, hermetically, against a stubbed
# session provider and real git worktrees:
#
#   1. An endpoint already in its recorded local copy produces no output at all.
#   2. A drifted AGENT-FREE endpoint is sent back, and only a read-back that
#      matches is reported as a rebind.
#   3. A drifted endpoint holding a LIVE agent is reported and nothing else -
#      nothing typed into it, nothing signalled.
#   4. The worktree-isolation assertion re-runs against the live path, so an
#      endpoint restored into the primary checkout is named as such.
#   5. Absence stays with the reclaim path; this never declares an endpoint gone.
#   6. Records this reconciliation has no business touching are skipped.
#   7. The per-backend capability split is a real gate, not a comment.
#   8. NEITHER control-plane refusal is weakened: `exit` still refuses a
#      composer it cannot prove empty, and the shared isolation predicate still
#      rejects the primary checkout and the project itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-isolation-lib.sh"

REBIND="$ROOT/bin/fm-endpoint-rebind.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-rebind)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

trap 'rm -rf "$TMP_ROOT"' EXIT

# A tmux stub that models the three reads this reconciliation depends on and
# the one write it can make. `pane_tty` deliberately answers nothing, so the
# foreground-process-group probe is unreadable and the agent verdict falls back
# to pane_current_command - the same shape tests/fm-control.test.sh uses.
# A `cd -- '<path>'` literal moves the modelled shell, unless the case asked
# for an endpoint that refuses to move.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        "cd -- '"*"'")
          if [ -z "${FM_FAKE_CD_IGNORED:-}" ]; then
            moved=${payload#"cd -- '"}; moved=${moved%"'"}
            printf '%s' "$moved" > "$D/cwd"
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_tty*) exit 1 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    [ ! -f "$D/session-missing" ] || { echo "can't find session: fmses" >&2; exit 1; }
    cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# new_case: a private home, a real project with a linked worktree, and a task
# record whose endpoint starts out sitting in that worktree.
new_case() {  # <label> [id] [harness] -> case dir
  local id=${2:-t1} harness=${3:-claude} dir="$TMP_ROOT/$1-$RANDOM"
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$dir/fake"
  fm_git_worktree "$proj" "$wt" "task-$id"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/composer"
  printf 'zsh' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$(cd "$wt" && pwd -P)" > "$dir/fake/cwd"
  make_tmux_stub "$dir"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "$dir"
}

run_rebind() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u TMUX \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_CD_IGNORED="${FM_FAKE_CD_IGNORED:-}" \
    FM_ENDPOINT_REBIND_POLL=0.01 FM_ENDPOINT_REBIND_WAIT=0.2 \
    "$REBIND" "$@" 2>&1
}

drift_endpoint_to() {  # <case-dir> <path>
  printf '%s' "$(cd "$2" && pwd -P)" > "$1/fake/cwd"
}

meta_set() {  # <case-dir> <id> <line>
  printf '%s\n' "$3" >> "$1/home/state/$2.meta"
}

# --- 1. no-op ---------------------------------------------------------------

test_endpoint_in_its_recorded_copy_says_nothing() {
  local dir out
  dir=$(new_case quiet q1)
  out=$(run_rebind "$dir" sweep)
  [ -z "$out" ] || fail "an endpoint already in its recorded local copy must produce no output, got: $out"
  [ ! -s "$dir/fake/literal" ] || fail "nothing may be typed into an endpoint that never moved"
  pass "fm-endpoint-rebind: an endpoint already in its recorded local copy is silent"
}

# --- 2. the rebind, and its read-back proof ---------------------------------

test_drifted_agent_free_endpoint_is_returned() {
  local dir out wt_real
  dir=$(new_case rebind r1)
  wt_real=$(cd "$dir/wt" && pwd -P)
  drift_endpoint_to "$dir" "$dir/proj"
  out=$(run_rebind "$dir" sweep)
  assert_contains "$out" "BOOTSTRAP_INFO: r1:" "a completed rebind is a no-action fact, not an actionable line"
  assert_contains "$out" "returned to the task's local copy $dir/wt" "the fact should name the local copy it returned to"
  [ "$(cat "$dir/fake/cwd")" = "$wt_real" ] \
    || fail "the endpoint should now be in its recorded local copy, got '$(cat "$dir/fake/cwd")'"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/literal" "the endpoint should have been told to return to its recorded local copy"
  pass "fm-endpoint-rebind: a drifted agent-free endpoint is returned to its recorded local copy"
}

test_rebind_is_reported_only_when_the_endpoint_actually_arrived() {
  local dir out
  dir=$(new_case noarrive r2)
  drift_endpoint_to "$dir" "$dir/proj"
  out=$(FM_FAKE_CD_IGNORED=1 run_rebind "$dir" sweep)
  assert_contains "$out" "ENDPOINT_REBIND: r2:" "an unproven rebind must be actionable, not a completed fact"
  assert_contains "$out" "could not be returned there" "the refusal should say the endpoint did not arrive"
  assert_not_contains "$out" "BOOTSTRAP_INFO" "a rebind that did not arrive must never be reported as done"
  pass "fm-endpoint-rebind: a rebind is reported only when the endpoint's live path reads back as the recorded copy"
}

# --- 3. a live agent outside the recorded copy ------------------------------

test_live_agent_outside_the_copy_is_reported_and_left_alone() {
  local dir out
  dir=$(new_case breach b1)
  printf 'claude' > "$dir/fake/command"
  drift_endpoint_to "$dir" "$dir/proj"
  out=$(run_rebind "$dir" sweep)
  assert_contains "$out" "a worker is running in" "the report should say a worker is running outside the copy"
  assert_contains "$out" "worktree-isolation contract" "the report should name the contract that was broken"
  [ ! -s "$dir/fake/literal" ] || fail "nothing may be typed into an endpoint holding a live agent"
  [ ! -s "$dir/fake/keys" ] || fail "no key may be sent to an endpoint holding a live agent"
  pass "fm-endpoint-rebind: a worker running outside the recorded local copy is reported, never typed into or signalled"
}

# --- 4. the isolation assertion re-runs on restore --------------------------

test_isolation_assertion_names_where_the_endpoint_ended_up() {
  local dir out primary
  dir=$(new_case isolation i1)
  primary=$(cd "$dir/proj" && pwd -P)
  printf 'claude' > "$dir/fake/command"
  printf '%s' "$primary" > "$dir/fake/cwd"
  out=$(run_rebind "$dir" sweep)
  assert_contains "$out" "it is the spawning project itself" \
    "the live path should be screened by the same isolation predicate the spawn guard uses"

  # A path that is no worktree at all (a restored shell in \$HOME) is named too.
  dir=$(new_case isolation-home i2)
  mkdir -p "$dir/elsewhere"
  printf 'claude' > "$dir/fake/command"
  drift_endpoint_to "$dir" "$dir/elsewhere"
  out=$(run_rebind "$dir" sweep)
  assert_contains "$out" "it is not inside a git worktree" "a restored shell outside any repository should be named as such"
  pass "fm-endpoint-rebind: the worktree-isolation assertion re-runs against the endpoint's live path"
}

# --- 5. absence stays with the reclaim path ---------------------------------

test_missing_endpoint_is_left_to_the_reclaim_path() {
  local dir out
  # The endpoint answers an existence read and a path read, then the
  # recovery-grade classifier reports it missing: a contradiction, not plain
  # absence, and still not this sweep's to resolve.
  dir=$(new_case gone g1)
  drift_endpoint_to "$dir" "$dir/proj"
  : > "$dir/fake/session-missing"
  out=$(run_rebind "$dir" sweep)
  assert_contains "$out" "read 'missing'" "the report should name the state it actually read"
  assert_contains "$out" "contradict" "the report should say the two reads disagree"
  assert_contains "$out" "relaunch" "absence should be handed to the reclaim path that owns it"
  [ ! -s "$dir/fake/literal" ] || fail "nothing may be typed into an endpoint that reads missing"
  pass "fm-endpoint-rebind: an endpoint that answers and then reads missing is reported, never resolved here"
}

test_an_endpoint_that_is_simply_not_there_is_silent() {
  local dir out
  dir=$(new_case absent a1)
  drift_endpoint_to "$dir" "$dir/proj"
  # No endpoint at all. The existence read fails, and nothing further may run -
  # a herdr path read would otherwise start the recorded session's server.
  cat > "$dir/fakebin/tmux" <<'ABSENT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_DIR/calls"
exit 1
ABSENT
  chmod +x "$dir/fakebin/tmux"
  out=$(run_rebind "$dir" sweep)
  [ -z "$out" ] || fail "an endpoint that is not there has no drift to reconcile, got: $out"
  assert_not_contains "$(cat "$dir/fake/calls" 2>/dev/null || true)" "pane_current_path" \
    "the path read must not run once the endpoint is known to be absent"
  pass "fm-endpoint-rebind: an endpoint that is not there is skipped without a further probe"
}

# --- 6. records this reconciliation does not own ----------------------------

test_secondmate_and_remote_records_are_skipped() {
  local dir out
  dir=$(new_case secondmate s1)
  drift_endpoint_to "$dir" "$dir/proj"
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/home/state/s1.meta" && rm -f "$dir/home/state/s1.meta.bak"
  out=$(run_rebind "$dir" sweep)
  [ -z "$out" ] || fail "a secondmate home is not a disposable task worktree and must be skipped, got: $out"

  dir=$(new_case remote s2)
  drift_endpoint_to "$dir" "$dir/proj"
  meta_set "$dir" s2 "remote_host=elsewhere.example"
  out=$(run_rebind "$dir" sweep)
  [ -z "$out" ] || fail "a remotely placed record's endpoint is on another host and must be skipped, got: $out"
  pass "fm-endpoint-rebind: secondmate and remotely placed records are skipped"
}

test_reconcile_refuses_an_id_it_cannot_resolve() {
  local dir out rc
  dir=$(new_case badid x1)
  out=$(run_rebind "$dir" reconcile nosuchtask); rc=$?
  expect_code 1 "$rc" "an unknown task id should refuse"
  assert_contains "$out" "no task" "the refusal should say the task is not in this home"
  out=$(run_rebind "$dir" reconcile ../escape); rc=$?
  expect_code 1 "$rc" "a path-unsafe task id should refuse"
  assert_contains "$out" "not a valid task id" "the refusal should name the invalid id"
  pass "fm-endpoint-rebind: reconcile refuses an unknown or path-unsafe task id"
}

# --- 7. the per-backend capability split ------------------------------------

test_only_live_path_backends_are_reconciled() {
  local b
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  for b in tmux herdr; do
    fm_backend_current_path_is_live "$b" \
      || fail "$b reports a live working directory and must be reconcilable"
  done
  for b in zellij cmux orca; do
    fm_backend_current_path_is_live "$b" \
      && fail "$b's path read is frozen at creation time or absent; drift must never be inferred on it"
  done
  pass "fm-endpoint-rebind: only backends with a live working-directory read are reconciled"
}

test_a_frozen_path_backend_record_is_never_acted_on() {
  local dir out
  dir=$(new_case frozen f1)
  drift_endpoint_to "$dir" "$dir/proj"
  # A valid zellij record, so the refusal under test is the capability gate and
  # not an unrelated metadata complaint.
  sed -i.bak 's|^window=.*$|window=fmses:2|' "$dir/home/state/f1.meta" \
    && rm -f "$dir/home/state/f1.meta.bak"
  {
    echo "backend=zellij"
    echo "zellij_session=fmses"
    echo "zellij_tab_id=1"
    echo "zellij_pane_id=2"
  } >> "$dir/home/state/f1.meta"
  out=$(run_rebind "$dir" sweep)
  [ -z "$out" ] || fail "a frozen-path backend must not be reconciled, got: $out"
  [ ! -s "$dir/fake/literal" ] || fail "nothing may be typed into an endpoint whose path read cannot prove drift"
  pass "fm-endpoint-rebind: a backend whose path read is frozen at creation time is never acted on"
}

# --- 8. neither control-plane refusal is weakened ---------------------------

test_exit_still_refuses_a_composer_it_cannot_prove_empty() {
  local dir out rc
  dir=$(new_case composer c1)
  printf 'claude' > "$dir/fake/command"
  printf 'half a thought' > "$dir/fake/composer"
  out=$(env -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 "$CONTROL" c1 exit 2>&1); rc=$?
  expect_code 1 "$rc" "exit must still refuse a composer holding pending text"
  assert_contains "$out" "not proven empty" "the refusal should still rest on the composer proof"
  assert_contains "$out" "refusing to type" "the refusal should still say it declined to type the exit command"
  [ ! -s "$dir/fake/literal" ] || fail "the exit command must not be typed onto pending text"
  pass "fm-control exit: still refuses a composer it cannot prove empty"
}

test_the_shared_isolation_predicate_still_rejects_primary_and_project() {
  local dir proj wt primary
  dir="$TMP_ROOT/predicate-$RANDOM"
  mkdir -p "$dir"
  proj="$dir/proj"; wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" pred
  primary=$(git -C "$proj" rev-parse --show-toplevel)

  fm_worktree_isolation_check "$wt" "$proj" \
    || fail "a linked disposable worktree must still pass the isolation predicate ($FM_WORKTREE_ISOLATION_REASON)"
  fm_worktree_isolation_check "$proj" "$proj" \
    && fail "the spawning project itself must still be refused"
  assert_contains "$FM_WORKTREE_ISOLATION_REASON" "spawning project itself" "the project refusal should keep its reason"
  fm_worktree_isolation_check "$primary" "$wt" \
    && fail "the repository's primary checkout must still be refused"
  assert_contains "$FM_WORKTREE_ISOLATION_REASON" "primary checkout" "the primary-checkout refusal should keep its reason"
  fm_worktree_isolation_check "$dir" "$proj" \
    && fail "a path in no repository must still be refused"
  assert_contains "$FM_WORKTREE_ISOLATION_REASON" "not inside a git worktree" "a non-repository path should keep its reason"
  pass "fm-worktree-isolation-lib: the shared predicate still refuses the project, the primary checkout, and a non-repository path"
}

test_endpoint_in_its_recorded_copy_says_nothing
test_drifted_agent_free_endpoint_is_returned
test_rebind_is_reported_only_when_the_endpoint_actually_arrived
test_live_agent_outside_the_copy_is_reported_and_left_alone
test_isolation_assertion_names_where_the_endpoint_ended_up
test_missing_endpoint_is_left_to_the_reclaim_path
test_an_endpoint_that_is_simply_not_there_is_silent
test_secondmate_and_remote_records_are_skipped
test_reconcile_refuses_an_id_it_cannot_resolve
test_only_live_path_backends_are_reconciled
test_a_frozen_path_backend_record_is_never_acted_on
test_exit_still_refuses_a_composer_it_cannot_prove_empty
test_the_shared_isolation_predicate_still_rejects_primary_and_project
