#!/usr/bin/env bash
# Deliver GitHub PR CI and review changes to the owning worker's steering inbox.
#
# Usage:
#   fm-pr-feedback.sh arm <task-id>
#   fm-pr-feedback.sh poll <task-id>
#
# Poll is silent on stdout when only the worker was notified, so the watcher does
# not wake main for worker-directed evidence. stderr may carry diagnostics.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

pr_feedback_check_id() {  # <task-id>
  printf '%s-pr-feedback' "$1"
}

pr_feedback_record_path() {  # <task-id>
  printf '%s/%s/pr-feedback.json' "$DATA" "$1"
}

pr_feedback_read_meta() {  # <task-id>
  local task=$1 meta
  PR_FEEDBACK_URL=; PR_FEEDBACK_HEAD=; PR_FEEDBACK_PROVIDER=
  fm_pr_task_id_valid "$task" || return 1
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  PR_FEEDBACK_URL=$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2- || true)
  PR_FEEDBACK_HEAD=$(grep '^pr_head=' "$meta" | tail -1 | cut -d= -f2- || true)
  fm_pr_url_parse "$PR_FEEDBACK_URL" || return 1
  PR_FEEDBACK_PROVIDER=$FM_PR_PROVIDER
  [ "$PR_FEEDBACK_PROVIDER" = github ] || return 1
  return 0
}

pr_feedback_load_state() {  # <task-id> <head>
  local task=$1 head=$2 path
  path=$(pr_feedback_record_path "$task")
  PR_FEEDBACK_DELIVERED_JSON='[]'
  PR_FEEDBACK_STORED_HEAD=
  [ -f "$path" ] || return 0
  PR_FEEDBACK_STORED_HEAD=$(jq -r '.head // ""' "$path" 2>/dev/null || true)
  if [ "$PR_FEEDBACK_STORED_HEAD" != "$head" ]; then
    PR_FEEDBACK_DELIVERED_JSON='[]'
    return 0
  fi
  PR_FEEDBACK_DELIVERED_JSON=$(jq -c '.delivered // []' "$path" 2>/dev/null || printf '[]')
}

pr_feedback_save_state() {  # <task-id> <head> <delivered-json-array>
  local task=$1 head=$2 delivered=$3 dir path tmp
  dir="$DATA/$task"
  path=$(pr_feedback_record_path "$task")
  mkdir -p "$dir" || return 1
  tmp=$(umask 077; mktemp "$dir/.pr-feedback.XXXXXX") || return 1
  jq -n --arg head "$head" --argjson delivered "$delivered" \
    '{schema:"fm-pr-feedback.v1",head:$head,delivered:$delivered}' > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

pr_feedback_already_delivered() {  # <token>
  local token=$1
  jq -e --arg t "$token" 'index($t) != null' <<<"$PR_FEEDBACK_DELIVERED_JSON" >/dev/null 2>&1
}

pr_feedback_append_delivered() {  # <token>
  local token=$1
  PR_FEEDBACK_DELIVERED_JSON=$(jq -c --arg t "$token" '. + [$t] | unique' <<<"$PR_FEEDBACK_DELIVERED_JSON")
}

pr_feedback_fetch_github() {  # <url> <head>
  local url=$1 head=$2 owner repo
  owner=$FM_PR_OWNER
  repo=$FM_PR_REPO
  [ -n "$head" ] || head=$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null || true)
  [ -n "$head" ] || return 1
  PR_FEEDBACK_HEAD=$head
  : > "$PR_FEEDBACK_TMP/checks.ndjson"
  gh api "/repos/$owner/$repo/commits/$head/check-runs" --paginate \
    --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")
      | {token:("check:" + (.id|tostring) + ":" + (.conclusion // "none")),
         kind:"check", name:.name, state:(.conclusion // .status), url:(.html_url // ""),
         excerpt:((.output.summary // "") | .[:240])}' \
    2>/dev/null >> "$PR_FEEDBACK_TMP/checks.ndjson" || return 1
  gh pr view "$url" --json reviews \
    --jq '.reviews[]? | select(.state == "CHANGES_REQUESTED")
      | {token:("review:" + (.id|tostring) + ":" + .state + ":" + (.commit.oid // "")),
         kind:"review", name:(.author.login // "reviewer"), state:.state, url:(.url // ""),
         excerpt:((.body // "") | .[:240])}' \
    2>/dev/null > "$PR_FEEDBACK_TMP/reviews.ndjson" || : > "$PR_FEEDBACK_TMP/reviews.ndjson"
  jq -n --arg head "$head" \
    --argjson checks "$( [ -s "$PR_FEEDBACK_TMP/checks.ndjson" ] \
      && jq -s '.' "$PR_FEEDBACK_TMP/checks.ndjson" || printf '[]' )" \
    --argjson reviews "$( [ -s "$PR_FEEDBACK_TMP/reviews.ndjson" ] \
      && jq -s '.' "$PR_FEEDBACK_TMP/reviews.ndjson" || printf '[]' )" \
    '{head:$head, items: ($checks + $reviews)}' > "$PR_FEEDBACK_TMP/combined.json"
  return 0
}

pr_feedback_actionable_items() {
  jq -c '.items // []' "$PR_FEEDBACK_TMP/combined.json"
}

pr_feedback_compose_message() {  # <task> <url>
  local task=$1 url=$2 lines item
  lines="PR feedback for $url (head ${PR_FEEDBACK_HEAD:0:8}) — routed to you directly; fix and push or declare a wait if blocked externally."
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    lines="$lines
- $(jq -r '[.kind,.name,.state] | join(": ")' <<<"$item")$(jq -r 'if .url != "" then " " + .url else "" end' <<<"$item")"
    excerpt=$(jq -r '.excerpt // ""' <<<"$item")
    [ -z "$excerpt" ] || lines="$lines
  $(printf '%s' "$excerpt" | head -3)"
  done < <(jq -c '.[]' <<<"$PR_FEEDBACK_ACTIONABLE")
  PR_FEEDBACK_MESSAGE=$lines
}

pr_feedback_poll_task() {  # <task-id>
  local task=$1 check_id delivered=0 sent=0
  PR_FEEDBACK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-feedback.XXXXXX") || return 1
  trap 'rm -rf -- "$PR_FEEDBACK_TMP"' RETURN
  pr_feedback_read_meta "$task" || return 0
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'pr-feedback: gh or jq unavailable; skipping %s\n' "$task" >&2
    return 0
  fi
  fm_pr_url_parse "$PR_FEEDBACK_URL" || return 0
  pr_feedback_fetch_github "$PR_FEEDBACK_URL" "$PR_FEEDBACK_HEAD" || return 0
  pr_feedback_load_state "$task" "$PR_FEEDBACK_HEAD"
  PR_FEEDBACK_ACTIONABLE=$(pr_feedback_actionable_items)
  PR_FEEDBACK_NEW=()
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    token=$(jq -r '.token' <<<"$item")
    pr_feedback_already_delivered "$token" && continue
    PR_FEEDBACK_NEW+=("$item")
    pr_feedback_append_delivered "$token"
    delivered=1
  done < <(jq -c '.[]' <<<"$PR_FEEDBACK_ACTIONABLE")
  [ "$delivered" -eq 1 ] || return 0
  pr_feedback_compose_message "$task" "$PR_FEEDBACK_URL"
  if FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-send.sh" "$task" "$PR_FEEDBACK_MESSAGE" >/dev/null 2>&1; then
    sent=1
    pr_feedback_save_state "$task" "$PR_FEEDBACK_HEAD" "$PR_FEEDBACK_DELIVERED_JSON" || true
  else
    printf 'pr-feedback: steer unconfirmed for %s\n' "$task" >&2
    return 0
  fi
  [ "$sent" -eq 1 ] || true
  return 0
}

pr_feedback_arm_task() {  # <task-id>
  local task=$1 check_id device staged shim
  fm_pr_task_id_valid "$task" || { echo "error: invalid task id" >&2; exit 2; }
  pr_feedback_read_meta "$task" || {
    echo "error: task has no GitHub PR to watch for worker feedback" >&2
    exit 1
  }
  check_id=$(pr_feedback_check_id "$task")
  device=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_regular_destination_on_device_or_absent "$STATE/$check_id.check.sh" "$device" \
    || { echo "error: unsafe check destination" >&2; exit 1; }
  staged=$(umask 077; mktemp "$STATE/.pr-feedback-check.XXXXXX") || exit 1
  shim=('#!/usr/bin/env bash'
    "export FM_HOME=$(printf '%q' "$FM_HOME")"
    "export FM_ROOT_OVERRIDE=$(printf '%q' "$FM_ROOT")"
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")"
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")"
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-feedback.sh") poll $(printf '%q' "$task")")
  printf '%s\n' "${shim[@]}" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/$check_id.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" "$check_id" >/dev/null \
    || { echo "error: could not register PR feedback check" >&2; exit 1; }
  printf 'armed: state/%s.check.sh\n' "$check_id"
}

case "${1:-}" in
  arm)
    [ "$#" -eq 2 ] || { echo "usage: fm-pr-feedback.sh arm <task-id>" >&2; exit 2; }
    pr_feedback_arm_task "$2"
    ;;
  poll)
    [ "$#" -eq 2 ] || { echo "usage: fm-pr-feedback.sh poll <task-id>" >&2; exit 2; }
    pr_feedback_poll_task "$2"
    ;;
  *)
    echo "usage: fm-pr-feedback.sh arm|poll <task-id>" >&2
    exit 2
    ;;
esac
