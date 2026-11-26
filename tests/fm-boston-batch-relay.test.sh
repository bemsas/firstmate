#!/usr/bin/env bash
# Two sandbox homes, real fm-on and remote job worker, simulated SSH boundary.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

fixture=$(fm_test_tmproot fm-boston-relay)
code="$fixture/code"
vm="$fixture/vm-build"
ops="$fixture/ops"
request="$fixture/request.md"
result="$fixture/result.md"
corr=a0123456789bcdef
head=1111111111111111111111111111111111111111
base=2222222222222222222222222222222222222222
request_path="data/boston-batch-relay/inbox/request-$corr.md"
result_path="data/boston-batch-relay/inbox/result-$corr.md"
queue=state/.wake-queue
export FM_REMOTE_JOB_STATE_ROOT="$fixture/jobs" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_BOSTON_TEST_ENTRYPOINT="$code/bin/fm-remote-entrypoint.sh"
export FM_SSH_BIN="$fixture/fake-ssh"

cleanup() {
  if [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$code/bin" "$vm/config" "$vm/data" "$vm/state" "$ops/config" "$ops/data" "$ops/state"
for tool in fm-boston-batch-relay.py fm-boston-batch-receive.sh fm-on.sh \
  fm-remote-entrypoint.sh fm-remote-job-lib.sh fm-remote-job-worker.sh \
  fm-secondmate-registry-lib.sh fm-wake-lib.sh fm-path-lib.sh; do
  cp "$ROOT/bin/$tool" "$code/bin/"
done
printf 'fixture\n' > "$code/AGENTS.md"
git -C "$code" init -q
git -C "$code" add AGENTS.md bin

cat > "$FM_SSH_BIN" <<'SH'
#!/usr/bin/env bash
while [ "$1" = -o ]; do shift 2; done
[ "$1" = -- ] || exit 90
shift
case "$1" in ops-host|vm-host) ;; *) exit 91 ;; esac
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
case "${FM_BOSTON_TEST_LINK:-up}" in
  down) exit 255 ;;
  drop-receipt) "$FM_BOSTON_TEST_ENTRYPOINT" "$@" || exit "$?"; exit 255 ;;
  up) exec "$FM_BOSTON_TEST_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FM_SSH_BIN"

config() {
  printf '%s\n- %s - Boston (host: %s; root: %s; home: %s; scope: Boston; projects: none; added 2026-11-26)\n' \
    "$2" "$3" "$4" "$code" "$5" > "$1/config/boston-batch-relay"
}
# Preserve the existing shape, distinct rows, and a shell-shaped suite string.
# The transport must never execute the text even in an authenticated request.
# shellcheck disable=SC2016
printf -v row_one -- '- https://github.com/example/widget/pull/7 head %s base %s | make test $(touch %s) | from widget-7' \
  "$head" "$base" "$fixture/suite-executed"
printf -v row_two -- '- https://github.com/example/gadget/pull/3 head %s | make all | from gadget-3' "$base"
printf '%s\n\n%s\n%s\n' '# Boston test requests from vm-build-mate (report PASS/FAIL with head)' \
  "$row_one" "$row_two" > "$request"
printf '%s\n\n%s | FAIL\n%s | PASS\n' '# Boston test results for vm-build-mate' \
  "$row_two" "$row_one" > "$result"

relay() {
  local home=$1
  shift
  FM_HOME="$home" python3 "$code/bin/fm-boston-batch-relay.py" "$@"
}

wire() {
  local home=$1 peer=$2 kind=$3 id=$4 file=$5 digest
  digest=${6:-$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' < "$file")}
  FM_HOME="$home" "$code/bin/fm-on.sh" --stdin "$peer" fm-boston-batch-receive.sh \
    "$kind" "$id" "$digest" < "$file"
}

reject() {
  if "$@" > "$fixture/refused.out" 2> "$fixture/refused.err"; then
    fail "unexpected success for $1"
  fi
}

test_default_local_vm_work() {
  printf 'working: owning VM test slot admitted widget-7\n' > "$vm/state/widget-7.status"
  reject relay "$vm" send "$corr" "$request"
  assert_grep 'Boston peer route is disabled' "$fixture/refused.err" "sender did not require opt-in"
  assert_absent "$vm/data/boston-batch-relay" "default VM work staged a Boston request"
  assert_absent "$ops/$request_path" "default VM work reached Boston"
  assert_absent "$ops/$queue" "default VM work woke Boston"
  pass "default owning-VM work stays local with no Boston route configured"
}

test_round_trip() {
  local prior_worker
  config "$vm" vm-build-mate ops ops-host "$ops"
  config "$ops" ops vm-build-mate vm-host "$vm"
  FM_BOSTON_TEST_LINK=down reject relay "$vm" send "$corr" "$request"
  cmp "$request" "$vm/data/boston-batch-relay/outbox/request-$corr.md"
  assert_absent "$ops/$request_path" "disconnected request reached Ops"
  assert_absent "$ops/$queue" "disconnected request woke Ops"

  # The recipient stored its receipt, but the wake queue was unreadable.
  # Restart the fixture worker and retry without supplying the original file.
  mkdir "$ops/$queue"
  reject relay "$vm" retry
  cmp "$request" "$ops/$request_path"
  rmdir "$ops/$queue"
  prior_worker=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  fm_remote_job_stop_worker_tree "$prior_worker" || true
  relay "$vm" retry
  assert_not_equals "$prior_worker" "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" "worker did not restart"
  wire "$vm" ops request "$corr" "$request"
  assert_equals 1 "$(wc -l < "$ops/$queue" | tr -d ' ')" "duplicate request wakes"
  assert_grep "check: Boston batch request $corr at $request_path" "$ops/$queue" "missing Ops check wake"

  FM_BOSTON_TEST_LINK=drop-receipt reject relay "$ops" send "$corr" "$result"
  cmp "$result" "$vm/$result_path"
  assert_absent "$ops/data/boston-batch-relay/outbox/result-$corr.sent" "lost reply recorded as confirmed"
  relay "$ops" retry
  FM_BOSTON_TEST_LINK=down relay "$ops" retry
  assert_present "$ops/data/boston-batch-relay/outbox/result-$corr.sent" "reply retry not confirmed"
  assert_equals 1 "$(wc -l < "$vm/$queue" | tr -d ' ')" "duplicate result wakes"
  assert_grep "check: Boston batch result $corr at $result_path" "$vm/$queue" "missing VM Build check wake"
  assert_absent "$fixture/suite-executed" "suite text executed"
  pass "a lost link, wake error and lost acknowledgement replay both ways without new receipts"
}

test_rejections() {
  local invalid="$fixture/invalid.md" bad=a0999999999bcdef digest different
  printf 'working: Boston batch data/batch.md\n' > "$vm/state/ordinary.status"
  FM_HOME="$vm" reject "$code/bin/fm-on.sh" ops fm-remote-entrypoint.sh
  assert_grep 'no safe secondmate registry' "$fixture/refused.err" "Boston record grants an ordinary route"
  config "$vm" vm-build-mate ops ops-host "$vm"
  reject wire "$vm" ops request "$bad" "$request"
  assert_grep 'wrong role' "$fixture/refused.err" "misrouted wire did not reach role check"
  config "$vm" vm-build-mate ops ops-host "$ops"
  assert_absent "$vm/data/boston-batch-relay/inbox/request-$bad.md" "misrouted request stored by VM Build"

  mv "$ops/config/boston-batch-relay" "$ops/config/disabled"
  reject wire "$vm" ops request "$bad" "$request"
  assert_grep 'Boston peer route is disabled' "$fixture/refused.err" "recipient did not require opt-in"
  mv "$ops/config/disabled" "$ops/config/boston-batch-relay"

  printf '%s\n%s\n%s\n' '# Boston test requests from vm-build-mate (report PASS/FAIL with head)' \
    "$row_one" '- malformed second row' > "$invalid"
  reject wire "$vm" ops request "$bad" "$invalid"
  assert_grep 'invalid Boston row' "$fixture/refused.err" "invalid row was not rejected"
  python3 - "$request" "$head" > "$invalid" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as request:
    header = request.readline()
row = "- https://github.com/example/widget/pull/{} head " + sys.argv[2] + " | {} | from widget\n"
body = header + "".join(row.format(number, "test") for number in range(1, 10))
padding = 65536 - len(body) - len(row.format(10, ""))
sys.stdout.write(body + row.format(10, "x" * padding))
PY
  reject wire "$vm" ops request "$bad" "$invalid"
  assert_grep 'too large to return a complete result' "$fixture/refused.err" "unanswerable batch was accepted"
  digest=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' < "$request")
  sed '$d' "$request" > "$invalid"
  reject wire "$vm" ops request "$bad" "$invalid" "$digest"
  assert_grep 'digest mismatch' "$fixture/refused.err" "a truncated batch with a valid prefix was accepted"
  assert_absent "$ops/data/boston-batch-relay/inbox/request-$bad.md" "invalid request stored by Ops"
  sed 's/make all/make other/' "$request" > "$invalid"
  reject wire "$vm" ops request "$corr" "$invalid"
  assert_grep 'conflicting Boston record' "$fixture/refused.err" "duplicate id with different bytes was accepted"
  cmp "$request" "$ops/$request_path"

  for different in "s/$head/$base/" "s/base $base/base $head/" 's/make all/make other/' 's/from gadget-3/from other/' 's/PASS/PENDING/'; do
    sed "$different" "$result" > "$invalid"
    reject wire "$ops" vm-build-mate result "$corr" "$invalid"
  done
  reject wire "$ops" vm-build-mate result "$bad" "$result"
  assert_grep 'no matching Boston request' "$fixture/refused.err" "uncorrelated result was accepted"
  assert_absent "$vm/data/boston-batch-relay/inbox/result-$bad.md" "uncorrelated result stored by VM Build"
  cmp "$result" "$vm/$result_path"
  assert_equals 1 "$(wc -l < "$ops/$queue" | tr -d ' ')" "unexpected Ops wake"
  assert_equals 1 "$(wc -l < "$vm/$queue" | tr -d ' ')" "unexpected VM Build wake"
  assert_equals 'working: Boston batch data/batch.md' "$(cat "$vm/state/ordinary.status")" "ordinary status changed"
  assert_equals 'working: owning VM test slot admitted widget-7' "$(cat "$vm/state/widget-7.status")" "owning-VM status changed"
  pass "a sibling route cannot carry other commands, and malformed or mismatched batches leave no receipt"
}

fm_test_run test_default_local_vm_work test_round_trip test_rejections
