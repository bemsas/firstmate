#!/usr/bin/env bash
# fm-review-eligibility-preview.sh - read-only explanation of which open pull
# requests of one GitHub repository look ready for another review.
#
# Usage: fm-review-eligibility-preview.sh <[host/]owner/repo> [--limit <n>] [--pr <n>]... [--json]
#
# It reports and never acts: no queue, backlog, task record, verdict journal, or
# forge write, no lock, and no dispatch. The one forge call is a bounded GraphQL
# query. Every row is advice bound to the head and time it was observed; the
# dispatch owner still checks the live head, holds, owners, capacity, proof, and
# model before it starts a review.
#
# Rows are the <n> most recently updated open pull requests (--limit, default 20),
# or exactly the --pr numbers. One call lists at most 100 open pull requests, so a
# requested number it does not list is reported unknown.
#
# Inputs, each read through its owner:
#   forge      bin/fm-review-capacity-lib.sh: target parsing, bounded gh-axi read,
#              and local task record matching
#   verdicts   bin/fm-review-verdict.sh history
#   holds      bin/fm-tasks-axi.sh list --state held, then show <id> --full; a hold
#              joins by its owning task or its required-review line, never prose
#   owners     task records and status logs; fm_dod_candidate_fields in
#              bin/fm-dod-lib.sh reads a ready report's exact head
#   reviews    state/<scout>.refute.json dispatch records
# They come only from the one home FM_HOME selects. Other-home owner and hold
# evidence is unknown. Its state/ must exist, and state/ and data/ must resolve to
# directories of that home, so FM_STATE_OVERRIDE and FM_DATA_OVERRIDE cannot point
# elsewhere. A linked status log is unreadable. Error messages name no local path.
#
# bin/fm-review-eligibility-preview.py owns how a row is judged and printed.
#
# Exit: 0 report printed, 1 the forge could not be observed (a report still
# prints, with the requested rows unknown), 2 invalid arguments, no state
# directory, or state or data outside the selected home.
# The single-quoted programs below use jq and GraphQL variables.
# shellcheck disable=SC2016
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-review-eligibility-preview: %s\n' "$*" >&2
  exit 2
}

TARGET='' LIMIT=20 JSON=0
PRS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help | -h) usage; exit 0 ;;
    --json) JSON=1 ;;
    --limit | --pr)
      [ "$#" -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 needs a positive number"
      if [ "$1" = --limit ]; then LIMIT=$2; else PRS+=("$2"); fi
      shift
      ;;
    -*) die "unknown option" ;;
    *)
      [ -z "$TARGET" ] || die "name exactly one repository"
      TARGET=$1
      ;;
  esac
  shift
done
[ -n "$TARGET" ] || die "usage: fm-review-eligibility-preview.sh <[host/]owner/repo> [--limit <n>] [--pr <n>]... [--json]"
case "$TARGET" in */*/*) ;; *) TARGET="github.com/$TARGET" ;; esac
# Checked before any library is sourced: bin/fm-wake-lib.sh would create it.
[ -d "$STATE" ] || die "state directory does not exist"
resolved() { (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P); }
HOME_REAL=$(resolved "$FM_HOME") || die "the selected home cannot be resolved"
[ "$(resolved "$STATE")" = "$HOME_REAL/state" ] || die "state directory is outside the selected home"
if [ -e "$DATA" ] || [ -L "$DATA" ]; then
  [ "$(resolved "$DATA")" = "$HOME_REAL/data" ] || die "data directory is outside the selected home"
else
  [ "$DATA" = "$FM_HOME/data" ] || die "data directory is outside the selected home"
fi
STATE="$HOME_REAL/state" DATA="$HOME_REAL/data"
for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-review-capacity-lib.sh
. "$SCRIPT_DIR/fm-review-capacity-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

fm_review_capacity_target "$FM_ROOT" "$TARGET" ||
  die "the repository is not a GitHub owner/repository on a host this home uses"
HOST=$FM_REVIEW_TARGET_HOST OWNER=$FM_REVIEW_TARGET_OWNER REPO=$FM_REVIEW_TARGET_REPO
WANT=$(printf '%s/%s/%s' "$HOST" "$OWNER" "$REPO" | tr '[:upper:]' '[:lower:]')

# Facts are JSON lines on descriptor 3; the formatter joins them.
fact() {  # <jq-program> [jq-args...]
  local program=$1
  shift
  jq -nc "$@" "$program" >&3
}

unreadable() {  # <input> <detail> [affected PR numbers]
  if [ -n "${3:-}" ]; then
    fact '{t:"unreadable",input:$input,detail:$detail,prs:($prs|split(" ")|map(select(length>0)|tonumber))}' \
      --arg input "$1" --arg detail "$2" --arg prs "$3"
  else
    fact '{t:"unreadable",input:$input,detail:$detail}' --arg input "$1" --arg detail "$2"
  fi
}

# The selected open pull requests, plus the head branches their owners could
# record.
HEADS=' '
HEAD_PR_NUMBERS=' '
HEAD_BRANCH_PR=' '
collect_forge() {
  local query jq_expr body entry num draft head hrepo base branch selected=' ' wanted p count=0
  query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:'"$FM_REVIEW_CAPACITY_PAGE"',orderBy:{field:UPDATED_AT,direction:DESC}){totalCount nodes{number isDraft baseRefName headRefName headRefOid headRepository{nameWithOwner}}}}}'
  jq_expr='.data.repository.pullRequests as $p | ([$p.nodes[] | "\(.number),\(if .isDraft then 1 else 0 end),\(.headRefOid // "" | tostring | @uri),\((.headRepository.nameWithOwner // "") | ascii_downcase | @uri),\(.baseRefName | @uri),\(.headRefName | @uri)"] | "fm-review-preview total=\($p.totalCount) \(join(" "))")'
  OBSERVED_AT=$(date +%s)
  # The shared query keeps an ambient GH_HOST for github.com; every row here is
  # labelled with $HOST, so the request is pinned to it.
  export GH_HOST="$HOST"
  if ! fm_review_capacity_query "$HOST" "$OWNER" "$REPO" "$query" "$jq_expr" \
    fm-review-preview "an open pull request list"; then
    FORGE_ERROR=$FM_REVIEW_QUERY_ERROR
    return 1
  fi
  body=${FM_REVIEW_QUERY_BODY#fm-review-preview total=}
  TOTAL=${body%% *}
  [[ "$TOTAL" =~ ^[0-9]+$ ]] || { FORGE_ERROR="gh-axi's answer is not an open pull request list"; return 1; }
  body=${body#"$TOTAL"}
  for p in ${PRS[@]+"${PRS[@]}"}; do selected="$selected$p "; done
  for entry in $body; do
    IFS=, read -r num draft head hrepo base branch <<< "$entry"
    if [ "${#PRS[@]}" -gt 0 ]; then
      case "$selected" in *" $num "*) wanted=1 ;; *) wanted=0 ;; esac
    else
      count=$((count + 1))
      wanted=$((count <= LIMIT))
    fi
    [ "$wanted" -eq 1 ] || continue
    HEADS="$HEADS$branch "
    HEAD_PR_NUMBERS="$HEAD_PR_NUMBERS$num "
    HEAD_BRANCH_PR="$HEAD_BRANCH_PR$branch:$num "
    fact '{t:"pr",number:($num|tonumber),draft:($draft=="1"),head:$head,head_repo:$hrepo,base:$base,branch:$branch}' \
      --arg num "$num" --arg draft "$draft" --arg head "$head" --arg hrepo "$hrepo" \
      --arg base "$base" --arg branch "$branch"
  done
}

# One task record, when its pr= is in this repository or its branch could be a
# selected pull request's head: its last status event and ready reports.
collect_record() {  # <state> <meta>
  local state=$1 meta=$2 id text kind pr pr_path pr_number branch pr_match=0 branch_match=0 target='' sources='' affected_prs='' pair
  local status last='' verb='' note line scan ready_url report_head done_lines=''
  if ! fm_review_capacity_read_record "$meta"; then
    [ -e "$meta" ] || return 0
    unreadable owners "task record $meta cannot be read coherently"
    return 0
  fi
  text=$FM_REVIEW_RECORD_TEXT
  id=$(basename "$meta" .meta)
  kind=$(fm_review_capacity_field "$text" kind)
  [ "$kind" != secondmate ] || return 0
  pr=$(fm_review_capacity_field "$text" pr)
  pr_path=$(printf '%s' "$pr" | tr '[:upper:]' '[:lower:]')
  case "$pr_path" in
    "https://$WANT/pull/"*)
      pr_number=${pr_path#"https://$WANT/pull/"}
      case "$pr_number" in ''|*[!0-9]*) ;; *) case "$HEAD_PR_NUMBERS" in *" $pr_number "*) pr_match=1 ;; esac ;; esac
      ;;
  esac
  branch=$(fm_review_capacity_field "$text" branch)
  if [ -n "$branch" ]; then
    branch=$(fm_review_capacity_uri "$branch")
    case "$HEADS" in *" $branch "*) branch_match=1 ;; esac
  fi
  if [ "$branch_match" -eq 1 ]; then
    target=$(fm_review_capacity_record_target "$text")
    if [ -z "$target" ]; then
      for pair in $HEAD_BRANCH_PR; do
        case "$pair" in "$branch":*) affected_prs="${affected_prs}${pair#*:} " ;; esac
      done
      unreadable owners "task $id records a selected head branch but its publication target cannot be resolved" "${affected_prs% }"
    fi
    [ "$target" = "$WANT" ] || branch_match=0
    [ "$branch_match" -eq 0 ] || sources=$(fm_review_capacity_record_sources "$text" "$WANT" | tr '\n' ' ')
  fi
  [ "$pr_match" -eq 1 ] || [ "$branch_match" -eq 1 ] || return 0
  [ "$branch_match" -eq 1 ] || branch=''
  status="$state/$id.status"
  if [ -e "$status" ] || [ -L "$status" ]; then
    if [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ]; then
      scan=$(_fm_crew_status_event_scan < "$status") || :
      last=${scan##*$'\n'}
      [ -z "$last" ] || status_line_verb "$last" verb
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *done*"PR https://"*) ;; *) continue ;; esac
        status_line_verb "$line" note
        [ "$note" = "done" ] || continue
        status_line_note "$line" note
        ready_url=$(fm_dod_ready_note_url "$note") || continue
        report_head=''
        if fm_dod_candidate_fields "$note"; then
          report_head=$FM_DOD_CANDIDATE_HEAD
        fi
        done_lines="$done_lines$ready_url $report_head"$'\n'
      done < "$status"
    else
      verb=unreadable
    fi
  fi
  fact '{t:"record",state:$state,id:$id,kind:$kind,pr:$pr,branch:$branch,sources:($sources|split(" ")|map(select(length>0))),verb:$verb,
         done:($reports|split("\n")|map(select(length>0)|capture("^(?<url>[^ ]+) (?<head>[^ ]*)$")))}' \
    --arg state "$state" --arg id "$id" --arg kind "$kind" --arg pr "$pr" --arg branch "$branch" \
    --arg sources "$sources" --arg verb "$verb" --arg reports "$done_lines"
}

collect_tickets() {  # <state>
  local state=$1 ticket row reviewer live status scan last verb status_unreadable
  for ticket in "$state"/*.refute.json; do
    [ -e "$ticket" ] || [ -L "$ticket" ] || continue
    if [ ! -f "$ticket" ] || [ -L "$ticket" ] || ! row=$(jq -ce '
      {pr: .candidate.pr, head: .candidate.head, reviewer: .reviewer}
      | if all(.pr, .reviewer; type == "string" and length > 0) then . else error("incomplete") end
      | .head |= (if type == "string" then . else "" end)' "$ticket" 2>/dev/null); then
      unreadable reviews "review dispatch record $ticket cannot be read"
      continue
    fi
    reviewer=$(basename "$ticket" .refute.json)
    live=false
    status_unreadable=false
    if [ -f "$state/$reviewer.meta" ] && [ ! -L "$state/$reviewer.meta" ]; then
      live=true
      verb=''
      status="$state/$reviewer.status"
      if [ -e "$status" ] || [ -L "$status" ]; then
        if [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ]; then
          scan=$(_fm_crew_status_event_scan < "$status") || :
          last=${scan##*$'\n'}
          [ -z "$last" ] || status_line_verb "$last" verb
          case "${verb:-}" in done|failed) live=false ;; esac
        else
          live=false
          status_unreadable=true
        fi
      fi
    fi
    fact '$row + {t:"ticket",state:$state,live:$live,status_unreadable:$status_unreadable}' \
      --argjson row "$row" --arg state "$state" --argjson live "$live" \
      --argjson status_unreadable "$status_unreadable"
  done
}

collect_verdicts() {  # <state>
  local state=$1 rows
  if ! rows=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-review-verdict.sh" history 2>/dev/null); then
    unreadable verdicts "review verdict journal in $state cannot be read"
    return 0
  fi
  [ -z "$rows" ] || printf '%s\n' "$rows" | jq -c --arg state "$state" '. + {t:"verdict",state:$state}' >&3
}

collect_holds() {  # <state> <home> <data>
  local state=$1 home=$2 data=$3 listing count ids id show
  if ! listing=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$SCRIPT_DIR/fm-tasks-axi.sh" list --state held --limit 100000 2>/dev/null); then
    unreadable holds "held tasks of $home cannot be listed"
    return 0
  fi
  count=$(printf '%s\n' "$listing" | sed -n 's/^count: \([0-9][0-9]*\).*/\1/p' | head -n 1)
  ids=$(printf '%s\n' "$listing" | awk '/^tasks\[[0-9]+\]\{id,/ { rows = 1; next } rows && /^  / { sub(/^  /, ""); sub(/,.*/, ""); print; next } { rows = 0 }')
  if [ -z "$count" ] || [ "$(printf '%s' "$ids" | grep -c .)" -ne "$count" ]; then
    unreadable holds "held task list of $home is incomplete or unrecognized"
    return 0
  fi
  for id in $ids; do
    if ! show=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
      "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null); then
      unreadable holds "held task $id of $home cannot be read"
      continue
    fi
    fact '{t:"hold",state:$state,id:$id,show:$show}' --arg state "$state" --arg id "$id" --arg show "$show"
  done
}

collect_local() {
  local meta
  if [ ! -d "$STATE" ] || [ ! -r "$STATE" ] || [ ! -x "$STATE" ]; then
    unreadable owners "the caller's local state cannot be read"
    unreadable verdicts "the caller's local state cannot be read"
    unreadable reviews "the caller's local state cannot be read"
    unreadable holds "the caller's local state cannot be read"
    return 0
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    collect_record "$STATE" "$meta"
  done
  collect_tickets "$STATE"
  collect_verdicts "$STATE"
  collect_holds "$STATE" "$FM_HOME" "$DATA"
}

collect() {
  exec 3>&1
  FORGE_ERROR='' TOTAL=0
  collect_forge || :
  fact '{t:"observation",repo:$repo,at:($at|tonumber),total:($total|tonumber),error:$error,
         requested:($requested|split(" ")|map(select(length>0)|tonumber))}' \
    --arg repo "$WANT" --arg at "$OBSERVED_AT" --arg total "$TOTAL" --arg error "$FORGE_ERROR" \
    --arg requested "${PRS[*]-}"
  [ -n "$FORGE_ERROR" ] || collect_local
}

FORMAT=()
[ "$JSON" -eq 0 ] || FORMAT+=(--json)
set -o pipefail
# Collector diagnostics can name local paths, so none are shown.
collect 2>/dev/null | python3 -I "$SCRIPT_DIR/fm-review-eligibility-preview.py" ${FORMAT[@]+"${FORMAT[@]}"}
