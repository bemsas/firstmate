#!/usr/bin/env bash
# Behavioral tests for bin/fm-wait-evidence-lib.sh wait records and crew-state suffixes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(fm_test_tmproot fm-wait-evidence)
HOME_DIR="$T/home"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
mkdir -p "$STATE" "$CONFIG"

# shellcheck source=bin/fm-wait-evidence-lib.sh
. "$ROOT/bin/fm-wait-evidence-lib.sh"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE"
FM_WAIT_EVIDENCE_HOME="$HOME_DIR"
FM_WAIT_EVIDENCE_STATE="$STATE"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

task=wait-ev-task
printf 'paused [at=1000]: waiting on CI until merge\n' > "$STATE/$task.status"

rec=$(task_wait_evidence_status "$task") || fail "paused status should produce wait evidence"
printf '%s' "$rec" | grep -Fq $'\037'external$'\037' || fail "expected external owner in record"
suffix=$(wait_record_format_suffix "$rec") || fail "format suffix failed"
case "$suffix" in
  *'wait-owner: external'*'wait-reason:'*'wait-action:'*) pass "suffix carries owner, reason, and action" ;;
  *) fail "unexpected suffix: $suffix" ;;
esac

printf 'captain-held [at=3000]: decision on merge\n' > "$STATE/$task.status"
rec=$(task_wait_evidence_status "$task") || fail "captain-held line should produce evidence"
suffix=$(wait_record_format_suffix "$rec")
case "$suffix" in
  *'wait-owner: captain'*) pass "captain-held maps to captain owner" ;;
  *) fail "expected captain owner: $suffix" ;;
esac

REPO="$T/repo"
mkdir -p "$REPO"
fm_write_meta "$STATE/$task.meta" \
  "window=firstmate:fm-$task" "worktree=$REPO" "kind=ship" "mode=local-only"
CREW_STATE=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/fm-crew-state.sh" "$task" 2>/dev/null | head -1)
case "$CREW_STATE" in
  *'wait-owner: captain'*) pass "crew-state line includes wait-owner" ;;
  *) fail "crew-state missing wait suffix: $CREW_STATE" ;;
esac

printf 'All wait-evidence tests passed.\n'
