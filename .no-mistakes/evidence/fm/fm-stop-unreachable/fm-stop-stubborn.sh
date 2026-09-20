#!/usr/bin/env bash
# LIVE: a stubborn agent that ignores SIGTERM must be reported as an
# UNCONFIRMED stop and must never be escalated to SIGKILL, because SIGKILL
# would deny the harness its chance to flush uncommitted work. Real processes
# on a real private tmux server, driving the real bin/fm-control.sh.
set -u
ROOT=/home/bemsas/.no-mistakes/worktrees/e6b827affbab/01M2ZX9BM5DZPSQ2TBHKR32RB7
REAL_TMUX=$(command -v tmux)
PERL=$(command -v perl) || { echo "skip: no perl"; exit 0; }
SOCKET="fm-stubborn-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stubborn.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/shim" "$WORK/home/state" "$WORK/home/data/t1" "$WORK/bin"
cat > "$WORK/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$WORK/shim/tmux"
# A REAL binary whose process name is a verified harness, which ignores SIGTERM.
cp "$PERL" "$WORK/bin/opencode"

git init -q -b main "$WORK/proj"
git -C "$WORK/proj" config user.email a@b.c; git -C "$WORK/proj" config user.name A
printf 'tracked\n' > "$WORK/proj/README.md"
git -C "$WORK/proj" add .; git -C "$WORK/proj" commit -qm init
git -C "$WORK/proj" worktree add -q -b stubborn "$WORK/wt"
printf 'uncommitted work\n' > "$WORK/wt/dirty.txt"
{
  echo "window=fmses:fm-t1"; echo "endpoint_task_id=t1"; echo "worktree=$WORK/wt"
  echo "project=$WORK/proj"; echo "harness=opencode"; echo "kind=ship"
  echo "mode=no-mistakes"; echo "yolo=off"; echo "model=default"; echo "effort=default"
} > "$WORK/home/state/t1.meta"
printf '# brief\n' > "$WORK/home/data/t1/brief.md"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s fmses -n scratch -c "$WORK" >/dev/null
"$REAL_TMUX" -L "$SOCKET" new-window -d -t fmses: -n fm-t1 -c "$WORK/wt" >/dev/null
SHELL_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t fmses:fm-t1 '#{pane_pid}')
"$REAL_TMUX" -L "$SOCKET" send-keys -t fmses:fm-t1 \
  "PATH=$WORK/bin:\$PATH opencode -e '\$SIG{TERM}=\"IGNORE\"; sleep 600 while 1'" Enter
sleep 3
PID=$(pgrep -P "$SHELL_PID" -x opencode | head -1)
echo "date            : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "code under test : $(git -C "$ROOT" rev-parse --short HEAD)"
echo "stubborn agent  : pid=$PID comm=$(ps -p "$PID" -o comm= | tr -d ' ') (ignores SIGTERM)"
echo "worktree before : $(git -C "$WORK/wt" status --porcelain --untracked-files=all | tr '\n' '|')"
echo
OUT=$(env PATH="$WORK/shim:$PATH" FM_HOME="$WORK/home" FM_GATE_REFUSE_BYPASS=1 \
  FM_CONTROL_EXIT_WAIT=4 bash "$ROOT/bin/fm-control.sh" t1 stop 2>&1); RC=$?
echo "\$ fm-control.sh t1 stop   -> rc=$RC"
printf '%s\n' "$OUT" | sed 's/^/  | /'
echo
sleep 1
if kill -0 "$PID" 2>/dev/null; then
  echo "  PASS the agent is still running - no SIGKILL was sent after the unacknowledged TERM"
else
  echo "  FAIL the agent was killed; SIGTERM-only was not honoured"
fi
case "$OUT" in *"stop=unconfirmed"*) echo "  PASS the result says the stop is unconfirmed, not that the agent stopped" ;;
  *) echo "  FAIL the result does not report an unconfirmed stop" ;; esac
case "$OUT" in *stopped\ pid=*) echo "  FAIL it claimed a stop that did not happen" ;; *) echo "  PASS no stop was claimed" ;; esac
echo "worktree after  : $(git -C "$WORK/wt" status --porcelain --untracked-files=all | tr '\n' '|')"
kill -9 "$PID" 2>/dev/null || true
