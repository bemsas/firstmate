#!/usr/bin/env bash
# Live guard for the agy worker busy hooks against the INSTALLED agy: it writes
# the exact workspace hooks bin/fm-agy-worker-hooks.sh gives a worker into a
# scratch git workspace, runs one interactive agy turn in a private tmux
# server, interrupts it with Escape, then completes a second turn, and requires:
#   - the running turn reads busy agy-hook (PreInvocation fired);
#   - after Escape the record is still busy agy-hook: agy fires no closing hook
#     on an interrupt, which is why bin/fm-control.sh and
#     fm_busy_agy_record_contradicted exist (a version that starts closing
#     interrupted turns fails here so the gap can be re-evaluated);
#   - the completed second turn reads idle agy-hook (Stop with fullyIdle true)
#     and its tool call reached the tool ring as an agy-hook event.
# Opt-in because it submits prompts:
#
#   FM_AGY_WORKER_HOOKS_LIVE_E2E=1 tests/fm-agy-worker-hooks-live-e2e.test.sh
#
# The scratch workspace is new to agy, so its folder-trust dialog is answered
# once, which records that scratch path in agy's own trust store. Failures name
# the harness and its version; an installed version missing from
# FM_BUSY_AGY_HOOK_VERIFIED_VERSIONS fails rather than passing over the gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_WORKER_HOOKS_LIVE_E2E agy tmux git jq python3

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

LAB=$(fm_test_tmproot fm-agy-worker-hooks-live)
SOCKET="fmagyh-$$"
STATE="$LAB/state"
WS="$LAB/workspace"
ID=agylive
VERSION=$(agy --version 2>/dev/null | head -1)
cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$STATE" "$WS"
git -C "$WS" init -q
printf 'hi\n' > "$WS/a.txt"

classify() { fm_busy_classify tmux "$SOCKET" agy "$ID" "$STATE"; }
wait_for() {  # <expected> <seconds>
  local i out=''
  for i in $(seq 1 "$2"); do
    out=$(classify)
    [ "$out" = "$1" ] && return 0
    sleep 1
  done
  printf '%s' "$out"
  return 1
}

test_agy_worker_hooks_bracket_turns() {
  local gen out i pane
  fm_busy_agy_hooks_verified "$VERSION" \
    || fail "agy $VERSION is not in FM_BUSY_AGY_HOOK_VERIFIED_VERSIONS; re-verify and add it"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID")
  "$ROOT/bin/fm-agy-worker-hooks.sh" "$WS" "$STATE" "$ID" "$gen" "$STATE/$ID.turn-ended" \
    || fail "agy $VERSION: hooks writer failed"
  tmux -L "$SOCKET" new-session -d -x 160 -y 45 \
    "cd '$WS' && agy --prompt-interactive 'Run the shell command: sleep 45 ; then reply with the single word finished.' --effort low; sleep 30"
  for i in $(seq 1 40); do
    pane=$(tmux -L "$SOCKET" capture-pane -p 2>/dev/null)
    case "$pane" in *"trust the contents"*) tmux -L "$SOCKET" send-keys Enter; sleep 2 ;; esac
    [ "$(classify)" = "busy agy-hook" ] && break
    sleep 1
  done
  out=$(wait_for "busy agy-hook" 30) || fail "agy $VERSION: PreInvocation never opened the turn (got '$out')"
  sleep 8
  tmux -L "$SOCKET" send-keys Escape
  sleep 8
  out=$(classify)
  [ "$out" = "busy agy-hook" ] \
    || fail "agy $VERSION: an Escape interrupt changed the record to '$out'; agy may now close interrupted turns - re-evaluate the interrupt invalidation"
  tmux -L "$SOCKET" send-keys -l 'Run the shell command: echo ok ; then reply with the single word done.'
  sleep 1
  tmux -L "$SOCKET" send-keys Enter
  out=$(wait_for "idle agy-hook" 150) || fail "agy $VERSION: a completed turn did not close on Stop fullyIdle (got '$out')"
  assert_present "$STATE/$ID.turn-ended" "agy $VERSION: the closing Stop did not touch the turn-ended notification"
  assert_grep '"src":"agy-hook"' "$STATE/$ID.tool-ring.jsonl" "agy $VERSION: PostToolUse did not reach the tool ring"
  pass "agy $VERSION: worker hooks open on PreInvocation, close on a fullyIdle Stop, stay open on Escape, and feed the ring"
}

fm_test_run test_agy_worker_hooks_bracket_turns
