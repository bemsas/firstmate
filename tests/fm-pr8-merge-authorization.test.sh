#!/usr/bin/env bash
# tests/fm-pr8-merge-authorization.test.sh - a received merge handoff is bound
# to the parent's still-current delivery, and the guarded merge is pinned to
# the base the handoff verified.
#
# Handoff provenance (bin/fm-merge-route.sh --verify-delivery): a parent home
# and a second mate home share one synthetic PR; the receiver's verification
# reads the parent's records read-only through the mate's trusted parent
# binding. A truthful current delivery verifies, whether its send is confirmed
# or still in flight; a replaced, withdrawn, unreadable, ambiguous,
# wrong-home, missing, or different-base one refuses.
# Base pin (bin/fm-pr-merge.sh --expected-base): GitHub, GitLab, and Forgejo
# forge fakes serve one green pull request; the base must match in the
# preflight and again in the final read just before the merge command, a
# merge without the flag behaves as before, and a refused merge never reaches
# the forge's merge call. Sends, forge reads, and merges are fixtures; nothing
# real merges or steers an endpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ROUTE="$ROOT/bin/fm-merge-route.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr8-merge-authorization)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PR=https://github.com/fixture/project/pull/7

# --- handoff provenance -----------------------------------------------------

# handoff_pair <name>: <root>/parent registers second mate "mate" at
# <root>/mate, which relays child1's PR; the mate home holds child1's record,
# its identity, and a local parent binding. Both homes read the same live PR.
handoff_pair() {
  local root="$TMP_ROOT/$1" p m h
  p="$root/parent"
  m="$root/mate"
  mkdir -p "$p/state" "$p/data" "$p/fakebin" "$m/state" "$m/data" "$m/fakebin"
  printf 'OPEN\n' > "$root/pr-state"
  printf '%s\n' "$HEAD_A" > "$root/pr-head"
  printf 'dev\n' > "$root/pr-base"
  for h in "$p" "$m"; do
    cat > "$h/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '{"state":"%s","isDraft":false,"headRefOid":"%s","baseRefName":"%s"}\n' \
  "\$(cat "$root/pr-state")" "\$(cat "$root/pr-head")" "\$(cat "$root/pr-base")"
SH
    chmod +x "$h/fakebin/gh"
  done
  printf 'kind=secondmate\nhome=%s\n' "$m" > "$p/state/mate.meta"
  printf 'done [key=child-pr-child1]: child child1 PR ready: %s\n' "$PR" > "$p/state/mate.status"
  printf 'mate\n' > "$m/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$p" > "$m/.fm-secondmate-parent"
  fm_write_meta "$m/state/child1.meta" "kind=ship" "pr=$PR"
  cat > "$root/send" <<SH
#!/usr/bin/env bash
printf '%s\n---\n' "\$4" >> "$root/sends"
exit \$(cat "$root/send-rc" 2>/dev/null || echo 0)
SH
  chmod +x "$root/send"
  printf '%s\n' "$root"
}

send_handoff() {  # <root> <mandate>
  PATH="$1/parent/fakebin:$PATH" FM_HOME="$1/parent" FM_MERGE_ROUTE_SEND_CMD="$1/send" \
    "$ROUTE" child1 "$PR" --send --mandate "$2"
}

receive() {  # <root> <delivery|""> [<base>]
  if [ -n "$2" ]; then
    PATH="$1/mate/fakebin:$PATH" FM_HOME="$1/mate" "$ROUTE" child1 "$PR" \
      --verify-head "$HEAD_A" --verify-base "${3:-dev}" --verify-delivery "$2"
  else
    PATH="$1/mate/fakebin:$PATH" FM_HOME="$1/mate" "$ROUTE" child1 "$PR" \
      --verify-head "$HEAD_A" --verify-base "${3:-dev}"
  fi
}

delivery_of() {  # <send output> -> the delivery id it names
  printf '%s\n' "$1" | sed -n 's/^sent: yes \([0-9a-f]\{16\}\)$/\1/p; s/^sent: unconfirmed .*delivery \([0-9a-f]\{16\}\))$/\1/p' | head -1
}

expect_refused() {  # <root> <delivery> <reason fragment> <what> [<base>]
  local out rc
  out=$(receive "$1" "$2" "${5:-dev}")
  rc=$?
  [ "$rc" -eq 3 ] || fail "$4 verified (rc=$rc): $out"
  assert_contains "$out" "verified: no" "$4 did not refuse: $out"
  assert_contains "$out" "$3" "$4 refused for another reason: $out"
}

expect_verified() {  # <root> <delivery> <what>
  local out rc
  out=$(receive "$1" "$2")
  rc=$?
  [ "$rc" -eq 0 ] || fail "$3 did not verify (rc=$rc): $out"
  assert_contains "$out" "verified: yes" "$3 did not verify: $out"
}

test_a_current_delivery_verifies_and_pins_the_merge() {
  local root out d last
  root=$(handoff_pair current)
  out=$(send_handoff "$root" 'Merge green development PRs.')
  d=$(delivery_of "$out")
  [ -n "$d" ] || fail "the handoff was not confirmed: $out"
  last=$(awk 'BEGIN { RS = "---\n" } NF { r = $0 } END { printf "%s", r }' "$root/sends")
  assert_contains "$last" "--verify-head $HEAD_A --verify-base dev --verify-delivery $d" \
    "the handoff did not name its delivery for the receiver's check"
  assert_contains "$last" "--expected-head $HEAD_A --expected-base dev" \
    "the handoff did not pin the mate's guarded merge to the head and base"
  expect_verified "$root" "$d" "a confirmed current delivery"
  out=$(receive "$root" "$d")
  assert_contains "$out" "newest confirmed handoff" "the confirmed delivery's provenance was not named: $out"
  expect_refused "$root" "$d" "is OPEN at head $HEAD_A on base dev" "a current delivery checked against another base" main
  pass "a truthful current delivery verifies and pins the mate's guarded merge to head and base"
}

test_an_in_flight_delivery_verifies_until_replaced() {
  local root out d1 d2
  root=$(handoff_pair in-flight)
  printf '3\n' > "$root/send-rc"
  out=$(send_handoff "$root" 'Merge green development PRs.')
  d1=$(delivery_of "$out")
  assert_contains "$out" "sent: unconfirmed" "the first send was not left unconfirmed: $out"
  [ -n "$d1" ] || fail "the unconfirmed send named no delivery: $out"
  expect_verified "$root" "$d1" "an in-flight current delivery"
  out=$(send_handoff "$root" 'Hold every merge until I return.')
  d2=$(delivery_of "$out")
  assert_contains "$out" "superseded:" "the changed mandate did not supersede the in-flight delivery: $out"
  [ -n "$d2" ] && [ "$d2" != "$d1" ] || fail "the changed mandate kept the same delivery: $out"
  expect_refused "$root" "$d1" "replaced by delivery $d2" "a superseded in-flight delivery"
  expect_verified "$root" "$d2" "the replacing in-flight delivery"
  pass "an unconfirmed delivery verifies while current and refuses once a changed mandate replaces it"
}

test_a_confirmed_delivery_refuses_once_replaced() {
  local root d1 d2
  root=$(handoff_pair replaced)
  d1=$(delivery_of "$(send_handoff "$root" 'Merge green development PRs.')")
  d2=$(delivery_of "$(send_handoff "$root" 'Merge only after the release note lands.')")
  [ -n "$d1" ] && [ -n "$d2" ] && [ "$d1" != "$d2" ] || fail "two mandates did not yield two confirmed deliveries"
  expect_refused "$root" "$d1" "replaced by delivery $d2" "a replaced confirmed delivery"
  expect_verified "$root" "$d2" "the newest confirmed delivery"
  pass "a confirmed delivery refuses once a newer confirmed delivery replaces it"
}

test_a_withdrawn_unreadable_or_ambiguous_record_refuses() {
  local root d pending slot
  root=$(handoff_pair withdrawn)
  d=$(delivery_of "$(send_handoff "$root" 'Merge green development PRs.')")
  rm -f "$root/parent/state/.merge-handoffs"
  expect_refused "$root" "$d" "no longer records delivery $d" "a delivery the parent withdrew"
  : > "$root/parent/state/.merge-handoffs"
  expect_refused "$root" "$d" "no longer records delivery $d" "a delivery missing from the parent's ledger"
  if [ "$(id -u)" -ne 0 ]; then
    printf 'x\tmate\t%s\t%s\t%s\n' "$PR" "$HEAD_A" "$d" > "$root/parent/state/.merge-handoffs"
    chmod 000 "$root/parent/state/.merge-handoffs"
    expect_refused "$root" "$d" "ledger cannot be read" "a delivery behind an unreadable ledger"
    chmod 600 "$root/parent/state/.merge-handoffs"
  fi
  # An in-flight slot that names the delivery without its pending message.
  root=$(handoff_pair ambiguous)
  printf '3\n' > "$root/send-rc"
  d=$(delivery_of "$(send_handoff "$root" 'Merge green development PRs.')")
  pending="$root/parent/state/.merge-handoffs.pending"
  rm -f "$pending/$d"
  expect_refused "$root" "$d" "ambiguous" "an in-flight record without its message"
  slot=$(find "$pending" -name 'slot-*' | head -1)
  : > "$slot"
  expect_refused "$root" "$d" "is empty" "an empty in-flight record"
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "$d" > "$slot"
    chmod 000 "$slot"
    expect_refused "$root" "$d" "cannot be read" "an unreadable in-flight record"
    chmod 600 "$slot"
  fi
  pass "a withdrawn, unreadable, or ambiguous parent record refuses the delivery"
}

test_identity_binding_and_home_are_enforced() {
  local root d
  root=$(handoff_pair identity)
  d=$(delivery_of "$(send_handoff "$root" 'Merge green development PRs.')")
  expect_refused "$root" "" "names no delivery id" "a received handoff without a delivery id"
  expect_refused "$root" "0123" "malformed" "a malformed delivery id"
  printf 'kind=secondmate\nhome=%s\n' "$TMP_ROOT" > "$root/parent/state/mate.meta"
  expect_refused "$root" "$d" "names another home" "a delivery addressed to another home"
  printf 'kind=secondmate\nhome=%s\n' "$root/mate" > "$root/parent/state/mate.meta"
  expect_verified "$root" "$d" "the delivery once its record names this home again"
  mv "$root/mate/.fm-secondmate-parent" "$root/mate/parent-binding"
  expect_refused "$root" "$d" "parent binding is missing" "a delivery with no parent binding"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=elsewhere\n' > "$root/mate/.fm-secondmate-parent"
  expect_refused "$root" "$d" "not a local route" "a delivery from a remote parent"
  mv "$root/mate/parent-binding" "$root/mate/.fm-secondmate-parent"
  rm -f "$root/parent/state/mate.meta"
  expect_refused "$root" "$d" "holds no readable record" "a delivery from a parent that no longer registers this home"
  pass "a missing delivery id, binding, or registration, a remote parent, and another home all refuse"
}

# --- the guarded merge's base pin --------------------------------------------

GH_URL=https://github.com/example/repo/pull/9
MR_URL=https://gitlab.example/group/project/-/merge_requests/7
FJ_URL=https://forgejo.example/fixture/fixture-repo/pulls/9

# merge_case <name>: a task home whose record task-x1 can merge one green pull
# request on any of the three forges. The live base is <case>/base, the head
# <case>/head; <case>/flip-after <n> with <case>/flip-base retargets the pull
# request right after the forge's n-th pull request read. Echoes the case.
merge_case() {
  local c="$TMP_ROOT/$1"
  mkdir -p "$c/state" "$c/home/data" "$c/home/config" "$c/fakebin" "$c/user-home"
  fm_git_init_commit "$c/wt"
  git -C "$c/wt" update-ref refs/remotes/origin/main "$(git -C "$c/wt" rev-parse HEAD)"
  fm_test_tasks_toml "$c/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$c/home/data/backlog.md"
  fm_write_meta "$c/state/task-x1.meta" "window=fm-task-x1" "worktree=$c/wt" \
    "project=$c/project" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "$HEAD_A" > "$c/head"
  printf 'dev\n' > "$c/base"
  : > "$c/forge.log"
  cat > "$c/fakebin/flip" <<SH
#!/usr/bin/env bash
n=\$(( \$(cat "$c/views" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "$c/views"
if [ -f "$c/flip-after" ] && [ "\$n" -eq "\$(cat "$c/flip-after")" ]; then cp "$c/flip-base" "$c/base"; fi
SH
  cat > "$c/fakebin/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$c/forge.log"
expr=
prev=
for arg in "\$@"; do
  case "\$prev" in --jq|-q) expr=\$arg ;; esac
  prev=\$arg
done
emit() { if [ -n "\$expr" ]; then jq -r "\$expr"; else cat; fi; }
case "\${1:-} \${2:-}" in
  "pr view")
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"%s","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' \
      "\$(cat "$c/head")" "\$(cat "$c/base")" | emit
    "$c/fakebin/flip"
    ;;
  "pr merge") printf 'merged\n' ;;
  "api graphql") printf 'state=MERGED\nmerged=true\nqueued=false\nbase=%s\n' "\$(cat "$c/base")" ;;
  api\ *)
    case "\$*" in
      *rules/branches/*) printf '[{"type":"deletion"}]\n' ;;
      *branches/*) printf '{"name":"%s","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' "\$(cat "$c/base")" ;;
      *) printf '[]\n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$c/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$c/fakebin/glab" <<SH
#!/usr/bin/env bash
printf 'glab %s\n' "\$*" >> "$c/forge.log"
case "\${1:-} \${2:-}" in
  "mr view")
    if [ -e "$c/merged" ]; then state=merged; else state=opened; fi
    base=\$(cat "$c/base")
    if [ "\$base" = - ]; then target=; else target=",\"target_branch\":\"\$base\""; fi
    printf '{"iid":7,"state":"%s","detailed_merge_status":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"sha":"%s","head_pipeline":{"sha":"%s","status":"success"},"merge_when_pipeline_succeeds":false,"merge_after":null%s}\n' \
      "\$state" "\$(cat "$c/head")" "\$(cat "$c/head")" "\$target"
    [ -e "$c/merged" ] || "$c/fakebin/flip"
    ;;
  "mr merge") : > "$c/merged" ;;
esac
exit 0
SH
  cat > "$c/fakebin/tea" <<SH
#!/usr/bin/env bash
printf 'tea %s\n' "\$*" >> "$c/forge.log"
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fm-fixture",\n    "url": "https://forgejo.example",\n    "ssh_host": "",\n    "user": "",\n    "default": "false"\n  }\n]\n'
  exit 0
fi
endpoint=
for arg in "\$@"; do case "\$arg" in /repos/*) endpoint=\$arg ;; esac; done
case "\$endpoint" in
  */status*)
    case "\$endpoint" in
      *page=1*) printf '{"state":"success","total_count":1,"statuses":[{"context":"ci","status":"success"}]}\n' ;;
      *) printf '{"state":"","total_count":0,"statuses":[]}\n' ;;
    esac
    ;;
  "/repos/{owner}/{repo}") printf '{"default_merge_style":"merge"}\n' ;;
  */merge) : > "$c/merged"; printf '{}\n' ;;
  *)
    if [ -e "$c/merged" ]; then
      printf '{"state":"closed","mergeable":false,"merged":true,"draft":false,"head":{"sha":"%s"},"base":{"ref":"%s"}}\n' "\$(cat "$c/head")" "\$(cat "$c/base")"
    else
      printf '{"state":"open","mergeable":true,"merged":false,"draft":false,"head":{"sha":"%s"},"base":{"ref":"%s"}}\n' "\$(cat "$c/head")" "\$(cat "$c/base")"
      "$c/fakebin/flip"
    fi
    ;;
esac
exit 0
SH
  chmod +x "$c/fakebin/flip" "$c/fakebin/gh" "$c/fakebin/gh-axi" "$c/fakebin/glab" "$c/fakebin/tea"
  printf '%s\n' "$c"
}

pr_merge() {  # <case> <url> [args...]
  local c=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$c/home" FM_STATE_OVERRIDE="$c/state" HOME="$c/user-home" \
    PATH="$c/fakebin:$PATH" "$PR_MERGE" task-x1 "$@"
}

merged_on() {  # <case> -> succeeds when the forge's merge call ran
  grep -qE '^(gh pr merge|glab mr merge|tea .*/merge)' "$1/forge.log"
}

# reads_before_merge <case>: pull request reads the forge served before its
# merge call.
reads_before_merge() {
  awk '/^(gh pr merge|glab mr merge)/ || (/^tea / && /\/merge( |$)/) { exit } /^gh pr view|^glab mr view/ || (/^tea api/ && /\/pulls\/9( |$)/) { n++ } END { print n + 0 }' "$1/forge.log"
}

# check_forge <forge> <url>: the base pin on one forge.
check_forge() {
  local forge=$1 url=$2 c out rc reads
  # Without --expected-base the merge behaves as before and reads no extra base.
  c=$(merge_case "$forge-unpinned")
  printf 'main\n' > "$c/base"
  out=$(pr_merge "$c" "$url" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "$forge: an unpinned merge stopped merging (rc=$rc): $out"
  merged_on "$c" || fail "$forge: an unpinned merge never reached the forge"
  # A truthful pinned base merges.
  c=$(merge_case "$forge-current")
  out=$(pr_merge "$c" "$url" --expected-head "$HEAD_A" --expected-base dev 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "$forge: a merge on its expected base refused (rc=$rc): $out"
  merged_on "$c" || fail "$forge: a merge on its expected base never reached the forge"
  reads=$(reads_before_merge "$c")
  [ "$reads" -ge 2 ] || fail "$forge: the pinned merge did not reread the pull request before merging ($reads reads)"
  # A different base at the preflight refuses before any merge call.
  c=$(merge_case "$forge-preflight")
  printf 'main\n' > "$c/base"
  out=$(pr_merge "$c" "$url" --expected-head "$HEAD_A" --expected-base dev 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$forge: a merge on another base was not refused"
  assert_contains "$out" 'the live base is "main", not the expected base dev' "$forge: the preflight did not name the moved base: $out"
  merged_on "$c" && fail "$forge: a refused merge still reached the forge"
  # A retarget after the preflight is caught by the final read.
  c=$(merge_case "$forge-retarget")
  printf '%s\n' "$((reads - 1))" > "$c/flip-after"
  printf 'main\n' > "$c/flip-base"
  out=$(pr_merge "$c" "$url" --expected-head "$HEAD_A" --expected-base dev 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$forge: a retarget after the preflight was not refused: $out"
  assert_contains "$out" 'the live base just before the merge is "main", not the expected base dev' \
    "$forge: the final read did not name the retarget: $out"
  merged_on "$c" && fail "$forge: a retargeted merge still reached the forge"
  pass "$forge: the guarded merge rechecks the expected base in the preflight and just before merging"
}

test_github_base_pin() { check_forge github "$GH_URL"; }
test_gitlab_base_pin() {
  local c out rc
  check_forge gitlab "$MR_URL"
  # GitLab reporting no target branch at all is a missing base.
  c=$(merge_case gitlab-missing)
  printf -- '-\n' > "$c/base"
  out=$(pr_merge "$c" "$MR_URL" --expected-head "$HEAD_A" --expected-base dev 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "gitlab: a merge request with no target branch was not refused"
  assert_contains "$out" 'the live base is "unreadable", not the expected base dev' "gitlab: a missing base was not named: $out"
  merged_on "$c" && fail "gitlab: a merge with no readable base still reached the forge"
  pass "gitlab: a missing target branch refuses a pinned merge"
}
test_forgejo_base_pin() { check_forge forgejo "$FJ_URL"; }

test_expected_base_usage() {
  local c rc
  c=$(merge_case usage)
  pr_merge "$c" "$GH_URL" --expected-base dev --expected-base dev >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a repeated --expected-base was not a usage error (rc=$rc)"
  pr_merge "$c" "$GH_URL" --expected-base=dev >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "--expected-base=<branch> was not a usage error (rc=$rc)"
  pr_merge "$c" "$GH_URL" --expected-base >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "--expected-base without a branch was not a usage error (rc=$rc)"
  merged_on "$c" && fail "a usage error still reached the forge"
  pass "--expected-base takes exactly one separate branch argument"
}

test_a_current_delivery_verifies_and_pins_the_merge
test_an_in_flight_delivery_verifies_until_replaced
test_a_confirmed_delivery_refuses_once_replaced
test_a_withdrawn_unreadable_or_ambiguous_record_refuses
test_identity_binding_and_home_are_enforced
test_github_base_pin
test_gitlab_base_pin
test_forgejo_base_pin
test_expected_base_usage
echo "# fm-pr8-merge-authorization.test.sh: all assertions passed"
