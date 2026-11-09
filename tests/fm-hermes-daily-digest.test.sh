#!/usr/bin/env bash
# tests/fm-hermes-daily-digest.test.sh - digest text, ops delivery, and launchd templates.
#
# Formatting, source refusal, idempotence, and plist install are driven through
# the executables. Provider and ssh calls are fixture stubs.
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
set -eu
dir=${FM_ASK_HERMES_STUB_DIR:?}
mkdir -p "$dir"
while ! mkdir "$dir/gate" 2>/dev/null; do
  sleep 0.05
done
printf 'x\n' >> "$dir/calls"
printf '%s\0' "$@" >> "$dir/args"
prev=
q=
for a in "$@"; do
  if [ "$prev" = --query-file ]; then
    q=$a
  fi
  prev=$a
done
if [ -n "${q:-}" ] && [ -f "$q" ]; then
  cp "$q" "$dir/query"
fi
rmdir "$dir/gate"
printf '%s\n' 'session_id: local-test' >&2
mode=${FM_ASK_HERMES_STUB_MODE:-ok}
case "$mode" in
  sleep)
    sleep "${FM_ASK_HERMES_STUB_SLEEP_SECS:-1}"
    printf '%s\n' ack
    ;;
  fail) exit "${FM_ASK_HERMES_STUB_EXIT:-9}" ;;
  ok) printf '%s\n' ack ;;
  *) exit 99 ;;
esac
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
    FM_ASK_HERMES_BIN="$STUB" \
    FM_ASK_HERMES_STUB_DIR="$STUB_DIR" \
    FM_ASK_HERMES_STUB_MODE="${FM_ASK_HERMES_STUB_MODE:-ok}" \
    FM_ASK_HERMES_STUB_EXIT="${FM_ASK_HERMES_STUB_EXIT:-9}" \
    FM_ASK_HERMES_STUB_SLEEP_SECS="${FM_ASK_HERMES_STUB_SLEEP_SECS:-1}" \
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
  unset FM_HERMES_DIGEST_SOURCE FM_ASK_HERMES_STUB_MODE || true
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
  local home src log profile count
  unset FM_HERMES_DIGEST_SOURCE FM_ASK_HERMES_STUB_MODE || true
  home=$(seed_home)
  src="$TMP_ROOT/send.json"
  write_min "$src" 'Send this' "$(iso_of $((NOW - 15)))"
  FM_HERMES_DIGEST_SOURCE=$src
  reset_calls
  FM_ASK_HERMES_STUB_MODE=fail
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 9 ] || fail "failed send exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(call_count)" -eq 1 ] || fail "failed send call count $(call_count)"
  assert_absent "$home/data/hermes-bridge/digest/$LONDON.delivered" "a failed send was marked delivered"
  assert_absent "$home/data/hermes-bridge/digest/$LONDON.sending" "a failed send left the in-flight claim"
  assert_grep 'exit=9' "$home/data/hermes-bridge/digest/$LONDON.failed" "failure record missing"
  FM_ASK_HERMES_STUB_MODE=ok
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "retry exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(call_count)" -eq 2 ] || fail "retry call count $(call_count)"
  assert_contains "$(cat "$STDOUT")" 'Do this: Send this' "retry hid the digest"
  assert_grep 'date=' "$STDOUT" "retry hid the date"
  profile=$(tr '\0' '\n' < "$STUB_DIR/args" | awk 'prev == "--profile" { print; exit } { prev = $0 }')
  [ "$profile" = ops ] || fail "profile was $profile"
  assert_contains "$(cat "$STUB_DIR/query")" 'Do not post publicly' "ops path skipped the ask wrapper"
  assert_contains "$(cat "$STUB_DIR/query")" 'Do this: Send this' "ops query lost the digest"
  log="$home/data/hermes-bridge/log.jsonl"
  [ -f "$log" ] || fail "exchange log missing"
  [ "$(mode_of "$log")" = 600 ] || fail "log mode $(mode_of "$log")"
  [ "$(mode_of "$(dirname "$log")")" = 700 ] || fail "log dir mode $(mode_of "$(dirname "$log")")"
  jq -se 'any(.[]; .topic == "ops" and .profile == "ops" and .direction == "outbound" and .outcome == "ok")' \
    "$log" >/dev/null || fail "ops log row missing: $(cat "$log")"
  count=$(call_count)
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "duplicate exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'already-delivered' "duplicate did not say it was already delivered"
  [ "$(call_count)" -eq "$count" ] || fail "duplicate sent again"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/missing-status.json
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "delivered date with a missing source exited $INVOKE_RC"
  [ "$(call_count)" -eq "$count" ] || fail "a delivered date sent after the source disappeared"
  pass "ops delivery is logged once and a failed send stays retryable"
}

recovers_a_successful_claim_and_a_dead_lock() {
  local home src dead
  unset FM_HERMES_DIGEST_SOURCE FM_ASK_HERMES_STUB_MODE || true
  home=$(seed_home)
  src="$TMP_ROOT/recover.json"
  write_min "$src" 'Fresh' "$(iso_of $((NOW - 15)))"
  mkdir -p "$home/data/hermes-bridge/digest"
  chmod 700 "$home/data/hermes-bridge" "$home/data/hermes-bridge/digest"
  {
    printf '%s\n' 'corr=bbbbbbbbbbbbbbbb'
    printf '%s\n' '---'
    printf '%s\n' 'Do this: planted'
  } > "$home/data/hermes-bridge/digest/$LONDON.sending"
  jq -nc \
    --arg corr bbbbbbbbbbbbbbbb \
    --arg exchange aaaaaaaaaaaaaaaa \
    '{timestamp:"2026-11-09T13:00:00Z",exchange_id:$exchange,correlation_id:$corr,target:"hermes",topic:"ops",profile:"ops",direction:"outbound",outcome:"ok",exit_code:0,request:"planted",reply:"ack",version:""}' \
    > "$home/data/hermes-bridge/log.jsonl"
  chmod 600 "$home/data/hermes-bridge/log.jsonl"
  FM_HERMES_DIGEST_SOURCE=$TMP_ROOT/missing-status.json
  reset_calls
  invoke "$home" --now "$NOW" --timeout 30
  [ "$INVOKE_RC" -eq 0 ] || fail "claim recovery exited $INVOKE_RC ($(cat "$STDERR"))"
  assert_contains "$(cat "$STDOUT")" 'already-delivered' "recovered claim did not record delivery"
  assert_contains "$(cat "$STDOUT")" 'Do this: planted' "recovered claim dropped the stored text"
  assert_contains "$(cat "$STDOUT")" 'exchange=aaaaaaaaaaaaaaaa' "recovered claim dropped the exchange"
  [ "$(call_count)" -eq 0 ] || fail "recovered claim sent again"
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
  pass "a logged in-flight claim is not sent again and a dead lock is replaced"
}

concurrent_launches_send_one_digest() {
  local home src p1 p2 r1 r2
  unset FM_HERMES_DIGEST_SOURCE || true
  home=$(seed_home)
  src="$TMP_ROOT/concurrent.json"
  write_min "$src" 'Only once' "$(iso_of $((NOW - 15)))"
  reset_calls
  FM_HOME="$home" \
    FM_ASK_HERMES_BIN="$STUB" \
    FM_ASK_HERMES_STUB_DIR="$STUB_DIR" \
    FM_ASK_HERMES_STUB_MODE=sleep \
    FM_ASK_HERMES_STUB_SLEEP_SECS=1 \
    FM_HERMES_DIGEST_SOURCE="$src" \
    bash "$ROOT/bin/fm-hermes-daily-digest.sh" --now "$NOW" --timeout 30 \
    >"$TMP_ROOT/out1" 2>"$TMP_ROOT/err1" &
  p1=$!
  FM_HOME="$home" \
    FM_ASK_HERMES_BIN="$STUB" \
    FM_ASK_HERMES_STUB_DIR="$STUB_DIR" \
    FM_ASK_HERMES_STUB_MODE=sleep \
    FM_ASK_HERMES_STUB_SLEEP_SECS=1 \
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
  FM_HOME="$home" bash "$ROOT/bin/fm-hermes-schedule.sh" --help >"$STDOUT" || fail "schedule help failed"
  assert_contains "$(cat "$STDOUT")" 'never loads' "help hid the no-load rule"
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
  assert_grep '/usr/bin:/bin:/usr/sbin:/sbin' "$digest" "PATH was not the minimal default"
  assert_grep 'https://example.com/a?b=1&amp;c=2' "$digest" "source was not XML-escaped"
  assert_grep "$home/data/hermes-bridge/digest-launchd.out" "$digest" "digest log left the home"
  if grep -q '<key>StartInterval</key>' "$digest"; then
    fail "digest plist used an interval"
  fi
  if grep -q -e '.bashrc' -e '.env' -e 'bash -l' "$digest" "$health"; then
    fail "plist sources a shell or credential file"
  fi
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

formats_bounds_action_urls_and_cutoff
formats_empty_groups_without_inventing_items
refuses_bad_sources
resolves_configured_and_local_sources
sends_once_to_ops_and_retries_failure
recovers_a_successful_claim_and_a_dead_lock
concurrent_launches_send_one_digest
installs_launchd_templates_without_loading_them
