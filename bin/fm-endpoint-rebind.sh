#!/usr/bin/env bash
# fm-endpoint-rebind.sh - RESTORED-ENDPOINT RECONCILIATION: return a task's
# terminal endpoint to the local copy its record names, after something outside
# firstmate moved it.
#
# Usage: fm-endpoint-rebind.sh sweep
#        fm-endpoint-rebind.sh reconcile <task-id>
#
# WHY THIS EXISTS. A terminal endpoint can be restored by its own runtime after
# a machine reboot, and a restored endpoint does not come back where it was.
# Measured live on 2026-09-21 (Herdr 0.9.1, boot 09:46:44, task
# fm-stop-unreachable-b): the recorded workspace, tab and pane ids all survived
# intact, while `pane get` reported BOTH `cwd` and `foreground_cwd` as the
# repository's primary checkout instead of the task's recorded worktree, and
# the pane's foreground process was `grok --resume <agent-session-id>` - Herdr
# had restarted the agent itself, from the restored pane's directory.
# docs/herdr-backend.md "Restored endpoints do not keep their working
# directory" owns that empirical statement.
#
# Two things follow, and this script is the single owner of both.
#
#   1. OWNERSHIP IS NOT CWD. Before this existed, a working directory that did
#      not match the record was the effective test of whether an endpoint was
#      still the task's, so a restored endpoint read as un-ownable and every
#      control verb that depends on reaching it was stuck. A working directory
#      does not survive a restore; the RECORDED ENDPOINT IDENTITY does, and it
#      is what proves ownership here - the same identity every other control
#      path binds to, validated by bin/fm-backend.sh's
#      fm_backend_validate_task_endpoint (for herdr that is the recorded
#      session plus workspace, tab and pane ids, all read back through the
#      recorded session's own socket; for tmux the exact fm-<id> window in the
#      recorded session). Once identity holds, a mismatched working directory
#      is DRIFT TO REPAIR, not evidence that the endpoint belongs to someone
#      else.
#
#   2. THE ISOLATION ASSERTION HAS TO RUN AGAIN. bin/fm-spawn.sh proves a task
#      starts in an isolated disposable worktree, but that proof is taken at
#      launch and a restore happens long after it. An endpoint restored into
#      the primary checkout or a project clone is outside the worktree-
#      isolation contract with nothing having steered it there. This re-runs
#      the SAME predicate (bin/fm-worktree-isolation-lib.sh) against the
#      endpoint's live path, so the breach is reported rather than silent.
#
# WHAT IT DOES, per task, and nothing else:
#   - proves the endpoint is this task's by its recorded identity;
#   - reads the endpoint's live working directory;
#   - when that already matches the recorded worktree, says nothing at all;
#   - when it does not, REBINDS an agent-free endpoint back to the recorded
#     worktree, so the ordinary control verbs work against it again;
#   - when an agent is running in the drifted endpoint, reports the isolation
#     breach and changes nothing.
#
# WHY REBIND, AND NOT "MARK THE ENDPOINT DESTROYED". The other available remedy
# is to record the endpoint as gone so relaunch's reclaim path re-creates one.
# That is the wrong remedy for an endpoint that SURVIVED: the live reads above
# show the recorded pane answering with its recorded ids, so `gone` would be a
# false fact written into a durable record, and it would be read by the one
# proof built to stop exactly that (fm_control_endpoint_absence_verdict, which
# exists because `missing` conflates destroyed with unreachable). Acting on it
# would send the herdr reclaim path off to create a SECOND endpoint for a task
# whose first one is still running an agent - the duplicate-agent outcome that
# proof was written to prevent. Reclaim already owns the genuinely-gone case
# and keeps it; this owns the survived-but-moved case, which nothing owned.
#
# WHAT IT REFUSES, and why each refusal is a property of the backend rather
# than of the reading:
#   - A backend whose current-path read is frozen at endpoint creation time
#     (zellij, cmux) or absent entirely (orca) cannot tell a moved endpoint
#     from an unmoved one, so drift is never inferred on it.
#     bin/fm-backend.sh's fm_backend_current_path_is_live owns that split.
#   - A backend with no recovery-grade agent-state classifier cannot prove the
#     endpoint is agent-free, and typing a shell command into an endpoint that
#     might hold a live agent is exactly what must not happen. Together those
#     two gates leave tmux and herdr.
#   - Anything other than a positive `dead` leaves the endpoint untouched. An
#     `alive` drifted endpoint is REPORTED, never typed into and never
#     signalled: this plane has no authority to end an agent, and does not take
#     any. bin/fm-control.sh keeps sole ownership of stopping one, with its
#     composer-empty proof intact.
#   - An endpoint that is simply not there is skipped in silence, and one that
#     answers a read and then classifies `missing` is reported as the
#     contradiction it is. Either way absence stays with the reclaim path that
#     owns it; this never declares an endpoint gone.
#   - A secondmate is skipped outright: its recorded worktree is a provisioned
#     home, not a disposable task worktree, and bin/fm-bootstrap.sh's liveness
#     sweep owns its recovery.
#   - A remotely placed record is skipped: its endpoint is on another host, so
#     nothing read here would be about it.
#
# ACCEPTED RESIDUAL. The `cd` is submitted as one line into an endpoint the
# recovery-grade classifier reports agent-free. A shell holding typed but
# unsubmitted text is not observable at process level on either backend, so
# such a line would concatenate and fail; the postcondition below is what makes
# that safe to accept - a rebind is reported only when the endpoint's live path
# is afterwards READ BACK as the recorded worktree, so a failed `cd` reports
# failure rather than a rebind that did not happen. This is the same exposure
# bin/fm-spawn.sh's relaunch path already accepts when it returns a drifted
# endpoint to its worktree.
#
# OUTPUT. One line per outcome that is not a no-op, and silence otherwise:
#   ENDPOINT_REBIND: <id>: <something firstmate must act on>
#   BOOTSTRAP_INFO: <id>: <completed, no action needed>
# Exit status is 0 whenever the sweep itself ran; a per-task problem is a
# reported line, not a failed sweep.
#
# WHERE IT RUNS. bin/fm-bootstrap.sh's local mutating sweep, which is the point
# where a restoration is first observed: a reboot ends the session that was
# supervising, so the next locked session start is firstmate's first look at
# the restored fleet. It is idempotent and safe to re-run by hand at any time.
#
# Environment knobs (bounded waits, seconds):
#   FM_ENDPOINT_REBIND_WAIT   live-path read-back wait after the cd (20)
#   FM_ENDPOINT_REBIND_POLL   poll interval for that read-back (0.5)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# A no-mistakes gate agent must never move a crewmate's endpoint.
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-worktree-isolation-lib.sh
. "$SCRIPT_DIR/fm-worktree-isolation-lib.sh"

FM_HOME="${FM_HOME:-$FM_ROOT}"
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

WAIT=${FM_ENDPOINT_REBIND_WAIT:-20}
POLL=${FM_ENDPOINT_REBIND_POLL:-0.5}
EXIT_RETRIES=${FM_ENDPOINT_REBIND_RETRIES:-3}

report() {  # <id> <text>
  echo "ENDPOINT_REBIND: $1: $2"
}

note() {  # <id> <text>
  echo "BOOTSTRAP_INFO: $1: $2"
}

real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s' "$real"
  else
    printf '%s' "$path"
  fi
}

# live_path: the endpoint's live working directory, physically resolved, or
# empty when the backend answered nothing.
live_path() {  # <backend> <target> <label>
  local seen
  seen=$(fm_backend_current_path "$1" "$2" "$3" 2>/dev/null) || seen=
  seen=${seen%%$'\n'*}
  [ -n "$seen" ] || return 0
  real_path_or_raw "$seen"
}

# drift_detail: a short phrase naming WHERE a drifted endpoint ended up, read
# from the same isolation predicate the spawn-time assertion uses. An isolated
# worktree that is simply not this task's is still drift; the predicate's
# reason is what distinguishes the serious case (the primary checkout, or the
# project itself) from the merely wrong one.
drift_detail() {  # <live-path> <project>
  if fm_worktree_isolation_check "$1" "$2"; then
    printf 'an isolated worktree that is not this task'"'"'s'
  else
    printf '%s' "$FM_WORKTREE_ISOLATION_REASON"
  fi
}

# rebind: send the endpoint back to <worktree> and prove it arrived. Prints
# nothing; returns 0 only when the live path reads back as the worktree.
rebind() {  # <backend> <target> <label> <worktree> <worktree-real>
  local backend=$1 target=$2 label=$3 wt=$4 wt_real=$5 quoted verdict elapsed=0 seen
  quoted=${wt//\'/\'\\\'\'}
  verdict=$(fm_backend_send_text_submit \
    "$backend" "$target" "cd -- '$quoted'" "$EXIT_RETRIES" "$POLL" 1.2 "$label" 2>/dev/null) \
    || return 1
  [ "$verdict" != send-failed ] || return 1
  while :; do
    seen=$(live_path "$backend" "$target" "$label")
    [ "$seen" != "$wt_real" ] || return 0
    awk -v e="$elapsed" -v t="$WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  REBIND_LAST_SEEN=$seen
  return 1
}

# reconcile_one: the whole contract above, for exactly one task record.
reconcile_one() {  # <meta> <id>
  local meta=$1 id=$2 backend target label kind wt project wt_real seen state detail
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != secondmate ] || return 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0

  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    report "$id" "its durable record does not pass endpoint validation, so this cannot say which endpoint is the task's; reconcile $meta before any control action"
    return 0
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  label="fm-$id"

  fm_backend_current_path_is_live "$backend" || return 0
  fm_control_backend_state_verified "$backend" || return 0

  wt=$(fm_meta_get "$meta" worktree)
  project=$(fm_meta_get "$meta" project)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  wt_real=$(real_path_or_raw "$wt")

  # Existence first, and through the one read that never starts anything: a
  # herdr current-path read goes through the adapter's target-ready helper,
  # which ENSURES the recorded session's server. Asking it about a session
  # whose server is gone would stand a fresh empty one up at every session
  # start. An endpoint that is not there has no drift to reconcile anyway, and
  # absence belongs to the reclaim path rather than to this sweep.
  fm_backend_target_exists "$backend" "$target" "$label" || return 0

  seen=$(live_path "$backend" "$target" "$label")
  [ -n "$seen" ] || return 0
  [ "$seen" != "$wt_real" ] || return 0

  detail=$(drift_detail "$seen" "$project")
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  case "$state" in
    dead)
      REBIND_LAST_SEEN=$seen
      if rebind "$backend" "$target" "$label" "$wt" "$wt_real"; then
        note "$id" "its endpoint had been restored into '$seen' ($detail) and was returned to the task's local copy $wt"
      else
        report "$id" "its endpoint is in '${REBIND_LAST_SEEN:-$seen}' ($detail), not the task's local copy $wt, and could not be returned there; inspect the endpoint before any control action"
      fi
      ;;
    alive)
      report "$id" "a worker is running in '$seen' ($detail), not the task's local copy $wt, so it is outside the worktree-isolation contract; nothing was typed into it and nothing was signalled - stop it with bin/fm-control.sh $id exit, then re-run this reconciliation"
      ;;
    missing)
      # The endpoint answered an existence read and a path read a moment ago,
      # so `missing` here is a contradiction rather than plain absence. Absence
      # is still not this sweep's to declare.
      report "$id" "its endpoint answered from '$seen', not the task's local copy $wt, and then read 'missing'; those two reads contradict each other, and absence is owned by the reclaim path (bin/fm-control.sh $id relaunch) rather than by this reconciliation"
      ;;
    *)
      report "$id" "its endpoint is in '$seen' ($detail), not the task's local copy $wt, and reads '$state' rather than a positively classified state; nothing was changed"
      ;;
  esac
}

sweep() {
  local meta id
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_task_id_path_safe "$id" || continue
    reconcile_one "$meta" "$id"
  done
}

REBIND_LAST_SEEN=

case "${1:-}" in
  sweep)
    [ "$#" -eq 1 ] || { echo "error: 'sweep' takes no arguments" >&2; exit 1; }
    sweep
    ;;
  reconcile)
    [ "$#" -eq 2 ] || { echo "error: 'reconcile' takes exactly one task id" >&2; exit 1; }
    fm_task_id_path_safe "$2" || { echo "error: '$2' is not a valid task id" >&2; exit 1; }
    [ -f "$STATE/$2.meta" ] || { echo "error: no task '$2' in $STATE" >&2; exit 1; }
    reconcile_one "$STATE/$2.meta" "$2"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
exit 0
