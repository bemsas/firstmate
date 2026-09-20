#!/usr/bin/env bash
# LIVE validation of bin/fm-control.sh `stop` - the non-typing shutdown - in an
# ISOLATED Herdr lab session, against REAL harness processes. The live default
# Herdr session and the real fleet are never touched: every Herdr call goes
# through bin/fm-herdr-lab.sh against an fm-lab-* session, FM_HOME is a throwaway
# temp home, and the lab is torn down in this same run.
set -u
ROOT=/home/bemsas/.no-mistakes/worktrees/e6b827affbab/01M2ZX9BM5DZPSQ2TBHKR32RB7
LAB="$ROOT/bin/fm-herdr-lab.sh"

SESSION=$("$LAB" name fmstoplive) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stop-live.XXXXXX")
CLEANED=0
cleanup() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  echo; echo "=== teardown ==="
  if "$LAB" teardown "$SESSION" >/dev/null 2>&1; then
    echo "  lab session torn down, live default session verified unchanged"
  else
    echo "  WARN: lab teardown reported a problem"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export HERDR_SESSION="$SESSION"

echo "date        : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "code under test: $(git -C "$ROOT" rev-parse --short HEAD)"
echo "lab session : $SESSION"
"$LAB" provision "$SESSION" || { echo "FATAL: could not provision lab"; exit 1; }
lab() { "$LAB" run "$SESSION" "$@"; }

PROJ="$TMP/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email live@example.com
git -C "$PROJ" config user.name Live
printf 'tracked\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -qm init
git -C "$PROJ" worktree add -q -b stop-live "$TMP/wt"
WT=$(cd -P "$TMP/wt" && pwd -P)
printf 'work the agent never committed\n' > "$WT/uncommitted-draft.md"
printf 'edited, not staged\n' >> "$WT/README.md"
echo "worktree    : $WT"

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
write_meta() {  # <id> <pane> <ws> <tab> <harness> <worktree>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# brief\n' > "$HOME_DIR/data/$1/brief.md"
  {
    echo "window=$SESSION:$2"; echo "backend=herdr"; echo "endpoint_task_id=$1"
    echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$3"
    echo "herdr_tab_id=$4"; echo "herdr_pane_id=$2"
    echo "worktree=$6"; echo "project=$PROJ"; echo "harness=$5"
    echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
    echo "model=default"; echo "effort=default"
  } > "$HOME_DIR/state/$1.meta"
}
# FM_GATE_REFUSE_BYPASS is the documented test-harness escape hatch
# (bin/fm-gate-refuse-lib.sh); this drives a throwaway FM_HOME and a lab session.
control() { env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_GATE_REFUSE_BYPASS=1 \
  bash "$ROOT/bin/fm-control.sh" "$@" 2>&1; }
probe() { env HERDR_SESSION="$SESSION" bash -c 'set -u; . "$1/bin/backends/herdr.sh"; shift; "$@"' _ "$ROOT" "$@"; }
gate() { probe fm_backend_herdr_composer_no_content_observed "$SESSION:$1" && echo yes || echo no; }
pane_alive() { lab pane get "$1" >/dev/null 2>&1; }
status_of() { git -C "$WT" status --porcelain --untracked-files=all | tr '\n' '|'; }
busy_verdict() {  # <id>
  env FM_HOME="$HOME_DIR" bash -c '
    set -u
    . "$1/bin/fm-backend.sh" >/dev/null 2>&1
    . "$1/bin/fm-busy-lib.sh" >/dev/null 2>&1
    fm_busy_classify_meta "$2/state/$3.meta" "$3" "$2/state"' _ "$ROOT" "$HOME_DIR" "$1" 2>&1
}
wait_alive() { local i=0; while [ "$i" -lt 120 ]; do
  [ "$(probe fm_backend_herdr_agent_state "$SESSION:$1")" = alive ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }

CREATE=$(lab workspace create --cwd "$PROJ" --label 'fm-stop-live' --no-focus) || exit 1
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id')
PANE_A=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
TAB_A=$(lab pane get "$PANE_A" | jq -er '.result.pane.tab_id')
mk_pane() { local out pane tab
  out=$(lab tab create --workspace "$WS" --cwd "$PROJ" --label "$1" --no-focus) || return 1
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')
  tab=$(lab pane get "$pane" | jq -er '.result.pane.tab_id')
  printf '%s %s' "$pane" "$tab"; }
read -r PANE_B TAB_B <<<"$(mk_pane draft)"
read -r PANE_C TAB_C <<<"$(mk_pane idle-shell)"

# ===========================================================================
echo
echo "############################################################"
echo "# S1/S2/S3: A WORKER WEDGED AT AUTHENTICATION"
echo "# grok launched against a fresh, unauthenticated home parks on"
echo "# its sign-in screen: alive, holding no composer, and unable to"
echo "# read anything that is typed at it. This is the incident."
echo "############################################################"
write_meta lt1 "$PANE_A" "$WS" "$TAB_A" grok "$WT"
mkdir -p "$TMP/grokhome"
lab pane run "$PANE_A" "cd $WT && HOME=$TMP/grokhome grok" >/dev/null || echo "WARN: launch failed"
wait_alive "$PANE_A" || echo "WARN: grok never classified alive"
sleep 8
echo
echo "--- what the firstmate sees in the worker's pane ---"
probe fm_backend_herdr_capture "$SESSION:$PANE_A" 32 | sed 's/^/  | /'
echo
echo "  agent state         : $(probe fm_backend_herdr_agent_state "$SESSION:$PANE_A")"
echo "  composer state      : $(probe fm_backend_herdr_composer_state "$SESSION:$PANE_A")"
echo "  no-content-observed : $(gate "$PANE_A")"
AGENT_PID=$(probe fm_backend_herdr_agent_process "$SESSION:$PANE_A") || AGENT_PID=
echo "  resolved agent pid  : ${AGENT_PID:-<none>} ($(ps -p "${AGENT_PID:-0}" -o comm= 2>/dev/null | tr -d ' ' || echo n/a))"

echo
echo "--- S1: 'exit' cannot serve this worker, and says where to go ---"
OUT=$(control lt1 exit); RC=$?
echo "  \$ fm-control.sh lt1 exit   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
case "$OUT" in *"use 'stop'"*) echo "  PASS the refusal names the non-typing verb" ;;
  *) echo "  FAIL the refusal does not point at stop" ;; esac
if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null; then echo "  PASS exit typed nothing and left the agent running"; else echo "  FAIL the agent is gone after a refusal"; fi

echo
echo "--- S2 (adversarial): the SAME live agent, recorded against a different worktree ---"
write_meta lt2 "$PANE_A" "$WS" "$TAB_A" grok "$PROJ"
OUT=$(control lt2 stop); RC=$?
echo "  \$ fm-control.sh lt2 stop   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null; then echo "  PASS the identity proof refused and the agent is untouched"; else echo "  FAIL a process outside the recorded worktree was signalled"; fi

echo
echo "--- S3: 'stop' shuts the wedged worker down without typing ---"
BEFORE=$(status_of)
echo "  worktree before : $BEFORE"
OUT=$(control lt1 stop); RC=$?
echo "  \$ fm-control.sh lt1 stop   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
sleep 1
[ -n "$AGENT_PID" ] && { kill -0 "$AGENT_PID" 2>/dev/null && echo "  FAIL agent pid $AGENT_PID still alive" || echo "  PASS agent process gone"; }
pane_alive "$PANE_A" && echo "  PASS herdr pane preserved" || echo "  FAIL herdr pane destroyed"
AFTER=$(status_of)
echo "  worktree after  : $AFTER"
if [ "$BEFORE" = "$AFTER" ] && [ -f "$WT/uncommitted-draft.md" ]; then echo "  PASS uncommitted work survived"; else echo "  FAIL uncommitted work changed"; fi
echo "--- the worker's pane after the stop ---"
probe fm_backend_herdr_capture "$SESSION:$PANE_A" 12 | sed 's/^/  | /'

# ===========================================================================
echo
echo "############################################################"
echo "# S4 (adversarial): A REAL UNSENT DRAFT IS NEVER SIGNALLED AWAY"
echo "############################################################"
write_meta lt4 "$PANE_B" "$WS" "$TAB_B" opencode "$WT"
lab pane run "$PANE_B" "cd $WT && opencode" >/dev/null || echo "WARN: opencode launch failed"
wait_alive "$PANE_B" || echo "WARN: opencode never classified alive"
sleep 4
echo "  composer state (idle)  : $(probe fm_backend_herdr_composer_state "$SESSION:$PANE_B")  no-content-observed: $(gate "$PANE_B")"
lab pane send-text "$PANE_B" 'a draft the human has not sent yet' >/dev/null
sleep 2
echo "--- the worker's pane, holding an unsent draft ---"
probe fm_backend_herdr_capture "$SESSION:$PANE_B" 14 | sed 's/^/  | /'
echo "  composer state (draft) : $(probe fm_backend_herdr_composer_state "$SESSION:$PANE_B")  no-content-observed: $(gate "$PANE_B")"
DRAFT_PID=$(probe fm_backend_herdr_agent_process "$SESSION:$PANE_B") || DRAFT_PID=
echo "  resolved agent pid     : ${DRAFT_PID:-<none>}"
OUT=$(control lt4 stop); RC=$?
echo "  \$ fm-control.sh lt4 stop   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
[ -n "$DRAFT_PID" ] && { kill -0 "$DRAFT_PID" 2>/dev/null && echo "  PASS agent left running" || echo "  FAIL the drafted agent was signalled"; }
probe fm_backend_herdr_capture "$SESSION:$PANE_B" 24 | grep -q 'a draft the human has not sent yet' \
  && echo "  PASS the draft is still on screen" || echo "  FAIL the draft did not survive"

# ===========================================================================
echo
echo "############################################################"
echo "# S5: AN AGENT THAT EXITED ON ITS OWN STOPS PINGING BUSY"
echo "# The likeliest path into the reported state: the wedged worker"
echo "# exhausts its retries and exits before a supervisor reaches it."
echo "############################################################"
write_meta lt5 "$PANE_C" "$WS" "$TAB_C" opencode "$WT"
echo "  agent state         : $(probe fm_backend_herdr_agent_state "$SESSION:$PANE_C")"
env FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" lt5 >/dev/null 2>&1 || echo "WARN: arm failed"
echo "  busy wiring armed   : $(ls "$HOME_DIR/state" | grep -E '^lt5\.busy' | tr '\n' ' ')"
echo "  busy verdict BEFORE : $(busy_verdict lt5)"
OUT=$(control lt5 stop); RC=$?
echo "  \$ fm-control.sh lt5 stop   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
LEFT=$(ls "$HOME_DIR/state" | grep -E '^lt5\.busy' | tr '\n' ' ')
[ -z "$LEFT" ] && echo "  PASS busy wiring retired" || echo "  FAIL busy wiring still armed: $LEFT"
echo "  busy verdict AFTER  : $(busy_verdict lt5)"
pane_alive "$PANE_C" && echo "  PASS the pane's shell was never signalled" || echo "  FAIL the shell pane died"
