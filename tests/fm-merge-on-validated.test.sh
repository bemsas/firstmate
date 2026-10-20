#!/usr/bin/env bash
# Tests for bin/fm-merge-on-validated.sh, the opt-in hook that merges a
# validated dev pull request in code instead of waiting for a supervisor wake.
#
# Every refusal reason the standing dev-merge test can give has its own case, so
# a change that loosens one condition fails exactly that case. The forge is a
# fake `gh` that serves canned JSON from the case directory, so no case ever
# touches a real repository. Live-mode cases run the script from a bin/ made of
# symlinks with a recording stand-in for fm-pr-merge.sh, which proves the hook
# calls the guarded entrypoint with exactly a task and a URL and never reaches
# a lower-level forge merge itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-merge-on-validated.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-on-validated)

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
URL=https://github.com/example/repo/pull/42
OTHER_URL=https://github.com/example/repo/pull/43

# make_case <name>: a home with a registered secondmate (vm-mate) whose status
# log already holds one old validated line, a yolo ship task that records the
# pull request, a fake gh serving a clean dev pull request, and a dry-run
# config. Echoes the case directory.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$fakebin"
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$dir/home/data/backlog.md"
  fm_write_secondmate_meta "$dir/home/state/vm-mate.meta" "$dir/home" "remote:vm-mate" commercialeye
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=fm-task-a" "kind=ship" "mode=direct-PR" "yolo=on" "base_branch=dev" "pr=$URL"
  printf 'validated [at=1]: corr=old %s head %s old history\n' "$OTHER_URL" "$HEAD_B" \
    > "$dir/home/state/vm-mate.status"
  printf '%s\n' dry-run > "$dir/home/config/merge-on-validated"
  : > "$dir/gh.log"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
c=$FM_FAKE_CASE
printf '%s\n' "$*" >> "$c/gh.log"
case "$1 $2" in
  "pr view")
    [ ! -f "$c/view.fail" ] || exit 1
    cat "$c/view.json"
    ;;
  "pr merge") exit 0 ;;
  "api graphql")
    [ ! -f "$c/threads.fail" ] || exit 1
    cat "$c/threads.json"
    ;;
  api\ repos/*)
    ref=${2#*ref=}
    if [ -f "$c/vision-$ref" ]; then
      if grep -q BOOM "$c/vision-$ref"; then echo "gh: boom (HTTP 500)" >&2; exit 1; fi
      cat "$c/vision-$ref"
    else
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  write_view "$dir" "$HEAD_A"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]}}}}}' \
    > "$dir/threads.json"
  printf 'blob1\n' > "$dir/vision-dev"
  printf 'blob1\n' > "$dir/vision-$HEAD_A"
  printf '%s\n' "$dir"
}

write_view() {  # <case> <head>
  cat > "$1/view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$2","baseRefName":"dev","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-20T10:00:00Z"}],"reviewDecision":"","reviews":[],"labels":[],"title":"docs: plain change","body":"A plain change."}
JSON
}

# edit_view <case> <jq-filter>: change the served pull request.
edit_view() {
  jq "$2" "$1/view.json" > "$1/view.tmp" && mv "$1/view.tmp" "$1/view.json"
}

validated_line() {  # [url] [head] [text]
  printf 'validated [at=2]: corr=new %s head %s %s\n' "${1:-$URL}" "${2:-$HEAD_A}" "${3:-checks green}"
}

append_status() {  # <case> <line>
  printf '%s\n' "$2" >> "$1/home/state/vm-mate.status"
}

# scan <case> [extra env...]: run the hook; stdout in <case>/stdout, stderr in
# <case>/stderr, exit code in SCAN_RC.
SCAN_RC=0
scan() {
  local dir=$1
  shift
  SCAN_RC=0
  env "FM_HOME=$dir/home" "FM_FAKE_CASE=$dir" "PATH=$dir/fakebin:$PATH" \
    FM_MERGE_ON_VALIDATED_UNKNOWN_SLEEP=0 "$@" \
    bash "${SCAN_BIN:-$HOOK}" scan > "$dir/stdout" 2> "$dir/stderr" </dev/null || SCAN_RC=$?
}

# prime <case>: take the first scan, which only records where the log ends.
prime() {
  scan "$1"
  expect_code 0 "$SCAN_RC" "$(basename "$1"): priming scan"
}

log_of() { cat "$1/home/state/merge-on-validated.log" 2>/dev/null || true; }

# refuses <case-name> <expected reason> [jq-filter]: serve the clean pull
# request edited by the filter, scan one fresh validated line, and expect a
# dry-run refusal carrying the reason.
refuses() {
  local name=$1 reason=$2 filter=${3:-} dir
  dir=$(make_case "$name")
  [ -z "$filter" ] || edit_view "$dir" "$filter"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  expect_code 0 "$SCAN_RC" "$name: scan"
  assert_contains "$(log_of "$dir")" "would not merge: " "$name: no refusal logged"
  assert_contains "$(log_of "$dir")" "$reason" "$name: wrong reason"
  assert_not_contains "$(log_of "$dir")" "would merge " "$name: a refused pull request was reported as mergeable"
  assert_equals "" "$(cat "$dir/stdout")" "$name: dry-run printed a wake line"
  assert_no_grep "pr merge" "$dir/gh.log" "$name: the forge merge ran"
}

test_off_without_config() {
  local dir
  dir=$(make_case off-without-config)
  rm -f "$dir/home/config/merge-on-validated"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  expect_code 0 "$SCAN_RC" "off-without-config: scan"
  assert_absent "$dir/home/state/merge-on-validated.log" "off-without-config: logged while off"
  assert_absent "$dir/home/state/.merge-on-validated.cursor" "off-without-config: cursor written while off"
  assert_equals "" "$(cat "$dir/gh.log")" "off-without-config: the forge was called while off"
  pass "the hook is inert unless config/merge-on-validated exists"
}

test_invalid_config_is_inert() {
  local dir word
  for word in live-ish 'dry-run live'; do
    dir=$(make_case "invalid-config-$(printf '%s' "$word" | tr -c 'a-z\n' '-')")
    printf '%s\n' "$word" > "$dir/home/config/merge-on-validated"
    append_status "$dir" "$(validated_line)"
    scan "$dir"
    expect_code 2 "$SCAN_RC" "invalid config '$word' must be refused"
    assert_contains "$(cat "$dir/stderr")" "the hook is inert" "invalid config '$word': no explanation"
    assert_absent "$dir/home/state/merge-on-validated.log" "invalid config '$word': logged anyway"
  done
  pass "an unrecognized or ambiguous config leaves the hook inert"
}

test_empty_config_means_dry_run() {
  local dir
  dir=$(make_case empty-config)
  : > "$dir/home/config/merge-on-validated"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "empty config: not a dry run"
  assert_no_grep "pr merge" "$dir/gh.log" "empty config: merged"
  pass "an empty config file means dry-run"
}

test_history_is_not_replayed() {
  local dir
  dir=$(make_case history-skipped)
  prime "$dir"
  assert_contains "$(log_of "$dir")" "watching the status log of vm-mate from now" "history: first sight not logged"
  assert_not_contains "$(log_of "$dir")" "would" "history: an old validated line was acted on"
  assert_equals "" "$(cat "$dir/gh.log")" "history: the forge was called for old history"
  pass "the first scan starts at the end of each status log"
}

test_dry_run_would_merge_once() {
  local dir
  dir=$(make_case dry-run-merges)
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  expect_code 0 "$SCAN_RC" "dry-run: scan"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "dry-run: passing PR not logged"
  assert_equals "" "$(cat "$dir/stdout")" "dry-run: printed a wake line"
  assert_no_grep "pr merge" "$dir/gh.log" "dry-run: the forge merge ran"
  scan "$dir"
  assert_equals "1" "$(log_of "$dir" | grep -c 'would merge')" "dry-run: the same line was acted on twice"
  pass "dry-run logs would-merge once and never merges"
}

test_only_exact_validated_lines_count() {
  local dir
  dir=$(make_case other-states)
  prime "$dir"
  append_status "$dir" "validated-detail [at=3]: corr=x $URL head $HEAD_A more detail"
  append_status "$dir" "validated-then-conflicting [at=4]: corr=x $URL head $HEAD_A (was $HEAD_B)"
  append_status "$dir" "done [key=child-outcome-x] [at=5]: child x done: validated $URL head $HEAD_A"
  append_status "$dir" "working [at=6]: validated $URL head $HEAD_A is not a validated line"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would" "other states: a non-validated line was acted on"
  assert_equals "" "$(cat "$dir/gh.log")" "other states: the forge was called"
  pass "only a line whose state word is exactly validated is acted on"
}

test_partial_line_waits_for_its_newline() {
  local dir
  dir=$(make_case partial-line)
  prime "$dir"
  printf '%s' "$(validated_line)" >> "$dir/home/state/vm-mate.status"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would" "partial line: acted on before its newline"
  printf '\n' >> "$dir/home/state/vm-mate.status"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "partial line: not acted on once complete"
  pass "an unterminated status line waits for its newline"
}

test_shrunk_log_resumes_at_end() {
  local dir
  dir=$(make_case shrunk-log)
  prime "$dir"
  append_status "$dir" "padding padding padding padding padding padding padding padding"
  scan "$dir"
  printf 'x\n' > "$dir/home/state/vm-mate.status"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "shrank; resumed at its end" "shrunk log: not noticed"
  pass "a truncated status log does not replay or wedge the cursor"
}

test_unparseable_validated_lines() {
  local dir
  dir=$(make_case unparseable)
  prime "$dir"
  append_status "$dir" "validated [at=7]: corr=x all good but no url"
  append_status "$dir" "validated [at=8]: corr=x $URL head abc123 short sha"
  append_status "$dir" "validated [at=9]: corr=x $URL head $HEAD_A and also $OTHER_URL"
  append_status "$dir" "validated [at=10]: corr=x https://gitlab.com/g/p/-/merge_requests/3 head $HEAD_A"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "no '<pull request URL> head <40-hex sha>'" "unparseable: missing url/head not reported"
  assert_contains "$(log_of "$dir")" "names more than one pull request" "unparseable: two pull requests not reported"
  assert_equals "" "$(cat "$dir/gh.log")" "unparseable: the forge was called for a line with no usable PR"
  pass "a validated line without exactly one PR and full head is refused"
}

test_refusal_reasons() {
  refuses base-not-dev "base is 'main', not dev" '.baseRefName = "main"'
  refuses live-head-moved "live head bbbbbbbbbbbb is not the validated head aaaaaaaaaaaa" \
    ".headRefOid = \"$HEAD_B\""
  refuses draft "draft" '.isDraft = true'
  refuses closed "state is CLOSED" '.state = "CLOSED"'
  refuses merged "state is MERGED" '.state = "MERGED"'
  refuses check-red "checks not green: ci" '.statusCheckRollup[0].conclusion = "FAILURE"'
  refuses check-pending "checks not green: ci" \
    '.statusCheckRollup[0].status = "IN_PROGRESS" | .statusCheckRollup[0].conclusion = null'
  refuses no-checks "no checks are reported" '.statusCheckRollup = []'
  refuses unreadable-checks "could not read the check results" 'del(.statusCheckRollup)'
  refuses changes-requested "review of record requests changes (rabbit)" \
    '.reviews = [{"author":{"login":"rabbit"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-20T10:00:00Z"}]'
  refuses decision-changes-requested "review of record requests changes" '.reviewDecision = "CHANGES_REQUESTED"'
  refuses conflicting "mergeable is CONFLICTING" '.mergeable = "CONFLICTING"'
  refuses unknown-mergeable "mergeable is UNKNOWN" '.mergeable = "UNKNOWN"'
  refuses security-label "marked security-sensitive on the pull request" '.labels = [{"name":"security"}]'
  refuses security-title "marked security-sensitive on the pull request" '.title = "fix: Security-Sensitive path"'
  refuses security-body "marked security-sensitive on the pull request" '.body = "this is security sensitive"'
  pass "each live condition refuses with its own reason"
}

test_later_approval_clears_an_earlier_change_request() {
  local dir
  dir=$(make_case rereview-approves)
  edit_view "$dir" '.reviews = [
    {"author":{"login":"rabbit"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-20T09:00:00Z"},
    {"author":{"login":"rabbit"},"state":"APPROVED","submittedAt":"2026-10-20T10:00:00Z"},
    {"author":{"login":"bot"},"state":"COMMENTED","submittedAt":"2026-10-20T10:30:00Z"}]'
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "re-review: a later approval did not clear the request"
  pass "a reviewer's latest decisive review is the review of record"
}

test_review_threads() {
  local dir
  dir=$(make_case open-thread)
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"nodes":[{"isResolved":true},{"isResolved":false}]}}}}}' \
    > "$dir/threads.json"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "1 open review thread(s)" "open thread: not reported"

  dir=$(make_case too-many-threads)
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":101,"nodes":[{"isResolved":true}]}}}}}' \
    > "$dir/threads.json"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "more than 100 review threads" "too many threads: not reported"

  dir=$(make_case unreadable-threads)
  : > "$dir/threads.fail"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "could not read the review threads" "unreadable threads: not reported"
  pass "an unresolved, uncountable, or unreadable review thread refuses"
}

test_vision() {
  local dir
  dir=$(make_case vision-differs)
  printf 'blob2\n' > "$dir/vision-$HEAD_A"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "VISION.md differs from the dev tip" "vision differs: not reported"

  dir=$(make_case vision-added)
  rm -f "$dir/vision-dev"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "VISION.md differs from the dev tip" "vision added: not reported"

  dir=$(make_case vision-unreadable)
  printf 'BOOM\n' > "$dir/vision-dev"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "could not read VISION.md" "vision unreadable: not reported"

  dir=$(make_case vision-absent-both)
  rm -f "$dir/vision-dev" "$dir/vision-$HEAD_A"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "vision absent from both: wrongly refused"
  pass "VISION.md must be the same blob at the head and the base"
}

test_security_marker_in_status_line() {
  local dir
  dir=$(make_case security-line)
  prime "$dir"
  append_status "$dir" "$(validated_line "$URL" "$HEAD_A" 'touches auth, Security-Sensitive')"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "marked security-sensitive in the validated line" "security line: not reported"
  assert_not_contains "$(log_of "$dir")" "would merge" "security line: reported as mergeable"
  pass "a security-sensitive mark in the validated line refuses"
}

test_task_conditions() {
  local dir
  dir=$(make_case no-task)
  rm -f "$dir/home/state/task-a.meta"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "no task in this home records this pull request" "no task: not reported"
  assert_equals "" "$(cat "$dir/gh.log")" "no task: live reads were spent on an unrecorded PR"

  dir=$(make_case two-tasks)
  fm_write_meta "$dir/home/state/task-b.meta" "kind=ship" "yolo=on" "pr=$URL"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "more than one task records this pull request" "two tasks: not reported"

  dir=$(make_case not-yolo)
  fm_write_meta "$dir/home/state/task-a.meta" "kind=ship" "yolo=off" "pr=$URL"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "is not yolo, so merge authority stays with the captain" "not yolo: not reported"

  dir=$(make_case not-ship)
  fm_write_meta "$dir/home/state/task-a.meta" "kind=scout" "yolo=on" "pr=$URL"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "is not a ship task" "not ship: not reported"
  pass "the PR needs exactly one yolo ship task that records it"
}

test_held_task_refuses() {
  local dir
  dir=$(make_case held)
  FM_HOME="$dir/home" "$ROOT/bin/fm-captain-hold.sh" hold task-a --reason "needs the captain" \
    --title "held work" --repo example/repo \
    > "$dir/hold.out" 2>&1 || fail "held: could not place the hold: $(cat "$dir/hold.out")"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "is held for the captain" "held: not reported"

  dir=$(make_case hold-unreadable)
  chmod 000 "$dir/home/data/backlog.md"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  chmod 644 "$dir/home/data/backlog.md"
  assert_contains "$(log_of "$dir")" "could not tell whether task task-a is held for the captain" \
    "hold unreadable: not reported"
  pass "a held or undeterminable captain hold refuses"
}

test_unreadable_live_state_retries_then_logs() {
  local dir
  dir=$(make_case unreadable-view)
  : > "$dir/view.fail"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would" "retry: gave up before three attempts"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "could not be read after 3 attempts" "retry: never gave up"
  scan "$dir"
  assert_equals "1" "$(log_of "$dir" | grep -c 'could not be read')" "retry: logged more than once"
  pass "an unreadable pull request is retried, then logged once"
}

test_unknown_mergeable_is_reread() {
  local dir
  dir=$(make_case unknown-then-clean)
  edit_view "$dir" '.mergeable = "UNKNOWN"'
  # A fake that answers UNKNOWN once and MERGEABLE afterwards.
  mv "$dir/fakebin/gh" "$dir/fakebin/gh.real"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
c=$FM_FAKE_CASE
if [ "$1 $2" = "pr view" ]; then
  n=$(cat "$c/views" 2>/dev/null || echo 0)
  printf '%s\n' "$((n + 1))" > "$c/views"
  if [ "$n" -ge 1 ]; then
    jq '.mergeable = "MERGEABLE"' "$c/view.json"
    exit 0
  fi
fi
exec "$(dirname "$0")/gh.real" "$@"
SH
  chmod +x "$dir/fakebin/gh"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "unknown: a transient UNKNOWN was not re-read"
  pass "a transient UNKNOWN mergeable answer is re-read"
}

test_closed_pull_request_is_not_reread_for_unknown() {
  local dir
  dir=$(make_case merged-unknown)
  edit_view "$dir" '.state = "MERGED" | .mergeable = "UNKNOWN"'
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "state is MERGED, not OPEN" "merged unknown: not refused"
  assert_equals "1" "$(grep -c '^pr view' "$dir/gh.log")" \
    "merged unknown: a merged pull request was re-read while waiting for its mergeable answer"
  pass "only an open pull request is re-read for an UNKNOWN mergeable answer"
}

# live_case <name> <merge-stub-exit>: a live-mode case whose bin/ is symlinks
# to the real scripts plus a recording stand-in for fm-pr-merge.sh.
live_case() {
  local name=$1 stub_rc=$2 dir f
  dir=$(make_case "$name")
  printf '%s\n' live > "$dir/home/config/merge-on-validated"
  mkdir -p "$dir/bin"
  for f in "$ROOT"/bin/*; do
    [ -f "$f" ] || continue
    ln -s "$f" "$dir/bin/$(basename "$f")"
  done
  rm -f "$dir/bin/fm-pr-merge.sh"
  cat > "$dir/bin/fm-pr-merge.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/merge.args'
if [ '$stub_rc' -ne 0 ]; then
  echo 'error: refusing to merge $URL' >&2
  echo '  - check ci is not green' >&2
fi
exit $stub_rc
SH
  chmod +x "$dir/bin/fm-pr-merge.sh"
  printf '%s\n' "$dir"
}

test_live_merges_through_fm_pr_merge() {
  local dir
  dir=$(live_case live-merges 0)
  SCAN_BIN="$dir/bin/fm-merge-on-validated.sh"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  expect_code 0 "$SCAN_RC" "live: scan"
  assert_equals "task-a $URL" "$(cat "$dir/merge.args")" \
    "live: fm-pr-merge must get exactly the task and the URL"
  assert_no_grep "pr merge" "$dir/gh.log" "live: the hook reached a lower-level forge merge"
  assert_contains "$(log_of "$dir")" "merged $URL $HEAD_A" "live: merge not logged"
  assert_contains "$(cat "$dir/stdout")" "merge-on-validated: merged $URL at $HEAD_A (task task-a)" \
    "live: no wake line for the supervisor"
  assert_contains "$(cat "$dir/stdout")" "teardown and the Linear record are pending" \
    "live: the wake line does not leave teardown to the supervisor"
  scan "$dir"
  assert_equals "1" "$(wc -l < "$dir/merge.args" | tr -d ' ')" "live: the same line merged twice"
  SCAN_BIN=
  pass "live mode merges through fm-pr-merge.sh only, once, and wakes the supervisor"
}

test_live_reports_a_refused_merge() {
  local dir
  dir=$(live_case live-refused 1)
  SCAN_BIN="$dir/bin/fm-merge-on-validated.sh"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "merge refused by fm-pr-merge: error: refusing to merge $URL" \
    "live refused: refusal not logged"
  assert_contains "$(cat "$dir/stdout")" "fm-pr-merge refused $URL" "live refused: no wake line"
  scan "$dir"
  assert_equals "1" "$(wc -l < "$dir/merge.args" | tr -d ' ')" "live refused: merge retried on the next poll"
  SCAN_BIN=
  pass "live mode reports a merge the guarded script refused"
}

test_live_failing_test_never_calls_the_merge() {
  local dir
  dir=$(live_case live-failing-test 0)
  edit_view "$dir" '.baseRefName = "main"'
  SCAN_BIN="$dir/bin/fm-merge-on-validated.sh"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_absent "$dir/merge.args" "live failing: fm-pr-merge was called for a failing PR"
  assert_contains "$(log_of "$dir")" "not merged: base is 'main', not dev" "live failing: not logged"
  assert_equals "" "$(cat "$dir/stdout")" "live failing: a refusal woke the supervisor"
  SCAN_BIN=
  pass "live mode never calls the merge for a pull request that fails the test"
}

test_arm_and_disarm() {
  local dir
  dir=$(make_case arming)
  env "FM_HOME=$dir/home" bash "$HOOK" arm > "$dir/arm.out" 2>&1 || fail "arm failed: $(cat "$dir/arm.out")"
  assert_present "$dir/home/state/merge-on-validated.check.sh" "arm: no shim"
  assert_present "$dir/home/state/merge-on-validated.check-trust" "arm: shim not bound"
  assert_equals "700" "$(stat -c %a "$dir/home/state/merge-on-validated.check.sh" 2>/dev/null || stat -f %Lp "$dir/home/state/merge-on-validated.check.sh")" \
    "arm: shim is not mode 0700"
  assert_grep "merge-on-validated.sh" "$dir/home/state/merge-on-validated.check.sh" "arm: shim does not run the hook"
  env "FM_HOME=$dir/home" bash "$HOOK" disarm > /dev/null
  assert_absent "$dir/home/state/merge-on-validated.check.sh" "disarm: shim left behind"
  assert_absent "$dir/home/state/merge-on-validated.check-trust" "disarm: trust binding left behind"

  rm -f "$dir/home/config/merge-on-validated"
  if env "FM_HOME=$dir/home" bash "$HOOK" arm > "$dir/arm2.out" 2>&1; then
    fail "arm succeeded without a config file"
  fi
  assert_absent "$dir/home/state/merge-on-validated.check.sh" "arm without config left a shim"
  pass "arm needs the config, binds the shim, and disarm removes it"
}

test_off_without_config
test_invalid_config_is_inert
test_empty_config_means_dry_run
test_history_is_not_replayed
test_dry_run_would_merge_once
test_only_exact_validated_lines_count
test_partial_line_waits_for_its_newline
test_shrunk_log_resumes_at_end
test_unparseable_validated_lines
test_refusal_reasons
test_later_approval_clears_an_earlier_change_request
test_review_threads
test_vision
test_security_marker_in_status_line
test_task_conditions
test_held_task_refuses
test_unreadable_live_state_retries_then_logs
test_unknown_mergeable_is_reread
test_closed_pull_request_is_not_reread_for_unknown
test_live_merges_through_fm_pr_merge
test_live_reports_a_refused_merge
test_live_failing_test_never_calls_the_merge
test_arm_and_disarm
