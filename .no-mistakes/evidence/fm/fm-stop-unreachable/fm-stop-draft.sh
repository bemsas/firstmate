#!/usr/bin/env bash
# LIVE: the content gate against a REAL opencode composer holding a REAL
# unsent draft, with the rendered pane captured either side of the refusal.
set -u
ROOT=/home/bemsas/.no-mistakes/worktrees/e6b827affbab/01M2ZX9BM5DZPSQ2TBHKR32RB7
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name fmstopdraft) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stop-draft.XXXXXX")
cleanup() { echo; echo "=== teardown ==="; "$LAB" teardown "$SESSION" >/dev/null 2>&1 \
  && echo "  lab torn down, live default session verified unchanged" || echo "  WARN teardown problem"; rm -rf "$TMP"; }
trap cleanup EXIT
export HERDR_SESSION="$SESSION"
echo "date            : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "code under test : $(git -C "$ROOT" rev-parse --short HEAD)"
echo "lab session     : $SESSION"
"$LAB" provision "$SESSION" || exit 1
lab() { "$LAB" run "$SESSION" "$@"; }
probe() { env HERDR_SESSION="$SESSION" bash -c 'set -u; . "$1/bin/backends/herdr.sh"; shift; "$@"' _ "$ROOT" "$@"; }
PROJ="$TMP/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main; git -C "$PROJ" config user.email a@b.c; git -C "$PROJ" config user.name A
printf 'tracked\n' > "$PROJ/README.md"; git -C "$PROJ" add .; git -C "$PROJ" commit -qm init
git -C "$PROJ" worktree add -q -b draft-live "$TMP/wt"
WT=$(cd -P "$TMP/wt" && pwd -P)
printf 'work the agent never committed\n' > "$WT/uncommitted-draft.md"
HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/dt1"
printf '# brief\n' > "$HOME_DIR/data/dt1/brief.md"
C=$(lab workspace create --cwd "$PROJ" --label fm-stop-draft --no-focus)
WS=$(printf '%s' "$C" | jq -er '.result.workspace.workspace_id')
PANE=$(printf '%s' "$C" | jq -er '.result.root_pane.pane_id')
TAB=$(lab pane get "$PANE" | jq -er '.result.pane.tab_id')
{ echo "window=$SESSION:$PANE"; echo "backend=herdr"; echo "endpoint_task_id=dt1"
  echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=$TAB"
  echo "herdr_pane_id=$PANE"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=opencode"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
  echo "model=default"; echo "effort=default"; } > "$HOME_DIR/state/dt1.meta"
lab pane run "$PANE" "cd $WT && opencode" >/dev/null
i=0; while [ "$i" -lt 120 ]; do [ "$(probe fm_backend_herdr_agent_state "$SESSION:$PANE")" = alive ] && break; sleep 0.5; i=$((i+1)); done
sleep 5
lab pane send-text "$PANE" 'a draft the human has not sent yet' >/dev/null
sleep 3
echo
echo "--- the worker's pane, with a real unsent draft in its composer ---"
probe fm_backend_herdr_capture "$SESSION:$PANE" 40 | grep -n . | sed 's/^/  | /'
echo
echo "  composer state      : $(probe fm_backend_herdr_composer_state "$SESSION:$PANE")"
probe fm_backend_herdr_composer_no_content_observed "$SESSION:$PANE" \
  && echo "  no-content-observed : yes" || echo "  no-content-observed : no"
PID=$(probe fm_backend_herdr_agent_process "$SESSION:$PANE"); echo "  resolved agent pid  : $PID"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_GATE_REFUSE_BYPASS=1 \
  bash "$ROOT/bin/fm-control.sh" dt1 stop 2>&1); RC=$?
echo
echo "\$ fm-control.sh dt1 stop   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
echo
kill -0 "$PID" 2>/dev/null && echo "  PASS the agent was never signalled" || echo "  FAIL the drafted agent was signalled"
echo "--- the same pane after the refusal ---"
probe fm_backend_herdr_capture "$SESSION:$PANE" 40 | grep -n . | sed 's/^/  | /'
