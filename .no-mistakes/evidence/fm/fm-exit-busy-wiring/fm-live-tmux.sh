#!/usr/bin/env bash
# Live: real tmux server (private TMUX_TMPDIR), real fm-control.sh exit on a
# task whose agent already exited (pane holds only its shell), with an armed
# busy incarnation.
set -u
ROOT=$1; export FM_GATE_REFUSE_BYPASS=1; unset NO_MISTAKES_GATE
L=$(mktemp -d /tmp/fm-live-exit.XXXX)
export TMUX_TMPDIR="$L/tmux"; mkdir -p "$TMUX_TMPDIR"
export FM_HOME="$L/home"; mkdir -p "$FM_HOME/state" "$FM_HOME/data/t1"
git init -q "$L/proj" && git -C "$L/proj" commit -q --allow-empty -m init
git -C "$L/proj" worktree add -q -b task-t1 "$L/wt" 2>/dev/null
echo '# brief' > "$FM_HOME/data/t1/brief.md"
cat > "$FM_HOME/state/t1.meta" <<M
window=fmlive:fm-t1
endpoint_task_id=t1
worktree=$L/wt
project=$L/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
M
tmux new-session -d -s fmlive -n fm-t1 -c "$L/wt" bash --norc --noprofile
sleep 0.5
echo "== tmux pane (agent already exited; only its shell remains):"
tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} cwd=#{pane_current_path}'
echo "== arm busy incarnation (worker wedged at auth was armed busy):"
bash "$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" t1; echo "arm rc=$?"
ls "$FM_HOME/state" | grep busy
echo "== fm_busy_classify BEFORE exit:"
( source "$ROOT/bin/fm-busy-lib.sh"; fm_busy_classify tmux fmlive:fm-t1 claude t1 "$FM_HOME/state"; echo )
echo "== fm-control.sh t1 exit:"
"$ROOT/bin/fm-control.sh" t1 exit; echo " rc=$?"
echo "== busy files AFTER exit:"
ls "$FM_HOME/state" | grep busy || echo "(none)"
echo "== fm_busy_classify AFTER exit:"
( source "$ROOT/bin/fm-busy-lib.sh"; fm_busy_classify tmux fmlive:fm-t1 claude t1 "$FM_HOME/state"; echo )
echo "== idempotent second exit with no armed incarnation:"
"$ROOT/bin/fm-control.sh" t1 exit; echo " rc=$?"
ls "$FM_HOME/state" | grep busy || echo "(none)"
echo "== endpoint preserved:"
tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command}'
tmux kill-server; rm -rf "$L"
