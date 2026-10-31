#!/usr/bin/env bash
# Compact launch task capsules and per-spawn launch context measurement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-capsule)

make_home() {
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  git -C "$projects/proj" init -q || fail "could not initialize project fixture"
  # Spawn refuses an unborn HEAD, so the fixture project needs one commit.
  git -C "$projects/proj" -c user.email=fm@example.com -c user.name=fm -c commit.gpgsign=false \
    commit -q --allow-empty -m init || fail "could not commit project fixture"
  printf '#!/bin/sh\nexit 1\n' >"$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

fill_brief_subsections() {
  local file=$1 intent=$2 spec=$3 content
  content=$(cat "$file")
  content=${content//'{TASK}'/$intent}
  content=${content//'{FIRSTMATE_SPEC}'/$spec}
  printf '%s\n' "$content" >"$file"
}

run_spawn() {
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_capsule_is_smaller_and_measured() {
  local rec home proj fakebin id out brief launch meta brief_bytes launch_bytes
  rec=$(make_home capsule)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id=capsule-ship-a1
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only >/dev/null
  brief="$home/data/$id/brief.md"
  fill_brief_subsections "$brief" "Ship a compact launch capsule." "Measure bytes on spawn."
  mkdir -p "$home/config"
  printf '%s\n' 'Standing home rule that should not appear in the launch capsule.' \
    >"$home/config/brief-include.md"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode local-only --yolo off) || true
  assert_present "$home/data/$id/launch-brief.md" \
    "capsule render failed before tmux: $out"
  launch="$home/data/$id/launch-brief.md"
  assert_present "$launch" "spawn did not render launch-brief.md"
  brief_bytes=$(wc -c <"$brief")
  launch_bytes=$(wc -c <"$launch")
  [ "$launch_bytes" -lt "$brief_bytes" ] \
    || fail "launch capsule ($launch_bytes bytes) was not smaller than brief.md ($brief_bytes bytes)"
  assert_grep '# Task capsule' "$launch" "launch brief missing capsule marker"
  assert_not_contains "$launch" 'Standing home rule' \
    "home brief additions leaked into the launch capsule"
  assert_grep '# Rules' "$brief" "fixture brief should still carry full Rules"
  assert_not_contains "$launch" '# Rules' "launch capsule should omit the Rules section"
  assert_grep 'do not reject it as another home' "$launch" \
    "launch capsule missing steering inbox authority"
  assert_present "$home/state/$id.launch-context.log" "spawn did not record launch context size"
  assert_grep 'bytes=' "$home/state/$id.launch-context.log" \
    "launch-context.log missing byte measurement"
  pass "fm-spawn: launch brief is a compact capsule with measured context size"
}

test_spawn_capsule_keeps_progress_notes() {
  local rec home proj fakebin id launch
  rec=$(make_home progress)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id=capsule-progress-a1
  FM_HOME="$home" "$BRIEF" "$id" proj --mode local-only >/dev/null
  brief="$home/data/$id/brief.md"
  fill_brief_subsections "$brief" "Continue after relaunch." "Preserve progress notes."
  printf '\n## Progress note (2026-01-01)\nFixed the parser crash.\n' >>"$brief"
  run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode local-only --yolo off >/dev/null || true
  launch="$home/data/$id/launch-brief.md"
  assert_grep 'Fixed the parser crash.' "$launch" \
    "launch capsule omitted a progress note from the full brief"
  pass "fm-spawn: progress notes reach the launch capsule"
}

test_spawn_capsule_is_smaller_and_measured
test_spawn_capsule_keeps_progress_notes

echo "# all fm-task-capsule tests passed"
