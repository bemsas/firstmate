#!/usr/bin/env bash
# fm-ask-grokbot.sh - record that Grok Bot has no supported message path.
#
# Grok Bot has no documented non-interactive message/reply CLI or local API
# that returns a bounded reply. This script reads only the app Info.plist
# version, when that plist is present, and appends one unsupported row to the
# exchange log owned by bin/fm-hermes-bridge-lib.sh.
# It does not launch the app, invoke grok or grokbot, write the parent channel,
# or write the parent-route inbox. No flag turns that into a send.
# The message is read from --message-file or stdin and is never evaluated.
#
# Exit codes:
#   2  usage or validation
#   3  the supported message/reply surface is missing
#
# Usage:
#   fm-ask-grokbot.sh --corr <16-hex> [--topic admin|ops] [--timeout <1-600>]
#       [--message-file <path>] [--inbound]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-hermes-bridge-lib.sh
. "$SCRIPT_DIR/fm-hermes-bridge-lib.sh"

umask 077

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-ask-grokbot.sh --corr <16-hex> [--topic admin|ops] [--timeout <1-600>]
      [--message-file <path>] [--inbound]
EOF
  exit 2
}

help_text() {
  cat <<'EOF'
Record a Grok Bot exchange that cannot be sent.

Grok Bot has no documented non-interactive message/reply CLI or local API.
This command does not launch the app and does not publish a reply.
A version string is read from the app Info.plist when that file is present.
The message is read from --message-file or from stdin and is not evaluated.
--topic admin and --topic ops are accepted and only recorded.
--inbound is accepted and still writes no steering record.
The exit status is 3 when the arguments are valid.
EOF
}

grokbot_version() {
  local plist='/Applications/Grok Bot.app/Contents/Info.plist' ver=''
  if [ -f "$plist" ] && [ ! -L "$plist" ] && command -v plutil >/dev/null 2>&1; then
    ver=$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)
  fi
  case "$ver" in
    [0-9]*) ;;
    *) ver=unknown ;;
  esac
  case "$ver" in
    unknown|[0-9A-Za-z._+-]*) ;;
    *) ver=unknown ;;
  esac
  printf '%s' "$ver"
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

require_home() {
  local home=${FM_HOME:-}
  case "$home" in
    /*) ;;
    *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
  esac
  [ -d "$home" ] || { printf '%s\n' 'error: FM_HOME is not a directory' >&2; exit 2; }
}

validate_timeout() {  # <seconds>
  case "$1" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) printf '%s\n' 'error: timeout must be a positive integer from 1 to 600' >&2; exit 2 ;;
  esac
  [ "$1" -le 600 ] || { printf '%s\n' 'error: timeout must be a positive integer from 1 to 600' >&2; exit 2; }
}

corr='' topic='' inbound=0 timeout=120 message_file=''
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
    --inbound) inbound=1; shift ;;
    *) usage ;;
  esac
done

fm_hermes_bridge_corr_ok "$corr" || { printf '%s\n' 'error: corr must be 16 hex characters' >&2; exit 2; }
corr=$(printf '%s' "$corr" | tr 'A-F' 'a-f')
require_home
validate_timeout "$timeout"
if [ -n "$topic" ]; then
  # Grok Bot records admin and ops only. Hermes profile trix is not a Grok Bot topic.
  case "$topic" in
    admin|ops) ;;
    *)
      printf '%s\n' 'error: topic must be admin or ops' >&2
      exit 2
      ;;
  esac
fi
# Accepted and unused: there is no provider process to bound.
: "$timeout"

message=$(read_body_or_die "$message_file")
direction=outbound
if [ "$inbound" -eq 1 ]; then
  direction=inbound
fi
version=$(grokbot_version)
exchange=$(fm_hermes_bridge_new_id) || { printf '%s\n' 'error: could not generate an exchange id' >&2; exit 1; }
fm_hermes_bridge_log_exchange grokbot "$exchange" "$corr" "$topic" '' "$direction" unsupported 3 "$message" '' "$version" || {
  printf '%s\n' 'error: exchange log failed' >&2
  exit 1
}
printf 'Grok Bot %s has no documented non-interactive message/reply surface\n' "$version" >&2
printf 'exchange=%s\n' "$exchange" >&2
exit 3
