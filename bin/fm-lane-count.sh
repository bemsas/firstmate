#!/usr/bin/env bash
# fm-lane-count.sh - the one owner of how many lanes a home is genuinely
# working, read per home from the canonical fresh fleet snapshot, with live
# worker-process occupancy kept as a separate, independently observable number.
#
# Usage:
#   fm-lane-count.sh [--json] [--snapshot-file <fm-fleet-snapshot.v1 json>]
#                    [--max-age <seconds>]
#   fm-lane-count.sh --occupancy | --occupancy-json
#   fm-lane-count.sh --host-health
#   fm-lane-count.sh -h | --help
#
# SOURCE. Without --snapshot-file the counts come from one
# `bin/fm-fleet-snapshot.sh --json` run, whose header owns collection,
# provenance, and freshness; this script never scans panes, status logs, or
# backlog text itself. The rows are this home (`self`, from the snapshot's
# tasks[]) and every registered second mate with a structured home summary
# (secondmate_current.records[]).
#
# COUNTS per home:
#   working    lanes genuinely working now: a working current state proven by
#              live evidence - a no-mistakes run step, a busy pane, or an ACP
#              (headless) session (bin/fm-crew-state.sh sources run-step, pane,
#              acp). A state carried only by a status log or a remote endpoint
#              read (metadata only), and every paused, parked, blocked, held,
#              done, failed, dead, or unknown lane, is not working. For a second
#              mate this is its summary's active_children (in-flight, non-program
#              work whose child state is working) filtered to that live evidence
#              and to ids absent from its holds and open decisions, so a held
#              lane, or a finished or duplicate review lane, which has no working
#              state, never counts.
#   active     every working-state lane, live evidence or not (the summary's
#              active_children count for a second mate).
#   total      every ordinary task record (endpoints for a second mate).
#   target     the home's authorized lane target from its summary's
#              lane_target (bin/fm-fleet-snapshot.sh), or none.
#   occupancy  ordinary task records with at least one live worker process:
#              same-UID, non-zombie processes whose command name (/proc comm)
#              equals the record's harness= and whose working directory is
#              inside the record's worktree=, each worktree counted once however
#              many child processes or duplicate records share it. It is
#              measured for this home on a host with /proc (unknown elsewhere),
#              and a second mate's row reads the lane_occupancy its own home
#              summary publishes from this same command, or unknown from an
#              older producer. A worker whose command name is not its harness
#              name (for example one running under a generic interpreter name)
#              is not counted: occupancy may undercount, never invent. No
#              process arguments or environments are read. This is a different
#              question from bin/fm-lane-vitals-lib.sh's attribution, which
#              charges every process in a lane (idle pane shells included) to
#              its resource budget; occupancy asks only whether a worker runs.
#              FM_PROC_ROOT_OVERRIDE replaces /proc, as in that library.
#   by tool    working and occupancy split by the recorded harness (the model
#              tool): `working_by_tool` from each working lane's harness
#              (a second mate's active_children carry it from its summary;
#              a lane with none counts under `unknown`), and
#              `occupancy_by_tool` from the same process scan. Raw process
#              presence never adds to working, and an older mate summary
#              without these fields reads as null, not zero.
#   evidence   fresh | stale | incomplete | unknown. A second mate's counts are
#              fresh only when its summary is a live ledger read (not the
#              parent's cached copy), at most FM_LANE_COUNT_MAX_AGE seconds old
#              (default 900), its structured state is not unknown, and its
#              active_children list is not truncated; otherwise working is
#              reported but must not be acted on. This home's own row is fresh
#              when the snapshot read it.
#
# OUTPUT. Default: one line per home,
#   <home>: working <N> active <N> total <N> target <N|none> occupancy <N|unknown> evidence <word> tools <tool>=<working>/<occupancy>,...|none|unknown
# so a consumer matching `working (\d+)` reads the genuinely-working count
# and the leading working/active/total fields keep their order.
# --json prints {schema:"fm-lane-count.v1",generated_epoch,homes:[{home,
# working,active,total,target,occupancy,evidence,observed_epoch,
# working_by_tool,occupancy_by_tool}]}, where observed_epoch is when the
# counted summary was generated.
# --max-age <seconds> reuses this home's last counted document
# (state/.lane-count.json) while it is younger than that, and otherwise counts
# afresh and stores it, so the watcher's away-mode refill scan and no-PR scan
# (bin/fm-lane-refill.sh, bin/fm-pr-progress.sh) share one snapshot per sweep.
# --occupancy prints only this home's occupancy number (or unknown);
# --occupancy-json prints {"total":N|null,"by_tool":{...}|null}.
# --host-health prints one line for this host and its fleet:
#   host-health: load1=<X|unknown> cores=<N|unknown> mem_avail_pct=<N|unknown> prs_last_hour=<N|unknown> prs_unknown_homes=<ids|none> spawn_gate=<admit|defer|unknown>
# from the same reads the spawn gate (bin/fm-capacity.sh --host-gate) and the
# no-PR alarm (bin/fm-pr-progress.sh count) use; a field that cannot be read
# says unknown. Main calls it as `bin/fm-lane-count.sh --host-health`.
# Exit 0 on success, 1 when the snapshot cannot be read, 2 on usage errors.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MAX_AGE=${FM_LANE_COUNT_MAX_AGE:-900}
case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=900 ;; esac
PROC_ROOT=${FM_PROC_ROOT_OVERRIDE:-/proc}

JSON=0
SNAPSHOT_FILE=
OCCUPANCY_ONLY=0
HOST_HEALTH=0
CACHE_AGE=
CACHE="$STATE/.lane-count.json"
doc=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --occupancy) OCCUPANCY_ONLY=1; shift ;;
    --occupancy-json) OCCUPANCY_ONLY=2; shift ;;
    --host-health) HOST_HEALTH=1; shift ;;
    --max-age)
      case "${2:-}" in ''|*[!0-9]*) echo "error: --max-age requires seconds" >&2; exit 2 ;; esac
      CACHE_AGE=$2; shift 2 ;;
    --snapshot-file)
      [ -n "${2:-}" ] || { echo "error: --snapshot-file requires a path" >&2; exit 2; }
      SNAPSHOT_FILE=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Live worker-process occupancy for this home (OCCUPANCY above). Only shell
# builtins read each process, and the one fork (readlink of the working
# directory) runs only for a same-UID live process whose command name is a
# recorded harness, so a busy host's scan stays cheap.
lane_occupancy() {
  local uid meta harness worktree pid comm cwd line st state harnesses=' ' pairs='' owners='' n=0
  OCC_BY_TOOL=
  [ -d "$PROC_ROOT" ] || { echo unknown; return 0; }
  uid=$(id -u)
  # One awk pass over every regular task record (last value of each key wins),
  # so a home with hundreds of records costs a single fork here.
  local metas=()
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] && metas+=("$meta")
  done
  [ "${#metas[@]}" -gt 0 ] || { echo 0; return 0; }
  pairs=$(awk '
    function flush() { if (file != "" && kind != "secondmate" && wt ~ /^\// && h ~ /^[A-Za-z0-9._-]+$/) { sub(/\/+$/, "", wt); print wt "\t" h } }
    FNR == 1 { flush(); file = FILENAME; kind = ""; wt = ""; h = "" }
    /^kind=/ { kind = substr($0, 6) }
    /^worktree=/ { wt = substr($0, 10) }
    /^harness=/ { h = substr($0, 9) }
    END { flush() }
  ' "${metas[@]}" 2>/dev/null)
  [ -n "$pairs" ] || { echo 0; return 0; }
  pairs="$pairs
"
  while IFS="	" read -r worktree harness; do
    [ -n "$harness" ] || continue
    case "$harnesses" in *" $harness "*) ;; *) harnesses="$harnesses$harness " ;; esac
  done <<PAIRS
$pairs
PAIRS
  for pid in "$PROC_ROOT"/[0-9]*; do
    comm=
    { read -r comm < "$pid/comm"; } 2>/dev/null || continue
    case "$harnesses" in *" $comm "*) ;; *) continue ;; esac
    st='' state=''
    while read -r line; do
      case "$line" in
        State:*) state=${line#State:}; state=${state#"${state%%[![:space:]]*}"}; state=${state%%[[:space:]]*} ;;
        Uid:*) st=${line#Uid:}; st=${st#"${st%%[![:space:]]*}"}; st=${st%%[[:space:]]*} ;;
      esac
    done 2>/dev/null < "$pid/status"
    [ "$st" = "$uid" ] || continue
    case "$state" in Z | X | '') continue ;; esac
    cwd=$(readlink "$pid/cwd" 2>/dev/null) || continue
    while IFS="	" read -r worktree harness; do
      [ -n "$worktree" ] && [ "$comm" = "$harness" ] || continue
      case "$cwd" in "$worktree" | "$worktree"/*) ;; *) continue ;; esac
      case "
$owners" in *"
$worktree
"*) ;; *) owners="$owners$worktree
"; n=$((n + 1)); OCC_BY_TOOL="$OCC_BY_TOOL$harness
" ;; esac
    done <<PAIRS
$pairs
PAIRS
  done
  echo "$n"
}

# {"total":N|null,"by_tool":{...}|null} from one scan. Run in this shell (not
# a command substitution) so OCC_BY_TOOL survives the scan.
occupancy_json() {
  local total
  lane_occupancy > "$OCC_TMP"
  total=$(cat "$OCC_TMP")
  if [ "$total" = unknown ]; then
    printf '{"total":null,"by_tool":null}\n'
    return 0
  fi
  printf '%s' "$OCC_BY_TOOL" | jq -Rsc --argjson total "$total" \
    '{total:$total, by_tool:(split("\n") | map(select(length > 0)) | group_by(.) | map({key:.[0], value:length}) | from_entries)}'
}
OCC_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-lane-count.XXXXXX") || exit 1
trap 'rm -f -- "$OCC_TMP"' EXIT

if [ "$OCCUPANCY_ONLY" -eq 1 ]; then
  lane_occupancy
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
if [ "$OCCUPANCY_ONLY" -eq 2 ]; then
  occupancy_json
  exit 0
fi

if [ "$HOST_HEALTH" -eq 1 ]; then
  gate=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-capacity.sh" --host-gate 2>/dev/null)
  hh_field() { v=$(printf '%s\n' "$gate" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1); printf '%s' "${v:-unknown}"; }
  prs=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-pr-progress.sh" count \
    --since $(( $(date +%s) - 3600 )) --json 2>/dev/null) || prs=
  total=$(printf '%s' "$prs" | jq -r '[.homes[]? | .count | select(. != null)] | if length == 0 then "unknown" else add end' 2>/dev/null) || total=
  unknown=$(printf '%s' "$prs" | jq -r '[.homes[]? | select(.count == null) | .home] | if length == 0 then "none" else join(",") end' 2>/dev/null) || unknown=
  printf 'host-health: load1=%s cores=%s mem_avail_pct=%s prs_last_hour=%s prs_unknown_homes=%s spawn_gate=%s\n' \
    "$(hh_field load1)" "$(hh_field cores)" "$(hh_field mem_avail_pct)" "${total:-unknown}" "${unknown:-unknown}" \
    "$(hh_field verdict)"
  exit 0
fi

if [ -n "$CACHE_AGE" ] && [ -z "$SNAPSHOT_FILE" ] && [ -f "$CACHE" ]; then
  cached_at=$(jq -r '.generated_epoch // empty' "$CACHE" 2>/dev/null)
  case "$cached_at" in
    '' | *[!0-9]*) ;;
    *) [ $(( $(date +%s) - cached_at )) -ge "$CACHE_AGE" ] || doc=$(cat "$CACHE") ;;
  esac
fi

if [ -z "$doc" ]; then
if [ -n "$SNAPSHOT_FILE" ]; then
  snapshot=$(cat "$SNAPSHOT_FILE" 2>/dev/null) || { echo "error: cannot read $SNAPSHOT_FILE" >&2; exit 1; }
else
  # Second mates count from their structured summaries, never from their own
  # task row, so the snapshot skips reading their panes.
  snapshot=$(FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATE_LIVE_STATE=skip "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) \
    || { echo "error: the fleet snapshot could not be read" >&2; exit 1; }
fi
printf '%s' "$snapshot" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1 \
  || { echo "error: not an fm-fleet-snapshot.v1 document" >&2; exit 1; }

now=$(date +%s)
occupancy_json > "$OCC_TMP.json"
occupancy=$(cat "$OCC_TMP.json")
rm -f -- "$OCC_TMP.json"
doc=$(printf '%s' "$snapshot" | jq -c --argjson now "$now" --argjson max_age "$MAX_AGE" --argjson occupancy "$occupancy" '
  def live: (.source // "") as $s | ($s == "run-step" or $s == "pane" or $s == "acp");
  def target: (.lane_target.value // null) | if type == "number" and . > 0 then . else null end;
  def by_tool: map(.harness // "" | if . == "" then "unknown" else . end) | group_by(.) | map({key:.[0], value:length}) | from_entries;
  {schema:"fm-lane-count.v1", generated_epoch:$now,
   homes:(
     [ {home:"self",
        working:([.tasks[]? | select(.kind != "secondmate")
                  | select(.current_state.state == "working") | select(.current_state | live)] | length),
        working_by_tool:([.tasks[]? | select(.kind != "secondmate")
                  | select(.current_state.state == "working") | select(.current_state | live)] | by_tool),
        occupancy_by_tool:$occupancy.by_tool,
        active:([.tasks[]? | select(.kind != "secondmate") | select(.current_state.state == "working")] | length),
        total:([.tasks[]? | select(.kind != "secondmate")] | length),
        target:null,
        occupancy:$occupancy.total,
        evidence:"fresh",
        observed_epoch:$now} ]
     + [ (.secondmate_current.records // [])[]
         | select(.provenance.selected == "structured-home")
         | (.freshness.age_seconds // null) as $age
         | ([.holds[]?.id] + [.decisions_open[]?.id]) as $held
         | ([.active_children[]? | select(.state == "working") | select(live)
             | select(.id as $id | $held | index($id) | not)]) as $working
         | {home:.id,
            working:($working | length),
            working_by_tool:(if ($working | length) > 0 and all($working[]; has("harness") | not) then null else ($working | by_tool) end),
            occupancy_by_tool:(.lane_occupancy_by_tool // null),
            active:(.counts.active_children // null),
            total:(.counts.endpoints // null),
            target:target,
            occupancy:(.lane_occupancy | if type == "number" then . else null end),
            evidence:(if (.provenance.summary_source // "") == "remote-ledger-cache" or (.freshness.status // "") != "fresh" then "stale"
                      elif ($age | type) != "number" or $age > $max_age then "stale"
                      elif (.current.state // "unknown") == "unknown" then "incomplete"
                      elif (.counts.active_children // -1) != ((.active_children // []) | length) then "incomplete"
                      else "fresh" end),
            observed_epoch:(if ($age | type) == "number" then $now - $age else null end)} ]
     + [ (.secondmate_current.records // [])[]
         | select(.provenance.selected != "structured-home")
         | {home:.id, working:null, active:null, total:null, target:null, occupancy:null,
            evidence:"unknown", observed_epoch:null, working_by_tool:null, occupancy_by_tool:null} ])}') \
  || { echo "error: the fleet snapshot could not be counted" >&2; exit 1; }
if [ -n "$CACHE_AGE" ] && [ -z "$SNAPSHOT_FILE" ]; then
  printf '%s\n' "$doc" > "$CACHE.next.$$" && mv -f "$CACHE.next.$$" "$CACHE"
fi
fi

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$doc"
  exit 0
fi
printf '%s' "$doc" | jq -r '
  def n($v): if $v == null then "unknown" else ($v | tostring) end;
  .homes[]
  | . as $h
  | ((($h.working_by_tool // {}) | keys) + (($h.occupancy_by_tool // {}) | keys) | unique) as $tools
  | (if $h.working_by_tool == null and $h.occupancy_by_tool == null then "unknown"
     elif ($tools | length) == 0 then "none"
     else [$tools[] as $t
           | "\($t)=\(if $h.working_by_tool == null then "unknown" else ($h.working_by_tool[$t] // 0 | tostring) end)/\(if $h.occupancy_by_tool == null then "unknown" else ($h.occupancy_by_tool[$t] // 0 | tostring) end)"]
          | join(",") end) as $tooltext
  | "\($h.home): working \(n($h.working)) active \(n($h.active)) total \(n($h.total)) target \($h.target // "none") occupancy \(n($h.occupancy)) evidence \($h.evidence) tools \($tooltext)"'
