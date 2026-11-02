#!/usr/bin/env bash
# tests/fm-ask-hermes.test.sh - Hermes ask bridge through its executable.
#
# Covers argument refusal, topic-to-profile routing, the no-external-action
# request wrapper, approval that does not widen the toolset, message text that
# must not be executed, the private exchange log, parent-channel publication,
# parent-route inbox sequencing, the time bound, provider status, an empty
# reply, and a failed parent-channel append.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP_ROOT=$(fm_test_tmproot fm-ask-hermes)
mkdir -p "$TMP_ROOT"
STUB_DIR="$TMP_ROOT/stub"
STDOUT="$TMP_ROOT/stdout"
STDERR="$TMP_ROOT/stderr"
STUB="$TMP_ROOT/hermes-stub"
CORR=0123456789abcdef
CORR2=fedcba9876543210
mkdir -p "$STUB_DIR"

cat > "$STUB" << 'EOF'
#!/usr/bin/env bash
set -eu
dir=${FM_ASK_HERMES_STUB_DIR:?}
mode=${FM_ASK_HERMES_STUB_MODE:-ok}
mkdir -p "$dir"
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
printf '%s\n' 'session_id: local-test' >&2
case "$mode" in
  sleep) sleep "${FM_ASK_HERMES_STUB_SLEEP_SECS:-30}" ;;
  fail) exit "${FM_ASK_HERMES_STUB_EXIT:-9}" ;;
  empty) exit 0 ;;
  ok) printf '%s\n' "${FM_ASK_HERMES_STUB_REPLY:-stub-reply}" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$STUB"

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

seed_home() {
  local dir
  dir=$(fm_test_tmproot fm-ask-hermes-home)
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' bridge-mate > "$dir/.fm-secondmate-home"
  printf '%s\n' 'schema=fm-secondmate-parent.v1' 'route=remote' 'parent_host=remote.example' \
    > "$dir/.fm-secondmate-parent"
  printf '%s\n' "$dir"
}

invoke() {  # <home> [--stdin <file>] <args...>
  local home=$1 input=/dev/null
  shift
  if [ "${1:-}" = --stdin ]; then
    input=$2
    shift 2
  fi
  rm -f "$STUB_DIR/args" "$STUB_DIR/query" "$STDOUT" "$STDERR"
  set +e
  FM_HOME="$home" \
    FM_ASK_HERMES_BIN="$STUB" \
    FM_ASK_HERMES_STUB_DIR="$STUB_DIR" \
    FM_ASK_HERMES_STUB_MODE="${FM_ASK_HERMES_STUB_MODE:-ok}" \
    FM_ASK_HERMES_STUB_REPLY="${FM_ASK_HERMES_STUB_REPLY:-stub-reply}" \
    FM_ASK_HERMES_STUB_EXIT="${FM_ASK_HERMES_STUB_EXIT:-9}" \
    FM_ASK_HERMES_STUB_SLEEP_SECS="${FM_ASK_HERMES_STUB_SLEEP_SECS:-30}" \
    bash "$ROOT/bin/fm-ask-hermes.sh" "$@" < "$input" >"$STDOUT" 2>"$STDERR"
  INVOKE_RC=$?
  return "$INVOKE_RC"
}

arg_at() {  # <index-from-1>
  tr '\0' '\n' < "$STUB_DIR/args" | sed -n "${1}p"
}

arg_count() {
  tr '\0' '\n' < "$STUB_DIR/args" | sed '/^$/d' | wc -l | tr -d ' '
}

write_msg() {  # <text>
  local path="$TMP_ROOT/message"
  printf '%s\n' "$1" > "$path"
  printf '%s\n' "$path"
}

parent_file() { printf '%s/state/parent-replies.status' "$1"; }

log_file() { printf '%s/data/hermes-bridge/log.jsonl' "$1"; }

rejects_bad_arguments() {
  local home rc
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  bash "$ROOT/bin/fm-ask-hermes.sh" --help >"$STDOUT" 2>"$STDERR" || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "help exited $rc"
  grep -q 'toolset clarify' "$STDOUT" || fail "help omitted the clarify toolset"
  rc=0
  bash "$ROOT/bin/fm-ask-hermes.sh" >"$STDOUT" 2>"$STDERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "no args exited $rc"
  home=$(seed_home)
  invoke "$home" --corr zzzz --topic admin --message-file "$(write_msg hello)"
  [ "$INVOKE_RC" -eq 2 ] || fail "bad corr exited $INVOKE_RC"
  [ ! -e "$STUB_DIR/args" ] || fail "bad corr invoked the provider"
  invoke "$home" --corr "$CORR" --message-file "$(write_msg hello)"
  [ "$INVOKE_RC" -eq 2 ] || fail "missing topic exited $INVOKE_RC"
  invoke "$home" --corr "$CORR" --topic desktop --message-file "$(write_msg hello)"
  [ "$INVOKE_RC" -eq 2 ] || fail "profile-as-topic exited $INVOKE_RC"
  [ ! -e "$STUB_DIR/args" ] || fail "bad topic invoked the provider"
  : > "$TMP_ROOT/empty"
  invoke "$home" --stdin "$TMP_ROOT/empty" --corr "$CORR" --topic admin
  [ "$INVOKE_RC" -eq 2 ] || fail "empty stdin exited $INVOKE_RC"
  pass "bad arguments are refused before the provider runs"
}

routes_topic_to_profile() {
  local home msg
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  msg=$(write_msg 'route check')
  invoke "$home" --corr "$CORR" --topic admin --message-file "$msg"
  [ "$INVOKE_RC" -eq 0 ] || fail "admin route exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(arg_count)" -eq 14 ] || fail "admin argv count $(arg_count)"
  [ "$(arg_at 1)" = --profile ] || fail "argv 1"
  [ "$(arg_at 2)" = desktop ] || fail "admin profile $(arg_at 2)"
  [ "$(arg_at 3)" = chat ] || fail "argv 3"
  [ "$(arg_at 4)" = --oneshot ] || fail "argv 4"
  [ "$(arg_at 5)" = --quiet ] || fail "argv 5"
  [ "$(arg_at 6)" = --query-file ] || fail "argv 6"
  [ "$(arg_at 8)" = --toolsets ] || fail "argv 8"
  [ "$(arg_at 9)" = clarify ] || fail "toolset $(arg_at 9)"
  [ "$(arg_at 10)" = --max-turns ] || fail "argv 10"
  [ "$(arg_at 11)" = 2 ] || fail "max-turns $(arg_at 11)"
  [ "$(arg_at 12)" = --ignore-rules ] || fail "argv 12"
  [ "$(arg_at 13)" = --source ] || fail "argv 13"
  [ "$(arg_at 14)" = tool ] || fail "source $(arg_at 14)"
  invoke "$home" --corr "$CORR2" --topic ops --message-file "$msg"
  [ "$INVOKE_RC" -eq 0 ] || fail "ops route exited $INVOKE_RC"
  [ "$(arg_at 2)" = ops ] || fail "ops profile $(arg_at 2)"
  [ "$(arg_at 9)" = clarify ] || fail "ops toolset $(arg_at 9)"
  pass "admin selects desktop and ops selects ops"
}

wraps_request_and_keeps_clarify_toolset() {
  local home msg statement
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  msg=$(write_msg 'plain request')
  statement="$TMP_ROOT/vague-statement"
  printf '%s\n' approved > "$statement"
  invoke "$home" --corr "$CORR" --topic admin --message-file "$msg" \
    --approved-action rotate-log --approved-statement-file "$statement"
  [ "$INVOKE_RC" -eq 2 ] || fail "vague approval exited $INVOKE_RC"
  [ ! -e "$STUB_DIR/args" ] || fail "vague approval invoked the provider"
  statement="$TMP_ROOT/missing-action-statement"
  printf '%s\n' 'this statement is long enough but names no action' > "$statement"
  invoke "$home" --corr "$CORR" --topic admin --message-file "$msg" \
    --approved-action rotate-log --approved-statement-file "$statement"
  [ "$INVOKE_RC" -eq 2 ] || fail "statement without the action exited $INVOKE_RC"
  statement="$TMP_ROOT/good-statement"
  printf '%s\n' 'rotate-log is approved for this one local maintenance request only' > "$statement"
  invoke "$home" --corr "$CORR" --topic admin --message-file "$msg" \
    --approved-action rotate-log --approved-statement-file "$statement"
  [ "$INVOKE_RC" -eq 0 ] || fail "specific approval exited $INVOKE_RC ($(cat "$STDERR"))"
  [ "$(arg_at 9)" = clarify ] || fail "approval widened the toolset to $(arg_at 9)"
  tr '\0' '\n' < "$STUB_DIR/args" | grep -q -x -- --yolo && fail "approval passed --yolo"
  grep -q 'Do not take any other external action.' "$STUB_DIR/query" \
    || fail "approval wrapper omitted the external-action limit"
  grep -q 'Approved action: rotate-log' "$STUB_DIR/query" || fail "approval action missing from query"
  grep -q 'Do not post publicly' "$STUB_DIR/query" || fail "public-post limit missing"
  grep -q 'plain request' "$STUB_DIR/query" || fail "request text missing from query"
  pass "approval stays on toolset clarify and a vague statement is refused"
}

does_not_execute_message_text() {
  local home marker msg
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  marker="$TMP_ROOT/should-not-exist"
  rm -f "$marker"
  msg=$(write_msg "before \$(touch $marker) after")
  invoke "$home" --corr "$CORR" --topic admin --message-file "$msg"
  [ "$INVOKE_RC" -eq 0 ] || fail "literal message exited $INVOKE_RC"
  [ ! -e "$marker" ] || fail "message file was executed"
  grep -F -q "\$(touch $marker)" "$STUB_DIR/query" || fail "query lost the literal message"
  if tr '\0' '\n' < "$STUB_DIR/args" | grep -F -q "touch $marker"; then
    fail "message text was passed as an argument"
  fi
  printf '%s\n' "stdin \$(touch $marker)" > "$TMP_ROOT/stdin-msg"
  invoke "$home" --stdin "$TMP_ROOT/stdin-msg" --corr "$CORR2" --topic ops
  [ "$INVOKE_RC" -eq 0 ] || fail "stdin message exited $INVOKE_RC"
  [ ! -e "$marker" ] || fail "stdin message was executed"
  grep -F -q "\$(touch $marker)" "$STUB_DIR/query" || fail "stdin query lost the literal message"
  pass "message text is transported literally and is not executed"
}

writes_private_jsonl_and_parent_reply() {
  local home log parent mode dirmode reply
  unset FM_ASK_HERMES_STUB_MODE || true
  FM_ASK_HERMES_STUB_REPLY='he said "ok"'
  home=$(seed_home)
  invoke "$home" --corr "$CORR" --topic admin --message-file "$(write_msg 'say "hi" and a\b')"
  unset FM_ASK_HERMES_STUB_REPLY || true
  [ "$INVOKE_RC" -eq 0 ] || fail "logged exchange exited $INVOKE_RC ($(cat "$STDERR"))"
  grep -F -q -x 'he said "ok"' "$STDOUT" || fail "stdout was not the provider reply"
  if grep -q '^session_id:' "$STDERR"; then
    fail "provider session id was forwarded"
  fi
  grep -q '^exchange=' "$STDERR" || fail "exchange id missing from stderr"
  log=$(log_file "$home")
  parent=$(parent_file "$home")
  [ -f "$log" ] || fail "log missing"
  mode=$(mode_of "$log")
  dirmode=$(mode_of "$(dirname "$log")")
  [ "$mode" = 600 ] || fail "log mode $mode"
  [ "$dirmode" = 700 ] || fail "log dir mode $dirmode"
  jq -e '
    .timestamp and .exchange_id and .correlation_id == "0123456789abcdef"
    and .target == "hermes" and .topic == "admin" and .profile == "desktop"
    and .direction == "outbound" and .outcome == "ok" and .exit_code == 0
    and .request == "say \"hi\" and a\\b" and .reply == "he said \"ok\""
    and .version == ""
  ' "$log" >/dev/null || fail "log row did not round-trip: $(cat "$log")"
  grep -E -q "^done \[corr=${CORR}\] \[at=[0-9]+\]: hermes topic=admin profile=desktop exchange=[0-9a-f]{16} he said \"ok\"" \
    "$parent" || fail "parent reply missing: $(cat "$parent")"
  reply=$(jq -r .reply "$log")
  [ "$reply" = 'he said "ok"' ] || fail "reply decoded as $reply"
  pass "exchange log is private JSON and the parent channel receives the reply"
}

hashes_secret_looking_text() {
  local home log
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  invoke "$home" --corr "$CORR" --topic admin \
    --message-file "$(write_msg 'prefix token=abc123 suffix')"
  [ "$INVOKE_RC" -eq 0 ] || fail "hashed exchange exited $INVOKE_RC"
  log=$(log_file "$home")
  if grep -F -q abc123 "$log"; then
    fail "log stored secret-looking request text"
  fi
  jq -e '.request | startswith("sha256:")' "$log" >/dev/null || fail "request was not hashed: $(cat "$log")"
  if grep -F -q abc123 "$(parent_file "$home")"; then
    fail "parent channel stored secret-looking request text"
  fi
  pass "secret-looking request text is hashed in the log"
}

inbound_sequences_parent_route_inbox() {
  local home inbox
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  invoke "$home" --corr "$CORR" --inbound --message-file "$(write_msg 'relay one')"
  [ "$INVOKE_RC" -eq 0 ] || fail "first inbound exited $INVOKE_RC ($(cat "$STDERR"))"
  [ ! -e "$STUB_DIR/args" ] || fail "inbound invoked the provider"
  inbox="$home/state/parent-route/bridge-mate.inbox"
  [ -f "$inbox/001.msg" ] || fail "001.msg missing"
  grep -F -q '[fm-from-firstmate]' "$inbox/001.msg" || fail "marker missing"
  grep -F -q "corr=$CORR" "$inbox/001.msg" || fail "corr missing"
  grep -F -q 'relay one' "$inbox/001.msg" || fail "body missing"
  invoke "$home" --corr "$CORR2" --inbound --message-file "$(write_msg 'relay two')"
  [ "$INVOKE_RC" -eq 0 ] || fail "second inbound exited $INVOKE_RC"
  [ -f "$inbox/002.msg" ] || fail "002.msg missing"
  [ -f "$inbox/001.msg" ] || fail "001.msg was reused"
  if [ -f "$(parent_file "$home")" ] && grep -q '^done ' "$(parent_file "$home")"; then
    fail "inbound published a done reply"
  fi
  mkdir -p "$home/state/parent-route"
  printf '%s\n' 'backend=not-a-backend' 'window=nowhere' > "$home/state/parent-route/bridge-mate.meta"
  invoke "$home" --corr "$CORR" --inbound --message-file "$(write_msg 'relay three')"
  [ "$INVOKE_RC" -eq 0 ] || fail "ring failure failed the write: $INVOKE_RC ($(cat "$STDERR"))"
  [ -f "$inbox/003.msg" ] || fail "003.msg missing after doorbell failure"
  jq -e 'select(.direction == "inbound" and .outcome == "recorded" and .exit_code == 0)' \
    "$(log_file "$home")" >/dev/null || fail "inbound log row missing"
  pass "inbound records are sequenced and a doorbell failure keeps the record"
}

timeout_preserves_124() {
  local home parent
  home=$(seed_home)
  FM_ASK_HERMES_STUB_MODE=sleep FM_ASK_HERMES_STUB_SLEEP_SECS=30 \
    invoke "$home" --corr "$CORR" --topic admin --timeout 1 --message-file "$(write_msg ping)"
  unset FM_ASK_HERMES_STUB_MODE || true
  [ "$INVOKE_RC" -eq 124 ] || fail "timeout exited $INVOKE_RC ($(cat "$STDERR"))"
  parent=$(parent_file "$home")
  grep -q "^failed \[corr=${CORR}\] " "$parent" || fail "timeout did not publish a failure"
  if grep -q "^done \[corr=${CORR}\] " "$parent"; then
    fail "timeout published success"
  fi
  jq -e '.outcome == "timeout" and .exit_code == 124' "$(log_file "$home")" >/dev/null \
    || fail "timeout log row missing: $(cat "$(log_file "$home")")"
  pass "a hit time bound exits 124 and does not publish success"
}

provider_failure_preserves_status() {
  local home parent
  home=$(seed_home)
  FM_ASK_HERMES_STUB_MODE=fail FM_ASK_HERMES_STUB_EXIT=9 \
    invoke "$home" --corr "$CORR" --topic admin --message-file "$(write_msg ping)"
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_EXIT || true
  [ "$INVOKE_RC" -eq 9 ] || fail "provider failure exited $INVOKE_RC"
  parent=$(parent_file "$home")
  grep -q "^failed \[corr=${CORR}\] " "$parent" || fail "provider failure was not published"
  if grep -q "^done " "$parent"; then
    fail "provider failure published success"
  fi
  jq -e '.outcome == "provider-failed" and .exit_code == 9' "$(log_file "$home")" >/dev/null \
    || fail "provider-failed log row missing"
  pass "provider status 9 is preserved and is not a successful reply"
}

empty_reply_is_failure() {
  local home parent
  home=$(seed_home)
  FM_ASK_HERMES_STUB_MODE=empty \
    invoke "$home" --corr "$CORR" --topic admin --message-file "$(write_msg ping)"
  unset FM_ASK_HERMES_STUB_MODE || true
  [ "$INVOKE_RC" -eq 1 ] || fail "empty reply exited $INVOKE_RC"
  parent=$(parent_file "$home")
  if grep -q "^done " "$parent"; then
    fail "empty reply published success"
  fi
  jq -e '.outcome == "empty" and .exit_code == 1' "$(log_file "$home")" >/dev/null \
    || fail "empty log row missing"
  pass "an empty provider reply is a failure"
}

channel_failure_is_exit_4() {
  local home
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  mkdir -p "$home/state/parent-replies.status"
  invoke "$home" --corr "$CORR" --topic admin --message-file "$(write_msg ping)"
  [ "$INVOKE_RC" -eq 4 ] || fail "undelivered reply exited $INVOKE_RC ($(cat "$STDERR"))"
  grep -F -q -x 'stub-reply' "$STDOUT" || fail "undelivered reply hid the provider stdout"
  jq -e '.outcome == "reply-undelivered" and .exit_code == 4' "$(log_file "$home")" >/dev/null \
    || fail "undelivered log row missing: $(cat "$(log_file "$home")")"
  pass "a failed parent-channel append exits 4 and keeps the reply"
}

concurrent_appends_stay_valid_json() {
  local home log line count one two p1 p2
  unset FM_ASK_HERMES_STUB_MODE FM_ASK_HERMES_STUB_REPLY || true
  home=$(seed_home)
  one=$(write_msg one)
  two="$TMP_ROOT/message-two"
  printf '%s\n' two > "$two"
  invoke "$home" --corr "$CORR" --topic admin --message-file "$one" &
  p1=$!
  invoke "$home" --corr "$CORR2" --topic ops --message-file "$two" &
  p2=$!
  wait "$p1" || fail "first concurrent ask failed"
  wait "$p2" || fail "second concurrent ask failed"
  log=$(log_file "$home")
  count=$(wc -l < "$log" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "concurrent log lines: $count"
  while IFS= read -r line; do
    printf '%s\n' "$line" | jq -e '.exchange_id and .correlation_id and .outcome == "ok"' >/dev/null \
      || fail "torn log line: $line"
  done < "$log"
  pass "concurrent appends stay valid JSON"
}

fm_test_run \
  rejects_bad_arguments \
  routes_topic_to_profile \
  wraps_request_and_keeps_clarify_toolset \
  does_not_execute_message_text \
  writes_private_jsonl_and_parent_reply \
  hashes_secret_looking_text \
  inbound_sequences_parent_route_inbox \
  timeout_preserves_124 \
  provider_failure_preserves_status \
  empty_reply_is_failure \
  channel_failure_is_exit_4 \
  concurrent_appends_stay_valid_json
