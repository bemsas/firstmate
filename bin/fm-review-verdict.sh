#!/usr/bin/env bash
# Record a second-model review for one exact GitHub pull request head.
# Usage: fm-review-verdict.sh <pr-url> <40-hex-head> merge|fix [reviewer]
#        fm-review-verdict.sh passing <pr-url> <exact-head>
#        fm-review-verdict.sh refute <ship-task> <scout-task> <exact-head>
#        fm-review-verdict.sh history
# 'passing' is a read-only check for an exact merge verdict in this home's
# journal. Missing, malformed, or latest non-passing evidence fails closed.
# 'history' is a read-only listing of this home's journal, one JSON object
# {pr,head,verdict,reviewer,eligible} per record in journal order, where
# eligible marks the records 'passing' decides from (a refute merge is not one).
# It takes no lock and creates nothing. An absent journal lists nothing; a
# linked, unreadable, or malformed one exits 1.
# The reviewer/supervisor calls this after the independent review; this helper
# records the verdict, it does not perform or infer a review. No forge calls.
# Firstmate runs this when accepting the report, with its exact reviewed head;
# optional reviewer identifies the independent reviewer in the audit record.
# Appends a private JSON object {pr,head,verdict,reviewer} to state/review-verdicts.jsonl
# under a lock shared by writers. The latest valid record for that PR and head
# wins; another head's record never authorizes a merge. Recording the same
# refute review again appends nothing and keeps its original row, so a retry
# cannot displace a later record. A refute merge is new only with a new scout or
# report; a refute fix is also new when the scout reports it again.
# Ordinary verdicts carry no event identity, so each one is appended. FM_HOME (or
# FM_ROOT_OVERRIDE) and FM_STATE_OVERRIDE select the home/state as usual.
# Exit: 0 recorded, already recorded, or listed, 1 read/write/lock failure,
# 2 invalid arguments.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FILE="$STATE/review-verdicts.jsonl"
# The one definition of a readable receipt and of which receipts are eligible.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
RECEIPTS='
  def receipt:
    if type == "object"
       and (.pr | type == "string" and test("^https://github\\.com/[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}/pull/[1-9][0-9]*$"))
       and (.head | type == "string" and test("^[0-9a-f]{40}$"))
       and (.reviewer | type == "string") and (.verdict == "merge" or .verdict == "fix")
    then . else error("invalid verdict receipt") end;
  def eligible: .verdict == "fix" or (has("refute") | not);
  def receipts: [split("\n")[] | select(length > 0) | fromjson | receipt];
'
# Answered before the wake library is sourced, because sourcing it creates the
# state directory.
if [ "$#" -eq 1 ] && [ "$1" = history ]; then
  [ -e "$FILE" ] || [ -L "$FILE" ] || exit 0
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || exit 1
  exec jq -Rsc "$RECEIPTS"'
    receipts[] | {pr, head, verdict, reviewer, eligible: eligible}
  ' "$FILE"
fi
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
usage() {
  printf '%s\n' 'usage: fm-review-verdict.sh <pr-url> <exact-head> merge|fix [reviewer]' \
    '       fm-review-verdict.sh passing <pr-url> <exact-head>' \
    '       fm-review-verdict.sh refute <ship-task> <scout-task> <exact-head>' \
    '       fm-review-verdict.sh history'
}
if [ "${1:-}" = --help ]; then usage; exit 0; fi
if [ "${1:-}" = passing ]; then
  if [ "$#" -ne 3 ] || ! fm_pr_url_parse "$2" || [ "$FM_PR_PROVIDER" != github ] \
    || ! fm_pr_head_valid "$3"; then
    usage >&2
    exit 2
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -f "$FILE" ] && [ ! -L "$FILE" ] || exit 1
  exec jq -Res --arg pr "$FM_PR_URL" --arg head "$3" "$RECEIPTS"'
    [receipts[] | select(.pr == $pr and .head == $head and eligible)]
    | last | .verdict == "merge"
  ' "$FILE" >/dev/null 2>&1
fi
if [ "${1:-}" = refute ]; then
  [ "$#" -eq 4 ] || { usage >&2; exit 2; }
else
  if { [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; } || ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != github ] \
    || ! fm_pr_head_valid "$2" || [ "${#2}" -ne 40 ]; then
    usage >&2
    exit 2
  fi
  case "$3" in merge|fix) ;; *) echo 'error: verdict must be merge or fix' >&2; exit 2 ;; esac
fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
LOCK="$STATE/.review-verdicts.lock"
fm_lock_acquire_wait "$LOCK" || exit 1
trap 'fm_lock_release "$LOCK"' EXIT
DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_regular_destination_on_device_or_absent "$FILE" "$DEVICE" || exit 1
if [ "$1" = refute ]; then
  ROW=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    python3 "$SCRIPT_DIR/fm-done-acceptance.py" review-result "$2" "$3" "$4")
  [ -n "$ROW" ] || exit 0
else
  ROW=$(jq -nc --arg pr "$FM_PR_URL" --arg head "$2" --arg verdict "$3" --arg reviewer "${4:-}" \
    '{pr:$pr,head:$head,verdict:$verdict,reviewer:$reviewer}')
fi
(umask 077; printf '%s\n' "$ROW" >> "$FILE")
