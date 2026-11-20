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
#   8. the independent review's counterexamples, with real owner fields: summary
#      age at read time, snapshot generation, partial and bounded surfaces,
#      omitted holds, terminal and orphan main evidence, latest-attempt
#      publication, display redaction, a corrupt ledger, unsupported matchers.
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

# snapshot <file> <spec-json>: write an fm-fleet-snapshot.v1 document carrying
# the owner fields bin/fm-fleet-snapshot.sh emits (generation time, task
# current_state, main_inventory, secondmate registration, provenance trust,
# freshness observed_at, counts, and omitted surfaces).
# spec: {"generated_age":S, "tasks":[id or [id,state]],
#        "backlog":[[id,state,title,hold_kind,hold_bucket,hold_until,current_role]],
#        "mates":[{id,state,age,cached,partial,registered,active:[[id,name]],
#                  queued:[[id,title,hold_kind,hold_bucket,hold_until]],
#                  active_count,queued_count,omitted:[surfaces]}]}
snapshot() {
  python3 - "$1" "$2" <<'PY'
import json, os, sys, time
now = int(os.environ['FM_OBLIGATIONS_NOW_EPOCH'])
utc = lambda e: time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(e))
spec = json.loads(sys.argv[2])
recs = []
for r in spec.get('backlog', []):
    rec = dict(zip(('id', 'state', 'title', 'hold_kind', 'hold_bucket', 'hold_until', 'current_role'), r))
    rec['structured'] = True
    if rec['state'] == 'in_flight' and not rec.get('current_role'):
        rec['current_role'] = 'held' if rec.get('hold_kind') else 'program'
    rec['requires_child_metadata'] = rec.get('current_role') == 'worker'
    recs.append(rec)
tasks = []
for t in spec.get('tasks', []):
    tid, state = (t, 'working') if isinstance(t, str) else t
    tasks.append({'id': tid, 'kind': 'ship', 'paths': {'meta': {'present': True}},
                  'current_state': {'state': state, 'source': 'status'}})
mates = []
for m in spec.get('mates', []):
    unknown = m.get('state') == 'unknown'
    partial = m.get('partial', False)
    active = [{'id': a, 'name': n} for a, n in m.get('active', [])]
    q = [dict(zip(('id', 'title', 'hold_kind', 'hold_bucket', 'hold_until'), r)) for r in m.get('queued', [])]
    age = m.get('age', 0)
    mates.append({
        'id': m['id'], 'registered': m.get('registered', True), 'remote': True,
        'current': {'state': m.get('state', 'active_child_work'),
                    'reason': 'structured home ledger is missing' if unknown else
                              ('structured home state invalid: orphan' if partial else None)},
        'provenance': {'selected': 'unknown' if unknown else 'structured-home',
                       'summary_source': 'remote-ledger-cache' if m.get('cached') else 'remote-ledger',
                       'summary_valid': not partial, 'trust': 'partial-structured' if partial else 'complete'},
        'freshness': {'status': 'cached' if m.get('cached') else 'fresh',
                      'observed_at': utc(now - age), 'age_seconds': age},
        'active_children': active, 'queued': q,
        'counts': {'active_children': m.get('active_count', len(active)),
                   'queued': m.get('queued_count', len(q))},
        'omitted': [{'surface': o, 'count': 1} for o in m.get('omitted', [])]})
    tasks.append({'id': m['id'], 'kind': 'secondmate', 'paths': {'meta': {'present': True}},
                  'current_state': {'state': 'unknown', 'source': 'remote'}})
doc = {'schema': 'fm-fleet-snapshot.v1', 'generated': utc(now - spec.get('generated_age', 0)),
       'backlog': {'present': spec.get('backlog_present', True), 'records': recs},
       'tasks': tasks,
       'main_inventory': spec.get('main_inventory', {'valid': True, 'reason': None,
                                                     'orphan_in_flight': [], 'unstructured_current_count': 0}),
       'secondmate_current': {'records': mates, 'total': len(mates), 'shown': len(mates), 'truncated': False}}
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
  snapshot "$snap" '{"mates":[{"id":"vm-a","cached":true,"age":99999},{"id":"vm-b","cached":true,"age":60},
    {"id":"vm-c","state":"unknown"},{"id":"vm-d","active":[["c1","other"]],"active_count":9,"omitted":["active_children"]}]}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_contains "$out" "unknown: stale (vm-a) - Stale; owner summary observed 99999s ago is stale" "stale remote cache is unknown"
  assert_contains "$out" "uncovered: fresh (vm-b)" "a fresh cached summary still judges coverage"
  assert_contains "$out" "unknown: unread (vm-c) - Unread; structured home ledger is missing" "unreadable remote is unknown"
  assert_contains "$out" "unknown: heldunk (vm-c)" "a hold behind an unreadable owner is unknown, not released"
  assert_contains "$out" "unknown: trunc (vm-d) - Trunc; owner summary omits active rows" "truncated summary is unknown"
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

test_review_counterexamples() {
  local h snap out rc=0 fifo old_pid i
  h=$(new_home review)
  snap="$TMP_ROOT/review.json"
  ob "$h" add --id item --kind ask --title "Synthetic ask" --owner mate --source s >/dev/null
  snapshot "$snap" '{"mates":[{"id":"mate","state":"no_active_work","age":4000}]}'
  assert_contains "$(ob "$h" reconcile --snapshot "$snap")" "unknown: item (mate) - Synthetic ask; owner summary observed 4000s ago is stale" \
    "a freshly fetched but old summary is unknown"
  snapshot "$snap" '{"mates":[{"id":"mate","state":"no_active_work","cached":true,"age":3599}]}'
  assert_contains "$(ob "$h" reconcile --snapshot "$snap")" "uncovered: item (mate)" "a cached summary inside the age limit judges coverage"
  assert_contains "$(FM_OBLIGATIONS_NOW_EPOCH=$((NOW + 2)) ob "$h" digest)" "unknown: item (mate) - Synthetic ask; owner summary observed 3601s ago is stale" \
    "summary age is judged when the digest is read"
  snapshot "$snap" '{"generated_age":99999,"mates":[{"id":"mate","state":"no_active_work"}]}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_contains "$out" "evidence-stale: fleet evidence is stale" "an old saved snapshot keeps its own generation time"
  assert_not_contains "$out" "uncovered" "an old snapshot never proves absence"
  snapshot "$snap" '{"mates":[{"id":"mate","state":"no_active_work","partial":true}]}'
  assert_contains "$(ob "$h" reconcile --snapshot "$snap")" "unknown: item (mate) - Synthetic ask; owner summary is partial" \
    "a partial projection cannot prove absence"
  ob "$h" update item --match "specific project" --evidence fixture >/dev/null
  snapshot "$snap" '{"mates":[{"id":"mate","partial":true,"active":[["c1","Specific project rollout"]]}]}'
  assert_not_contains "$(ob "$h" reconcile --snapshot "$snap")" "item" "a visible positive match in a partial projection still covers"
  snapshot "$snap" '{"mates":[{"id":"mate","active":[["child","XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX…"]]}]}'
  assert_contains "$(ob "$h" reconcile --snapshot "$snap")" "unknown: item (mate) - Synthetic ask; matching work child has no proven live state" \
    "a shortened title cannot prove absence"
  ob "$h" update item --match none --evidence fixture >/dev/null
  ob "$h" set item waiting_captain --hold decision --evidence fixture >/dev/null
  snapshot "$snap" '{"mates":[{"id":"mate","queued":[["other","Other item","captain","live",null]],"queued_count":40,"omitted":["queued"]}]}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_contains "$out" "unknown: item (mate) - Synthetic ask; owner summary omits queued rows; hold decision is not in the shown rows" \
    "a hold outside the queue bound is unknown"
  assert_not_contains "$out" "hold-released" "an omitted hold is never reported released"
  ob "$h" set item active --evidence fixture >/dev/null
  snapshot "$snap" '{"mates":[{"id":"mate","queued":[["item","Queued item"]],"active_count":16,"omitted":["active_children"]}]}'
  assert_contains "$(ob "$h" reconcile --snapshot "$snap")" "unknown: item (mate) - Synthetic ask; owner summary omits active rows" \
    "a queued match with omitted active rows is unknown, not queued-only"

  h=$(new_home review-main)
  ob "$h" add --id finished --kind ask --title "Finished worker" --owner main --source s >/dev/null
  ob "$h" add --id orphan --kind ask --title "Orphan row" --owner main --source s >/dev/null
  snapshot "$snap" '{"tasks":[["finished","failed"]],"backlog":[["orphan","in_flight","orphan work",null,null,null,"worker"]],
    "main_inventory":{"valid":false,"reason":"in-flight backlog item has no child metadata","orphan_in_flight":["orphan"],"unstructured_current_count":0}}'
  out=$(ob "$h" reconcile --snapshot "$snap")
  assert_contains "$out" "uncovered: finished (main)" "terminal task metadata is no live proof"
  assert_contains "$out" "unknown: orphan (main) - Orphan row; matching work orphan has no proven live state" "an orphan worker row is no live proof"
  snapshot "$snap" '{"main_inventory":{"valid":false,"reason":"unstructured current backlog row","orphan_in_flight":[],"unstructured_current_count":1}}'
  assert_contains "$(ob "$h" reconcile --snapshot "$snap")" "unknown: finished (main) - Finished worker; main backlog has unstructured current rows" \
    "an unstructured current backlog cannot prove absence"

  h=$(new_home review-race)
  ob "$h" add --id item --kind ask --title "Race" --owner main --source s >/dev/null
  snapshot "$TMP_ROOT/race.json" '{}'
  fifo="$h/delayed.json"
  mkfifo "$fifo"
  FM_HOME="$h" "$OB" check --snapshot "$fifo" > "$h/old.out" &
  old_pid=$!
  for i in $(seq 1 100); do
    [ -s "$h/state/obligations/attempt-seq" ] && break
    sleep 0.05
  done
  out=$(ob "$h" check --snapshot "$h/missing.json")
  assert_contains "$out" "evidence-unavailable" "the newer failed observation wakes"
  cat "$TMP_ROOT/race.json" > "$fifo"
  wait "$old_pid"
  assert_equals "$(cat "$h/old.out")" "" "an older check finishing later neither republishes nor wakes"
  assert_contains "$(ob "$h" digest)" "evidence-unavailable" "the newer observation stays published"

  h=$(new_home review-display)
  ob "$h" add --id leak --kind ask --title "token=sk-XXXXXXXXXXXXXXXXXXXXXXXX" --owner main --source s >/dev/null
  snapshot "$snap" '{}'
  out=$(ob "$h" check --snapshot "$snap")
  assert_not_contains "$out" "sk-XXXX" "watcher wake text is redacted"
  assert_not_contains "$(ob "$h" digest)" "sk-XXXX" "digest text is redacted"
  printf '\377' > "$h/data/obligations.json"
  out=$(ob "$h" check --snapshot "$snap") || rc=$?
  expect_code 0 "$rc" "a corrupt ledger check still exits 0"
  assert_contains "$out" "ledger-malformed: obligations ledger unusable: ledger is not valid UTF-8" "a corrupt ledger wakes visibly"

  h=$(new_home review-match)
  rc=0
  ob "$h" add --id slow --kind ask --title Slow --owner main --source s --match '^(a+)+$' >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a regex matcher is refused at write time"
  printf '{"schema":"fm-obligations.v1","obligations":[{"id":"slow","kind":"ask","title":"Slow","owner":"main","source":"s","status":"active","match":"^(a+)+$"}]}\n' \
    > "$h/data/obligations.json"
  snapshot "$snap" '{"tasks":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaax"]}'
  out=$(timeout 5 env FM_HOME="$h" "$OB" reconcile --snapshot "$snap") || fail "a hand-edited matcher stalled reconcile"
  assert_contains "$out" "match-invalid: slow (main)" "a hand-edited unsupported matcher is reported, never evaluated"
  pass "review counterexamples: ages, partial and bounded surfaces, terminal evidence, publication order, redaction"
}

fm_test_run test_coverage test_lifecycle test_unknown_is_never_uncovered test_digest_and_check \
  test_malformed_and_concurrency test_precompact_and_inject test_real_snapshot test_review_counterexamples
