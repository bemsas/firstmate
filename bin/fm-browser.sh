#!/usr/bin/env bash
# fm-browser.sh - start a visible browser window that agents drive through
# chrome-devtools-axi while a person watches it and logs in by hand.
#
# Usage:
#   fm-browser.sh [start]   start the browser, or reuse one already listening on
#                           the port; prints the export lines below on stdout
#   fm-browser.sh env       print the export lines without starting anything
#   fm-browser.sh status    report whether the port answers and who started it
#   fm-browser.sh stop      close the browser this script started, and only that
#
# Typical use:
#   eval "$(bin/fm-browser.sh start)"
#   chrome-devtools-axi open https://example.com
#
# The export lines are:
#   export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:<port>
#   export CHROME_DEVTOOLS_AXI_SESSION=<session>
# so chrome-devtools-axi attaches to this headed window instead of launching its
# own browser. Pages come back as a text accessibility tree with clickable refs,
# not screenshots, while the window stays on the desktop.
#
# The browser runs with a dedicated persistent profile under
# $FM_HOME/state/browser/profile, never the person's everyday profile, so logins
# made in the window survive restarts of the browser and of firstmate.
#
# Environment:
#   FM_BROWSER_BIN      browser executable; otherwise the first of google-chrome,
#                       google-chrome-stable, chrome, chromium, chromium-browser on
#                       PATH, then the macOS Google Chrome and Chromium app bundles
#   FM_BROWSER_PORT     remote-debugging port (default 9333)
#   FM_BROWSER_SESSION  chrome-devtools-axi session name (default fm-visible)
#   FM_BROWSER_WAIT     seconds to wait for the debugging port (default 20)
#
# Wayland sessions (WAYLAND_DISPLAY set, or XDG_SESSION_TYPE=wayland) also get
# --ozone-platform=wayland; other platforms get no display flags.
#
# stop signals only the process id this script recorded, and only while that
# process still carries this home's profile directory on its command line; a
# browser someone else started on the same port is left running.
#
# Exit codes: 0 success, 1 failure (no browser found, port never answered, or a
# stop that could not close its browser), 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

BROWSER_DIR="$STATE/browser"
PROFILE="$BROWSER_DIR/profile"
PIDFILE="$BROWSER_DIR/pid"
LOG="$BROWSER_DIR/browser.log"
PORT="${FM_BROWSER_PORT:-9333}"
SESSION="${FM_BROWSER_SESSION:-fm-visible}"
WAIT="${FM_BROWSER_WAIT:-20}"
URL="http://127.0.0.1:$PORT"

die() { printf 'fm-browser: %s\n' "$*" >&2; exit 1; }
say() { printf 'fm-browser: %s\n' "$*" >&2; }

case "$PORT" in ''|*[!0-9]*) printf 'fm-browser: FM_BROWSER_PORT must be a port number\n' >&2; exit 2 ;; esac
case "$WAIT" in ''|*[!0-9]*) printf 'fm-browser: FM_BROWSER_WAIT must be whole seconds\n' >&2; exit 2 ;; esac

print_env() {
  printf 'export CHROME_DEVTOOLS_AXI_BROWSER_URL=%s\n' "$URL"
  printf 'export CHROME_DEVTOOLS_AXI_SESSION=%s\n' "$SESSION"
}

port_answers() {
  curl -fsS --max-time 2 "$URL/json/version" >/dev/null 2>&1
}

find_browser() {
  local c
  if [ -n "${FM_BROWSER_BIN:-}" ]; then
    [ -x "$FM_BROWSER_BIN" ] || command -v "$FM_BROWSER_BIN" >/dev/null 2>&1 \
      || die "FM_BROWSER_BIN is not an executable: $FM_BROWSER_BIN"
    printf '%s\n' "$FM_BROWSER_BIN"
    return 0
  fi
  for c in google-chrome google-chrome-stable chrome chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "/Applications/Chromium.app/Contents/MacOS/Chromium" \
           "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "$HOME/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  die "no Chrome-family browser found; install Chrome or Chromium, or set FM_BROWSER_BIN"
}

# A zombie child still passes kill -0, so read the process state instead.
alive() {
  local st
  st=$(ps -p "$1" -o stat= 2>/dev/null) || return 1
  case "$st" in ''|Z*) return 1 ;; esac
}

# Prints the recorded pid only while that process is still our browser.
owned_pid() {
  local pid args
  [ -f "$PIDFILE" ] || return 1
  pid=$(head -n1 "$PIDFILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  args=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
  case "$args" in *"--user-data-dir=$PROFILE"*) printf '%s\n' "$pid" ;; *) return 1 ;; esac
}

cmd_start() {
  local bin pid waited=0
  local -a args
  if port_answers; then
    if owned_pid >/dev/null; then
      say "reusing the browser already running on port $PORT"
    else
      say "reusing a browser this script did not start, already listening on port $PORT"
    fi
    print_env
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to check the debugging port"
  bin=$(find_browser) || exit 1
  mkdir -p "$PROFILE" || die "cannot create profile directory $PROFILE"
  args=(
    "--remote-debugging-port=$PORT"
    "--user-data-dir=$PROFILE"
    --no-first-run
    --no-default-browser-check
  )
  if [ "$(uname -s)" != Darwin ] \
    && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; }; then
    args+=(--ozone-platform=wayland)
  fi
  nohup "$bin" "${args[@]}" >"$LOG" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$PIDFILE"
  while ! port_answers; do
    if ! alive "$pid"; then
      rm -f "$PIDFILE"
      die "browser exited before its debugging port answered; see $LOG"
    fi
    [ "$waited" -ge "$WAIT" ] && die "debugging port $PORT did not answer within ${WAIT}s; see $LOG"
    sleep 1
    waited=$((waited + 1))
  done
  say "started $bin on port $PORT with profile $PROFILE"
  print_env
}

cmd_status() {
  local pid
  if port_answers; then
    if pid=$(owned_pid); then
      printf 'running: pid %s on port %s, profile %s\n' "$pid" "$PORT" "$PROFILE"
    else
      printf 'running: port %s answers, but this script did not start that browser\n' "$PORT"
    fi
  else
    printf 'stopped: nothing answers on port %s\n' "$PORT"
  fi
}

cmd_stop() {
  local pid waited=0
  if ! pid=$(owned_pid); then
    rm -f "$PIDFILE"
    if port_answers; then
      say "the browser on port $PORT was not started by this script; leaving it running"
    else
      say "no browser started by this script is running"
    fi
    return 0
  fi
  kill "$pid" 2>/dev/null
  while alive "$pid"; do
    [ "$waited" -ge 10 ] && die "browser pid $pid did not exit after SIGTERM"
    sleep 1
    waited=$((waited + 1))
  done
  rm -f "$PIDFILE"
  say "stopped browser pid $pid"
}

sub="${1:-start}"
[ "$#" -gt 1 ] && { printf 'usage: fm-browser.sh [start|env|status|stop]\n' >&2; exit 2; }
case "$sub" in
  start) mkdir -p "$BROWSER_DIR" || die "cannot create $BROWSER_DIR"; cmd_start ;;
  env) print_env ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) printf 'usage: fm-browser.sh [start|env|status|stop]\n' >&2; exit 2 ;;
esac
