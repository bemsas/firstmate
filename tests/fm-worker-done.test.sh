#!/usr/bin/env bash
# Completion effects through the shared status-surface interface: metadata,
# optional capture/checklist, concurrency, retry, and detached wake delivery.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-worker-done)
export FM_HOME="$TMP/initial" FM_STATE_OVERRIDE="$TMP/initial/state"
mkdir -p "$FM_STATE_OVERRIDE"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-push-transition-lib.sh"

make_case() {
  local name=$1
  export FM_HOME="$TMP/$name" FM_STATE_OVERRIDE="$TMP/$name/state"
  export FM_DATA_OVERRIDE="$TMP/$name/data" FM_CONFIG_OVERRIDE="$TMP/$name/config"
  STATE=$FM_STATE_OVERRIDE
  mkdir -p "$STATE" "$FM_DATA_OVERRIDE/job" "$FM_CONFIG_OVERRIDE" "$FM_HOME/bin" \
    "$FM_DATA_OVERRIDE/secondbrain/tools"
  cp "$ROOT/bin/"{fm-worker-done,fm-wake-lib,fm-classify-lib,fm-pr-lib,fm-timeout-lib,fm-path-lib}.sh "$FM_HOME/bin/"
  # shellcheck disable=SC2034 # Read by the real mark_surfaced function sourced above.
  FM_PUSH_TRANSITION_LIB_DIR="$FM_HOME/bin"
  printf 'kind=ship\nharness=codex\n' > "$STATE/job.meta"
  printf 'lessons\n' > "$FM_DATA_OVERRIDE/job/lessons.md"
  cat > "$FM_DATA_OVERRIDE/secondbrain/tools/capture.py" <<'PY'
from pathlib import Path
import sys
home = Path(__file__).resolve().parents[3]
with (home / 'capture.calls').open('a') as log:
    log.write(sys.argv[1] + '\n')
if (home / 'capture.fail').exists():
    sys.exit(2)
PY
  cat > "$FM_HOME/bin/fm-done-check.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --auto ] || shift
printf '%s %s\n' "$1" "$2" >> "$FM_HOME/check.calls"
if [ -f "$FM_HOME/check.gated" ]; then
  : > "$FM_HOME/check.started"
  read -r _ < "$FM_HOME/release"
fi
if [ -f "$FM_HOME/check.error" ]; then exit 3; fi
if [ -f "$FM_HOME/check.fail" ]; then exit 10; fi
if [ -f "$FM_HOME/check.escalate" ]; then exit 11; fi
SH
  printf 'on\n' > "$FM_CONFIG_OVERRIDE/done-check"
}

snapshot() {
  END=$(wc -c < "$STATE/job.status" | tr -d '[:space:]')
  IDENT=$(_fm_open_decisions_file_ident "$STATE/job.status")
}
process_done() {
  snapshot
  bash "$FM_HOME/bin/fm-worker-done.sh" job "$END" "$IDENT" > "$FM_HOME/run.log" 2>&1
}
wait_file() {
  local i
  for ((i=0; i<200; i++)); do
    [ ! -f "$1" ] || return 0
    sleep 0.1
  done
  cat "$FM_STATE_OVERRIDE/worker-done.log" >&2 2>/dev/null || true
  fail "timed out waiting for $1"
}
assert_calls() {
  local file=$1 expected=$2 count=0
  [ ! -f "$file" ] || count=$(wc -l < "$file" | tr -d '[:space:]')
  [ "$count" -eq "$expected" ] || fail "$file: expected $expected calls, got $count"
}

make_case shared
printf 'done [at=123]: ready (https://github.com/example/project/pull/12)\nworking: trailing note\n' > "$STATE/job.status"
snapshot
mark_surfaced "$STATE/job.status" "$END" "$IDENT"
wait_file "$STATE/.worker-done-job/example--project--12.1.checked"
assert_contains "$(cat "$STATE/job.meta")" 'pr=https://github.com/example/project/pull/12' 'shared surface records the done URL before trailing progress'
assert_calls "$FM_HOME/capture.calls" 1
assert_equals 'job https://github.com/example/project/pull/12' "$(cat "$FM_HOME/check.calls")" 'done checker receives its existing task and URL interface'
# Repeated and concurrent surfaces converge to one capture and one checklist.
process_done & p1=$!
process_done & p2=$!
wait "$p1" || fail 'first duplicate failed'
wait "$p2" || fail 'second duplicate failed'
assert_calls "$FM_HOME/capture.calls" 1
assert_calls "$FM_HOME/check.calls" 1
pass 'shared surfaced-status path runs all three effects once'

make_case concurrent
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
process_done & p1=$!
process_done & p2=$!
wait "$p1" || fail 'first concurrent completion failed'
wait "$p2" || fail 'second concurrent completion failed'
assert_calls "$FM_HOME/capture.calls" 1
assert_calls "$FM_HOME/check.calls" 1
pass 'concurrent first completions serialize their side effects'

for harness in codex agy claude; do
  make_case "harness-$harness"
  printf 'kind=ship\nharness=%s\npr=' "$harness" > "$STATE/job.meta"
  printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
  snapshot
  mark_surfaced "$STATE/job.status" "$END" "$IDENT"
  wait_file "$STATE/.worker-done-job/example--project--12.1.checked"
  assert_grep 'pr=https://github.com/example/project/pull/12' "$STATE/job.meta" "$harness completion records empty PR metadata"
  assert_calls "$FM_HOME/capture.calls" 1
  assert_calls "$FM_HOME/check.calls" 1
done
pass 'codex, agy, and claude metadata use the same completion path'

make_case preserve
printf 'pr=https://github.com/other/repo/pull/5\n' >> "$STATE/job.meta"
mkdir -p "$FM_DATA_OVERRIDE/secondbrain/wiki/sources"
touch "$FM_DATA_OVERRIDE/secondbrain/wiki/sources/source-task-job.md"
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
process_done
assert_contains "$(cat "$STATE/job.meta")" 'pr=https://github.com/other/repo/pull/5' 'existing metadata is preserved'
assert_calls "$FM_HOME/capture.calls" 0
assert_calls "$FM_HOME/check.calls" 1
pass 'an existing capture card and PR metadata are respected'

for mode in off absent; do
  make_case "mode-$mode"
  printf '%s\n' "$mode" > "$FM_CONFIG_OVERRIDE/done-check"
  [ "$mode" != absent ] || rm "$FM_CONFIG_OVERRIDE/done-check"
  rm "$FM_DATA_OVERRIDE/job/lessons.md"
  printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
  process_done
  assert_calls "$FM_HOME/capture.calls" 0
  assert_calls "$FM_HOME/check.calls" 0
done
pass 'capture needs lessons and off/absent configs skip the checklist'

for role in scout secondmate; do
  make_case "role-$role"
  printf 'kind=%s\n' "$role" > "$STATE/job.meta"
  printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
  process_done
  assert_calls "$FM_HOME/capture.calls" 0
  assert_calls "$FM_HOME/check.calls" 0
  if grep -q '^pr=' "$STATE/job.meta"; then fail "$role claimed a PR"; fi
done
pass 'scouts and secondmates cannot claim ship completions'

make_case shadow
printf 'shadow\n' > "$FM_CONFIG_OVERRIDE/done-check"
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
process_done
process_done
assert_calls "$FM_HOME/check.calls" 1
printf 'on\n' > "$FM_CONFIG_OVERRIDE/done-check"
process_done
assert_calls "$FM_HOME/check.calls" 2
FM_DONE_CHECK=off process_done
assert_calls "$FM_HOME/check.calls" 2
pass 'shadow mode is retained, on rechecks a shadow receipt, and the environment override wins'

make_case unrelated
cat > "$STATE/job.status" <<'STATUS'
working: https://github.com/example/project/pull/12
note: done: https://github.com/example/project/pull/12
done: ready in branch fm/local-only
done: https://github.com/example/project/pull/12/files
done: https://github.com/example/project/pull/12bad
done: https://github.com/example/project/pull/0
done: https://github.com/example/../pull/12
done: https://github.com/example/project/pull/12 https://github.com/example/project/pull/13
STATUS
process_done
assert_calls "$FM_HOME/capture.calls" 0
assert_calls "$FM_HOME/check.calls" 0
if grep -q '^pr=' "$STATE/job.meta"; then fail 'unrelated status wrote metadata'; fi
pass 'progress, local-only completions, and invalid URLs do not trigger work'

make_case retry
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
touch "$FM_HOME/capture.fail" "$FM_HOME/check.error"
process_done
assert_contains "$(cat "$FM_HOME/run.log")" 'capture failed (exit 2)' 'capture errors are logged'
assert_contains "$(cat "$FM_HOME/run.log")" 'done check failed (exit 3)' 'checker errors are logged'
rm "$FM_HOME/capture.fail" "$FM_HOME/check.error"
process_done
assert_calls "$FM_HOME/capture.calls" 2
assert_calls "$FM_HOME/check.calls" 2
process_done
assert_calls "$FM_HOME/capture.calls" 2
assert_calls "$FM_HOME/check.calls" 2
pass 'failed operations retry without duplicating successful operations'

make_case verdict
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
touch "$FM_HOME/check.fail"
process_done
process_done
assert_calls "$FM_HOME/check.calls" 1
pass 'a completed failed verdict is not steered repeatedly'

make_case new-event
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
touch "$FM_HOME/check.escalate"
process_done
process_done
assert_calls "$FM_HOME/check.calls" 1
rm "$FM_HOME/check.escalate"
printf 'working: fixed the checklist\ndone: https://github.com/example/project/pull/12\n' >> "$STATE/job.status"
process_done
assert_calls "$FM_HOME/check.calls" 2
assert_calls "$FM_HOME/capture.calls" 1
pass 'escalations are receipted and a new done event rechecks the same PR'

make_case detached
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
mkfifo "$FM_HOME/release"
touch "$FM_HOME/check.gated"
snapshot
mark_surfaced "$STATE/job.status" "$END" "$IDENT"
# The caller has returned while the checklist cannot finish until we release it.
wait_file "$FM_HOME/check.started"
[ ! -f "$STATE/.worker-done-job/example--project--12.1.checked" ] || fail 'gated check unexpectedly completed'
printf 'release\n' > "$FM_HOME/release"
wait_file "$STATE/.worker-done-job/example--project--12.1.checked"
pass 'wake delivery returns while a checklist remains blocked'

make_case snapshot
printf 'working: still running\n' > "$STATE/job.status"
snapshot
printf 'done: https://github.com/example/project/pull/12\n' >> "$STATE/job.status"
bash "$FM_HOME/bin/fm-worker-done.sh" job "$END" "$IDENT"
assert_calls "$FM_HOME/check.calls" 0
process_done
assert_calls "$FM_HOME/check.calls" 1
mv "$STATE/job.status" "$STATE/old.status"
printf 'done: https://github.com/example/project/pull/12\n' > "$STATE/job.status"
process_done
assert_calls "$FM_HOME/check.calls" 2
rm "$STATE/job.meta"
process_done
[ ! -f "$STATE/job.meta" ] || fail 'removed metadata was resurrected'
pass 'captured bytes and file identity bound the work, and retired metadata stays absent'
