#!/usr/bin/env bash
# Explicit, opt-in bookkeeping for one software-feature ship job.
# Usage:
#   fm-job-ticket.sh init <task> --size S|M|L --kind ship
#   fm-job-ticket.sh truth <task> add --id T1 --text <text> --proof command|desktop|document|none --owner <actor>
#   fm-job-ticket.sh pass <task> <layer>... --actor <actor> (--artifact <file>|--ref <text>) [--version <40-hex>]
#   fm-job-ticket.sh observe <task> <truth-id> --by <actor> --status PROVEN|GAP|NOT_DETERMINED|NOT_RUN
#     --version <40-hex> [--evidence <file>]... [--baseline <file> --after <file>] [--synthetic] [--reason <text>]
#   fm-job-ticket.sh return <task> --code intent|approach|craft|proof|environment --by <actor> [--note <text>]
#   fm-job-ticket.sh check <task> [--version <40-hex>]
#   fm-job-ticket.sh show <task>
#
# FM_HOME must explicitly name an absolute home directory; there is no checkout
# fallback. FM_DATA_OVERRIDE and FM_CONFIG_OVERRIDE may select absolute data
# and config directories (defaults: $FM_HOME/data and $FM_HOME/config).
# Reads data/<task>/brief.md and owns only data/<task>/job-ticket.json, plus
# transient same-directory lock and temporary files. No state override is used.
# Mutations exit 0 with "disabled" before reading records or creating anything
# unless config/job-ticket exists. check/show are read-only even when disabled.
# check prints JSON to stdout and a bookkeeping summary to stderr.
# Actor labels are operator assertions, not authenticated or independent actors.
# docs/job-ticket.md owns schema and semantics; this header owns CLI mechanics.
# Exit: 0 recorded/read/complete/disabled; 1 rule or IO refusal; 2 usage;
# 3 check incomplete, stale or intent-changed; 11 local return escalation recorded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
usage() { sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0"; }
bad_usage() { printf 'fm-job-ticket: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'fm-job-ticket: %s\n' "$*" >&2; exit 1; }
actor_valid() { [[ $1 =~ ^[a-z][a-z0-9_-]*$ ]]; }
version_valid() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
layer_index() {
  case "$1" in
    intake) echo 0 ;; research) echo 1 ;; strategy) echo 2 ;; production) echo 3 ;;
    qa) echo 4 ;; reality) echo 5 ;; delivery) echo 6 ;; learning) echo 7 ;;
    *) bad_usage "unknown layer: $1" ;;
  esac
}
file_binding() {
  local file=$1 role=$2 hash
  [ -f "$file" ] && [ -s "$file" ] || refuse "missing or empty artifact: $file"
  file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  hash=$(fm_pr_sha256 "$file") || refuse "cannot hash artifact: $file"
  jq -nc --arg file "$file" --arg role "$role" --arg sha256 "$hash" \
    '{file:$file,role:$role,sha256:$sha256}'
}
intent_hash() {
  [ -f "$BRIEF" ] && fm_brief_heading_present "$BRIEF" "## Captain's intent" || return 1
  fm_brief_heading_body "$BRIEF" "## Captain's intent" | fm_pr_sha256 /dev/stdin
}
read_ticket() {
  [ -f "$FILE" ] || refuse 'ticket missing'
  ticket=$(cat "$FILE")
  jq -e --arg task "$TASK" '.schema == "fm-job-ticket.v1" and .task == $task and .kind == "ship"
    and (.layers|length) == 8 and (.ledger|type) == "array"' <<<"$ticket" >/dev/null || refuse 'invalid ticket'
}
write_ticket() {
  tmp=$(mktemp "$DIR/.job-ticket.tmp.XXXXXX") || refuse 'cannot create temporary ticket'
  printf '%s\n' "$ticket" > "$tmp"
  mv "$tmp" "$FILE"
  tmp=''
}

cmd=${1:-}
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  init|truth|pass|observe|return|check|show) ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -ge 2 ] || bad_usage 'task required'
TASK=$2
fm_task_id_path_safe "$TASK" || bad_usage 'invalid task identifier'
case "${FM_HOME:-}" in /*) ;; *) bad_usage 'explicit absolute FM_HOME required' ;; esac
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
case "$DATA:$CONFIG" in /*:/*) ;; *) bad_usage 'absolute data/config overrides required' ;; esac
DIR=$DATA/$TASK
FILE=$DIR/job-ticket.json
BRIEF=$DIR/brief.md
shift 2
case "$cmd" in
  check|show) ;;
  *) [ -e "$CONFIG/job-ticket" ] || { echo 'fm-job-ticket: disabled'; exit 0; } ;;
esac

layers=()
truth_id='' size='' kind='' text='' proof='' actor='' status='' version=''
artifact='' ref='' reason='' code='' note='' baseline='' after=''
evidence='[]' synthetic=false
case "$cmd" in
  truth) [ "${1:-}" = add ] || bad_usage 'truth requires add'; shift ;;
  observe) truth_id=${1:-}; [ -n "$truth_id" ] || bad_usage 'truth id required'; shift ;;
  pass)
    while [ "$#" -gt 0 ] && [[ $1 != --* ]]; do
      layers+=("$1"); shift
    done
    [ "${#layers[@]}" -gt 0 ] || bad_usage 'layer required'
    ;;
esac
while [ "$#" -gt 0 ]; do
  case "$cmd:$1" in
    init:--size|init:--kind|truth:--id|truth:--text|truth:--proof|truth:--owner|\
    pass:--actor|pass:--artifact|pass:--ref|pass:--version|\
    observe:--by|observe:--status|observe:--version|observe:--evidence|observe:--baseline|observe:--after|observe:--reason|\
    return:--code|return:--by|return:--note|check:--version)
      [ "$#" -ge 2 ] && [ -n "$2" ] || bad_usage "value required: $1"
      case "$1" in
        --size) size=$2 ;; --kind) kind=$2 ;; --id) truth_id=$2 ;; --text) text=$2 ;;
        --proof) proof=$2 ;; --owner|--actor|--by) actor=$2 ;; --status) status=$2 ;;
        --version) version=$2 ;; --artifact) artifact=$2 ;; --ref) ref=$2 ;;
        --reason) reason=$2 ;; --code) code=$2 ;; --note) note=$2 ;;
        --baseline) baseline=$2 ;; --after) after=$2 ;;
        --evidence) evidence=$(jq -c --arg file "$2" '. + [$file]' <<<"$evidence") ;;
      esac
      shift 2 ;;
    observe:--synthetic) synthetic=true; shift ;;
    *) bad_usage "unexpected argument: $1" ;;
  esac
done
[ -z "$version" ] || version_valid "$version" || bad_usage 'version must be 40 lower-case hex characters'
[ -z "$actor" ] || actor_valid "$actor" || bad_usage 'invalid actor label'
[ -z "$truth_id" ] || fm_task_id_path_safe "$truth_id" || bad_usage 'invalid truth identifier'

if [ "$cmd" = show ]; then read_ticket; printf '%s\n' "$ticket"; exit 0; fi
if [ "$cmd" = check ]; then
  read_ticket
  current_hash=$(intent_hash || true)
  # Re-read bound bytes without changing the ticket. A hash binds bytes only.
  broken='[]'
  while IFS= read -r binding; do
    path=$(jq -r '.file' <<<"$binding")
    expected=$(jq -r '.sha256' <<<"$binding")
    actual=$(fm_pr_sha256 "$path" || true)
    if [ "$expected" != "$actual" ]; then
      broken=$(jq -c --arg file "$path" '. + [$file]' <<<"$broken")
    fi
  done < <(jq -c '(.layers[]|select(.state=="passed")|.artifact // empty),
    (.ledger[].observation // empty|select(.state=="current")|.evidence[])' <<<"$ticket")
  verdict=$(jq -c --arg hash "$current_hash" --arg version "$version" --argjson broken "$broken" '
    ([.ledger[] | .observation.status // "UNOBSERVED"] | group_by(.) | map({key:.[0],value:length}) | from_entries) as $counts |
    (.layers[4].version // .layers[3].version) as $target |
    (any(.ledger[]; .observation != null and
      (.observation.state == "stale" or .observation.version != $target or
       ($version != "" and .observation.version != $version)))) as $old |
    (if .intent.sha256 != $hash then "intent-changed"
     elif any(.layers[]; .state == "stale") or $old or ($broken|length)>0 then "stale"
     elif any(.layers[]; .state != "passed") or any(.ledger[]; .observation == null) then "incomplete"
     else "complete" end) as $flow |
    {flow:$flow,layers:[.layers[]|{layer,state,actor}],
     statuses:({UNOBSERVED:0,PROVEN:0,GAP:0,NOT_DETERMINED:0,NOT_RUN:0} + $counts),
     synthetic:([.ledger[].observation|select(.synthetic == true)]|length),
     returns:(.returns|group_by(.code)|map({key:.[0].code,value:length})|from_entries),
     escalate:any(.returns[];.escalate),changed_artifacts:$broken} |
    if $flow == "intent-changed" and .layers[0].state == "passed" then .layers[0].state="stale" else . end |
    if $old and .layers[5].state == "passed" then .layers[5].state="stale" else . end' <<<"$ticket")
  printf '%s\n' "$verdict"
  flow=$(jq -r '.flow' <<<"$verdict")
  printf 'fm-job-ticket: bookkeeping %s; no work-quality verdict\n' "$flow" >&2
  [ "$flow" = complete ] && exit 0
  exit 3
fi

[ -d "$DIR" ] || refuse 'task data directory missing'
umask 077
# The shared lock library initializes STATE on source. Confine that initialization
# to the existing ticket directory, never the home state directory.
FM_STATE_OVERRIDE=$DIR
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK=$DIR/.job-ticket.lock
fm_lock_acquire_wait "$LOCK" || refuse 'cannot acquire ticket lock'
tmp=''
cleanup() {
  [ -z "$tmp" ] || rm -f "$tmp"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
now=$(date +%s)
if [ "$cmd" = init ]; then
  [ ! -e "$FILE" ] || refuse 'ticket already exists'
  case "$size" in S|M|L) ;; *) bad_usage 'size must be S, M or L' ;; esac
  [ "$kind" = ship ] || bad_usage 'only software-feature ship jobs supported (--kind ship)'
  body=$(fm_brief_heading_body "$BRIEF" "## Captain's intent") || refuse 'cannot read raw intent'
  [[ $body =~ [^[:space:]] ]] || refuse 'raw intent section missing or empty'
  hash=$(intent_hash) || refuse 'cannot read raw intent'
  ticket=$(jq -nc --arg task "$TASK" --arg size "$size" --arg file "$BRIEF" --arg hash "$hash" \
    '{schema:"fm-job-ticket.v1",task:$task,size:$size,kind:"ship",job_type:"software-feature",
      intent:{file:$file,section:"## Captain\u0027s intent",sha256:$hash,history:[]},ledger_frozen:false,
      layers:(["intake","research","strategy","production","qa","reality","delivery","learning"] |
        map({layer:.,state:"open",actor:null,artifact:null,ref:null,version:null,at:null,history:[]})),ledger:[],returns:[]}')
  write_ticket
  exit 0
fi
read_ticket
case "$cmd" in
  truth)
    [ -n "$truth_id" ] && [ -n "$text" ] && [ -n "$actor" ] || bad_usage 'truth requires id, text and owner'
    case "$proof" in command|desktop|document|none) ;; *) bad_usage 'invalid proof type' ;; esac
    jq -e '.ledger_frozen == false' <<<"$ticket" >/dev/null || refuse 'ledger frozen at strategy'
    jq -e --arg id "$truth_id" 'all(.ledger[]; .id != $id)' <<<"$ticket" >/dev/null || refuse 'duplicate truth id'
    ticket=$(jq --arg id "$truth_id" --arg text "$text" --arg proof "$proof" --arg owner "$actor" \
      '.ledger += [{id:$id,text:$text,proof:$proof,owner:$owner,observation:null,history:[]}]' <<<"$ticket")
    ;;
  pass)
    [ -n "$actor" ] || bad_usage 'actor required'
    [ -z "$artifact" ] || [ -z "$ref" ] || bad_usage 'choose artifact or reference'
    binding=null
    [ -z "$artifact" ] || binding=$(file_binding "$artifact" artifact)
    previous=-1
    for layer in "${layers[@]}"; do
      index=$(layer_index "$layer")
      [ "$previous" -eq -1 ] || [ "$index" -eq "$((previous + 1))" ] || refuse 'layers must be adjacent and ordered'
      previous=$index
      jq -e --argjson i "$index" 'all(.layers[:$i][]; .state == "passed")' <<<"$ticket" >/dev/null || refuse 'earlier layer open or stale'
      if [ "$index" -gt 0 ]; then
        hash=$(intent_hash || true)
        [ "$hash" = "$(jq -r '.intent.sha256' <<<"$ticket")" ] || refuse 'intent changed; pass intake again'
      fi
      if [ "$binding" = null ]; then
        case "$layer:$ref" in qa:?*|delivery:?*|learning:none) ;; *) refuse 'non-empty artifact required for this layer' ;; esac
      fi
      [ "$layer" != strategy ] || jq -e '(.ledger|length)>0' <<<"$ticket" >/dev/null || refuse 'strategy needs a truth ledger'
      [ "$layer" != production ] || [ -n "$version" ] || refuse 'production requires version'
      if [ "$layer" = intake ]; then
        body=$(fm_brief_heading_body "$BRIEF" "## Captain's intent") || refuse 'cannot read raw intent'
        [[ $body =~ [^[:space:]] ]] || refuse 'raw intent section missing or empty'
        hash=$(intent_hash) || refuse 'cannot read raw intent'
        ticket=$(jq --arg hash "$hash" --argjson at "$now" '
          if .intent.sha256 != $hash then
            .intent.history += [{sha256:.intent.sha256,at:$at}] | .intent.sha256=$hash
          else . end' <<<"$ticket")
      fi
      if [ "$layer" = reality ]; then
        jq -e '(.layers[4].version // .layers[3].version) as $v |
          all(.ledger[]; .observation != null and .observation.state == "current" and .observation.version == $v)' \
          <<<"$ticket" >/dev/null || refuse 'truth observations missing or stale for QA/production version'
      fi
      ticket=$(jq --argjson i "$index" --arg actor "$actor" --argjson artifact "$binding" --arg ref "$ref" \
        --arg version "$version" --argjson at "$now" '
        .layers[$i] |= (.history += [del(.history)] | .state="passed" | .actor=$actor |
          .artifact=$artifact | .ref=(if $ref=="" then null else $ref end) |
          .version=(if $version=="" then null else $version end) | .at=$at) |
        .layers |= [to_entries[] | if .key>$i and .value.at!=null then .value.state="stale" else . end | .value] |
        if $i<5 then .ledger |= map(if .observation != null then .observation.state="stale" else . end) else . end |
        if $i==2 then .ledger_frozen=true else . end' <<<"$ticket")
    done
    ;;
  observe)
    [ -n "$actor" ] && [ -n "$version" ] || bad_usage 'observer and version required'
    row=$(jq -c --arg id "$truth_id" '.ledger[]|select(.id==$id)' <<<"$ticket")
    [ -n "$row" ] || refuse 'unknown truth id'
    jq -e '.layers[3].state == "passed" and .layers[4].state == "passed"' <<<"$ticket" >/dev/null || refuse 'production and QA must be current'
    [ "$actor" != "$(jq -r '.layers[3].actor' <<<"$ticket")" ] || refuse 'maker cannot observe'
    [ "$actor" = "$(jq -r '.owner' <<<"$row")" ] || refuse 'wrong proof owner'
    case "$status" in
      PROVEN)
        if [ "$(jq -r '.proof' <<<"$row")" = desktop ]; then
          [ -n "$baseline" ] && [ -n "$after" ] || refuse 'PROVEN desktop truth needs baseline and after'
        fi ;;
      GAP|NOT_DETERMINED|NOT_RUN) [ -n "$reason" ] || refuse 'non-PROVEN status needs a reason' ;;
      *) bad_usage 'explicit observation status required' ;;
    esac
    bindings='[]'
    while IFS= read -r path; do
      binding=$(file_binding "$path" evidence)
      bindings=$(jq -c --argjson b "$binding" '. + [$b]' <<<"$bindings")
    done < <(jq -r '.[]' <<<"$evidence")
    for role in baseline after; do
      path=$baseline; [ "$role" != after ] || path=$after
      if [ -n "$path" ]; then
        binding=$(file_binding "$path" "$role")
        bindings=$(jq -c --argjson b "$binding" '. + [$b]' <<<"$bindings")
      fi
    done
    [ "$status" != PROVEN ] || [ "$(jq 'length' <<<"$bindings")" -gt 0 ] || refuse 'PROVEN needs evidence'
    ticket=$(jq --arg id "$truth_id" --arg by "$actor" --arg status "$status" --arg version "$version" \
      --arg reason "$reason" --argjson synthetic "$synthetic" --argjson evidence "$bindings" --argjson at "$now" '
      .ledger |= map(if .id==$id then
        (if .observation != null then .history += [.observation] else . end) |
        .observation={by:$by,status:$status,version:$version,reason:$reason,synthetic:$synthetic,evidence:$evidence,at:$at,state:"current"}
        else . end) |
      .layers |= [to_entries[]|if .key>=5 and .value.at!=null then .value.state="stale" else . end|.value]' <<<"$ticket")
    ;;
  return)
    [ -n "$actor" ] || bad_usage 'return actor required'
    case "$code" in
      intent) index=0 ;; approach) index=2 ;; craft) index=3 ;; proof) index=5 ;; environment) index=-1 ;;
      *) bad_usage 'invalid return code' ;;
    esac
    count=$(jq --argjson i "$index" '[.returns[]|select(.index==$i)]|length' <<<"$ticket")
    escalate=false
    if [ "$index" -ge 0 ] && [ "$count" -ge 2 ]; then escalate=true; fi
    ticket=$(jq --arg code "$code" --arg by "$actor" --arg note "$note" --argjson i "$index" \
      --argjson at "$now" --argjson escalate "$escalate" '
      .returns += [{code:$code,index:$i,by:$by,note:$note,at:$at,escalate:$escalate,
        reopened:(if $i<0 or $escalate then null else .layers[$i].layer end)}] |
      if $i>=0 and ($escalate|not) then
        .layers |= [to_entries[]|if .key==$i then .value.state="open" elif .key>$i and .value.at!=null then .value.state="stale" else . end|.value] |
        .ledger |= map(if .observation != null then .observation.state="stale" else . end) |
        if $i<=2 then .ledger_frozen=false else . end
      else . end' <<<"$ticket")
    write_ticket
    [ "$escalate" = false ] || exit 11
    exit 0
    ;;
esac
write_ticket
