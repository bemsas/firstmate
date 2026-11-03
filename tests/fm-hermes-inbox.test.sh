#!/usr/bin/env bash
# tests/fm-hermes-inbox.test.sh - Hermes note into the main firstmate inbox.
#
# Covers request creation, correlation, reply lookup, both profiles, malformed
# input, a missing reply, and exchange output that does not keep secret text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

TMP_ROOT=$(fm_test_tmproot fm-hermes-inbox)
mkdir -p "$TMP_ROOT"
STDOUT="$TMP_ROOT/stdout"
STDERR="$TMP_ROOT/stderr"
CORR=0123456789abcdef
CORR2=fedcba9876543210
HERMES_HOME_FOR_TEST=''

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

seed_home() {
  local dir
  dir=$(fm_test_tmproot fm-hermes-inbox-home)
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' "$dir"
}

invoke() {  # <home> <args...>
  local home=$1
  shift
  rm -f "$STDOUT" "$STDERR"
  set +e
  if [ -n "$HERMES_HOME_FOR_TEST" ]; then
    FM_HOME="$home" HERMES_HOME="$HERMES_HOME_FOR_TEST" \
      bash "$ROOT/bin/fm-hermes-inbox.sh" "$@" >"$STDOUT" 2>"$STDERR"
  else
    env -u HERMES_HOME FM_HOME="$home" \
      bash "$ROOT/bin/fm-hermes-inbox.sh" "$@" >"$STDOUT" 2>"$STDERR"
  fi
  INVOKE_RC=$?
  set -e
  return 0
}

write_msg() {  # <text>
  local path="$TMP_ROOT/message"
  printf '%s\n' "$1" > "$path"
  printf '%s\n' "$path"
}

log_file() { printf '%s/data/hermes-bridge/log.jsonl' "$1"; }

note_count() {  # <home>
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

rejects_malformed_input() {
  local home rc msg
  rc=0
  bash "$ROOT/bin/fm-hermes-inbox.sh" --help >"$STDOUT" 2>"$STDERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "help exited $rc"
  grep -q 'desktop and --profile ops' "$STDOUT" || fail "help omitted the profiles"
  grep -q 'fm-inbox.sh note' "$STDOUT" || fail "help omitted fm-inbox.sh note"
  rc=0
  bash "$ROOT/bin/fm-hermes-inbox.sh" >"$STDOUT" 2>"$STDERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "no args exited $rc"
  home=$(seed_home)
  msg=$(write_msg hello)
  HERMES_HOME_FOR_TEST=''
  invoke "$home" post --profile admin --corr "$CORR" --message-file "$msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "topic-as-profile exited $INVOKE_RC"
  [ "$(note_count "$home")" = 0 ] || fail "bad profile wrote a note"
  invoke "$home" post --profile default --corr "$CORR" --message-file "$msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "default profile exited $INVOKE_RC"
  invoke "$home" post --profile desktop --corr zzzz --message-file "$msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "bad corr exited $INVOKE_RC"
  [ ! -e "$(log_file "$home")" ] || fail "bad corr wrote a log"
  : > "$TMP_ROOT/empty"
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$TMP_ROOT/empty"
  [ "$INVOKE_RC" -eq 2 ] || fail "empty message exited $INVOKE_RC"
  printf 'a\0b' > "$TMP_ROOT/nul"
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$TMP_ROOT/nul"
  [ "$INVOKE_RC" -eq 2 ] || fail "NUL message exited $INVOKE_RC"
  python3 - "$TMP_ROOT/big" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"a" * 100001)
PY
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$TMP_ROOT/big"
  [ "$INVOKE_RC" -eq 2 ] || fail "oversize message exited $INVOKE_RC"
  invoke "$home" read --profile desktop --corr "$CORR" --message-file "$msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "read with a message file exited $INVOKE_RC"
  HERMES_HOME_FOR_TEST="$TMP_ROOT/profiles/ops"
  mkdir -p "$HERMES_HOME_FOR_TEST"
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "profile mismatch exited $INVOKE_RC"
  grep -q 'does not match HERMES_HOME' "$STDERR" || fail "mismatch stderr: $(cat "$STDERR")"
  HERMES_HOME_FOR_TEST="$TMP_ROOT/profiles/default"
  mkdir -p "$HERMES_HOME_FOR_TEST"
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "unsupported HERMES_HOME exited $INVOKE_RC"
  HERMES_HOME_FOR_TEST=''
  [ "$(note_count "$home")" = 0 ] || fail "malformed input wrote a note"
  pass "malformed inbox input is refused"
}

posts_and_reads_for_both_profiles() {
  local home msg note_id request_id mode dirmode profile corr
  home=$(seed_home)
  msg=$(write_msg 'bridge note')
  for profile in desktop ops; do
    if [ "$profile" = desktop ]; then
      corr=$CORR
    else
      corr=$CORR2
    fi
    HERMES_HOME_FOR_TEST="$TMP_ROOT/profiles/$profile"
    mkdir -p "$HERMES_HOME_FOR_TEST"
    invoke "$home" post --profile "$profile" --corr "$corr" --message-file "$msg"
    [ "$INVOKE_RC" -eq 0 ] || fail "$profile post exited $INVOKE_RC ($(cat "$STDERR"))"
    jq -e --arg profile "$profile" --arg corr "$corr" '
      .schema == "fm-hermes-inbox.v1" and .action == "post" and .profile == $profile
      and .correlation_id == $corr and .outcome == "created"
      and .request_id == ("hermes." + $profile + "." + $corr)
      and (.note_id | type == "string" and length > 0)
      and (has("reply") | not)
    ' "$STDOUT" >/dev/null || fail "$profile post json: $(cat "$STDOUT")"
    note_id=$(jq -r .note_id "$STDOUT")
    request_id=$(jq -r .request_id "$STDOUT")
    invoke "$home" read --profile "$profile" --corr "$corr"
    [ "$INVOKE_RC" -eq 3 ] || fail "$profile missing reply exited $INVOKE_RC ($(cat "$STDOUT"))"
    jq -e --arg id "$note_id" --arg corr "$corr" '
      .outcome == "pending" and .note_id == $id and .correlation_id == $corr
      and (has("reply") | not)
    ' "$STDOUT" >/dev/null || fail "$profile pending json: $(cat "$STDOUT")"
    FM_HOME="$home" bash "$ROOT/bin/fm-inbox.sh" reply "$note_id" 'he said "ok"' >/dev/null
    invoke "$home" read --profile "$profile" --corr "$corr"
    [ "$INVOKE_RC" -eq 0 ] || fail "$profile read exited $INVOKE_RC ($(cat "$STDERR"))"
    jq -e --arg id "$note_id" --arg request "$request_id" '
      .outcome == "reply" and .note_id == $id and .request_id == $request
      and .reply == "he said \"ok\""
    ' "$STDOUT" >/dev/null || fail "$profile reply json: $(cat "$STDOUT")"
  done
  log=$(log_file "$home")
  mode=$(mode_of "$log")
  dirmode=$(mode_of "$(dirname "$log")")
  [ "$mode" = 600 ] || fail "log mode $mode"
  [ "$dirmode" = 700 ] || fail "log dir mode $dirmode"
  jq -e 'select(.profile == "desktop" and .direction == "inbound" and .outcome == "created" and .topic == "admin" and .correlation_id == "0123456789abcdef")' \
    "$log" >/dev/null || fail "desktop create row missing: $(cat "$log")"
  jq -e 'select(.profile == "ops" and .direction == "read" and .outcome == "reply" and .topic == "ops" and .reply == "he said \"ok\"")' \
    "$log" >/dev/null || fail "ops reply row missing: $(cat "$log")"
  HERMES_HOME_FOR_TEST=''
  pass "both profiles create a correlated note and read its reply"
}

replay_keeps_the_original_message() {
  local home first second
  home=$(seed_home)
  HERMES_HOME_FOR_TEST=''
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$(write_msg 'original note')"
  [ "$INVOKE_RC" -eq 0 ] || fail "first post exited $INVOKE_RC"
  first=$(jq -r .note_id "$STDOUT")
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$(write_msg 'original note')"
  [ "$INVOKE_RC" -eq 0 ] || fail "replay exited $INVOKE_RC ($(cat "$STDERR"))"
  second=$(jq -r .note_id "$STDOUT")
  [ "$first" = "$second" ] || fail "replay changed the note id"
  jq -e '.outcome == "replay"' "$STDOUT" >/dev/null || fail "replay outcome: $(cat "$STDOUT")"
  [ "$(note_count "$home")" = 1 ] || fail "replay created another note"
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$(write_msg 'different note')"
  [ "$INVOKE_RC" -eq 2 ] || fail "conflicting replay exited $INVOKE_RC"
  grep -q 'different message' "$STDERR" || fail "conflict stderr: $(cat "$STDERR")"
  FM_HOME="$home" bash "$ROOT/bin/fm-inbox.sh" receipts --all-pending >"$TMP_ROOT/receipts"
  jq -e --arg id "$first" '
    [.pending[] | select(.id == $id) | .body | contains("original note")] | any
  ' "$TMP_ROOT/receipts" >/dev/null || fail "conflict replaced the note"
  jq -e 'select(.outcome == "conflict" and .exit_code == 2)' "$(log_file "$home")" >/dev/null \
    || fail "conflict was not logged"
  pass "a correlation replays the same message and refuses a different one"
}

missing_note_and_literal_text() {
  local home marker msg
  home=$(seed_home)
  HERMES_HOME_FOR_TEST=''
  invoke "$home" read --profile ops --corr "$CORR2"
  [ "$INVOKE_RC" -eq 3 ] || fail "missing note exited $INVOKE_RC"
  jq -e '.outcome == "missing" and .note_id == null and .profile == "ops"' "$STDOUT" >/dev/null \
    || fail "missing json: $(cat "$STDOUT")"
  marker="$TMP_ROOT/should-not-exist"
  rm -f "$marker"
  msg=$(write_msg "before \$(touch $marker) after")
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$msg"
  [ "$INVOKE_RC" -eq 0 ] || fail "literal post exited $INVOKE_RC"
  [ ! -e "$marker" ] || fail "message text was executed"
  FM_HOME="$home" bash "$ROOT/bin/fm-inbox.sh" receipts --all-pending >"$TMP_ROOT/receipts"
  jq -e 'any(.pending[]; .body | contains("$(touch"))' "$TMP_ROOT/receipts" >/dev/null \
    || fail "literal message was not stored"
  pass "a missing note is reported and message text is not executed"
}

does_not_leak_secrets() {
  local home marker bindir
  home=$(seed_home)
  HERMES_HOME_FOR_TEST=''
  printf '%s\n' 'prefix token=abc123 suffix' > "$TMP_ROOT/secret-msg"
  invoke "$home" post --profile desktop --corr "$CORR" --message-file "$TMP_ROOT/secret-msg"
  [ "$INVOKE_RC" -eq 0 ] || fail "secret post exited $INVOKE_RC ($(cat "$STDERR"))"
  if grep -F -q abc123 "$STDOUT" "$STDERR" "$(log_file "$home")"; then
    fail "post output kept the request secret"
  fi
  jq -e 'select(.direction == "inbound" and .outcome == "created") | .request | startswith("sha256:")' \
    "$(log_file "$home")" >/dev/null || fail "request was not hashed: $(cat "$(log_file "$home")")"
  FM_HOME="$home" bash "$ROOT/bin/fm-inbox.sh" note --request-id decoy -- 'password=othersecret' >/dev/null
  invoke "$home" read --profile desktop --corr "$CORR"
  [ "$INVOKE_RC" -eq 3 ] || fail "pending read exited $INVOKE_RC"
  if grep -F -q abc123 "$STDOUT" "$STDERR"; then
    fail "pending read echoed the request secret"
  fi
  if grep -F -q othersecret "$STDOUT" "$STDERR" "$(log_file "$home")"; then
    fail "read leaked another note"
  fi
  marker="$TMP_ROOT/transport-invoked"
  rm -f "$marker"
  bindir="$TMP_ROOT/fakebin"
  mkdir -p "$bindir"
  printf '#!/bin/sh\nprintf invoked > %q\n' "$marker" > "$bindir/hermes"
  chmod +x "$bindir/hermes"
  PATH="$bindir:$PATH" invoke "$home" read --profile desktop --corr "$CORR2"
  [ ! -e "$marker" ] || fail "hermes was executed"
  pass "secrets stay out of the exchange output and other notes are not returned"
}

entry_uses_pins_and_environment() {
  local home skill secret_pin
  home=$(seed_home)
  skill="$TMP_ROOT/skill"
  mkdir -p "$skill/scripts"
  cp "$ROOT/bin/fm-hermes-inbox-entry.sh" "$skill/scripts/firstmate-inbox.sh"
  chmod +x "$skill/scripts/firstmate-inbox.sh"
  printf '%s\n' "$ROOT" > "$skill/firstmate-root"
  printf '%s\n' "$home" > "$skill/fm-home"
  rm -f "$STDOUT" "$STDERR"
  set +e
  env -u FM_HOME -u FM_FIRSTMATE_ROOT -u HERMES_HOME \
    bash "$skill/scripts/firstmate-inbox.sh" post --profile desktop --corr "$CORR" \
    --message-file "$(write_msg 'from the skill entry')" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  set -e
  [ "$INVOKE_RC" -eq 0 ] || fail "pin entry exited $INVOKE_RC ($(cat "$STDERR"))"
  jq -e '.outcome == "created" and .profile == "desktop"' "$STDOUT" >/dev/null \
    || fail "pin entry json: $(cat "$STDOUT")"
  secret_pin="$TMP_ROOT/secret-pin"
  printf '%s\n' 'token=not-a-path' > "$secret_pin"
  ln -s "$secret_pin" "$skill/fm-home-link"
  rm -f "$skill/fm-home"
  ln -s "$secret_pin" "$skill/fm-home"
  rm -f "$STDOUT" "$STDERR"
  set +e
  env -u FM_HOME -u FM_FIRSTMATE_ROOT \
    bash "$skill/scripts/firstmate-inbox.sh" post --profile desktop --corr "$CORR2" \
    --message-file "$(write_msg 'should not post')" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  set -e
  [ "$INVOKE_RC" -eq 2 ] || fail "symlink pin exited $INVOKE_RC"
  if grep -F -q 'not-a-path' "$STDOUT" "$STDERR"; then
    fail "pin refusal printed the pin"
  fi
  rm -f "$STDOUT" "$STDERR"
  set +e
  env -u HERMES_HOME FM_HOME="$TMP_ROOT/missing-home" FM_FIRSTMATE_ROOT="$ROOT" \
    bash "$skill/scripts/firstmate-inbox.sh" read --profile ops --corr "$CORR2" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  set -e
  [ "$INVOKE_RC" -eq 2 ] || fail "environment should override a bad home pin, got $INVOKE_RC ($(cat "$STDERR"))"
  pass "the skill entry reads pins and lets the environment override them"
}

rejects_malformed_input
posts_and_reads_for_both_profiles
replay_keeps_the_original_message
missing_note_and_literal_text
does_not_leak_secrets
entry_uses_pins_and_environment
