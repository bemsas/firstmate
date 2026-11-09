#!/usr/bin/env bash
# fm-hermes-daily-digest.sh - send one captain digest to Hermes profile ops.
#
# Delivery calls bin/fm-ask-hermes.sh --topic ops with a regular message
# file and a bounded timeout. It does not invoke Hermes by any other path.
# The exchange log is the private log owned by bin/fm-hermes-bridge-lib.sh.
# One Europe/London local date gets at most one successful send. A lock is
# held across the send. A date already marked delivered is reprinted and
# is not read or sent again. A failed send removes the in-flight claim,
# writes data/hermes-bridge/digest/<date>.failed, and stays retryable.
# A later launch that finds a successful ops log row for the in-flight
# correlation records delivery from that claim and does not send again.
#
# --format-only prints the digest and does not send.
# --now <epoch> fixes the instant. The default is the current time.
# FM_HOME must be an absolute directory. The source rules live in
# bin/fm-hermes-digest-lib.sh.
#
# Exit codes:
#   0    digest sent, or this London date was already sent
#   2    usage, a missing or bad source, or a stale snapshot
#   other  the ask script's status
#
# Usage:
#   fm-hermes-daily-digest.sh [--now <epoch>] [--timeout <1-600>] [--format-only]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-hermes-digest-lib.sh
. "$SCRIPT_DIR/fm-hermes-digest-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-hermes-bridge-lib.sh
. "$SCRIPT_DIR/fm-hermes-bridge-lib.sh"

umask 077

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-hermes-daily-digest.sh [--now <epoch>] [--timeout <1-600>] [--format-only]
EOF
  exit 2
}

help_text() {
  cat <<'EOF'
Send one captain digest to Hermes profile ops, or print it.

The source is captain-status.v1, resolved by bin/fm-hermes-digest-lib.sh.
--format-only prints the digest and does not call Hermes.
--now fixes the Unix instant used for the London date and the 24-hour merge window.
--timeout is the bound passed to fm-ask-hermes.sh, from 1 to 600 seconds.
A London date that already has a delivered marker is not sent again.
EOF
}

require_home() {
  local home=${FM_HOME:-}
  case "$home" in
    /*) ;;
    *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
  esac
  [ -d "$home" ] || { printf '%s\n' 'error: FM_HOME is not a directory' >&2; exit 2; }
}

validate_timeout() {
  case "$1" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) printf '%s\n' 'error: timeout must be a positive integer from 1 to 600' >&2; exit 2 ;;
  esac
  [ "$1" -le 600 ] || { printf '%s\n' 'error: timeout must be a positive integer from 1 to 600' >&2; exit 2; }
}

# shellcheck disable=SC2329 # EXIT trap invokes this after a source file is materialized.
cleanup_temp() {
  [ -z "${FM_HERMES_DIGEST_TEMP:-}" ] || rm -f "$FM_HERMES_DIGEST_TEMP"
}
trap cleanup_temp EXIT

prepare_source() {
  FM_HERMES_DIGEST_SPEC=$(fm_hermes_digest_source_spec || true)
  if [ -z "${FM_HERMES_DIGEST_SPEC}" ]; then
    FM_HERMES_DIGEST_SPEC=$(fm_hermes_digest_local_default || true)
  fi
  FM_HERMES_DIGEST_PATH=$(fm_hermes_digest_materialize "$FM_HERMES_DIGEST_SPEC") || return 2
  if [ "$FM_HERMES_DIGEST_PATH" != "$FM_HERMES_DIGEST_SPEC" ]; then
    FM_HERMES_DIGEST_TEMP=$FM_HERMES_DIGEST_PATH
  fi
}

now='' timeout=120 format_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) help_text; exit 0 ;;
    --now)
      [ "$#" -ge 2 ] || usage
      now=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage
      timeout=$2
      shift 2
      ;;
    --format-only) format_only=1; shift ;;
    *) usage ;;
  esac
done

require_home
validate_timeout "$timeout"
if [ -z "$now" ]; then
  now=$(date +%s)
fi
case "$now" in
  [0-9]*) ;;
  *) printf '%s\n' 'error: now must be a Unix epoch' >&2; exit 2 ;;
esac

london=$(fm_hermes_digest_london_date "$now") || {
  printf '%s\n' 'error: could not resolve the Europe/London date' >&2
  exit 2
}

if [ "$format_only" -eq 1 ]; then
  prepare_source || exit 2
  digest=$(fm_hermes_digest_format "$FM_HERMES_DIGEST_PATH" "$now") || exit 2
  printf '%s\n' "$digest"
  exit 0
fi

digest_dir=$FM_HOME/data/hermes-bridge/digest
mkdir -p "$digest_dir"
chmod 700 "$FM_HOME/data/hermes-bridge" "$digest_dir" || true
lock=$FM_HOME/data/hermes-bridge/digest.lock
delivered=$digest_dir/$london.delivered
failed=$digest_dir/$london.failed
sending=$digest_dir/$london.sending
text_path=$digest_dir/$london.text

# shellcheck disable=SC2329 # EXIT trap invokes this after the digest lock is held.
release_lock() {
  rm -rf "$lock"
}

lock_mtime() {  # <dir>
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0'
}

acquire_lock() {
  local i=0 pid now_s mtime
  while [ "$i" -lt 200 ]; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid"
      return 0
    fi
    sleep 0.1
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    case "$pid" in
      [0-9]*)
        if ! kill -0 "$pid" 2>/dev/null; then
          rm -rf "$lock"
        fi
        ;;
      *)
        now_s=$(date +%s)
        mtime=$(lock_mtime "$lock")
        if [ $((now_s - mtime)) -ge 30 ]; then
          rm -rf "$lock"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' 'error: digest lock was not acquired' >&2
  return 1
}

log_has_success() {  # <corr>
  local log=$FM_HOME/data/hermes-bridge/log.jsonl corr=$1
  [ -s "$log" ] || return 1
  jq -se --arg corr "$corr" '
    any(.[]; .correlation_id == $corr and .topic == "ops" and .direction == "outbound" and .outcome == "ok")
  ' "$log" >/dev/null 2>&1
}

print_saved() {
  local exchange corr
  exchange=$(sed -n 's/^exchange=//p' "$delivered" | head -n 1)
  corr=$(sed -n 's/^corr=//p' "$delivered" | head -n 1)
  printf 'date=%s\n' "$london"
  printf 'exchange=%s\n' "$exchange"
  printf 'corr=%s\n' "$corr"
  printf 'already-delivered\n'
  cat "$text_path"
}

mark_delivered() {  # <corr> <exchange> <text>
  local corr=$1 exchange=$2 body=$3 tmp
  tmp=$(mktemp "$digest_dir/.delivered.XXXXXX")
  printf 'date=%s\ncorr=%s\nexchange=%s\n' "$london" "$corr" "$exchange" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$delivered"
  tmp=$(mktemp "$digest_dir/.text.XXXXXX")
  printf '%s\n' "$body" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$text_path"
  rm -f "$sending" "$failed"
}

acquire_lock || exit 1
trap 'release_lock; cleanup_temp' EXIT

if [ -f "$delivered" ]; then
  if [ ! -f "$text_path" ]; then
    printf 'error: %s was delivered but the saved digest text is missing\n' "$london" >&2
    exit 2
  fi
  print_saved
  exit 0
fi

if [ -f "$sending" ]; then
  prior_corr=$(sed -n 's/^corr=//p' "$sending" | head -n 1)
  prior_text=$(awk 'found { print } /^---$/ { found=1 }' "$sending")
  if [ -n "$prior_corr" ] && log_has_success "$prior_corr"; then
    prior_exchange=$(jq -r --arg corr "$prior_corr" '
      select(.correlation_id == $corr and .topic == "ops" and .outcome == "ok") | .exchange_id
    ' "$FM_HOME/data/hermes-bridge/log.jsonl" | head -n 1)
    mark_delivered "$prior_corr" "$prior_exchange" "$prior_text"
    print_saved
    exit 0
  fi
fi

prepare_source || exit 2
digest=$(fm_hermes_digest_format "$FM_HERMES_DIGEST_PATH" "$now") || exit 2

corr=$(fm_hermes_bridge_new_id) || {
  printf '%s\n' 'error: could not generate a correlation id' >&2
  exit 1
}
{
  printf 'corr=%s\n' "$corr"
  printf '%s\n' '---'
  printf '%s\n' "$digest"
} > "$sending"
chmod 600 "$sending"
msg=$digest_dir/$london.msg
printf '%s\n' "$digest" > "$msg"
chmod 600 "$msg"

work=$(mktemp -d)
set +e
bash "$SCRIPT_DIR/fm-ask-hermes.sh" \
  --corr "$corr" \
  --topic ops \
  --timeout "$timeout" \
  --message-file "$msg" \
  >"$work/reply" 2>"$work/err"
rc=$?
set -e
exchange=$(sed -n 's/^exchange=//p' "$work/err" | head -n 1)
if [ "$rc" -eq 0 ]; then
  mark_delivered "$corr" "$exchange" "$digest"
  printf 'date=%s\n' "$london"
  printf 'exchange=%s\n' "$exchange"
  printf 'corr=%s\n' "$corr"
  printf '%s\n' "$digest"
  rm -rf "$work"
  exit 0
fi
{
  printf 'date=%s\n' "$london"
  printf 'corr=%s\n' "$corr"
  printf 'exit=%s\n' "$rc"
} > "$failed"
chmod 600 "$failed"
rm -f "$sending"
cat "$work/err" >&2 || true
rm -rf "$work"
exit "$rc"
