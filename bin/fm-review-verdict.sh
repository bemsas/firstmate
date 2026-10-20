#!/usr/bin/env bash
# Record a second-model review for one exact GitHub pull request head.
# Usage: fm-review-verdict.sh <pr-url> <40-hex-head> merge|fix [reviewer]
# The reviewer/supervisor calls this after the independent review; this helper
# records the verdict, it does not perform or infer a review. No forge calls.
# Firstmate runs this when accepting the report, with its exact reviewed head;
# optional reviewer identifies the independent reviewer in the audit record.
# Appends a private JSON object {pr,head,verdict,reviewer} to state/review-verdicts.jsonl
# under a lock shared by writers. The latest valid record for that PR and head
# wins; another head's record never authorizes a merge. FM_HOME (or
# FM_ROOT_OVERRIDE) and FM_STATE_OVERRIDE select the home/state as usual.
# Exit: 0 recorded, 1 write/lock failure, 2 invalid arguments.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
usage() { echo 'usage: fm-review-verdict.sh <pr-url> <40-hex-head> merge|fix [reviewer]'; }
if [ "${1:-}" = --help ]; then usage; exit 0; fi
if { [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; } || ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != github ] \
  || ! fm_pr_head_valid "$2"; then
  usage >&2
  exit 2
fi
case "$3" in merge|fix) ;; *) echo 'error: verdict must be merge or fix' >&2; exit 2 ;; esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
FILE="$STATE/review-verdicts.jsonl"
LOCK="$STATE/.review-verdicts.lock"
fm_lock_acquire_wait "$LOCK" || exit 1
trap 'fm_lock_release "$LOCK"' EXIT
DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_regular_destination_on_device_or_absent "$FILE" "$DEVICE" || exit 1
ROW=$(jq -nc --arg pr "$FM_PR_URL" --arg head "$2" --arg verdict "$3" --arg reviewer "${4:-}" \
  '{pr:$pr,head:$head,verdict:$verdict,reviewer:$reviewer}')
(umask 077; printf '%s\n' "$ROW" >> "$FILE")
