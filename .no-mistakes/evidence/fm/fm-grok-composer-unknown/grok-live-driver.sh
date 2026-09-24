#!/usr/bin/env bash
# Live driver: real grok 1.0.41 in an isolated fm-lab-* Herdr session.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
BASE_LIB=${BASE_LIB:?}   # pre-fix bin/fm-composer-lib.sh copy
HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIG_PATH=$PATH
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-live.XXXXXX")
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
SESSION=$("$HELPER" name grok-composer)
export HELPER SESSION ORIG_PATH
log() { printf '%s\n' "$*" | tee -a "$EV/live-transcript.txt"; }
cleanup() {
  env PATH="$ORIG_PATH" "$HELPER" teardown "$SESSION" && log "teardown: $SESSION removed" || log "teardown FAILED for $SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
: > "$EV/live-transcript.txt"
log "== $(date -Is) grok $(grok --version) / herdr $(herdr --version | head -1) / lab session $SESSION"
"$HELPER" provision "$SESSION" || { log "provision failed"; exit 1; }

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
exec env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"; }

PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b glive "$WT"
printf 'uncommitted work\n' > "$WT/scratch.txt"

CREATE=$(lab workspace create --cwd "$WT" --label grok-composer --no-focus) || { log "workspace create failed"; exit 1; }
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id')
TAB=$(printf '%s' "$CREATE" | jq -er '.result.tab.tab_id // .result.root_pane.tab_id // empty')
TARGET="$SESSION:$PANE"
log "pane $TARGET (workspace $WS tab ${TAB:-?})"

classify() {  # <lib> -> verdict
  PATH="$FAKEBIN:$ORIG_PATH" bash -c '
    set -u; . "$1/bin/backends/herdr.sh"; [ -n "$3" ] && . "$3"
    fm_backend_herdr_composer_state "$2"' _ "$ROOT" "$TARGET" "${1:-}"
}
snap() {  # <name>
  lab pane read "$PANE" --source recent --lines 40 --format ansi > "$EV/$1.ansi" 2>/dev/null \
    || lab pane read "$PANE" > "$EV/$1.ansi" 2>/dev/null
  lab pane read "$PANE" --source recent --lines 40 > "$EV/$1.txt" 2>/dev/null || cp "$EV/$1.ansi" "$EV/$1.txt"
}
agent_status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // .error.code // empty'; }

lab pane run "$PANE" "grok --always-approve --no-alt-screen --reasoning-effort low" >/dev/null
for i in $(seq 1 90); do
  lab pane read "$PANE" 2>/dev/null | grep -q 'Grok .*(low)' && break
  # auto-accept a folder-trust prompt if shown
  lab pane read "$PANE" 2>/dev/null | grep -qi 'trust' && lab pane send-keys "$PANE" Enter >/dev/null 2>&1
  sleep 1
done
sleep 3
log "agent status after launch: $(agent_status)"
snap 01-idle
log "S1 idle: HEAD verdict=$(classify) | pre-fix lib verdict=$(classify "$BASE_LIB")"
grep "╰" "$EV/01-idle.txt" | grep -o "Grok [^─]*" | head -1 | sed 's/^/   bottom title: /' | tee -a "$EV/live-transcript.txt"

cat > "$SCRATCH/home.sh" <<SH
SH
HOME_DIR="$SCRATCH/fmhome"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/glive"
printf '# Task\n## Captain'"'"'s intent\nlive grok exit\n\n## Firstmate spec\nkeep worktree\n' > "$HOME_DIR/data/glive/brief.md"
{
  echo "window=$TARGET"; echo "endpoint_task_id=glive"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=grok"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=on"; echo "model=default"; echo "effort=low"
  echo "backend=herdr"; echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"
} > "$HOME_DIR/state/glive.meta"
run_control() {
  env PATH="$FAKEBIN:$ORIG_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_CONTROL_POLL=0.5 FM_CONTROL_EXIT_WAIT=30 "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# S2 adversarial: typed text must be pending and exit must refuse without typing.
lab pane send-text "$PANE" "deploy the fix now" >/dev/null; sleep 2
snap 02-typed
log "S2 typed: HEAD verdict=$(classify) | pre-fix lib verdict=$(classify "$BASE_LIB")"
OUT=$(run_control glive exit); RC=$?
log "S2 fm-control exit on typed composer: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/   /' | tee -a "$EV/live-transcript.txt"
snap 02b-typed-after-refusal
grep -q 'deploy the fix now' "$EV/02b-typed-after-refusal.txt" && ! grep -q 'deploy the fix now/exit' "$EV/02b-typed-after-refusal.txt" \
  && log "   typed text intact, no /exit concatenated" || log "   WARNING: composer changed after refusal"
log "   agent status: $(agent_status)"

# clear composer
for _ in $(seq 1 25); do lab pane send-keys "$PANE" Backspace >/dev/null 2>&1; done; sleep 2
snap 03-cleared
log "S3 cleared composer: HEAD verdict=$(classify) | pre-fix lib verdict=$(classify "$BASE_LIB")"

# S4 post-turn: submit a trivial turn and wait for it to finish.
if [ "${SKIP_TURN:-0}" != 1 ]; then
  lab pane send-text "$PANE" "Reply with only the word ok. Do not use tools." >/dev/null; sleep 0.5
  lab pane send-keys "$PANE" Enter >/dev/null
  for i in $(seq 1 120); do
    sleep 1; s=$(agent_status); [ "$i" -gt 5 ] && [ "$s" = idle -o "$s" = done ] && break
  done
  sleep 3
  snap 04-postturn
  log "S4 post-turn empty composer (agent $(agent_status)): HEAD verdict=$(classify) | pre-fix lib verdict=$(classify "$BASE_LIB")"
fi

# S5 pre-fix exit reproduction (control plane with pre-fix composer lib) then HEAD exit
if [ -n "${BASE_ROOT:-}" ]; then
  OUT=$(env PATH="$FAKEBIN:$ORIG_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_CONTROL_POLL=0.5 FM_CONTROL_EXIT_WAIT=30 "$BASE_ROOT/bin/fm-control.sh" glive exit 2>&1); RC=$?
  log "S5a PRE-FIX fm-control exit on empty grok composer: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/   /' | tee -a "$EV/live-transcript.txt"
  log "   agent status: $(agent_status)"
fi
OUT=$(run_control glive exit); RC=$?
log "S5b HEAD fm-control exit on empty grok composer: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/   /' | tee -a "$EV/live-transcript.txt"
sleep 2
snap 05-after-exit
log "   agent status after exit: $(agent_status)"
lab pane get "$PANE" >/dev/null 2>&1 && log "   endpoint pane $PANE still present" || log "   endpoint pane GONE"
[ -f "$WT/scratch.txt" ] && log "   worktree uncommitted file preserved" || log "   worktree file LOST"
pgrep -af "grok --always-approve --no-alt-screen" | grep -v pgrep | sed 's/^/   remaining grok proc: /' | tee -a "$EV/live-transcript.txt"
