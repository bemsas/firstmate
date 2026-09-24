#!/usr/bin/env bash
# Live driver: real tmux server (private TMUX_TMPDIR), real dead pane, real
# fm-busy-event arm, real bin/fm-control.sh exit, real fm_busy_classify_meta.
# Usage: live-tmux-exit-busy.sh <repo-root> <label>
set -u
ROOT=$1; LABEL=$2
# Sandbox-only fleet (private tmux server + temp FM_HOME): use the same
# documented test-harness bypass tests/lib.sh exports.
export FM_GATE_REFUSE_BYPASS=1
T=$(mktemp -d); export TMUX_TMPDIR=$T/tmux; mkdir -p $TMUX_TMPDIR; unset TMUX
export FM_HOME=$T/home; mkdir -p $FM_HOME/state $FM_HOME/data/t1 $FM_HOME/data/t2
cleanup(){ tmux kill-server 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
for id in t1 t2; do
  git init -q $T/proj-$id && git -C $T/proj-$id commit -q --allow-empty -m init
  git -C $T/proj-$id worktree add -q -b task-$id $T/wt-$id
  echo "# brief" > $FM_HOME/data/$id/brief.md
  printf 'window=fmlive:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\n' \
    $id $id $T/wt-$id $T/proj-$id > $FM_HOME/state/$id.meta
done
tmux new-session -d -s fmlive -n fm-t1 -c $T/wt-t1 bash --norc
tmux new-window -d -t fmlive: -n fm-t2 -c $T/wt-t2 bash --norc
sleep 0.5
echo "== [$LABEL] tmux panes (agent already gone; only a shell remains)"
tmux list-windows -t fmlive -F '#{window_name} cmd=#{pane_current_command} path=#{pane_current_path}'
classify(){ bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2/state/$3.meta" "$3" "$2/state"' _ "$ROOT" "$FM_HOME" "$1"; }
echo "== [$LABEL] Scenario A: t1 armed busy, worker exited on its own"
"$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" t1 >/dev/null
echo "state files before: $(cd $FM_HOME/state && ls t1.busy* 2>/dev/null | tr '\n' ' ')"
echo "classify before exit: $(classify t1)"
out=$("$ROOT/bin/fm-control.sh" t1 exit 2>&1); echo "fm-control t1 exit -> rc=$? out: $out"
echo "state files after: $(cd $FM_HOME/state && ls t1.busy* 2>/dev/null | tr '\n' ' ')"
echo "classify after exit: $(classify t1)"
echo "pane still present: $(tmux list-windows -t fmlive -F '#{window_name}' | grep -x fm-t1)"
echo "== [$LABEL] Scenario B: t2 never armed (no-op guard)"
echo "state files before: $(cd $FM_HOME/state && ls t2.* | tr '\n' ' ')"
out=$("$ROOT/bin/fm-control.sh" t2 exit 2>&1); echo "fm-control t2 exit -> rc=$? out: $out"
echo "state files after: $(cd $FM_HOME/state && ls t2.* | tr '\n' ' ')"
echo "== [$LABEL] Scenario C: rerun exit on t1 (idempotent, already retired)"
out=$("$ROOT/bin/fm-control.sh" t1 exit 2>&1); echo "fm-control t1 exit -> rc=$? out: $out"
echo "state files after: $(cd $FM_HOME/state && ls t1.* | tr '\n' ' ')"
