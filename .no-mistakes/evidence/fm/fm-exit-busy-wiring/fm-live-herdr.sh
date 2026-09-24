#!/usr/bin/env bash
# Live: real Herdr in a guarded fm-lab-* session; real fm-control.sh exit on an
# agent-free pane with an armed busy incarnation, through all three early returns.
set -u
ROOT=$1
. "$ROOT/tests/herdr-test-safety.sh"          # exports FM_GATE_REFUSE_BYPASS=1 for this sandbox fleet
unset NO_MISTAKES_GATE
herdr_forget_inherited_pane
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name exitbusy)
export HERDR_SESSION="$SESSION"
S=$(mktemp -d /tmp/fm-live-herdr.XXXX)
cleanup() { rm -rf "$S"; "$LAB" teardown "$SESSION" >/dev/null 2>&1 && echo "== teardown $SESSION: ok" || echo "== teardown $SESSION: FAILED"; }
trap cleanup EXIT
"$LAB" prepare "$SESSION" >/dev/null || { echo "lab provision failed"; exit 1; }
echo "== lab session: $SESSION ($(herdr --version | head -1))"
H="$S/home"; mkdir -p "$H/state"
git init -q "$S/proj"; git -C "$S/proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m i
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
mk() {  # <id> -> creates a real task pane and its meta
  local id=$1 wt="$S/wt-$1" c raw ws tab pane
  git -C "$S/proj" worktree add -q -b "task-$id" "$wt"
  mkdir -p "$H/data/$id"; printf '# Task\n## Captain'"'"'s intent\nx\n\n## Firstmate spec\ny\n' > "$H/data/$id/brief.md"
  raw=$(fm_backend_herdr_container_ensure "$wt"); c=${raw%%$'\t'*}; ws=${c#*:}
  read -r tab pane <<<"$(fm_backend_herdr_create_task "$c" "fm-$id" "$wt" "${raw#*$'\t'}")"
  printf '%s\n' "window=$SESSION:$pane" "endpoint_task_id=$id" "worktree=$wt" "project=$S/proj" \
    harness=claude kind=ship mode=no-mistakes yolo=off model=default effort=default backend=herdr \
    "herdr_session=$SESSION" "herdr_workspace_id=$ws" "herdr_tab_id=$tab" "herdr_pane_id=$pane" > "$H/state/$id.meta"
  echo "$pane"
}
ctl() { env FM_HOME="$H" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 "$ROOT/bin/fm-control.sh" "$@" 2>&1; echo " rc=$?"; }
cls() { ( . "$ROOT/bin/fm-busy-lib.sh"; fm_busy_classify herdr "$(sed -n 's/^window=//p' "$H/state/$1.meta")" claude "$1" "$H/state" ); }
arm() { bash "$ROOT/bin/fm-busy-event.sh" arm "$H/state" "$1" >/dev/null; echo "armed: $(cd "$H/state"; ls "$1".busy-* | tr '\n' ' ') classify=[$(cls "$1")]"; }
after() { echo "after: busy files=[$(cd "$H/state"; ls "$1".busy-* 2>/dev/null | tr '\n' ' ')] classify=[$(cls "$1")]"; }

echo; echo "### H1 dead: agent-free herdr pane (agent exited on its own)"
P1=$(mk h1); echo "pane=$P1 state=$(fm_backend_agent_state herdr "$SESSION:$P1")"; arm h1
echo -n "exit: "; ctl h1 exit; after h1

echo; echo "### H2 missing->gone: the recorded pane was destroyed"
P2=$(mk h2); "$LAB" run "$SESSION" pane close "$P2" >/dev/null 2>&1; sleep 0.5
echo "pane=$P2 state=$(fm_backend_agent_state herdr "$SESSION:$P2")"; arm h2
echo -n "exit: "; ctl h2 exit; after h2

echo; echo "### H3 missing->dead: lab session server stopped, pane outlives it"
P3=$(mk h3); arm h3
"$LAB" stop "$SESSION" >/dev/null 2>&1; echo "server stopped; state=$(fm_backend_agent_state herdr "$SESSION:$P3")"
echo -n "exit: "; ctl h3 exit; after h3
echo "pane still present after exit: $(herdr pane get "$P3" --session "$SESSION" >/dev/null 2>&1 && echo yes || echo no)"
