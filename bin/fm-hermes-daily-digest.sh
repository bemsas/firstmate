#!/usr/bin/env bash
# fm-hermes-daily-digest.sh - post one captain digest to the Hermes ops topic.
#
# Delivery runs the Hermes CLI's deterministic send, with no model and no
# agent loop:
#   hermes --profile ops send --to <target> --file <date>.msg --json
# The profile is the ops topic's profile from bin/fm-hermes-bridge-lib.sh.
# The target is config/hermes-digest-target, owned by
# bin/fm-hermes-digest-lib.sh. A missing or malformed target is refused and
# nothing is sent anywhere. FM_HERMES_DIGEST_BIN, when set, replaces hermes;
# otherwise hermes resolves on PATH, which bin/fm-hermes-schedule.sh pins.
# Delivery counts only when send exits 0 and its JSON result says success
# and not skipped.
#
# Every run that formats a digest archives it first as
# data/hermes-bridge/digest/<date>.msg, and a refused or failed send keeps
# that archive. One Europe/London local date gets at most one successful
# send. A lock is held across the send, and <date>.sending claims the date
# while it runs. A date already marked delivered is reprinted and is not
# read or sent again. A send that Hermes reports failed removes the claim,
# writes <date>.failed, and stays retryable. A send whose outcome is
# unknown (time bound, signal, or an unreadable result) keeps the claim,
# and later runs for that date refuse until the operator checks the ops
# topic and removes <date>.sending. Each send attempt appends one row,
# target hermes-send, to the exchange log owned by
# bin/fm-hermes-bridge-lib.sh. No output names the target.
#
# --format-only prints the digest and does not send.
# --now <epoch> fixes the instant. The default is the current time.
# FM_HOME must be an absolute directory. The source rules live in
# bin/fm-hermes-digest-lib.sh.
#
# Exit codes:
#   0    digest sent, or this London date was already sent
#   1    Hermes reported the send failed or skipped it
#   2    usage, a missing or bad source or target, a stale snapshot, or no hermes
#   3    this or an earlier send for this date has an unknown outcome
#   124  the time bound was hit; the outcome is unknown
#   other  Hermes ended on a signal; the outcome is unknown
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
Post one captain digest to the Hermes ops topic, or print it.

The source is captain-status.v1, resolved by bin/fm-hermes-digest-lib.sh.
The target is config/hermes-digest-target, platform:chat_id[:thread_id].
Delivery is hermes --profile ops send --to <target> --file <digest> --json.
A missing or malformed target is refused and nothing is sent.
--format-only prints the digest and does not call Hermes.
--now fixes the Unix instant used for the London date and the 24-hour merge window.
--timeout bounds the send, from 1 to 600 seconds.
A London date that already has a delivered marker is not sent again.
A date whose earlier send has an unknown outcome is refused until its
<date>.sending claim is removed.
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
  [ -z "${work:-}" ] || rm -rf "$work"
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

now='' timeout=120 format_only=0 work=''
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
msg=$digest_dir/$london.msg
result=$digest_dir/$london.send.json
profile=$(fm_hermes_bridge_profile_for_topic ops)

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

write_private() {  # <dest> <text>
  local tmp
  tmp=$(mktemp "$digest_dir/.write.XXXXXX")
  printf '%s\n' "$2" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$1"
}

print_saved() {
  local corr
  corr=$(sed -n 's/^corr=//p' "$delivered" | head -n 1)
  printf 'date=%s\n' "$london"
  printf 'corr=%s\n' "$corr"
  printf 'via=hermes-send\n'
  printf 'already-delivered\n'
  cat "$text_path"
}

mark_delivered() {  # <corr> <text>
  write_private "$delivered" "$(printf 'date=%s\ncorr=%s\nvia=hermes-send\nprofile=%s' "$london" "$1" "$profile")"
  write_private "$text_path" "$2"
  rm -f "$sending" "$failed"
}

record_failed() {  # <exit> <outcome> [corr]
  local body
  body=$(printf 'date=%s\n' "$london")
  [ -z "${3:-}" ] || body=$(printf '%s\ncorr=%s' "$body" "$3")
  body=$(printf '%s\nexit=%s\noutcome=%s' "$body" "$1" "$2")
  write_private "$failed" "$body"
}

log_send() {  # <corr> <outcome> <exit>
  fm_hermes_bridge_log_exchange hermes-send "$1" "$1" ops "$profile" outbound "$2" "$3" "$digest" '' '' || true
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

if [ -e "$sending" ]; then
  printf 'error: an earlier send for %s has an unknown outcome; check the ops topic, then remove %s to send again\n' \
    "$london" "$sending" >&2
  exit 3
fi

prepare_source || exit 2
digest=$(fm_hermes_digest_format "$FM_HERMES_DIGEST_PATH" "$now") || exit 2
write_private "$msg" "$digest"

target=$(fm_hermes_digest_target) || { record_failed 2 refused-target; exit 2; }
hermes_path=$(command -v "${FM_HERMES_DIGEST_BIN:-hermes}" 2>/dev/null || true)
case "$hermes_path" in
  /*) [ -x "$hermes_path" ] || hermes_path='' ;;
  *) hermes_path='' ;;
esac
if [ -z "$hermes_path" ]; then
  printf '%s\n' 'error: hermes is not on PATH; nothing was sent' >&2
  record_failed 2 refused-no-hermes
  exit 2
fi

corr=$(fm_hermes_bridge_new_id) || {
  printf '%s\n' 'error: could not generate a correlation id' >&2
  exit 1
}
write_private "$sending" "corr=$corr"

work=$(mktemp -d)
set +e
fm_run_timed "$timeout" "$hermes_path" --profile "$profile" send --to "$target" --file "$msg" --json \
  </dev/null >"$work/out" 2>"$work/err"
rc=$?
set -e
cp "$work/out" "$result" 2>/dev/null || true
chmod 600 "$result" 2>/dev/null || true
verdict=unknown
if jq -e 'type == "object"' "$work/out" >/dev/null 2>&1; then
  if jq -e '.success == true and (.skipped // false) != true and (.error // null) == null' "$work/out" >/dev/null 2>&1; then
    verdict=sent
  else
    verdict=refused
  fi
fi

if [ "$rc" -eq 0 ] && [ "$verdict" = sent ]; then
  log_send "$corr" sent 0
  mark_delivered "$corr" "$digest"
  printf 'date=%s\n' "$london"
  printf 'corr=%s\n' "$corr"
  printf 'via=hermes-send\n'
  printf '%s\n' "$digest"
  exit 0
fi

if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ] || { [ "$rc" -eq 0 ] && [ "$verdict" = refused ]; }; then
  log_send "$corr" failed "$rc"
  record_failed "$rc" failed "$corr"
  rm -f "$sending"
  printf 'error: hermes send did not deliver the digest for %s (exit %s); the archive is %s\n' \
    "$london" "$rc" "$msg" >&2
  exit 1
fi

log_send "$corr" unconfirmed "$rc"
record_failed "$rc" unconfirmed "$corr"
printf 'error: the send for %s has an unknown outcome (exit %s); check the ops topic before removing %s\n' \
  "$london" "$rc" "$sending" >&2
[ "$rc" -ne 0 ] || exit 3
exit "$rc"
