#!/usr/bin/env bash
# Behavior tests for the launch quota gate (bin/fm-quota-launch-lib.sh).
#
# Every case drives a real entry point - fm-spawn.sh, fm-dispatch-resolve.sh,
# or fm-claude-account-quota.sh - against synthetic logins. The stub quota-axi
# answers from the selected login root's own quota.json, so a case can only get
# another login's reading if the launch selected the wrong login. Each stub
# reading carries an account identity that no output or log may repeat. No case
# reads a real login, a real quota, or the network.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-launch-gate)
quota_gate_cleanup() { fm_test_cleanup; }
trap quota_gate_cleanup EXIT
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK \
  CLAUDE_CODE_USE_VERTEX OPENAI_API_KEY CODEX_API_KEY CODEX_HOME PI_CODING_AGENT_DIR \
  QUOTA_AXI_MAX_AGE QUOTA_AXI_SNAPSHOT
SECRET=private-person@example.invalid

# make_quota_stub <fakebin> <case-dir>
# Answers from the selected root's quota.json in the installed renderer's two
# tiers: only --full keeps a live state.refreshedAt, windows' startsAt, and the
# account identity; lean --json drops them unless the reading is reused. A
# root holding exit-1 prints its snapshot and then exits 1, as quota-axi does
# when it cannot measure a provider; one holding lean-only ignores --full.
make_quota_stub() {
  cat > "$1/quota-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' --provider claude '*) root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude} ;;
  *) root=\${PI_CODING_AGENT_DIR:-\$HOME} ;;
esac
printf 'root=%s max_age=%s snapshot=%s args=%s\n' "\$root" "\${QUOTA_AXI_MAX_AGE-unset}" \
  "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$2/quota-calls'
printf 'login $SECRET\n' >&2
[ ! -e "\$root/slow" ] || exec /bin/sleep 30
[ -f "\$root/quota.json" ] || exit 1
case " \$* " in
  *' --full '*) [ ! -e "\$root/lean-only" ] && full=1 || full= ;;
  *) full= ;;
esac
if [ -n "\$full" ]; then
  cat "\$root/quota.json"
else
  jq -c '.providers |= map(del(.account, .attempts) |
      if (.state | type) == "object" and .state.reused != true then .state |= del(.refreshedAt) else . end |
      if (.windows | type) == "array" then .windows |= map(del(.startsAt)) else . end)' \
    "\$root/quota.json" 2>/dev/null || cat "\$root/quota.json"
fi
[ ! -e "\$root/exit-1" ] || exit 1
SH
  chmod +x "$1/quota-axi"
}

# reading <provider> <state> <scope> <remaining> <runway> [accountKey] [refreshedAt] [stale-flag]
# An omitted refresh time is the current instant. "-" leaves the field out.
# "true" as the last argument sets state.stale.
reading() {
  local provider=$1 status=$2 scope=$3 remaining=$4 runway=$5
  local key=${6-} refresh_arg=${7-} stale_flag=${8-}
  local key_json='' refresh_json='' stale_json='' now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -z "$key" ] || key_json="\"accountKey\": \"$key\", "
  case "$refresh_arg" in
    -) ;;
    '') refresh_json=", \"refreshedAt\": \"$now\"" ;;
    *) refresh_json=", \"refreshedAt\": \"$refresh_arg\"" ;;
  esac
  [ "$stale_flag" = true ] && stale_json=', "stale": true'
  printf '{"provider": "%s", %s"account": {"email": "%s"}, "state": {"status": "%s"%s%s},
    "quotaSemantics": {"status": "known", "effectiveAvailability": [
      {"scope": "%s", "status": "known", "effectivePercentRemaining": %s,
       "runway": {"status": "%s"}, "selection": {"spendPriority": 0.5}}]}}' \
    "$provider" "$key_json" "$SECRET" "$status" "$stale_json" "$refresh_json" "$scope" "$remaining" "$runway"
}

# login <root> <schema> <reading>...: a signed-in login root holding that quota.
# generatedAt is the aggregate clock and is always "now", never a provider's refresh.
login() {
  local root=$1 schema=$2 rows generated
  shift 2
  rows=$(printf '%s,' "$@")
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$root"
  printf '{}\n' > "$root/.credentials.json"
  printf '{"generatedAt": "%s", "schemaVersion": %s, "providers": [%s]}\n' \
    "$generated" "$schema" "${rows%,}" > "$root/quota.json"
}
claude_login() {  # <root> <remaining> [runway] [scope] [state]
  login "$1" 5 "$(reading claude "${5:-fresh}" "${4:-all_models}" "$2" "${3:-through_reset}")"
}

# shape_login <root> <mode> <remaining> <runway>
# mode is now, missing, old, unbound, or stale-flag. Future resets keep the
# weekly window open so only the provider refresh time can make the row stale.
shape_login() {
  local root=$1 mode=$2 remaining=$3 runway=$4 refresh='-' flag=''
  case "$mode" in
    now|stale-flag) refresh=$(date -u +%Y-%m-%dT%H:%M:%SZ) ;;
    old) refresh=$(date -u -d '16 days ago' +%Y-%m-%dT%H:%M:%SZ) ;;
    unbound) refresh='2026-11-11T00:36:00' ;;
    missing) refresh='-' ;;
    *) fail "unknown refresh mode $mode" ;;
  esac
  [ "$mode" = stale-flag ] && flag=true
  login "$root" 5 "$(reading claude fresh all_models "$remaining" "$runway" '' "$refresh" "$flag")"
  jq --arg reset '2999-01-01T00:00:00.000Z' \
    '.providers[0].windows = [
      {id: "credits", percentRemaining: 86, resetsAt: $reset},
      {id: "product:grok_build", percentRemaining: 94, resetsAt: $reset}
    ]' "$root/quota.json" > "$root/quota.json.tmp" || fail "could not stamp reset windows"
  mv "$root/quota.json.tmp" "$root/quota.json"
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
  assert_grep "args=--provider claude --profile-only --full --json --no-credential-refresh" "$CASE/quota-calls" \
    "a Claude reading must be isolated to the selected root, in the tier that keeps its refresh time"
  assert_grep "task=$id harness=claude provider=claude quota=ok" "$HOME_DIR/state/quota-launch.log" \
    "the allowed launch should be logged"
  pass "a login swap is judged on the new login's own fresh reading"
}

test_a_destination_selected_login_is_never_refused_by_another() {
  local out rc
  new_case ambient claude
  claude_login "$CASE/spent" 0 exhausted_now
  claude_login "$HOME_DIR/user-home/.claude" 0 exhausted_now
  out=$(spawn_ship quota-ambient-default); rc=$?
  expect_launch quota-ambient-default "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "an unpinned launch cannot be matched"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE/spent" spawn_ship quota-ambient-root); rc=$?
  expect_launch quota-ambient-root "$rc" "$out"
  [ ! -s "$CASE/quota-calls" ] || fail "an unmatched login must not borrow another login's reading"
  out=$(spawn_ship quota-raw --harness "claude --print raw"); rc=$?
  expect_launch quota-raw "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "a raw command's login cannot be matched"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  out=$(QUOTA_AXI_MAX_AGE=1h QUOTA_AXI_SNAPSHOT="$CASE/fixture" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/spent" \
    spawn_ship quota-ordinary); rc=$?
  expect_refusal quota-ordinary "$rc" "$out"
  assert_grep "root=$HOME_DIR/user-home/.claude max_age=unset snapshot=unset" "$CASE/quota-calls" \
    "an ordinary pin should read the default login fresh, with no reuse or fixture"
  pass "only a login Firstmate selects can refuse a launch"
}

test_a_passed_reset_is_stale_evidence() {
  local out rc root when n=0
  new_case reset claude
  root="$CASE/pinned"
  printf '%s\n' "$root" > "$HOME_DIR/config/claude-account"
  for when in '"windows": [{"id": "w", "resetsAt": "2001-01-01T00:00:00Z"}]' \
    '"windows": [{"id": "w", "resetsAt": "2001-01-01T00:00:00.250+02:00"}]' \
    '"windows": [{"id": "w", "resetsAt": "soon"}]'; do
    n=$((n + 1))
    claude_login "$root" 0 exhausted_now
    sed -i.bak "s|\"provider\": \"claude\",|\"provider\": \"claude\", $when,|" "$root/quota.json"
    out=$(spawn_ship "quota-reset-$n"); rc=$?
    expect_launch "quota-reset-$n" "$rc" "$out"
    assert_contains "$out" "quota=stale reason=window-not-current" "reset evidence #$n should be stale"
  done
  claude_login "$root" 0 exhausted_now
  sed -i.bak 's|"provider": "claude",|"provider": "claude", "windows": [{"id": "w", "resetsAt": "2999-01-01T00:00:00.5Z"}],|' \
    "$root/quota.json"
  out=$(spawn_ship quota-reset-ahead); rc=$?
  expect_refusal quota-reset-ahead "$rc" "$out"
  pass "a reading past its reset launches as stale, and one before it still refuses"
}

test_only_scopes_that_bound_the_model_stop_it() {
  local out rc
  new_case scopes claude
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
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
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
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

test_provider_refresh_time_not_the_fresh_label() {
  local out rc root mode
  new_case refresh claude
  root="$CASE/pinned"
  printf '%s\n' "$root" > "$HOME_DIR/config/claude-account"
  for mode in missing old unbound stale-flag; do
    shape_login "$root" "$mode" 0 exhausted_now
    out=$(spawn_ship "quota-refresh-$mode"); rc=$?
    expect_launch "quota-refresh-$mode" "$rc" "$out"
    assert_contains "$out" "quota=stale reason=reading-not-fresh" \
      "a $mode provider row must not be compared against the cap"
  done
  shape_login "$root" now 0 exhausted_now
  out=$(spawn_ship quota-refresh-now); rc=$?
  expect_refusal quota-refresh-now "$rc" "$out"
  shape_login "$root" now 86 through_reset
  out=$(spawn_ship quota-refresh-open); rc=$?
  expect_launch quota-refresh-open "$rc" "$out"
  assert_not_contains "$out" "quota-gate:" "comparable headroom above the cap should be silent"
  assert_grep "task=quota-refresh-open harness=claude provider=claude quota=ok" \
    "$HOME_DIR/state/quota-launch.log" "comparable headroom should be logged as ok"
  pass "only a recent timezone-bound fresh reading can refuse, and headroom above the cap launches"
}

# keyed <accountKey or ""> <accountKeys,comma,separated> <remaining> <runway>
# One codex row as quota-axi publishes it: accountKeys on every row, and
# accountKey only when the report expanded to schema 6.
keyed() {
  reading codex fresh all_models "$3" "$4" "$1" | jq -c --arg keys "$2" '.accountKeys = ($keys | split(","))'
}

test_codex_is_unmatched_and_pi_binds_its_lane_by_account_keys() {
  local out rc calls
  new_case codex codex
  login "$HOME_DIR/user-home/.codex" 5 "$(reading codex fresh all_models 0 exhausted_now)"
  out=$(spawn_ship quota-codex); rc=$?
  expect_launch quota-codex "$rc" "$out"
  assert_contains "$out" "provider=codex quota=stale reason=unmatched-login" \
    "the terminal selects Codex's home, so it cannot be matched"
  cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>' ;;
  auth) printf '{"status":"ready"}\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/pi"
  login "$CASE/pi-root" 6 \
    "$(keyed openai-codex-spent openai-codex-spent 0 exhausted_now)" \
    "$(keyed openai-codex-open openai-codex-open 50 through_reset)" \
    "$(keyed codex-home codex-home,openai-codex-folded 0 exhausted_now)"
  login "$HOME_DIR/user-home" 6 "$(keyed openai-codex-open openai-codex-open 0 exhausted_now)"
  out=$(spawn_ship quota-pi-unpinned --harness pi --model openai-codex-open/gpt-6); rc=$?
  expect_launch quota-pi-unpinned "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "an unpinned Pi launch cannot be matched"
  printf '%s\nopenai-codex-spent openai-codex-open openai-codex-folded openai-codex-absent codex-native xai\n' \
    "$CASE/pi-root" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship quota-pi-native --harness pi --model codex-native/gpt-6); rc=$?
  expect_launch quota-pi-native "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "the terminal selects the native Codex home"
  : > "$CASE/quota-calls"
  out=$(spawn_ship quota-pi-spent --harness pi --model openai-codex-spent/gpt-6); rc=$?
  expect_refusal quota-pi-spent "$rc" "$out"
  assert_grep "root=$CASE/pi-root max_age=unset snapshot=unset args=--provider codex --full --json --no-credential-refresh" \
    "$CASE/quota-calls" "a pinned Pi lane is read under its own root, scoped to codex, in the full tier"
  out=$(spawn_ship quota-pi-open --harness pi --model openai-codex-open/gpt-6); rc=$?
  expect_launch quota-pi-open "$rc" "$out"
  assert_not_contains "$out" "quota-gate:" "the pinned lane's own headroom launches silently"
  out=$(spawn_ship quota-pi-folded --harness pi --model openai-codex-folded/gpt-6); rc=$?
  expect_refusal quota-pi-folded "$rc" "$out"
  out=$(spawn_ship quota-pi-other --harness pi --model openai-codex-absent/gpt-6); rc=$?
  expect_launch quota-pi-other "$rc" "$out"
  assert_contains "$out" "quota=stale reason=no-matching-row" "a lane with no row of its own is unmatched"
  calls=$(wc -l < "$CASE/quota-calls")
  out=$(spawn_ship quota-pi-xai --harness pi --model xai/grok-5); rc=$?
  expect_launch quota-pi-xai "$rc" "$out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "a Pi lane quota-axi does not key is unmatched"
  [ "$(wc -l < "$CASE/quota-calls")" = "$calls" ] || fail "an unkeyed Pi lane must not poll quota-axi"
  login "$CASE/pi-root" 5 "$(keyed '' openai-codex-spent 0 exhausted_now)"
  out=$(spawn_ship quota-pi-s5 --harness pi --model openai-codex-spent/gpt-6); rc=$?
  expect_refusal quota-pi-s5 "$rc" "$out"
  login "$CASE/pi-root" 5 "$(keyed '' codex-home 0 exhausted_now)"
  out=$(spawn_ship quota-pi-s5-native --harness pi --model openai-codex-spent/gpt-6); rc=$?
  expect_launch quota-pi-s5-native "$rc" "$out"
  assert_contains "$out" "quota=stale reason=no-matching-row" \
    "a schema-5 native Codex row must not bind to a Pi lane"
  pass "codex stays unmatched and a pinned Pi lane binds only the row whose accountKeys hold it"
}

test_invalid_account_config_still_refuses() {
  local out rc id=quota-badpin
  new_case badpin claude
  printf 'not-a-path\n' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a malformed pin should still refuse: $out"
  assert_contains "$out" "config/claude-account" "the refusal should name the pin"
  assert_contains "$out" "absolute path" "the refusal should stay the pin parser's own"
  assert_not_contains "$out" "shows no allowance left" "a bad pin is not a quota exhaustion"
  assert_not_contains "$out" "quota=stale" "a bad pin must not fall through the quota gate"
  assert_absent "$HOME_DIR/state/$id.meta" "a bad pin must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a bad pin must not launch a worker"
  [ ! -s "$CASE/quota-calls" ] || fail "a bad pin must not read quota"
  pass "an invalid account pin is still refused before the quota gate"
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

# Shapes printed by the installed quota-axi 0.1.56 renderer (quotaJsonReport)
# for one synthetic in-memory Claude reading, timestamps made placeholders.
# The full tier keeps state.refreshedAt, startsAt, and the account identity;
# the lean live tier drops all three.
RENDERED_FULL='{"generatedAt":"@NOW@","schemaVersion":5,"providers":[{"provider":"claude","accountKeys":["default"],"plan":"max","label":"Claude","source":"oauth","account":{"email":"@SECRET@"},"attempts":[{"source":"oauth","status":"ok"}],"windows":[{"id":"five_hour","label":"session","kind":"session","percentRemaining":100,"percentUsed":0,"startsAt":"@START5@","windowSeconds":18000,"resetsAt":"@RESET5@"},{"id":"seven_day","label":"week","kind":"weekly","percentRemaining":0,"percentUsed":100,"startsAt":"@START7@","windowSeconds":604800,"resetsAt":"@RESET7@"}],"state":{"status":"fresh","stale":false,"refreshedAt":"@NOW@","sourcesTried":["oauth"]},"quotaSemantics":{"status":"known","description":"d","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["seven_day"],"runway":{"status":"exhausted_now"},"selection":{"status":"known","spendPriority":-9}}]}}]}'
RENDERED_LEAN='{"generatedAt":"@NOW@","schemaVersion":5,"providers":[{"provider":"claude","accountKeys":["default"],"plan":"max","windows":[{"id":"five_hour","label":"session","kind":"session","percentRemaining":100,"resetsAt":"@RESET5@"},{"id":"seven_day","label":"week","kind":"weekly","percentRemaining":0,"resetsAt":"@RESET7@"}],"state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["seven_day"],"runway":{"status":"exhausted_now"},"selection":{"status":"known","spendPriority":-9}}]}}]}'

rendered() {  # <template> <root>
  mkdir -p "$2"
  printf '{}\n' > "$2/.credentials.json"
  printf '%s\n' "$1" | sed -e "s|@NOW@|$(date -u +%Y-%m-%dT%H:%M:%S.000Z)|g" \
    -e "s|@START5@|$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)|" \
    -e "s|@RESET5@|$(date -u -d '4 hours' +%Y-%m-%dT%H:%M:%S.000Z)|" \
    -e "s|@START7@|$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S.000Z)|" \
    -e "s|@RESET7@|$(date -u -d '5 days' +%Y-%m-%dT%H:%M:%S.000Z)|" \
    -e "s|@SECRET@|$SECRET|" > "$2/quota.json"
}

test_installed_renderer_tiers_full_compares_and_lean_is_stale() {
  local out rc root
  new_case tiers claude
  root="$CASE/pinned"
  printf '%s\n' "$root" > "$HOME_DIR/config/claude-account"
  rendered "$RENDERED_FULL" "$root"
  out=$(spawn_ship quota-tier-full); rc=$?
  expect_refusal quota-tier-full "$rc" "$out"
  assert_contains "$out" "quota=exhausted scope=all_models" "the full tier is comparable evidence"
  rendered "$RENDERED_LEAN" "$root"
  : > "$root/lean-only"
  out=$(spawn_ship quota-tier-lean); rc=$?
  expect_launch quota-tier-lean "$rc" "$out"
  assert_contains "$out" "quota=stale reason=reading-not-fresh" \
    "a lean live row has no refresh time, so it cannot stop a launch"
  pass "the installed renderer's full tier compares and its lean live tier is stale input"
}

# scoped_login <root> <all_models bounding window> <its reset> <its start>
# all_models is exhausted and bounded by that one window; model:other is bounded
# by a session window whose reset has already passed.
scoped_login() {
  local root=$1 window=$2 reset=$3 start=$4 now past
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  past=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$root"
  printf '{}\n' > "$root/.credentials.json"
  jq -n --arg now "$now" --arg past "$past" --arg window "$window" --arg reset "$reset" --arg start "$start" '{
    generatedAt: $now, schemaVersion: 5,
    providers: [{
      provider: "claude", accountKeys: ["default"],
      state: {status: "fresh", stale: false, refreshedAt: $now},
      windows: [
        {id: "five_hour", percentRemaining: 100, startsAt: "2001-01-01T00:00:00Z", resetsAt: $past},
        ({id: "seven_day", percentRemaining: 0, resetsAt: $reset} + (if $start == "" then {} else {startsAt: $start} end))
      ],
      quotaSemantics: {status: "known", effectiveAvailability: [
        {scope: "all_models", status: "known", effectivePercentRemaining: 0, boundedBy: [$window],
         runway: {status: "exhausted_now"}, selection: {spendPriority: -1}},
        {scope: "model:other", status: "known", effectivePercentRemaining: 100, boundedBy: ["five_hour"],
         runway: {status: "through_reset"}, selection: {spendPriority: 1}}
      ]}
    }]
  }' > "$root/quota.json"
}

test_a_reset_is_judged_on_the_scope_it_bounds() {
  local out rc root future
  new_case scoped claude
  root="$CASE/pinned"
  future=$(date -u -d '3 days' +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$root" > "$HOME_DIR/config/claude-account"
  scoped_login "$root" seven_day "$future" "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  out=$(spawn_ship quota-scope-current --model sonnet); rc=$?
  expect_refusal quota-scope-current "$rc" "$out"
  assert_contains "$out" "quota=exhausted scope=all_models" \
    "another scope's passed reset must not hide a current exhaustion"
  scoped_login "$root" five_hour "$future" ""
  out=$(spawn_ship quota-scope-reset --model sonnet); rc=$?
  expect_launch quota-scope-reset "$rc" "$out"
  assert_contains "$out" "quota=stale reason=window-not-current" "a scope bounded by a passed reset is stale"
  scoped_login "$root" seven_day "$future" "$(date -u -d '1 minute' +%Y-%m-%dT%H:%M:%SZ)"
  out=$(spawn_ship quota-scope-cycle --model sonnet); rc=$?
  expect_launch quota-scope-cycle "$rc" "$out"
  assert_contains "$out" "quota=stale reason=window-not-current" \
    "a window that started after the reading is a newer cycle than the reading"
  pass "a reset or a newer cycle is judged only on the scope whose window it bounds"
}

test_ordinary_pin_without_home_is_unmatched() {
  local out rc
  new_case nohome claude
  claude_login "$HOME_DIR/user-home/.claude" 0 exhausted_now
  # shellcheck disable=SC2016 # the program text expands in the child shell
  out=$(env HOME= PATH="$FAKEBIN:$PATH" STATE="$HOME_DIR/state" bash -c '
    . "$1/bin/fm-quota-launch-lib.sh"
    fm_quota_launch_gate quota-nohome claude sonnet ordinary "" 0 herdr' _ "$ROOT" 2>&1); rc=$?
  expect_code 0 "$rc" "an ordinary pin with no HOME must not refuse: $out"
  assert_contains "$out" "quota=stale reason=unmatched-login" "no HOME means no known default login"
  [ ! -s "$CASE/quota-calls" ] || fail "an ordinary pin with no HOME must not read /.claude"
  pass "an ordinary pin without HOME stays unmatched instead of reading /.claude"
}

# ago <date -d offset>
ago() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

# window_case <name> <refreshedAt> <windows-json> <boundedBy-json> <want>
# An exhausted pinned reading judged by the gate itself. <want> is "refused" or
# the stale reason it must launch with.
window_case() {
  local name=$1 refreshed=$2 windows=$3 bounded=$4 want=$5 out rc extra='{}'
  [ "$name" != reused ] || extra='{"reused": true}'
  claude_login "$CASE/pinned" 0 exhausted_now
  jq --arg at "$refreshed" --argjson windows "$windows" --argjson bounded "$bounded" --argjson extra "$extra" '
    .providers[0].state += ({refreshedAt: $at} + $extra) | .providers[0].windows = $windows |
    .providers[0].quotaSemantics.effectiveAvailability[0].boundedBy = $bounded' \
    "$CASE/pinned/quota.json" > "$CASE/pinned/quota.next" || fail "could not shape the $name reading"
  mv "$CASE/pinned/quota.next" "$CASE/pinned/quota.json"
  # shellcheck disable=SC2016 # the program text expands in the child shell
  out=$(env PATH="$FAKEBIN:$PATH" STATE="$HOME_DIR/state" bash -c '
    . "$1/bin/fm-quota-launch-lib.sh"
    fm_quota_launch_gate "$2" claude sonnet "$3" "$3" 0 herdr' _ "$ROOT" "quota-window-$name" "$CASE/pinned" 2>&1); rc=$?
  if [ "$want" = refused ]; then
    expect_code 1 "$rc" "$name should still refuse: $out"
    assert_contains "$out" "quota=exhausted scope=all_models" "$name is current evidence"
  else
    expect_code 0 "$rc" "$name must not stop a launch: $out"
    assert_contains "$out" "quota=stale reason=$want" "$name should be flagged stale"
  fi
  assert_private "$out"
}

test_windows_that_cannot_be_shown_current_never_stop() {
  local now later none='[]' stale='window-not-current'
  new_case windows claude
  now=$(ago now)
  later=$(ago '3 days')
  window_case session-elapsed "$(ago '2 days ago')" '[{"id":"s","kind":"session"}]' '["s"]' $stale
  window_case daily-elapsed "$(ago '2 days ago')" '[{"id":"d","windowSeconds":86400}]' '["d"]' $stale
  window_case started-long-ago "$now" "[{\"id\":\"s\",\"windowSeconds\":18000,\"startsAt\":\"$(ago '49 hours ago')\"}]" '["s"]' $stale
  window_case monthly-elapsed "$now" "[{\"id\":\"m\",\"kind\":\"monthly\",\"startsAt\":\"$(ago '29 days ago')\"}]" '["m"]' $stale
  window_case no-length-old "$(ago '1 hour ago')" '[{"id":"c","kind":"credits"}]' '["c"]' $stale
  window_case no-windows-old "$(ago '6 days ago')" "$none" "$none" $stale
  window_case named-missing-old "$(ago '6 days ago')" "$none" '["five_hour"]' $stale
  window_case named-missing-now "$now" "[{\"id\":\"w\",\"resetsAt\":\"$later\"}]" '["w","five_hour"]' $stale
  window_case start-unbound "$now" "[{\"id\":\"w\",\"resetsAt\":\"$later\",\"startsAt\":\"2026-11-27T12:00:00\"}]" '["w"]' $stale
  window_case start-unreadable "$now" "[{\"id\":\"w\",\"resetsAt\":\"$later\",\"startsAt\":\"soon\"}]" '["w"]' $stale
  window_case reused "$(ago '6 days ago')" "[{\"id\":\"w\",\"resetsAt\":\"$later\"}]" '["w"]' reading-not-fresh
  window_case session-current "$now" '[{"id":"s","kind":"session"}]' '["s"]' refused
  window_case weekly-current "$(ago '2 days ago')" '[{"id":"w","kind":"weekly"}]' '["w"]' refused
  window_case no-length-now "$now" '[{"id":"c","kind":"credits"}]' '["c"]' refused
  window_case no-windows-now "$now" "$none" "$none" refused
  [ "$(wc -l < "$CASE/quota-calls")" -eq 15 ] || fail "each window case should read the pinned login once"
  pass "an elapsed, missing, unreadable, or reused window is stale input, and a current one still refuses"
}

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

test_stale_intake_rows_exclude_no_profile() {
  local out state want
  new_case staleintake claude
  make_intake
  login "$HOME_DIR/user-home" 5 "$(reading claude fresh all_models 0 exhausted_now)"
  out=$(resolve)
  assert_contains "$out" "not eligible: runway exhausted_now" "a current row still excludes: $out"
  for state in stale reset; do
    rm -f "$HOME_DIR/state/quota-launch.log"
    want="reading-not-fresh"
    [ "$state" = stale ] || want="window-not-current"
    if [ "$state" = stale ]; then
      login "$HOME_DIR/user-home" 5 "$(reading claude stale all_models 0 exhausted_now)"
    else
      login "$HOME_DIR/user-home" 5 "$(reading claude fresh all_models 0 exhausted_now)"
      sed -i.bak 's|"provider": "claude",|"provider": "claude", "windows": [{"id": "w", "resetsAt": "2001-01-01T00:00:00Z"}],|' \
        "$HOME_DIR/user-home/quota.json"
    fi
    out=$(resolve)
    assert_not_contains "$out" "not eligible" "a $state row must not exclude the profile: $out"
    assert_contains "$out" "eligible, unranked" "a $state row leaves the profile eligible"
    assert_contains "$out" "quota: stale" "a $state row is flagged"
    assert_grep "quota=stale reason=$want" "$HOME_DIR/state/quota-launch.log" \
      "a $state row is logged with its own reason"
    assert_not_contains "$out" "$SECRET" "intake must not repeat an account identity"
  done
  mkdir -p "$CASE/listed"
  claude_login "$CASE/listed" 0 exhausted_now
  sed -i.bak 's|"provider": "claude",|"provider": "claude", "windows": [{"id": "w", "resetsAt": "2001-01-01T00:00:00Z"}],|' \
    "$CASE/listed/quota.json"
  printf '%s\n' "$CASE/listed" > "$HOME_DIR/config/claude-accounts"
  out=$(FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-claude-account-quota.sh" 2>&1)
  assert_contains "$out" "uncertainty: quota reading is stale or not current" "listed accounts: $out"
  assert_not_contains "$out" "remaining=" "a reset account reading prints no figures"
  pass "stale or reset intake rows exclude no profile"
}

# grok_snapshot <root> <mode> <remaining> <runway>
# A schema-5 aggregate generated now, with one grok row in the task-fixture
# shape: fresh label, stale false, future resets, and the named windows.
grok_snapshot() {
  local root=$1 mode=$2 remaining=$3 runway=$4 refresh now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "$mode" in
    now) refresh=$now ;;
    old) refresh=$(date -u -d '16 days ago' +%Y-%m-%dT%H:%M:%SZ) ;;
    unbound) refresh='2026-11-11T00:36:00' ;;
    missing) refresh='' ;;
    *) fail "unknown grok refresh mode $mode" ;;
  esac
  mkdir -p "$root"
  jq -n --arg now "$now" --arg refresh "$refresh" --argjson remaining "$remaining" --arg runway "$runway" --arg secret "$SECRET" \
    --arg reset '2999-12-03T03:45:33.000Z' '{
      generatedAt: $now,
      schemaVersion: 5,
      providers: [{
        provider: "grok",
        account: {email: $secret},
        state: ({status: "fresh", stale: false} + (if $refresh == "" then {} else {refreshedAt: $refresh} end)),
        windows: [
          {id: "credits", percentRemaining: 86, resetsAt: $reset},
          {id: "product:grok_build", percentRemaining: 94, resetsAt: $reset}
        ],
        quotaSemantics: {status: "known", effectiveAvailability: [{
          scope: "all_models", status: "known", effectivePercentRemaining: $remaining,
          runway: {status: $runway}, selection: {spendPriority: 0.5}
        }]}
      }]
    }' > "$root/quota.json"
}

test_a_labelled_fresh_row_is_judged_by_its_own_refresh_time() {
  local out mode
  new_case labelled grok
  make_intake
  printf '{"rules":[{"when":"A bug fix.","use":{"harness":"grok"}}]}\n' \
    > "$HOME_DIR/config/crew-dispatch.json"
  for mode in missing old unbound; do
    grok_snapshot "$HOME_DIR/user-home" "$mode" 0 exhausted_now
    out=$(resolve)
    assert_not_contains "$out" "not eligible" "a $mode grok row must not exclude: $out"
    assert_contains "$out" "quota: stale" "a $mode grok row is stale input: $out"
    assert_not_contains "$out" "$SECRET" "a $mode grok row must not leak the account: $out"
    assert_grep "quota=stale reason=reading-not-fresh" "$HOME_DIR/state/quota-launch.log" \
      "a $mode grok row is logged as not comparable"
  done
  grok_snapshot "$HOME_DIR/user-home" now 0 exhausted_now
  out=$(resolve)
  assert_contains "$out" "not eligible: runway exhausted_now" "a recent grok reading at the cap still excludes: $out"
  assert_not_contains "$out" "$SECRET" "a comparable grok reading must not leak the account: $out"
  grok_snapshot "$HOME_DIR/user-home" now 86 through_reset
  out=$(resolve)
  assert_contains "$out" "status: clear" "comparable grok headroom should resolve: $out"
  assert_contains "$out" "remaining=86%" "comparable grok headroom should keep its figure: $out"
  assert_not_contains "$out" "quota: stale" "comparable grok headroom is not stale: $out"
  assert_not_contains "$out" "$SECRET" "comparable grok headroom must not leak the account: $out"
  pass "a fresh label follows the provider refresh time, and the snapshot clock does not"
}

test_dispatch_intake_reads_the_pinned_login() {
  local out
  new_case intakepin claude
  make_intake
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

test_intake_reports_only_candidates_and_keeps_independent_rows() {
  local out
  new_case unrelated claude
  make_intake
  login "$HOME_DIR/user-home" 5 \
    "$(reading claude fresh all_models 80 through_reset)" \
    "$(jq -nc '{provider: "deepseek", notSetUp: true, state: {status: "unavailable", stale: false},
      quotaSemantics: {status: "unknown", effectiveAvailability: []}}')"
  out=$(resolve)
  assert_contains "$out" "status: clear" "an unrelated provider's absence leaves the candidate ranked: $out"
  assert_contains "$out" "remaining=80%" "the candidate keeps its own figure: $out"
  assert_not_contains "$out" "quota-gate:" "an unrelated provider must not be reported: $out"
  assert_not_contains "$out" "quota: stale" "an unrelated provider is not stale input for this intake: $out"
  [ ! -e "$HOME_DIR/state/quota-launch.log" ] ||
    assert_no_grep "quota=stale" "$HOME_DIR/state/quota-launch.log" "an unrelated provider must not be logged"
  assert_grep "args=--full --json --no-credential-refresh" "$CASE/quota-calls" \
    "the intake read keeps provider refresh times and never refreshes a credential"
  claude_login "$HOME_DIR/user-home" 64
  : > "$HOME_DIR/user-home/exit-1"
  out=$(resolve)
  assert_contains "$out" "status: clear" "a snapshot printed with exit 1 is still judged: $out"
  assert_contains "$out" "remaining=64%" "the exit-1 snapshot's attributable row is kept: $out"
  pass "intake reports only the candidates it ranks, and keeps every independently attributable row"
}

test_unusable_pi_pin_binds_no_pi_lane_at_intake() {
  local out
  new_case badpi claude
  make_intake
  printf '{"rules":[{"when":"A bug fix.","use":[{"harness":"pi","model":"openai-codex-work/gpt-6","provider":"codex"},{"harness":"codex","model":"gpt-6"}]}]}\n' \
    > "$HOME_DIR/config/crew-dispatch.json"
  printf 'not-a-path\nopenai-codex-work\n' > "$HOME_DIR/config/pi-account"
  login "$HOME_DIR/user-home" 6 \
    "$(keyed openai-codex-work openai-codex-work 90 through_reset)" \
    "$(keyed codex-home codex-home 50 through_reset)"
  out=$(resolve)
  assert_contains "$out" "status: clear" "native Codex still ranks: $out"
  assert_contains "$out" "candidate: codex:gpt-6  provider=codex  scope=all_models  remaining=50%" \
    "the native row is kept: $out"
  assert_contains "$out" "candidate: pi:openai-codex-work/gpt-6  provider=codex  -> eligible, unranked" \
    "a Pi lane must not borrow the ambient Pi login: $out"
  assert_contains "$out" "harness=pi provider=codex quota=stale reason=pi-pin-unusable" \
    "the unusable pin is reported against the Pi candidate: $out"
  assert_not_contains "$out" "remaining=90%" "the ambient Pi figure must not appear: $out"
  login "$HOME_DIR/user-home" 6 \
    "$(reading codex stale all_models 90 through_reset openai-codex-work)" \
    "$(reading codex stale all_models 50 through_reset default)"
  rm -f "$HOME_DIR/state/quota-launch.log"
  out=$(resolve)
  assert_contains "$out" "harness=pi provider=codex quota=stale reason=pi-pin-unusable" \
    "the Pi candidate keeps the pin reason: $out"
  assert_contains "$out" "harness=codex provider=codex quota=stale reason=reading-not-fresh" \
    "native Codex is reported for its own reading: $out"
  assert_not_contains "$out" "harness=codex provider=codex quota=stale reason=pi-pin-unusable" \
    "a Pi pin never explains native Codex: $out"
  login "$HOME_DIR/user-home" 6 \
    "$(reading codex fresh all_models 90 through_reset openai-codex-work)" \
    "$(reading codex fresh all_models 50 through_reset default)"
  out=$(resolve)
  assert_contains "$out" "candidate: codex:gpt-6  provider=codex  scope=all_models  remaining=50%" \
    "a legacy default row stays native Codex's: $out"
  assert_contains "$out" "candidate: pi:openai-codex-work/gpt-6  provider=codex  -> eligible, unranked" \
    "a legacy row without accountKeys must not leak an ambient Pi login: $out"
  assert_not_contains "$out" "remaining=90%" "the ambient legacy Pi figure must not appear: $out"
  make_intake
  printf 'not-a-path\n' > "$HOME_DIR/config/claude-account"
  out=$(resolve)
  assert_contains "$out" "harness=claude provider=claude quota=stale reason=claude-pin-unusable" \
    "an unusable Claude pin is named as such: $out"
  pass "an unusable Pi pin leaves Pi lanes unmeasured at intake instead of reading the ambient login"
}

test_pinned_login_swap_never_inherits_a_stop
test_a_destination_selected_login_is_never_refused_by_another
test_a_passed_reset_is_stale_evidence
test_only_scopes_that_bound_the_model_stop_it
test_missing_or_non_current_readings_launch_as_stale
test_provider_refresh_time_not_the_fresh_label
test_codex_is_unmatched_and_pi_binds_its_lane_by_account_keys
test_invalid_account_config_still_refuses
test_secondmate_launch_reads_its_own_pin
test_stale_intake_rows_exclude_no_profile
test_a_labelled_fresh_row_is_judged_by_its_own_refresh_time
test_dispatch_intake_reads_the_pinned_login
test_unusable_intake_read_falls_through_to_an_ordinary_launch
test_installed_renderer_tiers_full_compares_and_lean_is_stale
test_a_reset_is_judged_on_the_scope_it_bounds
test_ordinary_pin_without_home_is_unmatched
test_intake_reports_only_candidates_and_keeps_independent_rows
test_unusable_pi_pin_binds_no_pi_lane_at_intake
test_windows_that_cannot_be_shown_current_never_stop

echo "# all fm-quota-launch-gate tests passed"
