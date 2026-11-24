#!/usr/bin/env bash
# fm-review-capacity-lib.sh - how many unreviewed fleet pull requests a GitHub
# project may have open before bin/fm-spawn.sh stops admitting another
# publishing ship for it.
#
# The fleet's goal is landed pull requests, not busy workers. A pull request
# nobody has reviewed is work the captain still owes attention to, so once a
# project's review queue is full a new publishing worker only adds to it.
# bin/fm-spawn.sh therefore defers a fresh publishing ship while the project's
# review queue is at its cap, and the task keeps its queued backlog item until
# a place frees. Idling at the cap is the intended outcome (AGENTS.md section 7).
#
# This file is the single owner of the cap's declaration, of what holds a place
# in the review queue, of the forge observation, and of how an unknown or
# incomplete observation is judged. docs/configuration.md "Review capacity" is
# the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Which spawns are judged: a fresh (not --relaunch) ship whose task mode
# publishes a pull request (no-mistakes or direct-PR), whose project's registered
# forge is the default pull-request forge (bin/fm-project-mode.sh --forge none),
# and whose publication target is a GitHub repository: the spawn's
# --upstream-consent <host>/<owner>/<repo> when it records one, otherwise the
# repository a default publication reaches (fm_role_publication_target in
# bin/fm-role-lib.sh), on github.com or a host listed in config/github-hosts.
# Scouts, local-only ships, relaunches, secondmates, Gerrit/Forgejo/external
# forges, local-path remotes, and non-GitHub hosts are not judged: they open no
# GitHub pull request this observation could see. A relaunch is the manual
# recovery path for a task that already exists, so it continues an existing
# pull request without being refused. A scout promoted in place by
# bin/fm-promote.sh does not pass through fm-spawn's fresh admission and is not
# judged either.
#
# Declaration: config/review-capacity in the local root Firstmate home (the same
# directory config/project-capacity is read from; fm_project_capacity_config_dir
# in bin/fm-project-capacity-lib.sh), one `<project-name> <cap>` line per
# project in exactly config/project-capacity's format, parsed by the same
# fm_project_capacity_lookup, with the same refusal of an unreadable file. A
# project the file does not name, or a home without the file, has the default
# cap of FM_REVIEW_CAPACITY_DEFAULT (3). The cap is per project; there is no
# off switch, and a large number lifts it in practice.
#
# Holders: the review queue of the publication target is held by
#   - every OPEN pull request in the target repository whose head branch is a
#     fleet branch - its name starts with the spawn's own ship-branch prefix,
#     the project's registered prefix (bin/fm-project-mode.sh --branch-prefix),
#     or the default fm/, or it is exactly the recorded branch of a local task
#     record for the target (which is how an empty registered prefix is still
#     recognized) - and that is not approved. Head names are compared exactly,
#     in a lossless percent-encoding, so every valid ref character (such as +)
#     keeps its identity. Every base branch counts. "Approved" follows GitHub's
#     own reviewDecision when the repository reports one: APPROVED frees the
#     place, draft or not, while CHANGES_REQUESTED and REVIEW_REQUIRED hold it,
#     so a stale approval GitHub dismissed on a new push no longer frees
#     anything. With no reviewDecision (no required review), the place frees
#     only when a latest opinionated review is APPROVED on the pull request's
#     current head commit; a draft or a pull request whose only approval is of
#     an older head holds its place.
#   - every reservation: a ship task record (any mode but local-only, not a
#     secondmate) in any local Firstmate home on this machine
#     (fm_local_firstmate_state_dirs), other than the task being admitted, whose
#     publication target (its upstream_consent, else its project directory's
#     fm_role_publication_target) is the same repository - whatever origin its
#     clone uses - and whose recorded branch is not among the observed open
#     pull requests, when it has no recorded pr= handoff, or its record changed
#     at or after the observation began. Such a worker has not opened its pull
#     request yet, or opened it after the one read, so it still holds a place.
# A record whose branch IS an observed open pull request is counted once,
# through the forge, so a worker never double counts and never frees its place
# at PR-ready: its place moves from reservation to open pull request and frees
# only when the pull request is approved, merged, or closed. A record whose pr=
# handoff was recorded before the read and whose branch the read no longer
# lists has left the queue.
#
# Observation: exactly one bounded call per admission, through gh-axi's GraphQL
# passthrough, of at most FM_REVIEW_CAPACITY_PAGE (100) open pull requests,
# newest first, bounded to FM_REVIEW_CAPACITY_TIMEOUT seconds (default 20;
# bin/fm-timeout-lib.sh owns the bound). It is unknown when gh-axi is absent,
# the call fails or times out, the answer cannot be parsed, or gh-axi reports
# its body truncated. It is incomplete when the repository has more open pull
# requests than one page lists. An unknown or incomplete observation that has
# not already proven the queue at its cap defers rather than admits, because
# admitting on a missing count is exactly how the queue overflowed; a proven
# full queue defers as full. Both are exit 75, so the task stays queued and a
# later dispatch retries the observation.
#
# Race safety and limits: bin/fm-spawn.sh makes the forge call before taking
# any lock, then counts reservations while holding this machine's review
# admission lock for the publication target (fm_review_capacity_lock_path, in
# the local root home) and keeps holding it through metadata publication, so
# two spawns on this machine for one repository - from the same clone or from
# clones with different origins - can never both admit from one count. A local
# worker that records its pr= handoff while the read is in flight keeps its
# place by the record-change rule above. Neither the lock nor the record walk
# reaches another machine: a worker on another host that has not yet opened
# its pull request is invisible here until it does, and two hosts admitting at
# the same instant can each take the last place. The forge observation sees
# every host's published pull requests, so the overshoot is bounded by
# unpublished work on other hosts, and a pull request created outside the
# fleet under a fleet prefix is counted like any other.
#
# Requires bin/fm-project-capacity-lib.sh (the parser and config directory),
# bin/fm-wake-lib.sh (root home, local homes, fm_path_mtime), bin/fm-backend.sh
# (fm_meta_get), bin/fm-pr-lib.sh (fm_github_host_allowed,
# fm_pr_github_host_export), bin/fm-role-lib.sh (fm_role_publication_target),
# and bin/fm-timeout-lib.sh (fm_run_timed) to be sourced first. No side
# effects on source.

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_REVIEW_CAPACITY_DEFAULT=3
FM_REVIEW_CAPACITY_PAGE=100

# Resolve the GitHub repository a fresh publishing ship would open its pull
# request in. <consent> is the spawn's normalized --upstream-consent value or
# empty. Sets FM_REVIEW_TARGET_HOST, FM_REVIEW_TARGET_OWNER and
# FM_REVIEW_TARGET_REPO and returns 0 for a GitHub target; returns 1 with
# FM_REVIEW_TARGET_WHY when the target is not a GitHub repository.
fm_review_capacity_target() {  # <project-dir> <consent>
  local target=$2 host path
  FM_REVIEW_TARGET_HOST='' FM_REVIEW_TARGET_OWNER='' FM_REVIEW_TARGET_REPO='' FM_REVIEW_TARGET_WHY=''
  [ -n "$target" ] || target=$(fm_role_publication_target "$1")
  case "$target" in
    '') FM_REVIEW_TARGET_WHY="the project has no publication remote"; return 1 ;;
    path:*) FM_REVIEW_TARGET_WHY="the publication remote is a local path"; return 1 ;;
  esac
  host=${target%%/*}
  path=${target#*/}
  case "$path" in
    */*/* | /* | */ | *[!A-Za-z0-9._/-]*)
      FM_REVIEW_TARGET_WHY="the publication target $target is not a GitHub owner/repository"
      return 1
      ;;
    */*) ;;
    *)
      FM_REVIEW_TARGET_WHY="the publication target $target is not a GitHub owner/repository"
      return 1
      ;;
  esac
  if ! fm_github_host_allowed "$host"; then
    FM_REVIEW_TARGET_WHY="the publication host $host is not a GitHub host this home uses"
    return 1
  fi
  FM_REVIEW_TARGET_HOST=$host
  FM_REVIEW_TARGET_OWNER=${path%%/*}
  FM_REVIEW_TARGET_REPO=${path#*/}
  return 0
}

# One bounded observation of a GitHub repository's open pull requests.
# Sets FM_REVIEW_INVENTORY to space-separated <number>:<draft 0|1>:
# <approved|open>:<head-branch> entries, the head branch percent-encoded as
# jq's @uri does (fm_review_capacity_uri is the same encoding), so every valid
# ref character survives and no quote, space, or newline reaches the parser;
# FM_REVIEW_INVENTORY_AT to the epoch second just before the read;
# FM_REVIEW_INVENTORY_TOTAL to the
# repository's open count, FM_REVIEW_INVENTORY_COMPLETE to 1 when every open
# pull request was listed, else 0. Returns 1 with FM_REVIEW_INVENTORY_ERROR
# when the observation is unknown.
fm_review_capacity_observe() {  # <host> <owner> <repo>
  local host=$1 owner=$2 repo=$3 out rc body listed total query jq_expr
  FM_REVIEW_INVENTORY='' FM_REVIEW_INVENTORY_TOTAL='' FM_REVIEW_INVENTORY_COMPLETE=0 FM_REVIEW_INVENTORY_ERROR=''
  FM_REVIEW_INVENTORY_AT=$(date +%s)
  command -v gh-axi >/dev/null 2>&1 || {
    FM_REVIEW_INVENTORY_ERROR="gh-axi is not installed"
    return 1
  }
  query="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){pullRequests(states:OPEN,first:$FM_REVIEW_CAPACITY_PAGE,orderBy:{field:CREATED_AT,direction:DESC}){totalCount nodes{number headRefName headRefOid isDraft reviewDecision latestOpinionatedReviews(first:100){nodes{state commit{oid}}}}}}}"
  # The answer is reduced inside gh-axi's own jq to plain tokens; the head
  # name is percent-encoded, so it is kept exactly and still carries no quote,
  # backslash, space, or newline into the parser below.
  # shellcheck disable=SC2016 # jq variables, not shell expansions.
  jq_expr='.data.repository.pullRequests as $p | ([$p.nodes[] | . as $n | "\($n.number):\(if $n.isDraft then 1 else 0 end):\(if ($n.reviewDecision == "APPROVED") or ($n.reviewDecision == null and ([$n.latestOpinionatedReviews.nodes[] | select(.state == "APPROVED" and .commit.oid == $n.headRefOid)] | length) > 0) then "approved" else "open" end):\($n.headRefName | @uri)"] | "fm-review-inventory total=\($p.totalCount) listed=\($p.nodes | length) \(join(" "))")'
  rc=0
  out=$(
    fm_pr_github_host_export "$host"
    fm_run_timed "${FM_REVIEW_CAPACITY_TIMEOUT:-20}" gh-axi api graphql -X POST \
      --field query="$query" --field owner="$owner" --field name="$repo" \
      --jq "$jq_expr" --full </dev/null 2>/dev/null
  ) || rc=$?
  if [ "$rc" -eq 124 ]; then
    FM_REVIEW_INVENTORY_ERROR="the gh-axi call timed out after ${FM_REVIEW_CAPACITY_TIMEOUT:-20} s"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    FM_REVIEW_INVENTORY_ERROR="the gh-axi call failed with exit $rc"
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qx '  truncated: false'; then
    FM_REVIEW_INVENTORY_ERROR="gh-axi did not report a complete, untruncated answer"
    return 1
  fi
  body=$(printf '%s\n' "$out" | sed -n 's/^  body: "\{0,1\}\(fm-review-inventory [^"]*\)"\{0,1\}$/\1/p' | head -n 1)
  case "$body" in
    'fm-review-inventory total='*' listed='*) ;;
    *)
      FM_REVIEW_INVENTORY_ERROR="gh-axi's answer is not an open pull request inventory"
      return 1
      ;;
  esac
  body=${body#fm-review-inventory }
  total=${body%% *}
  total=${total#total=}
  body=${body#* }
  listed=${body%% *}
  listed=${listed#listed=}
  case "$body" in
    *' '*) body=${body#* } ;;
    *) body= ;;
  esac
  case "$total:$listed" in
    *[!0-9:]* | :* | *:)
      FM_REVIEW_INVENTORY_ERROR="gh-axi's answer is not an open pull request inventory"
      return 1
      ;;
  esac
  FM_REVIEW_INVENTORY=$body
  FM_REVIEW_INVENTORY_TOTAL=$total
  [ "$listed" -lt "$total" ] || FM_REVIEW_INVENTORY_COMPLETE=1
  return 0
}

# Percent-encode a string exactly as jq's @uri does: every byte outside
# A-Za-z0-9 - _ . ~ becomes %XX in upper-case hex. Encoding is per byte, so a
# prefix of a name encodes to a prefix of its encoding.
fm_review_capacity_uri() {  # <string>
  local LC_ALL=C s=$1 out='' c h i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) printf -v h '%%%02X' "'$c"; out+=${h: -3} ;;
    esac
  done
  printf '%s' "$out"
}

# The publication target a task record would open its pull request in, in
# lower case: its recorded upstream_consent, else the default publication target
# of its project directory (fm_role_publication_target). Empty when neither
# resolves.
fm_review_capacity_record_target() {  # <meta>
  local target project
  target=$(fm_meta_get "$1" upstream_consent)
  if [ -z "$target" ]; then
    project=$(fm_meta_get "$1" project)
    [ -n "$project" ] && [ -d "$project" ] || return 0
    target=$(fm_role_publication_target "$project")
  fi
  printf '%s' "$target" | tr '[:upper:]' '[:lower:]'
}

# The machine-wide lock that serializes review-queue admission for one
# publication target, in the local root home's state/ (fm_firstmate_root_home),
# so clones with different origins that publish to one repository share it.
fm_review_capacity_lock_path() {  # <home> <host> <owner> <repo>
  local root key
  root=$(fm_firstmate_root_home "$1") || return 1
  key=$(printf '%s_%s_%s' "$2" "$3" "$4" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_')
  printf '%s/state/.review-admission-%s.lock\n' "$root" "$key"
}

# Count the review-queue holders for one publication target from an
# observation already made by fm_review_capacity_observe (pass its exit status
# as <observed>, 0 or 1) plus this machine's task records. <target> is the
# lower-case host/owner/repo. <prefixes> is a space-separated list of fleet
# branch prefixes (empty ones are ignored). <first-state> and <own-id> are as in
# fm_project_capacity_occupants: the local homes come from
# fm_local_firstmate_state_dirs <first-state>, and the admitted task's own
# record is not counted. The caller holds fm_review_capacity_lock_path.
# A ship record (not local-only, not a secondmate) holds a reservation when its
# publication target (fm_review_capacity_record_target) is <target>, its
# recorded branch is not among the observed open pull requests, and either it
# has no pr= handoff or its record changed at or after the observation began
# (FM_REVIEW_INVENTORY_AT), since a handoff recorded after that read names a
# pull request the read could not have seen. Only a handoff already recorded
# before the read, whose branch the read no longer lists, has left the queue.
# Sets FM_REVIEW_HOLDERS (the count), FM_REVIEW_HOLDER_IDS (pull request
# numbers as #N and reservations as task ids), and FM_REVIEW_VERDICT to admit,
# full, or unknown, with FM_REVIEW_WHY naming the evidence for full or unknown.
# Returns 1 with FM_REVIEW_ERROR when the local homes or a record cannot be
# read, since skipping one could undercount.
fm_review_capacity_judge() {  # <cap> <observed> <target> <prefixes> <first-state> <own-id>
  local cap=$1 observed=$2 want=$3 prefixes=$4 first=$5 self=$6
  local state meta kind mode target id label branch pr mtime i entry num verdict head p fleet listed
  local -a rec_labels=() rec_branches=() rec_prs=() rec_mtimes=() enc_prefixes=()
  FM_REVIEW_HOLDERS=0 FM_REVIEW_HOLDER_IDS='' FM_REVIEW_VERDICT='' FM_REVIEW_WHY='' FM_REVIEW_ERROR=''
  fm_local_firstmate_state_dirs "$first" || {
    FM_REVIEW_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_REVIEW_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_REVIEW_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" = ship ] || continue
      mode=$(fm_meta_get "$meta" mode)
      [ "$mode" != local-only ] || continue
      target=$(fm_review_capacity_record_target "$meta")
      [ -n "$target" ] && [ "$target" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      mtime=$(fm_path_mtime "$meta") || mtime=
      rec_labels+=("$label")
      branch=$(fm_meta_get "$meta" branch)
      [ -z "$branch" ] || branch=$(fm_review_capacity_uri "$branch")
      rec_branches+=("$branch")
      rec_prs+=("$(fm_meta_get "$meta" pr)")
      rec_mtimes+=("$mtime")
    done
  done
  for p in $prefixes; do
    enc_prefixes+=("$(fm_review_capacity_uri "$p")")
  done
  # Open fleet pull requests without an approving review.
  listed=' '
  if [ "$observed" -eq 0 ]; then
    for entry in $FM_REVIEW_INVENTORY; do
      num=${entry%%:*}
      entry=${entry#*:}
      entry=${entry#*:}
      verdict=${entry%%:*}
      head=${entry#*:}
      listed="$listed$head "
      [ "$verdict" = open ] || continue
      fleet=0
      for p in ${enc_prefixes[@]+"${enc_prefixes[@]}"}; do
        case "$head" in "$p"*) fleet=1 ;; esac
      done
      i=0
      while [ "$fleet" -eq 0 ] && [ "$i" -lt "${#rec_branches[@]}" ]; do
        [ -z "${rec_branches[$i]}" ] || [ "${rec_branches[$i]}" != "$head" ] || fleet=1
        i=$((i + 1))
      done
      [ "$fleet" -eq 1 ] || continue
      FM_REVIEW_HOLDERS=$((FM_REVIEW_HOLDERS + 1))
      FM_REVIEW_HOLDER_IDS="${FM_REVIEW_HOLDER_IDS:+$FM_REVIEW_HOLDER_IDS, }#$num"
    done
  fi
  # Reservations on this machine. With no observation the open set is unknown,
  # so every record without a pr= handoff is a reservation.
  i=0
  while [ "$i" -lt "${#rec_labels[@]}" ]; do
    branch=${rec_branches[$i]}
    pr=${rec_prs[$i]}
    mtime=${rec_mtimes[$i]}
    if [ -n "$branch" ] && [ "$observed" -eq 0 ]; then
      case "$listed" in
        *" $branch "*) i=$((i + 1)); continue ;;
      esac
    fi
    if [ -z "$pr" ] || [ -z "$mtime" ] ||
      { [ "$observed" -eq 0 ] && [ "$mtime" -ge "${FM_REVIEW_INVENTORY_AT:-0}" ]; }; then
      FM_REVIEW_HOLDERS=$((FM_REVIEW_HOLDERS + 1))
      FM_REVIEW_HOLDER_IDS="${FM_REVIEW_HOLDER_IDS:+$FM_REVIEW_HOLDER_IDS, }${rec_labels[$i]}"
    fi
    i=$((i + 1))
  done
  if [ "$FM_REVIEW_HOLDERS" -ge "$cap" ]; then
    FM_REVIEW_VERDICT=full
    FM_REVIEW_WHY="$FM_REVIEW_HOLDERS of $cap places are held (${FM_REVIEW_HOLDER_IDS})"
    [ "$observed" -eq 0 ] || FM_REVIEW_WHY="$FM_REVIEW_WHY, counting local unpublished work alone because the forge could not be read"
  elif [ "$observed" -ne 0 ]; then
    FM_REVIEW_VERDICT=unknown
    FM_REVIEW_WHY="the open pull requests could not be observed ($FM_REVIEW_INVENTORY_ERROR)"
  elif [ "$FM_REVIEW_INVENTORY_COMPLETE" -ne 1 ]; then
    FM_REVIEW_VERDICT=unknown
    FM_REVIEW_WHY="the repository has $FM_REVIEW_INVENTORY_TOTAL open pull requests and one bounded call lists only $FM_REVIEW_CAPACITY_PAGE, so the $FM_REVIEW_HOLDERS holders found may undercount"
  else
    FM_REVIEW_VERDICT=admit
  fi
  return 0
}
