#!/usr/bin/env bash
# Deterministic wake router (prototype): sits between bin/fm-wake-drain.sh and
# the supervisor so only wakes that need a real decision cost a model turn.
# bin/fm-wake-router-lib.sh owns per-row classification; docs/wake-router.md
# owns the design, the rule table, and the safety limits.
#
# Usage:
#   fm-wake-route.sh classify            classify a drain transcript read on stdin
#   fm-wake-route.sh route [--execute]   drain, classify, and present or handle
#   fm-wake-route.sh replay <corpus>     replay a wake-shape corpus, report the split
#
# classify is read-only: it prints one "<seq>\t<kind>\t<class>\t<action>\t<reason>"
# row per wake, then "BATCH\t<needs-llm|routed>\t<reason>".
#
# route runs the drain itself, with stdout and stderr in one ordered transcript.
#   Off (no config/wake-router), away/quiet mode (state/.afk), or a branch
#   actor: the transcript is printed unchanged and the drain's exit status is
#   returned; the router steps aside entirely.
#   Shadow (config/wake-router without "live", or no --execute): the transcript
#   is printed unchanged and every row's verdict is appended to
#   state/.wake-router.log, so a home can measure the split before trusting it.
#   Live (config/wake-router names "live" AND --execute): auto-act rows run
#   their guarded script first, and a refusal turns that row into needs-llm.
#   When every row and every presented section is then routed, the router runs
#   the drain's own WAKE_ACK_REQUIRED command and exits 0: no supervisor turn
#   is needed and the host re-parks the next cycle exactly as after any handled
#   wake. Otherwise it prints a filtered presentation (needs-llm rows, their
#   annotations, every section it could not prove covered, the outcomes the
#   captain is owed, and the unchanged WAKE_ACK_REQUIRED line) and exits 10.
#   Any internal failure after the drain ran prints the raw transcript and
#   exits 10, so a router bug can cost a model turn but never hide a wake.
#
# Auto-act scripts are only ever bin/fm-pr-merge.sh <task> <url> and
# bin/fm-teardown.sh <task>, each of which re-verifies its own guards live
# (green head, landed work) and refuses rather than proceeding.
# Captain-facing outcomes of auto-acts are appended to
# state/.wake-router-outcomes and presented once, in the next needs-llm
# presentation, so the supervisor relays them in its next natural reply.
#
# replay reads a TSV corpus (docs/wake-router.md "Replay corpus" owns the
# columns), builds an isolated fixture home per row, classifies it through the
# same library, and prints per-row verdicts, mismatches against an expected
# class, and the per-class share. Exit 1 when any row's verdict differs from
# its expected class.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
export FM_HOME

# shellcheck source=bin/fm-wake-router-lib.sh
. "$SCRIPT_DIR/fm-wake-router-lib.sh"

FM_WAKE_ROUTE_DRAIN_BIN="${FM_WAKE_ROUTE_DRAIN_BIN:-$SCRIPT_DIR/fm-wake-drain.sh}"
FM_WAKE_ROUTE_MERGE_BIN="${FM_WAKE_ROUTE_MERGE_BIN:-$SCRIPT_DIR/fm-pr-merge.sh}"
FM_WAKE_ROUTE_TEARDOWN_BIN="${FM_WAKE_ROUTE_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"

TAB=$(printf '\t')
WORK=

usage() {
  sed -n '7,10p' "$0" | sed 's/^# //' >&2
  exit 2
}

cleanup() {
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT

new_work() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-route.XXXXXX") || return 1
  mkdir -p "$WORK/events"
}

# --- drain transcript parsing -------------------------------------------------
# parse_transcript <file>: split a drain transcript into
#   $WORK/rows       raw queue rows (epoch seq kind key payload)
#   $WORK/events/<status-key>  annotated events per status key
#   $WORK/backstop   "<task>\t<line>" outcome-backstop items
#   $WORK/forcing    every other line, verbatim: unknown text is never dropped
#   $WORK/ack        the WAKE_ACK_REQUIRED line
#   $WORK/annotations  annotation lines, verbatim, keyed "<status-key>\t<line>"
parse_transcript() {
  local file=$1 line section=none rest skey event task
  : > "$WORK/rows"; : > "$WORK/backstop"; : > "$WORK/forcing"; : > "$WORK/ack"; : > "$WORK/annotations"
  while IFS= read -r line || [ -n "$line" ]; do
    if printf '%s\n' "$line" | awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^(signal|stale|check|heartbeat)$/ { ok=1 } END { exit !ok }'; then
      printf '%s\n' "$line" >> "$WORK/rows"
      section=none
      continue
    fi
    case "$line" in
      'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through '*)
        printf '%s\n' "$line" > "$WORK/ack"
        section=none
        continue
        ;;
      'wake annotation: '*)
        rest=${line#wake annotation: }
        case "$rest" in *': '*': '*) ;; *) printf '%s\n' "$line" >> "$WORK/forcing"; continue ;; esac
        rest=${rest#*: }
        skey=${rest%%: *}
        event=${rest#*: }
        case "$skey" in ''|*/*|.*|*' '*) printf '%s\n' "$line" >> "$WORK/forcing"; continue ;; esac
        printf '%s\n' "$event" >> "$WORK/events/$skey"
        printf '%s\t%s\n' "$skey" "$line" >> "$WORK/annotations"
        section=none
        continue
        ;;
      'STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):')
        section=backstop
        continue
        ;;
      'WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.')
        continue
        ;;
      '')
        continue
        ;;
    esac
    if [ "$section" = backstop ]; then
      task=${line%% *}
      if printf '%s' "$task" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' && [ "$task" != "$line" ]; then
        printf '%s\t%s\n' "$task" "${line#"$task" }" >> "$WORK/backstop"
        continue
      fi
      section=none
    fi
    printf '%s\n' "$line" >> "$WORK/forcing"
  done < "$file"
}

# classify_rows: one verdict row per queue row into $WORK/verdicts as
# "<seq>\t<kind>\t<class>\t<action>\t<reason>\t<task>\t<line>".
classify_rows() {
  local epoch seq kind key payload task events
  : > "$WORK/verdicts"
  : > "$WORK/heartbeat-pending"
  while IFS="$TAB" read -r epoch seq kind key payload; do
    : "$epoch"
    events="$WORK/row-$seq.events"
    : > "$events"
    if [ "$kind" = signal ]; then
      task=${key%.status}
      task=${task%.turn-ended}
      [ ! -f "$WORK/events/$task.status" ] || cp "$WORK/events/$task.status" "$events"
    fi
    FM_WR_SEQ=$seq fm_wake_route_row "$STATE" "$CONFIG" "$kind" "$key" "$payload" "$events" || {
      FM_WR_CLASS=needs-llm FM_WR_ACTION=none FM_WR_REASON="classifier usage error" FM_WR_TASK='' FM_WR_LINE=''
    }
    [ -z "${FM_WR_HEARTBEAT_PENDING:-}" ] || printf '%s\n' "$FM_WR_HEARTBEAT_PENDING" > "$WORK/heartbeat-pending"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$kind" "$FM_WR_CLASS" "$FM_WR_ACTION" \
      "$FM_WR_REASON" "$FM_WR_TASK" "$FM_WR_LINE" >> "$WORK/verdicts"
  done < "$WORK/rows"
}

# uncovered_backstop: print backstop items not covered by a routed row of the
# same task deciding on that very event line.
uncovered_backstop() {
  local task line seq kind cls act why vtask vline covered
  while IFS="$TAB" read -r task line; do
    covered=false
    while IFS="$TAB" read -r seq kind cls act why vtask vline; do
      : "$seq" "$kind" "$act" "$why"
      [ "$vtask" = "$task" ] || continue
      [ "$cls" != needs-llm ] || continue
      [ "$vline" = "$line" ] && covered=true
    done < "$WORK/verdicts"
    [ "$covered" = true ] || printf '%s %s\n' "$task" "$line"
  done < "$WORK/backstop"
}

batch_verdict() {
  local n_llm uncovered
  n_llm=$(awk -F '\t' '$3 == "needs-llm"' "$WORK/verdicts" | awk 'END { print NR }')
  uncovered=$(uncovered_backstop)
  if [ ! -s "$WORK/rows" ]; then
    printf 'needs-llm\tno queue rows to route\n'
  elif [ ! -s "$WORK/ack" ]; then
    printf 'needs-llm\tdrain printed no acknowledgement command\n'
  elif [ -s "$WORK/forcing" ]; then
    printf 'needs-llm\tdrain printed %s line(s) the router does not own\n' "$(awk 'END { print NR }' "$WORK/forcing")"
  elif [ -n "$uncovered" ]; then
    printf 'needs-llm\toutcome backstop names an event no routed row decided\n'
  elif [ "$n_llm" -gt 0 ]; then
    printf 'needs-llm\t%s row(s) need a decision\n' "$n_llm"
  else
    printf 'routed\tevery row routed\n'
  fi
}

cmd_classify() {
  local seq kind cls act why
  new_work || exit 1
  cat > "$WORK/transcript"
  parse_transcript "$WORK/transcript"
  classify_rows
  while IFS="$TAB" read -r seq kind cls act why _; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$seq" "$kind" "$cls" "$act" "$why"
  done < "$WORK/verdicts"
  printf 'BATCH\t%s\n' "$(batch_verdict)"
}

# --- route ------------------------------------------------------------------

router_steps_aside() {
  [ -f "$CONFIG/wake-router" ] || return 0
  [ ! -e "$STATE/.afk" ] || return 0
  [ "${FM_SUPERVISION_ACTOR:-main}" = main ] || return 0
  return 1
}

log_verdicts() {  # <mode>
  local seq kind cls act why now
  now=$(date +%s)
  while IFS="$TAB" read -r seq kind cls act why _; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$1" "$seq" "$kind" "$cls" "$act" "$why"
  done < "$WORK/verdicts" >> "$STATE/.wake-router.log" 2>/dev/null || :
}

record_heartbeat_pending() {
  [ -s "$WORK/heartbeat-pending" ] || return 0
  cp "$WORK/heartbeat-pending" "$STATE/.wake-router-heartbeat.pending" 2>/dev/null || :
}

backlog_has_queued_work() {
  local backlog="$FM_HOME/data/backlog.md" toml="$FM_HOME/.tasks.toml"
  if [ -f "$toml" ] && ! grep -Eq '^[[:space:]]*backend[[:space:]]*=[[:space:]]*"markdown"' "$toml"; then
    return 0  # unknown backend: assume queued work so the supervisor looks
  fi
  [ -f "$backlog" ] || return 1
  awk '/^## /{ q = ($0 ~ /^## Queued/) ; next } q && /^- / { found=1 } END { exit !found }' "$backlog"
}

# run_actions: execute every auto-act verdict; rewrite a refused one to
# needs-llm with the refusal's tail as its reason. Outcomes go to the durable
# captain-outcome file.
run_actions() {
  local seq kind cls act why task line verb atask url out rc tail
  : > "$WORK/verdicts.new"
  while IFS="$TAB" read -r seq kind cls act why task line; do
    if [ "$cls" = auto-act ]; then
      read -r verb atask url <<EOF
$act
EOF
      rc=0
      case "$verb" in
        merge) out=$("$FM_WAKE_ROUTE_MERGE_BIN" "$atask" "$url" 2>&1) || rc=$? ;;
        cleanup) out=$("$FM_WAKE_ROUTE_TEARDOWN_BIN" "$atask" 2>&1) || rc=$? ;;
        *) out="unknown action $verb"; rc=2 ;;
      esac
      tail=$(printf '%s\n' "$out" | awk 'NF { l=$0 } END { print l }' | LC_ALL=C tr '\t' ' ')
      if [ "$rc" -eq 0 ]; then
        case "$verb" in
          merge) printf '%s\tmerged %s (%s)\n' "$(date +%s)" "$url" "$atask" >> "$STATE/.wake-router-outcomes" ;;
          cleanup)
            printf '%s\tcleaned up %s after its merge landed\n' "$(date +%s)" "$atask" >> "$STATE/.wake-router-outcomes"
            if backlog_has_queued_work; then
              cls=needs-llm why="cleaned up $atask; queued work must be re-evaluated"
            fi
            ;;
        esac
        why="$why; done: $act"
      else
        cls=needs-llm why="auto-act $verb refused (exit $rc): $tail"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$kind" "$cls" "$act" "$why" "$task" "$line" >> "$WORK/verdicts.new"
  done < "$WORK/verdicts"
  mv -f "$WORK/verdicts.new" "$WORK/verdicts"
}

present_filtered() {
  local seq kind cls act why task line n_ack n_act n_llm epoch rkey payload skey aline
  n_ack=$(awk -F '\t' '$3 == "auto-ack"' "$WORK/verdicts" | awk 'END { print NR }')
  n_act=$(awk -F '\t' '$3 == "auto-act"' "$WORK/verdicts" | awk 'END { print NR }')
  n_llm=$(awk -F '\t' '$3 == "needs-llm"' "$WORK/verdicts" | awk 'END { print NR }')
  printf 'WAKE ROUTER: %s row(s) routed without you (%s acknowledged, %s acted on); %s row(s) and the sections below need you.\n' \
    "$((n_ack + n_act))" "$n_ack" "$n_act" "$n_llm"
  while IFS="$TAB" read -r seq kind cls act why task line; do
    : "$task" "$line"
    [ "$cls" != needs-llm ] || continue
    printf 'WAKE ROUTER ROUTED: row %s %s %s - %s\n' "$seq" "$kind" "$cls" "$why"
  done < "$WORK/verdicts"
  while IFS="$TAB" read -r epoch seq kind rkey payload; do
    cls=$(awk -F '\t' -v s="$seq" '$1 == s { print $3; exit }' "$WORK/verdicts")
    [ "$cls" = needs-llm ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$rkey" "$payload"
    why=$(awk -F '\t' -v s="$seq" '$1 == s { print $5; exit }' "$WORK/verdicts")
    printf 'WAKE ROUTER REASON: row %s - %s\n' "$seq" "$why"
    if [ "$kind" = signal ]; then
      task=${rkey%.status}; task=${task%.turn-ended}
      while IFS="$TAB" read -r skey aline; do
        [ "$skey" = "$task.status" ] && printf '%s\n' "$aline"
      done < "$WORK/annotations"
    fi
  done < "$WORK/rows"
  if [ -s "$WORK/backstop" ]; then
    line=$(uncovered_backstop)
    if [ -n "$line" ]; then
      printf 'STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):\n%s\n' "$line"
    fi
  fi
  [ ! -s "$WORK/forcing" ] || cat "$WORK/forcing"
  if [ -s "$STATE/.wake-router-outcomes" ]; then
    printf 'WAKE ROUTER OUTCOMES (handled without you; relay to the captain in your next reply):\n'
    cut -f2- "$STATE/.wake-router-outcomes"
    cat "$STATE/.wake-router-outcomes" >> "$STATE/.wake-router-outcomes.presented" 2>/dev/null || :
    : > "$STATE/.wake-router-outcomes"
  fi
  cat "$WORK/ack"
}

cmd_route() {
  local execute=false rc=0 verdict cmd through gen
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --execute) execute=true ;;
      *) usage ;;
    esac
    shift
  done
  new_work || exit 1
  "$FM_WAKE_ROUTE_DRAIN_BIN" > "$WORK/transcript" 2>&1 || rc=$?
  if router_steps_aside; then
    cat "$WORK/transcript"
    return "$rc"
  fi
  if [ "$rc" -ne 0 ] || ! parse_transcript "$WORK/transcript" || ! classify_rows; then
    cat "$WORK/transcript"
    return 10
  fi
  if [ "$execute" != true ] || ! fm_wake_route_config_has "$CONFIG" live; then
    log_verdicts shadow
    record_heartbeat_pending
    cat "$WORK/transcript"
    return 0
  fi
  run_actions || { cat "$WORK/transcript"; return 10; }
  log_verdicts live
  verdict=$(batch_verdict)
  if [ "${verdict%%"$TAB"*}" = routed ]; then
    cmd=$(cat "$WORK/ack")
    cmd=${cmd#WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh }
    read -r _ through _ gen <<EOF
$cmd
EOF
    case "$through" in ''|*[!0-9]*) cat "$WORK/transcript"; return 10 ;; esac
    if "$FM_WAKE_ROUTE_DRAIN_BIN" --ack-through "$through" --recovery-generation "$gen" > "$WORK/ack-out" 2>&1; then
      # Every row, heartbeats included, was routed: the fingerprint that let a
      # heartbeat through is unchanged, so nothing new is committed.
      printf 'WAKE ROUTER: all %s row(s) routed and acknowledged through %s; no supervisor turn needed.\n' \
        "$(awk 'END { print NR }' "$WORK/rows")" "$through"
      return 0
    fi
    # The acknowledgement failed: hand the whole batch to the supervisor.
    cat "$WORK/transcript" "$WORK/ack-out"
    return 10
  fi
  record_heartbeat_pending
  present_filtered
  return 10
}

# --- replay -----------------------------------------------------------------
# Corpus columns (TAB-separated, '#' lines ignored):
#   1 id  2 source  3 expected-class  4 kind  5 key  6 payload
#   7 events (status lines joined by " || ", or "-")
#   8 meta (comma-separated k=v, or "-")  9 crew-state line (or "-")
#   10 extras (comma-separated: relaunches=<n>, heartbeat=unchanged|changed,
#      config=<token>+<token>, paused_age=<seconds>)
cmd_replay() {
  local corpus=${1:-} id src expect kind key payload events meta crew extras
  local home state config kv item n=0 bad=0 cls total_ack=0 total_act=0 total_llm=0 now line
  [ -n "$corpus" ] && [ -r "$corpus" ] || usage
  new_work || exit 1
  cat > "$WORK/crew-stub" <<'STUB'
#!/usr/bin/env bash
cat "$FM_STATE_OVERRIDE/$1.router-crew" 2>/dev/null
STUB
  chmod +x "$WORK/crew-stub"
  now=$(date +%s)
  printf 'ID\tEXPECTED\tGOT\tACTION\tREASON\n'
  while IFS="$TAB" read -r id src expect kind key payload events meta crew extras; do
    case "$id" in ''|'#'*) continue ;; esac
    : "$src"
    n=$((n + 1))
    home="$WORK/home-$n"
    state="$home/state"
    config="$home/config"
    mkdir -p "$state" "$config"
    : > "$state/.wake-queue"
    : > "$WORK/replay-events"
    if [ "$events" != - ]; then
      printf '%s\n' "$events" | awk '{ n = split($0, p, / \|\| /); for (i = 1; i <= n; i++) print p[i] }' > "$WORK/replay-events"
    fi
    case "$kind" in
      signal) item=${key%.status}; item=${item%.turn-ended} ;;
      stale) item=${key##*:}; item=${item#fm-} ;;
      check)
        item=
        case "$payload" in
          'check: merge landed: '*) item=${payload#check: merge landed: }; item=${item%% *} ;;
          'check: secondmate '*|'check: task '*) item=${payload#check: }; item=${item#* }; item=${item%% *} ;;
        esac
        ;;
      *) item= ;;
    esac
    if [ -n "$item" ] && [ "$meta" != - ]; then
      printf '%s\n' "$meta" | tr ',' '\n' > "$state/$item.meta"
      grep -q '^window=' "$state/$item.meta" || printf 'window=firstmate:fm-%s\n' "$item" >> "$state/$item.meta"
    fi
    if [ -n "$item" ] && [ -s "$WORK/replay-events" ]; then
      cp "$WORK/replay-events" "$state/$item.status"
    fi
    [ -z "$item" ] || [ "$crew" = - ] || printf '%s\n' "$crew" > "$state/$item.router-crew"
    for kv in $(printf '%s' "$extras" | tr ',' ' '); do
      case "$kv" in
        relaunches=*) : > "$state/.secondmate-relaunch-$item"
          for _ in $(seq 1 "${kv#relaunches=}"); do printf '%s\tdead\n' "$now" >> "$state/.secondmate-relaunch-$item"; done ;;
        config=*) printf '%s\n' "${kv#config=}" | tr '+' '\n' > "$config/wake-router" ;;
        paused_age=*)
          line="paused [at=$((now - ${kv#paused_age=}))]: waiting on upstream CI"
          printf '%s\n' "$line" > "$state/$item.status" ;;
        heartbeat=unchanged)
          FM_STATE_OVERRIDE=$state fm_wake_route_fleet_fingerprint "$state" > "$state/.wake-router-heartbeat" ;;
      esac
    done
    FM_CREW_STATE_BIN="$WORK/crew-stub" FM_HOME=$home FM_STATE_OVERRIDE=$state FM_WAKE_QUEUE="$state/.wake-queue" FM_WR_SEQ=$n \
      fm_wake_route_row "$state" "$config" "$kind" "$key" "$payload" "$WORK/replay-events"
    cls=$FM_WR_CLASS
    case "$cls" in
      auto-ack) total_ack=$((total_ack + 1)) ;;
      auto-act) total_act=$((total_act + 1)) ;;
      *) total_llm=$((total_llm + 1)) ;;
    esac
    if [ "$expect" != "$cls" ]; then
      bad=$((bad + 1))
      printf '%s\t%s\t%s\t%s\t%s\tMISMATCH\n' "$id" "$expect" "$cls" "$FM_WR_ACTION" "$FM_WR_REASON"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$expect" "$cls" "$FM_WR_ACTION" "$FM_WR_REASON"
    fi
  done < "$corpus"
  [ "$n" -gt 0 ] || { printf 'replay: corpus has no rows\n' >&2; exit 1; }
  awk -v n="$n" -v a="$total_ack" -v c="$total_act" -v l="$total_llm" -v b="$bad" 'BEGIN {
    printf "SUMMARY\trows=%d\tauto-ack=%d (%.1f%%)\tauto-act=%d (%.1f%%)\tneeds-llm=%d (%.1f%%)\tmismatches=%d\n",
      n, a, 100 * a / n, c, 100 * c / n, l, 100 * l / n, b
  }'
  [ "$bad" -eq 0 ]
}

case "${1:-}" in
  classify) shift; [ "$#" -eq 0 ] || usage; cmd_classify ;;
  route) shift; cmd_route "$@" ;;
  replay) shift; [ "$#" -eq 1 ] || usage; cmd_replay "$1" ;;
  *) usage ;;
esac
