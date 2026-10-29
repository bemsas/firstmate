#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-feedback.sh worker-directed PR CI delivery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/bin/fm-pr-feedback.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
URL=https://github.com/acme/widget/pull/9

command -v jq >/dev/null 2>&1 || fail "jq required"

T=$(fm_test_tmproot fm-pr-feedback)
HOME_DIR="$T/home"
ROOT_STUB="$T/root"
REPO="$T/repo"
FAKEBIN=$(fm_fakebin "$T")
SEND_LOG="$T/send.log"
export FM_TEST_SEND_LOG="$SEND_LOG"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/check-runs"*)
    jq -n -c --argjson runs "${FM_TEST_CHECK_RUNS:-[]}" '$runs[] |
      {token:("check:" + (.id|tostring) + ":" + (.conclusion // "none")),
       kind:"check", name:.name, state:(.conclusion // .status), url:(.html_url // ""),
       excerpt:((.output.summary // "") | .[:240])}' ;;
  *"--json reviews"*)
    jq -n -c --argjson reviews "${FM_TEST_REVIEWS:-[]}" '$reviews[] |
      select(.state == "CHANGES_REQUESTED") |
      {token:("review:" + (.id|tostring) + ":" + .state + ":" + (.commit.oid // "")),
       kind:"review", name:(.author.login // "reviewer"), state:.state, url:(.url // ""),
       excerpt:((.body // "") | .[:240])}' ;;
  *"--json headRefOid"*) printf '%s\n' "${FM_TEST_HEAD:-abc123def4567890123456789012345678901234}" ;;
  *"--json isDraft"*) printf '{"isDraft":false}\n' ;;
  *"--json headRefOid -q"*) printf '%s\n' "${FM_TEST_HEAD:-abc123def4567890123456789012345678901234}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

mkdir -p "$ROOT_STUB/bin" "$HOME_DIR/state" "$HOME_DIR/data/task-a" "$HOME_DIR/config"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT_STUB/bin/fm-guard.sh"
cat > "$ROOT_STUB/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SEND_LOG"
SH
chmod +x "$ROOT_STUB/bin/fm-guard.sh" "$ROOT_STUB/bin/fm-send.sh"
cp "$ROOT/bin/fm-pr-poll.sh" "$ROOT_STUB/bin/fm-pr-poll.sh"

fm_git_init_commit "$REPO"
fm_git_identity
HEAD=abc123def4567890123456789012345678901234

fm_write_meta "$HOME_DIR/state/task-a.meta" \
  "window=firstmate:fm-task-a" "endpoint_task_id=task-a" "worktree=$REPO" \
  "project=$REPO" "kind=ship" "mode=direct-PR" "pr=$URL" "pr_head=$HEAD"

: > "$SEND_LOG"

export FM_TEST_HEAD="$HEAD"
export FM_TEST_CHECK_RUNS='[{"id":42,"name":"unit","conclusion":"failure","html_url":"https://github.com/acme/widget/runs/1","output":{"summary":"tests failed"}}]'
export FM_TEST_REVIEWS='[]'

env FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
  "$SCRIPT" poll task-a >/dev/null || fail "poll failed"

grep -q '^task-a ' "$SEND_LOG" || fail "worker should receive steer on new CI failure"
lines=$(grep -c '^task-a ' "$SEND_LOG" || true)
[ "$lines" -eq 1 ] || fail "expected one delivery, got $lines"

env FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
  "$SCRIPT" poll task-a >/dev/null || fail "second poll failed"
lines=$(grep -c '^task-a ' "$SEND_LOG" || true)
[ "$lines" -eq 1 ] || fail "duplicate poll must not re-steer: $lines lines"

export FM_TEST_HEAD="def4567890123456789012345678901234567890abcd"
export FM_TEST_CHECK_RUNS='[{"id":99,"name":"unit","conclusion":"failure","html_url":"https://github.com/acme/widget/runs/2","output":{"summary":"still failing"}}]'
env FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
  "$SCRIPT" poll task-a >/dev/null || fail "poll after head change failed"
lines=$(grep -c '^task-a ' "$SEND_LOG" || true)
[ "$lines" -eq 2 ] || fail "new head should produce a new delivery: $lines"

env FM_ROOT_OVERRIDE="$ROOT_STUB" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
  "$SCRIPT" arm task-a >/dev/null || fail "arm failed"
[ -x "$HOME_DIR/state/task-a-pr-feedback.check.sh" ] || fail "feedback check shim missing"

printf 'All pr-feedback tests passed.\n'
