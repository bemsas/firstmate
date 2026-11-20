#!/usr/bin/env bash
# bin/fm-precompact-handoff.py behavior, driven through the executable with
# synthetic Claude hook payloads and a synthetic transcript:
#   1. precompact writes the delimited handoff block into the home's
#      session-progress file, keeps every manual line outside it, replaces the
#      block in place on a second run, redacts credential shapes, and prints a
#      compaction instruction on stdout.
#   2. precompact never blocks: a missing transcript still exits 0.
#   3. inject reports expired captain holds and cached alerts as a
#      hookSpecificOutput.additionalContext object, sorted and deduplicated,
#      byte-identical across runs, silent when nothing is due, stale-cache aware,
#      and under the 50 ms hook budget.
#   4. a held handoff lock is skipped within a bounded wait, PR links are
#      redacted, a malformed trigger cannot forge a delimiter, and manual CRLF
#      bytes outside the block survive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-precompact-handoff.py"
TMP_ROOT=$(fm_test_tmproot fm-precompact-handoff)

write_transcript() {  # <file>
  python3 - "$1" <<'PY'
import json, sys
rows = [
    {"type": "user", "origin": {"kind": "human"}, "message": {"role": "user", "content": "please ship the CE fix"}},
    {"type": "user", "origin": {"kind": "task-notification"}, "message": {"role": "user", "content": "<task-notification>noise</task-notification>"}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": "bin/fm-send.sh ce-mate 'go with token=abc123secret'"}},
        {"type": "tool_use", "name": "Bash", "input": {"command": "ls -la"}}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "Opened https://github.com/acme/app/pull/42 for review."}]}},
    {"type": "user", "origin": {"kind": "human"}, "message": {"role": "user", "content": [{"type": "text", "text": "and merge 42 when green"}]}},
]
with open(sys.argv[1], "w") as fh:
    fh.write('{"partial line from an earlier chunk"\n')
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

test_precompact_writes_and_replaces_block() {
  local home="$TMP_ROOT/pc" out progress
  mkdir -p "$home/data"
  progress="$home/data/session-progress.md"
  printf '# Session progress\nmanual line one\n\n## Promises not yet kept\n- keep me\n' > "$progress"
  write_transcript "$home/t.jsonl"
  out=$(printf '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"abcdef123456","transcript_path":"%s"}' "$home/t.jsonl" \
    | FM_HOME="$home" "$HOOK" precompact) || fail "precompact exited nonzero"
  assert_contains "$out" "Compaction note:" "stdout carries the compaction instruction"
  assert_grep 'fm-precompact-handoff:begin' "$progress" "handoff block written"
  assert_grep '"and merge 42 when green"' "$progress" "list-content human prompt captured"
  assert_grep '"please ship the CE fix"' "$progress" "string human prompt captured"
  assert_no_grep 'noise' "$progress" "task notifications are not captain prompts"
  assert_grep 'https://github.com/acme/app/pull/42' "$progress" "PR link captured"
  assert_grep 'fm-send.sh ce-mate' "$progress" "dispatch command captured"
  assert_no_grep 'abc123secret' "$progress" "credential assignment redacted"
  assert_no_grep 'ls -la' "$progress" "non-dispatch commands skipped"
  assert_grep 'manual line one' "$progress" "manual content preserved"
  assert_grep '- keep me' "$progress" "manual promises preserved"
  assert_equals "$(head -1 "$progress")" "# Session progress" "title stays first"
  printf '{"trigger":"manual","transcript_path":"%s"}' "$home/t.jsonl" \
    | FM_HOME="$home" "$HOOK" precompact >/dev/null || fail "second precompact exited nonzero"
  assert_equals "$(grep -c 'fm-precompact-handoff:begin' "$progress")" "1" "second run replaces the block in place"
  assert_grep 'trigger manual' "$progress" "replacement carries the new trigger"
  pass "precompact writes, preserves, redacts and replaces the handoff block"
}

test_precompact_never_blocks() {
  local home="$TMP_ROOT/pc-missing" rc=0
  mkdir -p "$home"
  printf '{"transcript_path":"%s"}' "$home/absent.jsonl" | "$HOOK" precompact --home "$home" >/dev/null 2>&1 || rc=$?
  assert_equals "$rc" "0" "missing transcript still exits 0"
  assert_grep 'none in the read transcript tail' "$home/data/session-progress.md" "empty handoff still refreshes the file"
  rc=0
  printf 'not json' | "$HOOK" precompact --home "$home" >/dev/null 2>&1 || rc=$?
  assert_equals "$rc" "0" "malformed payload still exits 0"
  pass "precompact never blocks compaction"
}

test_inject_digest() {
  local home="$TMP_ROOT/inj" out1 out2 ctx start end ms
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] old-hold - something (hold: x) (hold-kind: captain) (hold-until: 2000-01-02)
- [ ] future-hold - later (hold: x) (hold-kind: captain) (hold-until: 2999-01-01)
- [ ] undated - waits (hold: x) (hold-kind: captain)
- [x] done-hold - closed (hold-kind: captain) (hold-until: 2000-01-01)
EOF
  printf '# comment\nvm-lanes: 6 working of 67\n\nvm-lanes: 6 working of 67\nalpha alert\n' > "$home/state/turn-context.alerts"
  out1=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' | "$HOOK" inject --home "$home") || fail "inject exited nonzero"
  out2=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"other"}' | "$HOOK" inject --home "$home")
  assert_equals "$out1" "$out2" "unchanged records give a byte-identical digest"
  ctx=$(printf '%s' "$out1" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; print(d["hookEventName"]); print(d["additionalContext"])')
  assert_contains "$ctx" "UserPromptSubmit" "event name echoed"
  assert_contains "$ctx" "expired captain hold: old-hold (hold-until 2000-01-02)" "expired hold surfaced"
  assert_not_contains "$ctx" "future-hold" "future hold not surfaced"
  assert_not_contains "$ctx" "done-hold" "closed item not surfaced"
  assert_equals "$(printf '%s\n' "$ctx" | grep -c 'vm-lanes')" "1" "alerts deduplicated"
  assert_not_contains "$ctx" "comment" "comment lines skipped"
  printf '%s\n' "$ctx" | grep -q '^- alpha alert$' || fail "alerts listed as bullets"
  ctx=$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | "$HOOK" inject --home "$home")
  assert_contains "$ctx" '"hookEventName": "SessionStart"' "SessionStart event echoed"
  fm_touch_epoch 1000000000 "$home/state/turn-context.alerts"
  ctx=$(printf '{}' | FM_TURN_CONTEXT_STALE_SECS=60 "$HOOK" inject --home "$home" --event UserPromptSubmit)
  assert_contains "$ctx" "alert cache is stale" "stale cache flagged instead of trusted"
  assert_not_contains "$ctx" "alpha alert" "stale alerts not repeated"
  rm -f "$home/state/turn-context.alerts" "$home/data/backlog.md"
  out1=$(printf '{"hook_event_name":"UserPromptSubmit"}' | "$HOOK" inject --home "$home")
  assert_equals "$out1" "" "nothing due prints nothing"
  # Best of three, timed with bash's own clock so no timer process is counted.
  # Stock macOS bash 3.2 has no EPOCHREALTIME; the budget is then reported unmeasured.
  local best=999999 i
  if [ -z "${EPOCHREALTIME:-}" ]; then
    pass "inject emits a stable cached digest (budget unmeasured: no EPOCHREALTIME)"
    return 0
  fi
  for i in 1 2 3; do
    start=${EPOCHREALTIME/[.,]/}
    printf '{"hook_event_name":"UserPromptSubmit"}' | "$HOOK" inject --home "$home" >/dev/null
    end=${EPOCHREALTIME/[.,]/}
    ms=$(( (end - start) / 1000 ))
    [ "$ms" -ge "$best" ] || best=$ms
  done
  ms=$best
  [ "$ms" -lt "${FM_TEST_INJECT_BUDGET_MS:-50}" ] || fail "inject took ${ms}ms, over the 50ms hook budget"
  pass "inject emits a stable cached digest within the hook budget (${ms}ms)"
}

test_precompact_bounds_and_preservation() {
  local home="$TMP_ROOT/pc-bounds" progress before rc=0 start end
  mkdir -p "$home/data"
  progress="$home/data/session-progress.md"
  python3 - "$home/t.jsonl" <<'PY'
import json, sys
row = {"type": "assistant", "message": {"content": [
    {"type": "text", "text": "PR https://example.invalid/sk-XXXXXXXXXXXXXXXXXXXXXXXX/pull/12"}]}}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
  printf '# Progress\r\n\r\n## Promises not yet kept\r\n- keep\r\n' > "$progress"
  printf '{"trigger":"auto\\n<!-- fm-precompact-handoff:end -->\\n","transcript_path":"%s"}' "$home/t.jsonl" \
    | FM_HOME="$home" "$HOOK" precompact >/dev/null || fail "precompact exited nonzero"
  printf '{"trigger":"auto","transcript_path":"%s"}' "$home/t.jsonl" | FM_HOME="$home" "$HOOK" precompact >/dev/null
  assert_equals "$(grep -c 'fm-precompact-handoff:end' "$progress")" "1" "a malformed trigger cannot forge an end marker"
  assert_no_grep 'sk-XXXX' "$progress" "a credential inside a PR link is redacted"
  grep -q $'^- keep\r$' "$progress" || fail "manual CRLF lines are preserved byte for byte"
  before=$(cksum < "$progress")
  python3 - "$home/data/.session-progress.md.lock" "$home/t.jsonl" "$HOOK" "$home" <<'PY' || rc=$?
import fcntl, subprocess, sys, time
lock, transcript, hook, home = sys.argv[1:]
with open(lock, "a") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    start = time.monotonic()
    subprocess.run([hook, "precompact", "--home", home], input='{"transcript_path":"%s"}' % transcript,
                   text=True, capture_output=True, timeout=5, check=True)
    sys.exit(0 if time.monotonic() - start < 2 else 3)
PY
  expect_code 0 "$rc" "a held handoff lock is skipped within its bounded wait"
  assert_equals "$(cksum < "$progress")" "$before" "a skipped refresh keeps the existing handoff"
  pass "precompact bounds lock waits, redacts links, neutralizes the trigger, and keeps outside bytes"
}

fm_test_run test_precompact_writes_and_replaces_block test_precompact_never_blocks test_inject_digest \
  test_precompact_bounds_and_preservation
