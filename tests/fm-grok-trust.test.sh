#!/usr/bin/env bash
# Behavior tests for bin/fm-grok-trust.sh and the grok spawn that calls it.
#
# Both halves of the contract are load-bearing and both are proven here: a
# legitimate fresh task worktree gets its repository registered so the agent
# reaches its brief with no human, and every out-of-scope path, unwritable
# store, and unparseable store is REFUSED rather than warned about or quietly
# skipped.
#
# The central assertion of this suite is WHICH key gets written. Grok keys
# folder trust on the repository's MAIN worktree root, not on the directory the
# pane starts in, so registering the worktree path would write a key Grok never
# reads and the dialog would still fire. Every happy-path case therefore asserts
# the main root is trusted AND that the worktree path was not registered in its
# place. docs/verification/grok-folder-trust.md holds the live evidence for that
# rule; this suite pins the logic portably, with no grok binary.
#
# WHAT THIS SUITE CAN AND CANNOT SETTLE. It PINS the chosen contract - the key
# is the parent of the worktree's git common directory, derived here from git
# rather than read off the fixture variable that already knows the answer - so a
# helper that started writing some other key fails here. It cannot decide
# whether that contract still matches Grok: no assertion over a TOML file can
# observe the dialog. Only tests/fm-grok-trust-live-e2e.test.sh, which launches
# the real binary against a seeded store, can detect grok changing its keying
# model in a future release.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-grok-trust)

TRUST="$ROOT/bin/fm-grok-trust.sh"

# make_case <name>: a project with one linked worktree plus an isolated Grok
# home. Echoes "<case>|<proj>|<wt>|<grok-home>".
make_case() {
  local name=$1 case_dir proj wt grok_home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  grok_home="$case_dir/grok-home"
  mkdir -p "$grok_home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$grok_home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT GROK_HOME_DIR <<EOF
$1
EOF
}

# run_trust <grok-home> <worktree> <project> [home]: invoke with an isolated
# store so the developer's own ~/.grok is never written.
run_trust() {
  local grok_home=$1 wt=$2 proj=$3 home=${4:-$1}
  GROK_HOME="$grok_home" HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

store_of() { # <grok-home>
  printf '%s\n' "$1/trusted_folders.toml"
}

# Octal mode of a path. GNU stat is probed FIRST because GNU's -f means
# "filesystem", not a format string: it exits 0 on a BSD-shaped call and would
# return filesystem stats instead of a mode. BSD stat rejects -c, so the
# fallback only fires where it is the right tool.
mode_of() { # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# The store is the vendor's own TOML, so trust is asserted through a real parser
# rather than by matching serialized bytes.
trusted_paths() { # <store>
  python3 - "$1" <<'PY'
import sys, tomllib, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    raise SystemExit(0)
data = tomllib.loads(p.read_text("utf-8"))
for key, value in (data.get("folders") or {}).items():
    if isinstance(value, dict) and value.get("trusted") is True:
        print(key)
PY
}

assert_trusted() { # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_not_trusted() { # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

decided_at_of() { # <store> <path>
  python3 - "$1" "$2" <<'PY'
import sys, tomllib, pathlib
data = tomllib.loads(pathlib.Path(sys.argv[1]).read_text("utf-8"))
entry = (data.get("folders") or {}).get(sys.argv[2]) or {}
print(entry.get("decided_at", ""))
PY
}

# The contract, restated from git alone: the folder Grok looks up is the
# repository's main worktree, which is the directory holding the common git
# directory the launch worktree points at. Derived here rather than taken from
# the fixture's own <project> variable, so the assertion is a statement about
# the rule and not a restatement of how the fixture was built.
expected_key_for() { # <worktree>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    return 1
  (cd -P -- "$common/.." && pwd -P)
}

# --- the key that is written ------------------------------------------------

# The whole fix turns on this: the pane starts in the worktree, but the folder
# Grok looks up is the repository's main root, so that is what must be trusted.
test_worktree_registers_the_repository_main_root() {
  local case_dir out store expected
  case_dir=$(make_case main-root)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  expected=$(expected_key_for "$WT") ||
    fail "the expected trust key could not be derived from the worktree's git common dir"
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a fresh task worktree must be registered: $out"
  assert_trusted "$store" "$expected" \
    "the repository main root was not trusted, so grok would still show the dialog"
  assert_not_trusted "$store" "$WT" \
    "the worktree path was registered instead of the main root: grok never reads that key"
  assert_equals 1 "$(trusted_paths "$store" | wc -l | tr -d ' ')" \
    "exactly one folder must be granted, so no extra key is written alongside the main root"
  case $out in
    *"$expected"*) ;;
    *) fail "the success line must name the folder that was trusted: $out" ;;
  esac
  pass "fm-grok-trust.sh: a task worktree registers its repository's main root"
}

test_success_line_names_the_worktree_the_grant_covers() {
  local case_dir out
  case_dir=$(make_case covers-line)
  read_case "$case_dir"
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "registration must succeed: $out"
  case $out in
    *"covers worktree"*"$WT"*) ;;
    *) fail "the success line must say which worktree the repository grant covers: $out" ;;
  esac
  pass "fm-grok-trust.sh: the success line names the worktree the grant covers"
}

# The main root is read out of `git worktree list --porcelain`, whose path field
# runs to end of line. Reading it as a whitespace-delimited field would truncate
# any path containing a space and register a folder that does not exist.
test_main_root_with_a_space_is_registered_whole() {
  local case_dir proj wt grok_home out store
  case_dir="$TMP_ROOT/space case"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  grok_home="$case_dir/grok-home"
  mkdir -p "$grok_home"
  fm_git_worktree "$proj" "$wt" wt-space
  store=$(store_of "$grok_home")
  out=$(run_trust "$grok_home" "$wt" "$proj")
  expect_code 0 $? "a path containing a space must register: $out"
  assert_trusted "$store" "$proj" \
    "the main root was truncated at the space instead of registered whole"
  pass "fm-grok-trust.sh: a repository path containing a space is registered whole"
}

test_registration_is_idempotent() {
  local case_dir store first second count
  case_dir=$(make_case idempotent)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  run_trust "$GROK_HOME_DIR" "$WT" "$PROJ" >/dev/null ||
    fail "the first registration must succeed"
  first=$(decided_at_of "$store" "$PROJ")
  run_trust "$GROK_HOME_DIR" "$WT" "$PROJ" >/dev/null ||
    fail "re-registering an already trusted repository must succeed"
  second=$(decided_at_of "$store" "$PROJ")
  assert_equals "$first" "$second" \
    "a repeat run rewrote decided_at instead of leaving the existing grant alone"
  count=$(trusted_paths "$store" | grep -Fxc "$PROJ")
  assert_equals 1 "$count" "a repeat run duplicated the folder entry"
  pass "fm-grok-trust.sh: re-registering an already trusted repository is a no-op"
}

# --- preservation -----------------------------------------------------------

# The store is one shared file holding every folder the user has ever trusted,
# so losing an unrelated entry would re-wedge a previously trusted directory.
test_unrelated_store_entries_are_preserved() {
  local case_dir store out
  case_dir=$(make_case preserve)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  cat > "$store" <<'EOF'
# a comment the user wrote
[folders."/kept/one"]
trusted = true
decided_at = 1700000000

[folders."/kept/two"]
trusted = true
decided_at = 1700000001
EOF
  chmod 600 "$store"
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "registration must succeed against a populated store: $out"
  assert_trusted "$store" /kept/one "an unrelated trusted folder was lost"
  assert_trusted "$store" /kept/two "an unrelated trusted folder was lost"
  assert_trusted "$store" "$PROJ" "the new grant was not recorded"
  assert_grep '# a comment the user wrote' "$store" \
    "the user's own comment was dropped by a reserialization"
  pass "fm-grok-trust.sh: unrelated entries and comments survive a new grant"
}

# Append-only is the mechanism behind that preservation: proving the original
# bytes are still an exact prefix proves nothing existing was rewritten.
test_existing_bytes_are_never_rewritten() {
  local case_dir store before size after
  case_dir=$(make_case append-only)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  printf '[folders."/kept/one"]\ntrusted = true\ndecided_at = 1700000000\n' > "$store"
  chmod 600 "$store"
  before=$(cksum < "$store")
  size=$(wc -c < "$store")
  run_trust "$GROK_HOME_DIR" "$WT" "$PROJ" >/dev/null ||
    fail "registration must succeed"
  after=$(head -c "$size" "$store" | cksum)
  assert_equals "$before" "$after" \
    "the original store bytes were rewritten rather than appended to"
  pass "fm-grok-trust.sh: a new grant is appended without rewriting existing bytes"
}

test_store_keeps_private_permissions() {
  local case_dir store mode
  case_dir=$(make_case perms)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  run_trust "$GROK_HOME_DIR" "$WT" "$PROJ" >/dev/null ||
    fail "registration must succeed"
  mode=$(mode_of "$store")
  assert_equals 600 "$mode" "a created store must be private, got mode $mode"
  pass "fm-grok-trust.sh: a created store is mode 0600"
}

test_existing_store_permissions_are_not_widened() {
  local case_dir store mode
  case_dir=$(make_case perms-keep)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  printf '[folders."/kept"]\ntrusted = true\ndecided_at = 1\n' > "$store"
  chmod 600 "$store"
  run_trust "$GROK_HOME_DIR" "$WT" "$PROJ" >/dev/null ||
    fail "registration must succeed"
  mode=$(mode_of "$store")
  assert_equals 600 "$mode" "the store permissions were widened to $mode"
  pass "fm-grok-trust.sh: an existing store keeps its private permissions"
}

# --- stores that must not be rewritten --------------------------------------

test_unparseable_store_is_refused_and_left_untouched() {
  local case_dir store before out
  case_dir=$(make_case malformed)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  printf '[folders."/kept"]\ntrusted = true\nthis is not toml ===\n' > "$store"
  chmod 600 "$store"
  before=$(cksum < "$store")
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_equals "$before" "$(cksum < "$store")" \
    "an unparseable store was rewritten instead of refused"
  pass "fm-grok-trust.sh: an unparseable store is refused, never silently rewritten"
}

test_non_table_folders_value_is_refused() {
  local case_dir store before out
  case_dir=$(make_case folders-scalar)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  printf 'folders = "not a table"\n' > "$store"
  chmod 600 "$store"
  before=$(cksum < "$store")
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a non-table folders value must be refused: $out"
  assert_equals "$before" "$(cksum < "$store")" "the store was rewritten anyway"
  pass "fm-grok-trust.sh: a non-table folders value is refused"
}

# Only a deliberate decision can put a non-true value on a folder, so flipping
# it to trusted is not this helper's call to make.
test_explicitly_declined_folder_is_not_flipped() {
  local case_dir store before out
  case_dir=$(make_case declined)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  printf '[folders."%s"]\ntrusted = false\ndecided_at = 1700000000\n' "$PROJ" > "$store"
  chmod 600 "$store"
  before=$(cksum < "$store")
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a declined folder must be refused: $out"
  assert_equals "$before" "$(cksum < "$store")" \
    "a folder recorded as not trusted was flipped to trusted"
  assert_not_trusted "$store" "$PROJ" "the declined folder ended up trusted"
  pass "fm-grok-trust.sh: a folder recorded as not trusted is refused, never flipped"
}

test_unwritable_store_is_refused() {
  local case_dir store out
  case_dir=$(make_case unwritable)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  printf '[folders."/kept"]\ntrusted = true\ndecided_at = 1\n' > "$store"
  chmod 400 "$store"
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an unwritable store must be refused: $out"
  chmod 600 "$store"
  pass "fm-grok-trust.sh: an unwritable store is refused"
}

test_store_that_is_not_a_regular_file_is_refused() {
  local case_dir store out
  case_dir=$(make_case store-dir)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  mkdir -p "$store"
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a store that is a directory must be refused: $out"
  pass "fm-grok-trust.sh: a store that is not a regular file is refused"
}

# A dotfile manager may symlink the store; the link is followed and the target
# judged, so a legitimately linked store still works.
test_symlinked_store_to_an_owned_target_is_accepted() {
  local case_dir store target out
  case_dir=$(make_case store-symlink)
  read_case "$case_dir"
  store=$(store_of "$GROK_HOME_DIR")
  target="$CASE_DIR/real-store.toml"
  printf '[folders."/kept"]\ntrusted = true\ndecided_at = 1\n' > "$target"
  chmod 600 "$target"
  ln -s "$target" "$store"
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a symlinked store owned by this user must be accepted: $out"
  assert_trusted "$target" "$PROJ" "the grant did not reach the symlink target"
  assert_trusted "$target" /kept "the symlink target lost an unrelated entry"
  pass "fm-grok-trust.sh: a symlinked store resolving to an owned file is accepted"
}

# --- scope refusals ---------------------------------------------------------

test_primary_checkout_is_refused() {
  local case_dir out
  case_dir=$(make_case primary)
  read_case "$case_dir"
  out=$(run_trust "$GROK_HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: the primary checkout is refused"
}

# CDPATH redirects a relative `cd` operand, which is how a refusal that resolves
# paths through `cd` can be talked out of its verdict.
test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local case_dir out
  case_dir=$(make_case cdpath)
  read_case "$case_dir"
  out=$(CDPATH="$CASE_DIR" GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" \
    "$TRUST" "$PROJ" "$PROJ" 2>&1)
  expect_code 1 $? "CDPATH must not defeat the primary-checkout refusal: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: CDPATH cannot defeat the primary-checkout refusal"
}

# An inherited GIT_DIR with GIT_WORK_TREE makes a primary checkout report a
# linked worktree's git dir, which would walk the primary checkout past the
# isolation test.
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal() {
  local case_dir out
  case_dir=$(make_case gitenv)
  read_case "$case_dir"
  out=$(GIT_DIR="$PROJ/.git/worktrees/wt-gitenv" GIT_WORK_TREE="$PROJ" \
    GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" "$TRUST" "$PROJ" "$PROJ" 2>&1)
  expect_code 1 $? "git env overrides must not defeat the refusal: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: git env overrides cannot defeat the primary-checkout refusal"
}

test_worktree_subdirectory_is_refused() {
  local case_dir out
  case_dir=$(make_case subdir)
  read_case "$case_dir"
  mkdir -p "$WT/sub"
  out=$(run_trust "$GROK_HOME_DIR" "$WT/sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: a subdirectory of the worktree is refused"
}

test_foreign_project_worktree_is_refused() {
  local case_dir other out
  case_dir=$(make_case foreign)
  read_case "$case_dir"
  other=$(make_case foreign-other)
  out=$(run_trust "$GROK_HOME_DIR" "$WT" "$TMP_ROOT/foreign-other/project")
  expect_code 1 $? "a worktree of a different project must be refused: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  : "$other"
  pass "fm-grok-trust.sh: a worktree of an unrelated project is refused"
}

test_home_directory_is_refused() {
  local case_dir out
  case_dir=$(make_case home-dir)
  read_case "$case_dir"
  out=$(GROK_HOME="$GROK_HOME_DIR" HOME="$WT" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "the home directory must be refused: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: the home directory is refused even when it is a worktree"
}

test_filesystem_root_is_refused() {
  local case_dir out
  case_dir=$(make_case fsroot)
  read_case "$case_dir"
  out=$(run_trust "$GROK_HOME_DIR" / "$PROJ")
  expect_code 1 $? "the filesystem root must be refused: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: the filesystem root is refused"
}

test_grok_home_is_refused() {
  local case_dir out
  case_dir=$(make_case grokhome)
  read_case "$case_dir"
  out=$(run_trust "$GROK_HOME_DIR" "$GROK_HOME_DIR" "$PROJ")
  expect_code 1 $? "the grok home must be refused: $out"
  pass "fm-grok-trust.sh: the Grok home directory is refused"
}

test_non_git_directory_is_refused() {
  local case_dir out
  case_dir=$(make_case nongit)
  read_case "$case_dir"
  mkdir -p "$CASE_DIR/plain"
  out=$(run_trust "$GROK_HOME_DIR" "$CASE_DIR/plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: a non-git directory is refused"
}

test_missing_directory_is_refused() {
  local case_dir out
  case_dir=$(make_case missing)
  read_case "$case_dir"
  out=$(run_trust "$GROK_HOME_DIR" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a missing directory must be refused: $out"
  pass "fm-grok-trust.sh: a missing directory is refused"
}

# A relative GROK_HOME would resolve against this process's cwd here and the
# pane's cwd there, so the store the worker reads could not be guaranteed.
test_relative_grok_home_is_refused() {
  local case_dir out
  case_dir=$(make_case relhome)
  read_case "$case_dir"
  out=$(GROK_HOME="rel/path" HOME="$GROK_HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative GROK_HOME must be refused: $out"
  assert_contains "$out" "relative path" "the refusal must name the relative GROK_HOME"
  pass "fm-grok-trust.sh: a relative GROK_HOME is refused"
}

test_argument_shape_is_enforced() {
  local case_dir out
  case_dir=$(make_case args)
  read_case "$case_dir"
  out=$(GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" "$TRUST" 2>&1)
  expect_code 2 $? "no arguments must print usage: $out"
  out=$(GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" "$TRUST" "$WT" 2>&1)
  expect_code 2 $? "one argument must print usage: $out"
  out=$(GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" "$TRUST" "$WT" "$PROJ" extra 2>&1)
  expect_code 2 $? "three arguments must print usage: $out"
  out=$(GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" "$TRUST" --help 2>&1)
  expect_code 2 $? "--help must print usage: $out"
  assert_contains "$out" "usage: fm-grok-trust.sh" "usage text must name the script"
  pass "fm-grok-trust.sh: only its exact two-argument shape is accepted"
}

# A missing interpreter refuses like every other failure here, because degrading
# would launch a worker straight into the dialog this registration removes.
test_missing_python3_is_refused() {
  local case_dir out stub
  case_dir=$(make_case nopython)
  read_case "$case_dir"
  stub="$CASE_DIR/emptybin"
  mkdir -p "$stub"
  # Everything the script legitimately needs before it looks for python3,
  # including bash itself for the `env bash` shebang. python3 is the one tool
  # deliberately absent, so `command -v python3` genuinely fails.
  for tool in bash git awk mkdir; do
    ln -sf "$(command -v "$tool")" "$stub/$tool"
  done
  out=$(PATH="$stub" GROK_HOME="$GROK_HOME_DIR" HOME="$GROK_HOME_DIR" \
    "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a missing python3 must be refused: $out"
  assert_contains "$out" "python3" "the refusal must name the missing interpreter"
  assert_absent "$(store_of "$GROK_HOME_DIR")" "a refused run still wrote a store"
  pass "fm-grok-trust.sh: a missing python3 is refused, not degraded"
}

# --- spawn wiring -----------------------------------------------------------

# The helper only matters if the spawn calls it, so the wiring is proven through
# bin/fm-spawn.sh rather than by reading its source.
test_grok_spawn_pretrusts_its_repository_and_reaches_the_brief() {
  local case_dir home proj wt grok_home fakebin launch_log out store
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  grok_home="$case_dir/grok-home"
  launch_log="$case_dir/launch.log"
  mkdir -p "$grok_home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" grok)
  fm_test_spawn_home "$home" grok
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" grokspawn
  out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" grokspawn "$proj" grok \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the grok spawn must succeed: $out"
  store=$(store_of "$grok_home")
  assert_trusted "$store" "$proj" \
    "the grok spawn did not pre-register folder trust for its repository"
  assert_not_trusted "$store" "$wt" \
    "the spawn registered the worktree path, a key grok never reads"
  assert_present "$launch_log" "the grok spawn sent no launch command"
  assert_grep 'grok --always-approve' "$launch_log" \
    "the launch command was not the grok worker launch"
  assert_grep "$home/data/grokspawn/launch-brief.md" "$launch_log" \
    "the launch command did not carry the brief the worker must read"
  pass "fm-spawn.sh: a grok spawn pre-trusts its repository and launches with the brief"
}

# grok's dialog cannot be answered by this control plane, so an unrecordable
# grant must stop the spawn rather than launch a worker that would wedge.
test_grok_spawn_refuses_when_trust_cannot_be_recorded() {
  local case_dir home proj wt grok_home fakebin launch_log out store
  case_dir="$TMP_ROOT/spawn-refuse"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  grok_home="$case_dir/grok-home"
  launch_log="$case_dir/launch.log"
  mkdir -p "$grok_home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" grok)
  fm_test_spawn_home "$home" grok
  fm_git_worktree "$proj" "$wt" wt-spawn-refuse
  fm_test_spawn_brief "$home" grokrefuse
  # A store that does not parse is the refusal the helper owns; the spawn must
  # carry it through instead of launching anyway.
  store=$(store_of "$grok_home")
  printf '[folders."/kept"]\ntrusted = true\nthis is not toml ===\n' > "$store"
  chmod 600 "$store"
  out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" grokrefuse "$proj" grok \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "the grok spawn must refuse when trust cannot be recorded: $out"
  assert_contains "$out" "Grok folder trust" \
    "the refusal must name the folder-trust registration that failed"
  assert_absent "$launch_log" "a refused grok spawn still launched a worker"
  pass "fm-spawn.sh: a grok spawn refuses when folder trust cannot be recorded"
}

test_worktree_registers_the_repository_main_root
test_success_line_names_the_worktree_the_grant_covers
test_main_root_with_a_space_is_registered_whole
test_registration_is_idempotent
test_unrelated_store_entries_are_preserved
test_existing_bytes_are_never_rewritten
test_store_keeps_private_permissions
test_existing_store_permissions_are_not_widened
test_unparseable_store_is_refused_and_left_untouched
test_non_table_folders_value_is_refused
test_explicitly_declined_folder_is_not_flipped
test_unwritable_store_is_refused
test_store_that_is_not_a_regular_file_is_refused
test_symlinked_store_to_an_owned_target_is_accepted
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal
test_worktree_subdirectory_is_refused
test_foreign_project_worktree_is_refused
test_home_directory_is_refused
test_filesystem_root_is_refused
test_grok_home_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_relative_grok_home_is_refused
test_argument_shape_is_enforced
test_missing_python3_is_refused
test_grok_spawn_pretrusts_its_repository_and_reaches_the_brief
test_grok_spawn_refuses_when_trust_cannot_be_recorded
