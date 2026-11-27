#!/usr/bin/env bash
# Focused safety tests for bin/fm-herdr-session-cleanup.sh.
# Covers one exact cleanup, every title/journal/topology/agent/process refusal,
# locked revalidation races, focus refusal, read errors, and repeat idempotence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-session-cleanup)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
touch "$FM_CONFIG_OVERRIDE/herdr-presentation-spaces"
printf '%s\n' herdr > "$FM_CONFIG_OVERRIDE/backend"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
export PATH="$FAKEBIN:$PATH"
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-session-cleanup.sh"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY

# The idle-shell proof now lives in the backend as
# fm_backend_herdr_pane_idle_shell_pid; prove it still reads Linux argv
# arrays (no argv0 field) and rejects malformed executable identities.
FAKE_PS="$TMP_ROOT/fake-ps"
cat > "$FAKE_PS" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n67 1\n' ;;
  "-p 67 -o stat=") printf 'Ss\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_PS"
LINUX_PROCESS_INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":["/bin/sh"],"name":"sh","pid":67}]}}}'
argv_pid=$(
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' "$LINUX_PROCESS_INFO"; }
  FM_HERDR_PS_BIN="$FAKE_PS" fm_backend_herdr_pane_idle_shell_pid test w2:p1
) || fail "Linux Herdr process argv array was not accepted"
[ "$argv_pid" = 67 ] || fail "idle-shell proof printed the wrong shell pid: $argv_pid"
if (
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":[67],"name":"sh","pid":67}]}}}'; }
  FM_HERDR_PS_BIN="$FAKE_PS" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_idle_shell_pid test w2:p1
) >/dev/null 2>&1; then
  fail "non-string Herdr process argv was accepted"
fi
pass "process proof reads Linux Herdr argv arrays and rejects malformed executable identities"

TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=task
WS=w2
TAB=w2:t1
PANE=w2:p1
TITLE="└ task · p:$TOKEN"
FIXTURE_DIR="$TMP_ROOT/fixture"
LOCK_LOG="$TMP_ROOT/locks.log"
CLOSE_LOG="$TMP_ROOT/closes.log"
mkdir -p "$FIXTURE_DIR"

fm_backend_name() { printf herdr; }
fm_backend_herdr_session() { printf test; }
fm_backend_herdr_presentation_session_lock_path() {
  if [ -e "$FIXTURE_DIR/lock-path-missing" ]; then
    return 1
  fi
  if [ -f "$FIXTURE_DIR/next-lock-path" ]; then
    cat "$FIXTURE_DIR/next-lock-path"
    return 0
  fi
  printf '%s/presentation.lock' "$TMP_ROOT"
}
fm_lock_try_acquire() {
  local base hold n lockdir
  base=$(basename "$1")
  printf '%s\n' "$1" >> "$LOCK_LOG"
  [ ! -f "$FIXTURE_DIR/lock-cost-ms" ] || fake_clock_advance "$(cat "$FIXTURE_DIR/lock-cost-ms")"
  hold="$FIXTURE_DIR/hold-count-$base"
  if [ -f "$hold" ]; then
    n=$(cat "$hold")
    case "$n" in
      ''|*[!0-9]*|0) ;;
      *)
        for lockdir in "$FM_STATE_OVERRIDE"/.spawn-*.lock; do
          if [ -d "$lockdir" ]; then
            printf 'held\n' >> "$FIXTURE_DIR/task-lock-during-wait"
          else
            printf 'missing\n' >> "$FIXTURE_DIR/task-lock-during-wait"
          fi
          break
        done
        printf '%s\n' "$((n - 1))" > "$hold"
        if [ "$((n - 1))" -eq 0 ] && [ -f "$FIXTURE_DIR/on-wait-release-$base" ]; then
          bash "$FIXTURE_DIR/on-wait-release-$base"
        fi
        return 1
        ;;
    esac
  fi
  if [ -f "$FIXTURE_DIR/on-lock-$base" ]; then bash "$FIXTURE_DIR/on-lock-$base"; fi
  mkdir "$1" 2>/dev/null
}
fm_lock_release() { rm -rf -- "$1"; }

# The lock-wait budget reads fm_timing_now_ms. with_fake_wait runs a command on
# a deterministic clock that only sleeps and lock-cost-ms fake lock calls move,
# logging each sleep, so a wait's length is exact without any real waiting.
fake_clock_advance() { # <ms>
  local now
  now=$(cat "$FIXTURE_DIR/clock-ms" 2>/dev/null) || return 0
  printf '%s\n' "$((now + $1))" > "$FIXTURE_DIR/clock-ms"
}
with_fake_wait() { # <command> [arg...]
  (
    printf '0\n' > "$FIXTURE_DIR/clock-ms"
    : > "$FIXTURE_DIR/sleeps"
    # shellcheck disable=SC2329 # invoked by the lock-wait budget under test.
    fm_timing_now_ms() { cat "$FIXTURE_DIR/clock-ms"; }
    # shellcheck disable=SC2329 # invoked by the lock-wait budget under test.
    sleep() { printf '%s\n' "$1" >> "$FIXTURE_DIR/sleeps"; fake_clock_advance 100; }
    "$@"
  )
}
sleep_count() { wc -l < "$FIXTURE_DIR/sleeps" | tr -d ' '; }
fm_backend_herdr_pane_idle_shell_pid() { [ ! -e "$FIXTURE_DIR/process-unsafe" ] && printf '67\n'; }
fm_backend_herdr_projection_focus_snapshot() {
  [ ! -e "$FIXTURE_DIR/focus-unreadable" ] || return 1
  printf 'w1\t%s' "$(cat "$FIXTURE_DIR/active-tab")"
}

fixture_workspace_json() {
  local title=$1 tabs=$2 panes=$3 focused=false active=$TAB
  [ "$(cat "$FIXTURE_DIR/active-tab")" = "$TAB" ] && focused=true
  printf '{"workspace_id":"%s","label":"%s","focused":%s,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}' \
    "$WS" "$title" "$focused" "$active" "$tabs" "$panes"
}

fixture_workspaces() {
  local title tabs panes
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  printf '[{"workspace_id":"w1","label":"firstmate","focused":%s,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},' \
    "$( [ "$(cat "$FIXTURE_DIR/active-tab")" = w1:t1 ] && printf true || printf false )"
  fixture_workspace_json "$title" "$tabs" "$panes"
  if [ -e "$FIXTURE_DIR/duplicate-token" ]; then
    printf ',{"workspace_id":"w3","label":"└ copy · p:%s","focused":false,"active_tab_id":"w3:t1","tab_count":1,"pane_count":1}' "$TOKEN"
  fi
  if [ -f "$FIXTURE_DIR/extra-title" ]; then
    printf ',{"workspace_id":"w4","label":"%s","focused":false,"active_tab_id":"w4:t1","tab_count":1,"pane_count":1}' \
      "$(cat "$FIXTURE_DIR/extra-title")"
  fi
  printf ']'
}

fixture_tabs() {
  local count i
  count=$(cat "$FIXTURE_DIR/tabs")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"tab_id":"%s:t%s","workspace_id":"%s","focused":false,"label":"fm-task"}' "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fixture_panes() {
  local count i
  count=$(cat "$FIXTURE_DIR/panes")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"pane_id":"%s:p%s","tab_id":"%s:t%s","workspace_id":"%s","agent_status":"unknown"}' \
      "$WS" "$i" "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fm_backend_herdr_cli() {
  local _session=$1 first=${2:-} second=${3:-} title tabs panes
  shift
  [ ! -e "$FIXTURE_DIR/error-${first}-${second}" ] || return 1
  if [ -e "$FIXTURE_DIR/closed" ]; then
    case "$first $second" in
      "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2; return 1 ;;
      "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1}]}}'; return 0 ;;
    esac
  fi
  if [ -e "$FIXTURE_DIR/race" ] && [ -e "$FIXTURE_DIR/snapshotted" ] && [ "$first $second" = "workspace list" ]; then
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},{"workspace_id":"w2","label":"renamed","focused":false,"active_tab_id":"w2:t1","tab_count":1,"pane_count":1}]}}'
    return 0
  fi
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  case "$first $second" in
    "workspace list")
      printf '{"result":{"workspaces":'; fixture_workspaces; printf '}}\n'
      ;;
    "workspace get")
      printf '{"result":{"workspace":'; fixture_workspace_json "$title" "$tabs" "$panes"; printf '}}\n'
      ;;
    "tab list")
      printf '{"result":{"tabs":'; fixture_tabs; printf '}}\n'
      ;;
    "pane list")
      printf '{"result":{"panes":'; fixture_panes; printf '}}\n'
      ;;
    "pane get")
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' "$PANE" "$TAB" "$WS"
      ;;
    "agent get")
      case "$(cat "$FIXTURE_DIR/agent")" in
        absent) printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2; return 1 ;;
        live) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
        unknown) printf '%s\n' '{"error":{"code":"internal_error"}}' >&2; return 1 ;;
      esac
      ;;
    "api snapshot")
      : > "$FIXTURE_DIR/snapshotted"
      printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"%s","focused_pane_id":"w1:p1","workspaces":' "$(cat "$FIXTURE_DIR/active-tab")"
      fixture_workspaces
      printf ',"tabs":'; fixture_tabs
      printf ',"panes":'; fixture_panes
      printf '}}}\n'
      ;;
    "session list")
      printf '%s\n' '{"sessions":[{"name":"test","running":true,"socket_path":"/tmp/fake.sock"}]}'
      ;;
    "pane close")
      : > "$FIXTURE_DIR/closed"
      ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_projection_close_pane_focus_preserving() {
  [ ! -e "$FIXTURE_DIR/focus-refuse" ] || return 1
  [ "${3:-}" = no-agent ] || return 1
  printf '%s\n' "$*" >> "$CLOSE_LOG"
  : > "$FIXTURE_DIR/closed"
}

write_v1() { # <id> [token]
  local id=$1 token=${2:-$TOKEN}
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$FM_STATE_OVERRIDE/$id.herdr-presentation"
}

write_v2() { # <home> <workspace> <tab> <pane>
  local home=$1 workspace=$2 tab=$3 pane=$4
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$ID"
    printf 'projection_id=%s\n' "$TOKEN"
    printf 'home=%s\n' "$home"
    printf 'session=test\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$workspace" "$tab" "$pane"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$TITLE" "$ID"
  } > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"
}

write_cross_home_v2() {
  mkdir -p "$TMP_ROOT/other-home"
  write_v2 "$TMP_ROOT/other-home" "$WS" "$TAB" "$PANE"
}

reset_fixture() {
  rm -rf "$FIXTURE_DIR" "$TMP_ROOT"/*.lock "${FM_STATE_OVERRIDE:?}/"*
  mkdir -p "$FIXTURE_DIR"
  : > "$LOCK_LOG"; : > "$CLOSE_LOG"
  printf '%s\n' "$TITLE" > "$FIXTURE_DIR/title"
  printf '1\n' > "$FIXTURE_DIR/tabs"
  printf '1\n' > "$FIXTURE_DIR/panes"
  printf 'w1:t1\n' > "$FIXTURE_DIR/active-tab"
  printf 'absent\n' > "$FIXTURE_DIR/agent"
  write_v1 "$ID"
}

assert_preserved() { # <case>
  local name=$1 had_journal=0
  [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] && had_journal=1
  fm_herdr_session_cleanup >/dev/null 2>&1
  if [ "$had_journal" -eq 1 ]; then
    [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "$name retired the journal"
  fi
  [ ! -s "$CLOSE_LOG" ] || fail "$name closed the pane"
  pass "$name preserves the candidate"
}

reset_fixture
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "positive cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "positive cleanup did not close exactly once"
[ "$(sed -n '1p' "$LOCK_LOG")" = "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "task lock was not acquired first"
[ "$(sed -n '2p' "$LOCK_LOG")" = "$TMP_ROOT/presentation.lock" ] || fail "presentation lock was not acquired second"
pass "exact stale projection closes one exact pane under task then presentation locks"
fm_herdr_session_cleanup >/dev/null 2>&1
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "repeat cleanup closed again"
pass "successful cleanup is idempotent on repeat"

reset_fixture; printf '%s\n' '└ malformed p:AbCdEfGhIjKlMnOpQrStUv' > "$FIXTURE_DIR/title"; assert_preserved "malformed title"
reset_fixture; printf '%s\n' '└ missing-token' > "$FIXTURE_DIR/title"; assert_preserved "missing token"
reset_fixture; printf 'version=1\ntask_id=%s\nprojection_id=short\n' "$ID" > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "malformed journal"
reset_fixture; : > "$FIXTURE_DIR/duplicate-token"; assert_preserved "duplicate token"
reset_fixture; printf '%s\n' "└ task · p:$TOKEN p:$TOKEN" > "$FIXTURE_DIR/title"; assert_preserved "duplicate title token"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "zero journal match"
reset_fixture; write_v1 fm-task; assert_preserved "multiple journal matches"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; write_cross_home_v2; assert_preserved "cross-home journal"
reset_fixture; write_v2 "$FM_HOME" w9 "$TAB" "$PANE"; assert_preserved "v2 workspace binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" w9:t1 "$PANE"; assert_preserved "v2 tab binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" w9:p1; assert_preserved "v2 pane binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" "$PANE"
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "matching v2 cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "matching v2 cleanup did not close exactly once"
pass "v2 cleanup requires and accepts the exact journal endpoint binding"
reset_fixture; : > "$FM_STATE_OVERRIDE/$ID.meta"; assert_preserved "current task metadata"
reset_fixture; printf 'live\n' > "$FIXTURE_DIR/agent"; assert_preserved "registered agent"
reset_fixture; printf 'unknown\n' > "$FIXTURE_DIR/agent"; assert_preserved "unknown agent"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/tabs"; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple tabs"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple panes"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "non-idle shell"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "child process or shell job"
reset_fixture; : > "$FIXTURE_DIR/error-api-snapshot"; assert_preserved "unreadable snapshot"
reset_fixture; : > "$FIXTURE_DIR/error-workspace-get"; assert_preserved "unreadable topology check"
reset_fixture; : > "$FIXTURE_DIR/race"; assert_preserved "revalidation race"
reset_fixture; printf '%s\n' "$TAB" > "$FIXTURE_DIR/active-tab"; assert_preserved "active target"
reset_fixture; : > "$FIXTURE_DIR/focus-refuse"; assert_preserved "focus refusal"

TOKEN2=ZyXwVuTsRqPoNmLkJiHgFe
TITLE2="└ other · p:$TOKEN2"
assert_busy_skip() { # <case> <expected-sleeps>
  assert_contains "$out" "task skipped because the shared presentation lock is busy" "$1: a busy presentation lock did not skip cleanup"
  [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "$1: a busy presentation lock retired the journal"
  [ ! -s "$CLOSE_LOG" ] || fail "$1: a busy presentation lock closed the pane"
  assert_equals "$2" "$(sleep_count)" "$1: the wait did not match its elapsed budget"
  [ ! -e "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "$1: the task lock leaked after a busy presentation lock"
}

reset_fixture
mkdir "$TMP_ROOT/presentation.lock"
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=2 with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_busy_skip "busy lock" 2
pass "a presentation lock that stays busy skips the candidate after the wait budget"

reset_fixture
mkdir "$TMP_ROOT/presentation.lock"
printf '250\n' > "$FIXTURE_DIR/lock-cost-ms"
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=5 with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_busy_skip "slow lock call" 1
pass "time spent inside slow lock calls is charged to the wait budget"

# <value>:<expected sleeps>:<ms each fake lock call costs>. With 10s lock calls a
# 60s budget ends after five sleeps, so an uncapped huge value would keep waiting.
for budget_case in 0:0:0 00:0:0 08:8:0 010:10:0 9999999999999999999999:5:10000 600:5:10000; do
  budget=${budget_case%%:*}
  expected=${budget_case#*:}
  reset_fixture
  mkdir "$TMP_ROOT/presentation.lock"
  printf '%s\n' "${expected#*:}" > "$FIXTURE_DIR/lock-cost-ms"
  status=0
  out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=$budget with_fake_wait fm_herdr_session_cleanup 2>&1) || status=$?
  assert_equals 0 "$status" "budget $budget did not exit cleanly"
  assert_not_contains "$out" "line " "budget $budget raised a shell error"
  assert_busy_skip "budget $budget" "${expected%%:*}"
done
pass "zero, leading-zero, and huge budgets are read in base 10 and capped at sixty seconds"

for malformed in abc 1.5 -3 ' 4'; do
  reset_fixture
  mkdir "$TMP_ROOT/presentation.lock"
  out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=$malformed with_fake_wait fm_herdr_session_cleanup 2>&1)
  assert_contains "$out" "FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET is not a whole number of tenths; refusing it and not waiting" "malformed budget '$malformed' was not refused"
  assert_busy_skip "malformed budget '$malformed'" 0
done
pass "a malformed budget override is refused and waits for nothing"

reset_fixture
write_v1 other "$TOKEN2"
printf '%s\n' "$TITLE2" > "$FIXTURE_DIR/extra-title"
mkdir "$TMP_ROOT/presentation.lock"
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=3 with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_contains "$out" "task skipped because the shared presentation lock is busy" "the first candidate did not skip a spent presentation budget"
assert_contains "$out" "other skipped because the shared presentation lock is busy" "the second candidate did not skip after the shared budget was spent"
assert_equals 3 "$(sleep_count)" "two busy candidates waited separately instead of sharing one budget"
[ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "the shared budget retired the first journal"
[ -f "$FM_STATE_OVERRIDE/other.herdr-presentation" ] || fail "the shared budget retired the second journal"
[ ! -s "$CLOSE_LOG" ] || fail "the shared budget closed a pane"
pass "one cleanup pass shares the presentation-lock wait across candidates"

reset_fixture
printf '2\n' > "$FIXTURE_DIR/hold-count-presentation.lock"
: > "$FIXTURE_DIR/task-lock-during-wait"
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=5 with_fake_wait fm_herdr_session_cleanup 2>&1)
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "a presentation lock released during the wait kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "a presentation lock released during the wait did not close once"
assert_equals 2 "$(sleep_count)" "a release during the wait did not retry"
assert_not_contains "$(cat "$FIXTURE_DIR/task-lock-during-wait")" "missing" "the task lock was dropped while waiting for the presentation lock"
assert_contains "$(cat "$FIXTURE_DIR/task-lock-during-wait")" "held" "the task lock was not held during the presentation wait"
[ ! -e "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] && [ ! -e "$TMP_ROOT/presentation.lock" ] || fail "locks leaked after a release during the wait"
pass "a presentation lock released during the wait closes under both locks"

reset_fixture
printf '1\n' > "$FIXTURE_DIR/hold-count-presentation.lock"
printf '#!/usr/bin/env bash\n: > %s/race\n' "$FIXTURE_DIR" > "$FIXTURE_DIR/on-wait-release-presentation.lock"
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=5 with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_contains "$out" "preserved because immediate revalidation changed or was unreadable" "a candidate that moved during the wait was not preserved"
[ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "a moved candidate retired the journal"
[ ! -s "$CLOSE_LOG" ] || fail "a moved candidate closed the pane"
[ -s "$FIXTURE_DIR/sleeps" ] || fail "a moved candidate did not wait for the presentation lock"
[ ! -e "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] && [ ! -e "$TMP_ROOT/presentation.lock" ] || fail "locks leaked after a candidate moved during the wait"
pass "a candidate that moves during the presentation wait is preserved once the lock is acquired"

assert_identity_skip() { # <case>
  assert_contains "$out" "task skipped because the shared presentation lock vanished or changed" "$1 was accepted"
  [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "$1 retired the journal"
  [ ! -s "$CLOSE_LOG" ] || fail "$1 closed the pane"
  [ ! -e "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] && [ ! -e "$TMP_ROOT/presentation.lock" ] \
    && [ ! -e "$TMP_ROOT/other-presentation.lock" ] || fail "locks leaked after $1"
}

reset_fixture
printf '#!/usr/bin/env bash\nprintf %%s\\n %s/other-presentation.lock > %s/next-lock-path\n' "$TMP_ROOT" "$FIXTURE_DIR" > "$FIXTURE_DIR/on-lock-presentation.lock"
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=5 with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_identity_skip "a lock path that changed on acquisition"
reset_fixture
printf '#!/usr/bin/env bash\n: > %s/lock-path-missing\n' "$FIXTURE_DIR" > "$FIXTURE_DIR/on-lock-presentation.lock"
out=$(with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_identity_skip "a lock path that vanished on acquisition"
pass "a presentation lock path that vanishes or changes on acquisition skips the candidate"

# The old lock stays held while the session restarts or stops, so only the
# periodic identity recheck can end the wait before the 60s budget.
reset_fixture
mkdir "$TMP_ROOT/presentation.lock"
printf '2\n' > "$FIXTURE_DIR/hold-count-presentation.lock"
printf '#!/usr/bin/env bash\nprintf %%s\\n %s/other-presentation.lock > %s/next-lock-path\n' "$TMP_ROOT" "$FIXTURE_DIR" > "$FIXTURE_DIR/on-wait-release-presentation.lock"
out=$(with_fake_wait fm_herdr_session_cleanup 2>&1)
rm -rf "$TMP_ROOT/presentation.lock"
assert_identity_skip "a lock path that changed while waiting"
assert_equals 9 "$(sleep_count)" "a lock path that changed while waiting was polled past its recheck"
reset_fixture
mkdir "$TMP_ROOT/presentation.lock"
printf '2\n' > "$FIXTURE_DIR/hold-count-presentation.lock"
printf '#!/usr/bin/env bash\n: > %s/lock-path-missing\n' "$FIXTURE_DIR" > "$FIXTURE_DIR/on-wait-release-presentation.lock"
out=$(with_fake_wait fm_herdr_session_cleanup 2>&1)
rm -rf "$TMP_ROOT/presentation.lock"
assert_identity_skip "a lock path that vanished while waiting"
assert_equals 9 "$(sleep_count)" "a lock path that vanished while waiting was polled past its recheck"
pass "a presentation lock path that vanishes or changes while waiting ends the wait"

reset_fixture
printf '%s/missing-parent/presentation.lock\n' "$TMP_ROOT" > "$FIXTURE_DIR/next-lock-path"
out=$(with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_identity_skip "a lock whose parent directory is gone"
assert_equals 1 "$(sleep_count)" "a lock whose parent is gone was waited on"
pass "a presentation lock whose parent directory is gone ends the wait at once"

reset_fixture
: > "$FIXTURE_DIR/next-lock-path"
out=$(with_fake_wait fm_herdr_session_cleanup 2>&1)
assert_contains "$out" "task skipped because the shared presentation lock is unavailable" "an empty presentation lock path was not refused"
assert_equals 0 "$(sleep_count)" "an empty presentation lock path was waited on"
[ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] && [ ! -s "$CLOSE_LOG" ] || fail "an empty presentation lock path cleaned up"
[ ! -e "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "the task lock leaked after an empty presentation lock path"
pass "an empty presentation lock path is unavailable without waiting"

reset_fixture
out=$(with_fake_wait fm_herdr_session_cleanup 2>&1)
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "an uncontended presentation lock kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "an uncontended presentation lock did not close once"
[ ! -s "$FIXTURE_DIR/sleeps" ] || fail "an uncontended presentation lock waited"
pass "an uncontended presentation lock closes without waiting"

# shellcheck source=bin/fm-timing-lib.sh
. "$ROOT/bin/fm-timing-lib.sh"
reset_fixture
mkdir "$TMP_ROOT/presentation.lock"
started=$(fm_timing_now_ms)
out=$(FM_HERDR_PRESENTATION_LOCK_WAIT_BUDGET=3 fm_herdr_session_cleanup 2>&1)
elapsed=$(( $(fm_timing_now_ms) - started ))
assert_contains "$out" "task skipped because the shared presentation lock is busy" "the real-clock wait did not skip a busy lock"
[ "$elapsed" -ge 300 ] && [ "$elapsed" -lt 2000 ] || fail "a 300ms real-clock budget took ${elapsed}ms"
[ ! -e "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "the task lock leaked after the real-clock wait"
rm -rf "$TMP_ROOT/presentation.lock"
pass "the native clock ends a busy wait at its budget"

INTEGRATION_ROOT="$TMP_ROOT/bootstrap-integration"
mkdir -p "$INTEGRATION_ROOT/home/state" "$INTEGRATION_ROOT/home/data" "$INTEGRATION_ROOT/home/config"
cp -R "$ROOT/bin" "$INTEGRATION_ROOT/bin"
TRACE="$INTEGRATION_ROOT/cleanup.trace"
cat > "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_HOME:?}" >> "${FM_HERDR_CLEANUP_TRACE:?}"
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh"
printf '%s\n' manual > "$INTEGRATION_ROOT/home/config/backlog-backend"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "detect-only bootstrap ran stale projection cleanup"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "standalone bootstrap ran lock-owned stale projection cleanup"
pass "standalone bootstrap cannot run lock-owned stale projection cleanup"

cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'lock acquired'
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "lock-owning session start failed"
[ "$(cat "$TRACE")" = "$INTEGRATION_ROOT/home" ] \
  || fail "lock-owning session start did not run cleanup for its exact home"

: > "$TRACE"
cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'error: another live firstmate session holds the lock' >&2
exit 1
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "read-only session start failed"
[ ! -s "$TRACE" ] || fail "read-only session start ran stale projection cleanup"
pass "session start runs cleanup only after acquiring its home lock"

printf 'all fm-herdr-session-cleanup tests passed\n'
