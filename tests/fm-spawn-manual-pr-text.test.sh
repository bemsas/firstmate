#!/usr/bin/env bash
# Spawn behavior for a pr=manual project, whose worker writes the pull request
# title and body itself while the pipeline's pr and ci steps are skipped
# (bin/fm-project-mode.sh owns the registry token, bin/fm-dod-lib.sh the
# contract). These drive the real spawn path with a fake terminal: the task
# spawn launches only when the brief and the registry agree on the token.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-manual-pr-text)

# make_case <name> <id> <registry-tokens> [<brief-flags>...]: a home whose
# registry holds the tokens, a project with a pooled worktree, and a brief
# scaffolded with the flags. Sets CASE_DIR, HOME_DIR, PROJECT_DIR, POOL_DIR,
# FAKEBIN_DIR.
make_case() {
  local name=$1 id=$2 tokens=$3 content
  shift 3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf -- '- project [%s] - fixture (added 2026-01-01)\n' "$tokens" > "$HOME_DIR/data/projects.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  FM_HOME="$HOME_DIR" "$BRIEF" "$id" project --mode no-mistakes "$@" >/dev/null \
    || fail "the brief for $id should scaffold"
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content//'{TASK}'/Write the PR text by hand.}
  content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn path.}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
}

run_spawn() {  # <id> <args...>
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_spawn_launches_when_brief_and_registry_agree_on_pr_text() {
  local id out status
  id=pr-text-s1
  make_case record "$id" "no-mistakes pr=manual" --pr manual
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a pr=manual no-mistakes spawn should launch"$'\n'"$out"

  id=pr-text-s2
  make_case plain "$id" "no-mistakes"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "an ordinary no-mistakes spawn should launch"$'\n'"$out"
  pass "fm-spawn: a brief and registry that agree on pr=manual or on no token both launch"
}

test_spawn_refuses_a_pr_text_mismatch_before_launch() {
  local id out status
  id=pr-text-m1
  make_case missing "$id" "no-mistakes pr=manual"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a pr=manual project launched on a brief without the token"$'\n'"$out"
  assert_contains "$out" "PR-text mismatch" "the refusal did not name the drift"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn still published a task record"

  id=pr-text-m2
  make_case extra "$id" "no-mistakes" --pr manual
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a project with no pr token launched on a pr=manual brief"$'\n'"$out"
  assert_contains "$out" "PR-text mismatch" "the refusal did not name the drift"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn still published a task record"
  pass "fm-spawn: a brief and registry that disagree on pr=manual refuse before launch in both directions"
}

test_design_rework_requires_sources_before_launch() {
  local id=design-rework-a1 out rc brief content
  make_case rework "$id" "no-mistakes" --design-rework
  brief="$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "rework launched while its source links were missing"
  assert_contains "$out" "must link the agreed artifact and prior captain decisions" "rework refusal did not name the missing sources"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused rework published a task record"

  content=$(cat "$brief")
  content=${content//'<artifact-link>'/https:\/\/design.example.invalid\/accepted-frame}
  content=${content//'<decision-link>'/data\/design-review\/report.md}
  content=${content//'{DESIGN_CHANGE}'/Keep the accepted frame and simplify search.}
  printf '%s\n' "$content" > "$brief"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "rework with both source links and the requested change should launch"$'\n'"$out"
  assert_grep 'https://design.example.invalid/accepted-frame' "$HOME_DIR/data/$id/launch-brief.md" "the launch capsule lost the agreed artifact"
  assert_grep 'data/design-review/report.md' "$HOME_DIR/data/$id/launch-brief.md" "the launch capsule lost the prior decisions"

  id=fresh-design-a1
  make_case fresh-design "$id" "no-mistakes"
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content/Write the PR text by hand./Explore the first design for this new screen.}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "genuinely fresh design should launch with no prior agreement"$'\n'"$out"
  pass "design rework carries agreed sources through spawn, and fresh design can launch without past sources"
}

test_structured_rework_requires_the_current_approval() {
  command -v tasks-axi >/dev/null 2>&1 || { note "skip: structured local approval requires tasks-axi"; return; }
  local id=design-rework-structured out brief scaffold pointer old wrong_digest scout=eve-rework-scout
  local tasks="$ROOT/bin/fm-tasks-axi.sh" holds="$ROOT/bin/fm-captain-hold.sh"
  local artifact=https://design.example.invalid/eve/one-frame
  make_case structured "$id" "no-mistakes" --design-rework
  brief="$HOME_DIR/data/$id/brief.md"
  scaffold=$(cat "$brief")
  scaffold=${scaffold//'<artifact-link>'/$artifact}
  scaffold=${scaffold//'{DESIGN_CHANGE}'/Keep one frame and simplify search.}
  FM_HOME="$HOME_DIR" "$tasks" add eve-design "Eve design" >/dev/null || fail "create Eve origin"
  FM_HOME="$HOME_DIR" "$tasks" add other-design "Other design" >/dev/null || fail "create unrelated origin"
  FM_HOME="$HOME_DIR" "$tasks" add "$id" "Rework Eve design" --kind ship >/dev/null || fail "create rework task"
  FM_HOME="$HOME_DIR" "$holds" hold eve-pick --title "Select the Eve design" --reason "Choose a frame" \
    --origin eve-design >/dev/null || fail "hold Eve choice"
  printf 'Approve the one-frame design.\n' > "$HOME_DIR/answer"
  wrong_digest=$(printf '%064d' 0)

  rework_brief() {
    local content=${scaffold//'<decision-link>'/$1}
    content=${content//Change:/$'Origin: tasks-axi:'"$2"$'\nChange:'}
    printf '%s\n' "$content" > "$brief"
  }

  refuse_rework() {
    out=$(run_spawn "$id" --mode no-mistakes --yolo off) && fail "$1 launched rework"
    assert_contains "$out" "must link the agreed artifact and prior captain decisions" "$1 bypassed the rework gate"
    assert_absent "$HOME_DIR/state/$id.meta" "$1 published a task record"
  }

  rework_brief "tasks-axi:eve-pick#1-$wrong_digest" eve-design
  refuse_rework "unresolved choice"
  FM_HOME="$HOME_DIR" "$holds" answer eve-pick --release --decision-file "$HOME_DIR/answer" >/dev/null \
    || fail "record ordinary answer"
  refuse_rework "answer with no structured approval"
  FM_HOME="$HOME_DIR" "$holds" hold eve-pick --reason "Choose current revision" --origin eve-design >/dev/null \
    || fail "re-hold Eve"
  FM_HOME="$HOME_DIR" "$holds" answer eve-pick --release --decision-file "$HOME_DIR/answer" \
    --approve-design "$artifact" >/dev/null || fail "record exact approval"
  old=$(FM_HOME="$HOME_DIR" "$holds" design-decision eve-pick) || fail "read exact approval pointer"

  rework_brief "$old" other-design
  refuse_rework "incorrect home-local origin"
  mkdir -p "$HOME_DIR/data/$scout"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$scout" > "$HOME_DIR/state/$scout.meta"
  cp "$brief" "$HOME_DIR/data/$scout/brief.md"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-promote.sh" "$scout" --mode direct-PR --yolo off 2>&1) \
    && fail "promotion accepted the incorrect home-local origin"
  assert_contains "$out" "must link the agreed artifact and prior captain decisions" "promotion bypassed the rework gate"
  assert_grep 'kind=scout' "$HOME_DIR/state/$scout.meta" "promotion changed the refused scout"
  rework_brief "$old" eve-design
  sed 's@/eve/one-frame@/eve/two-frames@' "$brief" > "$brief.different"
  mv "$brief.different" "$brief"
  refuse_rework "different artifact"
  rework_brief tasks-axi:eve-pick eve-design
  refuse_rework "unqualified pointer"

  FM_HOME="$HOME_DIR" "$holds" hold eve-pick --reason "Confirm the agreed frame again" >/dev/null \
    || fail "re-hold existing approved occurrence"
  rework_brief "$old" eve-design
  refuse_rework "older approval with new open occurrence"
  FM_HOME="$HOME_DIR" "$holds" answer eve-pick --release --decision-file "$HOME_DIR/answer" \
    --approve-design "$artifact" >/dev/null || fail "record new approval with same words"
  refuse_rework "superseded identical answer"
  pointer=$(FM_HOME="$HOME_DIR" "$holds" design-decision eve-pick) || fail "read latest approval pointer"
  [ "$pointer" != "$old" ] || fail "the same words reused the prior occurrence"
  rework_brief "$pointer" eve-design
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || fail "exact approval did not launch: $out"
  assert_grep 'Origin: tasks-axi:eve-design' "$HOME_DIR/data/$id/launch-brief.md" "launch lost the prior-work identity"
  pass "spawn binds structured rework to the current approved occurrence, origin and artifact"
}

test_spawn_launches_when_brief_and_registry_agree_on_pr_text
test_spawn_refuses_a_pr_text_mismatch_before_launch
test_design_rework_requires_sources_before_launch
test_structured_rework_requires_the_current_approval

echo "# all fm-spawn-manual-pr-text tests passed"
