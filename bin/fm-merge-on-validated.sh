#!/usr/bin/env bash
# fm-merge-on-validated.sh - merge a validated dev pull request in code instead
# of waiting for a supervisor wake, behind an opt-in, dry-run-first hook.
#
# Usage:
#   fm-merge-on-validated.sh [scan]
#   fm-merge-on-validated.sh arm
#   fm-merge-on-validated.sh disarm
#   fm-merge-on-validated.sh --help
#
# The hook is OFF unless config/merge-on-validated exists in this home. The
# file holds one word: `dry-run` (also what an empty file means) or `live`.
# Anything else is refused and the hook stays inert. The file is local,
# gitignored, and never inherited by a secondmate home (docs/configuration.md
# "Merge on validated").
#
# `scan` reads the status log of every secondmate registered in this home
# (state/<id>.meta with kind=secondmate) from a per-log byte cursor. The first
# time a log is seen the cursor starts at its end, so history is never replayed;
# only `validated` lines appended afterwards are acted on. A line is acted on
# only when its state word is exactly `validated` (validated-detail,
# validated-then-conflicting, and a child's `done` outcome are not), and only
# when it carries one GitHub pull request URL followed by ` head <40-hex sha>`.
#
# The standing dev-merge test is then read live, never from the status line:
#   - one ship task records pr=, or one unbound ship task matches the live
#     headRefName to its metadata branch when no task records pr=;
#   - that task is yolo (merge authority stays with the captain otherwise);
#   - the task is not held for the captain;
#   - the PR is open, not a draft, and its base is exactly `dev`;
#   - the live head equals the validated sha;
#   - the validated line does not say "security-sensitive" or "security sensitive",
#     and no PR label contains "security" (title/body prose is not authority);
#   - the latest state/review-verdicts.jsonl entry for this PR and exact head
#     says merge, recorded by fm-review-verdict.sh after a second-model review;
#     alternatively, the validator attests its review verdict was applied;
#     a recorded fix always refuses. Without either verdict, only a complete
#     test/spec-only diff is exempt;
#   - every check is green by bin/fm-pr-lib.sh's fm_pr_github_checks_not_green,
#     and at least one check exists;
#   - no reviewer's latest approving-or-blocking review requests changes, and
#     the review decision is not CHANGES_REQUESTED;
#   - no review thread is unresolved (outdated or not), and at most 100 exist;
#   - the PR is MERGEABLE (an UNKNOWN answer is re-read a few times);
#   - VISION.md at the head is byte-identical (same blob) to VISION.md at the
#     base tip, or absent from both.
# Every failing condition that could be read is reported, joined with "; ".
#
# Dry-run only appends to state/merge-on-validated.log:
#   <utc> would merge <url> <sha>
#   <utc> would not merge: <reason> [<url> <sha>]
# It never calls a merge command and prints nothing, so it never wakes anyone.
#
# Live mode appends `not merged: <reason> [...]` for a failed test, and for a
# passing one calls bin/fm-pr-merge.sh <task> <url> with no extra arguments -
# never a lower-level merge, never --allow-red, --auto, --admin or an
# attended override - then logs `merged <url> <sha>` or `merge refused by
# fm-pr-merge: <first error>`. Live mode prints ONE line when a merge landed or
# fm-pr-merge refused a PR that passed the test, which the watcher turns into a
# `check:` wake: teardown, the backlog record, and any Linear record stay with
# the supervisor. A passing live attempt is saved before its cursor advances;
# a killed scan retries safely by checking the live PR state before merging.
# FM_PR_MERGE_EXPECTED_HEAD binds the guarded merge to the validated/reviewed head.
#
# `arm` writes state/merge-on-validated.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on the normal
# FM_CHECK_INTERVAL cadence; it requires a valid config file. `disarm` removes
# the shim and its trust binding and leaves the log and cursor in place.
#
# Bounds: scan stops starting new lines once FM_MERGE_ON_VALIDATED_BUDGET_SECS
# (default 45, cut to FM_CHECK_TIMEOUT minus 5 when that is smaller) is spent,
# leaving the rest for the next poll; each forge call is bounded by
# FM_MERGE_ON_VALIDATED_GH_SECS (default 8). A line whose live state cannot be
# read is retried on later polls and logged as `would not merge` / `not merged`
# after three unreadable attempts so one broken PR cannot block the log.
# Transient refusals (pending/missing checks or review, DIRTY/UNKNOWN mergeability,
# unreadable forge state, and a moved head) are kept as JSONL {pr,head,line} in
# state/.merge-on-validated.pending, one record per PR, under the scan lock.
# Later scans re-evaluate these without another validated line. A successful
# dry-run or merge, a permanent refusal, or a changed head on recheck retires the
# record; an initial moved-head read is retained for one recheck. Red completed
# checks, security markers, authority/hold refusals, and review fix are permanent.
# A new validated event can replace a pending PR's head. Original status text is
# retained so retry never drops its security marker. Scan budget applies to both
# retries and new lines; existing pending records are checked first.
# A VM review attestation is a standalone `review verdict applied` or
# `review verdict was applied` clause after `head <sha>`, case-insensitive,
# delimited by a comma, semicolon, pipe, or the end of the line. It authorizes
# only that validated PR/head, never another head or a recorded fix.
# The watcher's registered merge check defaults to a 50s timeout so its 45s
# scan budget is usable; an explicit FM_CHECK_TIMEOUT still bounds the scan.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/merge-on-validated"
LOG="$STATE/merge-on-validated.log"
CURSOR="$STATE/.merge-on-validated.cursor"
PENDING="$STATE/.merge-on-validated.pending"
LOCK="$STATE/.merge-on-validated.lock"
CHECK_ID=merge-on-validated
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
DEV_BASE=dev
MAX_ATTEMPTS=3
MIN_LINE_SECS=10
MAX_THREADS=100
HEAD_RE='(https://[^[:space:])]+/pull/[0-9]+)[[:space:]]+head[[:space:]]+([0-9a-f]{40})([^0-9a-f]|$)'
# shellcheck disable=SC2016  # GraphQL variables, not shell expansions.
THREADS_QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){totalCount nodes{isResolved}}}}}'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-merge-on-validated.sh [scan]   act on new `validated` lines from secondmate status logs
  fm-merge-on-validated.sh arm      write and register state/merge-on-validated.check.sh
  fm-merge-on-validated.sh disarm   remove the check shim and its trust binding
  fm-merge-on-validated.sh --help   print this help

Off unless config/merge-on-validated exists; its one word is `dry-run` (default) or `live`.
See docs/configuration.md "Merge on validated".
EOF
}

die_usage() {
  printf 'fm-merge-on-validated: %s\n' "$1" >&2
  usage >&2
  exit 2
}

now_epoch() { date +%s; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_line() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s %s\n' "$(now_utc)" "$1" >> "$LOG"
}

# Prints dry-run or live. Returns 1 when the hook is not enabled, 2 when the
# file is present but not a single valid setting.
config_mode() {
  local line setting=''
  [ -f "$CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    [ -z "$setting" ] || return 2
    setting=$line
  done < "$CONFIG"
  case "$setting" in
    ''|dry-run) printf 'dry-run\n' ;;
    live) printf 'live\n' ;;
    *) return 2 ;;
  esac
}

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# --- bounded forge reads ----------------------------------------------------

DEADLINE=0
GH_SECS=${FM_MERGE_ON_VALIDATED_GH_SECS:-8}

budget_left() {
  local left=$((DEADLINE - $(now_epoch)))
  [ "$left" -gt 0 ] || left=0
  printf '%s\n' "$left"
}

gh_run() {
  local left secs
  left=$(budget_left)
  [ "$left" -gt 0 ] || return 124
  secs=$GH_SECS
  [ "$left" -ge "$secs" ] || secs=$left
  fm_run_timed "$secs" gh "$@" </dev/null
}

# --- cursor -----------------------------------------------------------------

cursor_get() {  # <id> -> "<offset> <attempts>" or nothing
  [ -f "$CURSOR" ] || return 0
  awk -v id="$1" '$1 == id { print $2, $3; exit }' "$CURSOR"
}

cursor_set() {  # <id> <offset> <attempts>
  local tmp
  tmp=$(mktemp "$STATE/.merge-on-validated.cursor.XXXXXX") || return 1
  if {
    [ ! -f "$CURSOR" ] || awk -v id="$1" '$1 != id' "$CURSOR"
    printf '%s %s %s\n' "$1" "$2" "$3"
  } > "$tmp"; then
    mv -f -- "$tmp" "$CURSOR" && return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# --- the standing dev-merge test --------------------------------------------

EV_URL=
EV_SHA=
EV_TASK=
EV_REASON=
EV_JSON=
EV_RETRY=0
EV_PERMANENT=0
EV_HEAD_CHANGED=0

add_retry() {
  EV_RETRY=1
  EV_REASON="${EV_REASON:+$EV_REASON; }$1"
}

add_reason() {
  EV_PERMANENT=1
  EV_REASON="${EV_REASON:+$EV_REASON; }$1"
}

# Finds the one ship task in this home that records the PR. Sets EV_TASK.
find_task() {
  local f id found=0 pr kind branch
  EV_TASK=
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    pr=$(meta_value "$f" pr)
    [ "$pr" = "$EV_URL" ] || continue
    kind=$(meta_value "$f" kind)
    [ "$kind" != secondmate ] || continue
    id=$(basename "$f" .meta)
    fm_pr_task_id_valid "$id" || continue
    found=$((found + 1))
    EV_TASK=$id
  done
  if [ "$found" -eq 0 ]; then
    # The direct-PR path may not have recorded pr= yet. Resolve the live branch
    # only in that case; an explicit PR binding always takes precedence.
    branch=$(jqf '.headRefName // ""') || return 2
    [ -n "$branch" ] && [ "$branch" != null ] || return 2
    for f in "$STATE"/*.meta; do
      [ -f "$f" ] || continue
      [ "$(meta_value "$f" kind)" = ship ] || continue
      [ -z "$(meta_value "$f" pr)" ] || continue
      [ "$(meta_value "$f" branch)" = "$branch" ] || continue
      id=$(basename "$f" .meta)
      fm_pr_task_id_valid "$id" || continue
      found=$((found + 1))
      EV_TASK=$id
    done
  fi
  case "$found" in
    1) return 0 ;;
    0) add_reason "no task in this home records this pull request or its head branch"; EV_TASK= ;;
    *) add_reason "more than one task records this pull request or its head branch"; EV_TASK= ;;
  esac
  return 1
}

check_task() {  # sets reasons; uses EV_TASK
  local meta="$STATE/$EV_TASK.meta" kind yolo hold_rc=0
  kind=$(meta_value "$meta" kind)
  [ "$kind" = ship ] || add_reason "task $EV_TASK is not a ship task"
  yolo=$(meta_value "$meta" yolo)
  [ "$yolo" = on ] || add_reason "task $EV_TASK is not yolo, so merge authority stays with the captain"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$EV_TASK" --distinguish-absent >/dev/null 2>&1 </dev/null \
    || hold_rc=$?
  case "$hold_rc" in
    0) add_reason "task $EV_TASK is held for the captain" ;;
    1|3) ;;
    *) add_retry "could not tell whether task $EV_TASK is held for the captain" ;;
  esac
}

jqf() {  # <filter> over EV_JSON
  printf '%s' "$EV_JSON" | jq -r "$1" 2>/dev/null
}

vision_blob() {  # <ref> -> blob sha, or "absent"; returns 1 when unreadable
  local out rc=0
  out=$(gh_run api "repos/$FM_PR_OWNER/$FM_PR_REPO/contents/VISION.md?ref=$1" --jq .sha 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *"HTTP 404"*|*"Not Found"*) printf 'absent\n'; return 0 ;;
  esac
  return 1
}

# The latest valid verdict for this canonical PR and exact head is authoritative.
# Test-only exemptions require a complete forge file list, including rename sources.
check_review_verdict() {
  local verdict='' files count review_text
  review_text=${EV_LINE#*" head $EV_SHA"}
  if [ -f "$STATE/review-verdicts.jsonl" ]; then
    verdict=$(jq -Rrs --arg pr "$EV_URL" --arg head "$EV_SHA" '
      [split("\n")[] | fromjson? | select(.pr == $pr and .head == $head)
       | select(.verdict == "merge" or .verdict == "fix")] | last | .verdict // ""' \
      "$STATE/review-verdicts.jsonl" 2>/dev/null) || verdict=''
  fi
  case "$verdict" in
    merge) return 0 ;;
    fix) add_reason "second-model review says fix for this head"; return 0 ;;
  esac
  # A registered validator can attest that its independent review verdict was
  # applied to this exact validated head. Require a standalone affirmative
  # clause, so "not applied", instructions, and incidental prose do not count.
  if printf '%s\n' "$review_text" | grep -qiE '(^|[;|,:])[[:space:]]*review verdict (was )?applied[[:space:]]*([;|,.]|$)'; then
    return 0
  fi
  count=$(jqf '.changedFiles // 0')
  if files=$(gh_run api "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/files?per_page=100" --paginate --slurp) \
    && printf '%s' "$files" | jq -e --argjson count "$count" '
      add | length == $count and length > 0' >/dev/null 2>&1; then
    if printf '%s' "$files" | jq -e '
      def testfile: type == "string" and
        test("(^|/)(test_[^/]+\\.[^/]+|[^/]+[._-](test|spec)\\.[^/]+)$|(^|/)(tests?|specs?)/.*\\.(sh|[cm]?[jt]sx?|py|rb|go|rs|java|kt|swift|c|cpp)$");
      add | all(.[]; (.filename | testfile) and
        (if has("previous_filename") then (.previous_filename | testfile) else true end))' >/dev/null 2>&1; then
      return 0
    fi
  fi
  add_retry "missing second-model merge verdict for this head (diff is not verified test-only)"
}

# Reads the live pull request and appends every failing condition to EV_REASON.
# Returns 2 when the live state could not be read at all.
check_live() {
  local state draft mergeable merge_state base head decision red nchecks blocking check_reason
  local tries=0 sleep_secs=${FM_MERGE_ON_VALIDATED_UNKNOWN_SLEEP:-3}
  local threads total open vbase vhead

  while :; do
    EV_JSON=$(gh_run pr view "$EV_URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDecision,reviews,labels,changedFiles) \
      || { EV_REASON="could not read the live pull request"; return 2; }
    mergeable=$(jqf '.mergeable // ""')
    # GitHub answers UNKNOWN for a closed or merged pull request for good, so
    # only an open one is worth waiting on.
    [ "$mergeable" = UNKNOWN ] && [ "$(jqf '.state // ""')" = OPEN ] || break
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || break
    sleep "$sleep_secs"
  done
  merge_state=$(jqf '.mergeStateStatus // ""')
  state=$(jqf '.state // ""')
  draft=$(jqf 'if .isDraft == true then "true" elif .isDraft == false then "false" else "" end')
  base=$(jqf '.baseRefName // ""')
  head=$(jqf '.headRefOid // ""')
  decision=$(jqf '.reviewDecision // ""')
  if [ -z "$state" ] || [ -z "$base" ] || ! fm_pr_head_valid "$head"; then
    EV_REASON="could not read the live pull request"
    return 2
  fi

  if [ "$state" = MERGED ]; then
    add_reason "already merged"
    return 1
  fi
  [ "$state" = OPEN ] || add_reason "pull request state is $state, not OPEN"
  [ "$draft" = false ] || add_reason "pull request is a draft or its draft state is unreadable"
  [ "$base" = "$DEV_BASE" ] || add_reason "base is '$base', not $DEV_BASE"
  if [ "$head" != "$EV_SHA" ]; then
    EV_HEAD_CHANGED=1
    add_retry "live head ${head:0:12} is not the validated head ${EV_SHA:0:12}"
  fi
  # The remaining reads describe a head or base that will not be merged.
  if [ "$state" != OPEN ] || [ "$base" != "$DEV_BASE" ] || [ "$head" != "$EV_SHA" ]; then
    return 1
  fi

  if [ "$(jqf 'any(.labels[]?; (.name // "") | test("security"; "i"))')" = true ]; then
    add_reason "marked security-sensitive on the pull request"
  fi
  check_review_verdict

  if red=$(fm_pr_github_checks_not_green "$EV_JSON"); then
    nchecks=$(jqf '.statusCheckRollup | length')
    if [ "${nchecks:-0}" -eq 0 ]; then
      add_retry "no checks are reported at the head"
    fi
    if [ -n "$red" ]; then
      check_reason="checks not green: $(printf '%s' "$red" | paste -sd, - | sed 's/,/, /g')"
      if [ "$(jqf 'any(.statusCheckRollup[]?;
          (.__typename == "CheckRun" and .status == "COMPLETED" and
            (.conclusion != "SUCCESS" and .conclusion != "NEUTRAL" and .conclusion != "SKIPPED"))
          or (.__typename == "StatusContext" and (.state == "ERROR" or .state == "FAILURE")))')" = true ]; then
        add_reason "$check_reason"
      else
        add_retry "$check_reason"
      fi
    fi
  else
    add_retry "could not read the check results"
  fi

  blocking=$(jqf '[.reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")] | group_by(.author.login) | map(sort_by(.submittedAt) | last) | map(select(.state == "CHANGES_REQUESTED") | (.author.login // "unknown")) | join(", ")')
  if [ -n "$blocking" ] || [ "$decision" = CHANGES_REQUESTED ]; then
    add_reason "review of record requests changes${blocking:+ ($blocking)}"
  fi

  if threads=$(gh_run api graphql -f "query=$THREADS_QUERY" -F "owner=$FM_PR_OWNER" -F "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER") \
    && total=$(printf '%s' "$threads" | jq -r '.data.repository.pullRequest.reviewThreads.totalCount | tostring' 2>/dev/null) \
    && open=$(printf '%s' "$threads" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length' 2>/dev/null) \
    && [ -n "$total" ] && [ -n "$open" ]; then
    if [ "$total" -gt "$MAX_THREADS" ]; then
      add_reason "more than $MAX_THREADS review threads, so none can be verified resolved"
    elif [ "$open" -gt 0 ]; then
      add_reason "$open open review thread(s)"
    fi
  else
    add_retry "could not read the review threads"
  fi

  case "$mergeable:$merge_state" in
    *:DIRTY|UNKNOWN:*|:*) add_retry "mergeable is ${mergeable:-unreadable}, state ${merge_state:-unreadable}, not MERGEABLE" ;;
    MERGEABLE:*) ;;
    *) add_reason "mergeable is $mergeable, not MERGEABLE" ;;
  esac

  if vbase=$(vision_blob "$base") && vhead=$(vision_blob "$head"); then
    [ "$vbase" = "$vhead" ] || add_reason "VISION.md differs from the $base tip"
  else
    add_retry "could not read VISION.md at the head and the base"
  fi
  [ -z "$EV_REASON" ]
}

# Parses one status line, then runs the test. Returns 0 when the test passes,
# 1 when it refuses (EV_REASON set), 2 when the live state could not be read.
evaluate() {  # <status-line>
  local line=$1 body urls nurls
  EV_URL=
  EV_SHA=
  EV_TASK=
  EV_REASON=
  EV_JSON=
  EV_RETRY=0
  EV_PERMANENT=0
  EV_HEAD_CHANGED=0
  EV_LINE=$line
  body=${line#*]: }
  urls=$(printf '%s\n' "$body" | grep -oE 'https://[^[:space:])]+/(pull|merge_requests)/[0-9]+' | sort -u)
  nurls=$(printf '%s' "$urls" | grep -c . || true)
  if [ "$nurls" -gt 1 ]; then
    EV_REASON="the validated line names more than one pull request"
    return 1
  fi
  if [[ "$body" =~ $HEAD_RE ]]; then
    EV_URL=${BASH_REMATCH[1]}
    EV_SHA=${BASH_REMATCH[2]}
  else
    EV_REASON="the validated line has no '<pull request URL> head <40-hex sha>'"
    return 1
  fi
  if ! fm_pr_url_parse "$EV_URL" || [ "$FM_PR_PROVIDER" != github ]; then
    EV_REASON="not a GitHub pull request URL"
    return 1
  fi
  if printf '%s\n' "$line" | grep -qiE 'security[- ]sensitive'; then
    add_reason "marked security-sensitive in the validated line"
  fi
  local own=$EV_REASON rc=0 find_rc=0
  EV_REASON=
  # Read state first: a merged PR no longer needs a live task in this home.
  check_live || rc=$?
  [ "$rc" -ne 2 ] || return 2
  if [ "$(jqf '.state // ""')" != OPEN ]; then
    return 1
  fi
  if [ -n "$own" ]; then
    EV_REASON="$own${EV_REASON:+; $EV_REASON}"
  fi
  find_task || find_rc=$?
  if [ "$find_rc" -eq 2 ]; then
    add_retry "could not read the live pull request branch"
    return 2
  elif [ "$find_rc" -eq 0 ]; then
    check_task
  fi
  [ -z "$EV_REASON" ]
}

# --- one validated line -----------------------------------------------------

MODE=dry-run
WAKES=

add_wake() {
  WAKES="${WAKES:+$WAKES | }merge-on-validated: $1"
}

where_suffix() {
  [ -z "$EV_URL" ] || printf ' [%s %s]' "$EV_URL" "$EV_SHA"
}

# One bounded-size record per PR, replaced by a new validated head. Original
# status text preserves its security marker. All writes hold the scan lock.
pending_set() {  # <line>; empty line removes this PR
  local tmp
  [ -n "$EV_URL" ] || return 0
  tmp=$(umask 077; mktemp "$STATE/.merge-on-validated.pending.XXXXXX") || return 1
  if { [ ! -f "$PENDING" ] || jq -c --arg pr "$EV_URL" 'select(.pr != $pr)' "$PENDING"; } > "$tmp"; then
    if [ -n "$1" ]; then
      jq -nc --arg pr "$EV_URL" --arg head "$EV_SHA" --arg line "$1" \
        '{pr:$pr,head:$head,line:$line}' >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f -- "$tmp" "$PENDING" && return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Called with the verdict of evaluate. $1 is the cursor writer to run before a
# live merge starts. Pending retries re-read live PR state before another attempt.
act_on_verdict() {  # <evaluate-rc> <advance-command...>
  local rc=$1 out merge_rc=0 first
  shift
  if [ "$rc" -ne 0 ]; then
    if [ "$MODE" = live ]; then
      log_line "not merged: $EV_REASON$(where_suffix)"
    else
      log_line "would not merge: $EV_REASON$(where_suffix)"
    fi
    return 0
  fi
  if [ "$MODE" = dry-run ]; then
    log_line "would merge $EV_URL $EV_SHA"
    return 0
  fi
  if ! "$@"; then
    log_line "not merged: could not advance the cursor, so the merge was not attempted [$EV_URL $EV_SHA]"
    return 0
  fi
  log_line "merging $EV_URL $EV_SHA task=$EV_TASK"
  out=$(FM_HOME="$FM_HOME" FM_PR_MERGE_EXPECTED_HEAD="$EV_SHA" "$SCRIPT_DIR/fm-pr-merge.sh" "$EV_TASK" "$EV_URL" 2>&1 </dev/null) || merge_rc=$?
  if [ "$merge_rc" -eq 0 ]; then
    pending_set "" || return 1
    log_line "merged $EV_URL $EV_SHA"
    add_wake "merged $EV_URL at $EV_SHA (task $EV_TASK); teardown and the Linear record are pending"
  else
    first=$(printf '%s\n' "$out" | grep -m1 -E '^(error|actionable)' | cut -c1-200)
    [ -n "$first" ] || first=$(printf '%s\n' "$out" | head -n 1 | cut -c1-200)
    log_line "merge refused by fm-pr-merge: ${first:-exit $merge_rc} [$EV_URL $EV_SHA]"
    case "$out" in
      *UNKNOWN*|*DIRTY*|*[Pp]ending*|*"not green"*|*"head moved"*|*"head changed"*) ;;
      *) pending_set "" || return 1 ;;
    esac
    add_wake "fm-pr-merge refused $EV_URL at $EV_SHA (task $EV_TASK): ${first:-exit $merge_rc}"
  fi
}

# Persist before advancing or merging so a killed scan resumes safely. A changed
# head is retained once, then retired on recheck: old validation never blesses it.
handle_verdict() {  # <rc> <line> <is-pending> <advance-command...>
  local rc=$1 line=$2 is_pending=$3
  shift 3
  if [ "$is_pending" -eq 1 ] && [ "$EV_HEAD_CHANGED" -eq 1 ]; then
    pending_set "" || return 1
    log_line "not merged: pending validated head changed$(where_suffix)"
    return 0
  fi
  if [ "$EV_PERMANENT" -eq 0 ] && { [ "$EV_RETRY" -eq 1 ] || [ "$rc" -eq 2 ] || { [ "$rc" -eq 0 ] && [ "$MODE" = live ]; }; }; then
    pending_set "$line" || return 1
  else
    pending_set "" || return 1
  fi
  act_on_verdict "$rc" "$@"
}

scan_pending() {
  local snapshot row line rc
  [ -s "$PENDING" ] || return 0
  snapshot=$(mktemp "$STATE/.merge-on-validated.retry.XXXXXX") || return 1
  cp "$PENDING" "$snapshot" || { rm -f "$snapshot"; return 1; }
  while IFS= read -r row; do
    [ "$(budget_left)" -ge "$MIN_LINE_SECS" ] || break
    line=$(printf '%s' "$row" | jq -er .line) || continue
    rc=0
    evaluate "$line" || rc=$?
    handle_verdict "$rc" "$line" 1 true || break
  done < "$snapshot"
  rm -f -- "$snapshot"
}

# --- scan -------------------------------------------------------------------

scan_log() {  # <secondmate-id>; returns 1 to stop the whole scan
  local id=$1 file size cur off att chunk line newoff rc stop=0
  file="$STATE/$id.status"
  [ -f "$file" ] || return 0
  size=$(wc -c < "$file" | tr -d '[:space:]')
  cur=$(cursor_get "$id")
  if [ -z "$cur" ]; then
    cursor_set "$id" "$size" 0
    log_line "watching the status log of $id from now (byte $size)"
    return 0
  fi
  off=${cur% *}
  att=${cur#* }
  if [ "$size" -lt "$off" ]; then
    cursor_set "$id" "$size" 0
    log_line "the status log of $id shrank; resumed at its end (byte $size)"
    return 0
  fi
  [ "$size" -gt "$off" ] || return 0

  chunk=$(mktemp "$STATE/.merge-on-validated.chunk.XXXXXX") || return 0
  tail -c +$((off + 1)) "$file" | head -c $((size - off)) > "$chunk"
  while IFS= read -r line <&3; do
    newoff=$((off + ${#line} + 1))
    case "$line" in
      "validated ["*|"validated:"*)
        if [ "$(budget_left)" -lt "$MIN_LINE_SECS" ]; then
          log_line "scan budget exhausted; validated line deferred ($id byte $off)"
          stop=1
          break
        fi
        rc=0
        evaluate "$line" || rc=$?
        if [ "$rc" -eq 2 ]; then
          att=$((att + 1))
          if [ "$att" -lt "$MAX_ATTEMPTS" ]; then
            stop=1
            break
          fi
          EV_REASON="the live pull request could not be read after $MAX_ATTEMPTS attempts"
          EV_RETRY=1
          rc=1
        fi
        handle_verdict "$rc" "$line" 0 cursor_set "$id" "$newoff" 0 || { stop=1; break; }
        att=0
        ;;
    esac
    off=$newoff
    cursor_set "$id" "$off" 0
  done 3< "$chunk"
  rm -f -- "$chunk"
  if [ "$stop" -eq 1 ]; then
    cursor_set "$id" "$off" "$att"
    return 1
  fi
  return 0
}

action_scan() {
  local mode_rc=0 left budget f id check_timeout
  MODE=$(config_mode) || mode_rc=$?
  case "$mode_rc" in
    0) ;;
    1) return 0 ;;
    *)
      printf 'fm-merge-on-validated: %s must hold one word, dry-run or live; the hook is inert\n' "$CONFIG" >&2
      return 2
      ;;
  esac
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'fm-merge-on-validated: gh and jq are required\n' >&2
    return 1
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || return 0
  trap 'fm_lock_release "$LOCK"' EXIT

  budget=${FM_MERGE_ON_VALIDATED_BUDGET_SECS:-45}
  check_timeout=${FM_CHECK_TIMEOUT:-50}
  case "$budget$check_timeout" in *[!0-9]*|'') budget=45; check_timeout=50 ;; esac
  left=$((check_timeout - 5))
  [ "$left" -ge 5 ] || left=5
  [ "$budget" -le "$left" ] || budget=$left
  DEADLINE=$(( $(now_epoch) + budget ))

  scan_pending
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    [ "$(meta_value "$f" kind)" = secondmate ] || continue
    id=$(basename "$f" .meta)
    fm_pr_task_id_valid "$id" || continue
    scan_log "$id" || break
  done
  [ -z "$WAKES" ] || printf '%s\n' "$WAKES"
  return 0
}

# --- arm / disarm -----------------------------------------------------------

action_arm() {
  local mode_rc=0 home device tmp
  config_mode >/dev/null || mode_rc=$?
  if [ "$mode_rc" -ne 0 ]; then
    printf 'fm-merge-on-validated: write %s (one word: dry-run or live) before arming\n' "$CONFIG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-merge-on-validated-check.XXXXXX") || return 1
  if ! {
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      '# Auto-generated by fm-merge-on-validated.sh - merge-on-validated poll shim.' \
      '# The watcher validates these bytes, then dispatches the trusted scan.' \
      "export FM_HOME=$(printf '%q' "$home")" \
      "exec $(printf '%q' "$SCRIPT_DIR/fm-merge-on-validated.sh") scan"
  } > "$tmp" || ! chmod 0700 "$tmp" || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-merge-on-validated: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$STATE/$CHECK_ID.check-trust"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-scan}" in
  scan) action_scan ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
