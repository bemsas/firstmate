#!/usr/bin/env bash
# Retire the Herdr terminal pane of a finished ship worker before its PR lands.
#
# Usage: fm-pane-retire.sh [--apply] [--auto] [<task-id>...]
#
#   (no flag)  dry run: print one verdict line per task and close nothing.
#   --apply    print the same listing, then close every pane listed as `retire`.
#   --auto     the watcher's entry point: does nothing unless config/pane-retire
#              holds `on`, then behaves as --apply and prints only closes and
#              refusals. A bare listing is for the captain; this one is silent.
#   <task-id>  restrict the run to these tasks (default: every state/*.meta).
#
# Why: teardown closes a worker's pane only after landing, so a worker that
# finished long ago keeps a dead shell or an idle agent open for as long as its
# PR waits for merge. This step closes just that pane once the work is safe.
#
# A pane is closed only when ALL of these hold; every other outcome keeps it:
#   - the task is a Herdr ship worker whose metadata passes the shared exact
#     endpoint validation, and the pane Herdr reports under the recorded pane id
#     is in the recorded workspace and tab (a reused or foreign id is refused);
#   - the last status event is `done`, no steering message is waiting unread in
#     state/<id>.inbox, and the task has no presentation journal (a projected
#     workspace is left to teardown, which owns that journal);
#   - the delivery is safe off the pane: a recorded `pr=` whose `pr_head=`, when
#     recorded, still equals the worktree HEAD, or a worktree HEAD already
#     contained in a remote-tracking ref;
#   - the worktree is a clean checkout (no tracked or untracked change);
#   - the agent is provably gone or provably idle, by process proof and never by
#     the agent-status label alone:
#       idle-shell  Herdr's agent state is `no-agent` or `stale-agent` AND the
#                   pane holds one lone idle shell with no child process
#                   (fm_backend_herdr_pane_idle_shell_pid, the proof every
#                   pane-death close already relies on);
#       idle-agent  Herdr's agent state is `live`, its status reads idle or
#                   done, the foreground process group is the harness alone
#                   (fm_backend_herdr_pane_process_state is `agent`, so no tool
#                   is running in its own group), and the `done` line is at
#                   least FM_PANE_RETIRE_MIN_AGE seconds old (default 120).
#
# The close is the existing exact-pane focus-preserving helper
# (fm_backend_herdr_projection_close_pane_focus_preserving), called with the
# observed agent state as its required state so it re-reads that state at the
# close boundary. It runs under the task's spawn lock and the shared named
# session presentation lock, after the whole verdict is recomputed inside both
# locks. A busy lock, a changed verdict, a refused focus-unsafe close, or an
# unconfirmed close keeps the pane and reports why.
#
# A worker's Treehouse slot is held only by the process lease of the
# interactive `treehouse get` running in the pane, so closing the pane would
# free a clean slot for the next `treehouse get` to reset while the PR still
# waits for merge. Before any close the script therefore converts that hold into
# a durable lease (`treehouse lease`, a state-only operation that never touches
# the checkout), under the project's Treehouse lock, and refuses the close
# unless `treehouse status --json` then reports the slot leased. Teardown's
# `treehouse return --force` releases that lease like any other. A worktree that
# is not a Treehouse pool slot has no process lease to lapse and needs no lease.
#
# This script never edits or removes state/<id>.meta, the status log, the
# worktree's files, the branch, or any other task record: teardown after landing
# still owns those, and fm-spawn.sh --relaunch (bin/fm-control.sh relaunch)
# re-creates the endpoint of a proven-gone pane in the recorded worktree when a
# review fix needs the worker again. A second run finds the pane gone and is a
# no-op.
#
# Output: `retire|keep|gone <id> <detail>` per task, then `closed|refused <id>`
# per attempted close under --apply, then a summary line.
# Exit: 0 on any completed run, 2 on a usage error. A per-task problem is a
# `keep` or `refused` line, never a failed run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
fm_backend_source herdr

FM_PANE_RETIRE_MIN_AGE="${FM_PANE_RETIRE_MIN_AGE:-120}"
case "$FM_PANE_RETIRE_MIN_AGE" in
  ''|*[!0-9]*) FM_PANE_RETIRE_MIN_AGE=120 ;;
esac

# Verdict outputs of fm_pane_retire_evaluate.
FM_PANE_RETIRE_VERDICT=
FM_PANE_RETIRE_DETAIL=
FM_PANE_RETIRE_PROOF=
FM_PANE_RETIRE_AGENT_STATE=
FM_PANE_RETIRE_SESSION=
FM_PANE_RETIRE_PANE=

fm_pane_retire_enabled() {
  local flag="$CONFIG/pane-retire"
  [ -f "$flag" ] && [ ! -L "$flag" ] || return 1
  [ "$(tr -d '[:space:]' < "$flag" 2>/dev/null)" = on ]
}

fm_pane_retire_keep() {  # <detail>
  FM_PANE_RETIRE_VERDICT=keep
  FM_PANE_RETIRE_DETAIL=$1
  return 0
}

# The worktree holds no change a retired pane could be hiding: clean to
# `git status`, untracked files included.
fm_pane_retire_worktree_clean() {  # <worktree>
  local out
  out=$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null) || return 1
  [ -z "$out" ]
}

# The delivery no longer depends on the pane: a recorded PR whose recorded head
# still names this worktree's HEAD (or that recorded no head), or a HEAD that a
# remote-tracking ref already contains.
fm_pane_retire_delivered() {  # <meta> <worktree>
  local meta=$1 wt=$2 head pr pr_head contained
  head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  pr=$(fm_meta_get "$meta" pr)
  pr_head=$(fm_meta_get "$meta" pr_head)
  if [ -n "$pr" ] && { [ -z "$pr_head" ] || [ "$pr_head" = "$head" ]; }; then
    return 0
  fi
  contained=$(git -C "$wt" for-each-ref --contains "$head" --count=1 \
    --format='%(refname)' refs/remotes 2>/dev/null) || return 1
  [ -n "$contained" ]
}

fm_pane_retire_inbox_pending() {  # <id>
  local dir="$STATE/$1.inbox" f
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.msg; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# The pane Herdr reports under the recorded id must sit in the recorded
# workspace and tab; anything else is a reused or foreign id.
fm_pane_retire_pane_is_recorded() {  # <session> <pane> <workspace> <tab>
  local info
  info=$(fm_backend_herdr_cli "$1" pane get "$2" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$2" --arg ws "$3" --arg tab "$4" '
    .result.pane.pane_id == $pane
    and .result.pane.workspace_id == $ws
    and .result.pane.tab_id == $tab
  ' >/dev/null 2>&1
}

# Compute the verdict for one task into the FM_PANE_RETIRE_* outputs.
fm_pane_retire_evaluate() {  # <id>
  local id=$1 meta="$STATE/$1.meta" kind backend wt session pane workspace tab
  local last verb presence state raw done_at now age
  FM_PANE_RETIRE_VERDICT=keep
  FM_PANE_RETIRE_DETAIL=
  FM_PANE_RETIRE_PROOF=
  FM_PANE_RETIRE_AGENT_STATE=
  FM_PANE_RETIRE_SESSION=
  FM_PANE_RETIRE_PANE=

  [ -f "$meta" ] && [ ! -L "$meta" ] || { fm_pane_retire_keep "no task record"; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  kind=$(fm_meta_get "$meta" kind)
  [ "$backend" = herdr ] || { fm_pane_retire_keep "not a herdr worker"; return 0; }
  case "${kind:-ship}" in
    ship) ;;
    *) fm_pane_retire_keep "not a ship worker (kind=$kind)"; return 0 ;;
  esac
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 \
    || { fm_pane_retire_keep "endpoint record is not exact"; return 0; }
  session=$(fm_backend_meta_exact_value "$meta" herdr_session) || session=
  pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || pane=
  workspace=$(fm_backend_meta_exact_value "$meta" herdr_workspace_id) || workspace=
  tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id) || tab=
  FM_PANE_RETIRE_SESSION=$session
  FM_PANE_RETIRE_PANE=$pane

  last=$(last_status_line "$STATE/$id.status")
  verb=$(status_line_verb "$last")
  [ "$verb" = "done" ] || { fm_pane_retire_keep "last status is ${verb:-empty}, not done"; return 0; }
  if fm_pane_retire_inbox_pending "$id"; then
    fm_pane_retire_keep "a steering message is still waiting"
    return 0
  fi
  if [ -e "$STATE/$id.herdr-presentation" ] || [ -L "$STATE/$id.herdr-presentation" ]; then
    fm_pane_retire_keep "projected workspace is left to teardown"
    return 0
  fi

  wt=$(fm_backend_meta_exact_value "$meta" worktree) || wt=
  [ -n "$wt" ] && [ -d "$wt" ] || { fm_pane_retire_keep "worktree is missing"; return 0; }
  fm_pane_retire_delivered "$meta" "$wt" \
    || { fm_pane_retire_keep "no recorded PR for this head and head not pushed"; return 0; }
  fm_pane_retire_worktree_clean "$wt" \
    || { fm_pane_retire_keep "worktree is not clean"; return 0; }

  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
  case "$presence" in
    dead) FM_PANE_RETIRE_VERDICT=gone; FM_PANE_RETIRE_DETAIL="$session:$pane already closed"; return 0 ;;
    present) ;;
    *) fm_pane_retire_keep "pane presence is unreadable"; return 0 ;;
  esac
  fm_pane_retire_pane_is_recorded "$session" "$pane" "$workspace" "$tab" \
    || { fm_pane_retire_keep "pane is not the recorded workspace and tab"; return 0; }

  state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
  FM_PANE_RETIRE_AGENT_STATE=$state
  case "$state" in
    no-agent|stale-agent)
      fm_backend_herdr_pane_shell_tree_proof "$session" "$pane" >/dev/null 2>&1 \
        || { fm_pane_retire_keep "pane shell is not provably idle"; return 0; }
      FM_PANE_RETIRE_PROOF=idle-shell
      ;;
    live)
      raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane")
      case "$raw" in
        idle|done) ;;
        *) fm_pane_retire_keep "agent is ${raw:-unreadable}, not idle"; return 0 ;;
      esac
      [ "$(fm_backend_herdr_pane_process_state "$session" "$pane")" = agent ] \
        || { fm_pane_retire_keep "something besides the agent runs in the pane"; return 0; }
      done_at=$(status_line_at_epoch "$last") \
        || { fm_pane_retire_keep "done line has no timestamp to age"; return 0; }
      now=$(date +%s)
      age=$((now - done_at))
      [ "$age" -ge "$FM_PANE_RETIRE_MIN_AGE" ] \
        || { fm_pane_retire_keep "done line is ${age}s old, under ${FM_PANE_RETIRE_MIN_AGE}s"; return 0; }
      FM_PANE_RETIRE_PROOF=idle-agent
      ;;
    dead) FM_PANE_RETIRE_VERDICT=gone; FM_PANE_RETIRE_DETAIL="$session:$pane already closed"; return 0 ;;
    *) fm_pane_retire_keep "agent state is $state"; return 0 ;;
  esac
  FM_PANE_RETIRE_VERDICT=retire
  FM_PANE_RETIRE_DETAIL="$session:$pane $FM_PANE_RETIRE_PROOF"
}

# Make the task's Treehouse slot survive the pane. Succeeds when the worktree
# is not a pool slot, or when it is (or after `treehouse lease` has made it) a
# durable lease that `treehouse status --json` confirms for this exact path.
fm_pane_retire_slot_state() {  # <slot-path>
  local json
  json=$(cd -- "$1" 2>/dev/null && treehouse status --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r --arg path "$1" \
    '[.[]? | select(.path == $path)] | if length == 1 then .[0].status // "" else "" end' 2>/dev/null
}

fm_pane_retire_hold_slot() {  # <id> <project> <worktree>
  local id=$1 project=$2 wt=$3 slot name state lock
  slot=$(cd -- "$wt" 2>/dev/null && pwd -P) || return 1
  fm_treehouse_pool_slot "$project" "$slot" || return 0
  command -v treehouse >/dev/null 2>&1 || return 1
  [ "$(fm_pane_retire_slot_state "$slot")" != leased ] || return 0
  lock=$(fm_treehouse_project_lock_path "$project") || return 1
  fm_lock_try_acquire "$lock" || return 1
  name=$(basename "$(dirname "$slot")")
  (cd -- "$slot" && treehouse lease "$name" --lease-holder "fm-$id") >/dev/null 2>&1 || true
  state=$(fm_pane_retire_slot_state "$slot")
  fm_lock_release "$lock" || true
  [ "$state" = leased ]
}

# Close one task's pane under the task lock and the shared session presentation
# lock, recomputing the whole verdict inside both. Prints closed|refused.
fm_pane_retire_close() {  # <id>
  local id=$1 task_lock="$STATE/.spawn-$1.lock" session pane state proof presentation_lock close_status=0
  if ! fm_lock_try_acquire "$task_lock"; then
    echo "refused $id task lock is busy"
    return 1
  fi
  fm_pane_retire_evaluate "$id"
  if [ "$FM_PANE_RETIRE_VERDICT" != retire ]; then
    fm_lock_release "$task_lock" || true
    echo "refused $id verdict changed under the lock: $FM_PANE_RETIRE_VERDICT $FM_PANE_RETIRE_DETAIL"
    return 1
  fi
  session=$FM_PANE_RETIRE_SESSION
  pane=$FM_PANE_RETIRE_PANE
  state=$FM_PANE_RETIRE_AGENT_STATE
  proof=$FM_PANE_RETIRE_PROOF
  presentation_lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_lock_release "$task_lock" || true
    echo "refused $id session presentation lock is unavailable"
    return 1
  }
  if ! fm_lock_try_acquire "$presentation_lock"; then
    fm_lock_release "$task_lock" || true
    echo "refused $id session presentation lock is busy"
    return 1
  fi
  # The lock order is the one every other pane close uses: task, then session.
  # Recompute once more now that both are held; the helper re-reads the agent
  # state itself through its required-state argument.
  fm_pane_retire_evaluate "$id"
  if [ "$FM_PANE_RETIRE_VERDICT" != retire ] \
     || [ "$FM_PANE_RETIRE_AGENT_STATE" != "$state" ] \
     || [ "$FM_PANE_RETIRE_PROOF" != "$proof" ]; then
    echo "refused $id verdict changed under the locks: $FM_PANE_RETIRE_VERDICT $FM_PANE_RETIRE_DETAIL"
    close_status=1
  elif ! fm_pane_retire_hold_slot "$id" \
         "$(fm_backend_meta_exact_value "$STATE/$id.meta" project)" \
         "$(fm_backend_meta_exact_value "$STATE/$id.meta" worktree)"; then
    echo "refused $id the worktree slot could not be durably leased, so the pane stays open"
    close_status=1
  else
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane" "$state" \
      >/dev/null 2>&1 || close_status=$?
    if [ "$(fm_backend_herdr_pane_presence_state "$session" "$pane")" = dead ]; then
      echo "closed $id $session:$pane ($proof)"
      close_status=0
    else
      echo "refused $id the exact focus-safe close was refused or unconfirmed (status $close_status)"
      close_status=1
    fi
  fi
  fm_lock_release "$presentation_lock" || true
  fm_lock_release "$task_lock" || true
  return "$close_status"
}

fm_pane_retire_main() {
  local apply=0 auto=0 id meta ids=() arg retire_count=0 keep_count=0 gone_count=0 closed=0 refused=0
  local retire_ids=()
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      --auto) auto=1; apply=1 ;;
      -h|--help)
        sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
        return 0
        ;;
      -*) echo "error: unknown option $arg" >&2; return 2 ;;
      *)
        fm_task_id_creation_valid "$arg" || { echo "error: invalid task id: $arg" >&2; return 2; }
        ids+=("$arg")
        ;;
    esac
  done
  if [ "$auto" = 1 ] && ! fm_pane_retire_enabled; then
    return 0
  fi
  if [ "${#ids[@]}" -eq 0 ]; then
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || continue
      id=$(basename "$meta" .meta)
      fm_task_id_creation_valid "$id" || continue
      ids+=("$id")
    done
  fi
  [ "$auto" = 1 ] || {
    if [ "$apply" = 1 ]; then echo "fm-pane-retire: listing, then closing eligible panes"; else echo "fm-pane-retire: dry run, nothing is closed (pass --apply to close)"; fi
  }
  for id in ${ids[@]+"${ids[@]}"}; do
    fm_pane_retire_evaluate "$id"
    case "$FM_PANE_RETIRE_VERDICT" in
      retire) retire_count=$((retire_count + 1)); retire_ids+=("$id") ;;
      gone) gone_count=$((gone_count + 1)) ;;
      *) keep_count=$((keep_count + 1)) ;;
    esac
    [ "$auto" = 1 ] || printf '%-6s %s  %s\n' "$FM_PANE_RETIRE_VERDICT" "$id" "$FM_PANE_RETIRE_DETAIL"
  done
  if [ "$apply" = 1 ]; then
    for id in ${retire_ids[@]+"${retire_ids[@]}"}; do
      if fm_pane_retire_close "$id"; then closed=$((closed + 1)); else refused=$((refused + 1)); fi
    done
  fi
  [ "$auto" = 1 ] && [ "$retire_count" -eq 0 ] && return 0
  if [ "$apply" = 1 ]; then
    echo "summary: $closed closed, $refused refused, $keep_count kept, $gone_count already closed"
  else
    echo "summary: $retire_count eligible, $keep_count kept, $gone_count already closed"
  fi
  return 0
}

if [ "${FM_PANE_RETIRE_SOURCE_ONLY:-0}" != 1 ]; then
  fm_pane_retire_main "$@"
  exit $?
fi
