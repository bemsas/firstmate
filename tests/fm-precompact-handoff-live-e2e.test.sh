#!/usr/bin/env bash
# Live guards for bin/fm-precompact-handoff.py against installed Claude Code.
# The default loopback-only guard drives an already-started interactive
# /compact and checks the first model request for the entire bounded page.
# FM_CLAUDE_COMPACT_RESUME_LIVE_E2E=1 requires it wherever invoked.
#
# The legacy credentialed guard is separately opt-in:
# the handoff reads Claude's own PreCompact payload and transcript schema
# (transcript_path, origin.kind human), and the digest relies on Claude adding
# UserPromptSubmit additionalContext to model context, so only the real harness
# proves them. Opt-in because it submits prompts:
#
#   FM_PRECOMPACT_HANDOFF_LIVE_E2E=1 tests/fm-precompact-handoff-live-e2e.test.sh
#
# FM_PRECOMPACT_HANDOFF_LIVE_MODEL picks the model (default claude-haiku-5-5).
# It registers both hooks through --settings in a throwaway project, then:
#   1. a prompt must read back a canary that exists only in the cached alert
#      file the inject hook serves;
#   2. /compact on the resumed session must fire PreCompact and write the
#      handoff block holding that session's own prompt.
# Failures name the harness and its version.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_CLAUDE_COMPACT_RESUME_LIVE_E2E:-}" = 1 ] || {
  [ -z "${FM_PRECOMPACT_HANDOFF_LIVE_E2E:-}" ] && [ "${FM_LIVE:-}" != 1 ];
}; then
  fm_live_gate default-on FM_CLAUDE_COMPACT_RESUME_LIVE_E2E claude python3 tmux tasks-axi jq
  LAB=$(fm_test_tmproot fm-claude-compact-replay)
  VERSION=$(claude --version 2>/dev/null | head -1)
  CLAUDE_BIN=$(command -v claude)
  # A mise command wrapper requires the operator's home to resolve its binary.
  # Resolve it before giving the real process the isolated fixture home.
  if command -v mise >/dev/null 2>&1; then
    CLAUDE_BIN=$(mise which claude 2>/dev/null || printf '%s' "$CLAUDE_BIN")
  fi
  python3 -I "$ROOT/tests/fixtures/fm-claude-compact-replay.py" live "$ROOT" "$LAB/after" \
    --fixed --claude "$CLAUDE_BIN" || fail "Claude Code $VERSION: compact page did not reach the post-compact model request"
  pass "Claude Code $VERSION: the complete compact page reached the first post-compact model request once"
  exit 0
fi

fm_live_gate opt-in FM_PRECOMPACT_HANDOFF_LIVE_E2E claude python3

HOOK="$ROOT/bin/fm-precompact-handoff.py"
MODEL=${FM_PRECOMPACT_HANDOFF_LIVE_MODEL:-claude-haiku-5-5}
LAB=$(fm_test_tmproot fm-precompact-handoff-live)
trap fm_test_cleanup EXIT
unset FM_HOME
VERSION=$(claude --version 2>/dev/null | head -1)
CANARY="canary-$$-$RANDOM"
mkdir -p "$LAB/project" "$LAB/home/state" "$LAB/home/data"
printf 'live canary %s\n' "$CANARY" > "$LAB/home/state/turn-context.alerts"
cat > "$LAB/settings.json" <<EOF
{"hooks":{
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"$HOOK inject --home $LAB/home","timeout":5}]}],
 "PreCompact":[{"hooks":[{"type":"command","command":"$HOOK precompact --home $LAB/home","timeout":15}]}]}}
EOF

claude_p() {  # <args...>
  (cd "$LAB/project" && timeout 180 claude -p --model "$MODEL" --settings "$LAB/settings.json" "$@" </dev/null 2>/dev/null)
}

test_inject_reaches_model_context() {
  local reply
  reply=$(claude_p "If your context has a line starting with 'live canary', reply with exactly the token after 'live canary'; otherwise reply NONE.")
  assert_contains "$reply" "$CANARY" "claude $VERSION: UserPromptSubmit additionalContext did not reach the model"
  pass "claude $VERSION: inject digest reaches model context"
}

test_precompact_writes_handoff() {
  local sid progress="$LAB/home/data/session-progress.md"
  sid=$(claude_p --output-format json "Remember the word PELICAN-$$. Reply OK." \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_id"])') \
    || fail "claude $VERSION: no session id from the first turn"
  claude_p --resume "$sid" "/compact" >/dev/null
  assert_present "$progress" "claude $VERSION: PreCompact did not write $progress"
  assert_grep "PELICAN-$$" "$progress" "claude $VERSION: handoff lacks the session's human prompt"
  assert_grep "trigger manual, session ${sid:0:8}" "$progress" "claude $VERSION: handoff lacks trigger/session from the payload"
  pass "claude $VERSION: PreCompact writes the handoff from the real transcript"
}

fm_test_run test_inject_reaches_model_context test_precompact_writes_handoff
