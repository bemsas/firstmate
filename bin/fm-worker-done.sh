#!/usr/bin/env bash
# Process completion work for a successfully surfaced status snapshot.
# Usage: fm-worker-done.sh <task-id> <captured-byte-endpoint> <file-identity>
# Called detached by mark_surfaced in fm-push-transition-lib.sh for every harness
# and runtime. Only the last nonempty line of the captured snapshot may act.
# Scouts and ships capture lessons, including local-only ships with no PR URL.
# Only ships bind/check a canonical, unambiguous GitHub pull URL.
# Existing nonempty pr= metadata is preserved under the shared metadata lock.
# Capture uses the optional home-local data/secondbrain/tools/capture.py and its
# wiki/sources/source-task-<id>.md card or a successful capture receipt.
# FM_DONE_CHECK overrides config/done-check; on/shadow invoke the checker.
# Before evaluating a done line, atomically claim its byte endpoint in metadata
# as done_checked_at= with done_checked_ident= identifying the status file.
# Each event is attempted at most once, even after errors or mode changes;
# another done event can be checked again. Capture failures remain retryable.
# A per-task lock serializes claims, capture, and checks. Commands are bounded
# to 300 seconds each; the detached caller appends errors to worker-done.log.
# FM_HOME and FM_STATE/DATA/CONFIG_OVERRIDE select the owning home's paths.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

[ "$#" -eq 3 ] || exit 2
ID=$1 END=$2 IDENT=$3
fm_pr_task_id_valid "$ID" || exit 2
case "$END" in ''|*[!0-9]*) exit 2 ;; esac
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATUS="$STATE/$ID.status"
META="$STATE/$ID.meta"
RECEIPTS="$STATE/.worker-done-$ID"
LOCK="$STATE/.worker-done-$ID.lock"
META_LOCK=$(fm_meta_lock_path "$META") || exit 2

log_failure() { printf 'worker-done %s: %s\n' "$ID" "$*" >&2; }
snapshot_current() {
  [ -f "$STATUS" ] && [ ! -L "$STATUS" ] && [ -f "$META" ] && [ ! -L "$META" ] \
    && [ "$(_fm_open_decisions_file_ident "$STATUS")" = "$IDENT" ]
}
snapshot_current || exit 0
KIND=$(sed -n 's/^kind=//p' "$META")
case "$KIND" in ship|scout) ;; *) exit 0 ;; esac
fm_lock_acquire_wait_bounded "$LOCK" 5 || { log_failure 'task lock unavailable'; exit 1; }
trap 'fm_lock_release "$META_LOCK"; fm_lock_release "$LOCK"' EXIT
trap 'exit 143' HUP INT TERM
snapshot_current || exit 0
if [ -L "$RECEIPTS" ] || ! mkdir -p "$RECEIPTS"; then
  log_failure 'cannot create receipts'
  exit 1
fi
SNAPSHOT=$(_fm_status_read_span "$STATUS" 0 "$END") \
  || { log_failure 'cannot read captured status span'; exit 1; }
snapshot_current || exit 0
# Keep the event's endpoint independent of trailing blank status lines.
LINE_NUMBER=0
DONE_END=0
OFFSET=0
LAST_LINE=
export LC_ALL=C
while IFS= read -r line; do
  LINE_NUMBER=$((LINE_NUMBER + 1))
  OFFSET=$((OFFSET + ${#line} + 1))
  if [[ "$line" = *[![:space:]]* ]]; then
    LAST_LINE=$line
    DONE_END=$OFFSET
    DONE_LINE_NUMBER=$LINE_NUMBER
  fi
done <<< "$SNAPSHOT"
[ "$(status_line_verb "$LAST_LINE")" = 'done' ] || exit 0
LINE_NUMBER=$DONE_LINE_NUMBER

claim_done() {
  local checked ident tmp rc=0
  fm_lock_acquire_wait_bounded "$META_LOCK" 5 || return 1
  if snapshot_current; then
    checked=$(sed -n 's/^done_checked_at=//p' "$META")
    ident=$(sed -n 's/^done_checked_ident=//p' "$META")
    case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
    if [ "$ident" = "$IDENT" ] && [ "$checked" -ge "$DONE_END" ]; then
      rc=1
    else
      tmp=$(mktemp "$META.tmp.XXXXXX") || rc=1
      if [ "$rc" -eq 0 ]; then
        awk '!/^done_checked_(at|ident)=/ {print}' "$META" > "$tmp" \
          && printf 'done_checked_at=%s\ndone_checked_ident=%s\n' "$DONE_END" "$IDENT" >> "$tmp" \
          && mv -f "$tmp" "$META" || rc=1
        rm -f "$tmp"
      fi
    fi
  else
    rc=1
  fi
  fm_lock_release "$META_LOCK"
  return "$rc"
}

record_pr() {  # <url>
  local url=$1 line existing='' tmp rc=0
  fm_lock_acquire_wait_bounded "$META_LOCK" 5 || { log_failure 'metadata lock unavailable'; return 1; }
  if snapshot_current; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in pr=?*) existing=${line#pr=} ;; esac
    done < "$META"
    if [ -z "$existing" ]; then
      tmp=$(mktemp "$META.tmp.XXXXXX") || rc=1
      if [ "$rc" -eq 0 ]; then
        # Start the new field on its own line even after unterminated metadata.
        awk '!/^pr=$/ {print}' "$META" > "$tmp" \
          && printf 'pr=%s\n' "$url" >> "$tmp" \
          && mv -f "$tmp" "$META" || rc=1
        rm -f "$tmp"
      fi
    fi
  else
    rc=1
  fi
  fm_lock_release "$META_LOCK"
  [ "$rc" -eq 0 ] || log_failure 'cannot record PR metadata'
  return "$rc"
}

capture_lessons() {
  local card="$DATA/secondbrain/wiki/sources/source-task-$ID.md" rc=0
  [ -f "$DATA/$ID/lessons.md" ] || return 0
  [ ! -f "$card" ] || return 0
  [ "$(cat "$RECEIPTS/captured" 2>/dev/null)" != "$IDENT" ] || return 0
  fm_run_timed 300 python3 "$DATA/secondbrain/tools/capture.py" "$ID" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$IDENT" > "$RECEIPTS/captured" || log_failure 'cannot record capture receipt'
  else
    log_failure "capture failed (exit $rc)"
  fi
}

check_done() {  # <url>
  local url=$1 mode=${FM_DONE_CHECK-} line receipt rc=0
  local -a args=("$ID" "$url")
  if [ -z "$mode" ] && [ -f "$CONFIG/done-check" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      mode=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      break
    done < "$CONFIG/done-check"
  fi
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  case "$mode" in on|shadow) ;; *) return 0 ;; esac
  claim_done || return 0
  # Owner cannot contain --, so this delimiter is unambiguous with repo names.
  fm_pr_url_parse "$url" || return 1
  receipt="$RECEIPTS/$FM_PR_OWNER--$FM_PR_REPO--$FM_PR_NUMBER.$LINE_NUMBER.checked"
  [ "$(cat "$receipt" 2>/dev/null)" != "$IDENT $mode $url" ] || return 0
  [ "$(sed -n 's/^pr=//p' "$META")" != "$url" ] || args=(--auto "${args[@]}")
  fm_run_timed 300 bash "$SCRIPT_DIR/fm-done-check.sh" "${args[@]}" || rc=$?
  case "$rc" in
    0|10|11) printf '%s %s %s\n' "$IDENT" "$mode" "$url" > "$receipt" || log_failure 'cannot record checklist receipt'
             [ "$rc" -eq 0 ] || log_failure "checklist returned bounce/escalation (exit $rc)" ;;
    *) log_failure "done check failed (exit $rc)" ;;
  esac
}

# shellcheck disable=SC2016 # Backticks delimit Markdown code, never shell code.
URL_RE='(^|[[:space:]<(`])(https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*)([[:space:]>),.;`]|$)'
done_url() {  # <done-line>; refuse ambiguous PR ownership.
  local rest=$1 candidate
  URL=''
  while [[ "$rest" =~ $URL_RE ]]; do
    candidate=${BASH_REMATCH[2]}
    rest=${rest#*"$candidate"}
    fm_pr_url_parse "$candidate" || continue
    [ -z "$URL" ] || [ "$URL" = "$candidate" ] || return 1
    URL=$candidate
  done
  [ -n "$URL" ]
}
capture_lessons
[ "$KIND" = ship ] || exit 0
done_url "$LAST_LINE" || exit 0
record_pr "$URL" || exit 1
snapshot_current || exit 0
check_done "$URL"
