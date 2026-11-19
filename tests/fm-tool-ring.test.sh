#!/usr/bin/env bash
# bin/fm-tool-ring.py behavior through its executable:
#   1. append turns Claude PostToolUse / PostToolUseFailure / Stop / PreCompact
#      payloads into ring events that keep names and hashes only, caps the ring
#      at 20, ignores other payloads, and never fails a hook.
#   2. detect finds each of the five loop patterns, reports the first and last
#      event times of the loop (a fixture replay at 10 s spacing is caught
#      within 180 s of its first event), lets an old loop age out, and leaves
#      progress (changing outputs, distinct calls) alone.
#   3. detect derives the same events from a Codex rollout: paired calls and
#      outputs, nonzero exit codes, assistant messages, compactions, the
#      context percentage, and the 401/403 versus 429 status of failed calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RING="$ROOT/bin/fm-tool-ring.py"
TMP_ROOT=$(fm_test_tmproot fm-tool-ring)

hook() {  # <state> <id> <json>
  printf '%s' "$3" | "$RING" append "$1" "$2"
}

fixture_ring() {  # <state> <id> <t0> <spec>... ; spec = kind:sig:out:error[:context]
  local state=$1 id=$2 t0=$3 i=0 spec kind sig out err ctx
  shift 3
  : > "$state/$id.tool-ring.jsonl"
  for spec in "$@"; do
    IFS=: read -r kind sig out err ctx <<< "$spec"
    printf '{"v":1,"ts":%s,"src":"claude-hook","kind":"%s","tool":"Bash","sig":"%s","out":"%s","error":%s,"status":null,"context":%s}\n' \
      "$((t0 + 10 * i))" "$kind" "$sig" "$out" "${err:-false}" "${ctx:-false}" >> "$state/$id.tool-ring.jsonl"
    i=$((i + 1))
  done
}

field() {  # <line> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

test_append_keeps_hashes_only_and_caps() {
  local state="$TMP_ROOT/append" i out rc=0
  mkdir -p "$state"
  hook "$state" t1 '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cat .env"},"tool_response":{"stdout":"API_KEY=sk-live-123"}}'
  hook "$state" t1 '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"curl x"},"error":"HTTP 429 Too Many Requests"}'
  hook "$state" t1 '{"hook_event_name":"Stop","last_assistant_message":"I am done with secret plan"}'
  hook "$state" t1 '{"hook_event_name":"PreCompact","trigger":"auto"}'
  hook "$state" t1 '{"hook_event_name":"UserPromptSubmit","prompt":"ignored"}'
  assert_equals "$(wc -l < "$state/t1.tool-ring.jsonl" | tr -d ' ')" "4" "four recognized events, one ignored"
  assert_no_grep 'sk-live-123' "$state/t1.tool-ring.jsonl" "tool output text is never stored"
  assert_no_grep 'cat .env' "$state/t1.tool-ring.jsonl" "tool input text is never stored"
  assert_no_grep 'secret plan' "$state/t1.tool-ring.jsonl" "message text is never stored"
  out=$(sed -n 2p "$state/t1.tool-ring.jsonl")
  assert_contains "$out" '"error":true,"status":429' "a failed call records its 429 status"
  assert_contains "$(sed -n 3p "$state/t1.tool-ring.jsonl")" '"kind":"message"' "Stop becomes a message event"
  assert_contains "$(sed -n 4p "$state/t1.tool-ring.jsonl")" '"kind":"compact"' "PreCompact becomes a compact event"
  for i in $(seq 1 25); do
    hook "$state" t1 "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/f$i\"},\"tool_response\":\"x\"}"
  done
  assert_equals "$(wc -l < "$state/t1.tool-ring.jsonl" | tr -d ' ')" "20" "the ring is capped at 20 events"
  printf 'not json' | "$RING" append "$state" t1 || rc=$?
  assert_equals "$rc" "0" "a malformed payload still exits 0"
  printf '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | "$RING" append "$TMP_ROOT/absent" t1 || rc=$?
  assert_equals "$rc" "0" "a missing state directory still exits 0"
  expect_code 2 "$("$RING" append "$state" '../escape' </dev/null >/dev/null 2>&1; echo $?)" "an unsafe task id is refused"
  pass "append keeps names and hashes only, caps at 20, ignores the rest, never fails a hook"
}

test_detect_five_patterns_within_180s() {
  local state="$TMP_ROOT/detect" t0=1800000000 out
  mkdir -p "$state"
  fixture_ring "$state" p1 "$t0" tool:a:x:false tool:b:e:true tool:b:e:true tool:b:e:true
  out=$("$RING" detect "$state" p1 --now $((t0 + 40)))
  assert_contains "$out" "verdict=loop pattern=repeat_action_error" "three identical errors"
  assert_equals "$(( $(field "$out" last_ts) - $(field "$out" first_ts) ))" "20" "the loop is dated from its own events"
  fixture_ring "$state" p2 "$t0" tool:a:x:false tool:a:x:false tool:a:x:false tool:a:x:false
  out=$("$RING" detect "$state" p2 --now $((t0 + 40)))
  assert_contains "$out" "pattern=repeat_action_observation" "four identical call/output pairs"
  [ $(( $(field "$out" last_ts) - $(field "$out" first_ts) )) -lt 180 ] || fail "4x repeat not caught within 180s"
  fixture_ring "$state" p3 "$t0" tool:a:x:false tool:b:y:false tool:a:x:false tool:b:y:false tool:a:x:false tool:b:y:false
  out=$("$RING" detect "$state" p3 --now $((t0 + 60)))
  assert_contains "$out" "pattern=alternating" "ABABAB edits"
  [ $(( $(field "$out" last_ts) - $(field "$out" first_ts) )) -lt 180 ] || fail "6x ABAB not caught within 180s"
  fixture_ring "$state" p4 "$t0" tool:a:x:false message:m:: message:m:: message:m::
  out=$("$RING" detect "$state" p4 --now $((t0 + 40)))
  assert_contains "$out" "pattern=monologue" "three identical messages"
  fixture_ring "$state" p5 "$t0" tool:a:x:false compact::: compact::: compact:::
  out=$("$RING" detect "$state" p5 --now $((t0 + 40)))
  assert_contains "$out" "pattern=context_loop" "three compactions in a row"
  fixture_ring "$state" p6 "$t0" compact::: tool:a:e:true:true tool:c:f:true:true
  out=$("$RING" detect "$state" p6 --now $((t0 + 40)))
  assert_contains "$out" "pattern=context_loop" "context-window errors count toward the context loop"
  out=$("$RING" detect "$state" p2 --now $((t0 + 5000)))
  assert_contains "$out" "verdict=none" "a loop older than the window ages out"
  pass "detect finds all five patterns, each within 180s of its first event, and ages them out"
}

test_detect_leaves_progress_alone() {
  local state="$TMP_ROOT/progress" t0=1800000000 out
  mkdir -p "$state"
  fixture_ring "$state" q1 "$t0" tool:a:x1:false tool:a:x2:false tool:a:x3:false tool:a:x4:false
  out=$("$RING" detect "$state" q1 --now $((t0 + 40)))
  assert_contains "$out" "verdict=none" "a polled command whose output changes is progress"
  fixture_ring "$state" q2 "$t0" tool:a:x:true tool:b:x:true tool:c:x:true
  out=$("$RING" detect "$state" q2 --now $((t0 + 40)))
  assert_contains "$out" "verdict=none" "distinct failing calls are not a repeat"
  fixture_ring "$state" q3 "$t0" tool:a:x:false tool:b:y:false tool:a:x:false tool:c:z:false tool:a:x:false tool:b:y:false
  out=$("$RING" detect "$state" q3 --now $((t0 + 60)))
  assert_contains "$out" "verdict=none" "a broken alternation is not a loop"
  out=$("$RING" detect "$state" nothing --now "$t0")
  assert_equals "$out" "verdict=none pattern=- events=0 first_ts=- last_ts=- context_pct=- last_error_status=-" "no ring reads none"
  pass "detect leaves changing outputs, distinct calls and broken alternations alone"
}

test_detect_from_codex_rollout() {
  local state="$TMP_ROOT/codex" f out i
  mkdir -p "$state"
  f="$state/rollout.jsonl"
  printf '{"timestamp":"2026-11-19T20:39:26.000Z","ordinal":0,"type":"session_meta","payload":{"originator":"codex-tui","cli_version":"0.170.0"}}\n' > "$f"
  for i in 1 2 3; do
    printf '{"timestamp":"2026-11-19T20:40:0%s.000Z","ordinal":%s,"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"npm test\\"}","call_id":"c%s"}}\n' "$i" "$i" "$i" >> "$f"
    printf '{"timestamp":"2026-11-19T20:40:0%s.500Z","ordinal":%s,"type":"response_item","payload":{"type":"function_call_output","call_id":"c%s","output":"Process exited with code 1\\nError: 403 Forbidden"}}\n' "$i" "$i" "$i" >> "$f"
  done
  printf '{"timestamp":"2026-11-19T20:40:09.000Z","ordinal":9,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":400000},"model_context_window":475000}}}\n' >> "$f"
  out=$("$RING" detect "$state" cx --codex-rollout "$f" --now "$(date -d 2026-11-19T20:41:00Z +%s 2>/dev/null || echo 1795120860)")
  assert_contains "$out" "verdict=loop pattern=repeat_action_error" "three identical failing Codex calls"
  assert_contains "$out" "context_pct=84" "context percentage from the last token count"
  assert_contains "$out" "last_error_status=403" "a 403 is reported as an auth status"
  printf '{"timestamp":"2026-11-19T20:40:10.000Z","ordinal":10,"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"c9"}}\n' >> "$f"
  printf '{"timestamp":"2026-11-19T20:40:11.000Z","ordinal":11,"type":"response_item","payload":{"type":"function_call_output","call_id":"c9","output":"HTTP 429 rate limited; Process exited with code 2"}}\n' >> "$f"
  out=$("$RING" detect "$state" cx --codex-rollout "$f" --now 1795120860)
  assert_contains "$out" "last_error_status=429" "a later 429 is reported as a rate limit"
  assert_contains "$out" "verdict=none" "a different failing call breaks the repeat"
  pass "detect derives events, context percentage and 401/403 versus 429 status from a Codex rollout"
}

fm_test_run test_append_keeps_hashes_only_and_caps test_detect_five_patterns_within_180s \
  test_detect_leaves_progress_alone test_detect_from_codex_rollout
