#!/usr/bin/env bash
# shellcheck disable=SC2034 # Probe/relaunch output globals are read by sourcing callers.
# fm-broken-session-lib.sh - detect ship/scout workers stuck on a model API error
# banner and relaunch them through bin/fm-control.sh with a progress note, without
# discarding the recorded worktree or landed work.
#
# bin/fm-watch.sh owns the poll cadence, relaunch bounds, and check wake emission
# (broken_session_tick). This library owns classification, dwell timing, the
# attempt ledger, and the guarded relaunch call.
#
# A broken session is not a dead endpoint: the agent process may still read alive
# while the harness UI shows a provider failure and accepts no useful turn.
# Detection therefore combines semantic idle, a positively alive agent, and at
# least one visible-pane API-error pattern documented below. Backends without
# viewport capture are skipped rather than guessed from scrollback alone.
#
# Visible-pane patterns (case-insensitive, any one suffices):
#   - API Error
#   - Named models unavailable
#   - Provider error (
#   - Content generator not initialized
#
# Relaunch uses the same control-plane transaction as a manual relaunch: the
# isolated copy, branch, and task records stay authoritative; only the worker
# endpoint is replaced and a progress note is appended to the instructions.
#
# Ledger: state/.broken-session-relaunch-<id>, one tab-separated row per
# attempt, relaunched, failed, or rearmed outcome. Teardown removes it.

set -u

FM_BROKEN_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-backend.sh
. "$FM_BROKEN_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$FM_BROKEN_LIB_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_BROKEN_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_BROKEN_LIB_DIR/fm-timeout-lib.sh"

fm_broken_session_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_BROKEN_LIB_DIR/fm-wake-lib.sh"
}

fm_broken_session_first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# Portable pattern test for fixture and production callers.
fm_broken_session_capture_matches() {  # <visible-capture-text>
  local text=${1:-}
  [ -n "$text" ] || return 1
  printf '%s' "$text" | grep -Eqi \
    'API Error|Named models unavailable|Provider error \(|Content generator not initialized'
}

fm_broken_session_ledger_add() {  # <state> <id> <attempt|relaunched|failed|rearmed>
  printf '%s\t%s\n' "$(date +%s)" "$3" >> "$1/.broken-session-relaunch-$2" 2>/dev/null
}

fm_broken_session_recent_attempts() {  # <state> <id> <window-secs>
  local state=$1 id=$2 window=$3 now cutoff ledger
  ledger="$state/.broken-session-relaunch-$id"
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  now=$(date +%s)
  cutoff=$((now - window))
  awk -F '\t' -v cutoff="$cutoff" \
    '$2 == "rearmed" { n = 0; next } $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "attempt" { n++ } END { print n + 0 }' \
    "$ledger" 2>/dev/null
}

fm_broken_session_lock() {  # <state> <id>
  fm_broken_session_require_locks || return 1
  fm_lock_try_acquire "$1/.broken-session-$2.lock"
}

fm_broken_session_unlock() {  # <state> <id>
  fm_broken_session_require_locks || return 0
  fm_lock_release "$1/.broken-session-$2.lock" 2>/dev/null || true
}

# fm_broken_session_probe <state> <meta> <id>
#
# Read-only classification for one ordinary worker. Populates:
#   FM_BROKEN_STATUS   clear|broken|skip
#   FM_BROKEN_DETAIL   human-readable cause when broken
#   FM_BROKEN_BACKEND  backend name when known
#   FM_BROKEN_WINDOW   endpoint target when known
fm_broken_session_probe() {
  local state=$1 meta=$2 id=$3
  local kind backend target w label capture busy verdict agent_state since_file now age
  FM_BROKEN_STATUS=skip
  FM_BROKEN_DETAIL=
  FM_BROKEN_BACKEND=
  FM_BROKEN_WINDOW=
  kind=$(fm_meta_get "$meta" kind 2>/dev/null || true)
  case "$kind" in
    ship|scout) ;;
    *) FM_BROKEN_DETAIL="kind=$kind"; return 0 ;;
  esac
  backend=$(fm_backend_of_meta "$meta")
  FM_BROKEN_BACKEND=$backend
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    target=$(fm_meta_get "$meta" window 2>/dev/null || true)
  fi
  FM_BROKEN_WINDOW=$target
  [ -n "$target" ] || { FM_BROKEN_DETAIL='no recorded endpoint'; return 0; }
  fm_backend_visible_capture_supported "$backend" || {
    FM_BROKEN_DETAIL="backend $backend has no visible capture"
    return 0
  }
  label="fm-$id"
  capture=$(fm_backend_visible_capture "$backend" "$target" "$label" 2>/dev/null) || {
    FM_BROKEN_DETAIL="visible capture unreadable on $backend"
    return 0
  }
  fm_broken_session_capture_matches "$capture" || {
    FM_BROKEN_STATUS=clear
    return 0
  }
  # The current-state reads below may cost a bounded no-mistakes call, so they
  # are taken only once an error banner is actually on screen.
  if crew_is_paused "$id"; then
    FM_BROKEN_DETAIL='declared external wait'
    return 0
  fi
  if crew_gate_awaits_human_decision "$id" >/dev/null 2>&1; then
    FM_BROKEN_DETAIL='awaiting human gate decision'
    return 0
  fi
  busy=$(fm_busy_classify_meta "$meta" "$id" "$state" "$capture")
  verdict=${busy%% *}
  [ "$verdict" = idle ] || {
    FM_BROKEN_DETAIL="busy class $verdict with error banner visible"
    return 0
  }
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  [ "$agent_state" = alive ] || {
    FM_BROKEN_DETAIL="agent $agent_state with error banner visible"
    return 0
  }
  FM_BROKEN_STATUS=broken
  FM_BROKEN_DETAIL='API error banner visible with idle semantic state and live agent'
  return 0
}

# fm_broken_session_relaunch <state> <id> <note> [timeout-secs]
#
# Runs bin/fm-control.sh relaunch --note under a per-task lock and bounded timer.
# Returns the control exit status; output in FM_BROKEN_REL_OUT / FM_BROKEN_REL_RC.
fm_broken_session_relaunch() {
  local state=$1 id=$2 note=$3 timeout=${4:-120} rc=0
  local relaunch_lock wait_seconds
  FM_BROKEN_REL_OUT=
  FM_BROKEN_REL_RC=0
  if ! fm_broken_session_recent_attempts "$state" "$id" 0 >/dev/null; then
    FM_BROKEN_REL_RC=1
    return 1
  fi
  fm_broken_session_require_locks || return 1
  relaunch_lock="$state/.broken-session-relaunch.lock"
  wait_seconds=${timeout:-120}
  if ! fm_lock_acquire_wait_bounded "$relaunch_lock" "$wait_seconds"; then
    FM_BROKEN_REL_RC=1
    return 1
  fi
  if ! fm_broken_session_ledger_add "$state" "$id" attempt; then
    fm_lock_release "$relaunch_lock" || true
    FM_BROKEN_REL_RC=1
    return 1
  fi
  if [ -n "$timeout" ]; then
    FM_BROKEN_REL_OUT=$(fm_run_timed "$timeout" "$FM_BROKEN_LIB_DIR/fm-control.sh" "$id" relaunch --note "$note" 2>&1) || rc=$?
  else
    FM_BROKEN_REL_OUT=$("$FM_BROKEN_LIB_DIR/fm-control.sh" "$id" relaunch --note "$note" 2>&1) || rc=$?
  fi
  FM_BROKEN_REL_RC=$rc
  if [ "$rc" -eq 0 ]; then
    fm_broken_session_ledger_add "$state" "$id" relaunched || true
  else
    fm_broken_session_ledger_add "$state" "$id" failed || true
  fi
  fm_lock_release "$relaunch_lock" || true
  return "$rc"
}
