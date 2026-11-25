#!/usr/bin/env bash
# Behavioral tests for bin/fm-done-check.sh: the off/shadow/on switch, each checklist
# check, the bounded steering, and the bin/fm-pr-check.sh hook.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-done-check.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
URL=https://github.com/acme/widget/pull/7
command -v jq >/dev/null 2>&1 || fail "these tests read the verdict JSON with the real jq, which was not found"
fm_git_identity

T=$(fm_test_tmproot fm-done-check)
HOME_DIR="$T/home"
ROOT_STUB="$T/root"
REPO="$T/repo"
FAKEBIN=$(fm_fakebin "$T")
SEND_LOG="$T/send.log"

# The forge answers from variables: the PR view the checklist reads, the draft
# state and head that bin/fm-pr-check.sh reads before it arms anything.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
case "$*" in
  *"--json baseRefName,headRefOid,mergeable,mergeStateStatus"*)
    jq -n --arg base "${FM_TEST_BASE:-dev}" --arg head "$FM_TEST_HEAD" \
      --arg mergeable "${FM_TEST_MERGEABLE:-MERGEABLE}" --arg state "${FM_TEST_MERGE_STATE:-CLEAN}" \
      '{baseRefName: $base, headRefOid: $head, mergeable: $mergeable, mergeStateStatus: $state}' ;;
  *"--json isDraft"*) printf '{"isDraft":false}\n' ;;
  *"--json headRefOid -q"*) printf '%s\n' "$FM_TEST_HEAD" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

mkdir -p "$ROOT_STUB/bin" "$HOME_DIR/state" "$HOME_DIR/data/task-a" "$HOME_DIR/config"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_STUB/bin/fm-guard.sh"
cat > "$ROOT_STUB/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_SEND_RC:-0}" = 0 ] || exit "$FM_TEST_SEND_RC"
printf '%s\n' "$*" >> "$FM_TEST_SEND_LOG"
SH
chmod +x "$ROOT_STUB/bin/fm-guard.sh" "$ROOT_STUB/bin/fm-send.sh"

# repo: base branch dev with a bare origin, then a feature branch for the PR.
fm_git_init_commit "$REPO"
git -C "$REPO" checkout -q -b dev
mkdir -p "$REPO/bin" "$REPO/docs"
printf 'vision\n' > "$REPO/VISION.md"
printf 'one\n' > "$REPO/bin/tool.sh"
printf 'doc\n' > "$REPO/docs/guide.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'base content'
fm_git_add_origin "$REPO" "$T/origin.git"
git -C "$REPO" fetch -q origin
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

fm_write_meta "$HOME_DIR/state/task-a.meta" \
  "window=firstmate:fm-task-a" "endpoint_task_id=task-a" "worktree=$REPO" \
  "project=$REPO" "kind=ship" "mode=direct-PR"

# reset_pr: fresh feature branch off the base, no brief, receipt, config, or counters.
reset_pr() {
  git -C "$REPO" checkout -q -f -B feature "$BASE_SHA"
  rm -rf "$HOME_DIR/data/task-a/proof"
  rm -f "$HOME_DIR/data/task-a/"* "$HOME_DIR/config/done-check" "$HOME_DIR/state/task-a.done-check" \
    "$HOME_DIR/state/done-check.log" "$SEND_LOG" "$HOME_DIR/state/task-a.check.sh"
  rm -f "$HOME_DIR/state/task-a.status"
  : > "$SEND_LOG"
}

# commit_file <path> <content> [message]: one more commit on the PR branch. Hooks are
# off because an operator's commit-msg hook may strip the very trailers a case plants.
commit_file() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git -C "$REPO" add "$1"
  git -C "$REPO" -c core.hooksPath=/dev/null commit -qm "${3:-change $1}"
}

write_brief() { printf '%s\n' "$@" > "$HOME_DIR/data/task-a/brief.md"; }

OUT=
ERR=
RC=0
# check [VAR=value ...]: run the checklist against the current feature head.
check() {
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  RC=0
  OUT=$(env FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_TEST_HEAD="$head" FM_TEST_SEND_LOG="$SEND_LOG" "$@" \
    "$SCRIPT" task-a "$URL" 2> "$T/stderr") || RC=$?
  ERR=$(cat "$T/stderr")
}

result_of() { printf '%s' "$OUT" | jq -r --arg n "$1" '.checks[] | select(.name == $n) | .result'; }
sends() { grep -c '^task-a ' "$SEND_LOG" || true; }

test_off_by_default_does_nothing() {
  reset_pr
  commit_file VISION.md changed
  check
  expect_code 0 "$RC" "an unconfigured home"
  [ -z "$OUT$ERR" ] || fail "an unconfigured home printed: $OUT$ERR"
  assert_absent "$HOME_DIR/state/done-check.log" "off must not write a verdict log"
  printf 'off\n' > "$HOME_DIR/config/done-check"
  check
  expect_code 0 "$RC" "config off"
  printf 'bogus\n' > "$HOME_DIR/config/done-check"
  check
  expect_code 0 "$RC" "an unrecognized switch value stays off"
  [ -z "$OUT$ERR" ] || fail "an unrecognized switch value ran the checklist"
  pass "off by default, by config, and for unrecognized values"
}

test_switch_comes_from_config_file_or_env() {
  reset_pr
  commit_file VISION.md changed
  printf '# comment\n\non\n' > "$HOME_DIR/config/done-check"
  check
  expect_code 10 "$RC" "config on with a failing PR"
  check FM_DONE_CHECK=off
  expect_code 0 "$RC" "FM_DONE_CHECK=off beats the config file"
  pass "the switch reads config/done-check and FM_DONE_CHECK overrides it"
}

test_clean_pr_passes() {
  reset_pr
  commit_file bin/tool.sh two
  write_brief '## Base branch' 'dev' '' '## Files in scope' '- `bin/`' '' '## Tests' '- `bash tests/x.test.sh`'
  printf '{"head_sha":"%s","tests":[{"cmd":"bash tests/x.test.sh","exit":0}]}\n' "$(git -C "$REPO" rev-parse HEAD)" \
    > "$HOME_DIR/data/task-a/receipt.json"
  check FM_DONE_CHECK=on
  expect_code 0 "$RC" "a clean PR"
  assert_equals pass "$(printf '%s' "$OUT" | jq -r .verdict)" "verdict"
  for c in base mergeable vision trailers scope tests; do
    assert_equals pass "$(result_of "$c")" "check $c on a clean PR"
  done
  assert_equals 0 "$(sends)" "a clean PR must not steer the worker"
  assert_present "$HOME_DIR/state/done-check.log" "the verdict is logged"
  assert_absent "$HOME_DIR/state/task-a.done-check" "a pass must not count a bounce"
  pass "a clean PR passes every check and sends nothing"
}

test_base_must_match_the_brief() {
  reset_pr
  commit_file bin/tool.sh two
  write_brief '## Base branch' '`dev`'
  check FM_DONE_CHECK=on FM_TEST_BASE=main
  expect_code 10 "$RC" "wrong base"
  assert_equals fail "$(result_of base)" "base check"
  assert_contains "$(cat "$SEND_LOG")" 'targets main but the brief names dev' "the steer names both branches"
  reset_pr
  commit_file bin/tool.sh two
  check FM_DONE_CHECK=on FM_TEST_BASE=main
  assert_equals skip "$(result_of base)" "no declared base is skipped, not failed"
  check FM_DONE_CHECK=on FM_TEST_BASE=main FM_DONE_CHECK_BASE=dev
  assert_equals fail "$(result_of base)" "FM_DONE_CHECK_BASE declares the intended base"
  pass "base must equal the intended branch when one is declared"
}

test_mergeable_uses_forge_and_local_merge() {
  reset_pr
  commit_file bin/tool.sh two
  check FM_DONE_CHECK=on FM_TEST_MERGE_STATE=DIRTY FM_TEST_MERGEABLE=CONFLICTING
  expect_code 10 "$RC" "forge reports a conflict"
  assert_equals fail "$(result_of mergeable)" "forge DIRTY"
  # A conflict only a local merge can see: dev moved the same line after the PR branched.
  reset_pr
  commit_file bin/tool.sh mine
  git -C "$REPO" checkout -q dev
  printf 'theirs\n' > "$REPO/bin/tool.sh"
  git -C "$REPO" commit -qam 'dev moves the same line'
  git -C "$REPO" push -q origin dev
  git -C "$REPO" fetch -q origin
  git -C "$REPO" checkout -q feature
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "local merge conflict with a stale forge verdict"
  assert_equals fail "$(result_of mergeable)" "local merge-tree"
  assert_contains "$(cat "$SEND_LOG")" 'conflicts locally' "the steer says the conflict is real"
  git -C "$REPO" checkout -q -f dev
  git -C "$REPO" reset -q --hard "$BASE_SHA"
  git -C "$REPO" push -q -f origin dev
  git -C "$REPO" fetch -q origin
  pass "mergeable fails on a forge conflict and on a local merge conflict"
}

test_vision_must_be_unchanged_against_base() {
  reset_pr
  commit_file VISION.md changed
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "VISION.md edited"
  assert_equals fail "$(result_of vision)" "vision check"
  # The base moving VISION.md is not the PR's change.
  reset_pr
  commit_file bin/tool.sh two
  git -C "$REPO" checkout -q dev
  printf 'newer vision\n' > "$REPO/VISION.md"
  git -C "$REPO" commit -qam 'dev edits VISION.md'
  git -C "$REPO" push -q origin dev
  git -C "$REPO" fetch -q origin
  git -C "$REPO" checkout -q feature
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of vision)" "a base-side VISION.md change must not bounce the PR"
  git -C "$REPO" checkout -q -f dev
  git -C "$REPO" reset -q --hard "$BASE_SHA"
  git -C "$REPO" push -q -f origin dev
  git -C "$REPO" fetch -q origin
  pass "VISION.md must be unchanged by the PR itself"
}

test_ai_trailers_fail() {
  reset_pr
  commit_file bin/a.sh a $'feat: a\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "AI co-author trailer"
  assert_equals fail "$(result_of trailers)" "co-author trailer"
  reset_pr
  commit_file bin/a.sh a $'feat: a\n\nGenerated with Claude Code'
  check FM_DONE_CHECK=on
  assert_equals fail "$(result_of trailers)" "generated-with footer"
  reset_pr
  commit_file bin/a.sh a $'feat: a\n\nCo-authored-by: Jo Human <jo@example.com>'
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of trailers)" "a human co-author is not an AI trailer"
  pass "AI co-author trailers and generated-with footers fail, human co-authors pass"
}

test_scope_follows_the_brief() {
  reset_pr
  write_brief '## Files in scope' '- `bin/`' '- docs/*.md'
  commit_file bin/new.sh x
  commit_file docs/new.md x
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of scope)" "files inside the globs"
  commit_file README.md x
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "a file outside the scope"
  assert_equals fail "$(result_of scope)" "scope check"
  assert_contains "$(cat "$SEND_LOG")" 'README.md' "the steer names the stray file"
  reset_pr
  commit_file README.md x
  check FM_DONE_CHECK=on
  assert_equals skip "$(result_of scope)" "a brief with no scope declares nothing to enforce"
  pass "changed files must match the brief's declared scope"
}

test_tests_must_have_run() {
  reset_pr
  commit_file bin/tool.sh two
  head=$(git -C "$REPO" rev-parse HEAD)
  write_brief '## Tests' '- `bash tests/a.test.sh`' '- bash tests/b.test.sh'
  check FM_DONE_CHECK=on
  expect_code 0 "$RC" "no evidence is unknown, never a bounce"
  assert_equals unknown "$(result_of tests)" "no receipt or log"
  printf '{"head_sha":"%s","tests":[{"cmd":"bash tests/a.test.sh","exit":0}]}\n' "$head" > "$HOME_DIR/data/task-a/receipt.json"
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "a named test missing from the receipt"
  assert_contains "$(cat "$SEND_LOG")" "'bash tests/b.test.sh' is not in the receipt" "the steer names the missing test"
  rm -f "$HOME_DIR/state/task-a.done-check"
  printf '{"head_sha":"%s","tests":[{"cmd":"bash tests/a.test.sh","exit":0},{"cmd":"bash   tests/b.test.sh","exit":1}]}\n' "$head" \
    > "$HOME_DIR/data/task-a/receipt.json"
  check FM_DONE_CHECK=on
  assert_equals fail "$(result_of tests)" "a nonzero exit fails, whitespace-insensitively matched"
  assert_contains "$ERR" 'exited nonzero' "the failure says the test failed"
  printf '{"head_sha":"%s","tests":[{"cmd":"bash tests/a.test.sh","exit":0},{"cmd":"bash tests/b.test.sh","exit":0}]}\n' "$head" \
    > "$HOME_DIR/data/task-a/receipt.json"
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of tests)" "every named test passing"
  printf '{"head_sha":"0000000000000000000000000000000000000000","tests":[{"cmd":"bash tests/a.test.sh","exit":0},{"cmd":"bash tests/b.test.sh","exit":0}]}\n' \
    > "$HOME_DIR/data/task-a/receipt.json"
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of tests)" "a receipt for an older head is noted, not failed"
  assert_contains "$OUT" 'differs from PR head' "the head difference is recorded"
  rm -f "$HOME_DIR/data/task-a/receipt.json"
  printf 'ran bash tests/a.test.sh ok\n' > "$HOME_DIR/data/task-a/report.md"
  check FM_DONE_CHECK=on
  assert_equals fail "$(result_of tests)" "a report that omits one named test"
  printf 'ran bash tests/b.test.sh ok\n' >> "$HOME_DIR/data/task-a/report.md"
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of tests)" "a report that mentions every named test"
  reset_pr
  commit_file bin/tool.sh two
  check FM_DONE_CHECK=on
  assert_equals skip "$(result_of tests)" "a brief that names no tests"
  pass "tests named in the brief must be shown run and passing"
}

write_status_done() { printf '%s\n' "$@" > "$HOME_DIR/state/task-a.status"; }

test_proof_rider_on_ui_prs() {
  reset_pr
  rm -f "$HOME_DIR/state/task-a.status"
  commit_file bin/tool.sh two
  check FM_DONE_CHECK=on
  assert_equals skip "$(result_of proof)" "no UI files changed and no rider declared"
  commit_file web/src/App.tsx 'export default () => <div/>'
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "UI files without a proof rider bounce"
  assert_equals fail "$(result_of proof)" "UI-facing files demand proof"
  assert_contains "$(cat "$SEND_LOG")" 'proof' "the steer asks for visual proof"
  write_status_done "done [at=1]: $URL proof=none"
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of proof)" "proof=none declares no user-visible change"
  expect_code 0 "$RC" "proof=none leaves the PR clean"
  mkdir -p "$HOME_DIR/data/task-a/proof"
  printf 'x' > "$HOME_DIR/data/task-a/proof/home.png"
  printf 'x' > "$HOME_DIR/data/task-a/proof/flow.mp4"
  write_status_done "done [at=1]: $URL checks green proof=$HOME_DIR/data/task-a/proof/home.png,$HOME_DIR/data/task-a/proof/flow.mp4"
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of proof)" "a rider naming real screenshot and video files"
  expect_code 0 "$RC" "a UI PR with attached proof passes"
  write_status_done "done [at=1]: $URL proof=$HOME_DIR/data/task-a/proof/gone.png"
  check FM_DONE_CHECK=on
  assert_equals fail "$(result_of proof)" "a rider naming a missing file"
  printf 'x' > "$HOME_DIR/data/task-a/proof/notes.md"
  write_status_done "done [at=1]: $URL proof=$HOME_DIR/data/task-a/proof/notes.md"
  check FM_DONE_CHECK=on
  assert_equals fail "$(result_of proof)" "a text file is not visual proof"
  rm -f "$HOME_DIR/state/task-a.status"
  check FM_DONE_CHECK=on
  assert_equals fail "$(result_of proof)" "an unreadable ready report does not waive proof on a UI PR"
  reset_pr
  commit_file bin/tool.sh two
  rm -f "$HOME_DIR/state/task-a.done-check"
  check FM_DONE_CHECK=on
  assert_equals skip "$(result_of proof)" "no UI files changed needs no rider"
  reset_pr
  rm -rf "$HOME_DIR/data/task-a/proof" "$HOME_DIR/state/task-a.status"
  pass "a UI PR's ready report must carry a verified proof rider"
}

test_shadow_logs_and_never_acts() {
  reset_pr
  commit_file VISION.md changed
  check FM_DONE_CHECK=shadow
  expect_code 0 "$RC" "shadow mode"
  assert_equals fail "$(result_of vision)" "shadow still computes the verdict"
  assert_equals would-bounce "$(printf '%s' "$OUT" | jq -r .action)" "shadow action"
  assert_equals 0 "$(sends)" "shadow must not steer"
  assert_absent "$HOME_DIR/state/task-a.done-check" "shadow must not count bounces"
  assert_equals would-bounce "$(jq -r .action "$HOME_DIR/state/done-check.log")" "shadow logs the verdict"
  pass "shadow computes and logs the verdict without steering"
}

test_bounces_are_bounded() {
  reset_pr
  commit_file VISION.md changed
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "first failure"
  assert_equals 1 "$(sends)" "first bounce steers"
  assert_contains "$(cat "$SEND_LOG")" 'bounce 1 of 2' "the steer numbers the bounce"
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "same head again"
  assert_equals 1 "$(sends)" "a rerun on the same head must not steer or count again"
  assert_equals already-bounced "$(printf '%s' "$OUT" | jq -r .action)" "same-head action"
  commit_file bin/a.sh a
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "second failure on a new head"
  assert_equals 2 "$(sends)" "second bounce steers"
  assert_contains "$(cat "$SEND_LOG")" 'bounce 2 of 2' "second bounce is numbered"
  commit_file bin/b.sh b
  check FM_DONE_CHECK=on
  expect_code 11 "$RC" "third failure escalates"
  assert_equals escalate "$(printf '%s' "$OUT" | jq -r .action)" "escalation action"
  assert_equals 2 "$(sends)" "no third steer after the limit"
  pass "at most 2 bounces, then exit 11 escalates without another steer"
}

test_unconfirmed_steer_is_not_counted() {
  reset_pr
  commit_file VISION.md changed
  check FM_DONE_CHECK=on FM_TEST_SEND_RC=1
  expect_code 3 "$RC" "steer not confirmed"
  assert_absent "$HOME_DIR/state/task-a.done-check" "an unconfirmed steer must not use a bounce"
  check FM_DONE_CHECK=on
  expect_code 10 "$RC" "the retry steers"
  assert_contains "$(cat "$SEND_LOG")" 'bounce 1 of 2' "the retry is bounce 1"
  pass "an unconfirmed steer is not counted against the limit"
}

test_unreadable_facts_never_bounce() {
  reset_pr
  commit_file VISION.md changed
  check FM_DONE_CHECK=on FM_TEST_GH_FAIL=1
  expect_code 3 "$RC" "forge unreadable"
  assert_equals 0 "$(sends)" "an unknown verdict must not steer"
  RC=0
  FM_HOME="$HOME_DIR" FM_DONE_CHECK=on "$SCRIPT" task-a >/dev/null 2>&1 || RC=$?
  expect_code 2 "$RC" "missing PR argument"
  RC=0
  FM_HOME="$HOME_DIR" FM_DONE_CHECK=on "$SCRIPT" task-a not-a-url >/dev/null 2>&1 || RC=$?
  expect_code 2 "$RC" "malformed PR address"
  # Remote-tracking ref missing from the worktree: git facts are unknown, not failed.
  git -C "$REPO" update-ref -d refs/remotes/origin/dev
  check FM_DONE_CHECK=on
  expect_code 0 "$RC" "no base ref in the worktree"
  assert_equals unknown "$(result_of vision)" "vision unknown without a base ref"
  git -C "$REPO" fetch -q origin
  pass "unreadable facts are unknown and never bounce"
}

# The hook: a bounce or escalation stops bin/fm-pr-check.sh before anything is armed.
test_pr_check_hook() {
  local rc out head
  reset_pr
  commit_file VISION.md changed
  head=$(git -C "$REPO" rev-parse HEAD)
  # A direct-PR worker has pushed its head before it arms the PR, so the named-head gate passes.
  git -C "$REPO" push -q origin feature
  git -C "$REPO" fetch -q origin
  printf 'on\n' > "$HOME_DIR/config/done-check"
  rc=0
  out=$(FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_TEST_HEAD="$head" FM_TEST_SEND_LOG="$SEND_LOG" "$PR_CHECK" task-a "$URL" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-pr-check armed a PR that failed the done checklist"
  assert_contains "$out" 'done checklist' "the refusal names the checklist"
  assert_absent "$HOME_DIR/state/task-a.check.sh" "a bounced PR must not arm merge monitoring"
  assert_equals 1 "$(sends)" "the hook steers the worker once"
  printf 'off\n' > "$HOME_DIR/config/done-check"
  rc=0
  out=$(FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_TEST_HEAD="$head" FM_TEST_SEND_LOG="$SEND_LOG" "$PR_CHECK" task-a "$URL" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-pr-check with the checklist off failed: $out"
  assert_contains "$out" 'armed: state/task-a.check.sh' "off keeps today's arming"
  pass "fm-pr-check stops on a bounce and arms as before when the checklist is off"
}

test_auto_records_pr() {
  local head
  reset_pr
  head=$(git -C "$REPO" rev-parse HEAD)
  FM_HOME="$HOME_DIR" "$SCRIPT" --auto task-a "$URL" || fail "auto off binding failed"
  assert_grep "pr=$URL" "$HOME_DIR/state/task-a.meta" "auto did not bind pr with checklist off"
  assert_absent "$HOME_DIR/state/done-check.log" "off should not check"
  env FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_DONE_CHECK=shadow FM_TEST_HEAD="$head" "$SCRIPT" --auto task-a "$URL" >/dev/null 2>&1 \
    || fail "auto shadow check failed"
  assert_grep "pr_head=$head" "$HOME_DIR/state/task-a.meta" "auto did not record forge head"
  assert_equals 1 "$(grep -c '^pr=' "$HOME_DIR/state/task-a.meta")" "auto duplicated pr field"
  assert_present "$HOME_DIR/state/done-check.log" "auto never ran checklist"
  pass "auto binds canonical pr even with checklist off and records head when available"
}

test_watcher_runs_done_check() {
  # Reuse the hermetic watcher toolchain; no real backend or model is launched.
  # shellcheck source=tests/wake-helpers.sh
  . "$ROOT/tests/wake-helpers.sh"
  local TMP_ROOT="$T/watcher" dir state fakebin head pid i rc
  dir=$(make_case "auto-done-$1"); state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$dir/home/config" "$dir/home/data"
  printf '%s\n' "$1" > "$dir/home/config/done-check"
  cp "$FAKEBIN/gh" "$fakebin/gh"
  head=$(git -C "$REPO" rev-parse HEAD)
  fm_write_meta "$state/ship.meta" "kind=ship" "worktree=$REPO" "base=dev"
  fm_write_meta "$state/mate.meta" "kind=secondmate"
  fm_write_meta "$state/scout.meta" "kind=scout"
  printf 'done [at=1]: %s\n' "$URL" > "$state/ship.status"
  printf 'done [at=1]: %s\n' "$URL" > "$state/mate.status"
  printf 'done [at=1]: %s\n' "$URL" > "$state/scout.status"
  env -u FM_ROOT_OVERRIDE FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_HEAD="$head" PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" || true; fail "done watcher did not surface: $(cat "$dir/err")"; fi
  rc=0; wait "$pid" || rc=$?
  expect_code 0 "$rc" "watcher done signal"
  # Wake delivery is detached from completion work; wait for its receipt.
  for ((i=0; i<300; i++)); do
    [ ! -f "$state/.worker-done-ship/acme--widget--7.1.checked" ] || break
    sleep 0.1
  done
  [ "$i" -lt 300 ] || fail "completion did not finish: $(cat "$state/worker-done.log" 2>/dev/null)"
  assert_grep "pr=$URL" "$state/ship.meta" "watcher did not bind done PR"
  assert_grep "pr_head=$head" "$state/ship.meta" "watcher did not record done head"
  assert_equals 1 "$(wc -l < "$state/done-check.log" | tr -d ' ')" "watcher should check only the ship"
  assert_no_grep 'pr=' "$state/mate.meta" "secondmate must not own child PR"
  assert_no_grep 'pr=' "$state/scout.meta" "scout must not own PR"
  assert_contains "$(cat "$dir/out")" 'signal:' "check swallowed normal wake"
  pass "watcher runs auto checklist on latest ship done URLs; other roles stay unbound"
}

test_base_metadata_keys() {
  reset_pr
  commit_file bin/tool.sh two
  printf 'base=dev\nbase_branch=main\n' >> "$HOME_DIR/state/task-a.meta"
  check FM_DONE_CHECK=on FM_TEST_BASE=main
  assert_equals pass "$(result_of base)" 'base_branch takes priority over legacy base'
  sed '/^base_branch=/d' "$HOME_DIR/state/task-a.meta" > "$T/meta"
  mv "$T/meta" "$HOME_DIR/state/task-a.meta"
  check FM_DONE_CHECK=on FM_TEST_BASE=main
  assert_equals fail "$(result_of base)" 'legacy base remains a fallback'
  sed '/^base=/d' "$HOME_DIR/state/task-a.meta" > "$T/meta"
  mv "$T/meta" "$HOME_DIR/state/task-a.meta"
  pass 'base metadata uses base_branch before legacy base'
}
test_top_level_heading_ends_checklist_section() {
  reset_pr
  commit_file bin/tool.sh two
  write_brief '## Files in scope' '- `bin/`' '' '## Tests' '- `bash tests/a.test.sh`' '' '# Setup' '1. Create a branch' '# Rules' '2. Keep work isolated'
  printf '{"head_sha":"%s","tests":[{"cmd":"bash tests/a.test.sh","exit":0}]}\n' "$(git -C "$REPO" rev-parse HEAD)" > "$HOME_DIR/data/task-a/receipt.json"
  check FM_DONE_CHECK=on
  assert_equals pass "$(result_of tests)" 'top-level setup and rules must not become test commands'
  pass 'checklist sections stop at the next top-level heading'
}
if [ -z "${1:-}" ]; then
  test_top_level_heading_ends_checklist_section
  test_base_metadata_keys
  test_off_by_default_does_nothing
  test_switch_comes_from_config_file_or_env
  test_clean_pr_passes
  test_base_must_match_the_brief
  test_mergeable_uses_forge_and_local_merge
  test_vision_must_be_unchanged_against_base
  test_ai_trailers_fail
  test_scope_follows_the_brief
  test_tests_must_have_run
  test_shadow_logs_and_never_acts
  test_bounces_are_bounded
  test_unconfirmed_steer_is_not_counted
  test_unreadable_facts_never_bounce
  test_pr_check_hook
  test_proof_rider_on_ui_prs
  test_auto_records_pr
  test_watcher_runs_done_check on
  test_watcher_runs_done_check shadow
fi

# Real Git, network-free forge and native scout spawn with a fake terminal.
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"

A="$T/acceptance"
A_HOME="$A/home"
A_STATE="$A_HOME/state"
A_REPO="$A/repo"
A_ID=ship-accept
A_META="$A_STATE/$A_ID.meta"
A_STATUS="$A_STATE/$A_ID.status"
A_URL=https://github.com/acme/widget/pull/8
A_POLICY="$A_HOME/config/done-acceptance/$A_ID.json"
A_VERDICT="$ROOT/bin/fm-review-verdict.sh"
A_FAKE=$(make_spawn_fakebin "$A/tools" codex claude gh)
mkdir -p "$A_STATE" "$A_HOME/config/done-acceptance" "$A_HOME/data/$A_ID" "$A_HOME/projects"
touch "$A_STATE/.last-watcher-beat"

cat > "$A_FAKE/gh-axi" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 98
[ "${A_FORGE_UNREADABLE:-0}" = 0 ] || exit 4
case "$2" in
  /repos/acme/widget/pulls/8)
    body=$(jq -nr --arg url "$A_URL" --arg head "${A_LIVE_HEAD:-$A_HEAD}" \
      --arg branch "${A_LIVE_BRANCH:-fm/ship-accept}" --arg repo "${A_LIVE_REPO:-acme/widget}" '
      [$url,$repo,"dev","acme/widget",$branch,$head,"open",false] | @json | @base64
    ') ;;
  /repos/acme/widget/branches/dev)
    body=$(jq -nr --arg base "${A_LIVE_BASE:-$A_BASE}" '["dev",$base] | @json | @base64') ;;
  *) exit 98 ;;
esac
printf 'api_response:\n  body: %s\n  truncated: false\n' "$body"
STUB
chmod +x "$A_FAKE/gh-axi"

fm_git_init_commit "$A_REPO"
git -C "$A_REPO" checkout -qb dev || fail "cannot prepare acceptance base"
mkdir -p "$A_REPO/tests" "$A_REPO/src/"{__tests__,shop,App.Tests,cypress/e2e,e2e,packaging}
printf 'def test_contract():\n    assert actual() == 2\n' > "$A_REPO/tests/test_old.py"
printf 'test_check() { expect_result; }\ntest_check\n' > "$A_REPO/tests/contract.test.sh"
printf 'it("open", () => expect(state()).toBe("open"));\n' > "$A_REPO/src/__tests__/state.test.ts"
for runner_path in tests.py shop/tests.py test.js foo.tests.ts FooTest.java App.Tests/FooTests.cs \
  cypress/e2e/a.cy.ts e2e/login.ts conftest.py vitest.config.ts karma.conf.js .pytest.ini pytest.toml; do
  printf 'fixture entry\n' > "$A_REPO/src/$runner_path"
done
printf 'fn value() -> u8 { 1 }\n#[cfg(test)]\nmod tests { #[test] fn value_is_positive() { assert!(super::value() > 0); } }\n' \
  > "$A_REPO/src/lib.rs"
printf '[tool.pytest.ini_options]\ntestpaths = ["checks"]\n' > "$A_REPO/src/pyproject.toml"
printf '[tool:pytest]\npython_files = verify_*.py\n' > "$A_REPO/src/setup.cfg"
printf '[project]\nname = "fixture"\nversion = "1.0"\n' > "$A_REPO/src/packaging/pyproject.toml"
printf 'value = 1\n' > "$A_REPO/app.py"
git -C "$A_REPO" add . || fail "cannot stage acceptance base"
git -C "$A_REPO" commit -qm base || fail "cannot commit acceptance base"
fm_git_add_origin "$A_REPO" "$A/origin.git"
A_BASE=$(git -C "$A_REPO" rev-parse HEAD)
ln -s "$A_REPO" "$A/repo-link"
git clone --quiet --branch dev "$A/origin.git" "$A/pool" || fail "cannot initialize reviewer scratch"
printf -- '- repo [direct-PR] - fixture (added 2026-01-01)\n' > "$A_HOME/data/projects.md"
{
  printf '#!/usr/bin/env bash\n'
  printf 'real_git=%q\nforge_repo=%q\n' "$(command -v git)" "$A/origin.git"
  cat <<'STUB'
args=("$@")
if [[ "$1" != -C || "$2" != *.acceptance-git ]]; then
  exec "$real_git" "$@"
fi
for ((i=2; i<${#args[@]}; i++)); do
  [ "${args[i]}" = fetch ] || continue
  [ "${args[i+4]}" = https://github.com/acme/widget.git ] || exit 24
  if [ -f "${GH_CONFIG_DIR:-/nonexistent}/require-fixture-auth" ]; then
    cfg=("${args[@]:2:i-2}")
    git_credential() {
      printf 'protocol=https\nhost=%s\n\n' "$1" |
        "$real_git" -C "$2" "${cfg[@]}" credential fill 2>/dev/null
    }
    if git_credential example.invalid "$2" >/dev/null; then exit 25; fi
    reply=$(git_credential github.com "$2") || exit 26
    [[ "$reply" == *$'\nusername=fixture-reader\npassword=fixture-only' ]] || exit 27
    printf 'github.com only\n' >> "$GH_CONFIG_DIR/proof"
  fi
  exec "$real_git" -C "$2" -c fetch.fsckObjects=true fetch "$forge_repo" "${args[i+5]}" "${args[i+6]}"
done
exec "$real_git" "$@"
STUB
} > "$A_FAKE/git"
chmod +x "$A_FAKE/git"

mv "$A_FAKE/gh" "$A_FAKE/gh-fixture"
cat > "$A_FAKE/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$*" != 'auth git-credential get' ]; then
  exec "$(dirname "$0")/gh-fixture" "$@"
fi
request=$(cat)
[[ "$request" == $'protocol=https\nhost=github.com' ]] || exit 29
[ "${GH_PROMPT_DISABLED:-}" = 1 ] && [ -f "$GH_CONFIG_DIR/authorized" ] || exit 30
printf 'username=fixture-reader\npassword=fixture-only\n'
STUB
chmod +x "$A_FAKE/gh"

accept_cmd() {
  FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$A_HOME" PATH="$A_FAKE:$PATH" \
    A_HEAD="$A_HEAD" A_BASE="$A_BASE" A_URL="$A_URL" "$@"
}

accept_refused() {  # <reason> <command...>
  local reason=$1 result
  shift
  result=$(accept_cmd "$@" 2>&1) && fail "unexpected acceptance: $*"$'\n'"$result"
  assert_contains "$result" "$reason" "acceptance refusal should explain $reason"
}

accept_candidate() {
  if [ "${1:-}" != staged ]; then
    git -C "$A_REPO" add -A || fail "cannot stage candidate"
  fi
  git -C "$A_REPO" commit -qm candidate || fail "cannot commit candidate"
  A_HEAD=$(git -C "$A_REPO" rev-parse HEAD)
  git -C "$A_REPO" push --quiet "$A/origin.git" "$A_HEAD:refs/fixtures/$A_HEAD" || fail "cannot publish fixture objects"
  printf 'done [at=100]: PR %s head %s\n' "$A_URL" "$A_HEAD" > "$A_STATUS"
}

accept_reset() {
  git -C "$A_REPO" checkout -qf -B "fm/$A_ID" "$A_BASE" || fail "cannot reset candidate"
  fm_write_meta "$A_META" "kind=ship" "mode=direct-PR" "project=$A_REPO" \
    "worktree=$A_REPO" "branch=fm/$A_ID" "base_branch=dev" "spawn_gen=s100.200.300" \
    "harness=claude" "model=claude-sonnet-4-6" "yolo=off" \
    "builder_history=s100.200.300:claude:claude-sonnet-4-6"
  (umask 077; jq -n --arg base "$A_BASE" '
    {repo:"acme/widget",base_branch:"dev",base:$base,kind:"feature",
     allow:["app.py","tests/","src/"],tests:[],criteria:"The value is two."}
  ' > "$A_POLICY")
  printf 'value = 2\n' > "$A_REPO/app.py"
}

test_acceptance_private_fetch() {
  accept_reset
  accept_candidate
  local credentials="$A/credentials"
  mkdir -m 700 "$credentials"
  touch "$credentials/require-fixture-auth"
  GH_CONFIG_DIR="$A_REPO" accept_refused "outside worker-controlled paths" \
    "$SCRIPT" review-brief "$A_ID" "$A_URL" worker-credentials
  GH_CONFIG_DIR="$credentials" accept_refused "check supervisor GitHub credentials" \
    "$SCRIPT" review-brief "$A_ID" "$A_URL" needs-credentials
  assert_absent "$credentials/proof" "fetch unexpectedly authenticated"
  touch "$credentials/authorized"
  GH_CONFIG_DIR="$credentials" accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" private-source >/dev/null ||
    fail "trusted GitHub credential helper did not enable scoped fetch"
  assert_equals 'github.com only' "$(cat "$credentials/proof")" "fetch requires a credential only for GitHub.com"
  (umask 077; jq '.repo="Acme/Widget"' "$A_POLICY" > "$A/policy")
  mv "$A/policy" "$A_POLICY"
  accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" repository-case >/dev/null ||
    fail "a policy repository that differs from the forge only in letter case should match"
  A_LIVE_REPO=acme/gadget accept_refused "GitHub repository" "$SCRIPT" review-brief "$A_ID" "$A_URL" repository-name
  pass "exact source fetch requires scoped supervisor authentication when forge objects demand it"
}

pin_new_fixture_test() {
  local file=$1
  (umask 077; jq --arg path "$file" --arg sum "$(fixture_sha256 "$A_REPO/$file")" \
    '.new_tests[$path]=$sum' "$A_POLICY" > "$A/policy")
  mv "$A/policy" "$A_POLICY"
}

test_acceptance_test_locations() {
  local file marker=0
  for file in tests.py shop/tests.py test.js foo.tests.ts FooTest.java App.Tests/FooTests.cs \
    cypress/e2e/a.cy.ts e2e/login.ts conftest.py vitest.config.ts lib.rs; do
    accept_reset
    rm "$A_REPO/src/$file"
    accept_candidate
    marker=$((marker + 1))
    accept_refused "existing test entry changed: 'src/$file'" \
      "$SCRIPT" review-brief "$A_ID" "$A_URL" test-location-$marker
  done
  accept_reset
  printf 'fn application() {}\n' > "$A_REPO/src/lib.rs"
  accept_candidate
  accept_refused "existing test entry changed: 'src/lib.rs'" "$SCRIPT" review-brief "$A_ID" "$A_URL" in-file-test
  accept_reset
  printf '# Fixture collection configuration changed.\n' > "$A_REPO/src/conftest.py"
  accept_candidate
  accept_refused "existing test entry changed: 'src/conftest.py'" "$SCRIPT" review-brief "$A_ID" "$A_URL" collection-change
  pass "common test and runner paths and embedded Rust tests are protected by exact Git tree comparison"
}

test_acceptance_framework_config() {
  local file
  for file in karma.conf.js .pytest.ini pytest.toml pyproject.toml setup.cfg; do
    accept_reset
    rm "$A_REPO/src/$file"
    accept_candidate
    accept_refused "existing test entry changed: 'src/$file'" \
      "$SCRIPT" review-brief "$A_ID" "$A_URL" "runner-$file"
  done
  accept_reset
  printf '[project]\nname = "fixture"\nversion = "1.1"\n' > "$A_REPO/src/packaging/pyproject.toml"
  accept_candidate
  accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" packaging-change >/dev/null ||
    fail "an in-scope pyproject without pytest configuration should admit"

  accept_reset
  sed 's/u8 { 1 }/u8 { 2 }/' "$A_REPO/src/lib.rs" > "$A/inline.rs"
  mv "$A/inline.rs" "$A_REPO/src/lib.rs"
  accept_candidate
  accept_refused "existing test entry changed: 'src/lib.rs'" "$SCRIPT" review-brief "$A_ID" "$A_URL" inline-tests
  pass "default Karma and pytest configs are protected and standalone packaging edits still admit"
}

test_acceptance_pinned_test_signals() {
  accept_reset
  cat > "$A_REPO/tests/test_iterator.py" <<'PY'
def test_iterator(rows):
    def fallback():
        return "next"
    assert rows.skip(1).first() == fallback()

def test_nonempty():
    assert [*read_rows()]
    assert (*read_rows(),)
    assert {*read_rows()}
    assert {**read_counts()}
PY
  cat > "$A_REPO/tests/iterator.test.sh" <<'SH'
cat > "$temporary_fixture" <<'FIXTURE'
exit 0
FIXTURE
[ "$(selected_value)" = "$expected_value" ] || exit 1
test true = "$actual" || exit 1
assert true = "$actual" "reports true"
assert 1 -eq "$count" 'one record'
assert_true 1 "==" "$count"
assert true != "$actual"
assert_true "$(ready)" "true when ready"
assert_equals ready "$state" "ready state"
printf '%s\n' "usage: run.sh; exit 77 when tools are missing" 'or run.sh | skip-list; assert true' > "$usage"
find "$fixtures" -type f -exec test -s {} \; || exit 1
exit 0
SH
  cat > "$A_REPO/src/guide.test.js" <<'JS'
// Documentation example: test.skip("deferred", check);
/* Documentation example: test.only("focused", check); */
test("render test.skip() in the guide", () => expect(guide()).toContain("skip"));
test(`render test.only() in the guide`, () => expect(guide()).toContain("only"));
test(`render test.skip() for ${locale}`, () => expect(guide(locale)).toContain("skip"));
it(`${name} documents it.only("x")`, () => expect(guide()).toMatch(/don't `it.only(x)`/));
it(`lists ${rows.map((row) => `${row.id} test.todo(`)} // xit(`, () => expect(rows).toEqual(load({ a: { b: 1 } })));
it(`costs \${amount} \` test.skip(a)`, () => expect(price(`${amount}`)).toBe(`$5`));
test.each`
  input | output
  ${1}  | ${2}
`("doubles $input with test.skip() prose", ({ input, output }) => expect(double(input)).toBe(output));
JS
  pin_new_fixture_test tests/test_iterator.py
  pin_new_fixture_test tests/iterator.test.sh
  cat > "$A_REPO/src/guide_test.go" <<'GO'
package guide

// The old suite called t.Skip("offline") here; it now runs everywhere.
/* Neither t.SkipNow()
   nor t.Skipf("%s", reason) is needed. */
func TestGuide(t *testing.T) {
	quote, tick, escaped := '"', '`', '\''
	link := "https://example.test/*" // a t.Skip( in prose, with "quotes" and a ` tick
	want := "call \"t.Skip()\" to defer" + `
		t.SkipNow() // raw text
	`
	if got := guide(quote, tick, escaped, link); got != want {
		t.Fatalf("got %q; docs say t.Skip(reason)", got)
	}
}
GO
  pin_new_fixture_test src/guide.test.js
  pin_new_fixture_test src/guide_test.go
  accept_candidate
  accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" pinned-stubs >/dev/null ||
    fail "benign assertions, stubs and titles should be admitted when pinned"

  local id file reason source
  while IFS='|' read -r id file reason source; do
    accept_reset
    printf '%b\n' "$source" > "$A_REPO/$file"
    pin_new_fixture_test "$file"
    accept_candidate
    accept_refused "$reason" "$SCRIPT" review-brief "$A_ID" "$A_URL" "$id"
  done <<'CASES'
conditional-js|src/iterator.test.js|added skip|it.skipIf(environment)("sample", check);
focused-js|src/iterator.test.js|added skip|test.only("sample", check);
focused-concurrent-js|src/iterator.test.js|added skip|test.concurrent.only("sample", check);
commented-call-js|src/iterator.test.js|added skip|test /* note */ .skip("sample", check);
literal-js|src/iterator.test.js|added trivial assertion|it("sample", () => expect("ready").toEqual("ready"));
after-title-js|src/iterator.test.js|added skip|it(`a ${x} b`, check);\ntest.skip("later", check);\nit(`c`, check);
nested-title-js|src/iterator.test.js|added skip|it(`a ${ids.map((id) => `${id}!`)} ${fmt({ a: { b: 1 } })}`, check);\nit.only("later", check);\nit(`c ${y}`, check);
title-own-call-js|src/iterator.test.js|added skip|test.skip(`a ${x} b`, check);
each-table-js|src/iterator.test.js|added skip|test.skip.each`\na\n${1}\n`("case $a", check);
between-titles-js|src/iterator.test.js|added trivial assertion|it(`a ${x}`, () => expect(1).toBe(1));\nit(`b`, check);
in-interpolation-js|src/iterator.test.js|added skip|it("a", () => use(`${it.only("b", check)}`));
pattern-backtick-js|src/iterator.test.js|added skip|expect(text()).toMatch(/`/);\ntest.skip(`later ${x}`, check);
unpaired-backtick-js|src/iterator.test.js|added skip|const node = <p>`</p>;\ntest.skip("later", check);\nit(`a ${x}`, check);
message-shell|tests/iterator.test.sh|added trivial assertion|assert_true true "saves the record"
message-separator-shell|tests/iterator.test.sh|added trivial assertion|assert 1 'saves; then reloads'
message-variable-shell|tests/iterator.test.sh|added trivial assertion|assert true "$message" # note
same-operands-shell|tests/iterator.test.sh|added trivial assertion|assert 1 -eq 1 "one record"
literal-list-python|tests/test_iterator.py|added trivial assertion|assert [*read_rows(), 1]
literal-dict-python|tests/test_iterator.py|added trivial assertion|assert {**read_counts(), "key": 1}
after-quoted-shell|tests/iterator.test.sh|added skip|printf "usage; see docs"; exit 77; printf 'done'
between-quoted-shell|tests/iterator.test.sh|added skip|run 'a;b' && skip "later"
substitution-shell|tests/iterator.test.sh|added skip|value="$(load "a"; exit 77)"
evaluated-shell|tests/iterator.test.sh|added skip|eval "load; exit 77"
multiline-shell|tests/iterator.test.sh|added skip|value='first\nlast'; exit 77; run 'b'
literal-command-shell|tests/iterator.test.sh|added trivial assertion|test true # standalone check
go-skip|src/iterator_test.go|added skip|package iterator\nfunc TestExample(t *testing.T) { t.Skip("fixture") }
after-prose-go|src/iterator_test.go|added skip|package iterator\n// t.Skip is not needed\nfunc TestExample(t *testing.T) {\n\tt.SkipNow()\n}
after-literals-go|src/iterator_test.go|added skip|package iterator\nfunc TestExample(t *testing.T) { use("https://a/*", '"', '`'); t.Skipf("fixture %d", 1) }
after-raw-go|src/iterator_test.go|added skip|package iterator\nfunc TestExample(t *testing.T) { use(`"\\\\`); t.Skip() }
commented-call-go|src/iterator_test.go|added skip|package iterator\nfunc TestExample(t *testing.T) { t./* note */Skip("fixture") }
unterminated-go|src/iterator_test.go|added skip|package iterator\nfunc TestExample(t *testing.T) { t.Skip() }\n/* open
unittest-skip|tests/test_iterator.py|added skip|from unittest import skipIf as skip_unavailable\n@skip_unavailable(False, "fixture")\ndef test_iterator():\n    assert selected() == expected()
early-shell|tests/iterator.test.sh|added early-exit marker|exit 0\nassert_value
CASES
  pass "pinned tests permit benign stubs and refuse recognized skip, focus and trivial assertions"
}

test_acceptance_tamper() {
  accept_reset
  git -C "$A_REPO" rm -q tests/test_old.py || fail "cannot delete fixture test"
  accept_candidate
  accept_refused "existing test entry changed" "$SCRIPT" review-brief "$A_ID" "$A_URL" deletion

  accept_reset
  git -C "$A_REPO" mv tests/test_old.py tests/test_renamed.py || fail "cannot rename fixture test"
  accept_candidate
  accept_refused "existing test entry changed" "$SCRIPT" review-brief "$A_ID" "$A_URL" rename

  accept_reset
  printf 'def test_contract():\n    actual()\n' > "$A_REPO/tests/test_old.py"
  accept_candidate
  accept_refused "existing test entry changed" "$SCRIPT" review-brief "$A_ID" "$A_URL" assertion

  accept_reset
  printf '@pytest.mark.skip(reason="fixture")\ndef test_another():\n    assert value() == 2\n' > "$A_REPO/tests/test_new.py"
  accept_candidate
  accept_refused "added skip" "$SCRIPT" review-brief "$A_ID" "$A_URL" skip

  accept_reset
  printf 'def test_another():\n    assert True\n' > "$A_REPO/tests/test_new.py"
  accept_candidate
  accept_refused "added trivial assertion" "$SCRIPT" review-brief "$A_ID" "$A_URL" tautology

  accept_reset
  printf 'test_value() {\n  test 1 = 1\n}\n' > "$A_REPO/tests/value.test.sh"
  accept_candidate
  accept_refused "added trivial assertion" "$SCRIPT" review-brief "$A_ID" "$A_URL" shell-tautology

  accept_reset
  printf 'def helper():\n    assert actual() == 2\n' > "$A_REPO/tests/test_old.py"
  accept_candidate
  accept_refused "existing test entry changed" "$SCRIPT" review-brief "$A_ID" "$A_URL" test-removal

  accept_reset
  printf 'test_check() { expect_result; }\n' > "$A_REPO/tests/contract.test.sh"
  accept_candidate
  accept_refused "existing test entry changed: 'tests/contract.test.sh'" "$SCRIPT" review-brief "$A_ID" "$A_URL" shell-call

  accept_reset
  : > "$A_REPO/src/__tests__/state.test.ts"
  accept_candidate
  accept_refused "existing test entry changed: 'src/__tests__/state.test.ts'" "$SCRIPT" review-brief "$A_ID" "$A_URL" typescript

  accept_reset
  printf '__test__ = False\n' > "$A_REPO/tests/test_new.py"
  accept_candidate
  accept_refused "added collection override" "$SCRIPT" review-brief "$A_ID" "$A_URL" collection

  accept_reset
  printf 'def test_other():\n    return\n' > "$A_REPO/tests/test_new.py"
  accept_candidate
  accept_refused "added early-return marker" "$SCRIPT" review-brief "$A_ID" "$A_URL" early-return

  accept_reset
  printf 'it("state", () => expect(state()).toBe("ready"));\n' > "$A_REPO/src/__tests__/added.js"
  accept_candidate
  accept_refused "new test has no matching supervisor byte pin" "$SCRIPT" review-brief "$A_ID" "$A_URL" unapproved-test
  (umask 077; jq --arg sum "$(fixture_sha256 "$A_REPO/src/__tests__/added.js")" \
    '.new_tests={"src/__tests__/added.js":$sum}' "$A_POLICY" > "$A/policy")
  mv "$A/policy" "$A_POLICY"
  accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" approved-test >/dev/null ||
    fail "trusted exact byte pin should allow a new test format"

  accept_reset
  printf 'it.skip("state", () => expect(state()).toBe("ready"));\n' > "$A_REPO/src/__tests__/added.js"
  accept_candidate
  accept_refused "added skip" "$SCRIPT" review-brief "$A_ID" "$A_URL" skipped-javascript

  accept_reset
  git -C "$A_REPO" mv app.py moved.py || fail "cannot rename fixture source"
  accept_candidate
  accept_refused "out-of-scope change" "$SCRIPT" review-brief "$A_ID" "$A_URL" path

  accept_reset
  printf 'anything goes\n' > "$A_REPO/acceptance-policy.json"
  printf '## Files in scope\n- **\n' > "$A_HOME/data/$A_ID/brief.md"
  accept_candidate
  accept_refused "out-of-scope change" "$SCRIPT" review-brief "$A_ID" "$A_URL" policy

  accept_reset
  git -C "$A_REPO" add app.py || fail "cannot stage allowed edit"
  git -C "$A_REPO" update-index --add --cacheinfo "160000,$A_BASE,vendor" || fail "cannot stage Git link"
  accept_candidate staged
  git -C "$A_REPO" config diff.ignoreSubmodules all
  accept_refused "out-of-scope change: 'vendor'" "$SCRIPT" review-brief "$A_ID" "$A_URL" hidden-submodule
  git -C "$A_REPO" config --unset diff.ignoreSubmodules
  pass "exact diff rejects test and assertion deletion, skips, tautologies, renames and worker scope edits"
}

accept_add_regression() {
  cat > "$A_REPO/tests/test_regression.py" <<PY
import subprocess
import sys
import unittest

class Regression(unittest.TestCase):
    def test_value(self):
        observed = subprocess.check_output(
            [sys.executable, "-c", "from app import value; print(value)"], text=True
        )
        self.assertEqual(int(observed), $1)
PY
  chmod +x "$A_REPO/tests/test_regression.py"
  accept_regression_policy
}

accept_regression_policy() {
  local test_sha runner_sha
  test_sha=$(fixture_sha256 "$A_REPO/tests/test_regression.py")
  runner_sha=$(fixture_sha256 "$A_HOME/data/$A_ID/regression")
  (umask 077; jq --arg test "$test_sha" --arg runner "$runner_sha" '
    .kind = "bug" | .regression = {path:"tests/test_regression.py",test_sha256:$test,runner_sha256:$runner}
  ' "$A_POLICY" > "$A/policy")
  mv "$A/policy" "$A_POLICY"
}

fixture_sha256() {
  python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$1"
}

test_acceptance_regression() {
  local result
  if [ "$(uname -s)" != Linux ] || ! command -v bwrap >/dev/null; then
    printf '# regression execution requires Linux bubblewrap\n'
    return
  fi
  if ! bwrap --unshare-all --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind-try /lib64 /lib64 \
    -- /usr/bin/true >/dev/null 2>&1; then
    printf '# regression execution requires available bubblewrap namespaces\n'
    return
  fi
  accept_reset
  (umask 077; cat > "$A_HOME/data/$A_ID/regression" <<'PY'
#!/usr/bin/python3 -I
import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest

if Path("/home").exists() or os.environ.get("FM_HOME") or not os.access(sys.argv[1], os.X_OK):
    sys.exit(13)
spec = importlib.util.spec_from_file_location("regression", sys.argv[1])
module = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(module)
except (Exception, SystemExit):
    sys.exit(12)
suite = unittest.defaultTestLoader.loadTestsFromModule(module)
if suite.countTestCases() != 1:
    sys.exit(12)
result = unittest.TestResult()
suite.run(result)
if result.testsRun != 1 or result.skipped or result.errors:
    sys.exit(12)
def report(outcome):
    print(json.dumps({"test": sys.argv[1], "tests_run": result.testsRun, "result": outcome}))

if len(result.failures) == 1 and result.failures[0][1].endswith("AssertionError: 1 != 2\n"):
    report("expected-failure")
    sys.exit(10)
if result.wasSuccessful():
    report("pass")
    sys.exit(0)
sys.exit(12)
PY
  )
  accept_add_regression 2
  accept_candidate
  result=$(accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" bug-scout 2>&1) ||
    fail "isolated base-red/head-green regression did not pass: $result"
  assert_equals '10:0' "$(jq -r '.checks.regression | "\(.base_exit):\(.head_exit)"' "$A_STATE/bug-scout.refute.json")" \
    "trusted runner must observe the expected failure before and success after"
  assert_equals '1:expected-failure:1:pass' "$(jq -r '.checks.regression |
    "\(.base_execution.tests_run):\(.base_execution.result):\(.head_execution.tests_run):\(.head_execution.result)"' \
    "$A_STATE/bug-scout.refute.json")" "both legs must report the selected test ran"

  accept_reset
  printf '# Fixture module with a standard library module name.\n' > "$A_REPO/subprocess.py"
  (umask 077; jq '.allow += ["subprocess.py"]' "$A_POLICY" > "$A/policy")
  mv "$A/policy" "$A_POLICY"
  accept_add_regression 2
  git -C "$A_REPO" restore app.py
  accept_candidate
  accept_refused "head regression did not pass (exit 10)" \
    "$SCRIPT" review-brief "$A_ID" "$A_URL" observer-import
  printf 'value = 2\n' > "$A_REPO/app.py"
  accept_candidate
  accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" observer-import-fixed >/dev/null ||
    fail "trusted observer imports should be independent of the candidate's module names"

  accept_reset
  accept_add_regression 1
  accept_candidate
  accept_refused "already passes" "$SCRIPT" review-brief "$A_ID" "$A_URL" existing-pass

  accept_reset
  accept_add_regression 2
  rm "$A_REPO/tests/test_regression.py"
  accept_candidate
  accept_refused "regression test must be new" "$SCRIPT" review-brief "$A_ID" "$A_URL" missing-test

  accept_reset
  accept_add_regression 2
  printf 'import missing_fixture_dependency\n' >> "$A_REPO/tests/test_regression.py"
  accept_regression_policy
  accept_candidate
  accept_refused "base regression did not reach the expected failure (exit 12)" \
    "$SCRIPT" review-brief "$A_ID" "$A_URL" base-collection-error

  accept_reset
  accept_add_regression 2
  printf 'import missing_fixture_dependency\n' > "$A_REPO/app.py"
  accept_candidate
  accept_refused "head regression did not pass (exit 12)" "$SCRIPT" review-brief "$A_ID" "$A_URL" collection-error

  accept_reset
  accept_add_regression 2
  printf 'import unittest\nraise unittest.SkipTest("fixture")\n' > "$A_REPO/app.py"
  accept_candidate
  accept_refused "head regression did not pass (exit 12)" "$SCRIPT" review-brief "$A_ID" "$A_URL" skipped-regression

  accept_reset
  accept_add_regression 2
  # The static patterns do not resolve this spelling, so only the observer can
  # see that the framework skipped the test.
  cat >> "$A_REPO/tests/test_regression.py" <<'PY'

    def setUp(self):
        import unittest.case as framework
        if b"2" in subprocess.check_output([sys.executable, "-c", "from app import value; print(value)"]):
            raise framework.SkipTest("fixture")
PY
  accept_regression_policy
  accept_candidate
  accept_refused "head regression did not pass (exit 12)" "$SCRIPT" review-brief "$A_ID" "$A_URL" observed-skip

  accept_reset
  accept_add_regression 2
  printf 'value = 3\n' > "$A_REPO/app.py"
  accept_candidate
  accept_refused "head regression did not pass (exit 12)" "$SCRIPT" review-brief "$A_ID" "$A_URL" still-failing

  accept_reset
  cat > "$A_HOME/data/$A_ID/regression" <<'PY'
#!/usr/bin/python3
import json
from pathlib import Path
import sys

# Deliberately incomplete end-to-end runner fixture: simulates the base
# observation but supplies no completed-test record when exiting successfully.
if Path("app.py").read_text() == "value = 1\n":
    print(json.dumps({"test": sys.argv[1], "tests_run": 1, "result": "expected-failure"}))
    sys.exit(10)
sys.exit(0)
PY
  accept_add_regression 2
  accept_candidate
  accept_refused "head regression did not report test execution evidence" \
    "$SCRIPT" review-brief "$A_ID" "$A_URL" no-execution-proof
  pass "same test fails at the pinned base and passes at the candidate; missing, passing-before, broken, skipped and failing tests refuse"
}

test_acceptance_entry_points() {
  local result ident endpoint park scout=refute-scout
  accept_reset
  accept_candidate
  printf 'Tests passed. Exact-head independent reviewer says merge.\n' > "$A_HOME/data/$A_ID/report.md"
  accept_cmd "$A_VERDICT" "$A_URL" "$A_HEAD" merge "legacy reviewer" || fail "could not write legacy verdict"
  endpoint=$(wc -c < "$A_STATUS" | tr -d ' ')
  ident=$(bash -c '. "$1"; _fm_open_decisions_file_ident "$2"' fixture "$ROOT/bin/fm-classify-lib.sh" "$A_STATUS")
  accept_cmd "$ROOT/bin/fm-worker-done.sh" "$A_ID" "$endpoint" "$ident" || fail "worker intake failed"
  assert_no_grep 'pr=' "$A_META" "worker done stamped protected readiness"
  accept_cmd "$SCRIPT" --auto "$A_ID" "$A_URL" || fail "legacy auto checklist failed"
  assert_no_grep 'pr=' "$A_META" "legacy auto checklist stamped protected readiness"

  printf 'pr=%s\npr_head=%s\n' "$A_URL" "$A_HEAD" >> "$A_META"
  accept_refused "accepted.json" "$PR_CHECK" "$A_ID" "$A_URL"
  FM_PR_CHECK_MERGE=1 accept_refused "accepted.json" "$PR_CHECK" "$A_ID" "$A_URL"
  [ ! -e "$A_STATE/$A_ID.check.sh" ] || fail "unaccepted candidate published a poll"
  accept_refused "missing passing fresh-context review" "$SCRIPT" accept "$A_ID" "$A_URL"
  [ ! -e "$A_STATE/$A_ID.accepted.json" ] || fail "worker evidence was accepted"
  accept_refused "exact-head done candidate" "$SCRIPT" review-brief "$A_ID" https://github.com/acme/widget/pull/7 other-pr

  result=$(accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" "$scout" 2>&1) || fail "review brief refused: $result"
  assert_grep " -C $A_STATE/$A_ID.acceptance-git diff " "$result" \
    "review must use the supervisor's tree even when the worker reports both pins locally"
  accept_refused "provider absent from the builder lineage" "$SCRIPT" spawn-review "$scout" scout 0 claude claude-sonnet-4-6 "$A_REPO" "$result"
  accept_refused "fresh native scout" "$SCRIPT" spawn-review "$scout" scout 1 codex gpt-5.6-sol "$A_REPO" "$result"
  accept_refused "project or brief does not match" "$SCRIPT" spawn-review "$scout" scout 0 codex gpt-5.6-sol "$A/pool" "$result"
  accept_cmd "$SCRIPT" spawn-review "$scout" scout 0 codex gpt-5.6-sol "$A/repo-link" "$result" >/dev/null ||
    fail "a symlink to the candidate's own project should name the same project"
  accept_refused "$scout.meta" "$A_VERDICT" refute "$A_ID" "$scout" "$A_HEAD"

  result=$(A_HEAD="$A_HEAD" A_BASE="$A_BASE" A_URL="$A_URL" \
    fm_test_run_spawn "$A_HOME" "$A/pool" "$A_FAKE" "$scout" "$A_REPO" \
    --scout --backend tmux --harness codex --model gpt-5.6-sol) || fail "native scout did not launch: $result"
  printf 'Checked the criterion against app.py. No blocker.\n' > "$A_HOME/data/$scout/report.md"
  printf 'done: Refute %s %s merge\n' "$A_BASE" "$A_BASE" > "$A_STATE/$scout.status"
  accept_refused "scout did not report" "$A_VERDICT" refute "$A_ID" "$scout" "$A_HEAD"
  printf 'done: Refute %s %s merge\n' "$A_BASE" "$A_HEAD" > "$A_STATE/$scout.status"
  accept_refused "did not sign off" "$A_VERDICT" refute "$A_ID" "$scout" "$A_BASE"
  accept_refused "supervisor operations" env FM_TASK_ID="$scout" "$A_VERDICT" refute "$A_ID" "$scout" "$A_HEAD"
  accept_cmd "$A_VERDICT" refute "$A_ID" "$scout" "$A_HEAD" || fail "supervisor could not record scout result"
  assert_grep 'yolo=off' "$A_META" "recording a refute verdict changed merge authority"
  accept_refused "accepted.json" "$PR_CHECK" "$A_ID" "$A_URL"

  result=$(accept_cmd "$SCRIPT" accept "$A_ID" "$A_URL") || fail "exact-head acceptance failed"
  assert_equals "$A_HEAD" "$result" "acceptance wrote a different head"
  accept_refused "valid fresh scout ID" "$SCRIPT" review-brief "$A_ID" "$A_URL"
  A_FORGE_UNREADABLE=1 accept_cmd "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD" >/dev/null ||
    fail "offline status read contacted the forge"
  A_FORGE_UNREADABLE=1 accept_refused "done acceptance" "$PR_CHECK" "$A_ID" "$A_URL"
  A_FORGE_UNREADABLE=1 accept_refused "temporary forge read unavailable" "$SCRIPT" assert "$A_ID" "$A_URL"
  A_LIVE_HEAD=$A_BASE accept_refused "live GitHub head" "$PR_CHECK" "$A_ID" "$A_URL"
  A_LIVE_BASE=$A_HEAD accept_refused "live GitHub target branch" "$PR_CHECK" "$A_ID" "$A_URL"
  A_LIVE_BRANCH=fm/unrelated accept_refused "task branch" "$PR_CHECK" "$A_ID" "$A_URL"
  A_LIVE_REPO=other/widget accept_refused "GitHub repository" "$PR_CHECK" "$A_ID" "$A_URL"
  accept_cmd "$PR_CHECK" "$A_ID" "$A_URL" || fail "accepted candidate did not arm the ordinary PR check"
  [ -f "$A_STATE/$A_ID.check.sh" ] || fail "accepted candidate has no PR poll"
  assert_grep "pr_head=$A_HEAD" "$A_META" "registered the wrong PR head"

  cp "$A_STATUS" "$A/candidate.status"
  park="paused [at=101]: parked on review: PR $A_URL clean at ${A_HEAD:0:12}; agent stopped, relaunches on review activity"
  printf '%s\n' "$park" >> "$A_STATUS"
  accept_refused "no current exact-head done candidate" "$SCRIPT" assert "$A_ID" "$A_URL"
  cat "$A/candidate.status" > "$A_STATUS"
  FM_HOME="$A_HOME" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1"
    rc=0
    fm_wake_status_append_self_announced "$2" "$3" "$4" \
      "blocked [key=paused-overdue-$5]: paused 120s, wait overdue - decide or release" \
      "resolved [key=paused-overdue-$5]: worker pause changed" || rc=$?
    [ "$rc" -le 1 ]
  ' fixture "$ROOT/bin/fm-wake-lib.sh" "$A_STATE" "$A_STATUS" "$park" "$A_ID" ||
    fail "could not append supervisor park and watcher annotations"
  assert_present "$A_STATE/.$A_ID.home-appends" "home append provenance was not recorded"
  accept_cmd "$SCRIPT" assert "$A_ID" "$A_URL" "$A_HEAD" >/dev/null ||
    fail "supervisor operational annotations lost exact-head acceptance"
  accept_cmd "$PR_CHECK" "$A_ID" "$A_URL" || fail "accepted parked candidate lost PR admission"
  A_LIVE_BASE=$A_HEAD accept_refused "live GitHub target branch" "$SCRIPT" assert "$A_ID" "$A_URL"
  cp "$A_META" "$A/candidate.meta"
  sed 's/s100\.200\.300/s101.200.300/g' "$A/candidate.meta" > "$A_META"
  accept_refused "accepted evidence no longer matches" "$SCRIPT" assert "$A_ID" "$A_URL"
  cat "$A/candidate.meta" > "$A_META"
  cp "$A_STATUS" "$A/parked.status"
  printf 'working: reconsidering the fixture\n' >> "$A_STATUS"
  accept_refused "no current exact-head done candidate" "$SCRIPT" assert "$A_ID" "$A_URL"
  cat "$A/candidate.status" >> "$A_STATUS"
  accept_refused "accepted evidence no longer matches" "$SCRIPT" assert "$A_ID" "$A_URL"
  cat "$A/parked.status" > "$A_STATUS"

  mv "$A_STATE/review-verdicts.jsonl" "$A_STATE/review-verdicts.saved"
  ln -s "$A_STATE/review-verdicts.saved" "$A_STATE/review-verdicts.jsonl"
  accept_refused "done acceptance" "$SCRIPT" passing "$A_ID" "$A_URL"
  rm "$A_STATE/review-verdicts.jsonl"
  mv "$A_STATE/review-verdicts.saved" "$A_STATE/review-verdicts.jsonl"

  printf 'done: Refute %s %s fix\n' "$A_BASE" "$A_HEAD" > "$A_STATE/$scout.status"
  accept_cmd "$A_VERDICT" refute "$A_ID" "$scout" "$A_HEAD" || fail "could not record exact-head blocker"
  accept_refused "missing passing fresh-context review" "$PR_CHECK" "$A_ID" "$A_URL"
  if accept_cmd "$A_VERDICT" passing "$A_URL" "$A_HEAD"; then
    fail "a refute fix must block the legacy verdict reader"
  fi
  printf 'value = 3\n' > "$A_REPO/app.py"
  accept_candidate
  accept_refused "accepted evidence no longer matches" "$PR_CHECK" "$A_ID" "$A_URL"
  accept_refused "missing passing fresh-context review" "$SCRIPT" accept "$A_ID" "$A_URL"
  rm "$A_POLICY"
  accept_refused "$A_ID.json" "$PR_CHECK" "$A_ID" "$A_URL"
  pass "ordinary PR registration requires a current exact candidate, native independent review and explicit supervisor acceptance"
}

# Synthetic review records only: the scout metadata, report and status are
# ordinary files, and nothing is accepted, registered or launched.
prepare_review_record() {  # <scout> <report> <merge|fix> [project]
  local scout=$1
  mkdir -p "$A_HOME/data/$scout"
  accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" "$scout" >/dev/null || fail "could not prepare review $scout"
  fm_write_meta "$A_STATE/$scout.meta" "kind=scout" "spawn_gen=s200.300.$RANDOM" "project=${4:-$A_REPO}" \
    "harness=codex" "model=gpt-5.6-sol" "refute_context=$(fixture_sha256 "$A_STATE/$scout.refute.json")"
  printf '%s\n' "$2" > "$A_HOME/data/$scout/report.md"
  report_review "$scout" "$3"
}

report_review() {  # <scout> <merge|fix>
  printf 'done [at=%s]: Refute %s %s %s\n' "$RANDOM" "$A_BASE" "$A_HEAD" "$2" >> "$A_STATE/$1.status"
}

record_review() {  # <scout>
  accept_cmd "$A_VERDICT" refute "$A_ID" "$1" "$A_HEAD" 2> "$A/record.err" ||
    fail "supervisor could not record review $1: $(cat "$A/record.err")"
}

# The journal's last row for this candidate, as <reviewer>:<verdict>.
effective_review() { tail -n 1 "$A_STATE/review-verdicts.jsonl" | jq -r '"\(.reviewer):\(.verdict)"'; }

# Retrying <scout> must leave every journal byte, so also each ordering time.
assert_review_retry() {  # <scout> <label>
  cp "$A_STATE/review-verdicts.jsonl" "$A/journal"
  record_review "$1"
  cmp -s "$A/journal" "$A_STATE/review-verdicts.jsonl" ||
    fail "$2: a retry changed the journal"$'\n'"$(diff "$A/journal" "$A_STATE/review-verdicts.jsonl")"
  assert_grep "already recorded" "$A/record.err" "$2: a retry should say the review was already recorded"
}

test_review_event_retry() {
  local journal="$A_STATE/review-verdicts.jsonl" pid pids='' n
  accept_reset
  printf 'value = 31\n' > "$A_REPO/app.py"
  accept_candidate
  rm -f "$journal" "$A_STATE/$A_ID.accepted.json"

  prepare_review_record first 'Checked app.py. No blocker.' merge
  record_review first
  assert_review_retry first "latest review"

  # A later ordinary fix stays the effective decision.
  accept_cmd "$A_VERDICT" "$A_URL" "$A_HEAD" fix "second reviewer" || fail "could not record the later fix"
  assert_review_retry first "before a later fix"
  assert_equals "second reviewer:fix" "$(effective_review)" "a retry displaced a later fix"
  report_review first merge
  assert_review_retry first "a repeated merge report with no new evidence"
  accept_refused "missing passing fresh-context review" "$SCRIPT" accept "$A_ID" "$A_URL"
  assert_absent "$A_STATE/$A_ID.accepted.json" "a retried review must not accept the candidate"

  # A fresh report from the same scout and a fresh scout are both new evidence.
  printf 'Rechecked app.py after the fix verdict. No blocker.\n' > "$A_HOME/data/first/report.md"
  report_review first merge
  record_review first
  assert_equals first:merge "$(effective_review)" "a revised report is new evidence"
  prepare_review_record second 'Found a blocker in app.py.' fix "$A/pool"
  accept_refused "matching fresh native scout dispatch" "$A_VERDICT" refute "$A_ID" second "$A_HEAD"
  sed "s|^project=.*|project=$A/repo-link|" "$A_STATE/second.meta" > "$A/second.meta"
  mv "$A/second.meta" "$A_STATE/second.meta"
  record_review second
  assert_equals second:fix "$(effective_review)" "a fresh scout is new evidence"
  assert_review_retry first "before a later refute fix"
  assert_equals second:fix "$(effective_review)" "a retry displaced a later refute fix"

  # A retried fix cannot displace a later merge, but a newly reported one can.
  # Concurrent recordings of one review share the writer lock and append one row.
  prepare_review_record third 'Blocker does not reproduce.' merge
  for n in 1 2 3 4; do
    accept_cmd "$A_VERDICT" refute "$A_ID" third "$A_HEAD" 2> "$A/concurrent.$n" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || fail "a concurrent recording failed"; done
  assert_equals 1 "$(grep -c '"reviewer":"third"' "$journal")" "concurrent recordings of one review must append one row"
  assert_review_retry second "before a later merge"
  assert_equals third:merge "$(effective_review)" "a retried fix displaced a later merge"
  report_review second fix
  record_review second
  assert_equals second:fix "$(effective_review)" "a newly reported fix must block again"
  assert_review_retry second "newly reported fix"

  # Ordinary verdicts carry no event identity, so each one is still appended.
  accept_cmd "$A_VERDICT" "$A_URL" "$A_HEAD" fix "second reviewer" || fail "could not record an ordinary fix again"
  assert_equals "second reviewer:fix" "$(effective_review)" "an ordinary fix must still append"

  # A row recorded before events were kept reads the same and still identifies its review.
  jq -c 'if .refute then del(.refute.event) else . end' "$journal" > "$A/journal"
  cat "$A/journal" > "$journal"
  assert_review_retry third "row without an event"
  cp "$journal" "$A/journal"
  printf 'not a verdict\n' >> "$journal"
  accept_refused "done acceptance" "$A_VERDICT" refute "$A_ID" first "$A_HEAD"
  cat "$A/journal" > "$journal"
  pass "retrying a recorded review appends nothing and a later decision on the same head stays effective"
}

test_acceptance_inspects_pipeline_objects() {
  local result cache="$A_STATE/$A_ID.acceptance-git"
  accept_reset
  printf 'value = 23\n' > "$A_REPO/app.py"
  accept_candidate
  if git -C "$A/pool" cat-file -e "$A_HEAD" 2>/dev/null; then
    fail "test must start with the pipeline head absent from the worker copy"
  fi
  [ -d "$cache" ] || fail "test must start with an existing supervisor cache"
  if git -C "$cache" cat-file -e "$A_HEAD" 2>/dev/null; then
    fail "test must start with the pipeline head absent from the supervisor cache"
  fi
  sed "s|^worktree=.*|worktree=$A/pool|;s/^mode=.*/mode=no-mistakes/" "$A_META" > "$A/pipeline.meta"
  mv "$A/pipeline.meta" "$A_META"
  printf 'done: PR %s checks green head %s\n' "$A_URL" "$A_HEAD" > "$A_STATUS"
  result=$(accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" fetched-scout 2>&1) ||
    fail "could not prepare review of fetched pipeline objects: $result"
  assert_grep " -C $cache diff " "$result" "review should use the exact fetched objects"
  assert_equals commit "$(git -C "$cache" cat-file -t "$A_HEAD")" "review populated the supervisor cache"
  if git -C "$A/pool" cat-file -e "$A_HEAD" 2>/dev/null; then
    fail "fallback fetch wrote objects into the worker copy"
  fi
  pass "pipeline objects missing from the worker copy use a private pinned forge fetch"
}

test_acceptance_requires_complete_builder_lineage() {
  local brief
  accept_reset
  accept_candidate
  sed -e 's/^spawn_gen=.*/spawn_gen=s101.200.301/' -e 's/^harness=.*/harness=codex/' \
    -e 's/^model=.*/model=gpt-5.6-sol/' -e 's/^builder_history=.*/&:INVALID/' "$A_META" > "$A/lineage.meta"
  mv "$A/lineage.meta" "$A_META"
  accept_refused "builder lineage" "$SCRIPT" review-brief "$A_ID" "$A_URL" incomplete-history
  sed 's/:INVALID$/,s101.200.301:codex:gpt-5.6-sol/' "$A_META" > "$A/lineage.meta"
  mv "$A/lineage.meta" "$A_META"
  brief=$(accept_cmd "$SCRIPT" review-brief "$A_ID" "$A_URL" prior-model) || fail "known lineage should be readable"
  accept_refused "provider absent from the builder lineage" "$SCRIPT" spawn-review prior-model scout 0 \
    claude claude-sonnet-4-6 "$A_REPO" "$brief"
  accept_refused "provider absent from the builder lineage" "$SCRIPT" spawn-review prior-model scout 0 \
    codex gpt-5.6-sol "$A_REPO" "$brief"
  pass "review dispatch excludes every recorded builder provider"
}

if [ "${1:-}" = --framework-paths ]; then
  test_acceptance_test_locations
  test_acceptance_framework_config
  test_acceptance_pinned_test_signals
  exit
fi

if [ "${1:-}" = --review-events ]; then
  test_review_event_retry
  exit
fi

test_acceptance_private_fetch
test_acceptance_tamper
test_acceptance_test_locations
test_acceptance_framework_config
test_acceptance_pinned_test_signals
test_acceptance_regression
test_acceptance_entry_points
test_review_event_retry
test_acceptance_inspects_pipeline_objects
test_acceptance_requires_complete_builder_lineage
