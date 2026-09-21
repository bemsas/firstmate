#!/usr/bin/env bash
# Restored Herdr endpoints come back on the same pane id with a new shell
# whose cwd is the directory saved at pane creation, not the recorded worktree.
# Reconciliation closes that pane so relaunch reclaim applies.
# A shell that has been alive since the task was recorded is left running,
# which is the case a control-plane cwd refusal must still be able to refuse.
# Exit's composer refusal is pinned by tests/fm-control-relaunch.test.sh and
# is not relaxed here: this path never types into the pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-restored-endpoint)
mkdir -p "$TMP_ROOT"
SHELL_PID=
cleanup() {
  [ -z "$SHELL_PID" ] || kill "$SHELL_PID" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_herdr_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.1","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
echo "$next" > "$COUNT_FILE"
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

start_shell() {
  [ -n "$SHELL_PID" ] && kill -0 "$SHELL_PID" 2>/dev/null && return 0
  sleep 120 &
  SHELL_PID=$!
}

new_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/responses" "$dir/worktree" "$dir/drift"
  : > "$dir/log"
  printf '%s\n' "$dir"
}

write_meta() {  # <dir> <worktree> <spawn-gen> [extra-line]
  cat > "$1/state/t1.meta" <<EOF
window=fmtest:w1:p2
endpoint_task_id=t1
backend=herdr
worktree=$2
spawn_gen=$3
${4-}
EOF
}

pane_json() {  # <foreground> <pane-id>
  jq -nc --arg cwd "$1" --arg fg "$1" --arg pane "$2" \
    '{result:{pane:{pane_id:$pane,cwd:$cwd,foreground_cwd:$fg}}}'
}

process_json() {  # <pid>
  jq -nc --argjson pid "$1" \
    '{result:{type:"pane_process_info",process_info:{pane_id:"w1:p2",shell_pid:$pid}}}'
}

session_json() {
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-rebind-unit.sock"}]}'
}

not_found_json() {
  printf '%s\n' '{"error":{"code":"pane_not_found"}}'
}

run_one() {  # <dir>
  local fb
  fb=$(make_herdr_fakebin "$1")
  PATH="$fb:$PATH" FM_HOME="$1" FM_HERDR_LOG="$1/log" FM_HERDR_RESPONSES="$1/responses" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_reconcile_restored_endpoint "$2"' \
    _ "$ROOT" "$1/state/t1.meta"
}

run_sweep() {  # <dir>
  local fb
  fb=$(make_herdr_fakebin "$1")
  PATH="$fb:$PATH" FM_HOME="$1" FM_HERDR_LOG="$1/log" FM_HERDR_RESPONSES="$1/responses" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_reconcile_restored_endpoints "$2"' \
    _ "$ROOT" "$1/state"
}

closed() {  # <log>
  grep -q $'pane\x1fclose' "$1"
}

# --- a restored shell outside the worktree is closed -----------------------
start_shell
dir=$(new_case close-drift)
write_meta "$dir" "$dir/worktree" s1.1.1
pane_json "$dir/drift" w1:p2 > "$dir/responses/1.out"
process_json "$SHELL_PID" > "$dir/responses/2.out"
session_json > "$dir/responses/3.out"
printf '%s\n' '{}' > "$dir/responses/4.out"
not_found_json > "$dir/responses/6.out"
not_found_json > "$dir/responses/7.out"
out=$(run_one "$dir")
[ "$out" = destroyed ] || fail "a restored shell outside the worktree should be closed, got '$out'"
closed "$dir/log" || fail "closing a restored endpoint must close the pane: $(cat "$dir/log")"
if grep -E $'send-text|send-keys|pane\x1frun' "$dir/log" >/dev/null; then
  fail "reconciliation must not type into the pane: $(cat "$dir/log")"
fi
grep -q "^worktree=$dir/worktree$" "$dir/state/t1.meta" \
  || fail "closing the endpoint must leave the recorded worktree in place"
pass "a restored herdr shell outside its recorded worktree is closed and the record stays"

# --- the same record, swept, names the task --------------------------------
dir=$(new_case sweep)
write_meta "$dir" "$dir/worktree" s1.1.1
pane_json "$dir/drift" w1:p2 > "$dir/responses/1.out"
process_json "$SHELL_PID" > "$dir/responses/2.out"
session_json > "$dir/responses/3.out"
printf '%s\n' '{}' > "$dir/responses/4.out"
not_found_json > "$dir/responses/6.out"
not_found_json > "$dir/responses/7.out"
out=$(run_sweep "$dir")
[ "$out" = t1 ] || fail "the sweep should name the closed task, got '$out'"
pass "the state sweep reports the task whose restored endpoint was closed"

# --- foreground already in the worktree is left alone ----------------------
dir=$(new_case in-worktree)
write_meta "$dir" "$dir/worktree" s1.1.1
pane_json "$dir/worktree" w1:p2 > "$dir/responses/1.out"
out=$(run_one "$dir")
[ "$out" = in-worktree ] || fail "a shell in its worktree should stay, got '$out'"
closed "$dir/log" && fail "a shell in its worktree must not be closed"
pass "a herdr endpoint already in its recorded worktree is not closed"

# --- a shell alive since the task was recorded is the refusal case ---------
# spawn_gen is in the future, so this live shell is older than the record.
# That is the process a cwd refusal must still be able to refuse: it is
# outside the worktree and this reconciliation does not claim it.
dir=$(new_case live-drift)
write_meta "$dir" "$dir/worktree" s9999999999.1.1
pane_json "$dir/drift" w1:p2 > "$dir/responses/1.out"
process_json "$SHELL_PID" > "$dir/responses/2.out"
out=$(run_one "$dir")
[ "$out" = unproven ] || fail "a shell older than the record must not be claimed, got '$out'"
closed "$dir/log" && fail "a live cwd mismatch must be left for the control plane to refuse"
pass "a shell alive since the task was recorded is left running outside the worktree"

# --- identity that does not round-trip is not closed -----------------------
dir=$(new_case wrong-pane)
write_meta "$dir" "$dir/worktree" s1.1.1
pane_json "$dir/drift" w9:p9 > "$dir/responses/1.out"
out=$(run_one "$dir")
[ "$out" = unproven ] || fail "a different pane id must not be closed, got '$out'"
closed "$dir/log" && fail "a pane id mismatch must not close anything"
pass "a pane id that does not match the record is not closed"

# --- an already gone pane is not closed again ------------------------------
dir=$(new_case already-gone)
write_meta "$dir" "$dir/worktree" s1.1.1
not_found_json > "$dir/responses/1.out"
out=$(run_one "$dir")
[ "$out" = unproven ] || fail "a missing pane should be unproven, got '$out'"
closed "$dir/log" && fail "a missing pane must not be closed again"
pass "a pane that is already gone is left for reclaim without another close"

# --- other backends and a remote record change nothing --------------------
dir=$(new_case other-backends)
for backend in tmux zellij cmux orca; do
  printf 'window=somewhere\nendpoint_task_id=t1\nbackend=%s\nworktree=%s\nspawn_gen=s1.1.1\n' \
    "$backend" "$dir/worktree" > "$dir/state/t1.meta"
  out=$(run_one "$dir")
  [ "$out" = unsupported ] || fail "$backend should be unsupported, got '$out'"
done
printf 'window=fmtest:w1:p2\nendpoint_task_id=t1\nbackend=herdr\nworktree=%s\nspawn_gen=s1.1.1\nremote_host=other\n' \
  "$dir/worktree" > "$dir/state/t1.meta"
out=$(run_one "$dir")
[ "$out" = unsupported ] || fail "a remote record should be unsupported, got '$out'"
[ ! -s "$dir/log" ] || fail "unsupported backends must not call herdr: $(cat "$dir/log")"
pass "tmux, zellij, cmux, orca, and a remote record are not reconciled"

# --- a missing spawn generation cannot prove a restore ---------------------
dir=$(new_case no-spawn-gen)
printf 'window=fmtest:w1:p2\nendpoint_task_id=t1\nbackend=herdr\nworktree=%s\n' \
  "$dir/worktree" > "$dir/state/t1.meta"
out=$(run_one "$dir")
[ "$out" = unproven ] || fail "a record with no spawn_gen must be unproven, got '$out'"
[ ! -s "$dir/log" ] || fail "an unproven spawn generation must not call herdr"
pass "a record with no spawn generation is not closed"
