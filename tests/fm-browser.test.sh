#!/usr/bin/env bash
# Behavior tests for fm-browser.sh: launch a Chrome-family browser with a
# debugging port and a home-private profile, reuse a live port, print the
# chrome-devtools-axi environment, and stop only the browser it started.
# A node fake stands in for the browser and answers /json/version.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROWSER="$ROOT/bin/fm-browser.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser)
# Every fake browser runs from under TMP_ROOT, so this reaps only this suite's.
reap_fakes() { pkill -f -- "$TMP_ROOT/fake-chrome" 2>/dev/null; fm_test_cleanup; }
trap reap_fakes EXIT

command -v node >/dev/null 2>&1 || { pass "SKIP: node unavailable"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "SKIP: curl unavailable"; exit 0; }

FAKE="$TMP_ROOT/fake-chrome"
cat > "$FAKE" <<'JS'
#!/usr/bin/env node
const fs = require('fs');
const http = require('http');
const args = process.argv.slice(2);
if (process.env.FAKE_ARGS_LOG) fs.appendFileSync(process.env.FAKE_ARGS_LOG, args.join(' ') + '\n');
const port = Number((args.find(a => a.startsWith('--remote-debugging-port=')) || '').split('=')[1]);
http.createServer((req, res) => {
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ Browser: 'FakeChrome/1.0' }));
}).listen(port, '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
JS
chmod +x "$FAKE"

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# An exited browser can linger as a zombie until a subreaper collects it, and
# kill -0 still succeeds on a zombie, so read the process state instead.
running() {
  local st
  st=$(ps -p "$1" -o stat= 2>/dev/null) || return 1
  case "$st" in ''|Z*) return 1 ;; esac
}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# run <home> <port> <subcommand> - stdout to $home/out, stderr to $home/err.
run() {
  local home=$1 port=$2
  shift 2
  RC=0
  FM_HOME="$home" FM_BROWSER_BIN="$FAKE" FM_BROWSER_PORT="$port" FM_BROWSER_WAIT=10 \
    FAKE_ARGS_LOG="$home/args.log" "$BROWSER" "$@" >"$home/out" 2>"$home/err" || RC=$?
}

stop_quietly() {
  FM_HOME="$1" FM_BROWSER_PORT="$2" "$BROWSER" stop >/dev/null 2>&1 || true
}

test_start_launches_reuses_and_stops() {
  local home port pid
  home=$(make_home owned)
  port=$(free_port)
  run "$home" "$port" start
  expect_code 0 "$RC" "start"
  assert_contains "$(cat "$home/out")" "export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:$port" "start printed the browser URL"
  assert_contains "$(cat "$home/out")" "export CHROME_DEVTOOLS_AXI_SESSION=fm-visible" "start printed the session"
  assert_contains "$(cat "$home/args.log")" "--user-data-dir=$home/state/browser/profile" "profile lives under the home's state"
  assert_contains "$(cat "$home/args.log")" "--no-first-run" "first-run suppressed"
  pid=$(cat "$home/state/browser/pid")

  run "$home" "$port" start
  expect_code 0 "$RC" "second start"
  assert_equals 1 "$(wc -l < "$home/args.log" | tr -d ' ')" "second start launched another browser"
  assert_contains "$(cat "$home/err")" "reusing the browser already running" "second start did not report reuse"

  run "$home" "$port" status
  assert_contains "$(cat "$home/out")" "running: pid $pid" "status names the owned browser"

  run "$home" "$port" stop
  expect_code 0 "$RC" "stop"
  running "$pid" && fail "stop left the browser running"
  curl -fsS --max-time 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 && fail "port still answers after stop"
  assert_absent "$home/state/browser/pid" "stop kept the pid record"
  pass "start launches with a home profile, reuses a live port, and stop closes it"
}

test_wayland_flag_only_under_wayland() {
  local home port
  home=$(make_home wayland)
  port=$(free_port)
  RC=0
  env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE FM_HOME="$home" FM_BROWSER_BIN="$FAKE" FM_BROWSER_PORT="$port" \
    FAKE_ARGS_LOG="$home/args.log" "$BROWSER" start >/dev/null 2>&1 || RC=$?
  expect_code 0 "$RC" "start without wayland"
  assert_not_contains "$(cat "$home/args.log")" "--ozone-platform" "wayland flag passed outside wayland"
  stop_quietly "$home" "$port"

  [ "$(uname -s)" = Darwin ] && { pass "wayland flag omitted off wayland (macOS skips the wayland case)"; return; }
  : > "$home/args.log"
  port=$(free_port)
  RC=0
  WAYLAND_DISPLAY=wayland-1 FM_HOME="$home" FM_BROWSER_BIN="$FAKE" FM_BROWSER_PORT="$port" \
    FAKE_ARGS_LOG="$home/args.log" "$BROWSER" start >/dev/null 2>&1 || RC=$?
  expect_code 0 "$RC" "start under wayland"
  assert_contains "$(cat "$home/args.log")" "--ozone-platform=wayland" "wayland flag missing under wayland"
  stop_quietly "$home" "$port"
  pass "wayland flag is passed only under wayland"
}

test_stop_leaves_foreign_browser_running() {
  local home port foreign
  home=$(make_home foreign)
  port=$(free_port)
  FAKE_ARGS_LOG=/dev/null "$FAKE" "--remote-debugging-port=$port" --user-data-dir=/elsewhere &
  foreign=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS --max-time 1 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 && break
    sleep 0.3
  done

  run "$home" "$port" start
  expect_code 0 "$RC" "start against a foreign browser"
  assert_absent "$home/args.log" "start launched a browser although the port already answered"
  assert_contains "$(cat "$home/err")" "did not start" "start did not flag the foreign browser"

  run "$home" "$port" stop
  expect_code 0 "$RC" "stop against a foreign browser"
  running "$foreign" || fail "stop killed a browser it did not start"
  assert_contains "$(cat "$home/err")" "leaving it running" "stop did not explain why it left the browser"
  kill "$foreign" 2>/dev/null
  wait "$foreign" 2>/dev/null
  pass "stop leaves a browser it did not start running"
}

test_env_and_missing_browser() {
  local home port
  home=$(make_home env)
  port=$(free_port)
  RC=0
  FM_HOME="$home" FM_BROWSER_PORT="$port" FM_BROWSER_SESSION=custom "$BROWSER" env >"$home/out" 2>&1 || RC=$?
  expect_code 0 "$RC" "env"
  assert_equals "export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:$port
export CHROME_DEVTOOLS_AXI_SESSION=custom" "$(cat "$home/out")" "env output"
  assert_absent "$home/state/browser" "env created browser state"

  RC=0
  FM_HOME="$home" FM_BROWSER_BIN="$home/nope" FM_BROWSER_PORT="$port" "$BROWSER" start >"$home/out" 2>"$home/err" || RC=$?
  expect_code 1 "$RC" "start with a missing browser"
  assert_contains "$(cat "$home/err")" "FM_BROWSER_BIN is not an executable" "missing browser error"
  pass "env prints the attach values and a missing browser is reported"
}

test_start_launches_reuses_and_stops
test_wayland_flag_only_under_wayland
test_stop_leaves_foreign_browser_running
test_env_and_missing_browser
