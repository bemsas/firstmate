#!/usr/bin/env bash
# Behavior tests for project capacity admission: a project that declares how
# many workers it admits at once on this machine never gets a fresh worker
# launched beyond that number (bin/fm-project-capacity-lib.sh owns the
# contract; bin/fm-spawn.sh runs the check). The opt-in lane capacity spawn
# gate (config/lane-capacity admit-spawns; bin/fm-capacity.sh owns the verdict),
# the always-on host resource gate (bin/fm-capacity.sh --host-gate), and the
# review-queue cap on publishing ships (bin/fm-review-capacity-lib.sh) are
# covered here too, because they defer through the same spawn path. The review
# cases read a fixture of the forge's raw GraphQL answer through a fake gh-axi
# that applies the real jq reduction the library sends, so no network is used.
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries that log every call, and a real
# markdown backlog when tasks-axi is installed. A deferred spawn is judged by
# what it left behind - no task record, no rendered launch brief, no endpoint,
# no worktree allocation, and a backlog item still queued - never by wording
# alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-capacity)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise project capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse
# that record every call so a deferral can be proved to have created nothing.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*)
    # A spawn that is told to hold waits here, after its capacity check and
    # while it still holds the project lock, until the test releases it.
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1))
        [ "$i" -lt 400 ] || exit 1
        sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    target=
    previous=
    for arg in "$@"; do
      [ "$previous" = -t ] && target=$arg
      previous=$arg
    done
    target=${target##*:}
    target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other-project"
  fm_git_add_origin "$case_dir/other-project" "$case_dir/other-project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-capacity"
}

# A live worker already on a project: the record shape bin/fm-spawn.sh
# publishes, with its backlog item In flight so cleanup can close it.
write_live() {  # <home> <id> <project-dir> [extra-line...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Everything a deferred spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# --- cases ------------------------------------------------------------------

# The reported incident's shape before any declaration: the project is already
# busy, and nothing caps a further launch. Absent a declaration that stays true.
test_undeclared_capacity_keeps_dispatch_uncapped() {
  local case_dir home out rc=0
  case_dir=$(make_case undeclared task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "an undeclared project refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "an undeclared project did not launch the worker"
  assert_present "$home/state/task-c.meta" "an undeclared project's spawn published no record"
  pass "a project with no declared capacity keeps today's uncapped dispatch"
}

test_available_capacity_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case available task-c)
  home="$case_dir/home"
  declare_capacity "$home" "# heavy suite serves two workers" "project 2" "other-project 1"
  write_live "$home" live-a "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a spawn with a free place was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn with a free place did not launch"
  assert_not_contains "$out" "deferred:" "a spawn with a free place reported a deferral"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "an admitted spawn did not move its item In flight"
  fi
  pass "a spawn is admitted while its project still has a free place"
}

test_exhausted_capacity_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case exhausted task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn beyond capacity was not deferred: $out"
  assert_contains "$out" "deferred: project project admits 2 worker(s) at once on this machine ($home/config/project-capacity) and 2 already hold a place (live-a, live-b)" \
    "the deferral did not name the capacity and its holders"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" \
    "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a spawn beyond capacity is deferred before any record, brief, endpoint, worktree, or backlog move exists"
}

# The capacity is the last field, so a project whose clone directory name holds
# spaces can be declared. An indented '#' line is still a comment.
test_spaced_project_name_is_declared() {
  local case_dir home spaced out rc=0
  case_dir=$(make_case spaced task-c)
  home="$case_dir/home"
  spaced="$case_dir/my  heavy project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$spaced"
  declare_capacity "$home" "   # my  heavy project 9" "my  heavy project 1" "project 5"
  write_live "$home" live-a "$spaced"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$spaced" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a project whose name holds spaces was not capped by its declaration: $out"
  assert_contains "$out" "deferred: project my  heavy project admits 1 worker(s) at once" \
    "the deferral did not use the spaced project's declared capacity"
  assert_absent "$home/state/task-c.meta" "the deferred spaced-name spawn published a record"
  pass "a project name with spaces is declared by taking the capacity from the last field"
}

# A clone directory may be named with a leading '#'. That name is declared when
# the '#' is written against the rest of the name and the line ends with the
# capacity. A '#' followed by whitespace stays a comment even when the line
# ends with a number, and a '#' note that is not a capacity stays a comment.
test_hash_prefixed_project_name_is_declared() {
  local case_dir home hashed spaced out rc=0 wt
  case_dir=$(make_case hash-name task-c task-d)
  home="$case_dir/home"
  hashed="$case_dir/#hash-project"
  spaced="$case_dir/# serves"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$hashed"
  git clone -q "$(git -C "$case_dir/other-project" remote get-url origin)" "$spaced"
  declare_capacity "$home" "# serves 2" "#not-a-capacity" "#hash-project 1"
  write_live "$home" live-a "$hashed"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$hashed" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a project whose name begins with # was not capped by its declaration: $out"
  assert_contains "$out" "deferred: project #hash-project admits 1 worker(s) at once" \
    "the deferral did not use the hash-prefixed project's declared capacity"
  assert_absent "$home/state/task-c.meta" "the deferred hash-prefixed spawn published a record"

  write_live "$home" live-b "$spaced"
  write_live "$home" live-c "$spaced"
  git -C "$spaced" worktree add --quiet -b wt-d "$case_dir/wt-d"
  wt="$case_dir/wt-d"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$wt" task-d "$spaced" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a '#' comment that ends with a number was read as a capacity: $out"
  assert_contains "$out" "spawned task-d" "a project whose declaration line is a comment did not stay uncapped"
  pass "a project name beginning with # is declared, and a # comment stays a comment"
}

# A home reached through a symlink is still one home: its workers hold one
# place each, not one per spelling of its state directory.
test_symlinked_home_counts_each_worker_once() {
  local case_dir home out rc=0
  case_dir=$(make_case symlinked-home task-c)
  home="$case_dir/home"
  ln -s "$home" "$case_dir/home-link"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  out=$(run_spawn "$case_dir" "$case_dir/home-link" "$(new_worktree "$case_dir" task-c)" \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a spawn through a symlinked home counted its own worker twice: $out"
  assert_contains "$out" "spawned task-c" "a spawn through a symlinked home did not launch"
  pass "a home reached through a symlink counts each of its workers once"
}

# A fresh spawn that restarts an existing task id replaces that task's own
# record, so the record does not hold a place against it. Any other task on the
# project still sees that record as a holder.
test_restart_does_not_count_its_own_record() {
  local case_dir home out rc=0
  case_dir=$(make_case restart task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  fm_write_meta "$home/state/task-c.meta" \
    "window=firstmate:fm-task-c" \
    "project=$case_dir/project" \
    "kind=ship"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  assert_not_contains "$out" "deferred:" "a restart was deferred by its own record"
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "a restart exited with the deferral code: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "another task ignored the restarted task's place: $out"
  assert_contains "$out" "1 already hold a place (task-c)" "another task did not count the restarted task"
  pass "a restart of a task id does not count that task's own record"
}

# A place frees when a worker records its ready PR and when a task is cleaned
# up; each release admits exactly one more worker.
test_release_frees_a_place() {
  local case_dir home out rc=0
  case_dir=$(make_case release task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the full project admitted a worker: $out"

  # PR handoff: the line bin/fm-pr-check.sh records for a ready PR.
  printf 'pr=%s\n' "https://github.com/o/r/pull/7" >> "$home/state/live-a.meta"
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a recorded PR handoff did not free a place: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "one freed place admitted two workers: $out"
  assert_contains "$out" "2 already hold a place (live-b, task-c)" "the new worker did not take the freed place"

  # Cleanup: the real teardown removes the record, which frees its place.
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" live-b 2>&1) || rc=$?
  expect_code 0 "$rc" "cleanup of a live worker failed: $out"
  assert_absent "$home/state/live-b.meta" "cleanup left the worker's record"
  rc=0
  out=$(spawn_ship "$case_dir" task-d) || rc=$?
  expect_code 0 "$rc" "cleanup did not free a place: $out"
  pass "a recorded PR handoff or a cleanup each frees exactly one place"
}

# Only workers on the same project identity hold places: a secondmate record, a
# record for another project, and a scout on another project are ignored, while
# a scout and a legacy record without kind= on this project count.
test_occupancy_counts_only_this_projects_workers() {
  local case_dir home out rc=0
  case_dir=$(make_case occupancy task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 3"
  write_live "$home" scout-a "$case_dir/project"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$home/state/scout-a.meta" && rm -f "$home/state/scout-a.meta.bak"
  fm_write_meta "$home/state/legacy-b.meta" "window=firstmate:fm-legacy-b" "project=$case_dir/project"
  write_live "$home" other-c "$case_dir/other-project"
  fm_write_meta "$home/state/mate-d.meta" "window=remote:mate-d" "project=$case_dir/project" "kind=secondmate"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "records outside this project's workers took a place: $out"
  rc=0
  write_brief "$home" task-e
  add_item "$home" task-e
  out=$(spawn_ship "$case_dir" task-e "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the third worker on the project was not counted: $out"
  assert_contains "$out" "3 already hold a place (legacy-b, scout-a, task-c)" \
    "occupancy counted the wrong records"
  pass "only this project's ship and scout records hold places"
}

# Capacity belongs to the machine: a local secondmate home's workers on a
# separate clone of the same origin count, the declaration comes from the root
# home even when the secondmate spawns, and a remote home's workers never count.
test_capacity_is_shared_by_every_local_home() {
  local case_dir root mate out rc=0 mate_project
  case_dir=$(make_case machine)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate" task-m
  mate_project="$mate/projects/project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$mate_project"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  printf -- '- far - a remote mate (host: far.example; root: /srv/fm; home: %s/remote-home; scope: other; projects: project; added 2026-09-01)\n' "$case_dir" \
    >> "$root/data/secondmates.md"
  mkdir -p "$case_dir/remote-home/state"
  fm_write_meta "$case_dir/remote-home/state/far-x.meta" "window=w" "project=$case_dir/project" "kind=ship"
  declare_capacity "$root" "project 1"
  write_live "$root" live-a "$case_dir/project"
  git -C "$mate_project" worktree add --quiet -b wt-m "$case_dir/wt-m"
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a local secondmate launched past the machine's capacity: $out"
  assert_contains "$out" "admits 1 worker(s) at once on this machine ($root/config/project-capacity) and 1 already hold a place (live-a in $root)" \
    "the secondmate did not count the root home's worker against the root's declaration"
  assert_absent "$mate/state/task-m.meta" "the deferred secondmate spawn published a record"
  printf 'pr=%s\n' "https://github.com/o/r/pull/8" >> "$root/state/live-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the remote home's worker, or a handed-off one, took the machine's place: $out"
  pass "every local home shares one declared capacity per project origin, and remote homes do not count"
}

# A local home's state directory or task record that cannot be read could hide a
# holder, so admission refuses instead of counting without it.
test_unreadable_holders_refuse_admission() {
  local case_dir root mate out rc=0
  if [ "$(id -u)" = 0 ]; then
    printf 'ok - skipped the unreadable-holder case (root reads files regardless of mode)\n'
    return 0
  fi
  case_dir=$(make_case unreadable-holders task-c)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  declare_capacity "$root" "project 2"

  write_live "$root" live-a "$case_dir/project"
  chmod 000 "$root/state/live-a.meta"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 600 "$root/state/live-a.meta"
  expect_code 1 "$rc" "an unreadable task record did not refuse admission: $out"
  assert_contains "$out" "task record $root/state/live-a.meta cannot be read" \
    "the refusal did not name the unreadable task record"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable task record"

  chmod 000 "$mate/state"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 755 "$mate/state"
  expect_code 1 "$rc" "an unreadable local state directory did not refuse admission: $out"
  assert_contains "$out" "local Firstmate state directory $mate/state cannot be read" \
    "the refusal did not name the unreadable state directory"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable state directory"

  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a readable machine did not admit the worker: $out"
  pass "an unreadable state directory or task record refuses admission rather than undercounting"
}

# Two spawns racing for the last place: the one holding the project lock
# publishes, the other cannot publish while it waits and is deferred afterwards.
test_concurrent_spawns_cannot_both_take_the_last_place() {
  local case_dir home out rc=0 hold i wt
  case_dir=$(make_case concurrent task-a task-b)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  hold="$case_dir/hold"
  wt=$(new_worktree "$case_dir" task-a)
  FM_FAKE_HOLD="$hold" spawn_ship "$case_dir" task-a "$wt" > "$case_dir/a.out" 2>&1 &
  i=0
  while [ ! -f "$hold.reached" ]; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || fail "the first spawn never reached its launch: $(cat "$case_dir/a.out")"
    sleep 0.05
  done
  out=$(spawn_ship "$case_dir" task-b "$case_dir/unused") || rc=$?
  [ "$rc" -ne 0 ] || fail "a concurrent spawn launched while the last place was being taken: $out"
  assert_absent "$home/state/task-b.meta" "a concurrent spawn published past the last place"
  : > "$hold.release"
  wait || true
  assert_contains "$(cat "$case_dir/a.out")" "spawned task-a" "the lock-holding spawn did not finish"
  rc=0
  out=$(spawn_ship "$case_dir" task-b "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the retried spawn was not deferred once the place was taken: $out"
  assert_absent "$home/state/task-b.meta" "the retried spawn published past capacity"
  pass "concurrent spawns can never both take the last place"
}

# A spawn that fails after admission removes nothing it did not create and
# leaves no record, so it holds no place afterwards.
test_failed_spawn_after_admission_holds_no_place() {
  local case_dir home out rc=0
  case_dir=$(make_case failed task-a task-b)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  printf '%s\n' '# Task' "## Captain's intent" '{TASK}' '' '## Firstmate spec' 'x' > "$home/data/task-a/brief.md"
  out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne "$DEFER_EXIT" ] || fail "an invalid brief did not fail after admission (exit $rc): $out"
  assert_contains "$out" "still contains {TASK}" "the spawn did not fail where expected"
  assert_absent "$home/state/task-a.meta" "the failed spawn left a record"
  rc=0
  out=$(spawn_ship "$case_dir" task-b) || rc=$?
  expect_code 0 "$rc" "a failed spawn kept holding the only place: $out"
  pass "a spawn that fails after admission leaves no record and holds no place"
}

test_unreadable_declaration_refuses_every_spawn() {
  local case_dir home out rc label body before worktrees
  case_dir=$(make_case unreadable task-c)
  home="$case_dir/home"
  while IFS='|' read -r label body; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/project-capacity"
    before=$(call_count "$case_dir")
    worktrees=$(worktree_list "$case_dir")
    rc=0
    out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
    expect_code 1 "$rc" "$label: an unreadable declaration did not refuse: $out"
    assert_contains "$out" "the project capacity declaration is unreadable" "$label: the refusal did not name the declaration"
    assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  done <<'ROWS'
missing capacity|project\n
zero capacity|project 0\n
non-numeric capacity|other-project two\n
trailing text|project 2 # suite\n
named twice|project 2\nproject 3\n
ROWS
  rm -f "$home/config/project-capacity"
  mkdir "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a declaration that is not a file did not refuse: $out"
  pass "an unreadable declaration refuses every fresh spawn rather than guessing the limit"
}

test_batch_reports_a_deferred_pair() {
  local case_dir home out rc=0
  case_dir=$(make_case batch task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  write_live "$home" live-a "$case_dir/project"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" "task-c=$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a batch whose only pair was deferred did not exit with the deferral status: $out"
  assert_contains "$out" "batch: DEFERRED task-c ($case_dir/project) - its project or this machine's lanes are at capacity, so it stays queued" \
    "the batch did not report the deferral"
  assert_not_contains "$out" "batch: FAILED" "the batch reported a deferral as a failure"
  pass "a batch reports a capacity deferral as deferred, not failed"
}

# Orca owns its own worktrees and never takes the Treehouse allocation lock, so
# a declared capacity is what makes an Orca spawn take the shared project lock,
# even from an uncapped clone of a capped origin whose worker would still hold a
# place: it refuses while another holder has it, and defers at capacity before
# asking Orca for anything but its runtime status.
test_orca_spawn_is_admitted_under_the_shared_project_lock() {
  local case_dir home out out2 rc=0 rc2 holder i
  command -v node >/dev/null 2>&1 || {
    printf 'ok - skipped the Orca capacity case (node, which the Orca status check needs, is not installed)\n'
    return 0
  }
  case_dir=$(make_case orca task-o)
  home="$case_dir/home"
  cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
printf 'orca %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 1
SH
  chmod +x "$case_dir/fakebin/orca"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$case_dir/project-2"
  declare_capacity "$home" "project 1"

  # shellcheck disable=SC2016 # expanded by the holder's own shell
  FM_HOME="$home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$2") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    : > "$3.held"
    while [ ! -f "$3.release" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/project" "$case_dir/holder" &
  holder=$!
  i=0
  while [ ! -f "$case_dir/holder.held" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "the lock holder never took the project lock"
    sleep 0.05
  done
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project" \
    --backend orca --mode no-mistakes --yolo off) || rc=$?
  rc2=0
  out2=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project-2" \
    --backend orca --mode no-mistakes --yolo off) || rc2=$?
  : > "$case_dir/holder.release"
  wait "$holder" || true
  expect_code 1 "$rc" "an Orca spawn ignored a held project lock: $out"
  assert_contains "$out" "another spawn or cleanup holds the shared project lock for $case_dir/project; refusing to race its capacity admission" \
    "the Orca spawn did not refuse on the shared project lock"
  expect_code 1 "$rc2" "an Orca spawn from an uncapped same-origin clone ignored the held project lock: $out2"
  assert_contains "$out2" "another spawn or cleanup holds the shared project lock for $case_dir/project-2" \
    "the uncapped same-origin clone's Orca spawn did not refuse on the shared project lock"
  assert_absent "$home/state/task-o.meta" "the uncapped clone's Orca spawn published a record while the lock was held"
  assert_no_grep "orca " "$case_dir/calls.log" "the Orca spawn asked Orca for more than its runtime status"

  write_live "$home" live-a "$case_dir/project"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project" \
    --backend orca --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Orca spawn beyond capacity was not deferred: $out"
  assert_absent "$home/state/task-o.meta" "the deferred Orca spawn published a record"
  assert_no_grep "orca " "$case_dir/calls.log" "the deferred Orca spawn created an Orca worktree"
  pass "an Orca spawn takes the shared project lock whenever a same-origin clone is capped and defers before creating anything"
}

# A full lane cap gates nothing until config/lane-capacity asks for the gate.
test_lane_capacity_gate_is_opt_in() {
  local case_dir home out rc=0
  case_dir=$(make_case lane-opt-in task-c)
  home="$case_dir/home"
  printf '0\n' > "$home/config/lane-capacity"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a lane cap without admit-spawns refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "a lane cap without admit-spawns did not launch the worker"
  assert_absent "$home/state/.lane-admission.lock" "a spawn without admit-spawns touched the lane admission lock"
  pass "a full lane cap without admit-spawns never gates a spawn"
}

test_lane_capacity_gate_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case lane-defer task-c)
  home="$case_dir/home"
  printf '1\nadmit-spawns\n' > "$home/config/lane-capacity"
  write_live "$home" live-a "$case_dir/project"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn beyond the lane cap was not deferred: $out"
  # The reasons depend on this host's own probes, so only the verdict's owner is asserted.
  assert_contains "$out" "deferred: lane capacity of this home ($home/config/lane-capacity) does not admit another lane: " \
    "the deferral did not name the lane capacity verdict"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  assert_absent "$home/state/.lane-admission.lock" "a deferred spawn left the lane admission lock held"
  rc=0
  out=$(FM_SPAWN_IGNORE_LANE_CAPACITY=1 spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an environment variable bypassed the lane capacity verdict: $out"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "admit-spawns defers a spawn the lane verdict refuses, leaves nothing behind, and nothing in the environment bypasses it"
}

test_lane_capacity_gate_refuses_an_unreadable_opt_in() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case lane-invalid task-c)
  home="$case_dir/home"
  printf 'twelve\nadmit-spawns\n' > "$home/config/lane-capacity"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "an unreadable opted-in lane capacity did not refuse: $out"
  assert_contains "$out" "this home's lane capacity cannot be read" "the refusal did not name the lane capacity"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  printf 'auto\n' > "$home/config/lane-capacity"
  chmod 000 "$home/config/lane-capacity"
  if [ ! -r "$home/config/lane-capacity" ]; then
    rc=0
    out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
    expect_code 1 "$rc" "a lane capacity file that cannot be read did not refuse: $out"
    assert_contains "$out" "this home's lane capacity cannot be read" "the refusal did not name the unreadable lane capacity"
    assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  fi
  chmod 600 "$home/config/lane-capacity"
  printf 'twelve\n' > "$home/config/lane-capacity"
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a malformed lane capacity without admit-spawns refused a spawn: $out"
  pass "a malformed lane capacity refuses spawns only when it asks for the gate, and one that cannot be read always refuses"
}

# --- host resource gate -----------------------------------------------------

# A fixture /proc for the host gate's Linux probes; the core count stays real,
# so an "above" load is set far beyond 1.5 x any real core count. A dash
# leaves that probe file out, which reads as unknown.
host_proc() {  # <case-dir> <name> <load1|-> <mem-avail-pct|->
  local dir="$1/proc-$2"
  mkdir -p "$dir"
  [ "$3" = - ] || printf '%s 0.00 0.00 1/1 1\n' "$3" > "$dir/loadavg"
  [ "$4" = - ] || printf 'MemTotal: 1000000 kB\nMemAvailable: %s kB\n' "$(( $4 * 10000 ))" > "$dir/meminfo"
  printf '%s\n' "$dir"
}

test_host_gate_defers_an_overloaded_host_and_keeps_the_task_queued() {
  local case_dir home out rc=0 before worktrees proc
  if [ "$(uname -s)" != Linux ]; then
    pass "host gate spawn deferral (skipped: its fixture replaces the Linux /proc probes; the verdict itself is covered portably by tests/fm-capacity.test.sh)"
    return 0
  fi
  case_dir=$(make_case host-gate task-c task-d task-e task-f)
  home="$case_dir/home"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  proc=$(host_proc "$case_dir" load 100000.00 60)
  out=$(FM_PROC_ROOT_OVERRIDE=$proc spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn on an overloaded host was not deferred: $out"
  assert_contains "$out" "deferred: this host is overloaded (1-minute load 100000.00" "the deferral did not name the observed load"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  rc=0
  proc=$(host_proc "$case_dir" mem 0.00 19)
  out=$(FM_PROC_ROOT_OVERRIDE=$proc spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn with under 20 percent memory available was not deferred: $out"
  assert_contains "$out" "available memory 19% against a floor of 20%" "the deferral did not name the memory reading"
  assert_nothing_created "$case_dir" "$home" task-d "$before" "$worktrees"
  rc=0
  proc=$(host_proc "$case_dir" ok 0.00 20)
  out=$(FM_PROC_ROOT_OVERRIDE=$proc spawn_ship "$case_dir" task-e) || rc=$?
  expect_code 0 "$rc" "a spawn on a host under both limits was refused: $out"
  assert_contains "$out" "spawned task-e" "a spawn under both limits did not launch"
  rc=0
  proc=$(host_proc "$case_dir" unknown - -)
  out=$(FM_PROC_ROOT_OVERRIDE=$proc spawn_ship "$case_dir" task-f) || rc=$?
  expect_code 0 "$rc" "unknown host readings refused a spawn: $out"
  assert_contains "$out" "warning: host gate: this host's load1,mem_avail_pct reading is unknown, so it was not judged" "unknown readings were not named"
  assert_contains "$out" "spawned task-f" "a spawn with unknown readings did not launch"
  pass "the host gate defers a spawn on observed load above 1.5 x cores or memory under 20 percent before anything exists, and names but does not defer on unknown readings"
}

# --- review capacity --------------------------------------------------------

# Points the case's project at a GitHub publication target without any fetch
# reaching it: bin/fm-spawn.sh fetches only origin, which stays a local path.
github_target() {  # <case-dir>
  git -C "$1/project" remote add upstream https://github.com/acme/widget.git
}

# Replaces the case's gh-axi with one that logs each call, applies the --jq
# program the caller sent to the raw GraphQL fixture with the real jq, and
# answers in gh-axi's api_response shape. FM_FAKE_GH_RC fails the call,
# FM_FAKE_GH_TRUNCATED reports the body truncated, and FM_FAKE_GH_HOOK names a
# script run while the call is in flight, before the answer is printed.
review_forge() {  # <case-dir>
  cat > "$1/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
if [ "${FM_FAKE_GH_RC:-0}" != 0 ]; then
  printf 'error: "forge unavailable"\ncode: UNKNOWN\n'
  exit "$FM_FAKE_GH_RC"
fi
[ -z "${FM_FAKE_GH_HOOK:-}" ] || bash "$FM_FAKE_GH_HOOK"
expr=
while [ "$#" -gt 0 ]; do
  [ "$1" != --jq ] || { expr=$2; shift; }
  shift
done
body=$(jq -r "$expr" "$FM_FAKE_GH_JSON") || exit 1
printf 'api_response:\n  body: "%s"\n  truncated: %s\n' "$body" "$([ -n "${FM_FAKE_GH_TRUNCATED:-}" ] && echo true || echo false)"
SH
  chmod +x "$1/fakebin/gh-axi"
  : > "$1/gh.log"
}

# One open pull request node: number, head branch, draft, reviewDecision
# (null for none), the head commit an APPROVED review was left on (empty for
# none), and the repository the head branch lives in (default acme/widget, the
# target itself). Its own head commit is h<number>.
pr_node() {  # <number> <head> <draft> <decision|null> [<approved-oid>] [<head-repo>]
  jq -cn --argjson n "$1" --arg head "$2" --argjson draft "$3" --arg d "$4" --arg ap "${5:-}" --arg hr "${6:-Acme/Widget}" '{
    number: $n, headRefName: $head, headRefOid: "h\($n)", isDraft: $draft,
    headRepository: {nameWithOwner: $hr},
    reviewDecision: (if $d == "null" then null else $d end),
    latestOpinionatedReviews: {nodes: (if $ap == "" then [] else [{state: "APPROVED", commit: {oid: $ap}}] end)}}'
}

# The raw GraphQL answer: <total-count>, then one pr_node per open PR listed.
forge_answer() {  # <case-dir> <total-count> [<node>...]
  local out="$1/forge.json" total=$2
  shift 2
  printf '%s\n' "$@" | jq -s --argjson t "$total" '{data: {repository: {pullRequests: {totalCount: $t, nodes: .}}}}' > "$out"
}

# Review spawns read an idle, roomy host fixture, so the always-on host gate
# can never decide a review case on this machine's live load or memory.
review_spawn() {  # <case-dir> <id> [pane-path]
  FM_PROC_ROOT_OVERRIDE=$(host_proc "$1" review 0.00 60) \
    FM_FAKE_GH_LOG="$1/gh.log" FM_FAKE_GH_JSON="$1/forge.json" spawn_ship "$@"
}

# Moves a task record's change time ten minutes into the past, as for a
# handoff recorded long before the spawn's forge read.
age_record() {  # <meta>
  perl -e 'utime(time - 600, time - 600, $ARGV[0]) or exit 1' "$1"
}

test_review_capacity_admits_below_the_cap_with_one_bounded_call() {
  local case_dir out rc=0
  case_dir=$(make_case review-below task-c)
  github_target "$case_dir"
  review_forge "$case_dir"
  # Two holders: a fleet PR awaiting review and a fleet draft. A human branch,
  # an approved fleet PR, a fleet PR approved on its current head, an approved
  # draft, and a PR GitHub reports APPROVED although its listed approval is of
  # an older head hold none: GitHub's own decision takes precedence.
  forge_answer "$case_dir" 7 \
    "$(pr_node 11 fm/a false REVIEW_REQUIRED)" \
    "$(pr_node 12 fm/b true null)" \
    "$(pr_node 13 feat/human false null)" \
    "$(pr_node 14 fm/c false APPROVED)" \
    "$(pr_node 15 fm/e false null h15)" \
    "$(pr_node 16 fm/f true APPROVED h16)" \
    "$(pr_node 17 fm/g false APPROVED h-old)"
  out=$(review_spawn "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a spawn below the review cap was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn below the review cap did not launch"
  assert_equals 1 "$(wc -l < "$case_dir/gh.log" | tr -d ' ')" "admission did not make exactly one forge call"
  assert_contains "$(cat "$case_dir/gh.log")" "api graphql -X POST" "the forge call was not the bounded GraphQL read"
  assert_contains "$(cat "$case_dir/gh.log")" "owner=acme --field name=widget" "the forge call did not address the publication target"
  pass "a publishing ship is admitted below the review cap after one bounded forge call; approved, human, and current-head-approved PRs hold no place"
}

test_review_capacity_defers_a_full_queue_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case review-full task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  # The third holder is a fleet PR whose only approval is of an older head.
  forge_answer "$case_dir" 4 \
    "$(pr_node 11 fm/a false REVIEW_REQUIRED)" \
    "$(pr_node 12 fm/b true null)" \
    "$(pr_node 13 fm/d false null h-old)" \
    "$(pr_node 14 fm/c false CHANGES_REQUESTED)"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn at the review cap was not deferred: $out"
  assert_contains "$out" "deferred: project project admits 3 open unreviewed fleet PR(s) in github.com/acme/widget and its review queue is full: 4 of 3 places are held (#11, #12, #13, #14)" \
    "the deferral did not name the cap and its holders"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a publishing ship at the review cap is deferred before any record, brief, endpoint, worktree, or backlog move exists; drafts, changes requested, and stale approvals hold places"
}

test_review_capacity_counts_unpublished_work_once() {
  local case_dir home out rc=0
  case_dir=$(make_case review-reserve task-c task-d)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  # live-b is PR-ready and its PR is open: counted once, through the forge.
  # live-c recorded a PR that is no longer open: it has left the queue.
  write_live "$home" live-b "$case_dir/project" "branch=fm/live-b" "pr=https://github.com/acme/widget/pull/21"
  write_live "$home" live-c "$case_dir/project" "branch=fm/live-c" "pr=https://github.com/acme/widget/pull/9"
  age_record "$home/state/live-c.meta"
  forge_answer "$case_dir" 2 \
    "$(pr_node 20 fm/a false REVIEW_REQUIRED)" \
    "$(pr_node 21 fm/live-b false REVIEW_REQUIRED)"
  out=$(review_spawn "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a PR-ready worker was counted twice or a landed one still held a place: $out"
  assert_contains "$out" "spawned task-c" "the admitted spawn did not launch"
  # task-c has not published yet, so it now reserves the third place.
  rc=0
  out=$(review_spawn "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an unpublished worker did not reserve its place: $out"
  assert_contains "$out" "3 of 3 places are held (#20, #21, task-c)" "the deferral did not count the unpublished worker as a reservation"
  assert_absent "$home/state/task-d.meta" "the deferred spawn published a record"
  pass "an unpublished ship reserves a place, a PR-ready one is counted once through its open PR, and a landed one frees its place"
}

# A cap of 1 makes each boundary visible on its own. A local worker that
# records its PR handoff while the forge read is in flight keeps its place; a
# fleet head with a valid character outside the plain set (here +) is still
# matched; and a clone with a different origin that publishes to the same
# repository shares the queue.
test_review_capacity_keeps_places_across_handoff_heads_and_clones() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case review-handoff task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  printf '%s\n' "project 1" > "$home/config/review-capacity"
  write_live "$home" live-h "$case_dir/project" "branch=fm/live-h"
  printf 'printf "pr=https://github.com/acme/widget/pull/30\\n" >> "%s"\n' "$home/state/live-h.meta" > "$case_dir/handoff.sh"
  forge_answer "$case_dir" 0
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(FM_FAKE_GH_HOOK="$case_dir/handoff.sh" review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a worker whose handoff landed during the forge read lost its place: $out"
  assert_contains "$out" "1 of 1 places are held (live-h)" "the deferral did not keep the handing-off worker's place"
  grep -qx 'pr=https://github.com/acme/widget/pull/30' "$home/state/live-h.meta" || fail "the handoff fixture did not record the PR during the read"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"

  case_dir=$(make_case review-plus task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  printf '%s\n' "project 1" > "$home/config/review-capacity"
  forge_answer "$case_dir" 1 "$(pr_node 31 'fm/review+followup' false REVIEW_REQUIRED)"
  rc=0
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a fleet PR whose head holds + was not counted: $out"
  assert_contains "$out" "1 of 1 places are held (#31)" "the deferral did not name the + head's PR"

  case_dir=$(make_case review-clones task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  printf '%s\n' "project 1" > "$home/config/review-capacity"
  fm_git_init_commit "$case_dir/mirror"
  fm_git_add_origin "$case_dir/mirror" "$case_dir/mirror.origin.git"
  git -C "$case_dir/mirror" remote add upstream git@github.com:acme/widget.git
  write_live "$home" live-m "$case_dir/mirror" "branch=fm/live-m"
  forge_answer "$case_dir" 0
  rc=0
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a reservation in a clone with a different origin for the same repository was not counted: $out"
  assert_contains "$out" "1 of 1 places are held (live-m)" "the deferral did not count the other clone's reservation"
  pass "a handoff during the forge read keeps its place, a + head is matched exactly, and clones with different origins share one repository's queue"
}

# A worker's own pull request is matched by its exact identity, never by a
# branch name alone, and its record is read as one generation of the file.
test_review_capacity_matches_exact_identity_and_reads_records_coherently() {
  local case_dir home out rc=0 before worktrees real_stat
  # An approved pull request from another fork that shares an unpublished
  # worker's branch name does not release that worker's place.
  case_dir=$(make_case review-fork task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  printf '%s\n' "project 1" > "$home/config/review-capacity"
  write_live "$home" live-s "$case_dir/project" "branch=fm/same-name"
  forge_answer "$case_dir" 1 "$(pr_node 40 fm/same-name false APPROVED '' other/widget)"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "another fork's approved lookalike released a local reservation: $out"
  assert_contains "$out" "1 of 1 places are held (live-s)" "the deferral did not keep the unpublished worker's place"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  # Control: the same approved pull request from the worker's own repository
  # is its pull request, so the approval frees the place.
  forge_answer "$case_dir" 1 "$(pr_node 40 fm/same-name false APPROVED)"
  rc=0
  out=$(review_spawn "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the worker's own approved pull request did not free its place: $out"

  # A handoff published by rename while the walk reads the record: a stat shim
  # replaces the record (as bin/fm-worker-done.sh does) on its first identity
  # read and reports the old identity, so only a coherent read keeps the place.
  if [ "$(uname -s)" != Linux ]; then
    pass "review capacity matches exact pull request identity; the mid-read handoff case skipped (its stat shim replaces GNU stat)"
    return 0
  fi
  case_dir=$(make_case review-rename task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  printf '%s\n' "project 1" > "$home/config/review-capacity"
  write_live "$home" live-r "$case_dir/project" "branch=fm/live-r"
  age_record "$home/state/live-r.meta"
  real_stat=$(command -v stat)
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
target="$home/state/live-r.meta"
if [ "\$1" = -c ] && [ "\$2" = '%i %Y' ] && [ "\$3" = "\$target" ] && [ ! -e "$case_dir/stat.fired" ]; then
  : > "$case_dir/stat.fired"
  old=\$("$real_stat" "\$@")
  { cat "\$target"; printf 'pr=https://github.com/acme/widget/pull/50\n'; } > "\$target.new"
  PATH=/usr/bin:/bin mv -f "\$target.new" "\$target"
  printf '%s\n' "\$old"
  exit 0
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/stat"
  forge_answer "$case_dir" 0
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  rc=0
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  [ -e "$case_dir/stat.fired" ] || fail "the mid-read rename shim never fired"
  grep -qx 'pr=https://github.com/acme/widget/pull/50' "$home/state/live-r.meta" || fail "the shim did not publish the handoff"
  expect_code "$DEFER_EXIT" "$rc" "a handoff renamed in mid-read released its place: $out"
  assert_contains "$out" "1 of 1 places are held (live-r)" "the deferral did not keep the renamed record's place"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  # A record that is present but whose text cannot be read is never skipped.
  case_dir=$(make_case review-unreadable task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  write_live "$home" live-u "$case_dir/project" "branch=fm/live-u"
  cat > "$case_dir/fakebin/cat" <<SH
#!/usr/bin/env bash
[ "\$*" != "-- $home/state/live-u.meta" ] || exit 1
PATH=/usr/bin:/bin exec cat "\$@"
SH
  chmod +x "$case_dir/fakebin/cat"
  forge_answer "$case_dir" 0
  rc=0
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "an unreadable task record was skipped instead of refusing admission: $out"
  assert_contains "$out" "task record $home/state/live-u.meta cannot be read" "the refusal did not name the unreadable record"
  assert_absent "$home/state/task-c.meta" "a spawn refused on an unreadable record published one"
  pass "review capacity matches a worker's exact pull request (another fork's lookalike never releases it), reads each record as one generation across a rename, and refuses when a record cannot be read"
}

test_review_capacity_defers_when_the_queue_cannot_be_counted() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case review-unknown task-c)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  forge_answer "$case_dir" 1 "$(pr_node 11 fm/a false REVIEW_REQUIRED)"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(FM_FAKE_GH_RC=1 review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn whose forge call failed was admitted: $out"
  assert_contains "$out" "review queue in github.com/acme/widget cannot be counted: the open pull requests could not be observed (the gh-axi call failed with exit 1)" \
    "the deferral did not name the failed observation"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  rc=0
  out=$(FM_FAKE_GH_TRUNCATED=1 review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a truncated forge answer was admitted: $out"
  assert_contains "$out" "gh-axi did not report a complete, untruncated answer" "the deferral did not name the truncated answer"
  # More open pull requests than one bounded call lists: the count may be low.
  forge_answer "$case_dir" 250 "$(pr_node 11 fm/a false REVIEW_REQUIRED)"
  rc=0
  out=$(review_spawn "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an incomplete inventory was admitted: $out"
  assert_contains "$out" "the repository has 250 open pull requests and one bounded call lists only 100" "the deferral did not name the incomplete inventory"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "an unreadable, truncated, or incomplete forge inventory defers with the task still queued"
}

test_review_capacity_override_and_scope() {
  local case_dir home out rc=0
  case_dir=$(make_case review-override task-c task-d task-e)
  home="$case_dir/home"
  github_target "$case_dir"
  review_forge "$case_dir"
  forge_answer "$case_dir" 3 \
    "$(pr_node 11 fm/a false REVIEW_REQUIRED)" \
    "$(pr_node 12 fm/b false REVIEW_REQUIRED)" \
    "$(pr_node 13 fm/c false REVIEW_REQUIRED)"
  printf '%s\n' "# widget has two reviewers" "project 4" > "$home/config/review-capacity"
  out=$(review_spawn "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a per-project override of 4 did not admit the fourth: $out"
  printf '%s\n' "project zero" > "$home/config/review-capacity"
  rc=0
  out=$(review_spawn "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a malformed review capacity did not refuse: $out"
  assert_contains "$out" "the review capacity declaration is unreadable" "the refusal did not name the declaration"
  assert_absent "$home/state/task-d.meta" "the refused spawn published a record"
  # A project whose publication target is not GitHub is never judged.
  printf '%s\n' "project 1" > "$home/config/review-capacity"
  git -C "$case_dir/project" remote remove upstream
  : > "$case_dir/gh.log"
  rc=0
  out=$(review_spawn "$case_dir" task-e) || rc=$?
  expect_code 0 "$rc" "a project with no GitHub target was judged: $out"
  assert_equals 0 "$(wc -l < "$case_dir/gh.log" | tr -d ' ')" "a project with no GitHub target made a forge call"
  pass "config/review-capacity overrides the default cap per project, a malformed one refuses, and a non-GitHub target is not judged"
}

test_undeclared_capacity_keeps_dispatch_uncapped
test_available_capacity_admits_the_worker
test_exhausted_capacity_defers_without_leaving_anything_behind
test_spaced_project_name_is_declared
test_hash_prefixed_project_name_is_declared
test_symlinked_home_counts_each_worker_once
test_release_frees_a_place
test_restart_does_not_count_its_own_record
test_occupancy_counts_only_this_projects_workers
test_capacity_is_shared_by_every_local_home
test_unreadable_holders_refuse_admission
test_concurrent_spawns_cannot_both_take_the_last_place
test_failed_spawn_after_admission_holds_no_place
test_unreadable_declaration_refuses_every_spawn
test_batch_reports_a_deferred_pair
test_orca_spawn_is_admitted_under_the_shared_project_lock
test_lane_capacity_gate_is_opt_in
test_lane_capacity_gate_defers_without_leaving_anything_behind
test_lane_capacity_gate_refuses_an_unreadable_opt_in
test_host_gate_defers_an_overloaded_host_and_keeps_the_task_queued
test_review_capacity_admits_below_the_cap_with_one_bounded_call
test_review_capacity_defers_a_full_queue_without_leaving_anything_behind
test_review_capacity_counts_unpublished_work_once
test_review_capacity_keeps_places_across_handoff_heads_and_clones
test_review_capacity_matches_exact_identity_and_reads_records_coherently
test_review_capacity_defers_when_the_queue_cannot_be_counted
test_review_capacity_override_and_scope
