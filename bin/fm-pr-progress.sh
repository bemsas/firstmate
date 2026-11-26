#!/usr/bin/env bash
# fm-pr-progress.sh - newly created pull requests per home from the existing
# status records, and the alarm for a home whose busy lanes have produced no
# new pull request for a full continuous hour.
#
# Usage:
#   fm-pr-progress.sh count [--since <epoch>] [--json]
#   fm-pr-progress.sh scan [--counts-file <fm-lane-count.v1 json>]
#   fm-pr-progress.sh cue <home> <episode-id>
#   fm-pr-progress.sh -h | --help
#
# PR CREATION EVIDENCE (`count`). No forge is polled. A pull request's creation
# time is the earliest `[at=<epoch>]` status line that names its URL (GitHub
# /pull/<n>, GitLab /-/merge_requests/<n>, Forgejo /pulls/<n>):
#   self       every ordinary task status log in this home (state/<id>.status
#              whose state/<id>.meta kind is not secondmate);
#   <mate-id>  the second mate's relay log in this home (state/<mate>.status),
#              where it relays each child's PR-ready and done lines.
# A home whose log cannot be read reports count null (unknown), never 0; a
# line without an [at=] stamp proves nothing and is skipped. `count` prints
# `<home>: prs <N|unknown> since <epoch>` per home, or with --json
# {"since":E,"homes":[{"home","count"}]}. --since defaults to an hour ago.
#
# ALARM (`scan`). Run from bin/fm-watch.sh's existing check sweep in every
# posture, at most every FM_PR_PROGRESS_INTERVAL seconds (default 300). Busy
# lanes come from bin/fm-lane-count.sh --json --max-age 240 (the one owner of a
# genuinely working lane; the cache keeps the sweep to one snapshot). Per home
# (state/.pr-progress, `<home> <since> <emitted-epoch|0> <sent 0|1>
# <episode-id> <last-observed-epoch>`):
#   - evidence other than fresh, working 0 or unknown, or a PR count that
#     cannot be read: no episode (recovery, stale data, and unknown telemetry
#     all reset it, so an alarm always rests on an unbroken busy hour);
#   - a busy observation more than FM_PR_PROGRESS_MAX_GAP seconds (default
#     3600, one alarm window) after the episode's last one starts a new
#     episode at this observation, because the home may have been idle unseen;
#   - busy with a new PR created after the episode began: the episode restarts
#     at that PR's creation time (a real PR resets the hour); the PR that
#     started the episode is not new, so it never resets it again;
#   - busy with no new PR for at least FM_PR_PROGRESS_AFTER seconds (default
#     3600): emitted once, as
#       no-pr-progress: <home> busy <w> lanes and no new PR since <utc> episode <id> (cue: bin/fm-pr-progress.sh cue <home> <id>)
#     which the watcher queues as one `check:` wake for MAIN (the away session
#     while an away record stands). An emitted episode prints again only after
#     FM_PR_PROGRESS_RENOTIFY seconds (default 7200).
# CUE (`cue <mate> <episode>`) sends the owning second mate, once per episode
# through bin/fm-send.sh --fire-and-forget, the instruction to stop spawning
# new work and diagnose why its busy lanes created no PR; it says not to
# exit, destroy, or reshuffle any worker and changes no quality gate. The
# `self` home has no mate to cue: the wake itself is MAIN's cue. A cue for an
# episode that is no longer current is refused (exit 3).
#
# Test seams: --counts-file replaces the lane count read; FM_PR_PROGRESS_SEND_CMD
# replaces bin/fm-send.sh; FM_PR_PROGRESS_NOW pins the clock.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EPISODES="$STATE/.pr-progress"
LOCK="$STATE/.pr-progress.lock"
LAST_SCAN="$STATE/.pr-progress-last-scan"
AFTER=${FM_PR_PROGRESS_AFTER:-3600}
RENOTIFY=${FM_PR_PROGRESS_RENOTIFY:-7200}
INTERVAL=${FM_PR_PROGRESS_INTERVAL:-300}
MAX_GAP=${FM_PR_PROGRESS_MAX_GAP:-3600}
case "$MAX_GAP" in ''|*[!0-9]*) MAX_GAP=3600 ;; esac
case "$AFTER" in ''|*[!0-9]*) AFTER=3600 ;; esac
case "$RENOTIFY" in ''|*[!0-9]*) RENOTIFY=7200 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=300 ;; esac
NOW=${FM_PR_PROGRESS_NOW:-$(date +%s)}
TAB=$(printf '\t')

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ; }

kind_of() { sed -n 's/^kind=//p' "$1" 2>/dev/null | tail -1; }

# Earliest stamped appearance of each PR URL across <files...>, one
# "<epoch>\t<url>" line each.
first_seen() {
  awk '
    {
      if (!match($0, /\[at=[0-9]+\]/)) next
      at = substr($0, RSTART + 4, RLENGTH - 5) + 0
      line = $0
      while (match(line, /https:\/\/[A-Za-z0-9.-]+\/[^ \t]+\/(pull|pulls|-\/merge_requests)\/[0-9]+/)) {
        url = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (!(url in seen) || at < seen[url]) seen[url] = at
      }
    }
    END { for (u in seen) print seen[u] "\t" u }
  ' "$@" 2>/dev/null
}

# Count PRs first seen at or after <since> for one home; prints N or unknown.
home_count() {  # <home> <since>
  local home=$1 since=$2 meta files=() status
  if [ "$home" = self ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      [ "$(kind_of "$meta")" != secondmate ] || continue
      status="${meta%.meta}.status"
      [ -f "$status" ] || continue
      [ -r "$status" ] || { echo unknown; return 0; }
      files+=("$status")
    done
    [ "${#files[@]}" -gt 0 ] || { echo 0; return 0; }
  else
    status="$STATE/$home.status"
    [ -f "$status" ] && [ -r "$status" ] || { echo unknown; return 0; }
    files=("$status")
  fi
  first_seen "${files[@]}" | awk -F '\t' -v s="$since" '$1 >= s { n++ } END { print n + 0 }'
}

# The newest first-seen PR time at or after <since>, or empty.
home_latest() {  # <home> <since>
  local home=$1 since=$2 meta files=() status
  if [ "$home" = self ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      [ "$(kind_of "$meta")" != secondmate ] || continue
      status="${meta%.meta}.status"
      [ -f "$status" ] && files+=("$status")
    done
  else
    files=("$STATE/$home.status")
  fi
  [ "${#files[@]}" -gt 0 ] || return 0
  first_seen "${files[@]}" | awk -F '\t' -v s="$since" '$1 >= s && $1 > m { m = $1 } END { if (m) print m }'
}

homes() {
  local meta
  echo self
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(kind_of "$meta")" = secondmate ] && basename "$meta" .meta
  done
}

cmd_count() {
  local since=$((NOW - 3600)) json=0 home n out=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) case "${2:-}" in ''|*[!0-9]*) echo "error: --since requires an epoch" >&2; exit 2 ;; esac
        since=$2; shift 2 ;;
      --json) json=1; shift ;;
      *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  while IFS= read -r home; do
    n=$(home_count "$home" "$since")
    if [ "$json" -eq 1 ]; then
      out="$out$home	$n
"
    else
      printf '%s: prs %s since %s\n' "$home" "$n" "$since"
    fi
  done <<EOF
$(homes)
EOF
  [ "$json" -eq 1 ] || return 0
  printf '%s' "$out" | jq -Rsc --argjson since "$since" \
    '{since:$since, homes:(split("\n") | map(select(length > 0) | split("\t")
      | {home:.[0], count:(if .[1] == "unknown" then null else (.[1] | tonumber) end)}))}'
}

lock_take() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait_max "$LOCK" 30 || { echo "error: the PR-progress record is busy" >&2; exit 1; }
  trap 'fm_lock_release "$LOCK" || true' EXIT
}

cmd_scan() {
  local counts_file='' counts rows home working evidence observed line prev_since prev_emitted prev_sent prev_id prev_observed
  local since emitted sent id latest n out='' next last
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --counts-file) [ -n "${2:-}" ] || { echo "error: --counts-file requires a path" >&2; exit 2; }
        counts_file=$2; shift 2 ;;
      *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$counts_file" ]; then
    last=$(cat "$LAST_SCAN" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((NOW - last)) -ge "$INTERVAL" ] || return 0
    printf '%s\n' "$NOW" > "$LAST_SCAN"
    counts=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lane-count.sh" --json --max-age 240 2>/dev/null) || return 0
  else
    counts=$(cat "$counts_file" 2>/dev/null) || { echo "error: cannot read $counts_file" >&2; exit 1; }
  fi
  rows=$(printf '%s' "$counts" | jq -r '.homes[]?
    | [.home, (.working // "-" | tostring), (.evidence // "unknown"), (.observed_epoch // "-" | tostring)] | @tsv' 2>/dev/null) || return 0
  lock_take
  next=$(mktemp "$STATE/.pr-progress.next.XXXXXX") || exit 1
  while IFS="$TAB" read -r home working evidence observed; do
    [ -n "$home" ] || continue
    case "$working$observed" in *[!0-9]*) continue ;; esac
    [ "$evidence" = fresh ] && [ "$working" -gt 0 ] || continue
    line=$(awk -F "$TAB" -v h="$home" '$1 == h { print; exit }' "$EPISODES" 2>/dev/null)
    IFS="$TAB" read -r _ prev_since prev_emitted prev_sent prev_id prev_observed <<EOF
$line
EOF
    case "$prev_observed" in ''|*[!0-9]*) prev_observed=0 ;; esac
    if [ -n "$line" ] && [ $((observed - prev_observed)) -le "$MAX_GAP" ]; then
      since=$prev_since emitted=$prev_emitted sent=$prev_sent id=$prev_id
    else
      since=$observed emitted=0 sent=0 id=
    fi
    # Only a PR first seen after the episode's start is new progress.
    n=$(home_count "$home" $((since + 1)))
    [ "$n" != unknown ] || continue
    if [ "$n" -gt 0 ]; then
      latest=$(home_latest "$home" $((since + 1)))
      since=${latest:-$observed} emitted=0 sent=0 id=
    fi
    [ -n "$id" ] || id="$home-$since"
    if [ $((observed - since)) -ge "$AFTER" ] && [ "$sent" -eq 0 ]; then
      if [ "$emitted" -eq 0 ] || [ $((NOW - emitted)) -ge "$RENOTIFY" ]; then
        emitted=$NOW
        out="${out:+$out
}no-pr-progress: $home busy $working lanes and no new PR since $(iso "$since") episode $id (cue: bin/fm-pr-progress.sh cue $home $id)"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$home" "$since" "$emitted" "$sent" "$id" "$observed" >> "$next"
  done <<EOF
$rows
EOF
  mv -f "$next" "$EPISODES" || exit 1
  [ -z "$out" ] || printf '%s\n' "$out"
}

cmd_cue() {
  local mate=${1:-} episode=${2:-} line emitted sent id since delivery message rc
  [ -n "$mate" ] && [ -n "$episode" ] || { usage >&2; exit 2; }
  case "$mate" in .* | *[!A-Za-z0-9._-]*) echo "error: invalid home id" >&2; exit 2 ;; esac
  if [ "$mate" = self ]; then
    echo "sent: no (this home's own lanes have no mate to cue; the wake itself is MAIN's)"
    exit 0
  fi
  [ "$(kind_of "$STATE/$mate.meta")" = secondmate ] || { echo "sent: no ($mate is not a registered second mate)"; exit 3; }
  lock_take
  line=$(awk -F "$TAB" -v h="$mate" '$1 == h { print; exit }' "$EPISODES" 2>/dev/null)
  IFS="$TAB" read -r _ since emitted sent id _ <<EOF
$line
EOF
  if [ -z "$line" ] || [ "$id" != "$episode" ] || [ "${emitted:-0}" = 0 ]; then
    echo "sent: no (episode $episode is not $mate's current no-PR episode; it recovered, reset, or was never emitted)"
    exit 3
  fi
  [ "$sent" != 1 ] || { echo "sent: already"; exit 0; }
  if command -v shasum >/dev/null 2>&1; then
    delivery=$(printf 'pr-progress|%s' "$episode" | shasum -a 256 | cut -c1-16)
  else
    delivery=$(printf 'pr-progress|%s' "$episode" | sha256sum | cut -c1-16)
  fi
  message="No-PR alarm from the parent home: your fresh home summary has shown busy worker lanes since $(iso "$since") with no new pull request relayed in that time, a full hour or more.
Stop spawning new work now and diagnose why the busy lanes are not producing pull requests (stuck, looping, starved for memory, or waiting on something), then relay what you found.
Do not exit, destroy, or reshuffle any worker for this, and keep every quality gate as it is."
  FM_HOME=$FM_HOME "${FM_PR_PROGRESS_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}" "$mate" --fire-and-forget "$delivery" "$message"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "sent: unconfirmed (fm-send exit $rc; re-run this command to retry the same delivery $delivery)"
    exit "$rc"
  fi
  awk -F "$TAB" -v OFS="$TAB" -v h="$mate" '$1 == h { $4 = 1 } { print }' "$EPISODES" > "$EPISODES.tmp" \
    && mv -f "$EPISODES.tmp" "$EPISODES"
  echo "sent: yes $delivery"
}

case "${1:-}" in
  count) shift; cmd_count "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  cue) shift; cmd_cue "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
