#!/usr/bin/env bash
# Regression tests for per-task clone isolation (isolation=clone).
#
# A project registered isolation=clone must get a dedicated full clone per ship
# or scout instead of a git worktree. These tests pin the registry token, the
# registration proof every consumer decides through (bound to the home, task,
# copies root, exact copy path, and git directory), a real spawn that creates a
# clone rather than a worktree, trust registration for that clone, the test
# runner's placement guard, the local-only landing that carries the branch into
# the project, and teardown's refusal of unlanded work on any branch or stash
# before it removes a landed clone.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-clone-copy)
LIB="$ROOT/bin/fm-clone-copy-lib.sh"

# <case>/origin.git, <case>/project (a clone of origin with repo-local identity),
# and <case>/publisher, which advances origin/main past the project's checkout.
make_repos() {
  local case_dir=$1
  mkdir -p "$case_dir"
  git init --quiet --bare -b main "$case_dir/origin.git"
  git clone --quiet "file://$case_dir/origin.git" "$case_dir/project" 2>/dev/null
  git -C "$case_dir/project" config user.name 'Project Owner'
  git -C "$case_dir/project" config user.email owner@example.invalid
  printf 'base\n' > "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" commit -qm initial
  git -C "$case_dir/project" push --quiet origin main
  git -C "$case_dir/project" remote set-head origin main
  git clone --quiet "file://$case_dir/origin.git" "$case_dir/publisher"
  printf 'advanced\n' > "$case_dir/publisher/advanced.txt"
  git -C "$case_dir/publisher" add advanced.txt
  git -C "$case_dir/publisher" commit -qm advance
  git -C "$case_dir/publisher" push --quiet origin main
}

# <case>/home with config/clone-root naming <case>/copies.
make_home() {
  local case_dir=$1
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data" "$case_dir/copies"
  printf '%s\n' "$case_dir/copies" > "$case_dir/home/config/clone-root"
}

lib_call() { # <fn> <args...>
  bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

registered() { # <case> <copy> <task-id>
  lib_call fm_clone_copy_is_registered "$2" "$1/project" "$3" "$1/home" "$1/home/config"
}

# Creates task <id>'s registered clone for <case> and prints its physical path.
new_clone() { # <case> <task-id>
  lib_call fm_clone_copy_create "$1/project" "$1/home" "$1/home/config" "$2" || return 1
  (cd "$1/copies/$2/project" && pwd -P)
}

test_registry_isolation_token() {
  local home out status
  home="$TMP_ROOT/registry"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR isolation=clone] - a (added 2026-10-08)
- beta [isolation=clone local-only +yolo] - b (added 2026-10-08)
- gamma [local-only] - c (added 2026-10-08)
- delta [direct-PR isolation=worktree] - d (added 2026-10-08)
- eps [direct-PR isolation=clon] - e (added 2026-10-08)
EOF
  assert_equals clone "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --isolation alpha)" "alpha should register clone isolation"
  assert_equals clone "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --isolation beta)" "a leading isolation token should not become the mode"
  assert_equals "local-only on" "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" beta 2>/dev/null)" "the isolation token changed beta's posture"
  assert_equals "direct-PR off" "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" alpha 2>/dev/null)" "the isolation token changed alpha's posture"
  assert_equals worktree "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --isolation gamma)" "a project with no token should keep worktrees"
  assert_equals worktree "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --isolation delta)" "an explicit worktree token should resolve to worktree"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --isolation missing 2>&1)
  assert_equals worktree "$out" "an unregistered project should default to worktree without a warning"
  out=$(FM_HOME="$TMP_ROOT/no-registry" "$ROOT/bin/fm-project-mode.sh" --isolation alpha 2>&1)
  assert_equals worktree "$out" "an absent registry should default to worktree without a warning"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --isolation eps 2>/dev/null)
  status=$?
  expect_code 3 "$status" "a malformed isolation value should be refused"
  assert_equals "" "$out" "a refused isolation query printed a value"
  pass "the registry isolation token resolves, defaults, and refuses as documented"
}

test_registration_proof() {
  local case_dir clone out
  case_dir="$TMP_ROOT/proof"
  make_repos "$case_dir"
  make_home "$case_dir"
  clone=$(new_clone "$case_dir" t1) || fail "fm_clone_copy_create failed"
  registered "$case_dir" "$clone" t1 || fail "a freshly created clone copy is not registered"
  registered "$case_dir" "$clone" t2 && fail "a clone registered for t1 was accepted for t2"
  lib_call fm_clone_copy_is_registered "$clone" "$case_dir/project" t1 "$case_dir/publisher" "$case_dir/home/config" \
    && fail "a clone was accepted for a home that did not register it"
  registered "$case_dir" "$case_dir/project" t1 && fail "the project itself was accepted as its own clone copy"
  git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/linked" HEAD
  registered "$case_dir" "$case_dir/linked" t1 && fail "a linked worktree was accepted as a clone copy"
  mv "$clone/.git/fm-clone-copy" "$case_dir/marker"
  ln -s "$case_dir/marker" "$clone/.git/fm-clone-copy"
  registered "$case_dir" "$clone" t1 && fail "a symlinked marker was accepted"
  rm "$clone/.git/fm-clone-copy"
  { cat "$case_dir/marker"; printf 'extra=1\n'; } > "$clone/.git/fm-clone-copy"
  registered "$case_dir" "$clone" t1 && fail "a marker with an extra field was accepted"
  mv "$case_dir/marker" "$clone/.git/fm-clone-copy"
  registered "$case_dir" "$clone" t1 || fail "restoring the marker did not restore registration"
  lib_call fm_clone_copy_create "$case_dir/project" "$case_dir/home" "$case_dir/home/config" t1 2>/dev/null \
    && fail "creating over an existing clone path succeeded"
  lib_call fm_clone_copy_create "$case_dir/project" "$case_dir/home" "$case_dir/home/config" ../escape 2>/dev/null \
    && fail "a task id with a path separator created a clone"
  assert_absent "$case_dir/escape" "a path-escaping task id wrote outside the copies root"
  mkdir -p "$case_dir/inside/config"
  printf '%s\n' "$case_dir/inside/copies" > "$case_dir/inside/config/clone-root"
  lib_call fm_clone_copy_create "$case_dir/project" "$case_dir/inside" "$case_dir/inside/config" t3 2>/dev/null \
    && fail "a clone root inside the home was accepted"
  out=$(HOME="$case_dir/user" lib_call fm_clone_copy_path "$case_dir/home2" "$case_dir/home2/config" t9 "$case_dir/project")
  case "$out" in
    "$case_dir/user/.firstmate/clones/"*/t9/project) ;;
    *) fail "the default clone path is not under HOME/.firstmate/clones: $out" ;;
  esac
  pass "only a strictly registered clone of the named home, project, and task passes the proof"
}

test_proof_rejects_moved_copied_and_symlinked_copies() {
  local case_dir clone stray out
  case_dir="$TMP_ROOT/proof-escape"
  make_repos "$case_dir"
  make_home "$case_dir"
  clone=$(new_clone "$case_dir" t1) || fail "fm_clone_copy_create failed"

  mkdir -p "$case_dir/outside"
  mv "$clone" "$case_dir/outside/project"
  registered "$case_dir" "$case_dir/outside/project" t1 && fail "a registered clone moved outside the copies root was accepted"
  out=$(lib_call fm_clone_copy_remove "$case_dir/outside/project" "$case_dir/project" t1 "$case_dir/home" "$case_dir/home/config" 2>&1) \
    && fail "a clone moved outside the copies root was removed"
  assert_present "$case_dir/outside/project/README.md" "removal deleted a clone outside the copies root: $out"

  git init --quiet "$clone"
  cp "$case_dir/outside/project/.git/fm-clone-copy" "$clone/.git/fm-clone-copy"
  registered "$case_dir" "$clone" t1 && fail "an unrelated repository carrying a copied marker was accepted"
  rm -rf "$clone"

  mv "$case_dir/outside/project" "$case_dir/outside/real"
  mkdir -p "$case_dir/outside/t1"
  mv "$case_dir/outside/real" "$case_dir/outside/t1/project"
  rmdir "$case_dir/copies/t1"
  ln -s "$case_dir/outside/t1" "$case_dir/copies/t1"
  registered "$case_dir" "$case_dir/copies/t1/project" t1 && fail "a copy reached through a symlinked task directory was accepted"
  out=$(lib_call fm_clone_copy_remove "$case_dir/copies/t1/project" "$case_dir/project" t1 "$case_dir/home" "$case_dir/home/config" 2>&1) \
    && fail "a copy reached through a symlinked task directory was removed"
  assert_present "$case_dir/outside/t1/project/README.md" "removal followed a symlinked component: $out"

  git clone --quiet "file://$case_dir/origin.git" "$case_dir/stray"
  stray=$(cd "$case_dir/stray" && pwd -P)
  registered "$case_dir" "$stray" t1 && fail "an unregistered clone was accepted as a clone copy"
  pass "moved, copied-marker, and symlink-redirected copies are refused and never removed"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home
  case_dir="$TMP_ROOT/$name"
  make_repos "$case_dir"
  make_home "$case_dir"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  printf -- '- project [direct-PR isolation=clone] - clone isolated (added 2026-10-08)\n' > "$home/data/projects.md"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

test_spawn_creates_a_real_clone() {
  local case_dir home id clone fakebin out status common worktrees
  id='clone-spawn-s1'
  case_dir=$(make_spawn_case spawn "$id")
  home="$case_dir/home"
  clone="$(cd "$case_dir/copies" && pwd -P)/$id/project"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  out=$(fm_test_run_spawn "$home" "$clone" "$fakebin" "$id" "$case_dir/project" --scout)
  status=$?
  expect_code 0 "$status" "a clone-isolated scout spawn should launch"$'\n'"$out"
  assert_grep "worktree=$clone" "$home/state/$id.meta" "the spawn did not record the clone as the task copy"
  assert_grep "isolation=clone" "$home/state/$id.meta" "the spawn did not record clone isolation"
  common=$(cd "$clone" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  assert_equals "$clone/.git" "$common" "the task copy shares another repository's git dir"
  worktrees=$(git -C "$case_dir/project" worktree list --porcelain | grep -c '^worktree ')
  assert_equals 1 "$worktrees" "the spawn added a worktree to the project"
  [ ! -e "$clone/.git/objects/info/alternates" ] || fail "the clone borrows objects through alternates"
  assert_equals "$(git -C "$case_dir/origin.git" rev-parse main)" "$(git -C "$clone" rev-parse HEAD)" \
    "the clone did not start from origin's current default branch"
  assert_equals HEAD "$(git -C "$clone" rev-parse --abbrev-ref HEAD)" "the clone is not on a detached HEAD"
  assert_equals 'Project Owner' "$(git -C "$clone" config --local user.name)" "the clone did not copy the project's user.name"
  assert_equals owner@example.invalid "$(git -C "$clone" config --local user.email)" "the clone did not copy the project's user.email"
  registered "$case_dir" "$clone" "$id" || fail "the spawned clone does not pass the registration proof"
  pass "a clone-isolated spawn launches in a fresh full clone, not a worktree"
}

test_spawn_refuses_no_mistakes_ship_for_clone() {
  local case_dir home id fakebin out status
  id='clone-spawn-nm1'
  case_dir=$(make_spawn_case spawn-nm "$id")
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  out=$(fm_test_run_spawn "$home" "$case_dir/copies/$id/project" "$fakebin" "$id" "$case_dir/project" \
    --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a no-mistakes ship on a clone-isolated project should refuse"
  assert_contains "$out" "isolation=clone" "the refusal did not name clone isolation"
  assert_absent "$case_dir/copies/$id" "the refused spawn left a clone behind"
  assert_absent "$home/state/$id.meta" "the refused spawn published task metadata"
  pass "a no-mistakes ship on a clone-isolated project is refused before any copy exists"
}

test_trust_accepts_only_a_registered_clone() {
  local case_dir clone cfg out
  case_dir="$TMP_ROOT/trust"
  make_repos "$case_dir"
  make_home "$case_dir"
  clone=$(new_clone "$case_dir" t1) || fail "fm_clone_copy_create failed"
  cfg="$case_dir/claude"
  mkdir -p "$cfg"
  out=$(CLAUDE_CONFIG_DIR="$cfg" "$ROOT/bin/fm-claude-trust.sh" --clone-copy "$clone" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" 2>&1) || fail "Claude trust refused a registered clone copy: $out"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (s.projects?.[process.argv[2]]?.hasTrustDialogAccepted !== true) process.exit(1);
  ' "$cfg/.claude.json" "$clone" || fail "Claude trust did not record the clone entry"
  CLAUDE_CONFIG_DIR="$cfg" "$ROOT/bin/fm-claude-trust.sh" --clone-copy "$clone" "$case_dir/project" t2 \
    "$case_dir/home" "$case_dir/home/config" >/dev/null 2>&1 && fail "Claude trust accepted a clone registered for another task"
  CLAUDE_CONFIG_DIR="$cfg" "$ROOT/bin/fm-claude-trust.sh" "$clone" "$case_dir/project" >/dev/null 2>&1 \
    && fail "Claude worktree-mode trust accepted a clone"
  git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/linked" HEAD
  CLAUDE_CONFIG_DIR="$cfg" "$ROOT/bin/fm-claude-trust.sh" --clone-copy "$case_dir/linked" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" >/dev/null 2>&1 && fail "Claude clone-copy trust accepted a linked worktree"
  mkdir -p "$case_dir/agy-home"
  out=$(HOME="$case_dir/agy-home" "$ROOT/bin/fm-agy-trust.sh" --clone-copy "$clone" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" 2>&1) || fail "agy trust refused a registered clone copy: $out"
  grep -qF "$clone" "$case_dir/agy-home/.gemini/antigravity-cli/settings.json" || fail "agy trust did not record the clone"
  HOME="$case_dir/agy-home" "$ROOT/bin/fm-agy-trust.sh" --clone-copy "$case_dir/linked" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" >/dev/null 2>&1 && fail "agy clone-copy trust accepted a linked worktree"
  mkdir -p "$case_dir/kimi-home"
  out=$(HOME="$case_dir/kimi-home" KIMI_CODE_HOME='' "$ROOT/bin/fm-kimi-trust.sh" --clone-copy "$clone" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" 2>&1) || fail "Kimi trust refused a registered clone copy: $out"
  grep -rqF "\"root\":\"$clone\"" "$case_dir/kimi-home/.kimi-code/workspace-trust" || fail "Kimi trust did not record the clone"
  HOME="$case_dir/kimi-home" KIMI_CODE_HOME='' "$ROOT/bin/fm-kimi-trust.sh" --clone-copy "$clone" "$case_dir/project" t2 \
    "$case_dir/home" "$case_dir/home/config" >/dev/null 2>&1 && fail "Kimi trust accepted a clone registered for another task"
  HOME="$case_dir/kimi-home" KIMI_CODE_HOME='' "$ROOT/bin/fm-kimi-trust.sh" "$clone" "$case_dir/project" >/dev/null 2>&1 \
    && fail "Kimi worktree-mode trust accepted a clone"
  HOME="$case_dir/kimi-home" KIMI_CODE_HOME='' "$ROOT/bin/fm-kimi-trust.sh" --clone-copy "$case_dir/linked" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" >/dev/null 2>&1 && fail "Kimi clone-copy trust accepted a linked worktree"

  git init --quiet "$case_dir/copies/t4/project"
  cp "$clone/.git/fm-clone-copy" "$case_dir/copies/t4/project/.git/fm-clone-copy"
  CLAUDE_CONFIG_DIR="$cfg" "$ROOT/bin/fm-claude-trust.sh" --clone-copy "$case_dir/copies/t4/project" "$case_dir/project" t1 \
    "$case_dir/home" "$case_dir/home/config" >/dev/null 2>&1 && fail "Claude trust accepted an unrelated repository with a copied marker"
  pass "Claude, agy, and Kimi trust register a registered clone copy and refuse anything else"
}

# A fixture project that carries the real test runner, so it can be invoked from
# a registered clone with the environment spawn supplies.
test_runner_accepts_registered_clone_and_refuses_primary() {
  local case_dir clone out status
  case_dir="$TMP_ROOT/runner"
  make_repos "$case_dir"
  make_home "$case_dir"
  mkdir -p "$case_dir/project/bin" "$case_dir/project/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-clone-copy-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$case_dir/project/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$case_dir/project/tests/"
  printf '#!/usr/bin/env bash\necho "ok - placement probe ran"\n' > "$case_dir/project/tests/fm-placement-probe.test.sh"
  chmod +x "$case_dir/project/tests/fm-placement-probe.test.sh"
  git -C "$case_dir/project" pull --quiet --ff-only origin main
  git -C "$case_dir/project" add bin tests
  git -C "$case_dir/project" commit -qm runner
  git -C "$case_dir/project" push --quiet origin main
  clone=$(new_clone "$case_dir" run-1) || fail "fm_clone_copy_create failed"
  git -C "$clone" checkout --quiet origin/main

  out=$(cd "$clone" && FM_TASK_ID=run-1 bash bin/fm-test-run.sh tests/fm-placement-probe.test.sh 2>&1)
  status=$?
  expect_code 0 "$status" "the runner should run from the task's registered clone"$'\n'"$out"
  assert_contains "$out" "placement probe ran" "the runner did not execute the suite from the clone"

  out=$(cd "$clone" && FM_TASK_ID=other-task bash bin/fm-test-run.sh tests/fm-placement-probe.test.sh 2>&1)
  status=$?
  expect_code 2 "$status" "the runner should refuse a clone registered for another task"$'\n'"$out"

  out=$(cd "$case_dir/project" && FM_TASK_ID=run-1 bash bin/fm-test-run.sh tests/fm-placement-probe.test.sh 2>&1)
  status=$?
  expect_code 2 "$status" "the runner should still refuse the primary checkout"$'\n'"$out"
  assert_contains "$out" "primary checkout" "the primary refusal did not name the primary checkout"
  pass "the test runner accepts the task's registered clone and still refuses the primary checkout"
}

test_promote_refuses_no_mistakes_for_clone_scout() {
  local case_dir home out status
  case_dir="$TMP_ROOT/promote"
  make_repos "$case_dir"
  make_home "$case_dir"
  home="$case_dir/home"
  fm_test_spawn_brief "$home" promo-1
  fm_write_meta "$home/state/promo-1.meta" \
    "window=firstmate:fm-promo-1" \
    "endpoint_task_id=promo-1" \
    "worktree=$case_dir/copies/promo-1/project" \
    "isolation=clone" \
    "project=$case_dir/project" \
    "kind=scout" \
    "spawn_gen=clone-copy-test-promo-1"
  cp "$home/state/promo-1.meta" "$case_dir/meta-before"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-promote.sh" promo-1 --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "promoting a clone scout to no-mistakes should refuse"$'\n'"$out"
  assert_contains "$out" "per-task clone" "the promotion refusal did not name the clone"
  cmp -s "$case_dir/meta-before" "$home/state/promo-1.meta" || fail "a refused promotion changed the task record"
  pass "a clone scout cannot be promoted to a no-mistakes ship"
}

# Sets CLONE to the case's registered clone on branch fm/task-x1.
make_teardown_case() {
  local name=$1 mode=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  make_repos "$case_dir"
  make_home "$case_dir"
  git -C "$case_dir/project" pull --quiet --ff-only origin main
  mkdir -p "$case_dir/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/no-mistakes"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/"*
  touch "$case_dir/home/state/.last-watcher-beat"
  CLONE=$(new_clone "$case_dir" task-x1) || fail "fm_clone_copy_create failed"
  git -C "$CLONE" checkout --quiet -b fm/task-x1
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$CLONE" \
    "isolation=clone" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode" \
    "branch=fm/task-x1" \
    "spawn_gen=clone-copy-test-task-x1"
  CASE_DIR=$case_dir
}

run_clone_tool() { # <case> <bin-script> <args...>
  local case_dir=$1 tool=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_CONFIG_OVERRIDE="$case_dir/home/config" PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/$tool" "$@"
}

test_teardown_refuses_unlanded_clone_and_removes_landed_one() {
  local out status
  make_teardown_case teardown-local local-only
  printf 'work\n' > "$CLONE/work.txt"
  git -C "$CLONE" add work.txt
  git -C "$CLONE" commit -qm work
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 1 "$status" "teardown should refuse a clone whose commit is neither on origin nor in local main"$'\n'"$out"
  assert_contains "$out" REFUSED "the unlanded refusal did not say REFUSED"
  assert_present "$CLONE/work.txt" "a refused teardown removed the clone"

  printf 'scratch\n' > "$CLONE/scratch.txt"
  git -C "$CLONE" add scratch.txt
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 1 "$status" "teardown should refuse a clone with uncommitted changes"$'\n'"$out"
  git -C "$CLONE" rm --quiet --cached scratch.txt
  rm "$CLONE/scratch.txt"

  out=$(run_clone_tool "$CASE_DIR" fm-merge-local.sh task-x1 2>&1)
  status=$?
  expect_code 0 "$status" "local landing should carry the clone's branch into the project and fast-forward"$'\n'"$out"
  assert_equals "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$CASE_DIR/project" rev-parse main)" \
    "the project's main did not land the clone's work"

  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should remove a clone whose work landed in local main"$'\n'"$out"
  assert_absent "$CLONE" "teardown left the landed clone in place"
  assert_absent "$CASE_DIR/copies/task-x1" "teardown left the clone's task directory behind"
  assert_present "$CASE_DIR/project/work.txt" "teardown disturbed the project's landed work"
  pass "teardown refuses unlanded or dirty clone work and removes a landed clone"
}

test_teardown_refuses_unpushed_other_branch() {
  local out status saved
  make_teardown_case teardown-other-branch local-only
  git -C "$CLONE" checkout --quiet -b saved-work
  printf 'saved\n' > "$CLONE/saved.txt"
  git -C "$CLONE" add saved.txt
  git -C "$CLONE" commit -qm saved
  saved=$(git -C "$CLONE" rev-parse HEAD)
  git -C "$CLONE" checkout --quiet fm/task-x1
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 1 "$status" "teardown should refuse a clone holding an unpushed commit on another branch"$'\n'"$out"
  assert_contains "$out" saved-work "the refusal did not name the unlanded branch"
  assert_equals "$saved" "$(git -C "$CLONE" rev-parse saved-work)" "a refused teardown lost the other branch's commit"

  git -C "$CASE_DIR/project" fetch --quiet "$CLONE" saved-work:saved-work
  git -C "$CASE_DIR/project" merge --quiet --ff-only saved-work
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should proceed once the other branch's tip is in local main"$'\n'"$out"
  assert_absent "$CLONE" "teardown left a clone whose every branch had landed"
  pass "teardown refuses an unpushed non-current branch and accepts it once its tip is in local main"
}

test_teardown_refuses_stash() {
  local out status
  make_teardown_case teardown-stash direct-PR
  printf 'stashed\n' > "$CLONE/README.md"
  git -C "$CLONE" stash push --quiet -m keep-me
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 1 "$status" "teardown should refuse a clone holding a stash"$'\n'"$out"
  assert_contains "$out" keep-me "the refusal did not list the stash"
  [ -n "$(git -C "$CLONE" stash list)" ] || fail "a refused teardown lost the stash"
  pass "teardown refuses a clone holding a stash"
}

test_teardown_refuses_clone_moved_outside_root() {
  local out status outside
  make_teardown_case teardown-outside direct-PR
  outside="$CASE_DIR/unmanaged/project"
  mkdir -p "$CASE_DIR/unmanaged"
  mv "$CLONE" "$outside"
  sed -i.bak "s|^worktree=.*|worktree=$outside|" "$CASE_DIR/home/state/task-x1.meta"
  rm -f "$CASE_DIR/home/state/task-x1.meta.bak"
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown should refuse a recorded copy outside the copies root, even with --force"$'\n'"$out"
  assert_present "$outside/README.md" "teardown deleted a checkout outside the copies root"
  pass "teardown never deletes a recorded copy outside the copies root"
}

test_teardown_removes_clone_whose_branch_is_on_origin() {
  local out status
  make_teardown_case teardown-pushed direct-PR
  printf 'pushed\n' > "$CLONE/pushed.txt"
  git -C "$CLONE" add pushed.txt
  git -C "$CLONE" commit -qm pushed
  git -C "$CLONE" push --quiet origin fm/task-x1
  out=$(run_clone_tool "$CASE_DIR" fm-teardown.sh task-x1 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should remove a clone whose branch is on origin"$'\n'"$out"
  assert_absent "$CLONE" "teardown left the pushed clone in place"
  pass "teardown removes a clone whose work is on its origin"
}

test_registry_isolation_token
test_registration_proof
test_proof_rejects_moved_copied_and_symlinked_copies
test_spawn_creates_a_real_clone
test_spawn_refuses_no_mistakes_ship_for_clone
test_promote_refuses_no_mistakes_for_clone_scout
test_trust_accepts_only_a_registered_clone
test_runner_accepts_registered_clone_and_refuses_primary
test_teardown_refuses_unlanded_clone_and_removes_landed_one
test_teardown_refuses_unpushed_other_branch
test_teardown_refuses_stash
test_teardown_refuses_clone_moved_outside_root
test_teardown_removes_clone_whose_branch_is_on_origin

echo "# all fm-clone-copy tests passed"
