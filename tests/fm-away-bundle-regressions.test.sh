#!/usr/bin/env bash
# tests/fm-away-bundle-regressions.test.sh - the away bundle's guarantees that
# an independent refutation broke at f305b2cd: a retried or received merge
# handoff is bound to the live head, base, and deployment decision; ownership
# comes only from a relay whose subject and structured PR field match; one
# refill shortage yields at most one cue across an ambiguous delivery; a
# configured zero-lane limit survives a keep-full entry; incomplete process
# evidence never frees an occupied lane; and only structured PR evidence
# counts as a newly opened PR. Forge reads, sends, the process table, and the
# clock are fixtures; nothing merges, spawns a worker, or steers an endpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-merge-route.sh"
REFILL="$ROOT/bin/fm-lane-refill.sh"
PROGRESS="$ROOT/bin/fm-pr-progress.sh"
CAPACITY="$ROOT/bin/fm-capacity.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-bundle-regressions)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PR=https://github.com/fixture/project/pull/7

route_home() {  # <name> -> home with a prod=main project clone and a gh fixture
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/fakebin"
  printf '%s\n' '# Projects' '- project [no-mistakes-prod-only prod=main] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  git init -q "$home/projects/project"
  git -C "$home/projects/project" remote add origin https://github.com/fixture/project.git
  printf 'OPEN\n' > "$home/pr-state"
  printf '%s\n' "$HEAD_A" > "$home/pr-head"
  printf 'dev\n' > "$home/pr-base"
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '{"state":"%s","isDraft":false,"headRefOid":"%s","baseRefName":"%s"}\n' \
  "\$(cat "$home/pr-state")" "\$(cat "$home/pr-head")" "\$(cat "$home/pr-base")"
SH
  chmod +x "$home/fakebin/gh"
  cat > "$home/send" <<SH
#!/usr/bin/env bash
printf '%s\n---\n' "\$4" >> "$home/sends"
exit \$(cat "$home/send-rc" 2>/dev/null || echo 0)
SH
  chmod +x "$home/send"
  printf '%s\n' "$home"
}

route() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_MERGE_ROUTE_SEND_CMD="$home/send" "$ROUTE" "$@"
}

relay() {  # <home> <mate> <line>
  printf 'kind=secondmate\nhome=/remote/%s\n' "$2" > "$1/state/$2.meta"
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

test_a_retried_handoff_never_carries_a_stale_base() {
  local home out last
  home=$(route_home stale-base)
  relay "$home" mate "done [key=child-pr-child1]: child child1 PR ready: $PR"
  FM_HOME="$home" "$CONTRACT" enter --words 'Merge green development PRs. Hold production.' >/dev/null 2>&1 || fail "away entry failed"
  printf '3\n' > "$home/send-rc"
  out=$(route "$home" child1 "$PR" --send)
  assert_contains "$out" "sent: unconfirmed" "the first send was not left unconfirmed: $out"
  printf 'main\n' > "$home/pr-base"
  rm -f "$home/send-rc"
  out=$(route "$home" child1 "$PR" --send)
  assert_contains "$out" "production: production" "the retry did not classify the live base: $out"
  assert_contains "$out" "superseded:" "the stale unconfirmed handoff was not named superseded: $out"
  assert_contains "$out" "sent: yes" "the handoff for the current facts was not sent: $out"
  last=$(awk 'BEGIN { RS = "---\n" } NF { r = $0 } END { printf "%s", r }' "$home/sends")
  assert_contains "$last" "Base: main" "the retried body kept the stale base"
  assert_contains "$last" "Production (parent registry, by base): production" "the retried body kept the stale production decision"
  assert_not_contains "$last" "Base: dev" "the retried body still carried the old base"
  assert_contains "$last" "--verify-head $HEAD_A --verify-base main" "the body did not tell the receiver to verify head and base"
  # The receiver of the stale first body verifies against the live facts.
  out=$(route "$home" child1 "$PR" --verify-head "$HEAD_A" --verify-base dev)
  [ "$?" -eq 3 ] || fail "a handoff whose base moved verified: $out"
  assert_contains "$out" "verified: no" "a moved base was not refused at the receiver: $out"
  out=$(route "$home" child1 "$PR" --verify-head "$HEAD_A" --verify-base main)
  assert_contains "$out" "verified: yes" "a current handoff did not verify: $out"
  pass "a retried handoff is rebuilt for the live base and deployment decision, and a stale one fails verification"
}

test_a_cited_child_and_pr_never_claim_ownership() {
  local home out
  home=$(route_home cited)
  relay "$home" mate "done [key=child-pr-other]: child other PR ready: https://github.com/fixture/project/pull/8"
  relay "$home" mate "blocked [key=child-outcome-other-blocked-01234567]: child other blocked: waiting for child unrelated $PR"
  out=$(route "$home" unrelated "$PR")
  [ "$?" -eq 3 ] || fail "a cited child and PR did not hold: $out"
  assert_contains "$out" "owner: missing" "a note citing a child and PR claimed ownership: $out"
  assert_contains "$out" "route: hold" "a note citing a child and PR routed a handoff: $out"
  relay "$home" mate "blocked [key=child-outcome-unrelated-blocked-1] [at=1]: child unrelated blocked: checks red pr=$PR"
  out=$(route "$home" unrelated "$PR")
  assert_contains "$out" "owner: mate" "a relay whose subject and pr= field match was not owned"
  pass "ownership needs the relay subject and a structured PR field, never a citation in a note"
}

refill_home() {  # <name> -> home with a mate, an away keep-full record, and an inbox stub
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/recipient"
  fm_write_meta "$home/state/vm.meta" "kind=secondmate" "home=/remote/vm"
  cat > "$home/send" <<SH
#!/usr/bin/env bash
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "$home/recipient" vm "\$4" fire-and-forget >/dev/null || exit 1
exit \$(cat "$home/send-rc" 2>/dev/null || echo 0)
SH
  chmod +x "$home/send"
  FM_HOME="$home" "$CONTRACT" enter --keep-full --words 'Keep the lanes full. Refill when due.' >/dev/null 2>&1 \
    || fail "away entry failed"
  printf '%s\n' "$home"
}

emit_shortage() {  # <home> -> the emitted episode id
  local t0 out
  t0=$(($(date +%s) - 1000))
  printf '{"schema":"fm-lane-count.v1","homes":[{"home":"vm","working":2,"target":8,"evidence":"fresh","observed_epoch":%s}]}\n' "$t0" > "$1/counts.json"
  FM_HOME="$1" "$REFILL" scan --counts-file "$1/counts.json" >/dev/null
  printf '{"schema":"fm-lane-count.v1","homes":[{"home":"vm","working":2,"target":8,"evidence":"fresh","observed_epoch":%s}]}\n' $((t0 + 901)) > "$1/counts.json"
  out=$(FM_HOME="$1" "$REFILL" scan --counts-file "$1/counts.json")
  printf '%s\n' "${out##* episode }"
}

inbox_records() { find "$1/recipient/vm.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }

test_one_shortage_yields_at_most_one_cue_across_an_ambiguous_send() {
  local home out episode
  # The first enqueue lands but its acknowledgment is lost; the words change; the cue is retried.
  home=$(refill_home ambiguous)
  episode=$(emit_shortage "$home")
  [ -n "$episode" ] || fail "the sustained shortage did not emit"
  printf '3\n' > "$home/send-rc"
  out=$(FM_HOME="$home" FM_LANE_REFILL_SEND_CMD="$home/send" "$REFILL" cue vm "$episode")
  assert_contains "$out" "sent: unconfirmed" "the lost acknowledgment was not reported: $out"
  FM_HOME="$home" "$CONTRACT" enter --keep-full --words 'Keep lanes full, prioritizing queued fixes.' >/dev/null 2>&1 \
    || fail "mandate replacement failed"
  rm -f "$home/send-rc"
  out=$(FM_HOME="$home" FM_LANE_REFILL_SEND_CMD="$home/send" "$REFILL" cue vm "$episode")
  [ "$?" -eq 3 ] || fail "a cue was resent after the away words changed: $out"
  [ "$(inbox_records "$home")" = 1 ] || fail "one shortage produced $(inbox_records "$home") inbox records"
  # With the words unchanged, the retry resends the identical body, which the inbox folds.
  home=$(refill_home same-words)
  episode=$(emit_shortage "$home")
  printf '3\n' > "$home/send-rc"
  FM_HOME="$home" FM_LANE_REFILL_SEND_CMD="$home/send" "$REFILL" cue vm "$episode" >/dev/null
  rm -f "$home/send-rc"
  out=$(FM_HOME="$home" FM_LANE_REFILL_SEND_CMD="$home/send" "$REFILL" cue vm "$episode")
  assert_contains "$out" "sent: yes" "the same-words retry was not confirmed: $out"
  [ "$(inbox_records "$home")" = 1 ] || fail "a same-words retry landed $(inbox_records "$home") records"
  pass "a shortage cue survives a lost acknowledgment as one record, and changed words never resend it"
}

test_a_configured_zero_survives_keep_full() {
  local home root out status
  home="$TMP_ROOT/zero-home"
  root="$TMP_ROOT/zero-root"
  mkdir -p "$home/state" "$home/config" "$root"
  git init -q -b main "$root"
  git -C "$root" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  printf '0\n' > "$home/config/lane-capacity"
  FM_HOME="$home" "$CONTRACT" enter --keep-full --words 'Keep lanes full within the configured limit.' >/dev/null 2>&1 \
    || fail "keep-full entry under a zero cap failed"
  [ "$(FM_HOME="$home" "$CONTRACT" field lane_target)" = 0 ] || fail "the configured zero lane target was dropped"
  [ "$(FM_HOME="$home" "$CONTRACT" field spend_max_concurrent_workers)" = 0 ] || fail "the zero limit did not become a zero spend cap"
  FM_HOME="$home" "$CONTRACT" validate >/dev/null 2>&1 || fail "a keep-full zero record did not validate"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-spawn.sh" task-new --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 1 ] || fail "a spawn under a zero spend cap exited $status, not 1: $out"
  assert_contains "$out" "caps concurrent workers at 0" "a spawn under a zero spend cap was not refused by the cap: $out"
  out=$(FM_HOME="$home" "$CONTRACT" enter --spend 0 2>&1)
  [ "$?" -eq 2 ] || fail "an explicit --spend 0 stopped being a usage error: $out"
  pass "a configured zero lane limit is recorded as a zero cap that refuses fresh spawns"
}

fake_proc() {  # <proc> <pid> <comm> [cwd] [uid]
  mkdir -p "$1/$2"
  printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 5 5 0 0 20 0 1 0 0 0 100 0\n' "$2" "$3" > "$1/$2/stat"
  [ -z "${4:-}" ] || ln -s "$4" "$1/$2/cwd"
  [ -z "${5:-}" ] || printf 'Name:\t%s\nState:\tS (sleeping)\nUid:\t%s\t%s\t%s\t%s\n' "$3" "$5" "$5" "$5" "$5" > "$1/$2/status"
}

test_incomplete_process_evidence_never_frees_a_lane() {
  local home proc out uid
  if [ "$(uname -s)" != Linux ]; then
    pass "process-evidence case skipped off Linux (its fake /proc drives Linux probes only)"
    return 0
  fi
  uid=$(id -u)
  home="$TMP_ROOT/partial"
  proc="$home/proc"
  mkdir -p "$home/state" "$home/config" "$home/wt" "$home/elsewhere" "$proc"
  fm_write_meta "$home/state/work.meta" "kind=ship" "harness=codex" "worktree=$home/wt" "spawn_gen=s$(($(date +%s) - 1000)).1"
  printf '1\nadmit-spawns\nmin-avail-gb 0\nmin-disk-gb 0\n' > "$home/config/lane-capacity"
  printf '1.00 1.00 1.00 1/1 1\n' > "$proc/loadavg"
  printf 'MemTotal: 1000 kB\nMemAvailable: 900 kB\n' > "$proc/meminfo"
  fake_proc "$proc" 100 bash "$home/elsewhere"
  fake_proc "$proc" 200 codex "$home/wt"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$CAPACITY" --json | jq -c '.lanes | [.count, (.stopped // 0)]')
  [ "$out" = '[1,0]' ] || fail "a worker with a readable directory did not hold its lane: $out"
  # The worker's directory becomes unreadable while it still runs as this user.
  rm -f "$proc/200/cwd"
  fake_proc "$proc" 200 codex "" "$uid"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$CAPACITY" --json | jq -c '.lanes | [.count, (.stopped // 0)]')
  [ "$out" = '[1,0]' ] || fail "an unreadable directory of our own process freed the lane: $out"
  FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 "$CAPACITY" --publish >/dev/null 2>&1 || fail "publish failed"
  [ "$(jq -c '.lanes.stopped_keys // []' "$home/state/lane-capacity.json")" = '[]' ] \
    || fail "the publish carried stopped keys from incomplete evidence: $(jq -c '.lanes' "$home/state/lane-capacity.json")"
  FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$CAPACITY" --spawn-gate >/dev/null 2>&1
  [ "$?" -eq 75 ] || fail "admission opened an occupied lane on incomplete evidence"
  # No status at all is just as unprovable.
  rm -f "$proc/200/status"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$CAPACITY" --json | jq -c '.lanes | [.count, (.stopped // 0)]')
  [ "$out" = '[1,0]' ] || fail "a process of unknown owner freed the lane: $out"
  # Another user's unreadable directory cannot be ours, so the lane is provably stopped.
  fake_proc "$proc" 200 codex "" $((uid + 1))
  out=$(FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$CAPACITY" --json | jq -c '.lanes | [.count, .stopped]')
  [ "$out" = '[0,1]' ] || fail "a lane with only another user's process was not set aside: $out"
  pass "an unreadable directory of our own or an unknown process withholds stopped proof; another user's does not"
}

test_only_structured_pr_evidence_counts_as_a_new_pr() {
  local home t out
  home="$TMP_ROOT/cited-pr"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/mate.meta" "kind=secondmate" "home=/remote/mate"
  : > "$home/state/mate.status"
  for t in $(seq 0 300 3600); do
    printf '{"schema":"fm-lane-count.v1","homes":[{"home":"mate","working":2,"evidence":"fresh","observed_epoch":%s}]}\n' $((2000000000 + t)) > "$home/counts.json"
    [ "$t" -ne 1800 ] || printf 'working [at=2000001800]: child c1 working: diagnosing against an older external reference %s\n' "$PR" >> "$home/state/mate.status"
    out=$(FM_HOME="$home" FM_PR_PROGRESS_NOW=$((2000000000 + t)) FM_PR_PROGRESS_SEND_CMD=/bin/false "$PROGRESS" scan --counts-file "$home/counts.json")
  done
  assert_contains "$out" "no-pr-progress: mate busy 2 lanes" "a cited PR suppressed the one-hour alarm: $out"
  out=$(FM_HOME="$home" FM_PR_PROGRESS_NOW=2000003600 "$PROGRESS" count --since 2000000000 --json)
  [ "$(printf '%s' "$out" | jq -c '[.homes[] | select(.home == "mate") | .count]')" = '[0]' ] \
    || fail "a cited PR counted as newly opened: $out"
  printf 'done [key=child-pr-c1] [at=2000003700]: child c1 PR ready: %s\n' "$PR" >> "$home/state/mate.status"
  out=$(FM_HOME="$home" FM_PR_PROGRESS_NOW=2000003800 "$PROGRESS" count --since 2000000000 --json)
  [ "$(printf '%s' "$out" | jq -c '[.homes[] | select(.home == "mate") | .count]')" = '[1]' ] \
    || fail "a structured PR-ready relay did not count: $out"
  pass "only structured PR evidence counts as a new PR, so a cited URL neither resets the hour nor inflates the count"
}

test_a_retried_handoff_never_carries_a_stale_base
test_a_cited_child_and_pr_never_claim_ownership
test_one_shortage_yields_at_most_one_cue_across_an_ambiguous_send
test_a_configured_zero_survives_keep_full
test_incomplete_process_evidence_never_frees_a_lane
test_only_structured_pr_evidence_counts_as_a_new_pr
echo "# fm-away-bundle-regressions.test.sh: all assertions passed"
