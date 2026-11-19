#!/usr/bin/env bash
# Live guard for the codex-rollout busy source (bin/fm-busy-lib.sh) against the
# INSTALLED Codex CLI: it launches a sandboxed interactive Codex exactly like a
# Firstmate worker (task-private home through bin/fm-codex-worker.py
# prepare/launch) in a private tmux server, and requires fm_busy_classify to
# read busy while a turn runs, idle after an Escape interrupt, and idle after
# a completed turn. Opt-in because it submits prompts:
#
#   FM_CODEX_ROLLOUT_LIVE_E2E=1 tests/fm-codex-rollout-live-e2e.test.sh
#
# Failures name the harness and its version; an installed version missing
# from FM_BUSY_CODEX_ROLLOUT_VERIFIED_VERSIONS fails rather than passing over
# the gate, so a Codex upgrade is re-verified before it is trusted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_ROLLOUT_LIVE_E2E codex tmux git python3

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

LAB=$(fm_test_tmproot fm-codex-rollout-live)
SOCKET="fmcxr-$$"
TASK=cxlive
STATE="$LAB/state"
PROJ="$LAB/project"
VERSION=$(codex --version 2>/dev/null | head -1)
cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  python3 "$ROOT/bin/fm-codex-worker.py" remove "$STATE/$TASK.codex-home" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$STATE" "$PROJ"
git -C "$PROJ" init -q
printf 'hi\n' > "$PROJ/a.txt"

classify() { fm_busy_classify tmux "$SOCKET" codex "$TASK" "$STATE"; }
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

test_codex_rollout_brackets_turns() {
  local out i pane ver
  python3 "$ROOT/bin/fm-codex-worker.py" prepare "$PROJ" "$STATE" "$TASK" \
    || fail "$VERSION: worker home prepare failed"
  tmux -L "$SOCKET" new-session -d -x 160 -y 45 \
    "cd '$PROJ' && python3 '$ROOT/bin/fm-codex-worker.py' launch '$STATE/$TASK.codex-home' '$PROJ' codex -s workspace-write -a never -c model_reasoning_effort=low 'Run the shell command: sleep 45 ; then reply with the single word finished.'; sleep 30"
  for i in $(seq 1 40); do
    pane=$(tmux -L "$SOCKET" capture-pane -p 2>/dev/null)
    case "$pane" in *"Trust this folder"*) tmux -L "$SOCKET" send-keys Enter; sleep 2 ;; esac
    fm_busy_codex_rollout "$STATE" "$TASK" >/dev/null 2>&1 && break
    sleep 1
  done
  out=$(fm_busy_codex_rollout "$STATE" "$TASK") || fail "$VERSION: no interactive rollout appeared in the private home"
  ver=$(fm_busy_codex_rollout_version "$out")
  fm_busy_codex_rollout_verified "$ver" \
    || fail "codex $ver: rollout version is not in FM_BUSY_CODEX_ROLLOUT_VERIFIED_VERSIONS; re-verify and add it"
  out=$(wait_for "busy codex-rollout" 60) || fail "$VERSION: a running turn did not classify busy (got '$out')"
  sleep 8
  out=$(classify)
  [ "$out" = "busy codex-rollout" ] || fail "$VERSION: the turn stopped reading busy mid-command (got '$out')"
  tmux -L "$SOCKET" send-keys Escape
  out=$(wait_for "idle codex-rollout" 20) || fail "$VERSION: an Escape interrupt did not close the turn (got '$out')"
  tmux -L "$SOCKET" send-keys -l 'Reply with the single word ok.'
  sleep 1
  tmux -L "$SOCKET" send-keys Enter
  out=$(wait_for "busy codex-rollout" 30) || fail "$VERSION: the second turn did not open (got '$out')"
  out=$(wait_for "idle codex-rollout" 120) || fail "$VERSION: a completed turn did not close (got '$out')"
  pass "codex $ver: rollout source reads busy during a turn, idle after Escape and after completion"
}

fm_test_run test_codex_rollout_brackets_turns
