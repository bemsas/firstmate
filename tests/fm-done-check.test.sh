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
  rm -f "$HOME_DIR/data/task-a/"* "$HOME_DIR/config/done-check" "$HOME_DIR/state/task-a.done-check" \
    "$HOME_DIR/state/done-check.log" "$SEND_LOG" "$HOME_DIR/state/task-a.check.sh"
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

test_auto_records_pr
test_watcher_runs_done_check on
test_watcher_runs_done_check shadow
