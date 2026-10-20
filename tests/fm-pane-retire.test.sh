#!/usr/bin/env bash
# Safety tests for bin/fm-pane-retire.sh.
# Every guard has a case that must keep the pane (dirty tree, no PR, working
# agent, wrong pane, ...), plus the dry run, the locked recheck, the durable
# Treehouse lease, the untouched task records, idempotence, and the
# config/pane-retire gate. The Herdr adapter is faked at its function boundary
# (the same seam tests/fm-herdr-session-cleanup.test.sh uses), so no Herdr
# server, lifecycle, or paid model is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pane-retire)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
export PATH="$FAKEBIN:$PATH"
export FM_PANE_RETIRE_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pane-retire.sh"
unset FM_PANE_RETIRE_SOURCE_ONLY

FIX="$TMP_ROOT/fixture"
CLOSE_LOG="$TMP_ROOT/closes.log"
EVENT_LOG="$TMP_ROOT/events.log"
mkdir -p "$FIX"
: > "$CLOSE_LOG"
: > "$EVENT_LOG"

# --- Herdr adapter fakes, driven by files under $FIX ------------------------

# shellcheck disable=SC2329 # invoked indirectly by the script under test.
fm_backend_herdr_cli() {
  local _session=$1 first=${2:-} second=${3:-} pane=${4:-}
  if [ "$first $second" = "pane get" ] && [ -f "$FIX/paneget-$pane" ]; then
    cat "$FIX/paneget-$pane"
    return 0
  fi
  return 1
}
# shellcheck disable=SC2329
fm_backend_herdr_pane_presence_state() {
  [ ! -e "$FIX/closed-$2" ] || { printf dead; return 0; }
  [ ! -e "$FIX/presence-unknown-$2" ] || { printf unknown; return 0; }
  printf present
}
# shellcheck disable=SC2329
fm_backend_herdr_pane_agent_state() {
  if [ -e "$FIX/closed-$2" ]; then printf dead; return 0; fi
  if [ -f "$FIX/agent-$2" ]; then cat "$FIX/agent-$2"; else printf no-agent; fi
}
# shellcheck disable=SC2329
fm_backend_herdr_pane_shell_tree_proof() { [ ! -e "$FIX/shell-busy-$2" ]; }
# shellcheck disable=SC2329
fm_backend_herdr_agent_status_raw() {
  if [ -f "$FIX/status-$2" ]; then cat "$FIX/status-$2"; else printf idle; fi
}
# shellcheck disable=SC2329
fm_backend_herdr_pane_process_state() {
  if [ -f "$FIX/proc-$2" ]; then cat "$FIX/proc-$2"; else printf agent; fi
}
# shellcheck disable=SC2329
fm_backend_herdr_projection_close_pane_focus_preserving() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CLOSE_LOG"
  printf 'close %s\n' "$2" >> "$EVENT_LOG"
  [ ! -e "$FIX/close-refuses" ] || return 1
  : > "$FIX/closed-$2"
}
# shellcheck disable=SC2329
fm_backend_herdr_presentation_session_lock_path() { printf '%s/presentation.lock' "$TMP_ROOT"; }
# shellcheck disable=SC2329
fm_lock_try_acquire() {
  # A hook may flip a fixture the moment a named lock is taken, to prove the
  # verdict is recomputed after both locks are held.
  if [ -f "$FIX/on-lock-$(basename "$1")" ]; then bash "$FIX/on-lock-$(basename "$1")"; fi
  mkdir "$1" 2>/dev/null
}
# shellcheck disable=SC2329
fm_lock_release() { rm -rf -- "$1"; }
# The Treehouse slot hook is a flag: absent = not a pool slot.
# shellcheck disable=SC2329
fm_treehouse_pool_slot() { [ -e "$FIX/pool-slot" ]; }
# shellcheck disable=SC2329
fm_treehouse_project_lock_path() { printf '%s/project.lock' "$TMP_ROOT"; }
# shellcheck disable=SC2329
fm_pane_retire_slot_state() {
  if [ -e "$FIX/slot-leased" ]; then printf leased; else printf in-use; fi
}
# shellcheck disable=SC2329
treehouse() {
  printf 'treehouse %s\n' "$*" >> "$EVENT_LOG"
  [ ! -e "$FIX/lease-fails" ] || return 1
  : > "$FIX/slot-leased"
}

# --- fixtures ---------------------------------------------------------------

NOW=$(date +%s)

# mk_task <id> [pane-suffix]: a finished ship worker whose pane may be retired.
# Defaults: recorded PR, clean worktree, `done` 1000s old, dead agent over a
# provably idle shell, pane id matching Herdr's report.
mk_task() {
  local id=$1 pane="w1:p$1" tab="w1:t$1" wt="$TMP_ROOT/wt-$1" proj="$TMP_ROOT/proj"
  fm_git_init_commit "$wt"
  mkdir -p "$proj"
  fm_write_meta "$STATE_DIR/$id.meta" \
    "window=default:$pane" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "backend=herdr" "herdr_session=default" \
    "herdr_workspace_id=w1" "herdr_tab_id=$tab" "herdr_pane_id=$pane" \
    "pr=https://example.invalid/pull/1"
  printf 'done [at=%s]: PR https://example.invalid/pull/1\n' "$((NOW - 1000))" > "$STATE_DIR/$id.status"
  printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1"}}}\n' "$pane" "$tab" \
    > "$FIX/paneget-$pane"
}
STATE_DIR=$FM_STATE_OVERRIDE

pane_of() { printf 'w1:p%s' "$1"; }

# Run the script's main under a fresh log; echoes its output.
run_main() { : > "$CLOSE_LOG"; : > "$EVENT_LOG"; fm_pane_retire_main "$@" 2>&1; }

record_digest() {  # <id> -> digest of every record retire must never touch
  local id=$1 wt
  wt=$(fm_meta_get "$STATE_DIR/$id.meta" worktree)
  { cat "$STATE_DIR/$id.meta" "$STATE_DIR/$id.status"
    git -C "$wt" rev-parse HEAD
    git -C "$wt" status --porcelain --untracked-files=all
    git -C "$wt" branch --show-current
  } | cksum
}

reset_fixture() {
  rm -rf "$FIX" "$TMP_ROOT"/*.lock "$TMP_ROOT"/wt-*
  mkdir -p "$FIX"
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

# --- dry run ----------------------------------------------------------------

reset_fixture
mk_task a
out=$(run_main)
assert_contains "$out" "retire a  default:$(pane_of a) idle-shell" "eligible dead-shell worker was not listed as retire"
assert_contains "$out" "summary: 1 eligible" "dry run summary is wrong"
[ ! -s "$CLOSE_LOG" ] || fail "dry run closed a pane"
pass "dry run lists the eligible pane and closes nothing"

# --- apply: happy path, records untouched, idempotent -----------------------

before=$(record_digest a)
out=$(run_main --apply)
assert_contains "$out" "closed a default:$(pane_of a) (idle-shell)" "apply did not report the close"
assert_equals "default $(pane_of a) no-agent" "$(cat "$CLOSE_LOG")" "close helper was not called once with the observed agent state"
assert_equals "$before" "$(record_digest a)" "retire changed a task record, the worktree, or the branch"
pass "apply closes exactly the eligible pane and leaves meta, status, worktree, and branch untouched"
out=$(run_main --apply)
assert_contains "$out" "gone   a" "second run did not see the pane already closed"
[ ! -s "$CLOSE_LOG" ] || fail "second run closed again"
pass "a second run finds the pane gone and is a no-op"

# --- guard: dirty worktree ---------------------------------------------------

reset_fixture
mk_task d1
printf 'x\n' > "$TMP_ROOT/wt-d1/untracked.txt"
mk_task d2
printf 'changed\n' >> "$TMP_ROOT/wt-d2/README.md"
out=$(run_main --apply d1 d2)
assert_contains "$out" "keep   d1  worktree is not clean" "untracked file did not block retirement"
assert_contains "$out" "keep   d2  worktree is not clean" "tracked edit did not block retirement"
[ ! -s "$CLOSE_LOG" ] || fail "a dirty worktree's pane was closed"
pass "guard: dirty tree (untracked or tracked) keeps the pane"

# --- guard: delivery ---------------------------------------------------------

reset_fixture
mk_task p1
sed -i '/^pr=/d' "$STATE_DIR/p1.meta"
mk_task p2
printf 'pr_head=%s\n' "0000000000000000000000000000000000000000" >> "$STATE_DIR/p2.meta"
mk_task p3
sed -i '/^pr=/d' "$STATE_DIR/p3.meta"
fm_git_add_origin "$TMP_ROOT/wt-p3" "$TMP_ROOT/p3.origin.git"
git -C "$TMP_ROOT/wt-p3" fetch -q origin
mk_task p4
printf 'pr_head=%s\n' "$(git -C "$TMP_ROOT/wt-p4" rev-parse HEAD)" >> "$STATE_DIR/p4.meta"
out=$(run_main --apply p1 p2 p3 p4)
assert_contains "$out" "keep   p1  no recorded PR for this head and head not pushed" "no PR and no push did not block retirement"
assert_contains "$out" "keep   p2  no recorded PR for this head" "a PR recorded for a different head did not block retirement"
assert_contains "$out" "closed p3" "a pushed head with no PR should be eligible"
assert_contains "$out" "closed p4" "a PR recorded for this exact head should be eligible"
assert_equals 2 "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" "exactly the two delivered workers should have been closed"
pass "guard: no PR and unpushed head keeps the pane; a pushed head or a matching PR head allows it"

# --- guard: agent state ------------------------------------------------------

reset_fixture
mk_task w1
printf 'live' > "$FIX/agent-$(pane_of w1)"
printf 'working' > "$FIX/status-$(pane_of w1)"
mk_task w2
printf 'live' > "$FIX/agent-$(pane_of w2)"
printf 'other' > "$FIX/proc-$(pane_of w2)"
mk_task w3
printf 'live' > "$FIX/agent-$(pane_of w3)"
printf 'done [at=%s]: PR https://example.invalid/pull/1\n' "$((NOW - 5))" > "$STATE_DIR/w3.status"
mk_task w4
printf 'live' > "$FIX/agent-$(pane_of w4)"
mk_task w5
: > "$FIX/shell-busy-$(pane_of w5)"
mk_task w6
printf 'live' > "$FIX/agent-$(pane_of w6)"
printf 'blocked' > "$FIX/status-$(pane_of w6)"
mk_task w7
printf 'unknown' > "$FIX/agent-$(pane_of w7)"
out=$(run_main --apply w1 w2 w3 w4 w5 w6 w7)
assert_contains "$out" "keep   w1  agent is working, not idle" "a working agent was not protected"
assert_contains "$out" "keep   w2  something besides the agent runs in the pane" "a tool running next to the agent was not protected"
assert_contains "$out" "keep   w3  done line is " "a just-finished agent was not given its quiet time"
assert_contains "$out" "closed w4 default:$(pane_of w4) (idle-agent)" "an idle agent with an old done line should be retired"
assert_contains "$out" "keep   w5  pane shell is not provably idle" "a shell that fails the process proof was not protected"
assert_contains "$out" "keep   w6  agent is blocked, not idle" "a blocked agent was not protected"
assert_contains "$out" "keep   w7  agent state is unknown" "an unknown agent state was not protected"
assert_equals "default $(pane_of w4) live" "$(cat "$CLOSE_LOG")" "only the provably idle agent may be closed, with its live state as the required state"
pass "guard: working, blocked, unknown, busy-pane, and too-fresh agents keep the pane; a provably idle agent is retired"

# --- guard: wrong pane -------------------------------------------------------

reset_fixture
mk_task x1
printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:tOTHER","workspace_id":"w1"}}}\n' "$(pane_of x1)" > "$FIX/paneget-$(pane_of x1)"
mk_task x2
printf '{"result":{"pane":{"pane_id":"w1:pELSE","tab_id":"w1:tx2","workspace_id":"w1"}}}\n' > "$FIX/paneget-$(pane_of x2)"
mk_task x3
printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:tx3","workspace_id":"w9"}}}\n' "$(pane_of x3)" > "$FIX/paneget-$(pane_of x3)"
mk_task x4
rm -f "$FIX/paneget-$(pane_of x4)"
mk_task x5
: > "$FIX/presence-unknown-$(pane_of x5)"
mk_task x6
sed -i 's/^herdr_pane_id=.*/herdr_pane_id=w1:pOTHER/' "$STATE_DIR/x6.meta"
out=$(run_main --apply x1 x2 x3 x4 x5 x6)
for id in x1 x2 x3 x4; do
  assert_contains "$out" "keep   $id  pane is not the recorded workspace and tab" "a pane that does not match the recorded identity was not protected ($id)"
done
assert_contains "$out" "keep   x5  pane presence is unreadable" "an unreadable pane was not protected"
assert_contains "$out" "keep   x6  endpoint record is not exact" "inconsistent endpoint metadata was not protected"
[ ! -s "$CLOSE_LOG" ] || fail "a wrong or unreadable pane was closed"
pass "guard: a pane Herdr does not report as the recorded workspace and tab, an unreadable pane, and a bad endpoint record keep the pane"

# --- guard: task state -------------------------------------------------------

reset_fixture
mk_task s1
printf 'working [at=%s]: reviewing\n' "$NOW" >> "$STATE_DIR/s1.status"
mk_task s2
: > "$STATE_DIR/s2.status"
mk_task s3
mkdir -p "$STATE_DIR/s3.inbox"
: > "$STATE_DIR/s3.inbox/001.msg"
mk_task s4
sed -i 's/^kind=ship/kind=scout/' "$STATE_DIR/s4.meta"
mk_task s5
printf 'backend=tmux\n' >> "$STATE_DIR/s5.meta"
sed -i '/^backend=herdr/d' "$STATE_DIR/s5.meta"
mk_task s6
: > "$STATE_DIR/s6.herdr-presentation"
mk_task s7
mkdir -p "$STATE_DIR/s7.inbox/handled"
: > "$STATE_DIR/s7.inbox/handled/001.msg"
out=$(run_main --apply s1 s2 s3 s4 s5 s6 s7)
assert_contains "$out" "keep   s1  last status is working, not done" "a later working line did not block retirement"
assert_contains "$out" "keep   s2  last status is empty, not done" "a task with no status was retired"
assert_contains "$out" "keep   s3  a steering message is still waiting" "an unread steering message did not block retirement"
assert_contains "$out" "keep   s4  not a ship worker (kind=scout)" "a scout was retired"
assert_contains "$out" "keep   s5  not a herdr worker" "a non-Herdr worker was retired"
assert_contains "$out" "keep   s6  projected workspace is left to teardown" "a projected workspace was retired"
assert_contains "$out" "closed s7" "an acknowledged steering message must not block retirement"
assert_equals 1 "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" "only the task with a handled inbox should have closed"
pass "guard: non-done status, unread steering, scouts, other backends, and projected workspaces keep the pane"

# --- locks and the recheck under them ---------------------------------------

reset_fixture
mk_task l1
mkdir "$TMP_ROOT/presentation.lock"
out=$(run_main --apply l1)
assert_contains "$out" "refused l1 session presentation lock is busy" "a busy session lock did not refuse"
[ ! -s "$CLOSE_LOG" ] || fail "closed while the session lock was busy"
[ ! -e "$STATE_DIR/.spawn-l1.lock" ] || fail "the task lock leaked after a busy session lock"
rm -rf "$TMP_ROOT/presentation.lock"
mkdir "$STATE_DIR/.spawn-l1.lock"
out=$(run_main --apply l1)
assert_contains "$out" "refused l1 task lock is busy" "a busy task lock did not refuse"
[ ! -s "$CLOSE_LOG" ] || fail "closed while the task lock was busy"
rm -rf "$STATE_DIR/.spawn-l1.lock"
pass "a busy task lock or session lock refuses the close and leaks no lock"

reset_fixture
mk_task r1
printf '#!/usr/bin/env bash\nprintf dirt > %s/untracked.txt\n' "$TMP_ROOT/wt-r1" > "$FIX/on-lock-presentation.lock"
out=$(run_main --apply r1)
assert_contains "$out" "refused r1 verdict changed under the locks: keep" "a change landing between listing and close was not caught"
[ ! -s "$CLOSE_LOG" ] || fail "closed on a stale verdict"
[ ! -e "$STATE_DIR/.spawn-r1.lock" ] && [ ! -e "$TMP_ROOT/presentation.lock" ] || fail "locks leaked after a changed verdict"
pass "the whole verdict is recomputed after both locks are held"

reset_fixture
mk_task c1
: > "$FIX/close-refuses"
out=$(run_main --apply c1)
assert_contains "$out" "refused c1 the exact focus-safe close was refused or unconfirmed" "a refused close was reported as success"
[ ! -e "$FIX/closed-$(pane_of c1)" ] || fail "fixture closed the pane despite refusal"
pass "a refused or unconfirmed focus-safe close is reported as refused"

# --- durable Treehouse lease --------------------------------------------------

reset_fixture
mk_task t1
: > "$FIX/pool-slot"
: > "$FIX/lease-fails"
out=$(run_main --apply t1)
assert_contains "$out" "refused t1 the worktree slot could not be durably leased" "a failed lease did not stop the close"
[ ! -s "$CLOSE_LOG" ] || fail "closed a pane whose slot could not be durably leased"
rm -f "$FIX/lease-fails"
out=$(run_main --apply t1)
assert_contains "$out" "closed t1" "a successful lease should allow the close"
first=$(grep -n '^treehouse lease' "$EVENT_LOG" | head -1 | cut -d: -f1)
second=$(grep -n '^close ' "$EVENT_LOG" | head -1 | cut -d: -f1)
[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || fail "the lease must be taken before the pane is closed"
assert_contains "$(cat "$EVENT_LOG")" "--lease-holder fm-t1" "the lease must name the task as holder"
pass "a pool slot is durably leased before its pane is closed, and an unleasable slot keeps the pane"

reset_fixture
mk_task t2
: > "$FIX/pool-slot"
: > "$FIX/slot-leased"
out=$(run_main --apply t2)
assert_contains "$out" "closed t2" "an already-leased slot should allow the close"
assert_not_contains "$(cat "$EVENT_LOG")" "treehouse lease" "an already leased slot must not be leased again"
reset_fixture
mk_task t3
out=$(run_main --apply t3)
assert_contains "$out" "closed t3" "a worktree outside any pool should allow the close"
assert_not_contains "$(cat "$EVENT_LOG")" "treehouse" "a worktree that is not a pool slot needs no lease"
pass "an already-leased slot and a non-pool worktree need no new lease"

# --- id restriction, bad usage ------------------------------------------------

reset_fixture
mk_task i1
mk_task i2
out=$(run_main --apply i1)
assert_contains "$out" "closed i1" "the named task was not closed"
assert_not_contains "$out" "i2" "an unnamed task appeared in a restricted run"
assert_equals 1 "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" "a restricted run closed more than the named task"
status=0
fm_pane_retire_main --nope >/dev/null 2>&1 || status=$?
expect_code 2 "$status" "unknown option exit"
status=0
fm_pane_retire_main 'bad id' >/dev/null 2>&1 || status=$?
expect_code 2 "$status" "invalid task id exit"
pass "naming tasks restricts the run and bad usage exits 2"

# --- config/pane-retire gate for --auto --------------------------------------

reset_fixture
mk_task g1
rm -f "$FM_CONFIG_OVERRIDE/pane-retire"
out=$(run_main --auto)
assert_equals "" "$out" "--auto without the flag must be silent"
[ ! -s "$CLOSE_LOG" ] || fail "--auto without the flag closed a pane"
printf 'off\n' > "$FM_CONFIG_OVERRIDE/pane-retire"
out=$(run_main --auto)
[ ! -s "$CLOSE_LOG" ] || fail "--auto with the flag off closed a pane"
printf 'yes please\n' > "$FM_CONFIG_OVERRIDE/pane-retire"
out=$(run_main --auto)
[ ! -s "$CLOSE_LOG" ] || fail "--auto with an invalid flag value closed a pane"
printf 'on\n' > "$FM_CONFIG_OVERRIDE/pane-retire"
out=$(run_main --auto)
assert_contains "$out" "closed g1" "--auto with the flag on did not close the eligible pane"
assert_not_contains "$out" "dry run" "--auto must not print the captain-facing banner"
rm -f "$FM_CONFIG_OVERRIDE/pane-retire"
pass "--auto does nothing unless config/pane-retire holds on"

# --- the watcher paces the sweep only when the flag is present ----------------

home="$TMP_ROOT/watch-home"
mkdir -p "$home/state" "$home/data" "$home/config"
env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 >/dev/null 2>&1 || true
[ ! -e "$home/state/.last-pane-retire" ] || fail "the watcher ran the retire sweep without config/pane-retire"
printf 'on\n' > "$home/config/pane-retire"
env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 >/dev/null 2>&1 || true
[ -e "$home/state/.last-pane-retire" ] || fail "the watcher did not pace the retire sweep with config/pane-retire on"
pass "the watcher runs the sweep only in a home that opted in"

# --- adapter proof: nothing but shells below the pane shell -------------------
# The sample is the proof's one strict observation; the file-level fake above
# replaces the retrying wrapper, so the real logic is exercised through it.

PS_DIR="$TMP_ROOT/ps"
mkdir -p "$PS_DIR"
cat > "$PS_DIR/ps" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
case "$*" in
  "-axo pid=,ppid=,comm=") cat "$dir/rows" ;;
  "-axo pid=,ppid=") awk '{print $1, $2}' "$dir/rows" ;;
  "-p "*" -o args=")
    pid=$2
    cat "$dir/args-$pid" 2>/dev/null || exit 1
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$PS_DIR/ps"
printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:pT","shell_pid":100,"foreground_process_group_id":300,"foreground_processes":[{"argv":["/usr/bin/bash","-i","-l"],"cmdline":"/usr/bin/bash -i -l","name":"bash","pid":300}]}}}' > "$PS_DIR/info"
printf '/usr/bin/bash -i -l\n' > "$PS_DIR/args-300"
printf 'treehouse get\n' > "$PS_DIR/args-200"
printf 'node server.js\n' > "$PS_DIR/args-400"

# Same shape the live crew panes have: pane shell, `treehouse get`, nested login shell.
printf '100 1 bash\n200 100 treehouse\n300 200 bash\n' > "$PS_DIR/rows"
(
  # shellcheck disable=SC2329 # invoked indirectly by the proof.
  fm_backend_herdr_cli() { cat "$PS_DIR/info"; }
  FM_HERDR_PS_BIN="$PS_DIR/ps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_shell_tree_sample test w1:pT >/dev/null
) || fail "the nested treehouse login-shell shape was not accepted by the shell-tree proof"
pass "shell-tree proof accepts a pane shell with a nested treehouse login shell"

# A backgrounded server under the same shell must keep the pane open.
printf '100 1 bash\n200 100 treehouse\n300 200 bash\n400 300 node\n' > "$PS_DIR/rows"
if (
  # shellcheck disable=SC2329 # invoked indirectly by the proof.
  fm_backend_herdr_cli() { cat "$PS_DIR/info"; }
  FM_HERDR_PS_BIN="$PS_DIR/ps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_shell_tree_sample test w1:pT >/dev/null
); then
  fail "a background server under the pane shell passed the shell-tree proof"
fi
pass "shell-tree proof refuses a backgrounded server below the pane shell"

# A foreground tool in its own process group is not a shell-only pane.
printf '100 1 bash\n300 100 vite\n' > "$PS_DIR/rows"
printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:pT","shell_pid":100,"foreground_process_group_id":300,"foreground_processes":[{"argv":["vite"],"cmdline":"vite","name":"vite","pid":300}]}}}' > "$PS_DIR/info"
if (
  # shellcheck disable=SC2329 # invoked indirectly by the proof.
  fm_backend_herdr_cli() { cat "$PS_DIR/info"; }
  FM_HERDR_PS_BIN="$PS_DIR/ps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_shell_tree_sample test w1:pT >/dev/null
); then
  fail "a foreground tool passed the shell-tree proof"
fi
pass "shell-tree proof refuses a foreground tool"

# --- real Treehouse: the lease survives the process that held the slot --------

if command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  unset -f treehouse fm_treehouse_pool_slot fm_treehouse_project_lock_path fm_pane_retire_slot_state
  # Reload the real definitions (locks, slot state) the fakes above replaced.
  # shellcheck source=/dev/null
  FM_PANE_RETIRE_SOURCE_ONLY=1 . "$ROOT/bin/fm-pane-retire.sh"
  TH="$TMP_ROOT/th"
  mkdir -p "$TH/pool" "$TH/bin"
  REPO="$TH/repo"
  fm_git_init_commit "$REPO"
  export TREEHOUSE_ROOT="$TH/pool"
  # A shell that stays alive stands in for the interactive `treehouse get`.
  printf '#!/bin/sh\necho $$ > %s/holder.pid\nexec sleep 60\n' "$TH" > "$TH/bin/holdsh"
  chmod +x "$TH/bin/holdsh"
  ( cd "$REPO" && SHELL="$TH/bin/holdsh" treehouse get >/dev/null 2>&1 ) &
  holder=$!
  slot=
  for _ in $(seq 1 50); do
    slot=$(cd "$REPO" && treehouse status --json 2>/dev/null | jq -r '[.[] | select(.status == "in-use")][0].path // empty')
    [ -n "$slot" ] && break
    sleep 0.2
  done
  [ -n "$slot" ] || fail "could not acquire a real Treehouse slot for the lease test"
  mkdir -p "$FM_HOME/state"
  fm_pane_retire_hold_slot lease1 "$REPO" "$slot" || fail "real treehouse lease was not confirmed"
  kill "$(cat "$TH/holder.pid" 2>/dev/null)" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  sleep 1
  state=$(cd "$slot" && treehouse status --json 2>/dev/null | jq -r --arg p "$slot" '.[] | select(.path == $p) | .status')
  assert_equals leased "$state" "the slot was not held after its process exited"
  ( cd "$slot" && treehouse return --force "$slot" ) >/dev/null 2>&1 || fail "teardown's return could not release the retire lease"
  state=$(cd "$REPO" && treehouse status --json 2>/dev/null | jq -r --arg p "$slot" '.[] | select(.path == $p) | .status')
  assert_not_equals leased "$state" "treehouse return did not release the retire lease"
  unset TREEHOUSE_ROOT
  pass "a real Treehouse slot stays leased after its process exits, and teardown's return releases it"
else
  printf 'skip: treehouse or jq not found; real lease case not run\n'
fi

printf 'all fm-pane-retire tests passed\n'
