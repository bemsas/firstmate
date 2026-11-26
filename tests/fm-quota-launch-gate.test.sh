#!/usr/bin/env bash
# Behavior tests for the launch quota gate (bin/fm-quota-launch-lib.sh).
#
# Every case drives a real entry point - fm-spawn.sh, fm-control.sh relaunch,
# or fm-dispatch-resolve.sh - against synthetic logins. The stub quota-axi
# answers from the selected login root's own quota.json, so a case can only get
# another login's reading if the launch selected the wrong login. Each stub
# reading carries an account identity that no output or log may repeat. No case
# reads a real login, a real quota, or the network.
# shellcheck disable=SC2030,SC2031 # The watcher tick sets PATH in its own subshell only.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-launch-gate)
RELAUNCH_ID="quota-rl-$$"
quota_gate_cleanup() {
  fm_test_remove_tree "/tmp/fm-$RELAUNCH_ID"
  fm_test_cleanup
}
trap quota_gate_cleanup EXIT
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK \
  CLAUDE_CODE_USE_VERTEX OPENAI_API_KEY CODEX_API_KEY CODEX_HOME PI_CODING_AGENT_DIR \
  QUOTA_AXI_MAX_AGE QUOTA_AXI_SNAPSHOT
SECRET=private-person@example.invalid

# make_quota_stub <fakebin> <case-dir>
make_quota_stub() {
  cat > "$1/quota-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' --provider codex '*) root=\${CODEX_HOME:-\$HOME/.codex} ;;
  *' --provider claude '*) root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude} ;;
  *) root=\${PI_CODING_AGENT_DIR:-\$HOME} ;;
esac
printf 'root=%s max_age=%s snapshot=%s args=%s\n' "\$root" "\${QUOTA_AXI_MAX_AGE-unset}" \
  "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$2/quota-calls'
printf 'login $SECRET\n' >&2
[ ! -e "\$root/slow" ] || exec /bin/sleep 30
cat "\$root/quota.json" 2>/dev/null || exit 1
SH
  chmod +x "$1/quota-axi"
}

# reading <provider> <state> <scope> <remaining> <runway> [accountKey]
reading() {
  local key=''
  [ -z "${6:-}" ] || key="\"accountKey\": \"$6\","
  printf '{"provider": "%s", %s "account": {"email": "%s"}, "state": {"status": "%s"},
    "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "%s", "status": "known", "effectivePercentRemaining": %s,
       "runway": {"status": "%s"}, "selection": {"spendPriority": 0.5}}]}}' \
    "$1" "$key" "$SECRET" "$2" "$3" "$4" "$5"
}

# login <root> <schema> <reading>...: a signed-in login root holding that quota.
login() {
  local root=$1 schema=$2 rows
  shift 2
  rows=$(printf '%s,' "$@")
  mkdir -p "$root"
  printf '{}\n' > "$root/.credentials.json"
  printf '{"schemaVersion": %s, "providers": [%s]}\n' "$schema" "${rows%,}" > "$root/quota.json"
}
claude_login() {  # <root> <remaining> [runway] [scope] [state]
  login "$1" 5 "$(reading claude "${5:-fresh}" "${4:-all_models}" "$2" "${3:-through_reset}")"
}

new_case() {  # <name> <harness>
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/claude"
  chmod +x "$FAKEBIN/claude"
  make_quota_stub "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : > "$CASE/quota-calls"
}

spawn_ship() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

assert_private() {  # <output>
  assert_not_contains "$1" "$SECRET" "launch output must not repeat quota-axi output or an account identity"
  assert_no_grep "$SECRET" "$HOME_DIR/state/quota-launch.log" "the gate log must not hold an account identity"
  assert_no_grep "$CASE/" "$HOME_DIR/state/quota-launch.log" "the gate log must not hold a login path"
}

expect_launch() {  # <id> <rc> <out>
  expect_code 0 "$2" "$1 should launch: $3"
  assert_present "$HOME_DIR/state/$1.meta" "$1 should publish its task record"
  assert_private "$3"
}
expect_refusal() {  # <id> <rc> <out>
  expect_code 1 "$2" "$1 should be refused: $3"
  assert_contains "$3" "shows no allowance left" "$1 should be refused by the quota gate"
  assert_absent "$HOME_DIR/state/$1.meta" "a quota refusal must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a quota refusal must not launch a worker"
  assert_private "$3"
}

test_pinned_login_swap_never_inherits_a_stop() {
  local out rc id=quota-swap
  new_case swap claude
  claude_login "$CASE/spent" 0 exhausted_now
  claude_login "$CASE/open" 60
  # The ambient login is exhausted throughout: only the pin may be read.
  claude_login "$HOME_DIR/user-home/.claude" 0 exhausted_now
  printf '%s\n' "$CASE/spent" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_refusal "$id" "$rc" "$out"
  printf '%s\n' "$CASE/open" > "$HOME_DIR/config/claude-account"
  : > "$CASE/quota-calls"
  out=$(spawn_ship "$id"); rc=$?
  expect_launch "$id" "$rc" "$out"
  assert_not_contains "$out" "quota-gate:" "a fresh reading with headroom should be silent"
  assert_grep "root=$CASE/open " "$CASE/quota-calls" "the swapped login should be the one read"
  assert_no_grep "root=$CASE/spent " "$CASE/quota-calls" "the previous login must not be read again"
  assert_grep "args=--provider claude --profile-only --json --no-credential-refresh" "$CASE/quota-calls" \
    "a Claude reading must be isolated to the selected root"
  assert_grep "task=$id harness=claude provider=claude quota=ok" "$HOME_DIR/state/quota-launch.log" \
    "the allowed launch should be logged"
  pass "a login swap is judged on the new login's own fresh reading"
}

test_unpinned_launch_reads_the_ambient_login_without_reuse() {
  local out rc
  new_case ambient claude
  claude_login "$CASE/spent" 0
  claude_login "$HOME_DIR/user-home/.claude" 40
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE/spent" spawn_ship quota-ambient-spent); rc=$?
  expect_refusal quota-ambient-spent "$rc" "$out"
  out=$(QUOTA_AXI_MAX_AGE=1h QUOTA_AXI_SNAPSHOT="$CASE/fixture" spawn_ship quota-ambient-open); rc=$?
  expect_launch quota-ambient-open "$rc" "$out"
  assert_grep "root=$HOME_DIR/user-home/.claude max_age=unset snapshot=unset" "$CASE/quota-calls" \
    "the default login should be read fresh, with no reuse or fixture"
  : > "$CASE/quota-calls"
  out=$(ANTHROPIC_API_KEY=synthetic-key FM_TEST_CLAUDE_CONFIG_DIR="$CASE/spent" spawn_ship quota-ambient-key); rc=$?
  expect_launch quota-ambient-key "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "an outranking credential cannot be matched"
  assert_not_contains "$out" "synthetic-key" "a credential must never be printed"
  [ ! -s "$CASE/quota-calls" ] || fail "an unmatched login must not borrow another login's reading"
  out=$(spawn_ship quota-raw --harness "claude --print raw"); rc=$?
  expect_launch quota-raw "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "a raw command's login cannot be matched"
  pass "an unpinned launch reads the ambient login fresh and never borrows one it cannot match"
}

test_only_scopes_that_bound_the_model_stop_it() {
  local out rc
  new_case scopes claude
  claude_login "$HOME_DIR/user-home/.claude" 0 through_reset model:fable
  out=$(spawn_ship quota-bound --model fable); rc=$?
  expect_refusal quota-bound "$rc" "$out"
  assert_contains "$out" "quota=exhausted scope=model:fable" "the refusal should name the bounding scope"
  out=$(spawn_ship quota-unbound --model sonnet); rc=$?
  expect_launch quota-unbound "$rc" "$out"
  assert_contains "$out" "quota=stale reason=quota-unknown" "no applicable scope is unknown, not exhausted"
  pass "only a scope bounding the launch model can stop it"
}

test_missing_or_non_current_readings_launch_as_stale() {
  local out rc root started elapsed name want n=0
  new_case stale claude
  root="$HOME_DIR/user-home/.claude"
  for name in missing invalid not-fresh timeout; do
    n=$((n + 1))
    rm -rf "$root"
    mkdir -p "$root"
    case "$name" in
      missing) want=read-failed ;;
      invalid) printf 'login %s\n' "$SECRET" > "$root/quota.json"; want=read-failed ;;
      not-fresh) claude_login "$root" 0 exhausted_now all_models stale; want=reading-not-fresh ;;
      timeout) claude_login "$root" 0 exhausted_now; : > "$root/slow"; want=read-timeout ;;
    esac
    started=$SECONDS
    out=$(FM_QUOTA_LAUNCH_SECONDS=1 spawn_ship "quota-stale-$n"); rc=$?
    elapsed=$((SECONDS - started))
    expect_launch "quota-stale-$n" "$rc" "$out"
    assert_contains "$out" "quota=stale reason=$want" "a $name reading should be flagged stale"
    assert_grep "task=quota-stale-$n harness=claude provider=claude quota=stale reason=$want" \
      "$HOME_DIR/state/quota-launch.log" "a $name reading should be logged"
    [ "$elapsed" -lt 25 ] || fail "a $name reading must be time-bounded, took ${elapsed}s"
  done
  pass "missing, invalid, non-fresh, and timed-out readings launch and are logged as stale"
}

test_codex_and_pi_read_their_own_login() {
  local out rc
  new_case codex codex
  login "$CASE/codex-spent" 5 "$(reading codex fresh all_models 0 exhausted_now)"
  login "$HOME_DIR/user-home/.codex" 5 "$(reading codex fresh all_models 0 exhausted_now)"
  out=$(spawn_ship quota-codex-spent); rc=$?
  expect_refusal quota-codex-spent "$rc" "$out"
  out=$(CODEX_HOME="$CASE/codex-spent" spawn_ship quota-codex-elsewhere); rc=$?
  expect_launch quota-codex-elsewhere "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "a root the launch does not carry is unmatched"
  login "$HOME_DIR/user-home/.codex" 5 "$(reading codex fresh all_models 30 through_reset)"
  out=$(spawn_ship quota-codex-open); rc=$?
  expect_launch quota-codex-open "$rc" "$out"
  login "$HOME_DIR/user-home" 6 \
    "$(reading codex fresh all_models 0 exhausted_now lane-spent)" \
    "$(reading codex fresh all_models 50 through_reset lane-open)"
  out=$(spawn_ship quota-pi-spent --harness pi --model lane-spent/gpt-6); rc=$?
  expect_refusal quota-pi-spent "$rc" "$out"
  out=$(spawn_ship quota-pi-open --harness pi --model lane-open/gpt-6); rc=$?
  expect_launch quota-pi-open "$rc" "$out"
  out=$(spawn_ship quota-pi-other --harness pi --model lane-absent/gpt-6); rc=$?
  expect_launch quota-pi-other "$rc" "$out"
  assert_contains "$out" "quota=stale reason=no-matching-row" "a lane with no row of its own is unmatched"
  pass "codex and Pi launches are judged only on their own login row"
}

test_secondmate_launch_reads_its_own_pin() {
  local out rc id=quota-mate sm
  new_case mate claude
  sm="$CASE/mate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$HOME_DIR/config/secondmate-accounts/$id"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  claude_login "$CASE/spent" 0
  claude_login "$CASE/open" 70
  printf '%s\n' "$CASE/open" > "$HOME_DIR/config/claude-account"
  printf '%s\n' "$CASE/spent" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_refusal "$id" "$rc" "$out"
  printf '%s\n' "$CASE/open" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_launch "$id" "$rc" "$out"
  pass "a secondmate launch is judged on the secondmate's own pinned login"
}

# A tmux stand-in for one recorded endpoint: the harness's exit command stops
# the agent and a launch literal starts it again.
make_relaunch_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    for payload in "$@"; do :; done
    case "$payload" in ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;; esac
    printf '%s\n' "$payload" >> "$D/sent"
    case "$payload" in
      /exit) printf 'zsh' > "$D/command" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) printf 'claude' > "$D/command" ;;
    esac ;;
  display-message)
    case "$*" in
      *cursor_y*) printf '1\n' ;;
      *pane_current_command*) cat "$D/command"; printf '\n' ;;
      *pane_current_path*) cat "$D/cwd"; printf '\n' ;;
      *) printf 'fakepane\n' ;;
    esac ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) cat "$D/windows" ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/sleep"
  chmod +x "$1/sleep"
}

run_relaunch() {  # <note>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$CASE/pane" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$RELAUNCH_ID" relaunch --note "$1" 2>&1
}

test_relaunch_rechecks_the_current_login() {
  local out rc id=$RELAUNCH_ID
  new_case relaunch claude
  make_relaunch_tmux "$FAKEBIN"
  mkdir -p "$CASE/pane" "$HOME_DIR/data/$id" "$HOME_DIR/user-home"
  printf 'claude' > "$CASE/pane/command"
  printf 'fm-%s\n' "$id" > "$CASE/pane/windows"
  printf '%s' "$WT" > "$CASE/pane/cwd"
  : > "$CASE/pane/sent"
  printf "# Task\n## Captain's intent\nRelaunch.\n\n## Firstmate spec\nKeep the task.\n" \
    > "$HOME_DIR/data/$id/brief.md"
  printf '%s\n' "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$WT" "project=$PROJ" \
    harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=/tmp/fm-$id" model=default effort=default \
    > "$HOME_DIR/state/$id.meta"
  cp "$HOME_DIR/state/$id.meta" "$CASE/meta-before"
  claude_login "$CASE/spent" 0 exhausted_now
  claude_login "$CASE/open" 55
  printf '%s\n' "$CASE/spent" > "$HOME_DIR/config/claude-account"
  # An earlier rate-limit episode the watcher parked must not decide anything.
  printf 'quota - \n' > "$HOME_DIR/state/.broken-session-park-$id"
  out=$(run_relaunch "login spent"); rc=$?
  expect_code 1 "$rc" "a relaunch onto an exhausted login should be refused: $out"
  assert_contains "$out" "shows no allowance left" "the quota gate should explain the refusal"
  [ "$(cat "$CASE/pane/command")" = claude ] || fail "the running agent must not be stopped"
  [ ! -s "$CASE/pane/sent" ] || fail "no lifecycle input may be sent: $(cat "$CASE/pane/sent")"
  cmp -s "$CASE/meta-before" "$HOME_DIR/state/$id.meta" || fail "the task record must be unchanged"
  assert_private "$out"
  printf '%s\n' "$CASE/open" > "$HOME_DIR/config/claude-account"
  out=$(run_relaunch "login swapped"); rc=$?
  expect_code 0 "$rc" "a relaunch after a login swap should succeed: $out"
  assert_contains "$(cat "$CASE/pane/sent")" "CLAUDE_CONFIG_DIR='$CASE/open'" \
    "the replacement should launch on the new login"
  assert_private "$out"
  rm "$CASE/open/quota.json"
  out=$(run_relaunch "reading missing"); rc=$?
  expect_code 0 "$rc" "a relaunch with a missing reading should succeed: $out"
  assert_grep "task=$id harness=claude provider=claude quota=stale reason=read-failed" \
    "$HOME_DIR/state/quota-launch.log" "the stale relaunch should be logged"
  pass "a relaunch rechecks the current login before stopping the agent and reuses no recorded stop"
}

# Dispatch intake: stub curl picks the only rule, and each candidate line shows
# whose figures the resolver judged.
resolve() {  # [brief]
  FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" PATH="${RESOLVE_PATH:-$FAKEBIN:$PATH}" \
    FM_DISPATCH_PROVIDER=typesafe TYPESAFE_API_KEY=synthetic-dispatch-key \
    "$ROOT/bin/fm-dispatch-resolve.sh" "${1:-$CASE/brief.md}" 2>&1
}

make_intake() {
  printf '# Task\nFix a pager bug.\n' > "$CASE/brief.md"
  printf '{"rules":[{"when":"A bug fix.","use":{"harness":"claude","model":"sonnet"}}]}\n' \
    > "$HOME_DIR/config/crew-dispatch.json"
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ $# -gt 0 ]; do [ "$1" != -o ] || { out=$2; shift; }; shift; done
cat >/dev/null
printf '{"model":"m","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}}}' > "$out"
printf 200
SH
  chmod +x "$FAKEBIN/curl"
}

test_dispatch_intake_reads_the_pinned_login() {
  local out
  new_case resolve claude
  make_intake
  # The stub answers an unscoped read from HOME: the ambient login, exhausted.
  login "$HOME_DIR/user-home" 5 "$(reading claude fresh all_models 0 exhausted_now)"
  claude_login "$CASE/open" 64
  printf '%s\n' "$CASE/open" > "$HOME_DIR/config/claude-account"
  out=$(QUOTA_AXI_SNAPSHOT="$CASE/fixture" QUOTA_AXI_MAX_AGE=1h resolve)
  assert_contains "$out" "status: clear" "the pinned login's headroom should resolve: $out"
  assert_no_grep "snapshot=$CASE/fixture" "$CASE/quota-calls" "no intake read may be answered by a fixture"
  assert_no_grep "max_age=1h" "$CASE/quota-calls" "no intake read may reuse an earlier reading"
  assert_contains "$out" "remaining=64%" "the candidate should carry the pinned login's figure"
  assert_not_contains "$out" "$SECRET" "intake must not repeat an account identity"
  printf '%s\n' "$CASE/open" "$CASE/other" > "$HOME_DIR/config/claude-accounts"
  rm "$HOME_DIR/config/claude-account"
  out=$(resolve)
  assert_contains "$out" "provider claude not in the quota snapshot" \
    "an undecided account must not borrow the ambient login: $out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "the unmeasured provider should be flagged stale"
  pass "dispatch intake judges the login a launch would spend"
}

test_unusable_intake_read_falls_through_to_an_ordinary_launch() {
  local out rc name id n=0 root dir clean
  new_case intake claude
  make_intake
  root="$HOME_DIR/user-home"
  # Every PATH directory holding a real quota-axi is left out for the missing case.
  clean=$FAKEBIN
  while IFS= read -r -d: dir; do
    [ -x "$dir/quota-axi" ] || clean="$clean:$dir"
  done <<< "$PATH:"
  for name in missing failed invalid timeout; do
    n=$((n + 1))
    id="quota-intake-$n"
    rm -rf "$root/quota.json" "$root/slow" "$root/.claude"
    make_quota_stub "$FAKEBIN" "$CASE"
    case "$name" in
      missing) rm "$FAKEBIN/quota-axi" ;;
      invalid) printf 'login %s\n' "$SECRET" > "$root/quota.json" ;;
      timeout) : > "$root/slow" ;;
    esac
    fm_test_spawn_brief "$HOME_DIR" "$id"
    if [ "$name" = missing ]; then
      out=$(RESOLVE_PATH="$clean" resolve "$HOME_DIR/data/$id/brief.md")
    else
      out=$(FM_QUOTA_LAUNCH_SECONDS=1 resolve "$HOME_DIR/data/$id/brief.md")
    fi
    assert_contains "$out" "status: error" "a $name read should leave intake non-clear: $out"
    assert_contains "$out" "quota: stale" "a $name read should be flagged stale"
    assert_not_contains "$out" "$SECRET" "a $name read must not leak an identity"
    assert_grep "task=$id harness=- provider=- quota=stale" "$HOME_DIR/state/quota-launch.log" \
      "a $name intake read should be logged"
    assert_grep '"status":"error"' "$HOME_DIR/data/$id/dispatch-resolution.json" \
      "a $name read should be recorded as the ordinary error outcome"
    make_quota_stub "$FAKEBIN" "$CASE"
    out=$(FM_QUOTA_LAUNCH_SECONDS=1 spawn_ship "$id" --harness claude --model sonnet); rc=$?
    expect_launch "$id" "$rc" "$out"
    assert_contains "$out" "quota=stale" "the launch after a $name read should carry the stale marker"
  done
  pass "a missing or unusable intake read falls through to a launch flagged stale"
}

# One watcher tick over a task whose idle pane shows a rate-limit banner.
watch_tick() {  # <recheck-seconds>
  rm -f "$HOME_DIR/state/.broken-session-tick"
  (
    export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" HOME="$HOME_DIR/user-home" \
      PATH="$FAKEBIN:$PATH" FM_BROKEN_QUOTA_RECHECK_SECS="$1" CLAUDE_CONFIG_DIR=
    # shellcheck source=bin/fm-watch.sh
    . "$ROOT/bin/fm-watch.sh"
    wake() { printf 'WAKE %s\n' "$1"; }
    broken_session_tick
  ) 2>&1
}

test_old_rate_limit_episode_never_blocks_recovery() {
  local out meta
  new_case watch claude
  meta="$HOME_DIR/state/ship1.meta"
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  capture-pane) cat '$CASE/pane.txt' ;;
  display-message) case "\$*" in *pane_current_command*) printf 'claude\n' ;; esac ;;
  list-windows) printf 'win\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"
  printf 'API Error: 429 rate_limit_error\n' > "$CASE/pane.txt"
  printf 'window=ses:win\nkind=ship\nharness=claude\nbackend=tmux\nspawn_gen=one\n' > "$meta"
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" ship1 \
    --state idle --source claude-hook --event stop-failure >/dev/null || fail "could not arm busy state"
  claude_login "$CASE/spent" 0 exhausted_now
  claude_login "$CASE/open" 55
  printf '%s\n' "$CASE/spent" > "$HOME_DIR/config/claude-account"
  out=$(watch_tick 0)
  assert_contains "$out" "its current login has no allowance left" "a current refusal should be reported: $out"
  out=$(watch_tick 0)
  assert_not_contains "$out" "WAKE" "an unchanged refusal should not be repeated: $out"
  printf '%s\n' "$CASE/open" > "$HOME_DIR/config/claude-account"
  out=$(watch_tick 3600)
  assert_not_contains "$out" "WAKE" "the login is only reread on its cadence: $out"
  out=$(watch_tick 0)
  assert_contains "$out" "current login has headroom" "a login change should reopen recovery: $out"
  assert_private "$out"
  out=$(watch_tick 0)
  assert_not_contains "$out" "WAKE" "headroom is reported once per launch: $out"
  sed -i.bak 's/^spawn_gen=one$/spawn_gen=two/' "$meta"
  rm "$CASE/open/quota.json"
  out=$(watch_tick 3600)
  assert_contains "$out" "quota=stale for its current login" "a new launch's limit is a new episode: $out"
  assert_absent "$HOME_DIR/state/.broken-session-relaunch-ship1" \
    "a visible provider limit must never be relaunched automatically"
  printf 'API Error: 401 Unauthorized\n' > "$CASE/pane.txt"
  : > "$CASE/quota-calls"
  out=$(watch_tick 0)
  assert_contains "$out" "needs a credential or login" "an authentication refusal is unchanged: $out"
  [ ! -s "$CASE/quota-calls" ] || fail "an authentication refusal reads no quota"
  pass "a parked rate limit is rechecked against the current login and never auto-relaunched"
}

test_unusable_intake_read_falls_through_to_an_ordinary_launch
test_old_rate_limit_episode_never_blocks_recovery
test_pinned_login_swap_never_inherits_a_stop
test_unpinned_launch_reads_the_ambient_login_without_reuse
test_only_scopes_that_bound_the_model_stop_it
test_missing_or_non_current_readings_launch_as_stale
test_codex_and_pi_read_their_own_login
test_secondmate_launch_reads_its_own_pin
test_relaunch_rechecks_the_current_login
test_dispatch_intake_reads_the_pinned_login

echo "# all fm-quota-launch-gate tests passed"
