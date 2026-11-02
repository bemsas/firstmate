#!/usr/bin/env bash
# tests/fm-ask-grokbot.test.sh - fail-closed Grok Bot ask script.
#
# Grok Bot has no documented non-interactive message/reply surface. These
# checks prove the script reports that, records the exchange, and does not
# execute the message or publish a reply.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP_ROOT=$(fm_test_tmproot fm-ask-grokbot)
mkdir -p "$TMP_ROOT"
STDOUT="$TMP_ROOT/stdout"
STDERR="$TMP_ROOT/stderr"
CORR=0123456789abcdef

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

seed_home() {
  local dir
  dir=$(fm_test_tmproot fm-ask-grokbot-home)
  mkdir -p "$dir/data" "$dir/state"
  printf '%s\n' "$dir"
}

invoke() {  # <home> <args...>
  local home=$1
  shift
  rm -f "$STDOUT" "$STDERR"
  set +e
  FM_HOME="$home" bash "$ROOT/bin/fm-ask-grokbot.sh" "$@" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  return "$INVOKE_RC"
}

rejects_bad_arguments() {
  local home rc
  rc=0
  bash "$ROOT/bin/fm-ask-grokbot.sh" --help >"$STDOUT" 2>"$STDERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "help exited $rc"
  grep -q 'no documented non-interactive message/reply' "$STDOUT" || fail "help omitted the missing surface"
  rc=0
  bash "$ROOT/bin/fm-ask-grokbot.sh" >"$STDOUT" 2>"$STDERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "no args exited $rc"
  home=$(seed_home)
  printf '%s\n' hello > "$TMP_ROOT/msg"
  invoke "$home" --corr zzzz --message-file "$TMP_ROOT/msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "bad corr exited $INVOKE_RC"
  [ ! -e "$home/data/hermes-bridge/log.jsonl" ] || fail "bad corr wrote a log"
  invoke "$home" --corr "$CORR" --topic desktop --message-file "$TMP_ROOT/msg"
  [ "$INVOKE_RC" -eq 2 ] || fail "bad topic exited $INVOKE_RC"
  : > "$TMP_ROOT/empty"
  invoke "$home" --corr "$CORR" --message-file "$TMP_ROOT/empty"
  [ "$INVOKE_RC" -eq 2 ] || fail "empty message exited $INVOKE_RC"
  pass "bad Grok Bot arguments are refused"
}

reports_unsupported_and_records_exchange() {
  local home log ver mode dirmode
  home=$(seed_home)
  printf '%s\n' 'ping: reply with your profile name and one-line status' > "$TMP_ROOT/msg"
  invoke "$home" --corr "$CORR" --topic ops --timeout 30 --message-file "$TMP_ROOT/msg"
  [ "$INVOKE_RC" -eq 3 ] || fail "unsupported exchange exited $INVOKE_RC"
  [ ! -s "$STDOUT" ] || fail "unsupported exchange wrote stdout: $(cat "$STDOUT")"
  grep -q 'has no documented non-interactive message/reply surface' "$STDERR" \
    || fail "stderr omitted the missing surface: $(cat "$STDERR")"
  log="$home/data/hermes-bridge/log.jsonl"
  [ -f "$log" ] || fail "log missing"
  mode=$(mode_of "$log")
  dirmode=$(mode_of "$(dirname "$log")")
  [ "$mode" = 600 ] || fail "log mode $mode"
  [ "$dirmode" = 700 ] || fail "log dir mode $dirmode"
  jq -e '
    .target == "grokbot" and .topic == "ops" and .profile == ""
    and .direction == "outbound" and .outcome == "unsupported" and .exit_code == 3
    and .correlation_id == "0123456789abcdef" and .exchange_id and .timestamp
    and (.request | index("ping:") != null) and .reply == ""
  ' "$log" >/dev/null || fail "log row mismatch: $(cat "$log")"
  ver=$(jq -r .version "$log")
  case "$ver" in
    unknown|[0-9]*) ;;
    *) fail "version was not a safe version string: $ver" ;;
  esac
  pass "a valid ask is recorded as unsupported and exits 3"
}

does_not_execute_message_or_publish() {
  local home marker bindir trap literal
  home=$(seed_home)
  marker="$TMP_ROOT/should-not-exist"
  trap="$TMP_ROOT/transport-invoked"
  rm -f "$marker" "$trap"
  bindir="$TMP_ROOT/fakebin"
  mkdir -p "$bindir"
  cat > "$bindir/grokbot" << EOF
#!/bin/sh
printf '%s\n' invoked > '$trap'
EOF
  cat > "$bindir/grok" << EOF
#!/bin/sh
printf '%s\n' invoked > '$trap'
EOF
  cat > "$bindir/open" << EOF
#!/bin/sh
printf '%s\n' invoked > '$trap'
EOF
  chmod +x "$bindir/grokbot" "$bindir/grok" "$bindir/open"
  printf '%s\n' "\$(touch $marker)" > "$TMP_ROOT/msg"
  PATH="$bindir:$PATH" invoke "$home" --corr "$CORR" --inbound --message-file "$TMP_ROOT/msg"
  [ "$INVOKE_RC" -eq 3 ] || fail "inbound refusal exited $INVOKE_RC"
  [ ! -e "$marker" ] || fail "message text was executed"
  [ ! -e "$trap" ] || fail "a transport command was executed"
  [ ! -e "$home/state/parent-replies.status" ] || fail "refusal published a parent reply"
  [ ! -d "$home/state/parent-route" ] || fail "refusal wrote a parent-route inbox"
  literal=$(printf '$%s' '(touch')
  if grep -F -q "touch $marker" "$home/data/hermes-bridge/log.jsonl" \
    && grep -F -q "$literal" "$home/data/hermes-bridge/log.jsonl"; then
    :
  else
    fail "log did not keep the literal message: $(cat "$home/data/hermes-bridge/log.jsonl")"
  fi
  jq -e '.direction == "inbound" and .outcome == "unsupported" and .exit_code == 3' \
    "$home/data/hermes-bridge/log.jsonl" >/dev/null || fail "inbound log row mismatch"
  pass "Grok Bot text is not executed and no reply is published"
}

fm_test_run \
  rejects_bad_arguments \
  reports_unsupported_and_records_exchange \
  does_not_execute_message_or_publish
