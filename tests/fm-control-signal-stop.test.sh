#!/usr/bin/env bash
# tests/fm-control-signal-stop.test.sh - portable regression for the control
# plane's non-typing stop (bin/fm-control.sh exit when the composer is not
# proven empty).
#
# A real tmux server on a private socket hosts a harness-named sleep under a
# pane shell, so the composer is unreadable and the agent pid is still
# identified. exit must signal that pid, leave the pane and local copy in
# place, and never type the harness exit command. Needs no credentials.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

CONTROL="$ROOT/bin/fm-control.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-signal-stop-$$"
SESSION=sigstop
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-signal-stop.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/home/state" "$LAB/home/data/t1"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
ln -s "$SLEEP_BIN" "$LAB/bin/claude"
PATH="$LAB/shim:$PATH"
export PATH

fm_git_worktree "$LAB/proj" "$LAB/wt" task-t1
printf '# brief\n' > "$LAB/home/data/t1/brief.md"
{
  echo "window=$SESSION:fm-t1"
  echo "endpoint_task_id=t1"
  echo "worktree=$LAB/wt"
  echo "project=$LAB/proj"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
} > "$LAB/home/state/t1.meta"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n shell -c "$LAB/wt" -- bash
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n fm-t1 -c "$LAB/wt" -- bash
# Launch the harness-named sleep as a foreground child of the pane shell so
# signaling it leaves the endpoint behind.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:fm-t1" "$LAB/bin/claude 900" Enter

waited=0
state=
while [ "$waited" -lt 50 ]; do
  state=$(PATH="$LAB/shim:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$SESSION:fm-t1")
  [ "$state" = alive ] && break
  sleep 0.1
  waited=$((waited + 1))
done
[ "$state" = alive ] || fail "the harness-named sleep never classified alive (last state: ${state:-none})"

composer=$(PATH="$LAB/shim:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux "$2"' _ "$ROOT" "$SESSION:fm-t1")
[ "$composer" = no-composer ] \
  || fail "the non-typing stop is reachable only from a pane proven to hold no composer; this construction read '$composer'"

# tmux answers an absent target from the session's CURRENT window instead of
# failing, so a pid read that skips window membership would hand the stop
# another task's harness. Make the agent window current, then ask for a window
# that does not exist: the read must fail rather than answer.
"$REAL_TMUX" -L "$SOCKET" select-window -t "$SESSION:fm-t1"
if absent=$(PATH="$LAB/shim:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_pids tmux "$2"' _ "$ROOT" "$SESSION:fm-t1-gone"); then
  fail "an absent window must not report pids, but it answered with '$absent'"
fi

pids=$(PATH="$LAB/shim:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_pids tmux "$2"' _ "$ROOT" "$SESSION:fm-t1")
[ -n "$pids" ] || fail "the harness-named sleep must be identifiable as an agent pid"
pid=$(printf '%s\n' "$pids" | head -n 1)
case "$pid" in
  ''|*[!0-9]*|0) fail "agent pid list was not a process id: '$pids'" ;;
esac

out=$(env PATH="$LAB/shim:$PATH" FM_HOME="$LAB/home" \
  FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=5 \
  "$CONTROL" t1 exit 2>&1) || fail "exit should stop an identified agent whose composer is unreadable: $out"
case "$out" in
  "stopped t1"*) : ;;
  *) fail "expected 'stopped t1', got: $out" ;;
esac

if kill -0 "$pid" 2>/dev/null; then
  fail "the identified agent pid $pid is still running after the non-typing stop"
fi
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SESSION" -F '#{window_name}' | grep -qxF fm-t1 \
  || fail "the non-typing stop must not remove the pane"
[ -d "$LAB/wt" ] || fail "the non-typing stop must not remove the local copy"
pass "fm-control exit: an identified agent behind an unreadable composer is signaled, not typed into"
