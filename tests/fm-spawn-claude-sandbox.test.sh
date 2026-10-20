#!/usr/bin/env bash
# Exercise real spawn's sandbox opt-in against isolated git homes and a fake
# pane. Execute emitted commands with an argv/env probe, never source assertions.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-sandbox)
setup_case() {
  local label=$1 harness=${2:-claude}
  CASE="$TMP_ROOT/$label"
  HOME_DIR="$CASE/home"
  WT="$CASE/wt"
  PROJ="$CASE/proj"
  ID=${3:-"sandbox-$label-$$"}
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ" "$WT" "wt-$label"
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  LAUNCH_LOG="$CASE/launch"
  PANE_LOG="$CASE/pane"
}
spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" "$PROJ" --scout "$@"
}
probe() {
  printf '#!/usr/bin/env bash\nPROBE_OUT=%q\n' "$CASE" > "$FAKEBIN/claude"
  cat >> "$FAKEBIN/claude" <<'SH'
set -euo pipefail
printf '%s\n' "${CLAUDE_CODE_TMPDIR-unset}" > "$PROBE_OUT/temp"
printf '%s\n' "$@" > "$PROBE_OUT/args"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --settings ]; then printf '%s\n' "$2" > "$PROBE_OUT/settings"; break; fi
  shift
done
SH
  chmod +x "$FAKEBIN/claude"
  PROBE_OUT="$CASE" PATH="$FAKEBIN:$PATH" /bin/sh -c "$(cat "$LAUNCH_LOG")"
}
setup_case default
spawn > "$CASE/out"
probe
assert_equals unset "$(cat "$CASE/temp")" 'default launch gets no temp override'
jq -e 'has("sandbox") | not' "$CASE/settings" >/dev/null
assert_equals "/tmp/fm-$ID" "$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$ID.meta")" 'default task temp unchanged'
rm -rf "/tmp/fm-$ID"
pass 'default-off launch preserves existing settings, permission flag and temp behavior'

for mode in default auto; do
  setup_case "on-$mode-long-name-for-the-unix-socket-budget"
  : > "$HOME_DIR/config/launch-env-allowlist"
  if [ "$mode" = auto ]; then printf 'auto\n' > "$HOME_DIR/config/claude-permission-mode"; fi
  spawn --claude-sandbox > "$CASE/out" || fail "opt-in spawn: $(cat "$CASE/out")"
  probe
  temp=$(cat "$CASE/temp")
  [ "${#temp}" -le 30 ] || fail 'temp override too long'
  assert_equals "$temp" "$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$ID.meta")" 'teardown owns temp root'
  assert_equals on "$(sed -n 's/^claude_sandbox=//p' "$HOME_DIR/state/$ID.meta")" 'policy persisted'
  grep -qx -- 'local' "$CASE/args" || fail 'sandbox settings sources must be local only'
  grep -qx -- '--permission-mode' "$CASE/args" || fail 'permission mode flag missing'
  grep -qx -- "$mode" "$CASE/args" || fail 'wrong sandbox permission mode'
  jq -e --arg home "$HOME_DIR" --arg id "$ID" '
    .sandbox.enabled and .sandbox.failIfUnavailable and
    (.sandbox.allowUnsandboxedCommands | not) and
    .sandbox.network.strictAllowlist and
    (.sandbox.filesystem.denyRead | index("/tmp") | not) and
    (.sandbox.filesystem.allowWrite | index($home + "/state/" + $id + ".status")) and
    (.sandbox.filesystem.allowWrite | index($home + "/data/" + $id)) and
    (.sandbox.filesystem.allowWrite | index($home + "/state/" + $id + ".inbox")) and
    (.sandbox.filesystem.allowWrite | index($home + "/state") | not) and
    (.sandbox.excludedCommands == ["gh-axi issue list *", "gh-axi pr list *", "gh-axi pr view *"]) and
    .attribution.commit == "" and .feedbackDrafts == "off"
  ' "$CASE/settings" >/dev/null || fail 'sandbox policy grants are incorrect'
  [ -d "$temp" ] || fail 'private temp root missing'
  [ -f "$HOME_DIR/state/$ID.status" ] || fail 'status inode not prepared'
  [ -d "$HOME_DIR/state/$ID.inbox/handled" ] || fail 'inbox not prepared'
  rm -rf "$temp"
  pass "opt-in $mode launch delivers policy and short temp even under cleared env"
done

for harness in codex 'claude --print' ; do
  setup_case "refuse-${harness%% *}" codex
  if out=$(spawn --harness "$harness" --claude-sandbox); then fail 'unsupported launch accepted'; fi
  assert_contains "$out" 'requires a canonical Claude ship/scout launch' 'unsupported sandbox fails closed'
  [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail 'refusal published a task'
  pass "sandbox refuses unsupported launch: $harness"
done

setup_case ledger
: > "$HOME_DIR/config/fleet-ledger"
"$ROOT/bin/fm-claude-sandbox.sh" "$WT" "$ROOT" "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$ID" "$("$ROOT/bin/fm-claude-sandbox.sh" --temp-parent)/test-$$" > "$CASE/policy"
jq -e --arg state "$HOME_DIR/state" '
  (.sandbox.filesystem.allowWrite | index($state + "/fleet-ledger.jsonl") | not) and
  (.sandbox.filesystem.allowWrite | index($state) | not) and
  (.hooks.PostToolUse[0].matcher == "Bash")
' "$CASE/policy" >/dev/null || fail 'ledger policy wrong'
mkdir -p "$HOME_DIR/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$CASE/ledger-call" > "$HOME_DIR/bin/fm-fleet-ledger.sh"
/bin/bash -c "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$CASE/policy")"
assert_equals "$(printf 'appended\n%s\n%s' "$HOME_DIR/config" "$HOME_DIR/state/$ID.status")" "$(cat "$CASE/ledger-call")" 'ledger hook captures only own status'
pass 'optional ledger hook calls the owning writer outside the Bash sandbox without shared write grants'

setup_case unsafe-status
ln -s "$CASE/other-file" "$HOME_DIR/state/$ID.status"
if out=$("$ROOT/bin/fm-claude-sandbox.sh" "$WT" "$ROOT" "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$ID" "$("$ROOT/bin/fm-claude-sandbox.sh" --temp-parent)/test-$$" 2>&1); then
  fail 'symlinked status accepted'
fi
assert_contains "$out" 'regular non-symlink file' 'status symlink refused'
[ ! -e "$CASE/other-file" ] || fail 'status symlink target written'
pass 'sandbox setup refuses a symlinked status without writing its target'

for name in home-one home-two; do
  setup_case "$name" claude "sandbox-same-id-$$"
  spawn --claude-sandbox > "$CASE/out" || fail "spawn: $(cat "$CASE/out")"
  current_temp=$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$ID.meta")
  if [ "$name" = home-one ]; then first_temp=$current_temp; else
    [ "$first_temp" != "$current_temp" ] || fail 'same task id in two homes shared a temp root'
  fi
  rm -rf "$current_temp"
done
pass 'equal task ids in different homes receive different short temp roots'
