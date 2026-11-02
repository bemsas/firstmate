#!/usr/bin/env bash
# Deterministic wake router classifier (prototype): the single owner of which
# queued wake rows can be handled without a supervisor model turn.
#
# Every row the drain presents is routed to exactly one class:
#   auto-ack   nothing needs doing; the row is safe to acknowledge unread
#   auto-act   one known, scripted, guard-owned action handles it completely
#   needs-llm  a real decision, or anything this classifier cannot prove safe
# needs-llm is the default: a rule below must positively match a row's shape
# AND its current evidence before either other class is returned, so a new,
# renamed, or malformed wake shape always reaches the supervisor.
# docs/wake-router.md owns the design, rule rationale, and safety limits;
# bin/fm-wake-route.sh owns presentation, action execution, and acknowledgement.
#
# Classification is read-only. It reads the row, the drain's own annotation
# lines for that row (the events the supervisor would have been shown), the
# task's state/<id>.meta, the secondmate relaunch ledger, and, only for rows
# whose answer depends on live state, one bin/fm-crew-state.sh line
# (FM_CREW_STATE_BIN, the same seam bin/fm-classify-lib.sh honors).
# It never writes, never acknowledges, and never runs an action.
#
# Result contract: fm_wake_route_row sets
#   FM_WR_CLASS   auto-ack | auto-act | needs-llm
#   FM_WR_ACTION  none | merge <task> <url> | cleanup <task>
#   FM_WR_REASON  one line naming the rule that matched
#   FM_WR_TASK    the task the row resolved to, or empty
#   FM_WR_LINE    the status event an auto-act or auto-ack was decided on
# and returns 0; it returns 2 only for a usage error.
#
# Opt-in configuration (config/wake-router, one token per line):
#   live        bin/fm-wake-route.sh may act and acknowledge; otherwise shadow
#   auto-merge  a yolo, checks-green ship PR may route to the merge action;
#               without it that row stays needs-llm even under yolo
# Tunables: FM_WAKE_ROUTE_PAUSE_MAX_SECS (default 86400) bounds how old a
# declared wait may be for its recheck to be auto-acknowledged.

_FM_WAKE_ROUTER_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_WAKE_ROUTER_LIB_DIR="."

# bin/fm-classify-lib.sh owns status verb parsing, the declared-wait
# vocabulary, and window-to-task resolution; the router reuses them rather
# than re-deriving any of that grammar.
case $- in *u*) _fm_wr_nounset=on ;; *) _fm_wr_nounset=off ;; esac
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_WAKE_ROUTER_LIB_DIR/fm-classify-lib.sh"
[ "$_fm_wr_nounset" = on ] || set +u
unset _fm_wr_nounset

FM_WR_CLASS=
FM_WR_ACTION=
FM_WR_REASON=
FM_WR_TASK=
FM_WR_LINE=
FM_WR_HEARTBEAT_PENDING=

_fm_wr_set() {  # <class> <action> <reason>
  FM_WR_CLASS=$1
  FM_WR_ACTION=$2
  FM_WR_REASON=$3
}

# fm_wake_route_config_has <config-dir> <token>: 0 when config/wake-router
# names <token> on a line of its own. An absent or unreadable file names none.
fm_wake_route_config_has() {
  local dir=$1 token=$2 line
  [ -f "$dir/wake-router" ] && [ -r "$dir/wake-router" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [ "$line" = "$token" ] && return 0
  done < "$dir/wake-router"
  return 1
}

# fm_wake_route_meta <state> <task> <field>: the last value of <field> in
# state/<task>.meta, or nothing. A task id that could escape the state
# directory reads nothing.
fm_wake_route_meta() {
  local state=$1 task=$2 field=$3 line value=
  case "$task" in ''|*/*|.*) return 0 ;; esac
  [ -f "$state/$task.meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$field="*) value=${line#"$field="} ;; esac
  done < "$state/$task.meta" 2>/dev/null
  printf '%s' "$value"
}

# fm_wake_route_crew_state <state> <task>: the first line of the current-state
# reader, or nothing when it cannot answer. Never fatal: an unanswered read is
# simply not evidence for an absorb.
fm_wake_route_crew_state() {
  local state=$1 task=$2 home
  home=${FM_HOME:-${state%/state}}
  FM_HOME=$home FM_STATE_OVERRIDE=$state FM_CREW_STATE_NO_FORGE=1 \
    "$FM_CREW_STATE_BIN" "$task" 2>/dev/null | head -n 1 || true
}

# _fm_wr_crew_word <crew-state-line>: the <word> of "state: <word> · ...".
_fm_wr_crew_word() {
  local line=$1 word
  case "$line" in
    'state: '*) word=${line#state: }; word=${word%%[[:space:]]*}; printf '%s' "$word" ;;
  esac
}

# _fm_wr_pr_url <status-line>: the first forge PR/MR URL the line names.
_fm_wr_pr_url() {
  local word
  for word in $1; do
    case "$word" in
      https://*/pull/[0-9]*|https://*/merge_requests/[0-9]*|https://*/pulls/[0-9]*)
        word=${word%%[),.;]}
        printf '%s' "$word"
        return 0
        ;;
    esac
  done
  return 1
}

# fm_wake_route_event <state> <config> <task> <status-line>
# Classify ONE status event line for <task>. Sets the FM_WR_* result.
fm_wake_route_event() {
  local state=$1 config=$2 task=$3 line=$4 verb kind mode yolo forge url crew word xreq
  FM_WR_LINE=$line
  if status_prefix_unrecognized "$line" >/dev/null 2>&1; then
    _fm_wr_set needs-llm none "unrecognized status prefix"
    return 0
  fi
  verb=$(status_line_verb "$line")
  kind=$(fm_wake_route_meta "$state" "$task" kind)
  case "$verb" in
    needs-decision|blocked|failed)
      _fm_wr_set needs-llm none "worker raised $verb"
      return 0
      ;;
    captain-held)
      _fm_wr_set needs-llm none "captain-held transfer must reach the captain"
      return 0
      ;;
    note|resolved)
      _fm_wr_set needs-llm none "informational $verb line must be read"
      return 0
      ;;
    paused)
      _fm_wr_set auto-ack none "worker declared a wait (paused:)"
      return 0
      ;;
    done) ;;
    *)
      # A no-verb line (working:, progress prose) is absorbed only on the same
      # positive execution evidence the watcher itself requires.
      crew=$(fm_wake_route_crew_state "$state" "$task")
      word=$(_fm_wr_crew_word "$crew")
      case "$word" in
        working) _fm_wr_set auto-ack none "no-verb event; current state reads working" ;;
        paused) _fm_wr_set auto-ack none "no-verb event; current state reads a declared wait" ;;
        *) _fm_wr_set needs-llm none "no-verb event without working evidence (${word:-unknown})" ;;
      esac
      return 0
      ;;
  esac

  # done: only a yolo, checks-green ship PR is ever scripted.
  case "$kind" in
    ship) ;;
    scout) _fm_wr_set needs-llm none "scout finished: findings must be relayed"; return 0 ;;
    *) _fm_wr_set needs-llm none "done from a ${kind:-unrecorded} task"; return 0 ;;
  esac
  if ! url=$(_fm_wr_pr_url "$line"); then
    _fm_wr_set needs-llm none "ship done without a PR (handoff, local-only, or review upload)"
    return 0
  fi
  mode=$(fm_wake_route_meta "$state" "$task" mode)
  yolo=$(fm_wake_route_meta "$state" "$task" yolo)
  forge=$(fm_wake_route_meta "$state" "$task" forge)
  xreq=$(fm_wake_route_meta "$state" "$task" x_request)
  if [ "$yolo" != on ]; then
    _fm_wr_set needs-llm none "PR ready; merge needs the captain (yolo off)"
  elif [ -n "$xreq" ]; then
    _fm_wr_set needs-llm none "PR ready on Relay-linked work: public follow-up owed"
  elif [ -n "$forge" ] && [ "$forge" != none ]; then
    _fm_wr_set needs-llm none "PR ready on forge=$forge"
  elif [ "$mode" != no-mistakes ] && [ "$mode" != direct-PR ]; then
    _fm_wr_set needs-llm none "PR ready in mode ${mode:-unrecorded}"
  else
    case " $line " in
      *' checks green '*) ;;
      *) _fm_wr_set needs-llm none "PR ready but the ready line does not report checks green"; return 0 ;;
    esac
    if fm_wake_route_config_has "$config" auto-merge; then
      _fm_wr_set auto-act "merge $task $url" "yolo ship PR reports checks green"
    else
      _fm_wr_set needs-llm none "yolo ship PR checks green; router auto-merge not enabled"
    fi
  fi
  return 0
}

_fm_wr_rank() {
  case "$1" in needs-llm) echo 3 ;; auto-act) echo 2 ;; auto-ack) echo 1 ;; *) echo 3 ;; esac
}

# fm_wake_route_events <state> <config> <task> <events-file>
# Fold every event line in <events-file> (one per line): the most severe
# class wins, needs-llm > auto-act > auto-ack. Two scripted actions in one row
# are never combined; the second makes the row needs-llm.
fm_wake_route_events() {
  local state=$1 config=$2 task=$3 events=$4 line best=0 rank cls='' act=none why='' bline=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    fm_wake_route_event "$state" "$config" "$task" "$line"
    rank=$(_fm_wr_rank "$FM_WR_CLASS")
    if [ "$FM_WR_CLASS" = auto-act ] && [ "$act" != none ] && [ "$act" != "$FM_WR_ACTION" ]; then
      cls=needs-llm act=none why="two scripted actions in one wake" best=3 bline=$line
      continue
    fi
    if [ "$rank" -gt "$best" ]; then
      best=$rank cls=$FM_WR_CLASS act=$FM_WR_ACTION why=$FM_WR_REASON bline=$line
    fi
  done < "$events"
  if [ -z "$cls" ]; then
    _fm_wr_set needs-llm none "no status event to classify"
    FM_WR_LINE=
    return 0
  fi
  _fm_wr_set "$cls" "$act" "$why"
  FM_WR_LINE=$bline
}

# fm_wake_route_row <state> <config> <kind> <key> <payload> <events-file>
# Classify one durable wake row. <events-file> holds the status event lines
# the drain annotated for this row (possibly empty).
fm_wake_route_row() {
  local state=$1 config=$2 kind=$3 key=$4 payload=$5 events=$6 task window crew word
  local ledger n max age at now until line
  FM_WR_TASK='' FM_WR_LINE='' FM_WR_HEARTBEAT_PENDING=''
  [ "$#" -eq 6 ] || { printf 'fm_wake_route_row: expected 6 arguments\n' >&2; return 2; }
  case "$kind" in
    signal)
      task=${key%.status}
      task=${task%.turn-ended}
      case "$task" in ''|*/*|.*) _fm_wr_set needs-llm none "signal key does not name a task"; return 0 ;; esac
      FM_WR_TASK=$task
      if [ ! -s "$events" ]; then
        # No unread event was annotated (a bare turn-end, or bytes already
        # presented): fall back to the newest recorded event, then current state.
        last_status_line "$state/$task.status" > "$events.last" 2>/dev/null || :
        if [ ! -s "$events.last" ]; then
          rm -f -- "$events.last"
          crew=$(fm_wake_route_crew_state "$state" "$task")
          word=$(_fm_wr_crew_word "$crew")
          case "$word" in
            working|paused) _fm_wr_set auto-ack none "bare turn-end; current state reads $word" ;;
            *) _fm_wr_set needs-llm none "signal with no readable event (${word:-unknown})" ;;
          esac
          return 0
        fi
        # An already-presented terminal or decision event is not news, but
        # this classifier cannot prove it was handled, so only a declared wait
        # or provable work is absorbed from the replayed newest event.
        fm_wake_route_events "$state" "$config" "$task" "$events.last"
        rm -f -- "$events.last"
        if [ "$FM_WR_CLASS" = auto-act ]; then
          _fm_wr_set needs-llm none "scripted action only on an unread event"
        fi
        return 0
      fi
      fm_wake_route_events "$state" "$config" "$task" "$events"
      return 0
      ;;
    stale)
      window=$key
      task=$(window_to_task "$window" "$state")
      FM_WR_TASK=$task
      case "$payload" in
        *escalation*|*demand-deep-inspection*|*PERMANENTLY-WEDGED*|*blocked-on-prompt:*|*'unread firstmate instruction'*|*unwritable*|*'possible wedge'*|*'no agent'*)
          _fm_wr_set needs-llm none "stale escalation or recovery evidence in the reason"
          return 0
          ;;
      esac
      crew=$(fm_wake_route_crew_state "$state" "$task")
      word=$(_fm_wr_crew_word "$crew")
      case "$payload" in
        *'(paused'*|*'awaiting external'*|*'declared wait'*|*'captain-held'*)
          case "$payload" in
            *captain*) _fm_wr_set needs-llm none "recheck of a wait held on the captain"; return 0 ;;
          esac
          if [ "$word" != paused ]; then
            _fm_wr_set needs-llm none "declared-wait recheck but current state reads ${word:-unknown}"
            return 0
          fi
          at=
          line=$(status_declared_wait_line "$state/$task.status" 2>/dev/null) || line=
          [ -z "$line" ] || at=$(status_line_at_epoch "$line" 2>/dev/null) || at=
          max=${FM_WAKE_ROUTE_PAUSE_MAX_SECS:-86400}
          case "$max" in ''|*[!0-9]*) max=86400 ;; esac
          now=$(date +%s)
          case "$at" in
            ''|*[!0-9]*) _fm_wr_set needs-llm none "declared-wait recheck with no declaration time"; return 0 ;;
          esac
          age=$(( now - at ))
          until=$(status_paused_until "$line" 2>/dev/null) || until=
          if [ -n "$until" ] && [ "$until" -le "$now" ]; then
            _fm_wr_set needs-llm none "declared wait named a clear time that has passed"
          elif [ "$age" -le "$max" ]; then
            FM_WR_LINE=$line
            _fm_wr_set auto-ack none "declared wait still current (${age}s old)"
          else
            _fm_wr_set needs-llm none "declared wait ${age}s old exceeds ${max}s"
          fi
          return 0
          ;;
      esac
      case "$payload" in
        "stale: $window") ;;
        *'rechecked on a long cadence not a wedge'*)
          # The watcher's own deferral rechecks (worktree writes, a validating
          # run, a backlog hold): absorbed only when the crew reads working now.
          case "$payload" in
            *captain*|*'held'*) _fm_wr_set needs-llm none "deferral recheck involving a hold"; return 0 ;;
          esac
          if [ "$word" = working ]; then
            _fm_wr_set auto-ack none "long-cadence deferral recheck; current state reads working"
          else
            _fm_wr_set needs-llm none "long-cadence deferral recheck; current state reads ${word:-unknown}"
          fi
          return 0
          ;;
        *) _fm_wr_set needs-llm none "unrecognized stale reason"; return 0 ;;
      esac
      if [ "$word" = working ]; then
        _fm_wr_set auto-ack none "first-sight stale; current state reads working"
      else
        _fm_wr_set needs-llm none "stale pane not provably working (${word:-unknown})"
      fi
      return 0
      ;;
    check)
      case "$payload" in
        *';'*) _fm_wr_set needs-llm none "joined check outputs"; return 0 ;;
      esac
      case "$payload" in
        'check: merge landed: '*)
          task=${payload#check: merge landed: }
          task=${task%%[[:space:]]*}
          case "$task" in ''|*/*|.*) _fm_wr_set needs-llm none "merge outcome names no task"; return 0 ;; esac
          FM_WR_TASK=$task
          if [ ! -f "$state/$task.meta" ]; then
            _fm_wr_set auto-ack none "merge landed for a task already cleaned up"
          elif [ "$(fm_wake_route_meta "$state" "$task" kind)" != ship ]; then
            _fm_wr_set needs-llm none "merge landed for a non-ship task"
          elif [ -n "$(fm_wake_route_meta "$state" "$task" x_request)" ]; then
            _fm_wr_set needs-llm none "merge landed on Relay-linked work: final follow-up owed"
          else
            _fm_wr_set auto-act "cleanup $task" "merge landed; guarded cleanup"
          fi
          return 0
          ;;
        'check: secondmate '*' auto-relaunched after '*)
          task=${payload#check: secondmate }
          task=${task%% *}
          case "$task" in ''|*/*|.*) _fm_wr_set needs-llm none "relaunch names no secondmate"; return 0 ;; esac
          FM_WR_TASK=$task
          ledger="$state/.secondmate-relaunch-$task"
          n=0
          [ ! -r "$ledger" ] || n=$(awk 'END { print NR }' "$ledger" 2>/dev/null) || n=99
          if [ "$n" -gt 1 ]; then
            _fm_wr_set needs-llm none "secondmate relaunched $n times: investigate the repeat"
            return 0
          fi
          crew=$(fm_wake_route_crew_state "$state" "$task")
          word=$(_fm_wr_crew_word "$crew")
          case "$word" in
            working|paused|parked|done) _fm_wr_set auto-ack none "first relaunch already completed; mate reads $word" ;;
            *) _fm_wr_set needs-llm none "relaunched mate reads ${word:-unknown}" ;;
          esac
          return 0
          ;;
        'check: task '*' auto-relaunched after broken model session'*)
          task=${payload#check: task }
          task=${task%% *}
          FM_WR_TASK=$task
          crew=$(fm_wake_route_crew_state "$state" "$task")
          word=$(_fm_wr_crew_word "$crew")
          if [ "$word" = working ]; then
            _fm_wr_set auto-ack none "broken-session relaunch completed; worker reads working"
          else
            _fm_wr_set needs-llm none "relaunched worker reads ${word:-unknown}"
          fi
          return 0
          ;;
      esac
      _fm_wr_set needs-llm none "check result needs a decision"
      return 0
      ;;
    heartbeat)
      fm_wake_route_heartbeat "$state" "${FM_WR_SEQ:-0}"
      return 0
      ;;
  esac
  _fm_wr_set needs-llm none "unknown wake kind"
  return 0
}

# fm_wake_route_fleet_fingerprint <state>: a stable digest of what a heartbeat
# fleet review reads - each task's status log size and newest event, and each
# meta file's identity and PR fields. Any change makes the next heartbeat
# needs-llm again.
fm_wake_route_fleet_fingerprint() {
  local state=$1 f
  {
    for f in "$state"/*.status; do
      [ -f "$f" ] || continue
      printf 'S\t%s\t%s\t%s\n' "${f##*/}" "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "$(last_status_line "$f" 2>/dev/null)"
    done
    for f in "$state"/*.meta; do
      [ -f "$f" ] || continue
      printf 'M\t%s\t%s\n' "${f##*/}" "$(grep -E '^(kind|pr|pr_head|yolo|mode)=' "$f" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
    done
  } | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{ print $1 }'
}

# fm_wake_route_heartbeat <state> <seq>: classify a heartbeat row against the
# fingerprint committed when the last heartbeat was acknowledged. The
# commitment is two-phase so an interrupted turn cannot launder a review:
# .wake-router-heartbeat.pending holds "<seq> <fingerprint>" from the turn that
# presented it, and is promoted to .wake-router-heartbeat only once that seq is
# gone from the queue, meaning a supervisor acknowledged it after handling.
fm_wake_route_heartbeat() {
  local state=$1 seq=$2 fp pseq pfp committed=''
  if [ -r "$state/.wake-router-heartbeat.pending" ]; then
    read -r pseq pfp < "$state/.wake-router-heartbeat.pending" || pseq=
    if [ -n "${pseq:-}" ] && ! awk -F '\t' -v s="$pseq" '$2 == s { found=1 } END { exit !found }' "${FM_WAKE_QUEUE:-$state/.wake-queue}" 2>/dev/null; then
      printf '%s\n' "$pfp" > "$state/.wake-router-heartbeat" 2>/dev/null || :
      rm -f -- "$state/.wake-router-heartbeat.pending"
    fi
  fi
  [ ! -r "$state/.wake-router-heartbeat" ] || read -r committed < "$state/.wake-router-heartbeat" || committed=
  fp=$(fm_wake_route_fleet_fingerprint "$state")
  # shellcheck disable=SC2034 # Result variables read by the sourcing caller.
  FM_WR_TASK='' FM_WR_LINE=''
  if [ -n "$fp" ] && [ "$fp" = "$committed" ]; then
    _fm_wr_set auto-ack none "heartbeat: fleet unchanged since the last reviewed heartbeat"
  else
    _fm_wr_set needs-llm none "heartbeat: fleet changed since the last reviewed heartbeat"
    # shellcheck disable=SC2034 # Result variable read by the sourcing caller.
    FM_WR_HEARTBEAT_PENDING="$seq $fp"
  fi
}
