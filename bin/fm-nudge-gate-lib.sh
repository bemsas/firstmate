#!/usr/bin/env bash
# fm-nudge-gate-lib.sh - the ONE owner of the pane-nudge gate: completion-seq
# idempotency (last_nudged_seq) and the human-focus cooldown.
#
# Sourced, never executed; set -u safe; no side effects on source.
#
# Inputs come from the backend's turn projection: on Herdr,
# fm_backend_herdr_turn_projection prints
#   agent_status=<status> completion_seq=<uint|-> focused=<true|false>
# where completion_seq is Herdr's AgentInfo.completion_seq (it advances each
# time the agent completes work, whoever has viewed it) and focused is whether
# a client has that pane focused. Other backends have no projection, and the
# gate is never consulted for them.
#
# Record: state/<id>.nudge-gate, one line, atomically replaced:
#   v1 last_nudged_seq=<uint|-> last_focused_at=<epoch>
#
# fm_nudge_gate_decide <state> <id> <completion_seq|-> <focused> [now] [mode]
#   Prints `allow` or `hold <reason>`, and records last_focused_at=now whenever
#   focused is true, so a pane a human just left stays held for the cooldown.
#   Hold reasons, in order:
#     human-focused     a client has the pane focused now
#     focus-cooldown    it was seen focused under FM_NUDGE_FOCUS_COOLDOWN_SECS
#                       (default 120) ago
#     unchanged-seq     mode seq only: completion_seq is a number equal to
#                       last_nudged_seq, so the pane has completed no work
#                       since the last nudge (one nudge per completed turn)
#   Mode focus (the default) applies only the two focus rules. A caller that
#   re-delivers a lost message must use focus mode: an idle worker whose first
#   delivery was lost has an unchanged completion_seq, and holding it on that
#   rule would block the recovery.
# fm_nudge_gate_record <state> <id> <completion_seq|-> [now]
#   Records that a nudge was actually sent for that completion_seq.
# A missing or malformed record reads as never nudged and never focused.

FM_NUDGE_FOCUS_COOLDOWN_SECS=${FM_NUDGE_FOCUS_COOLDOWN_SECS:-120}

fm_nudge_gate_path() {  # <state> <id>
  printf '%s/%s.nudge-gate' "$1" "$2"
}

fm_nudge_gate_read() {  # <state> <id> -> "<last_nudged_seq> <last_focused_at>"
  local line seq='-' focused=0
  line=$(head -1 "$(fm_nudge_gate_path "$1" "$2")" 2>/dev/null) || line=
  case "$line" in
    'v1 last_nudged_seq='*' last_focused_at='*)
      seq=${line#v1 last_nudged_seq=}
      seq=${seq%% *}
      focused=${line##*last_focused_at=}
      ;;
  esac
  case "$seq" in -|'') seq='-' ;; *[!0-9]*) seq='-' ;; esac
  case "$focused" in ''|*[!0-9]*) focused=0 ;; esac
  printf '%s %s' "$seq" "$focused"
}

fm_nudge_gate_write() {  # <state> <id> <seq> <focused_at>
  local path tmp
  path=$(fm_nudge_gate_path "$1" "$2")
  tmp="$path.tmp.$$"
  printf 'v1 last_nudged_seq=%s last_focused_at=%s\n' "$3" "$4" > "$tmp" && mv -f "$tmp" "$path"
}

fm_nudge_gate_decide() {  # <state> <id> <completion_seq|-> <focused> [now] [mode]
  local state=$1 id=$2 seq=${3:--} focused=${4:-false} now=${5:-} mode=${6:-focus} rec last_seq last_focus
  [ -n "$now" ] || now=$(date +%s)
  rec=$(fm_nudge_gate_read "$state" "$id")
  last_seq=${rec% *}
  last_focus=${rec#* }
  if [ "$focused" = true ]; then
    fm_nudge_gate_write "$state" "$id" "$last_seq" "$now" || true
    printf 'hold human-focused'
    return 0
  fi
  if [ "$last_focus" -gt 0 ] && [ $((now - last_focus)) -lt "$FM_NUDGE_FOCUS_COOLDOWN_SECS" ]; then
    printf 'hold focus-cooldown'
    return 0
  fi
  if [ "$mode" = seq ]; then
    case "$seq" in
      ''|-|*[!0-9]*) ;;
      *)
        if [ "$seq" = "$last_seq" ]; then
          printf 'hold unchanged-seq'
          return 0
        fi
        ;;
    esac
  fi
  printf 'allow'
}

fm_nudge_gate_record() {  # <state> <id> <completion_seq|-> [now]
  local rec seq=${3:--}
  case "$seq" in ''|*[!0-9-]*) seq='-' ;; esac
  rec=$(fm_nudge_gate_read "$1" "$2")
  fm_nudge_gate_write "$1" "$2" "$seq" "${rec#* }"
}
