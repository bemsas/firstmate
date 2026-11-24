#!/usr/bin/env bash
# tests/fm-merge-route.test.sh - bin/fm-merge-route.sh: the owner decision that
# precedes every merge. A task this home records merges here; a second mate's
# relayed child is handed to that mate through the send path with its exact
# URL, head, base, relay evidence, and mandate, once per head; a missing or
# conflicting owner holds. Production comes from the verified base and the
# project's deployment mapping. No real forge, merge, or endpoint is touched:
# gh and the send command are fixtures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-merge-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-route-tests)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

make_home() {  # <name> -> home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/fakebin"
  printf '%s\n' '# Projects' \
    '- rs [no-mistakes-prod-only +yolo prod=main] - RatedStylist (added 2026-01-01)' \
    '- sd [no-mistakes-prod-only] - Script Daddy, no deployment mapping (added 2026-01-01)' > "$home/data/projects.md"
  git init -q "$home/projects/rs"
  git -C "$home/projects/rs" remote add origin https://github.com/o/rs.git
  git init -q "$home/projects/sd"
  git -C "$home/projects/sd" remote add origin git@github.com:o/sd.git
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
printf '%s\n' "\$*" >> "$home/sends"
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

# One send per call: the stub records each call's arguments as one record whose
# first line starts with the target, so count only those first lines.
sends() { [ -f "$1/sends" ] && grep -c -- '--fire-and-forget' "$1/sends" || echo 0; }

test_main_owned_task_merges_here_and_never_sends() {
  local home out status
  home=$(make_home main-owned)
  fm_write_meta "$home/state/ship-1.meta" "kind=ship" "project=$home/projects/rs" "harness=claude"
  out=$(route "$home" ship-1 https://github.com/o/rs/pull/7)
  status=$?
  [ "$status" -eq 0 ] || fail "a main-owned task did not resolve (rc=$status): $out"
  assert_contains "$out" "owner: main" "a recorded task was not main-owned"
  assert_contains "$out" "route: merge-here" "a recorded task did not route to the guarded merge here"
  assert_contains "$out" "project: rs" "the project did not come from the task record"
  out=$(route "$home" ship-1 https://github.com/o/rs/pull/7 --send --mandate "merge it")
  assert_contains "$out" "sent: no" "a main-owned --send claimed a handoff"
  [ "$(sends "$home")" = 0 ] || fail "a main-owned task was sent to a mate"
  pass "a task this home records routes to the guarded merge here and is never handed off"
}

test_mate_child_routes_to_its_owner_and_classifies_by_base() {
  local home out status
  home=$(make_home mate-child)
  relay "$home" vm-build-mate 'done [key=child-outcome-c1-done-1] [at=1]: child c1 done: PR https://github.com/o/rs/pull/5 pr=https://github.com/o/rs/pull/5 mode=direct-PR yolo=off'
  relay "$home" vm-build-mate 'done [key=child-outcome-c9-done-1] [at=2]: child c9 done: PR https://github.com/o/rs/pull/50 pr=https://github.com/o/rs/pull/50'
  out=$(route "$home" c1 https://github.com/o/rs/pull/5)
  status=$?
  [ "$status" -eq 0 ] || fail "a relayed child did not resolve (rc=$status): $out"
  assert_contains "$out" "owner: vm-build-mate" "the relaying mate was not the owner"
  assert_contains "$out" "route: handoff" "a mate's child did not route to a handoff"
  assert_contains "$out" "evidence: done [key=child-outcome-c1-done-1]" "the relay line was not carried as evidence"
  assert_contains "$out" "project: rs" "the project was not resolved from the clone's origin"
  assert_contains "$out" "base: dev" "the live base was not read"
  assert_contains "$out" "production: non-production" "a dev base inherited the project's production status"
  printf 'main\n' > "$home/pr-base"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5)
  assert_contains "$out" "production: production" "the registered production base was not production"
  printf 'master\n' > "$home/pr-base"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5)
  assert_contains "$out" "production: non-production" "master matched a main production mapping"
  out=$(route "$home" c9 https://github.com/o/rs/pull/5)
  [ "$?" -eq 3 ] || fail "a different child's relay of another PR claimed this one"
  relay "$home" ce-vm-mate 'done [key=child-pr-c2]: child c2 PR ready: https://github.com/o/sd/pull/3'
  out=$(route "$home" c2 https://github.com/o/sd/pull/3)
  assert_contains "$out" "owner: ce-vm-mate" "a child-pr ready line did not establish ownership"
  assert_contains "$out" "project: sd" "an ssh origin did not resolve the project"
  assert_contains "$out" "production: unknown" "an unmapped project was not held as unknown"
  pass "a mate's relayed child routes to that mate, and production follows only the verified base and deployment mapping"
}

test_missing_and_conflicting_owners_hold() {
  local home out status
  home=$(make_home owners-hold)
  out=$(route "$home" nobody https://github.com/o/rs/pull/5)
  status=$?
  [ "$status" -eq 3 ] || fail "an unowned PR did not hold (rc=$status)"
  assert_contains "$out" "owner: missing" "an unowned PR was not reported missing"
  assert_contains "$out" "route: hold" "an unowned PR did not hold"
  relay "$home" mate-a 'done [at=1]: child c1 done: PR https://github.com/o/rs/pull/5'
  relay "$home" mate-b 'done [at=1]: child c1 done: pr=https://github.com/o/rs/pull/5'
  out=$(route "$home" c1 https://github.com/o/rs/pull/5)
  [ "$?" -eq 3 ] || fail "two claiming mates did not hold"
  assert_contains "$out" "owner: conflicting" "two claiming mates were not a conflict"
  home=$(make_home owners-main-and-mate)
  fm_write_meta "$home/state/c1.meta" "kind=ship" "project=$home/projects/rs"
  relay "$home" mate-a 'done [at=1]: child c1 done: PR https://github.com/o/rs/pull/5'
  out=$(route "$home" c1 https://github.com/o/rs/pull/5)
  [ "$?" -eq 3 ] || fail "a record here plus a mate relay did not hold"
  assert_contains "$out" "owner: conflicting" "a record here plus a mate relay was not a conflict"
  out=$(route "$home" mate-a https://github.com/o/rs/pull/5)
  [ "$?" -eq 3 ] || fail "a second mate's own id did not hold"
  assert_contains "$out" "is a second mate" "a second mate's own id was not named"
  out=$(route "$home" 'bad id' https://github.com/o/rs/pull/5 2>&1)
  [ "$?" -eq 2 ] || fail "an invalid id was not a usage error"
  pass "a missing or conflicting owner holds, and nothing invalid is guessed"
}

test_handoff_sends_once_per_head_with_the_mandate() {
  local home out status
  home=$(make_home handoff)
  relay "$home" vm-build-mate 'done [at=1]: child c1 done: PR https://github.com/o/rs/pull/5 pr=https://github.com/o/rs/pull/5'
  out=$(route "$home" c1 https://github.com/o/rs/pull/5 --send)
  status=$?
  [ "$status" -eq 3 ] || fail "an attended handoff with no mandate sent (rc=$status): $out"
  assert_contains "$out" "no away record stands and no --mandate" "the missing mandate was not named"
  [ "$(sends "$home")" = 0 ] || fail "a handoff with no mandate reached the send path"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge green non-prod work, hold anything prod' >/dev/null 2>&1 \
    || fail "away entry failed"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5 --send) || fail "the away handoff did not send: $out"
  assert_contains "$out" "sent: yes" "the handoff did not confirm its send"
  [ "$(sends "$home")" = 1 ] || fail "the handoff did not send exactly once"
  assert_contains "$(cat "$home/sends")" "vm-build-mate --fire-and-forget" "the handoff did not use the idempotent send"
  assert_contains "$(cat "$home/sends")" "Head: $HEAD_A" "the handoff did not carry the exact head"
  assert_contains "$(cat "$home/sends")" "Base: dev" "the handoff did not carry the base"
  assert_contains "$(cat "$home/sends")" "merge green non-prod work, hold anything prod" "the handoff did not carry the away words verbatim"
  assert_contains "$(cat "$home/sends")" "--expected-head $HEAD_A" "the handoff did not pin the mate's guarded merge to the head"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5 --send)
  assert_contains "$out" "sent: already" "a replayed handoff was not deduplicated"
  [ "$(sends "$home")" = 1 ] || fail "a replayed handoff sent twice"
  printf '%s\n' "$HEAD_B" > "$home/pr-head"
  printf '3\n' > "$home/send-rc"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5 --send)
  [ "$?" -eq 3 ] || fail "an unconfirmed send did not return the send's status"
  assert_contains "$out" "sent: unconfirmed" "an unconfirmed send was not named"
  rm -f "$home/send-rc"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5 --send)
  assert_contains "$out" "sent: yes" "a new head after an unconfirmed send was not handed off"
  [ "$(sends "$home")" = 3 ] || fail "a new head was not a separate handoff: $(sends "$home") sends"
  [ "$(grep -- '--fire-and-forget' "$home/sends" | awk '{print $3}' | sort -u | wc -l | tr -d ' ')" = 2 ] \
    || fail "the retried send did not reuse its delivery id"
  printf 'MERGED\n' > "$home/pr-state"
  printf '%s\n' "cccccccccccccccccccccccccccccccccccccccc" > "$home/pr-head"
  out=$(route "$home" c1 https://github.com/o/rs/pull/5 --send)
  [ "$?" -eq 3 ] || fail "a pull request that is not open was handed off"
  [ "$(sends "$home")" = 3 ] || fail "a closed pull request reached the send path"
  pass "a handoff carries the exact facts and mandate, sends once per head, and refuses without a mandate or an open PR"
}

test_main_owned_task_merges_here_and_never_sends
test_mate_child_routes_to_its_owner_and_classifies_by_base
test_missing_and_conflicting_owners_hold
test_handoff_sends_once_per_head_with_the_mandate
echo "# fm-merge-route.test.sh: all assertions passed"
