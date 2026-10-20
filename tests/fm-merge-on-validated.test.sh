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
    "window=fm-task-a" "kind=ship" "mode=direct-PR" "yolo=on" "base_branch=dev" "branch=fm/task-a" "pr=$URL"
  printf 'validated [at=1]: corr=old %s head %s old history\n' "$OTHER_URL" "$HEAD_B" \
    > "$dir/home/state/vm-mate.status"
  printf '%s\n' dry-run > "$dir/home/config/merge-on-validated"
  printf '{"pr":"%s","head":"%s","verdict":"merge"}\n' "$URL" "$HEAD_A" > "$dir/home/state/review-verdicts.jsonl"
  : > "$dir/gh.log"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
c=$FM_FAKE_CASE
printf '%s\n' "$*" >> "$c/gh.log"
case "$1 $2" in
  "pr view")
    [ ! -f "$c/view.fail" ] || exit 1
    if [ "$*" = "pr view $3 --json headRefName --jq .headRefName" ]; then
      jq -r .headRefName "$c/view.json"
    else
      cat "$c/view.json"
    fi
    ;;
  "pr merge") exit 0 ;;
  api\ repos/*/pulls/*/files*)
    [ ! -f "$c/files.fail" ] || exit 1
    cat "$c/files.json"
    ;;
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
  printf '[[{"filename":"src/app.js","status":"modified"}]]\n' > "$dir/files.json"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]}}}}}' \
    > "$dir/threads.json"
  printf 'blob1\n' > "$dir/vision-dev"
  printf 'blob1\n' > "$dir/vision-$HEAD_A"
  printf '%s\n' "$dir"
}

write_view() {  # <case> <head>
  cat > "$1/view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$2","headRefName":"fm/task-a","changedFiles":1,"baseRefName":"dev","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-20T10:00:00Z"}],"reviewDecision":"","reviews":[],"labels":[],"title":"docs: plain change","body":"A plain change."}
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
  refuses merged "already merged" '.state = "MERGED"'
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
  assert_contains "$(log_of "$dir")" "already merged" "merged unknown: not refused"
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
printf '%s\n' "\${FM_PR_MERGE_EXPECTED_HEAD:-}" > '$dir/expected-head'
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
  assert_equals "$HEAD_A" "$(cat "$dir/expected-head")" "live: review head binding was lost"
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
  assert_equals "2" "$(wc -l < "$dir/merge.args" | tr -d ' ')" "live refused: transient check refusal was not retried"
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

test_branch_fallback() {
  local dir
  dir=$(make_case branch-fallback)
  sed '/^pr=/d' "$dir/home/state/task-a.meta" > "$dir/meta.tmp"
  mv "$dir/meta.tmp" "$dir/home/state/task-a.meta"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "branch fallback did not find the unbound task"
  pass "an unbound ship task is found by the live PR branch"
}

test_prose_is_not_security_authority() {
  local dir
  dir=$(make_case security-prose)
  edit_view "$dir" '.title = "Security-sensitive discussion" | .body = "This is not security-sensitive."'
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "free prose caused a security refusal"
  pass "PR title and body prose do not classify security sensitivity"
}

test_pending_retries() {
  local dir filter name
  for name in pending-check dirty unknown; do
    dir=$(make_case "retry-$name")
    case "$name" in
      pending-check) filter='.statusCheckRollup[0].status = "IN_PROGRESS" | .statusCheckRollup[0].conclusion = null' ;;
      dirty) filter='.mergeStateStatus = "DIRTY"' ;;
      unknown) filter='.mergeable = "UNKNOWN"' ;;
    esac
    edit_view "$dir" "$filter"
    prime "$dir"
    append_status "$dir" "$(validated_line)"
    scan "$dir"
    assert_not_contains "$(log_of "$dir")" "would merge " "$name should wait"
    assert_present "$dir/home/state/.merge-on-validated.pending" "$name was not retained"
    write_view "$dir" "$HEAD_A"
    scan "$dir"
    assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "$name was never retried"
    scan "$dir"
    assert_equals 1 "$(log_of "$dir" | grep -c 'would merge ')" "$name success replayed"
  done
  pass "pending checks and DIRTY/UNKNOWN mergeability retry without new status lines"
}

test_review_verdict_gate() {
  local dir rc
  dir=$(make_case review-verdict)
  rm "$dir/home/state/review-verdicts.jsonl"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "missing second-model merge verdict" "missing review must wait"
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_B" merge || fail "could not record stale-head review"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would merge " "another head authorized merge"
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$OTHER_URL" "$HEAD_A" merge || fail "could not record other PR review"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would merge " "another PR authorized merge"
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" merge independent-review || fail "could not record review"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "exact-head merge verdict did not release wait"
  assert_equals independent-review "$(jq -r '.reviewer // empty' "$dir/home/state/review-verdicts.jsonl" | tail -1)" "review acceptance records the reviewer"
  assert_equals 3 "$(wc -l < "$dir/home/state/review-verdicts.jsonl" | tr -d ' ')" "helper lost a record"
  rc=0
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" bad merge >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "bad review head"
  rc=0
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" approve >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "bad verdict"

  dir=$(make_case fix-verdict)
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" fix || fail "could not record fix verdict"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "second-model review says fix" "latest fix verdict did not refuse"
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" merge || fail "could not record revised verdict"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would merge " "a permanent refusal was retried"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "fresh validation after re-review should pass"
  pass "second-model review is exact-head, exact-PR, latest-record, and fail-closed"
}

test_test_only_review_exemption() {
  local dir name
  for name in suffix directory renamed-source mixed truncated empty unreadable; do
    dir=$(make_case "test-only-$name")
    rm "$dir/home/state/review-verdicts.jsonl"
    case "$name" in
      suffix) printf '[[{"filename":"src/app.spec.ts"}]]' > "$dir/files.json" ;;
      directory) printf '[[{"filename":"tests/check.sh"}]]' > "$dir/files.json" ;;
      renamed-source) printf '[[{"filename":"src/app.spec.ts","previous_filename":"src/app.ts"}]]' > "$dir/files.json" ;;
      mixed) printf '[[{"filename":"tests/check.sh"}],[{"filename":"src/app.js"}]]' > "$dir/files.json"; edit_view "$dir" '.changedFiles = 2' ;;
      truncated) printf '[[{"filename":"tests/check.sh"}]]' > "$dir/files.json"; edit_view "$dir" '.changedFiles = 2' ;;
      empty) printf '[[]]' > "$dir/files.json"; edit_view "$dir" '.changedFiles = 0' ;;
      unreadable) : > "$dir/files.fail" ;;
    esac
    prime "$dir"
    append_status "$dir" "$(validated_line)"
    scan "$dir"
    case "$name" in
      suffix|directory) assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "$name needs no review" ;;
      *) assert_not_contains "$(log_of "$dir")" "would merge " "$name must require review" ;;
    esac
  done
  pass "only a complete test-only diff exempts missing review; renamed source and unreadable lists fail closed"
}

test_pending_retirement() {
  local dir
  dir=$(make_case pending-retirement)
  prime "$dir"
  edit_view "$dir" '.mergeable = "UNKNOWN"'
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  edit_view "$dir" '.baseRefName = "main"'
  scan "$dir"
  write_view "$dir" "$HEAD_A"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would merge " "permanent refusal was retried"

  dir=$(make_case pending-head-change)
  prime "$dir"
  edit_view "$dir" '.mergeable = "UNKNOWN"'
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  write_view "$dir" "$HEAD_B"
  scan "$dir"
  write_view "$dir" "$HEAD_A"
  scan "$dir"
  assert_not_contains "$(log_of "$dir")" "would merge " "head change did not retire validation"
  assert_contains "$(log_of "$dir")" "pending validated head changed" "head change not explained"

  dir=$(make_case moved-head-recovery)
  prime "$dir"
  write_view "$dir" "$HEAD_B"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_present "$dir/home/state/.merge-on-validated.pending" "initial head mismatch must be retained"
  write_view "$dir" "$HEAD_A"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "transient moved-head read did not recover"
  pass "pending validations retire after permanent refusal or head change, and transient moved-head reads recover"
}

test_branch_fallback_ambiguity() {
  local dir
  dir=$(make_case branch-ambiguity)
  fm_write_meta "$dir/home/state/task-a.meta" "kind=ship" "yolo=on" "branch=fm/task-a"
  fm_write_meta "$dir/home/state/task-b.meta" "kind=ship" "yolo=on" "branch=fm/task-a"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "more than one task" "ambiguous branch should refuse"
  assert_not_contains "$(log_of "$dir")" "would merge " "ambiguous branch merged"
  pass "branch fallback refuses ambiguity"
}

test_pending_live_merge_and_revalidation() {
  local dir
  dir=$(live_case pending-live 0)
  SCAN_BIN="$dir/bin/fm-merge-on-validated.sh"
  rm "$dir/home/state/review-verdicts.jsonl"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_absent "$dir/merge.args" "missing review reached guarded merge"
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" merge || fail "could not record live review"
  scan "$dir"
  scan "$dir"
  assert_equals 1 "$(wc -l < "$dir/merge.args" | tr -d ' ')" "pending live merge did not run exactly once"
  [ ! -s "$dir/home/state/.merge-on-validated.pending" ] || fail "merged pending record remains"
  SCAN_BIN=

  dir=$(make_case revalidated-new-head)
  prime "$dir"
  edit_view "$dir" '.mergeable = "UNKNOWN"'
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  write_view "$dir" "$HEAD_B"
  printf 'blob1\n' > "$dir/vision-$HEAD_B"
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_B" merge || fail "could not review new head"
  append_status "$dir" "$(validated_line "$URL" "$HEAD_B")"
  scan "$dir"
  assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_B" "fresh validation did not replace obsolete pending head"
  assert_not_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "old head was authorized"
  pass "pending live merges run once after review and fresh validation can replace an obsolete head"
}

test_retry_after_unreadable_supporting_facts() {
  local dir name
  for name in threads vision; do
    dir=$(make_case "retry-unreadable-$name")
    prime "$dir"
    edit_view "$dir" '.mergeable = "UNKNOWN"'
    case "$name" in
      threads) : > "$dir/threads.fail" ;;
      vision) printf 'BOOM\n' > "$dir/vision-dev" ;;
    esac
    append_status "$dir" "$(validated_line)"
    scan "$dir"
    rm -f "$dir/threads.fail"
    printf 'blob1\n' > "$dir/vision-dev"
    write_view "$dir" "$HEAD_A"
    scan "$dir"
    assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" "unreadable $name incorrectly retired a transient refusal"
  done
  pass "unreadable supporting facts cannot turn transient mergeability into a permanent refusal"
}

test_merged_without_task_and_vm_review() {
  local dir text
  dir=$(make_case merged-without-task)
  rm "$dir/home/state/task-a.meta"
  edit_view "$dir" '.state = "MERGED" | .mergeable = "UNKNOWN"'
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_contains "$(log_of "$dir")" 'already merged' 'retired task must not mask an already merged PR'
  assert_not_contains "$(log_of "$dir")" 'no task' 'merged PR should not look up a task'
  for text in 'review verdict applied' 'review verdict was applied' 'review verdict was not applied' 'checks green'; do
    dir=$(make_case "vm-review-$(printf '%s' "$text" | tr ' ' '-')")
    rm "$dir/home/state/review-verdicts.jsonl"
    prime "$dir"
    append_status "$dir" "$(validated_line "$URL" "$HEAD_A" "$text")"
    scan "$dir"
    case "$text" in
      'review verdict applied'|'review verdict was applied')
        assert_contains "$(log_of "$dir")" "would merge $URL $HEAD_A" 'explicit applied review should satisfy gate' ;;
      *) assert_contains "$(log_of "$dir")" 'missing second-model merge verdict' 'no positive review must remain blocked' ;;
    esac
  done
  dir=$(make_case vm-review-fix)
  FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" fix || fail 'record fix'
  prime "$dir"
  append_status "$dir" "$(validated_line "$URL" "$HEAD_A" 'review verdict applied')"
  scan "$dir"
  assert_contains "$(log_of "$dir")" 'second-model review says fix' 'VM applied marker must not override explicit fix'
  pass 'merged PR state precedes task lookup and explicit VM applied review is accepted safely'
}
test_default_budget_covers_slow_prior_pr() {
  local dir real_date
  dir=$(make_case budget)
  real_date=$(command -v date)
  cat > "$dir/fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  now=\$("$real_date" +%s)
  shift_secs=\$(cat "$dir/clock-shift" 2>/dev/null || echo 0)
  echo \$((now + shift_secs))
else
  exec "$real_date" "\$@"
fi
SH
  mv "$dir/fakebin/gh" "$dir/fakebin/gh-real"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  shift_secs=$(cat "$FM_FAKE_CASE/clock-shift" 2>/dev/null || echo 0)
  echo $((shift_secs + 12)) > "$FM_FAKE_CASE/clock-shift"
fi
exec "$FM_FAKE_CASE/fakebin/gh-real" "$@"
SH
  chmod +x "$dir/fakebin/date" "$dir/fakebin/gh"
  prime "$dir"
  append_status "$dir" "$(validated_line)"
  append_status "$dir" "$(validated_line)"
  scan "$dir"
  assert_equals 2 "$(grep -c 'would merge ' "$dir/home/state/merge-on-validated.log")" 'scan handles a second validation after a simulated 12s first PR'
  assert_equals "$(wc -c < "$dir/home/state/vm-mate.status" | tr -d ' ')" "$(awk '{print $2}' "$dir/home/state/.merge-on-validated.cursor")" 'scan reaches both validated lines'
  pass '45s default budget processes the next validation after a slow PR read'
}
test_vm_review_live_guard() {
  local dir name text
  for name in missing applied fix; do
    dir=$(live_case "vm-review-live-$name" 0)
    rm "$dir/home/state/review-verdicts.jsonl"
    text='checks green'
    if [ "$name" != missing ]; then text='checks green; review verdict was applied; checks green'; fi
    if [ "$name" = fix ]; then
      FM_HOME="$dir/home" "$ROOT/bin/fm-review-verdict.sh" "$URL" "$HEAD_A" fix independent-review || fail 'record blocking review'
    fi
    SCAN_BIN="$dir/bin/fm-merge-on-validated.sh" prime "$dir"
    append_status "$dir" "$(validated_line "$URL" "$HEAD_A" "$text")"
    SCAN_BIN="$dir/bin/fm-merge-on-validated.sh" scan "$dir"
    if [ "$name" = applied ]; then
      assert_equals "task-a $URL" "$(cat "$dir/merge.args")" 'applied review reaches guarded merge'
    else
      assert_absent "$dir/merge.args" 'missing or blocking review must never call merge'
      if [ "$name" = missing ]; then
        assert_contains "$(log_of "$dir")" 'not merged: missing second-model merge verdict' 'live skip clearly names missing review'
      fi
    fi
  done
  pass 'live mode requires a review and a VM applied marker never overrides fix'
}
test_vm_review_live_guard
test_default_budget_covers_slow_prior_pr
test_merged_without_task_and_vm_review

test_retry_after_unreadable_supporting_facts
test_pending_live_merge_and_revalidation
test_review_verdict_gate
test_test_only_review_exemption
test_pending_retirement
test_branch_fallback_ambiguity
test_branch_fallback
test_prose_is_not_security_authority
test_pending_retries
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
