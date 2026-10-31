#!/usr/bin/env bash
# fm-wait-evidence-lib.sh - structured wait reason, owner, and clearing action.
#
# Each wait kind carries its dependency owner and the action that clears it as
# data, not as prose chosen at each recheck site. The US-delimited wait_record
# format is owned here; bin/fm-watch.sh wedge deferral and bin/fm-crew-state.sh
# presentation consume it.
#
# Usage (sourced):
#   wait_record <kind> <subject> <whom> <action> <age-anchor-path>
#   task_wait_evidence <task>              -> one wait_record or exit 1
#   task_wait_evidence_status <task>       -> status/backlog only (no crew-state)
#   wait_record_format_suffix <record>     -> " · wait-owner: … · …" or empty
set -u

FM_WAIT_EVIDENCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAIT_EVIDENCE_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_WAIT_EVIDENCE_LIB_DIR/.." && pwd)}}"
FM_WAIT_EVIDENCE_STATE="${FM_STATE_OVERRIDE:-$FM_WAIT_EVIDENCE_HOME/state}"
FM_WAIT_EVIDENCE_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_WAIT_EVIDENCE_HOME/config}"

# shellcheck source=bin/fm-classify-lib.sh
. "$FM_WAIT_EVIDENCE_LIB_DIR/fm-classify-lib.sh"

WAIT_EVIDENCE_BACKLOG_HOLD_KIND='captain hold'
WAIT_EVIDENCE_US=$'\037'

wait_record() {  # <kind> <subject> <whom> <action> <age-record>
  printf '%s\037%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" "$5"
}

task_wait_evidence_open_call() {  # <task> -> sets TASK_WAIT_CALL_IDENTITY, 0/1
  local task=$1
  TASK_WAIT_CALL_IDENTITY=
  [ -n "$task" ] || return 1
  TASK_WAIT_CALL_IDENTITY=$(FM_HOME="$FM_WAIT_EVIDENCE_HOME" \
    "$FM_WAIT_EVIDENCE_LIB_DIR/fm-captain-hold.sh" open "$task" --identity 2>/dev/null) || return 1
  return 0
}

task_wait_evidence_status() {  # <task> -> one wait_record on stdout
  local task=$1 last until statusf verb
  [ -n "$task" ] || return 1
  statusf="$FM_WAIT_EVIDENCE_STATE/$task.status"
  last=$(status_declared_wait_line "$statusf")
  if status_is_captain_held "$last"; then
    wait_record 'captain-held' 'awaiting the captain - verified hold transfer' \
      captain 'answer the held decision or release the hold' "$statusf"
    return 0
  fi
  if status_is_paused "$last" \
    && { ! until=$(status_paused_until "$last") || [ "$(date +%s)" -lt "$until" ]; }; then
    wait_record 'declared wait' 'awaiting external' \
      external 'confirm the wait still holds' "$statusf"
    return 0
  fi
  if task_wait_evidence_open_call "$task"; then
    wait_record "$WAIT_EVIDENCE_BACKLOG_HOLD_KIND" 'awaiting the captain - held in the backlog' \
      captain 'answer the held decision or release the hold' ''
    return 0
  fi
  if [ -e "$FM_WAIT_EVIDENCE_CONFIG/wedge-defer-worker-wait" ] && verb=$(status_worker_wait_verb "$statusf"); then
    if [ "$verb" = blocked ]; then
      wait_record 'declared blocker' 'awaiting firstmate - its own newest line reports a blocker' \
        supervisor 'clear the reported blocker and close it with fm-send --resolve-key' "$statusf"
    else
      wait_record 'declared decision' 'awaiting firstmate - its own newest line asks for a decision' \
        supervisor 'answer the reported decision with fm-send --resolve-key' "$statusf"
    fi
    return 0
  fi
  return 1
}

task_wait_evidence() {  # <task> -> one wait_record on stdout
  local task=$1 statusf run
  task_wait_evidence_status "$task" && return 0
  [ -e "$FM_WAIT_EVIDENCE_CONFIG/wedge-defer-parked-gate" ] || return 1
  statusf="$FM_WAIT_EVIDENCE_STATE/$task.status"
  if status_has_open_needs_decision "$statusf" \
    && run=$(crew_gate_awaits_human_decision "$task") \
    && status_has_open_needs_decision "$statusf" "$run"; then
    wait_record 'verified wait at a parked gate' "awaiting firstmate's ask-user decision" \
      supervisor "decide the gate's ask-user finding and relay the decision to the crewmate" ''
    return 0
  fi
  return 1
}

wait_record_parse() {  # <record> -> sets WAIT_REC_* ; returns 0 when valid
  local record=$1 ok=1
  WAIT_REC_KIND=; WAIT_REC_SUBJECT=; WAIT_REC_WHOM=; WAIT_REC_ACTION=; WAIT_REC_ANCHOR=
  IFS=$WAIT_EVIDENCE_US read -r WAIT_REC_KIND WAIT_REC_SUBJECT WAIT_REC_WHOM WAIT_REC_ACTION WAIT_REC_ANCHOR <<EOF
$record
EOF
  case "$WAIT_REC_WHOM" in
    captain|supervisor|external) ;;
    *) ok=0 ;;
  esac
  case "$WAIT_REC_ANCHOR" in
    *"$WAIT_EVIDENCE_US"*) ok=0 ;;
  esac
  if [ -z "$WAIT_REC_KIND" ] || [ -z "$WAIT_REC_SUBJECT" ] || [ -z "$WAIT_REC_ACTION" ]; then ok=0; fi
  [ "$ok" -eq 1 ]
}

wait_owner_label() {  # <whom>
  case "$1" in
    captain) printf 'captain' ;;
    supervisor) printf 'supervisor' ;;
    external) printf 'external' ;;
    *) printf '%s' "$1" ;;
  esac
}

wait_record_format_suffix() {  # <record>
  wait_record_parse "$1" || return 1
  printf ' · wait-owner: %s · wait-reason: %s · wait-action: %s' \
    "$(wait_owner_label "$WAIT_REC_WHOM")" "$WAIT_REC_SUBJECT" "$WAIT_REC_ACTION"
}
