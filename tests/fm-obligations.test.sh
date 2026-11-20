#!/usr/bin/env bash
# bin/fm-obligations.py and its bin/fm-precompact-handoff.py integration,
# driven through the executables with synthetic homes and fake cached fleet
# snapshots (no network, no shared host services):
#   1. coverage: an active obligation with no live work is uncovered; live
#      task records, In flight rows, and a secondmate's active children cover;
#      queued-only work is named as such.
#   2. lifecycle: deferred, captain-held, expired-hold, released-hold, and
#      done/dropped obligations; transitions need evidence and keep history.
#   3. unknown is never uncovered: stale or unreadable remote summaries,
#      unregistered owners, truncated summaries, failed or stale evidence.
#   4. the digest is stable, sorted, bounded, and timestamp-free; the watcher
#      check wakes only on new findings.
#   5. a malformed ledger is reported and never overwritten; concurrent writers
#      lose nothing.
#   6. PreCompact: repeated and concurrent runs keep one block, manual promises
#      survive, transcript text cannot forge the block delimiters or change the
#      ledger, and a non-regular transcript path is not opened; inject carries
#      the obligation findings.
#   7. a real bin/fm-fleet-snapshot.sh run on a synthetic home reconciles.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OB="$ROOT/bin/fm-obligations.py"
HOOK="$ROOT/bin/fm-precompact-handoff.py"
TMP_ROOT=$(fm_test_tmproot fm-obligations)
NOW=1795219200   # 2026-11-20T00:00:00Z
export FM_OBLIGATIONS_NOW_EPOCH=$NOW

ob() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$OB" "$@"
}

new_home() {  # <name> -> path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s' "$home"
}

# snapshot <file> <spec-json>: write a minimal fm-fleet-snapshot.v1 document.
# spec: {"tasks":[ids], "backlog":[[id,state,title,hold_kind,hold_bucket,hold_until]],
#        "mates":[{id,state,cached_age,active:[[id,name]],queued:[...],omitted:bool}]}
snapshot() {
  python3 - "$1" "$2" <<'PY'
import json, sys
spec = json.loads(sys.argv[2])
recs = [dict(zip(('id', 'state', 'title', 'hold_kind', 'hold_bucket', 'hold_until'), r)) for r in spec.get('backlog', [])]
tasks = [{'id': t, 'kind': 'ship', 'paths': {'meta': {'present': True}}} for t in spec.get('tasks', [])]
mates = []
for m in spec.get('mates', []):
    unknown = m.get('state') == 'unknown'
    q = [dict(zip(('id', 'title', 'hold_kind', 'hold_bucket', 'hold_until'), r)) for r in m.get('queued', [])]
    mates.append({
        'id': m['id'], 'current': {'state': m.get('state', 'active_child_work'),
                                    'reason': 'structured home ledger is missing' if unknown else None},
        'provenance': {'selected': 'unknown' if unknown else 'structured-home',
                       'summary_source': 'remote-ledger-cache' if 'cached_age' in m else 'local-ledger'},
        'freshness': {'status': 'cached' if 'cached_age' in m else 'fresh', 'age_seconds': m.get('cached_age', 0)},
        'active_children': [{'id': a, 'name': n} for a, n in m.get('active', [])],
        'queued': q, 'counts': {'active_children': m.get('active_count', len(m.get('active', [])))},
        'omitted': [{'surface': 'active_children', 'count': 3}] if m.get('omitted') else []})
    tasks.append({'id': m['id'], 'kind': 'secondmate', 'paths': {'meta': {'present': True}}})
doc = {'schema': 'fm-fleet-snapshot.v1', 'backlog': {'present': spec.get('backlog_present', True), 'records': recs},
       'tasks': tasks, 'secondmate_current': {'records': mates}}
json.dump(doc, open(sys.argv[1], 'w'))
PY
}

digest_has() {  # <home> <line-fragment> <label>
  assert_contains "$(ob "$1" digest)" "$2" "$3"
}

test_coverage() {
  local h snap out
  h=$(new_home cov)
  snap="$TMP_ROOT/cov.json"
  ob "$h" add --id lost --kind side_quest --title "Lost side quest" --owner main --source "captain 2026-11-19" >/dev/null
  ob "$h" add --id taskcov --kind project --title "Alpha" --owner main --source s --match '^alpha-' >/dev/null
  ob "$h" add --id rowcov --kind project --title "Beta" --owner main --source s --ref beta-row >/dev/null
  ob "$h" add --id queued --kind ask --title "Gamma" --owner main --source s --match gamma >/dev/null
  ob "$h" add --id matecov --kind project --title "Delta" --owner mate1 --source s --match 'delta' >/dev/null
  ob "$h" add --id mateidle --kind project --title "Echo" --owner mate1 --source s --match 'echo' >/dev/null
  snapshot "$snap" '{"tasks":["alpha-fix"],
    "backlog":[["beta-row","in_flight","beta work",null,null,null],["g1","queued","gamma follow-up",null,null,null]],
    "mates":[{"id":"mate1","active":[["c1","Delta release prep"]]}]}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_contains "$out" "uncovered: lost (main) - Lost side quest" "active obligation with no live work is uncovered"
  assert_contains "$out" "uncovered: mateidle (mate1)" "secondmate owner without matching child work is uncovered"
  assert_contains "$out" "queued-only: queued (main)" "queued-only work is named"
  assert_not_contains "$out" "taskcov" "live task record covers"
  assert_not_contains "$out" "rowcov" "In flight backlog row covers"
  assert_not_contains "$out" "matecov" "secondmate active child covers by title"
  pass "coverage: uncovered, owner live work, and queued-only"
}

test_lifecycle() {
  local h snap out rc=0
  h=$(new_home life)
  snap="$TMP_ROOT/life.json"
  for id in later dueback heldok heldexp heldgone heldclosed fin drop soon late; do
    ob "$h" add --id "$id" --kind ask --title "T $id" --owner main --source s >/dev/null || fail "add $id"
  done
  ob "$h" set later deferred --until 2026-12-01 --evidence "captain: after December" >/dev/null
  ob "$h" set dueback deferred --until 2026-11-20 --evidence "captain: revisit on the 20th" >/dev/null
  ob "$h" set heldok waiting_captain --hold h-ok --evidence "fm-captain-hold.sh hold h-ok" >/dev/null
  ob "$h" set heldexp waiting_captain --hold h-exp --evidence "held" >/dev/null
  ob "$h" set heldgone waiting_captain --hold h-gone --evidence "held" >/dev/null
  ob "$h" set heldclosed waiting_captain --hold h-closed --evidence "held" >/dev/null
  ob "$h" set fin "done" --evidence "PR merged https://example.invalid/pull/1" >/dev/null
  ob "$h" set drop dropped --evidence "captain: drop it" >/dev/null
  ob "$h" update soon --due 2026-11-21 --evidence "captain: by Saturday" >/dev/null
  ob "$h" update late --due 2026-11-18 --evidence "captain: by Wednesday" >/dev/null
  ob "$h" set fin waiting_captain --evidence x >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "waiting_captain without a hold id is refused"
  rc=0
  ob "$h" set fin "done" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a status change without evidence is refused"
  snapshot "$snap" '{"tasks":["soon","late"],"backlog":[
    ["h-ok","queued","pick vendor","captain","dated","2026-12-05"],
    ["h-exp","queued","pick colour","captain","live","2026-11-10"],
    ["h-closed","done","old call",null,null,null]]}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_not_contains "$out" "later" "future deferral is silent"
  assert_contains "$out" "defer-expired: dueback (main) - T dueback; until 2026-11-20" "arrived deferral surfaces"
  assert_not_contains "$out" "heldok" "a dated captain hold is waiting, not dropped"
  assert_contains "$out" "hold-expired: heldexp (main) - T heldexp; hold-until 2026-11-10" "expired captain hold surfaces"
  assert_contains "$out" "hold-released: heldgone (main) - T heldgone; item h-gone is no longer captain-held" "released hold surfaces"
  assert_contains "$out" "hold-released: heldclosed (main) - T heldclosed; held item h-closed is closed" "closed held item surfaces"
  assert_contains "$out" "due-soon: soon (main)" "due within two days surfaces even when covered"
  assert_contains "$out" "overdue: late (main)" "past due surfaces"
  assert_not_contains "$out" "fin (" "done obligation is silent"
  assert_not_contains "$out" "drop (" "dropped obligation is silent"
  out=$(ob "$h" list --all --json)
  assert_contains "$out" "PR merged https://example.invalid/pull/1" "evidence kept in history"
  assert_contains "$out" '"action": "add"' "history keeps the original add"
  pass "lifecycle: deferred, held, expired, released, done and dropped"
}

test_unknown_is_never_uncovered() {
  local h snap out
  h=$(new_home unk)
  snap="$TMP_ROOT/unk.json"
  ob "$h" add --id stale --kind project --title Stale --owner vm-a --source s --match zzz >/dev/null
  ob "$h" add --id fresh --kind project --title Fresh --owner vm-b --source s --match zzz >/dev/null
  ob "$h" add --id unread --kind project --title Unread --owner vm-c --source s --match zzz >/dev/null
  ob "$h" add --id trunc --kind project --title Trunc --owner vm-d --source s --match zzz >/dev/null
  ob "$h" add --id nobody --kind project --title Nobody --owner ghost --source s >/dev/null
  ob "$h" add --id heldunk --kind ask --title HeldUnk --owner vm-c --source s >/dev/null
  ob "$h" set heldunk waiting_captain --hold h1 --evidence held >/dev/null
  snapshot "$snap" '{"mates":[{"id":"vm-a","cached_age":99999},{"id":"vm-b","cached_age":60},
    {"id":"vm-c","state":"unknown"},{"id":"vm-d","active":[["c1","other"]],"active_count":9,"omitted":true}]}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_contains "$out" "unknown: stale (vm-a) - Stale; cached remote summary is stale" "stale remote cache is unknown"
  assert_contains "$out" "uncovered: fresh (vm-b)" "a fresh cached summary still judges coverage"
  assert_contains "$out" "unknown: unread (vm-c) - Unread; structured home ledger is missing" "unreadable remote is unknown"
  assert_contains "$out" "unknown: heldunk (vm-c)" "a hold behind an unreadable owner is unknown, not released"
  assert_contains "$out" "unknown: trunc (vm-d) - Trunc; owner summary truncated" "truncated summary is unknown"
  assert_contains "$out" "unknown: nobody (ghost) - Nobody; owner ghost is not a registered secondmate" "unregistered owner is unknown"
  assert_not_contains "$out" "uncovered: stale" "stale is never uncovered"
  out=$(ob "$h" reconcile --snapshot "$TMP_ROOT/does-not-exist.json")
  assert_contains "$out" "evidence-unavailable: snapshot file unreadable" "failed evidence is reported"
  assert_contains "$out" "unknown: fresh (vm-b)" "failed evidence turns coverage unknown, not uncovered"
  assert_not_contains "$out" "uncovered" "nothing is uncovered without evidence"
  ob "$h" reconcile --snapshot "$snap" >/dev/null
  out=$(FM_OBLIGATIONS_NOW_EPOCH=$((NOW + 7201)) ob "$h" digest)
  assert_contains "$out" "evidence-stale: fleet evidence is stale" "old evidence is stale"
  assert_not_contains "$out" "uncovered" "stale evidence never reports uncovered"
  pass "unknown: stale, unreadable, unregistered, truncated and failed evidence"
}

test_digest_and_check() {
  local h snap d1 d2 out i
  h=$(new_home dig)
  snap="$TMP_ROOT/dig.json"
  for i in 09 03 07 01 05 02 08 04 06 10 11 12 13 14; do
    ob "$h" add --id "q$i" --kind ask --title "Ask $i" --owner main --source s >/dev/null
  done
  ob "$h" update q13 --due 2026-11-01 --evidence "captain deadline" >/dev/null
  snapshot "$snap" '{}'
  out=$(ob "$h" check --snapshot "$snap")
  assert_contains "$out" "obligations: 15 new finding(s)" "first check wakes with every new finding"
  assert_equals "$(ob "$h" check --snapshot "$snap")" "" "an unchanged finding set stays quiet"
  d1=$(ob "$h" digest)
  d2=$(FM_OBLIGATIONS_NOW_EPOCH=$((NOW + 3600)) ob "$h" digest)
  assert_equals "$d1" "$d2" "digest is byte-identical as the clock moves"
  assert_equals "$(printf '%s\n' "$d1" | head -1)" "overdue: q13 (main) - Ask 13; due 2026-11-01" "most severe finding sorts first"
  assert_equals "$(printf '%s\n' "$d1" | sed -n 2p)" "uncovered: q01 (main) - Ask 01; no live work by main matches" "ids sort within a code"
  assert_equals "$(printf '%s\n' "$d1" | wc -l | tr -d ' ')" "13" "digest is bounded to 12 lines plus a remainder line"
  assert_contains "$d1" "... 3 more obligation findings" "remainder is counted"
  if printf '%s' "$d1" | grep -Eq '[0-9]{2}:[0-9]{2}|T[0-9]{2}'; then fail "digest carries a clock time"; fi
  ob "$h" set q01 "done" --evidence "delivered" >/dev/null
  assert_equals "$(ob "$h" check --snapshot "$snap")" "" "a cleared finding does not wake"
  ob "$h" set q01 active --evidence "reopened by the captain" >/dev/null
  assert_contains "$(ob "$h" check --snapshot "$snap")" "uncovered: q01" "a returning finding wakes again"
  pass "digest: stable, sorted, bounded, timestamp-free; check wakes on new findings"
}

test_malformed_and_concurrency() {
  local h before rc=0 out i
  h=$(new_home bad)
  printf '{"schema":"fm-obligations.v1","obligations":[{"id":"x"' > "$h/data/obligations.json"
  before=$(cat "$h/data/obligations.json")
  ob "$h" add --id y --kind ask --title Y --owner main --source s >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a writer refuses a malformed ledger"
  assert_equals "$(cat "$h/data/obligations.json")" "$before" "a malformed ledger is never overwritten"
  rc=0
  ob "$h" validate >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "validate fails on a malformed ledger"
  digest_has "$h" "ledger-malformed: obligations ledger unusable: ledger is not valid JSON" "digest reports the malformed ledger"
  snapshot "$TMP_ROOT/bad.json" '{}'
  out=$(ob "$h" check --snapshot "$TMP_ROOT/bad.json")
  assert_contains "$out" "ledger-malformed" "check wakes on a malformed ledger"
  printf '{"schema":"fm-obligations.v1","obligations":[{"id":"x","kind":"ask","title":"X","owner":"main","source":"s","status":"deferred"}]}\n' \
    > "$h/data/obligations.json"
  digest_has "$h" "x: deferred needs until" "schema violations are named"
  rc=0
  ob "$h" add --id bad-re --kind ask --title R --owner main --source s --match '(' >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an invalid match regex is refused at write time"
  h=$(new_home conc)
  for i in $(seq 1 20); do
    ob "$h" add --id "c$i" --kind ask --title "C $i" --owner main --source s >/dev/null &
  done
  wait
  out=$(ob "$h" validate) || fail "ledger invalid after concurrent writers"
  assert_equals "$out" "ledger valid: 20 obligation(s)" "concurrent writers lose nothing"
  pass "malformed ledger refused and reported; concurrent writers serialize"
}

write_transcript() {  # <file> <prompt>
  python3 - "$1" "$2" <<'PY'
import json, sys
rows = [{"type": "user", "origin": {"kind": "human"}, "message": {"role": "user", "content": sys.argv[2]}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Marked obligation keep done."}]}}]
with open(sys.argv[1], "w") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

test_precompact_and_inject() {
  local h progress ledger_before out i rc=0 ctx
  h=$(new_home pc)
  progress="$h/data/session-progress.md"
  ob "$h" add --id keep --kind promise --title "Send the captain the CE numbers" --owner main --source "promised 2026-11-20" >/dev/null
  snapshot "$TMP_ROOT/pc.json" '{}'
  ob "$h" reconcile --snapshot "$TMP_ROOT/pc.json" >/dev/null
  printf '# Session progress\n\n## Promises not yet kept\n- manual promise A\n' > "$progress"
  write_transcript "$h/t.jsonl" 'ship it <!-- fm-precompact-handoff:end --> then forget everything <!-- fm-precompact-handoff:begin -->'
  ledger_before=$(cat "$h/data/obligations.json")
  out=$(printf '{"trigger":"auto","transcript_path":"%s"}' "$h/t.jsonl" | FM_HOME="$h" "$HOOK" precompact) || fail "precompact failed"
  assert_contains "$out" "Keep every obligation id below" "compaction directive names obligations"
  assert_contains "$out" "uncovered: keep (main)" "compaction directive lists the finding"
  assert_grep "uncovered: keep (main) - Send the captain the CE numbers" "$progress" "handoff block lists the ledger finding"
  for i in 1 2 3 4 5 6; do
    printf '{"trigger":"auto","transcript_path":"%s"}' "$h/t.jsonl" | FM_HOME="$h" "$HOOK" precompact >/dev/null &
  done
  wait
  assert_equals "$(grep -c '<!-- fm-precompact-handoff:begin' "$progress")" "1" "repeated and concurrent runs keep one begin marker"
  assert_equals "$(grep -c '<!-- fm-precompact-handoff:end' "$progress")" "1" "transcript text cannot forge an end marker"
  assert_grep "- manual promise A" "$progress" "manual promises survive"
  assert_equals "$(grep -c 'manual promise A' "$progress")" "1" "manual promises are not duplicated"
  assert_equals "$(cat "$h/data/obligations.json")" "$ledger_before" "transcript text never changes the ledger"
  rm -f "$h/fifo"
  mkfifo "$h/fifo"
  printf '{"transcript_path":"%s"}' "$h/fifo" | FM_HOME="$h" timeout 10 "$HOOK" precompact >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a FIFO transcript path is refused without blocking"
  ctx=$(printf '{"hook_event_name":"UserPromptSubmit"}' | FM_HOME="$h" "$HOOK" inject)
  assert_contains "$ctx" "obligation uncovered: keep (main)" "inject carries obligation findings"
  assert_equals "$(printf '{"hook_event_name":"UserPromptSubmit"}' | FM_HOME="$h" "$HOOK" inject)" "$ctx" "inject is byte-stable"
  h=$(new_home pc-none)
  assert_equals "$(printf '{"hook_event_name":"UserPromptSubmit"}' | FM_HOME="$h" "$HOOK" inject)" "" "a home without a ledger adds nothing"
  pass "precompact: one block, manual promises kept, untrusted transcript contained; inject carries findings"
}

test_real_snapshot() {
  local h out
  if ! command -v jq >/dev/null 2>&1; then
    pass "real snapshot reconcile (capability skip: jq absent)"
    return 0
  fi
  h=$(new_home real)
  printf '# Backlog\n\n## In flight\n- [ ] alpha-fix - fix alpha login (since 2026-11-20)\n## Queued\n## Done\n' > "$h/data/backlog.md"
  fm_write_meta "$h/state/alpha-fix.meta" window=fm-alpha-fix "worktree=$h/none" endpoint_task_id=alpha-fix
  ob "$h" add --id alpha --kind project --title Alpha --owner main --source s --match alpha >/dev/null
  ob "$h" add --id omega --kind project --title Omega --owner main --source s >/dev/null
  out=$(FM_OBLIGATIONS_NOW_EPOCH=$(date +%s) ob "$h" reconcile) || fail "reconcile against the real snapshot failed"
  assert_contains "$out" "uncovered: omega (main)" "real snapshot: uncovered obligation found"
  assert_not_contains "$out" "alpha" "real snapshot: live task covers"
  assert_not_contains "$out" "evidence-unavailable" "real snapshot produced evidence"
  pass "a real fleet snapshot on a synthetic home reconciles"
}

fm_test_run test_coverage test_lifecycle test_unknown_is_never_uncovered test_digest_and_check \
  test_malformed_and_concurrency test_precompact_and_inject test_real_snapshot
