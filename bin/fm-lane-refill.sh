#!/usr/bin/env bash
# fm-lane-refill.sh - away-mode-only detection of a second mate whose genuinely
# working lanes have stayed below its authorized lane target, and the one
# deduplicated refill cue per shortage episode.
#
# Usage:
#   fm-lane-refill.sh scan [--counts-file <fm-lane-count.v1 json>]
#   fm-lane-refill.sh cue <mate-id> <episode-id>
#   fm-lane-refill.sh -h | --help
#
# NO NEW WATCHER. `scan` runs inside bin/fm-watch.sh's existing check sweep
# (FM_CHECK_INTERVAL) and does nothing at all unless this home holds an away
# record (bin/fm-afk-contract.sh mode away: never quiet mode, never attended)
# and at least one registered second mate (state/<id>.meta, kind=secondmate).
# It reads counts only through bin/fm-lane-count.sh --json, the one owner of
# what a genuinely working lane is, which reads the canonical fresh fleet
# snapshot; it never dispatches, spawns, or sends anything itself.
#
# EPISODES (state/.lane-refill, one tab-separated line per mate:
#   <mate> <target>:<working> <since-epoch> <last-observed-epoch> <emitted 0|1>
#   <sent 0|1> <episode-id> <emitted-epoch>).
# For each second mate on every scan:
#   - evidence other than fresh (stale, cached, incomplete, unknown), or no
#     numeric lane target or working count: the mate's episode is dropped, so
#     continuity must be proven again by fresh evidence and nothing is cued;
#   - working >= target: recovered, the episode is dropped;
#   - working < target: the episode identity is <target>:<working>. The same
#     identity keeps its start while this observation is no more than
#     FM_LANE_REFILL_MAX_GAP seconds (default 1200, four default check sweeps)
#     after the episode's last observation; any other identity (a count
#     identity change, a new target) or a longer gap, in which the mate may
#     have recovered unseen, starts a new episode at this observation's epoch,
#     the summary's own generation time rather than the scan time.
#   - an episode whose latest fresh observation is more than
#     FM_LANE_REFILL_AFTER seconds (default 900, so more than 15 continuous
#     minutes) after its start is emitted once: the scan prints
#       lane-refill: <mate> working <w> of target <t> since <utc> episode <id>
#     which the watcher queues as a `check:` wake for the away session. An
#     emitted episode that is still unsent is printed again only after
#     FM_LANE_REFILL_RENOTIFY seconds (default 1800), so a lost wake recovers
#     without a repeat every sweep.
# Leaving away mode clears the file: an archived record authorizes nothing.
# The file's first line, `#away <entered_epoch> <words-digest>`, binds it to the
# away record and the away words it was observed under, so episodes from an
# earlier away window, or from before the words were replaced, are discarded
# rather than continued even when no scan ran in between.
#
# CUE. `cue <mate> <episode>` sends the one refill cue for an emitted episode
# through bin/fm-send.sh --fire-and-forget, with a delivery id derived from the
# episode id, and marks it sent. The cue's message is written once, before the
# first send, to state/.lane-refill.pending/<delivery-id>, and every retry
# resends exactly that message, so an attempt whose acknowledgment was lost and
# its retry land at most one record (the inbox deduplicates by the whole body);
# because the episode file is bound to the words, a retry after the words
# changed is refused rather than resent with other words.
# It refuses (exit 3) when no away record stands, the episode file is bound to
# another away record than the current one, the episode is not the mate's
# current emitted one, or its last fresh observation is more than
# FM_LANE_REFILL_CUE_MAX_AGE seconds old (default 3600, so scans that stopped
# cannot send a stale shortage), and prints `sent: already` for one already sent.
# The cue states the observed shortage and the away words and asks the mate to
# refill only under its own existing authorization, capacity, and health
# gates; it authorizes nothing by itself.
#
# Test seams: --counts-file replaces the fm-lane-count.sh read, and
# FM_LANE_REFILL_SEND_CMD replaces bin/fm-send.sh, so fixtures never collect a
# live fleet or steer a live endpoint.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EPISODES="$STATE/.lane-refill"
LOCK="$STATE/.lane-refill.lock"
AFTER=${FM_LANE_REFILL_AFTER:-900}
RENOTIFY=${FM_LANE_REFILL_RENOTIFY:-1800}
MAX_GAP=${FM_LANE_REFILL_MAX_GAP:-1200}
CUE_MAX_AGE=${FM_LANE_REFILL_CUE_MAX_AGE:-3600}
case "$CUE_MAX_AGE" in ''|*[!0-9]*) CUE_MAX_AGE=3600 ;; esac
case "$MAX_GAP" in ''|*[!0-9]*) MAX_GAP=1200 ;; esac
case "$AFTER" in ''|*[!0-9]*) AFTER=900 ;; esac
case "$RENOTIFY" in ''|*[!0-9]*) RENOTIFY=1800 ;; esac
TAB=$(printf '\t')

# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ; }

have_secondmate() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null && return 0
  done
  return 1
}

sha16() {  # stdin -> first 16 hex characters of its SHA-256
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-16; else sha256sum | cut -c1-16; fi
}

# The away record and words the episodes are bound to: `<entered_epoch>\t<words
# digest>`, or empty when no away record can be read.
away_binding() {
  local entered words
  entered=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" field entered_epoch 2>/dev/null) || return 0
  [ -n "$entered" ] || return 0
  words=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" words 2>/dev/null; printf x) || return 0
  printf '%s\t%s\n' "$entered" "$(printf '%s' "${words%x}" | sha16)"
}

lock_take() {
  fm_lock_acquire_wait_max "$LOCK" 30 || { echo "error: the lane-refill record is busy" >&2; exit 1; }
  trap 'fm_lock_release "$LOCK" || true' EXIT
}

cmd_scan() {
  local counts_file='' counts now rows mate target working evidence observed line
  local prev_identity prev_since prev_observed prev_emitted prev_sent prev_id prev_emitted_at identity since emitted sent id emitted_at out=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --counts-file) [ -n "${2:-}" ] || { echo "error: --counts-file requires a path" >&2; exit 2; }
        counts_file=$2; shift 2 ;;
      *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  if ! fm_afk_contract_away_present "$STATE"; then
    [ ! -e "$EPISODES" ] || rm -f "$EPISODES"
    return 0
  fi
  have_secondmate || return 0
  if [ -n "$counts_file" ]; then
    counts=$(cat "$counts_file" 2>/dev/null) || { echo "error: cannot read $counts_file" >&2; exit 1; }
  else
    counts=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lane-count.sh" --json --max-age 240 2>/dev/null) || return 0
  fi
  rows=$(printf '%s' "$counts" | jq -r '.homes[]? | select(.home != "self")
    | [.home, (.target // "-" | tostring), (.working // "-" | tostring), (.evidence // "unknown"),
       (.observed_epoch // "-" | tostring)] | @tsv' 2>/dev/null) || return 0
  now=$(date +%s)
  lock_take
  local next away_id
  away_id=$(away_binding)
  [ "$(sed -n '1p' "$EPISODES" 2>/dev/null)" = "#away	$away_id" ] || rm -f "$EPISODES"
  next=$(mktemp "$STATE/.lane-refill.next.XXXXXX") || exit 1
  printf '#away\t%s\n' "$away_id" > "$next"
  while IFS="$TAB" read -r mate target working evidence observed; do
    [ -n "$mate" ] || continue
    case "$target$working$observed" in *[!0-9]*) continue ;; esac
    [ "$evidence" = fresh ] && [ "$target" -gt 0 ] || continue
    [ "$working" -lt "$target" ] || continue
    identity="$target:$working"
    line=$(awk -F "$TAB" -v m="$mate" '$1 == m { print; exit }' "$EPISODES" 2>/dev/null)
    IFS="$TAB" read -r _ prev_identity prev_since prev_observed prev_emitted prev_sent prev_id prev_emitted_at <<EOF
$line
EOF
    case "$prev_observed" in ''|*[!0-9]*) prev_observed=0 ;; esac
    if [ -n "$line" ] && [ "$prev_identity" = "$identity" ] && [ $((observed - prev_observed)) -le "$MAX_GAP" ]; then
      since=$prev_since emitted=$prev_emitted sent=$prev_sent id=$prev_id emitted_at=${prev_emitted_at:-0}
    else
      since=$observed emitted=0 sent=0 emitted_at=0
      id="$mate-$since-$target-$working"
    fi
    [ "$observed" -ge "$since" ] || since=$observed
    if [ "$sent" -eq 0 ] && [ $((observed - since)) -gt "$AFTER" ]; then
      if [ "$emitted" -eq 0 ] || [ $((now - emitted_at)) -ge "$RENOTIFY" ]; then
        emitted=1 emitted_at=$now
        out="${out:+$out
}lane-refill: $mate working $working of target $target since $(iso "$since") episode $id"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mate" "$identity" "$since" "$observed" "$emitted" "$sent" "$id" "$emitted_at" >> "$next"
  done <<EOF
$rows
EOF
  mv -f "$next" "$EPISODES" || { rm -f "$next"; exit 1; }
  [ -z "$out" ] || printf '%s\n' "$out"
}

cmd_cue() {
  local mate=${1:-} episode=${2:-} away_id line identity since last_observed emitted sent id words delivery pending target working message rc
  [ -n "$mate" ] && [ -n "$episode" ] || { usage >&2; exit 2; }
  case "$mate" in .* | *[!A-Za-z0-9._-]*) echo "error: invalid mate id" >&2; exit 2 ;; esac
  fm_afk_contract_away_present "$STATE" || { echo "sent: no (no away record stands; a refill cue is an away-mode action only)"; exit 3; }
  lock_take
  away_id=$(away_binding)
  if [ -z "$away_id" ] || [ "$(sed -n '1p' "$EPISODES" 2>/dev/null)" != "#away${TAB}$away_id" ]; then
    echo "sent: no (episode $episode was not observed under the current away record)"
    exit 3
  fi
  line=$(awk -F "$TAB" -v m="$mate" '$1 == m { print; exit }' "$EPISODES" 2>/dev/null)
  IFS="$TAB" read -r _ identity since last_observed emitted sent id _ <<EOF
$line
EOF
  if [ -z "$line" ] || [ "$id" != "$episode" ] || [ "$emitted" != 1 ]; then
    echo "sent: no (episode $episode is not $mate's current shortage; it recovered, changed, or was never emitted)"
    exit 3
  fi
  case "$last_observed" in ''|*[!0-9]*) last_observed=0 ;; esac
  if [ "$sent" != 1 ] && [ $(( $(date +%s) - last_observed )) -gt "$CUE_MAX_AGE" ]; then
    echo "sent: no (episode $episode was last observed at $(iso "$last_observed"); no fresh observation since, so the shortage is not current)"
    exit 3
  fi
  if [ "$sent" = 1 ]; then
    echo "sent: already"
    exit 0
  fi
  target=${identity%%:*}
  working=${identity#*:}
  words=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" words 2>/dev/null) || words=
  delivery=$(printf 'lane-refill|%s' "$episode" | sha16)
  message="Lane refill cue from the parent home's away session: your fresh home summary has shown $working genuinely working lanes against your lane target of $target continuously since $(iso "$since"), more than 15 minutes.
Parent away words, verbatim: ${words:-(none recorded)}
Refill only with queued work your own existing authorization, capacity, and health gates already admit; launch nothing they do not, and if nothing is dispatchable say why in your next relay. This cue authorizes nothing by itself."
  pending="$STATE/.lane-refill.pending/$delivery"
  if [ -f "$pending" ]; then
    message=$(cat "$pending") || { echo "sent: no (the pending cue $delivery could not be read)"; exit 3; }
  else
    { mkdir -p "${pending%/*}" && printf '%s' "$message" > "$pending.tmp" && mv -f "$pending.tmp" "$pending"; } || {
      rm -f "$pending.tmp"
      echo "sent: no (the pending cue $delivery could not be recorded)"
      exit 3
    }
  fi
  FM_HOME=$FM_HOME "${FM_LANE_REFILL_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}" "$mate" --fire-and-forget "$delivery" "$message"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "sent: unconfirmed (fm-send exit $rc; re-run this command to retry the same delivery $delivery)"
    exit "$rc"
  fi
  awk -F "$TAB" -v OFS="$TAB" -v m="$mate" '$1 == m { $6 = 1 } { print }' "$EPISODES" > "$EPISODES.tmp" \
    && mv -f "$EPISODES.tmp" "$EPISODES"
  rm -f "$pending"
  echo "sent: yes $delivery"
}

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  cue) shift; cmd_cue "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
