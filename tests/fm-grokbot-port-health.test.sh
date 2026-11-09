#!/usr/bin/env bash
# tests/fm-grokbot-port-health.test.sh - Grok Bot port check through its executable.
#
# Port, update, quit, and relaunch are fixture commands. The real app is not touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP_ROOT=$(fm_test_tmproot fm-grokbot-port-health)
mkdir -p "$TMP_ROOT/stub"
STDOUT="$TMP_ROOT/stdout"
STDERR="$TMP_ROOT/stderr"
STUB="$TMP_ROOT/stub"
PROBE="$STUB/probe"
APP="$STUB/app"
QUIT="$STUB/quit"
RELAUNCH="$STUB/relaunch"
PLIST="$STUB/ShipItState.plist"

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

cat > "$PROBE" << 'EOF'
#!/usr/bin/env bash
set -eu
dir=${FM_GROKBOT_STUB_DIR:?}
printf 'x\n' >> "$dir/probes"
n=$(wc -l < "$dir/probes" | tr -d ' ')
mode=$(cat "$dir/probe-mode")
case "$mode" in
  up) exit 0 ;;
  down) exit 1 ;;
  second)
    [ "$n" -ge 2 ] && exit 0
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF

cat > "$APP" << 'EOF'
#!/usr/bin/env bash
set -eu
dir=${FM_GROKBOT_STUB_DIR:?}
mode=$(cat "$dir/app-mode")
[ "$mode" = up ]
EOF

cat > "$QUIT" << 'EOF'
#!/usr/bin/env bash
set -eu
dir=${FM_GROKBOT_STUB_DIR:?}
printf 'quit\n' >> "$dir/actions"
mode=$(cat "$dir/quit-mode")
case "$mode" in
  ok) exit 0 ;;
  fail) exit 3 ;;
  hang) sleep 8; exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat > "$RELAUNCH" << 'EOF'
#!/usr/bin/env bash
set -eu
dir=${FM_GROKBOT_STUB_DIR:?}
printf 'relaunch\n' >> "$dir/actions"
mode=$(cat "$dir/relaunch-mode")
case "$mode" in
  ok) exit 0 ;;
  fail) exit 3 ;;
  hang) sleep 8; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PROBE" "$APP" "$QUIT" "$RELAUNCH"

seed_home() {
  local dir
  dir=$(fm_test_tmproot fm-grokbot-port-home)
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

reset_stub() {  # <probe-mode> <app-mode> <quit-mode> <relaunch-mode>
  rm -f "$STUB/probes" "$STUB/actions" "$PLIST"
  printf '%s\n' "$1" > "$STUB/probe-mode"
  printf '%s\n' "$2" > "$STUB/app-mode"
  printf '%s\n' "$3" > "$STUB/quit-mode"
  printf '%s\n' "$4" > "$STUB/relaunch-mode"
}

invoke() {  # <home>
  local home=$1
  rm -f "$STDOUT" "$STDERR"
  set +e
  FM_HOME="$home" \
    FM_GROKBOT_PORT_PROBE="$PROBE" \
    FM_GROKBOT_UPDATE_PLIST="$PLIST" \
    FM_GROKBOT_APP_PROBE="$APP" \
    FM_GROKBOT_QUIT="$QUIT" \
    FM_GROKBOT_RELAUNCH="$RELAUNCH" \
    FM_GROKBOT_STUB_DIR="$STUB" \
    FM_GROKBOT_PROBE_SECONDS="${FM_GROKBOT_PROBE_SECONDS:-1}" \
    FM_GROKBOT_RELAUNCH_SECONDS="${FM_GROKBOT_RELAUNCH_SECONDS:-2}" \
    FM_GROKBOT_WAIT_SECONDS="${FM_GROKBOT_WAIT_SECONDS:-3}" \
    bash "$ROOT/bin/fm-grokbot-port-health.sh" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  return 0
}

log_of() { printf '%s/data/hermes-bridge/grokbot-port-health.jsonl' "$1"; }

assert_outcome() {  # <home> <outcome> <detail>
  local log
  log=$(log_of "$1")
  [ -f "$log" ] || fail "health log missing"
  [ "$(mode_of "$log")" = 600 ] || fail "health log mode $(mode_of "$log")"
  jq -se --arg outcome "$2" --arg detail "$3" \
    'any(.[]; .outcome == $outcome and .detail == $detail and .timestamp != "")' \
    "$log" >/dev/null || fail "missing $2 log: $(cat "$log")"
}

healthy_port_does_nothing() {
  local home
  home=$(seed_home)
  reset_stub up down ok ok
  printf '%s\n' 'SECRET-UPDATE-URL' > "$PLIST"
  invoke "$home"
  [ "$INVOKE_RC" -eq 0 ] || fail "healthy port exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" healthy 'port 127.0.0.1:9333 is up'
  assert_absent "$STUB/actions" "a healthy port quit or relaunched"
  if grep -q 'SECRET-UPDATE-URL' "$(log_of "$home")"; then
    fail "health log copied the update file"
  fi
  pass "a healthy port is a no-op"
}

update_in_progress_does_nothing() {
  local home
  home=$(seed_home)
  reset_stub down up hang hang
  printf '%s\n' 'SECRET-UPDATE-URL' > "$PLIST"
  invoke "$home"
  [ "$INVOKE_RC" -eq 0 ] || fail "update no-op exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" update 'ShipIt request is present; port left down'
  assert_absent "$STUB/actions" "an update quit or relaunched"
  if grep -q 'SECRET-UPDATE-URL' "$(log_of "$home")"; then
    fail "update log copied the update file"
  fi
  printf '%s\n' 'not-a-signal' > "$STUB/plist-body"
  reset_stub second down ok ok
  ln -sf "$STUB/plist-body" "$PLIST"
  invoke "$home"
  [ "$INVOKE_RC" -eq 0 ] || fail "symlink update signal exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_grep 'relaunch' "$STUB/actions" "a symlink was treated as an update"
  assert_outcome "$home" relaunch 'opened Grok Bot with --remote-debugging-port=9333'
  pass "a real update request does nothing and a symlink does not"
}

missing_port_relaunches_within_bounds() {
  local home
  home=$(seed_home)
  reset_stub second down ok ok
  invoke "$home"
  [ "$INVOKE_RC" -eq 0 ] || fail "relaunch exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" relaunch 'opened Grok Bot with --remote-debugging-port=9333'
  assert_grep 'relaunch' "$STUB/actions" "missing port did not relaunch"
  if grep -q 'quit' "$STUB/actions"; then
    fail "a stopped app was quit"
  fi
  pass "a missing port relaunches Grok Bot and records it"
}

timeout_and_failure_are_logged() {
  local home
  unset FM_GROKBOT_PROBE_SECONDS FM_GROKBOT_RELAUNCH_SECONDS FM_GROKBOT_WAIT_SECONDS || true
  home=$(seed_home)
  reset_stub down up hang ok
  FM_GROKBOT_RELAUNCH_SECONDS=1
  invoke "$home"
  [ "$INVOKE_RC" -eq 124 ] || fail "quit timeout exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" timeout 'quit exceeded its bound'
  assert_no_grep 'relaunch' "$STUB/actions" "quit timeout continued to relaunch"
  home=$(seed_home)
  reset_stub down down ok hang
  FM_GROKBOT_RELAUNCH_SECONDS=1
  invoke "$home"
  [ "$INVOKE_RC" -eq 124 ] || fail "relaunch timeout exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" timeout 'relaunch exceeded its bound'
  home=$(seed_home)
  reset_stub down down ok fail
  FM_GROKBOT_RELAUNCH_SECONDS=2
  invoke "$home"
  [ "$INVOKE_RC" -eq 1 ] || fail "relaunch failure exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" failure 'relaunch failed'
  home=$(seed_home)
  reset_stub down up fail ok
  invoke "$home"
  [ "$INVOKE_RC" -eq 1 ] || fail "quit failure exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" failure 'quit failed'
  assert_no_grep 'relaunch' "$STUB/actions" "quit failure continued to relaunch"
  home=$(seed_home)
  reset_stub down down ok ok
  FM_GROKBOT_WAIT_SECONDS=1
  FM_GROKBOT_PROBE_SECONDS=1
  printf '%s\n' down > "$STUB/probe-mode"
  invoke "$home"
  [ "$INVOKE_RC" -eq 124 ] || fail "port wait exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_outcome "$home" timeout 'port stayed down after relaunch'
  bash "$ROOT/bin/fm-grokbot-port-health.sh" --help >"$STDOUT" || fail "help failed"
  assert_contains "$(cat "$STDOUT")" 'does not send a message' "help hid the no-send rule"
  set +e
  FM_HOME="$home" bash "$ROOT/bin/fm-grokbot-port-health.sh" --extra >"$STDOUT" 2>"$STDERR"
  [ "$?" -eq 2 ] || fail "extra args were accepted"
  FM_GROKBOT_PROBE_SECONDS=0 FM_HOME="$home" \
    FM_GROKBOT_PORT_PROBE="$PROBE" \
    FM_GROKBOT_UPDATE_PLIST="$PLIST" \
    bash "$ROOT/bin/fm-grokbot-port-health.sh" >"$STDOUT" 2>"$STDERR"
  [ "$?" -eq 2 ] || fail "a zero bound was accepted"
  set -e
  pass "timeouts and failures stay private and bounded"
}

healthy_port_does_nothing
update_in_progress_does_nothing
missing_port_relaunches_within_bounds
timeout_and_failure_are_logged
