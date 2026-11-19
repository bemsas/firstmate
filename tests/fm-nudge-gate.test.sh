#!/usr/bin/env bash
# bin/fm-nudge-gate-lib.sh behavior:
#   1. a focused pane is held and its focus time recorded; it stays held for
#      the cooldown after the human leaves, then is allowed again;
#   2. seq mode holds a pane whose completion_seq has not advanced since the
#      last recorded nudge, and an unchanged sequence and focus write nothing;
#   3. focus mode (doorbell re-delivery) never holds on completion_seq, so a
#      lost delivery to an idle worker is still re-rung;
#   4. a missing or malformed record reads as never nudged, never focused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nudge-gate-lib.sh
. "$ROOT/bin/fm-nudge-gate-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nudge-gate)

test_focus_hold_and_cooldown() {
  local state="$TMP_ROOT/focus" t0=1800000000
  mkdir -p "$state"
  assert_equals "$(fm_nudge_gate_decide "$state" t1 3 true "$t0")" "hold human-focused" "a focused pane is held"
  assert_grep "last_focused_at=$t0" "$state/t1.nudge-gate" "the focus time is recorded"
  assert_equals "$(fm_nudge_gate_decide "$state" t1 3 false $((t0 + 60)))" "hold focus-cooldown" "held within the cooldown"
  assert_equals "$(fm_nudge_gate_decide "$state" t1 3 false $((t0 + 119)))" "hold focus-cooldown" "held until the cooldown ends"
  assert_equals "$(fm_nudge_gate_decide "$state" t1 3 false $((t0 + 120)))" "allow" "allowed once the cooldown passes"
  assert_equals "$(FM_NUDGE_FOCUS_COOLDOWN_SECS=10; fm_nudge_gate_decide "$state" t1 3 false $((t0 + 11)))" "allow" "the cooldown is tunable"
  pass "a focused pane is held, and held for the cooldown after the human leaves"
}

test_seq_idempotency_writes_nothing() {
  local state="$TMP_ROOT/seq" t0=1800000000 before after i
  mkdir -p "$state"
  assert_equals "$(fm_nudge_gate_decide "$state" t2 5 false "$t0" seq)" "allow" "a first nudge is allowed"
  fm_nudge_gate_record "$state" t2 5
  assert_grep "last_nudged_seq=5" "$state/t2.nudge-gate" "the nudged seq is recorded"
  before=$(cksum < "$state/t2.nudge-gate")
  for i in 1 2 3 4 5; do
    assert_equals "$(fm_nudge_gate_decide "$state" t2 5 false $((t0 + 300 * i)) seq)" "hold unchanged-seq" "unchanged seq poll $i is held"
  done
  after=$(cksum < "$state/t2.nudge-gate")
  assert_equals "$after" "$before" "an unchanged sequence and focus write nothing"
  assert_equals "$(fm_nudge_gate_decide "$state" t2 6 false $((t0 + 2000)) seq)" "allow" "a completed turn re-allows one nudge"
  assert_equals "$(fm_nudge_gate_decide "$state" t2 - false $((t0 + 2000)) seq)" "allow" "an unknown seq never holds by itself"
  pass "seq mode allows one nudge per completed turn and an unchanged sequence writes nothing"
}

test_focus_mode_never_holds_on_seq() {
  local state="$TMP_ROOT/doorbell" t0=1800000000
  mkdir -p "$state"
  fm_nudge_gate_record "$state" t3 9
  assert_equals "$(fm_nudge_gate_decide "$state" t3 9 false "$t0")" "allow" "a lost doorbell on an idle worker is still re-rung"
  pass "focus mode never holds a re-delivery on an unchanged completion_seq"
}

test_malformed_record_reads_empty() {
  local state="$TMP_ROOT/bad" t0=1800000000
  mkdir -p "$state"
  printf 'garbage\n' > "$state/t4.nudge-gate"
  assert_equals "$(fm_nudge_gate_decide "$state" t4 1 false "$t0" seq)" "allow" "a malformed record is never nudged, never focused"
  printf 'v1 last_nudged_seq=x9 last_focused_at=abc\n' > "$state/t4.nudge-gate"
  assert_equals "$(fm_nudge_gate_read "$state" t4)" "- 0" "malformed fields read as empty"
  pass "a missing or malformed record reads as never nudged and never focused"
}

fm_test_run test_focus_hold_and_cooldown test_seq_idempotency_writes_nothing \
  test_focus_mode_never_holds_on_seq test_malformed_record_reads_empty
