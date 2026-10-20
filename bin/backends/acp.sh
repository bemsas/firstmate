#!/usr/bin/env bash
# bin/backends/acp.sh - the ACP harness adapter (PILOT, scouts only).
#
# Unlike the pane-based backends, an acp task has no terminal: bin/fm-acp-harness.py
# owns the agent as a child process over the Agent Client Protocol (v1) and keeps
# its state under state/<id>.acp.json. The recorded endpoint is `acp:<task-id>`.
# Every operation here is a thin call into that script; its header owns the
# command surface, docs/acp-backend.md owns the operator view and the pilot limits.
# Sourced only through bin/fm-backend.sh's fm_backend_source.

fm_backend_acp_harness() {  # <harness-args...>
  FM_HOME="$FM_HOME" python3 "${FM_ACP_HARNESS:-$FM_BACKEND_LIB_DIR/fm-acp-harness.py}" "$@"
}

fm_backend_acp_task_id() {  # <target> -> task id
  case "${1:-}" in
    acp:?*) printf '%s' "${1#acp:}" ;;
    *) return 1 ;;
  esac
}

# Readable view of the event log, newest <lines> events.
fm_backend_acp_capture() {  # <target> <lines>
  local id
  id=$(fm_backend_acp_task_id "$1") || return 1
  fm_backend_acp_harness tail "$id" -n "${2:-40}"
}

# A steer is a durable inbox record plus a doorbell line, exactly as on a pane;
# here the doorbell is a session/prompt. `empty` is the proof-carrying verdict
# fm-send.sh requires for a confirmed delivery.
fm_backend_acp_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local id
  id=$(fm_backend_acp_task_id "$1") || return 1
  fm_backend_acp_harness steer "$id" "$2" >/dev/null || return 1
  printf 'empty'
}

fm_backend_acp_send_key() {  # <target> <key>
  echo "error: backend 'acp' has no terminal keys; use fm-acp-harness.py cancel or stop" >&2
  return 1
}

# stop is idempotent: an already-exited or never-started harness is a clean close.
fm_backend_acp_kill() {  # <target>
  local id
  id=$(fm_backend_acp_task_id "$1") || return 1
  fm_backend_acp_harness stop "$id"
}

fm_backend_acp_target_exists() {  # <target>
  local id
  id=$(fm_backend_acp_task_id "$1") || return 1
  case "$(fm_backend_acp_harness state "$id" 2>/dev/null)" in
    running | idle | blocked | starting) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_acp_busy_state() {  # <target>
  local id
  id=$(fm_backend_acp_task_id "$1") || { printf 'unknown'; return 0; }
  case "$(fm_backend_acp_harness state "$id" 2>/dev/null)" in
    running) printf 'busy' ;;
    idle | blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# The harness owns the pid and proves liveness with the /proc start time, so its
# verdict is a process fact. `missing` only when no state exists at all.
fm_backend_acp_agent_state() {  # <target>
  local id
  id=$(fm_backend_acp_task_id "$1") || { printf 'unreadable'; return 0; }
  case "$(fm_backend_acp_harness state "$id" 2>/dev/null)" in
    running | idle | blocked) printf 'alive' ;;
    exited | dead) printf 'dead' ;;
    missing) printf 'missing' ;;
    *) printf 'unreadable' ;;
  esac
}
