#!/usr/bin/env bash
# Credentialed, token-spending Claude scout smoke. Uses disposable task paths,
# real Bash sandboxing and gh-axi's host keyring. No fleet endpoint or worktree
# pool operations. Run with FM_CLAUDE_SANDBOX_LIVE=1; Linux guard only.
# FM_SANDBOX_EVIDENCE_DIR optionally keeps the transcript/policy/probe output.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_SANDBOX_LIVE claude gh-axi jq bwrap socat
[ "$(uname -s)" = Linux ] || fail 'Claude sandbox live guard currently requires Linux'
version=$(claude --version)
# Put the fixture under home to exercise re-opening exact task paths beneath
# the home read mask, not merely writes under an otherwise readable /tmp.
scratch_parent=${FM_SANDBOX_EVIDENCE_DIR:-$HOME/.cache}
mkdir -p "$scratch_parent"
TMP_ROOT=$(TMPDIR="$scratch_parent" fm_test_tmproot fm-claude-sandbox-live)
case "$TMP_ROOT" in "$HOME"/*) ;; *) fail 'live evidence directory must be under HOME to test the home mask' ;; esac
wt="$TMP_ROOT/scout"
home="$TMP_ROOT/home"
id=smoke
mkdir -p "$wt" "$home/state/$id.inbox/handled" "$home/data/$id" "$home/config" "$home/state/operational-inbox"
ln -s "$ROOT/bin" "$home/bin"
: > "$home/config/fleet-ledger"
fm_git_init_commit "$wt"
git -C "$wt" remote add origin https://github.com/kunchenguid/firstmate.git
temp_parent=$("$ROOT/bin/fm-claude-sandbox.sh" --temp-parent)
temp=$(mktemp -d "$temp_parent/XXXXXXXXXXXXXX")
siblingtemp=$(mktemp -d "$temp_parent/XXXXXXXXXXXXXX")
printf 'synthetic other worker scratch\n' > "$siblingtemp/canary"
shared="/tmp/claude-$(id -u)"
# A new uniquely named canary only; never enumerate or read existing scratch.
mkdir -p "$shared"
canary=$(mktemp "$shared/fm-sandbox-canary.XXXXXXXX")
printf 'synthetic sandbox canary\n' > "$canary"
printf 'synthetic home canary\n' > "$TMP_ROOT/hidden-canary"
cleanup() {
  rm -f "$canary"
  rm -rf "$temp" "$siblingtemp"
  fm_test_cleanup
}
trap cleanup EXIT
printf 'synthetic instruction\n' > "$home/state/$id.inbox/001.msg"
"$ROOT/bin/fm-claude-sandbox.sh" "$wt" "$ROOT" "$home" "$home/state" "$home/data" "$home/config" "$id" "$temp" > "$TMP_ROOT/settings.json"
# The host executes the same probe first with a control-only argument, proving
# the planted canary is readable before expecting the sandbox to hide it.
cat > "$wt/probe.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
home=$1
canary=$2
siblingtemp=$3
if [ "${4:-}" = control ]; then cat "$canary" "$siblingtemp/canary" >/dev/null; exit 0; fi
if cat "$siblingtemp/canary" >/dev/null 2>&1; then echo 'other worker scratch leaked'; exit 1; fi
if cat "$canary" >/dev/null 2>&1; then echo 'shared canary leaked'; exit 1; fi
if cat "${home%/*}/hidden-canary" >/dev/null 2>&1; then echo 'home canary leaked'; exit 1; fi
# With home masked, bwrap may accept this into a disposable tmpfs. The host
# assertion below decides whether it escaped, rather than trusting the exit.
touch "$home/state/sibling.status" 2>/dev/null || true
cat "$home/state/smoke.inbox/001.msg" >/dev/null
mv "$home/state/smoke.inbox/001.msg" "$home/state/smoke.inbox/handled/"
printf 'working: sandbox scout\n' >> "$home/state/smoke.status"
"$home/bin/fm-fleet-ledger.sh" appended "$home/config" "$home/state/smoke.status" >/dev/null 2>&1 || true
printf 'sandbox scout report\n' > "$home/data/smoke/report.md"
git status --short >/dev/null
curl -IsS --max-time 20 https://github.com >/dev/null
if curl -IsS --max-time 20 https://example.com >/dev/null 2>&1; then echo 'unlisted host allowed'; exit 1; fi
printf 'SANDBOX_SCOUT_PROBE_OK\n'
SH
bash "$wt/probe.sh" "$home" "$canary" "$siblingtemp" control
printf -v probe_cmd 'bash %q %q %q %q' "$wt/probe.sh" "$home" "$canary" "$siblingtemp"
prompt="This is a finite sandbox verification scout. Use only Bash, with precisely these two separate calls, no pipelines, retries or other commands: (1) $probe_cmd (2) gh-axi issue list --limit 1. Do not read any key or .env file or inspect other sessions. If either call fails, report failure and stop. Otherwise say scout complete."
# Local-only settings and empty MCP avoid unrelated user hooks or servers. The policy
# and prompt are task-owned; the real CLI still obtains its normal subscription
# credentials itself. No worker or supervision markers are inherited.
(
  cd "$wt"
  env -u FM_TASK_ID -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ID -u FM_HOME -u FM_ROOT_OVERRIDE \
    CLAUDE_CODE_TMPDIR="$temp" COMPACT_ADVISER_DISABLE=1 \
    claude -p --model haiku --permission-mode default --setting-sources local \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools Bash \
    --add-dir "$home/state/operational-inbox" --add-dir "$home/state/$id.inbox" \
    --add-dir "$home/data/$id" --add-dir "$ROOT/.agents/skills" \
    --settings "$TMP_ROOT/settings.json" --output-format stream-json --verbose \
    --max-turns 5 "$prompt"
) > "$TMP_ROOT/transcript.jsonl" 2> "$TMP_ROOT/stderr"
if [ -n "${FM_SANDBOX_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$FM_SANDBOX_EVIDENCE_DIR"
  cp "$TMP_ROOT/settings.json" "$TMP_ROOT/transcript.jsonl" "$TMP_ROOT/stderr" "$FM_SANDBOX_EVIDENCE_DIR/"
fi
[ -s "$home/state/smoke.status" ] || fail "$version: status write missing"
[ -s "$home/data/smoke/report.md" ] || fail "$version: report write missing"
jq -se 'any(.[]; .event == "task.status" and .task == "smoke")' "$home/state/fleet-ledger.jsonl" >/dev/null || fail "$version: status ledger hook missing"
[ -f "$home/state/smoke.inbox/handled/001.msg" ] || fail "$version: inbox acknowledgement missing"
[ ! -e "$home/state/sibling.status" ] || fail "$version: sibling write escaped"
jq -se '
  [.. | objects | select(.type? == "tool_use" and .name? == "Bash") | .input.command] as $cmds |
  ($cmds | any(startswith("gh-axi issue list"))) and
  ([.. | objects | select(.type? == "tool_result") | .is_error // false] | all(. == false)) and
  any(.[]; .type == "result" and .is_error == false)
' "$TMP_ROOT/transcript.jsonl" >/dev/null || fail "$version: real gh-axi read or Bash probe failed"
pass "$version: sandbox scout wrote status/report, acknowledged inbox, hid shared canary, contained sibling write and refused unlisted host, and read GitHub via keyring exception"
