#!/usr/bin/env bash
# tests/fm-hermes-daily-digest.test.sh - digest text, ops-topic send, and launchd templates.
#
# Formatting, source refusal, idempotence, and plist install are driven through
# the executables. Hermes and ssh are fixture stubs; the Hermes stub follows
# the installed hermes send argument and --json result contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP_ROOT=$(fm_test_tmproot fm-hermes-daily-digest)
mkdir -p "$TMP_ROOT"
STDOUT="$TMP_ROOT/stdout"
STDERR="$TMP_ROOT/stderr"
STUB_DIR="$TMP_ROOT/stub"
STUB="$TMP_ROOT/hermes-stub"
SSH_STUB="$TMP_ROOT/ssh-stub"
SSH_LOG="$TMP_ROOT/ssh-log"
TARGET='telegram:-1000000000000:7'
NOW=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-11-09T13:00:00Z' +%s 2>/dev/null || date -u -d '2026-11-09T13:00:00Z' +%s)
[ -n "${NOW:-}" ] || fail "could not parse the fixture instant"
LONDON=$(TZ=Europe/London date -r "$NOW" +%F 2>/dev/null || TZ=Europe/London date -d "@$NOW" +%F)
[ -n "${LONDON:-}" ] || fail "could not resolve the London date"

iso_of() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

call_count() {
  if [ -f "$STUB_DIR/calls" ]; then
    wc -l < "$STUB_DIR/calls" | tr -d ' '
  else
    printf '0'
  fi
}

reset_calls() {
  rm -rf "$STUB_DIR"
  mkdir -p "$STUB_DIR"
}

seed_home() {
  local dir
  dir=$(fm_test_tmproot fm-hermes-digest-home)
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  printf '%s\n' bridge-mate > "$dir/.fm-secondmate-home"
  printf '%s\n' 'schema=fm-secondmate-parent.v1' 'route=remote' 'parent_host=remote.example' \
    > "$dir/.fm-secondmate-parent"
  printf '%s\n' "$TARGET" > "$dir/config/hermes-digest-target"
  printf '%s\n' "$dir"
}

plain_home() {
  local dir
  dir=$(fm_test_tmproot fm-hermes-digest-plain)
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

cat > "$STUB" << 'EOF'
#!/usr/bin/env bash
# Fixture for the installed hermes CLI: [--profile <name>] send --to <target>
# --file <path> [--json]. Any other shape is a usage error (exit 2), as in
# hermes send. A chat call is recorded so a test can prove it never happens.
set -eu
dir=${FM_HERMES_STUB_DIR:?}
mkdir -p "$dir"
while ! mkdir "$dir/gate" 2>/dev/null; do
  sleep 0.05
done
printf 'x\n' >> "$dir/calls"
printf '%s\0' "$@" >> "$dir/args"
profile='' cmd='' to='' file='' json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) profile=$2; shift 2 ;;
    send|chat) cmd=$1; shift ;;
    --to) to=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --json) json=1; shift ;;
    *) rmdir "$dir/gate"; printf 'usage: unexpected %s\n' "$1" >&2; exit 2 ;;
  esac
done
rmdir "$dir/gate"
if [ "$cmd" = chat ]; then
  printf 'chat\n' >> "$dir/chat"
  printf '%s\n' ack
  exit 0
fi
[ "$cmd" = send ] && [ -n "$to" ] && [ -f "$file" ] || { printf '%s\n' 'usage: send --to --file' >&2; exit 2; }
cp "$file" "$dir/body"
printf '%s\n' "$profile" > "$dir/profile"
printf '%s\n' "$to" > "$dir/to"
mode=${FM_HERMES_STUB_MODE:-ok}
case "$mode" in
  sleep) sleep "${FM_HERMES_STUB_SLEEP_SECS:-1}"; printf '%s\n' '{"success": true, "note": "sent"}' ;;
  ok) printf '%s\n' '{"success": true, "note": "sent"}' ;;
  fail) printf '%s\n' '{"error": "platform rejected the message"}'; exit 1 ;;
  skipped) printf '%s\n' '{"success": true, "skipped": true, "reason": "cron_auto_delivery_duplicate_target"}' ;;
  garbage) printf '%s\n' 'not json' ;;
  *) exit 99 ;;
esac
[ "$json" -eq 1 ] || exit 98
EOF
chmod +x "$STUB"

cat > "$SSH_STUB" << 'EOF'
#!/usr/bin/env bash
set -eu
log=${FM_HERMES_DIGEST_SSH_LOG:?}
mkdir -p "$(dirname "$log")"
printf '%s\0' "$@" >> "$log"
if [ "${FM_HERMES_DIGEST_SSH_FAIL:-0}" = 1 ]; then
  exit 1
fi
cat "${FM_HERMES_DIGEST_SSH_BODY:?}"
EOF
chmod +x "$SSH_STUB"

invoke() {  # <home> <args...>
  local home=$1
  shift
  rm -f "$STDOUT" "$STDERR"
  set +e
  FM_HOME="$home" \
    FM_HERMES_DIGEST_BIN="${FM_HERMES_DIGEST_BIN:-$STUB}" \
    FM_ASK_HERMES_BIN="$STUB" \
    FM_HERMES_STUB_DIR="$STUB_DIR" \
    FM_HERMES_STUB_MODE="${FM_HERMES_STUB_MODE:-ok}" \
    FM_HERMES_STUB_SLEEP_SECS="${FM_HERMES_STUB_SLEEP_SECS:-1}" \
    FM_HERMES_DIGEST_SOURCE="${FM_HERMES_DIGEST_SOURCE:-}" \
    FM_HERMES_DIGEST_SSH_BIN="${FM_HERMES_DIGEST_SSH_BIN:-}" \
    FM_HERMES_DIGEST_SSH_LOG="${FM_HERMES_DIGEST_SSH_LOG:-$SSH_LOG}" \
    FM_HERMES_DIGEST_SSH_BODY="${FM_HERMES_DIGEST_SSH_BODY:-}" \
    FM_HERMES_DIGEST_SSH_FAIL="${FM_HERMES_DIGEST_SSH_FAIL:-0}" \
    FM_HERMES_DIGEST_STALE_SECONDS="${FM_HERMES_DIGEST_STALE_SECONDS:-}" \
    bash "$ROOT/bin/fm-hermes-daily-digest.sh" "$@" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  return 0
}

write_rich() {  # <path>
  local path=$1 updated recent old edge just_out
  updated=$(iso_of $((NOW - 60)))
  recent=$(iso_of $((NOW - 3600)))
  old=$(iso_of $((NOW - 90000)))
  edge=$(iso_of $((NOW - 86400)))
  just_out=$(iso_of $((NOW - 86401)))
  jq -n \
    --arg updated "$updated" \
    --arg recent "$recent" \
    --arg old "$old" \
    --arg edge "$edge" \
    --arg just_out "$just_out" \
    '{
      schema: "captain-status.v1",
      updated: $updated,
      headline: "Headline only.",
      waiting_on_you: [
        {what: "Send the note", why: "See https://github.com/example/repo/pull/12"},
        {what: "Second", why: "because two"},
        {what: "Third", why: "because three"},
        {what: "Fourth", why: "because four"},
        {what: "Fifth https://github.com/example/repo/pull/5", why: "because five"},
        {what: "Sixth https://github.com/example/repo/pull/66", why: "because six"}
      ],
      done_recently: [
        ("Merged https://github.com/example/repo/pull/9 at " + $recent),
        ("Merged older at " + $old),
        ("Boundary https://github.com/example/repo/pull/24 at " + $edge),
        ("Just outside https://github.com/example/repo/pull/25 at " + $just_out),
        "Merged without a date",
        "Merged at 00:14Z",
        "Landed 9 November 2026 at 12:00:00Z https://github.com/example/repo/pull/4"
      ],
      projects: [
        {
          name: "n",
          where: "the build is blocked",
          next: "unblocked the queue",
          running: ["still blocked."],
          money_goal: ""
        }
      ]
    }' > "$path"
}

write_min() {  # <path> <headline> <updated-iso> [extra-jq]
  local path=$1 headline=$2 updated=$3
  jq -n \
    --arg updated "$updated" \
    --arg headline "$headline" \
    '{
      schema: "captain-status.v1",
      updated: $updated,
      headline: $headline,
      waiting_on_you: [],
      done_recently: [],
      projects: [{name: "n", where: "fine", next: "go", running: [], money_goal: ""}]
    }' > "$path"
}

formats_bounds_action_urls_and_cutoff() {
  local home src out1 out2
  unset FM_HERMES_DIGEST_SOURCE FM_HERMES_STUB_MODE || true
  home=$(plain_home)
  src="$TMP_ROOT/rich.json"
  write_rich "$src"
  reset_calls
  FM_HERMES_DIGEST_SOURCE=$src
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "format exited $INVOKE_RC ($(cat "$STDERR"))"
  out1=$(cat "$STDOUT")
  assert_equals "Do this: Send the note" "$(head -n 1 "$STDOUT")" "first line is the one action"
  assert_contains "$out1" 'https://github.com/example/repo/pull/12' "decision URL preserved"
  assert_contains "$out1" 'https://github.com/example/repo/pull/5' "fifth URL preserved"
  assert_not_contains "$out1" 'https://github.com/example/repo/pull/66' "sixth item stayed capped"
  assert_contains "$out1" 'And 1 more.' "cap reports the remainder"
  assert_contains "$out1" 'the build is blocked' "whole-word blocker kept"
  assert_contains "$out1" 'still blocked.' "trailing blocker kept"
  assert_not_contains "$out1" 'unblocked the queue' "unblocked is not a blocker"
  assert_contains "$out1" 'https://github.com/example/repo/pull/9' "recent merge kept"
  assert_contains "$out1" 'https://github.com/example/repo/pull/24' "24-hour boundary kept"
  assert_contains "$out1" 'https://github.com/example/repo/pull/4' "dated English merge kept"
  assert_not_contains "$out1" 'https://github.com/example/repo/pull/25' "older than 24 hours dropped"
  assert_not_contains "$out1" 'Merged older at' "old merge dropped"
  assert_not_contains "$out1" 'Merged without a date' "undated merge dropped"
  assert_not_contains "$out1" '00:14Z' "clock without a date dropped"
  invoke "$home" --format-only --now "$NOW"
  out2=$(cat "$STDOUT")
  [ "$out1" = "$out2" ] || fail "the same snapshot and instant changed text"
  [ "$(call_count)" -eq 0 ] || fail "format-only called Hermes"
  [ ! -e "$home/data/hermes-bridge/log.jsonl" ] || fail "format-only wrote the exchange log"
  pass "format caps groups, keeps URLs, and cuts merges at 24 hours"
}

formats_empty_groups_without_inventing_items() {
  local home src out
  unset FM_HERMES_DIGEST_SOURCE || true
  home=$(plain_home)
  src="$TMP_ROOT/empty.json"
  write_min "$src" 'All quiet' "$(iso_of $((NOW - 60)))"
  FM_HERMES_DIGEST_SOURCE=$src
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "empty format exited $INVOKE_RC ($(cat "$STDERR"))"
  out=$(cat "$STDOUT")
  assert_equals "Do this: All quiet" "$(head -n 1 "$STDOUT")" "empty decisions use the headline"
  assert_contains "$out" $'- None.' "an empty group says none"
  assert_not_contains "$out" 'https://' "empty input invented no URL"
  jq -n \
    --arg updated "$(iso_of $((NOW - 30)))" \
    '{
      schema: "captain-status.v1",
      updated: $updated,
      headline: "",
      waiting_on_you: [],
      done_recently: [],
      blockers: [],
      projects: [{
        name: "n",
        where: "the build is blocked",
        next: "go",
        running: [],
        money_goal: ""
      }]
    }' > "$TMP_ROOT/explicit-blockers.json"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/explicit-blockers.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "explicit blockers exited $INVOKE_RC"
  out=$(cat "$STDOUT")
  assert_equals "Do this: nothing is waiting on you" "$(head -n 1 "$STDOUT")" "blank headline has a concrete fallback"
  assert_not_contains "$out" 'the build is blocked' "an explicit blocker list replaces project text"
  jq -n \
    --arg updated "$(iso_of $((NOW - 30)))" \
    '{
      schema: "captain-status.v1",
      updated: $updated,
      headline: "h",
      waiting_on_you: [{what: "Decide", why: "now"}],
      done_recently: [],
      blockers: [{what: "CI is blocked", why: "the check failed"}],
      projects: [{name: "n", where: "fine", next: "go", running: [], money_goal: ""}]
    }' > "$TMP_ROOT/object-blocker.json"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/object-blocker.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "object blocker exited $INVOKE_RC"
  assert_contains "$(cat "$STDOUT")" 'CI is blocked. the check failed' "object blocker kept its reason"
  pass "empty groups stay empty and an explicit blocker list wins"
}

refuses_bad_sources() {
  local home src updated
  unset FM_HERMES_DIGEST_SOURCE FM_HERMES_DIGEST_SSH_BIN FM_HERMES_DIGEST_SSH_FAIL || true
  home=$(plain_home)
  updated=$(iso_of $((NOW - 60)))
  src="$TMP_ROOT/good.json"
  write_min "$src" 'Ready' "$updated"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/missing-status.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "missing source exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'absent or not a regular file' "missing source names the problem"
  ln -s "$src" "$TMP_ROOT/status-link"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/status-link
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "symlink source exited $INVOKE_RC"
  printf '%s\n' '{' > "$TMP_ROOT/malformed.json"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/malformed.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "malformed source exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'malformed' "malformed source says so"
  write_min "$TMP_ROOT/stale.json" 'Old' "$(iso_of $((NOW - 150000)))"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/stale.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "stale source exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'stale' "stale source says so"
  write_min "$TMP_ROOT/future.json" 'Future' "$(iso_of $((NOW + 301)))"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/future.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "future source exited $INVOKE_RC"
  printf 'x\0y\n' > "$TMP_ROOT/nul.json"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/nul.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "nul source exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'NUL' "nul source says so"
  dd if=/dev/zero of="$TMP_ROOT/big.json" bs=200001 count=1 status=none 2>/dev/null \
    || dd if=/dev/zero of="$TMP_ROOT/big.json" bs=200001 count=1 >/dev/null 2>&1
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/big.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "oversized source exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'size bound' "oversized source says so"
  for name in .env secrets.env auth.json credentials.json mcp-token.json mytoken.json; do
    cp "$src" "$TMP_ROOT/$name"
    FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/$name
    invoke "$home" --format-only --now "$NOW"
    [ "$INVOKE_RC" -eq 2 ] || fail "$name exited $INVOKE_RC"
    assert_contains "$(cat "$STDERR")" 'credential file' "$name was not refused"
  done
  FM_HERMES_DIGEST_SOURCE=relative.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "relative source exited $INVOKE_RC"
  rm -f "$SSH_LOG"
  FM_HERMES_DIGEST_SSH_BIN=$SSH_STUB
  FM_HERMES_DIGEST_SSH_BODY=$src
  FM_HERMES_DIGEST_SOURCE=ssh://omarchy.example/tmp/secrets.env
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "ssh credential path exited $INVOKE_RC"
  [ ! -e "$SSH_LOG" ] || fail "a credential ssh path invoked ssh"
  FM_HERMES_DIGEST_SOURCE=ssh://omarchy.example/tmp/captain-status.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "ssh source exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'Do this: Ready' "ssh body was formatted"
  tr '\0' '\n' < "$SSH_LOG" > "$TMP_ROOT/ssh-args"
  assert_contains "$(cat "$TMP_ROOT/ssh-args")" 'BatchMode=yes' "ssh stayed noninteractive"
  assert_contains "$(cat "$TMP_ROOT/ssh-args")" 'ConnectTimeout=8' "ssh connect bound missing"
  assert_contains "$(cat "$TMP_ROOT/ssh-args")" 'ClearAllForwardings=yes' "ssh forwarding was not cleared"
  assert_contains "$(cat "$TMP_ROOT/ssh-args")" 'omarchy.example' "ssh host missing"
  FM_HERMES_DIGEST_SSH_FAIL=1
  rm -f "$SSH_LOG"
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "failed ssh exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'could not be read' "failed ssh names the source"
  unset FM_HERMES_DIGEST_SSH_BIN FM_HERMES_DIGEST_SSH_FAIL || true
  pass "bad, secret, and unreadable sources fail closed"
}

resolves_configured_and_local_sources() {
  local home parent src
  unset FM_HERMES_DIGEST_SOURCE || true
  src="$TMP_ROOT/configured.json"
  write_min "$src" 'From config' "$(iso_of $((NOW - 10)))"
  home=$(seed_home)
  printf '%s\n' "$TMP_ROOT/missing-status.json" > "$home/config/hermes-digest-source"
  printf '%s\n' "$src" > "$TMP_ROOT/elsewhere.json"
  cp "$src" "$TMP_ROOT/elsewhere.json"
  write_min "$TMP_ROOT/elsewhere.json" 'From env' "$(iso_of $((NOW - 10)))"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/elsewhere.json
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "env source exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'Do this: From env' "env source lost to config"
  unset FM_HERMES_DIGEST_SOURCE || true
  printf '%s\n' "$src" > "$home/config/hermes-digest-source"
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "config source exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'Do this: From config' "config source was not used"
  unset FM_HERMES_DIGEST_SOURCE || true
  rm -f "$home/config/hermes-digest-source"
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 2 ] || fail "remote parent without a source exited $INVOKE_RC"
  assert_contains "$(cat "$STDERR")" 'not configured' "remote parent invented a source"
  parent=$(plain_home)
  mkdir -p "$parent/data/secondbrain/status"
  write_min "$parent/data/secondbrain/status/captain-status.json" 'From parent' "$(iso_of $((NOW - 10)))"
  printf '%s\n' 'schema=fm-secondmate-parent.v1' 'route=local' "parent_home=$parent" \
    > "$home/.fm-secondmate-parent"
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "local parent source exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'Do this: From parent' "local parent source missed"
  home=$(plain_home)
  mkdir -p "$home/data/secondbrain/status"
  write_min "$home/data/secondbrain/status/captain-status.json" 'From home' "$(iso_of $((NOW - 10)))"
  invoke "$home" --format-only --now "$NOW"
  [ "$INVOKE_RC" -eq 0 ] || fail "home default exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'Do this: From home' "a main home default missed"
  pass "source resolution stays explicit and local"
}

sends_once_to_ops_and_retries_failure() {
  local home src log count digest_dir
  unset FM_HERMES_DIGEST_SOURCE FM_HERMES_STUB_MODE || true
  home=$(seed_home)
  digest_dir="$home/data/hermes-bridge/digest"
  src="$TMP_ROOT/send.json"
  write_min "$src" 'Send this' "$(iso_of $((NOW - 15)))"
  FM_HERMES_DIGEST_SOURCE=$src
  reset_calls
  FM_HERMES_STUB_MODE=fail
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 1 ] || fail "failed send exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(call_count)" -eq 1 ] || fail "failed send call count $(call_count)"
  assert_absent "$digest_dir/$LONDON.delivered" "a failed send was marked delivered"
  assert_absent "$digest_dir/$LONDON.sending" "a failed send left the in-flight claim"
  assert_grep 'exit=1' "$digest_dir/$LONDON.failed" "failure record missing"
  assert_grep 'outcome=failed' "$digest_dir/$LONDON.failed" "failure outcome missing"
  assert_grep 'Do this: Send this' "$digest_dir/$LONDON.msg" "a failed send lost the archive"
  assert_contains "$(cat "$STDERR")" 'did not deliver' "a failed send was silent"
  FM_HERMES_STUB_MODE=ok
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "retry exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(call_count)" -eq 2 ] || fail "retry call count $(call_count)"
  assert_contains "$(cat "$STDOUT")" 'Do this: Send this' "retry hid the digest"
  assert_contains "$(cat "$STDOUT")" 'via=hermes-send' "retry hid the delivery path"
  assert_not_contains "$(cat "$STDOUT")$(cat "$STDERR")" "$TARGET" "output named the target"
  assert_equals "ops" "$(cat "$STUB_DIR/profile")" "send used the ops profile"
  assert_equals "$TARGET" "$(cat "$STUB_DIR/to")" "send used the configured target"
  assert_equals "$(cat "$digest_dir/$LONDON.msg")" "$(cat "$STUB_DIR/body")" "sent body is the archived digest"
  assert_equals "$(printf '%s\n' --profile ops send --to "$TARGET" --file "$digest_dir/$LONDON.msg" --json)" \
    "$(tail -n 8 < <(tr '\0' '\n' < "$STUB_DIR/args"))" "send argv"
  [ ! -e "$STUB_DIR/chat" ] || fail "delivery went through a Hermes chat session"
  assert_absent "$digest_dir/$LONDON.failed" "delivery left the failure record"
  assert_present "$digest_dir/$LONDON.msg" "delivery dropped the archive"
  log="$home/data/hermes-bridge/log.jsonl"
  [ "$(mode_of "$log")" = 600 ] || fail "log mode $(mode_of "$log")"
  jq -se 'any(.[]; .target == "hermes-send" and .topic == "ops" and .outcome == "sent")' \
    "$log" >/dev/null || fail "send log row missing: $(cat "$log")"
  count=$(call_count)
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "duplicate exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'already-delivered' "duplicate did not say it was already delivered"
  [ "$(call_count)" -eq "$count" ] || fail "duplicate sent again"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/missing-status.json
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "delivered date with a missing source exited $INVOKE_RC"
  [ "$(call_count)" -eq "$count" ] || fail "a delivered date sent after the source disappeared"
  pass "the digest is sent once to the ops topic by hermes send and a failed send stays retryable"
}

refuses_a_missing_target_or_hermes() {
  local home src digest_dir
  unset FM_HERMES_DIGEST_SOURCE FM_HERMES_STUB_MODE || true
  src="$TMP_ROOT/target.json"
  write_min "$src" 'Target check' "$(iso_of $((NOW - 15)))"
  FM_HERMES_DIGEST_SOURCE=$src
  for case_name in absent bare symlink; do
    home=$(seed_home)
    digest_dir="$home/data/hermes-bridge/digest"
    case "$case_name" in
      absent) rm -f "$home/config/hermes-digest-target" ;;
      bare) printf '%s\n' telegram > "$home/config/hermes-digest-target" ;;
      symlink)
        printf '%s\n' "$TARGET" > "$TMP_ROOT/linked-target"
        rm -f "$home/config/hermes-digest-target"
        ln -s "$TMP_ROOT/linked-target" "$home/config/hermes-digest-target"
        ;;
    esac
    reset_calls
    invoke "$home" --now "$NOW" --timeout 30
    [ "$INVOKE_RC" -eq 2 ] || fail "$case_name target exited $INVOKE_RC"
    [ "$(call_count)" -eq 0 ] || fail "$case_name target called hermes"
    assert_grep 'outcome=refused-target' "$digest_dir/$LONDON.failed" "$case_name target was not recorded"
    assert_grep 'Do this: Target check' "$digest_dir/$LONDON.msg" "$case_name target lost the archive"
    assert_absent "$digest_dir/$LONDON.delivered" "$case_name target was marked delivered"
    assert_absent "$digest_dir/$LONDON.sending" "$case_name target left a claim"
    assert_contains "$(cat "$STDERR")" 'hermes-digest-target' "$case_name refusal hid the config name"
  done
  home=$(seed_home)
  reset_calls
  FM_HERMES_DIGEST_BIN="$TMP_ROOT/no-such-hermes" invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 2 ] || fail "missing hermes exited $INVOKE_RC"
  assert_grep 'outcome=refused-no-hermes' "$home/data/hermes-bridge/digest/$LONDON.failed" "missing hermes was not recorded"
  assert_contains "$(cat "$STDERR")" 'nothing was sent' "missing hermes refusal was unclear"
  pass "a missing or bare target, or a missing hermes, sends nothing and keeps the archive"
}

unknown_outcomes_keep_the_claim() {
  local home src digest_dir mode want
  unset FM_HERMES_DIGEST_SOURCE FM_HERMES_STUB_MODE || true
  src="$TMP_ROOT/unknown.json"
  write_min "$src" 'Unknown outcome' "$(iso_of $((NOW - 15)))"
  FM_HERMES_DIGEST_SOURCE=$src
  home=$(seed_home)
  reset_calls
  FM_HERMES_STUB_MODE=skipped
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 1 ] || fail "skipped send exited $INVOKE_RC"
  assert_absent "$home/data/hermes-bridge/digest/$LONDON.delivered" "a skipped send was marked delivered"
  assert_absent "$home/data/hermes-bridge/digest/$LONDON.sending" "a skipped send kept the claim"
  for mode in garbage sleep; do
    home=$(seed_home)
    digest_dir="$home/data/hermes-bridge/digest"
    reset_calls
    FM_HERMES_STUB_MODE=$mode
    FM_HERMES_STUB_SLEEP_SECS=5
    invoke "$home" --now "$NOW" --timeout 1
    want=3
    [ "$mode" = sleep ] && want=124
    [ "$INVOKE_RC" -eq "$want" ] || fail "$mode send exited $INVOKE_RC, not $want ($(cat "$STDERR"))"
    assert_absent "$digest_dir/$LONDON.delivered" "$mode send was marked delivered"
    assert_present "$digest_dir/$LONDON.sending" "$mode send dropped the claim"
    assert_grep 'outcome=unconfirmed' "$digest_dir/$LONDON.failed" "$mode outcome was not recorded"
    assert_contains "$(cat "$STDERR")" 'unknown outcome' "$mode send was silent"
    FM_HERMES_STUB_MODE=ok
    invoke "$home" --now "$NOW" --timeout 30
    [ "$INVOKE_RC" -eq 3 ] || fail "rerun after $mode exited $INVOKE_RC"
    [ "$(call_count)" -eq 1 ] || fail "rerun after $mode sent again"
    rm -f "$digest_dir/$LONDON.sending"
    invoke "$home" --now "$NOW" --timeout 30
    [ "$INVOKE_RC" -eq 0 ] || fail "send after clearing the $mode claim exited $INVOKE_RC"
  done
  unset FM_HERMES_STUB_SLEEP_SECS
  pass "a skipped send stays retryable and an unknown outcome blocks a second send"
}

recovers_a_dead_lock() {
  local home src dead
  unset FM_HERMES_DIGEST_SOURCE FM_HERMES_STUB_MODE || true
  src="$TMP_ROOT/recover.json"
  write_min "$src" 'Fresh' "$(iso_of $((NOW - 15)))"
  home=$(seed_home)
  FM_HERMES_DIGEST_SOURCE=$src
  dead=2147483646
  if kill -0 "$dead" 2>/dev/null; then
    dead=$(bash -c 'echo $$')
  fi
  if kill -0 "$dead" 2>/dev/null; then
    fail "could not find a dead pid"
  fi
  mkdir -p "$home/data/hermes-bridge/digest.lock"
  printf '%s\n' "$dead" > "$home/data/hermes-bridge/digest.lock/pid"
  reset_calls
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "dead lock exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(call_count)" -eq 1 ] || fail "dead lock did not send ($(cat "$STDERR"))"
  pass "a dead lock is replaced"
}

concurrent_launches_send_one_digest() {
  local home src p1 p2 r1 r2
  unset FM_HERMES_DIGEST_SOURCE || true
  home=$(seed_home)
  src="$TMP_ROOT/concurrent.json"
  write_min "$src" 'Only once' "$(iso_of $((NOW - 15)))"
  reset_calls
  FM_HOME="$home" \
    FM_HERMES_DIGEST_BIN="$STUB" \
    FM_HERMES_STUB_DIR="$STUB_DIR" \
    FM_HERMES_STUB_MODE=sleep \
    FM_HERMES_STUB_SLEEP_SECS=1 \
    FM_HERMES_DIGEST_SOURCE="$src" \
    bash "$ROOT/bin/fm-hermes-daily-digest.sh" --now "$NOW" --timeout 30 \
    >"$TMP_ROOT/out1" 2>"$TMP_ROOT/err1" &
  p1=$!
  FM_HOME="$home" \
    FM_HERMES_DIGEST_BIN="$STUB" \
    FM_HERMES_STUB_DIR="$STUB_DIR" \
    FM_HERMES_STUB_MODE=sleep \
    FM_HERMES_STUB_SLEEP_SECS=1 \
    FM_HERMES_DIGEST_SOURCE="$src" \
    bash "$ROOT/bin/fm-hermes-daily-digest.sh" --now "$NOW" --timeout 30 \
    >"$TMP_ROOT/out2" 2>"$TMP_ROOT/err2" &
  p2=$!
  r1=0
  r2=0
  wait "$p1" || r1=$?
  wait "$p2" || r2=$?
  [ "$r1" -eq 0 ] || fail "first concurrent launch exited $r1 ($(cat "$TMP_ROOT/err1"))"
  [ "$r2" -eq 0 ] || fail "second concurrent launch exited $r2 ($(cat "$TMP_ROOT/err2"))"
  [ "$(call_count)" -eq 1 ] || fail "concurrent launches sent $(call_count) digests"
  if ! grep -q 'already-delivered' "$TMP_ROOT/out1" "$TMP_ROOT/out2"; then
    fail "neither concurrent launch reported the existing delivery"
  fi
  pass "concurrent launches send one digest for the London date"
}

installs_launchd_templates_without_loading_them() {
  local home dir agents fake before after digest health
  unset FM_HERMES_SCHEDULE_ALLOW_USER_AGENT FM_HERMES_SCHEDULE_PATH FM_HERMES_DIGEST_SOURCE || true
  home=$(plain_home)
  dir="$TMP_ROOT/LaunchAgents"
  fake="$TMP_ROOT/fakebin"
  mkdir -p "$fake"
  cat > "$fake/launchctl" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/launchctl.log"
exit 0
EOF
  chmod +x "$fake/launchctl"
  printf '#!/bin/sh\nexit 0\n' > "$fake/hermes"
  chmod +x "$fake/hermes"
  FM_HOME="$home" bash "$ROOT/bin/fm-hermes-schedule.sh" --help >"$STDOUT" || fail "schedule help failed"
  assert_contains "$(cat "$STDOUT")" 'never loads' "help hid the no-load rule"
  set +e
  PATH="$fake:$PATH" FM_HOME="$home" \
    bash "$ROOT/bin/fm-hermes-schedule.sh" install --launch-agents-dir "$dir" >"$STDOUT" 2>"$STDERR"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "install without a digest target exited $rc"
  assert_contains "$(cat "$STDERR")" 'hermes-digest-target' "refusal did not name the target config"
  assert_absent "$dir/dev.firstmate.hermes-daily-digest.plist" "a digest job without a target was written"
  mkdir -p "$home/config"
  printf '%s\n' "$TARGET" > "$home/config/hermes-digest-target"
  set +e
  PATH="$fake:$PATH" FM_HOME="$home" FM_HERMES_DIGEST_SOURCE='https://example.com/a?b=1&c=2' \
    bash "$ROOT/bin/fm-hermes-schedule.sh" install --launch-agents-dir "$dir" >"$STDOUT" 2>"$STDERR"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "install exited nonzero ($(cat "$STDERR"))"
  [ ! -e "$TMP_ROOT/launchctl.log" ] || fail "install called launchctl"
  digest="$dir/dev.firstmate.hermes-daily-digest.plist"
  health="$dir/dev.firstmate.grokbot-port-health.plist"
  assert_present "$digest" "digest plist missing"
  assert_present "$health" "health plist missing"
  assert_grep '<integer>7</integer>' "$digest" "hour is not 07:00"
  assert_grep '<integer>0</integer>' "$digest" "minute is not 0"
  assert_grep '<false/>' "$digest" "RunAtLoad was not false"
  assert_grep "$home/bin/fm-hermes-daily-digest.sh" "$digest" "digest program is not under FM_HOME"
  assert_grep "<string>$fake:" "$digest" "PATH did not pin the hermes directory first"
  assert_grep '/usr/bin:/bin:/usr/sbin:/sbin</string>' "$digest" "PATH did not end with the minimal default"
  assert_grep 'https://example.com/a?b=1&amp;c=2' "$digest" "source was not XML-escaped"
  assert_grep "$home/data/hermes-bridge/digest-launchd.out" "$digest" "digest log left the home"
  if grep -q '<key>StartInterval</key>' "$digest"; then
    fail "digest plist used an interval"
  fi
  if grep -q -e '.bashrc' -e '.env' -e 'bash -l' "$digest" "$health"; then
    fail "plist sources a shell or credential file"
  fi
  assert_no_grep "$TARGET" "$digest" "the plist carries the target"
  assert_grep '<integer>1800</integer>' "$health" "port check is not every 30 minutes"
  assert_grep "$home/bin/fm-grokbot-port-health.sh" "$health" "health program is not under FM_HOME"
  if grep -q '<key>StartCalendarInterval</key>' "$health"; then
    fail "port check used a calendar interval"
  fi
  printf '%s\n' keep > "$dir/other.plist"
  PATH="$fake:$PATH" FM_HOME="$home" \
    bash "$ROOT/bin/fm-hermes-schedule.sh" status --launch-agents-dir "$dir" >"$STDOUT"
  assert_contains "$(cat "$STDOUT")" "present $digest" "status missed the digest plist"
  assert_contains "$(cat "$STDOUT")" "present $health" "status missed the health plist"
  PATH="$fake:$PATH" FM_HOME="$home" \
    bash "$ROOT/bin/fm-hermes-schedule.sh" uninstall --launch-agents-dir "$dir" >"$STDOUT"
  assert_absent "$digest" "uninstall left the digest plist"
  assert_absent "$health" "uninstall left the health plist"
  assert_present "$dir/other.plist" "uninstall removed an unrelated plist"
  [ ! -e "$TMP_ROOT/launchctl.log" ] || fail "status or uninstall called launchctl"
  agents="${HOME:-}/Library/LaunchAgents"
  before=$(cksum "$agents/dev.firstmate.hermes-daily-digest.plist" 2>/dev/null || printf 'absent')
  set +e
  PATH="$fake:$PATH" FM_HOME="$home" \
    bash "$ROOT/bin/fm-hermes-schedule.sh" install --launch-agents-dir "$agents" >"$STDOUT" 2>"$STDERR"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "user LaunchAgents install exited $rc"
  after=$(cksum "$agents/dev.firstmate.hermes-daily-digest.plist" 2>/dev/null || printf 'absent')
  [ "$before" = "$after" ] || fail "user LaunchAgents directory changed"
  assert_contains "$(cat "$STDERR")" 'FM_HERMES_SCHEDULE_ALLOW_USER_AGENT=1' "refusal hid the guard"
  pass "launchd templates install without loading a job"
}

scheduled_digest_runs_under_its_plist_environment() {
  local home dir userbin src calls rc plist_env prog
  unset FM_HERMES_SCHEDULE_ALLOW_USER_AGENT FM_HERMES_SCHEDULE_PATH FM_HERMES_DIGEST_SOURCE || true
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read the plist"
  home=$(seed_home)
  ln -s "$ROOT/bin" "$home/bin"
  dir="$TMP_ROOT/agents-env"
  userbin="$TMP_ROOT/userbin"
  calls="$TMP_ROOT/userbin-calls"
  mkdir -p "$userbin"
  cat > "$userbin/hermes" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$calls"
printf '%s\n' '{"success": true}'
EOF
  chmod +x "$userbin/hermes"
  src="$TMP_ROOT/plist-env.json"
  write_min "$src" "Plist env headline" "$(iso_of "$(date +%s)")"
  set +e
  PATH="$userbin:$PATH" FM_HOME="$home" FM_HERMES_DIGEST_SOURCE="$src" \
    bash "$ROOT/bin/fm-hermes-schedule.sh" install --launch-agents-dir "$dir" >"$STDOUT" 2>"$STDERR"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "install exited $rc ($(cat "$STDERR"))"
  plist_env=$(python3 -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
e = d["EnvironmentVariables"]
print(e["PATH"]); print(e["FM_HOME"]); print(e["FM_HERMES_DIGEST_SOURCE"]); print(d["ProgramArguments"][0])' \
    "$dir/dev.firstmate.hermes-daily-digest.plist") || fail "digest plist did not parse"
  prog=$(printf '%s\n' "$plist_env" | sed -n 4p)
  set +e
  (
    cd "$home" && env -i HOME="$TMP_ROOT" \
      PATH="$(printf '%s\n' "$plist_env" | sed -n 1p)" \
      FM_HOME="$(printf '%s\n' "$plist_env" | sed -n 2p)" \
      FM_HERMES_DIGEST_SOURCE="$(printf '%s\n' "$plist_env" | sed -n 3p)" \
      "$prog"
  ) >"$STDOUT" 2>"$STDERR"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "digest under the plist environment exited $rc ($(cat "$STDERR"))"
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ] || fail "hermes was not called once under the plist environment"
  assert_grep "--profile ops send --to $TARGET --file " "$calls" "the scheduled run did not use hermes send"
  assert_contains "$(cat "$STDOUT")" 'Plist env headline' "digest text was not printed"
  mkdir -p "$TMP_ROOT/emptybin"
  set +e
  FM_HERMES_SCHEDULE_PATH="$TMP_ROOT/emptybin" FM_HOME="$home" \
    bash "$ROOT/bin/fm-hermes-schedule.sh" install --launch-agents-dir "$TMP_ROOT/agents-refused" >"$STDOUT" 2>"$STDERR"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "install with no hermes on the job PATH exited $rc"
  assert_contains "$(cat "$STDERR")" 'hermes is not on the job PATH' "refusal did not name hermes"
  assert_absent "$TMP_ROOT/agents-refused/dev.firstmate.hermes-daily-digest.plist" "a job without hermes was written"
  pass "a scheduled digest finds hermes under its plist environment, and a job without it is refused"
}

formats_bounds_action_urls_and_cutoff
formats_empty_groups_without_inventing_items
refuses_bad_sources
resolves_configured_and_local_sources
sends_once_to_ops_and_retries_failure
refuses_a_missing_target_or_hermes
unknown_outcomes_keep_the_claim
recovers_a_dead_lock
concurrent_launches_send_one_digest
installs_launchd_templates_without_loading_them
scheduled_digest_runs_under_its_plist_environment
