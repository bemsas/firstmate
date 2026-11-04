#!/usr/bin/env bash
# fm-ask-hermes.sh - ask the local Hermes CLI and relay the reply.
#
# Outbound runs the documented one-shot chat command and publishes the reply
# through the parent channel (bin/fm-parent-channel-lib.sh). Inbound validates
# a message and writes one parent-route steering record (bin/fm-task-inbox-lib.sh)
# with the from-firstmate marker and correlation token
# (bin/fm-pending-reply-lib.sh). The exchange log is bin/fm-hermes-bridge-lib.sh.
#
# Topic routing fails closed: admin selects profile desktop, ops selects
# profile ops, and trix selects profile trix. There is no default topic.
# The Hermes command is:
#   hermes --profile <profile> chat --oneshot --quiet --query-file <file>
#     --toolsets clarify --max-turns 2 --ignore-rules --source tool
# --toolsets clarify stays in force even when an approval pair is present.
# The approval pair records one named action and its statement in the request
# text. It does not add tools, and it is not a boolean.
# Top-level hermes -z is not used: that mode enables unattended tool execution.
# FM_ASK_HERMES_BIN, when set, is the executable used instead of hermes.
# The message is read from --message-file or stdin and is never evaluated.
#
# Exit codes:
#   0    reply published, or inbound record written
#   2    usage or validation
#   4    the provider replied and the parent channel append failed
#   124  the time bound was hit
#   other  the provider's own status
#
# Usage:
#   fm-ask-hermes.sh --corr <16-hex> --topic admin|ops|trix [--timeout <1-600>]
#       [--message-file <path>] [--approved-action <name> --approved-statement-file <path>]
#   fm-ask-hermes.sh --inbound --corr <16-hex> [--message-file <path>]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-hermes-bridge-lib.sh
. "$SCRIPT_DIR/fm-hermes-bridge-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

umask 077

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-ask-hermes.sh --corr <16-hex> --topic admin|ops|trix [--timeout <1-600>]
      [--message-file <path>] [--approved-action <name> --approved-statement-file <path>]
  fm-ask-hermes.sh --inbound --corr <16-hex> [--message-file <path>]
EOF
  exit 2
}

help_text() {
  cat <<'EOF'
Ask the local Hermes CLI, or relay one inbound message to this home.

--topic admin selects Hermes profile desktop.
--topic ops selects Hermes profile ops.
--topic trix selects Hermes profile trix.
Any other topic is refused.
The provider runs with toolset clarify, a query file, and a two-turn bound.
An approval pair is --approved-action plus --approved-statement-file.
The statement must name that action and must be more than a bare yes.
The pair is written into the request. The toolset stays clarify.
--inbound writes one parent-route steering record and does not call Hermes.
The message is read from --message-file or from stdin and is not evaluated.
Set FM_ASK_HERMES_BIN to replace the hermes executable.
EOF
}

read_body_or_die() {  # [path]
  local path=${1-} body rc=0
  body=$(fm_hermes_bridge_read_body "$path") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2) printf '%s\n' 'error: message file is not a regular file' >&2 ;;
      3) printf '%s\n' 'error: message exceeds the size bound' >&2 ;;
      4) printf '%s\n' 'error: message is empty' >&2 ;;
      5) printf '%s\n' 'error: message contains a NUL byte' >&2 ;;
      *) printf '%s\n' 'error: message could not be read' >&2 ;;
    esac
    exit 2
  fi
  case "${body//[[:space:]]/}" in
    '') printf '%s\n' 'error: message is empty' >&2; exit 2 ;;
  esac
  printf '%s' "$body"
}

approval_denied() {
  printf '%s\n' 'error: approval requires a named action and a statement that quotes that action' >&2
  exit 2
}

validate_approval() {  # <action> <statement>
  local action=$1 statement=$2 trimmed lower
  case "$action" in
    [A-Za-z0-9]*) ;;
    *) approval_denied ;;
  esac
  case "$action" in
    *[!A-Za-z0-9._:-]*) approval_denied ;;
  esac
  [ "${#action}" -le 64 ] || approval_denied
  lower=$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    approved|yes|true|ok|y|approve) approval_denied ;;
  esac
  trimmed=$(printf '%s' "$statement" | tr '\t\r\n' '   ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ "${#trimmed}" -ge 24 ] || approval_denied
  lower=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    approved|yes|true|ok|y|approve) approval_denied ;;
  esac
  case "$trimmed" in
    *"$action"*) ;;
    *) approval_denied ;;
  esac
  printf '%s' "$trimmed"
}

require_home() {
  local home=${FM_HOME:-}
  case "$home" in
    /*) ;;
    *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
  esac
  [ -d "$home" ] || { printf '%s\n' 'error: FM_HOME is not a directory' >&2; exit 2; }
  fm_parent_channel_home_id "$home" >/dev/null || {
    printf '%s\n' 'error: FM_HOME is not a usable secondmate home' >&2
    exit 2
  }
  fm_parent_channel_destination "$home" "$home/state" >/dev/null || {
    printf '%s\n' 'error: parent channel is not available from this home' >&2
    exit 2
  }
}

validate_timeout() {  # <seconds>
  case "$1" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) printf '%s\n' 'error: timeout must be a positive integer from 1 to 600' >&2; exit 2 ;;
  esac
  [ "$1" -le 600 ] || { printf '%s\n' 'error: timeout must be a positive integer from 1 to 600' >&2; exit 2; }
}

note_for() {  # <text>
  local text=$1 shown hex
  if fm_hermes_bridge_unsafe "$text"; then
    hex=$(fm_hermes_bridge_hash "$text") || hex=unhashed
    printf 'sha256:%s' "$hex"
    return 0
  fi
  shown=$(printf '%s' "$text" | head -c 500)
  fm_parent_channel_clean_note "$shown"
}

write_query() {  # <dest> <message> <action> <statement>
  local dest=$1 message=$2 action=$3 statement=$4
  {
    printf '%s\n' 'Local operations request.'
    if [ -n "$action" ]; then
      printf '%s\n' 'One named action is approved for this request only.'
      printf 'Approved action: %s\n' "$action"
      printf 'Approval statement: %s\n' "$statement"
      printf '%s\n' 'Do not take any other external action.'
    else
      printf '%s\n' 'Do not take any external action.'
    fi
    printf '%s\n' 'Do not post publicly, send email, direct-message anyone, place an order, or spend money.'
    printf '%s\n' 'Reply with the answer only.'
    printf '\n%s\n' 'Request:'
    printf '%s\n' "$message"
  } > "$dest"
}

load_inbound_owners() {
  if declare -F fm_task_inbox_write >/dev/null 2>&1 && declare -F fm_pending_reply_embed_corr >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
}

ring_parent_route() {  # <backend> <target> <record>
  local backend=$1 target=$2 rec=$3 pid killer=0
  case "$backend" in
    ''|*[!A-Za-z0-9_-]*) return 0 ;;
  esac
  case "$target" in
    ''|*[!A-Za-z0-9_.:-]*) return 0 ;;
  esac
  fm_task_inbox_ring "$backend" "$target" "$rec" >/dev/null 2>&1 &
  pid=$!
  (
    sleep 12
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  killer=$!
  wait "$pid" || true
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
}

do_inbound() {  # <corr> <message> <exchange>
  local corr=$1 message=$2 exchange=$3 home id meta backend='' window='' embedded rec rc=0 line
  home=$FM_HOME
  id=$(fm_parent_channel_home_id "$home") || exit 2
  load_inbound_owners
  fm_pending_reply_embed_corr "$message" "$corr" embedded || exit 1
  rec=$(fm_task_inbox_write "$home/state/parent-route" "$id" "$embedded") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$rec" ]; then
    fm_hermes_bridge_log_exchange hermes "$exchange" "$corr" '' '' inbound "inbox-failed" 1 "$message" '' '' || true
    printf '%s\n' 'error: parent-route record was not written' >&2
    exit 1
  fi
  meta="$home/state/parent-route/$id.meta"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        backend=*) backend=${line#backend=} ;;
        window=*) window=${line#window=} ;;
      esac
    done < "$meta"
    ring_parent_route "$backend" "$window" "$rec" || true
  fi
  fm_hermes_bridge_log_exchange hermes "$exchange" "$corr" '' '' inbound recorded 0 "$message" '' '' || {
    printf '%s\n' 'error: exchange log failed' >&2
    exit 1
  }
  printf 'exchange=%s\n' "$exchange" >&2
}

do_outbound() {  # <corr> <topic> <profile> <timeout> <message> <action> <statement> <exchange>
  local corr=$1 topic=$2 profile=$3 timeout=$4 message=$5 action=$6 statement=$7 exchange=$8
  local bin work rc=0 reply outcome line pub_rc=0 err_text
  if [ -n "${FM_ASK_HERMES_BIN:-}" ]; then
    bin=$FM_ASK_HERMES_BIN
  else
    bin=$(command -v hermes || true)
  fi
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    printf '%s\n' 'error: hermes is not executable' >&2
    exit 2
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-ask-hermes.XXXXXX") || exit 1
  # shellcheck disable=SC2064 # work is a fixed temp dir for this process
  trap "rm -rf -- $(printf '%q' "$work")" EXIT
  write_query "$work/query" "$message" "$action" "$statement"
  set +e
  (
    cd "$work" || exit 1
    fm_run_timed "$timeout" "$bin" \
      --profile "$profile" \
      chat \
      --oneshot \
      --quiet \
      --query-file "$work/query" \
      --toolsets clarify \
      --max-turns 2 \
      --ignore-rules \
      --source tool
  ) >"$work/reply" 2>"$work/err"
  rc=$?
  set -e
  reply=$(cat "$work/reply" 2>/dev/null || true)
  if fm_timed_out "$rc"; then
    outcome=timeout
    rc=124
  elif [ "$rc" -eq 0 ] && [ ! -s "$work/reply" ]; then
    outcome=empty
    rc=1
  elif [ "$rc" -ne 0 ]; then
    outcome="provider-failed"
  else
    outcome=ok
  fi
  if [ -s "$work/err" ]; then
    # Quiet mode can still print a session trailer. Keep it out of the caller output.
    err_text=$(grep -v '^session_id:' "$work/err" | grep -v '^[[:space:]]*$' || true)
    if [ -n "$err_text" ]; then
      if fm_hermes_bridge_unsafe "$err_text"; then
        printf '%s\n' 'provider error withheld' >&2
      else
        printf '%s\n' "$err_text" >&2
      fi
    fi
  fi
  if [ "$outcome" = ok ]; then
    line=$(printf 'done [corr=%s]: hermes topic=%s profile=%s exchange=%s %s' \
      "$corr" "$topic" "$profile" "$exchange" "$(note_for "$reply")")
    pub_rc=0
    fm_parent_channel_report "$FM_HOME" "$FM_HOME/state" "$line" || pub_rc=$?
    if [ "$pub_rc" -ne 0 ]; then
      outcome="reply-undelivered"
      rc=4
    fi
    cat "$work/reply"
  else
    line=$(printf 'failed [corr=%s]: hermes topic=%s profile=%s exchange=%s outcome=%s exit=%s' \
      "$corr" "$topic" "$profile" "$exchange" "$outcome" "$rc")
    fm_parent_channel_report "$FM_HOME" "$FM_HOME/state" "$line" || true
  fi
  fm_hermes_bridge_log_exchange hermes "$exchange" "$corr" "$topic" "$profile" outbound "$outcome" "$rc" "$message" "$reply" '' || {
    printf '%s\n' 'error: exchange log failed' >&2
    exit 1
  }
  printf 'exchange=%s\n' "$exchange" >&2
  exit "$rc"
}

corr='' topic='' inbound=0 timeout=120 action='' statement_file='' message_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) help_text; exit 0 ;;
    --corr)
      [ "$#" -ge 2 ] || usage
      corr=$2
      shift 2
      ;;
    --topic)
      [ "$#" -ge 2 ] || usage
      topic=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage
      timeout=$2
      shift 2
      ;;
    --message-file)
      [ "$#" -ge 2 ] || usage
      message_file=$2
      shift 2
      ;;
    --approved-action)
      [ "$#" -ge 2 ] || usage
      action=$2
      shift 2
      ;;
    --approved-statement-file)
      [ "$#" -ge 2 ] || usage
      statement_file=$2
      shift 2
      ;;
    --inbound) inbound=1; shift ;;
    *) usage ;;
  esac
done

fm_hermes_bridge_corr_ok "$corr" || { printf '%s\n' 'error: corr must be 16 hex characters' >&2; exit 2; }
corr=$(printf '%s' "$corr" | tr 'A-F' 'a-f')
require_home
validate_timeout "$timeout"

if [ "$inbound" -eq 1 ]; then
  [ -z "$topic" ] || usage
  [ -z "$action" ] && [ -z "$statement_file" ] || usage
else
  [ -n "$topic" ] || usage
fi

if [ -n "$action" ] || [ -n "$statement_file" ]; then
  [ -n "$action" ] && [ -n "$statement_file" ] || approval_denied
fi

message=$(read_body_or_die "$message_file")
statement=''
if [ -n "$action" ]; then
  statement=$(read_body_or_die "$statement_file")
  statement=$(validate_approval "$action" "$statement")
fi

exchange=$(fm_hermes_bridge_new_id) || { printf '%s\n' 'error: could not generate an exchange id' >&2; exit 1; }

if [ "$inbound" -eq 1 ]; then
  do_inbound "$corr" "$message" "$exchange"
  exit 0
fi

profile=$(fm_hermes_bridge_profile_for_topic "$topic") || {
  printf '%s\n' 'error: topic must be admin, ops, or trix' >&2
  exit 2
}
do_outbound "$corr" "$topic" "$profile" "$timeout" "$message" "$action" "$statement" "$exchange"
