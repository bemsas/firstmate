#!/usr/bin/env bash
# fm-grokbot-port-health.sh - keep Grok Bot's local debug port up.
#
# The port is TCP 127.0.0.1:9333. A healthy port is a no-op.
# A relaunch runs only when that port is down and Grok Bot is not applying
# an update. The update signal is the app's own ShipIt request file,
# ~/Library/Caches/com.anysphere.sand.ShipIt/ShipItState.plist, which the
# installed app treats as shipItRequestPresent. Existence of that regular
# file is enough. The file is not parsed.
# The relaunch is: quit Grok Bot when it is running, then open
# /Applications/Grok Bot.app with --remote-debugging-port=9333.
# This script does not send a message, post, email, direct-message, or spend.
# Grok Bot stays on private drafts. A public post still needs the captain.
#
# Every run appends one JSON line to
# $FM_HOME/data/hermes-bridge/grokbot-port-health.jsonl.
# Probe, quit, and relaunch waits are bounded.
#
# Test seams, all optional:
#   FM_GROKBOT_PORT_PROBE     executable, exit 0 when the port is up
#   FM_GROKBOT_UPDATE_PLIST   path of the ShipIt request file
#   FM_GROKBOT_APP_PROBE      executable, exit 0 when the app is running
#   FM_GROKBOT_QUIT           executable that quits the app
#   FM_GROKBOT_RELAUNCH       executable that starts the app with the port
#   FM_GROKBOT_PROBE_SECONDS  bound for one port probe (default 5)
#   FM_GROKBOT_RELAUNCH_SECONDS bound for quit and open (default 15)
#   FM_GROKBOT_WAIT_SECONDS   bound to see the port after relaunch (default 20)
#
# Exit codes:
#   0    port healthy, update in progress, or relaunch restored the port
#   1    relaunch failed or the port stayed down
#   2    usage or a missing home
#   124  a bounded wait was hit
#
# Usage:
#   fm-grokbot-port-health.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

umask 077

help_text() {
  cat <<'EOF'
Check TCP 127.0.0.1:9333 and relaunch Grok Bot only when it is down.

A healthy port does nothing. A ShipItState.plist update request does nothing.
The relaunch passes --remote-debugging-port=9333 and does not send a message.
Each run appends one private JSON line under the home.
EOF
}

case "${1:-}" in
  --help|-h) help_text; exit 0 ;;
  '') ;;
  *) printf '%s\n' 'error: no arguments are accepted' >&2; exit 2 ;;
esac

home=${FM_HOME:-}
case "$home" in
  /*) ;;
  *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
esac
[ -d "$home" ] || { printf '%s\n' 'error: FM_HOME is not a directory' >&2; exit 2; }

probe_seconds=${FM_GROKBOT_PROBE_SECONDS:-5}
relaunch_seconds=${FM_GROKBOT_RELAUNCH_SECONDS:-15}
wait_seconds=${FM_GROKBOT_WAIT_SECONDS:-20}
valid_bound() {  # <seconds>
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' 'error: bounds must be positive integers' >&2; exit 2 ;;
  esac
  [ "$1" -ge 1 ] || { printf '%s\n' 'error: bounds must be positive integers' >&2; exit 2; }
}
valid_bound "$probe_seconds"
valid_bound "$relaunch_seconds"
valid_bound "$wait_seconds"

log_dir=$home/data/hermes-bridge
log=$log_dir/grokbot-port-health.jsonl
mkdir -p "$log_dir"
chmod 700 "$log_dir" || true

append_log() {  # <outcome> <detail>
  local outcome=$1 detail=$2 ts json
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  json=$(jq -nc --arg ts "$ts" --arg outcome "$outcome" --arg detail "$detail" \
    '{timestamp:$ts,outcome:$outcome,detail:$detail}')
  touch "$log"
  chmod 600 "$log"
  printf '%s\n' "$json" >> "$log"
}

port_up() {
  local rc=0 probe=${FM_GROKBOT_PORT_PROBE:-}
  set +e
  if [ -n "$probe" ]; then
    fm_run_timed "$probe_seconds" "$probe"
  else
    fm_run_timed "$probe_seconds" nc -z -G "$probe_seconds" 127.0.0.1 9333
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ]
}

update_in_progress() {
  local plist=${FM_GROKBOT_UPDATE_PLIST:-$HOME/Library/Caches/com.anysphere.sand.ShipIt/ShipItState.plist}
  [ -f "$plist" ] && [ ! -L "$plist" ]
}

app_running() {
  local probe=${FM_GROKBOT_APP_PROBE:-}
  if [ -n "$probe" ]; then
    "$probe" >/dev/null 2>&1
    return
  fi
  pgrep -f '/Applications/Grok Bot.app/Contents/MacOS/Grok Bot' >/dev/null 2>&1
}

quit_app() {
  local quit=${FM_GROKBOT_QUIT:-} rc=0
  set +e
  if [ -n "$quit" ]; then
    fm_run_timed "$relaunch_seconds" "$quit"
  else
    fm_run_timed "$relaunch_seconds" osascript -e 'tell application "Grok Bot" to quit'
  fi
  rc=$?
  set -e
  return "$rc"
}

open_app() {
  local relaunch=${FM_GROKBOT_RELAUNCH:-} rc=0
  set +e
  if [ -n "$relaunch" ]; then
    fm_run_timed "$relaunch_seconds" "$relaunch"
  else
    fm_run_timed "$relaunch_seconds" open -na '/Applications/Grok Bot.app' --args --remote-debugging-port=9333
  fi
  rc=$?
  set -e
  return "$rc"
}

if port_up; then
  append_log healthy 'port 127.0.0.1:9333 is up'
  exit 0
fi

if update_in_progress; then
  append_log update 'ShipIt request is present; port left down'
  exit 0
fi

rc=0
if app_running; then
  quit_app || rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      append_log timeout 'quit exceeded its bound'
      exit 124
    fi
    append_log failure 'quit failed'
    exit 1
  fi
fi

rc=0
open_app || rc=$?
if [ "$rc" -ne 0 ]; then
  if fm_timed_out "$rc"; then
    append_log timeout 'relaunch exceeded its bound'
    exit 124
  fi
  append_log failure 'relaunch failed'
  exit 1
fi

deadline=$(( $(date +%s) + wait_seconds ))
while [ "$(date +%s)" -le "$deadline" ]; do
  if port_up; then
    append_log relaunch 'opened Grok Bot with --remote-debugging-port=9333'
    exit 0
  fi
  sleep 1
done
append_log timeout 'port stayed down after relaunch'
exit 124
