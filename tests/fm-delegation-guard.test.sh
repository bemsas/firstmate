#!/usr/bin/env bash
# bin/fm-delegation-pretool-check.sh and bin/fm-delegation-guard.py behavior,
# driven through the hook entrypoint with synthetic Claude PreToolUse payloads
# in a synthetic primary home (a plain git checkout with a nested project
# clone), an unrelated git repository, and a linked task worktree:
#   1. file-write tools: project clones and other git work trees are denied;
#      private state, memory-like and scratch paths are allowed; shared tracked
#      material is denied only while a task record exists.
#   2. Bash: git mutations, test/build runners, redirections and file mutators
#      aimed at a project are denied; reads, private writes, firstmate's own
#      scripts, and subshell-scoped cd are allowed; newlines split commands.
#   3. grants: a concrete captain operation is allowed only for the named ops,
#      inside the named path, until expiry or revoke; broad or malformed grants
#      are refused; no environment variable bypasses the guard.
#   4. scope: a linked worker worktree and a non-firstmate directory are inert,
#      and malformed or unparseable input allows.
#   5. the independent review's counterexamples: ordinary option and
#      directory-stack spellings, destructive ancestors, owner-script identity,
#      replayed grant validation, and worker binding under an inherited hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-delegation-guard)
H="$TMP_ROOT/home"
EXT="$TMP_ROOT/ext"
WT="$TMP_ROOT/worker-wt"
# The fixture root is the fake $HOME and carries a .git marker, so the guard's
# documented $HOME-rooted work tree exemption ends every ancestor walk here no
# matter which Git checkout the temporary directory sits inside.
FAKE_HOME="$TMP_ROOT"

setup_world() {
  fm_git_init_commit "$H"
  mkdir -p "$H/bin" "$H/data" "$H/state" "$H/config" "$FAKE_HOME/.git" "$TMP_ROOT/scratch"
  printf '# agents\n' > "$H/AGENTS.md"
  cp "$ROOT/bin/fm-delegation-pretool-check.sh" "$ROOT/bin/fm-delegation-guard.py" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$H/bin/"
  git -C "$H" add AGENTS.md bin
  git -C "$H" -c user.name=t -c user.email=t@example.invalid commit -qm home
  fm_git_init_commit "$H/projects/app"
  fm_git_init_commit "$EXT"
  git -C "$H" worktree add -q -b worker "$WT"
  mkdir -p "$WT/state" "$WT/projects"
}

# hook <home-root> <json>: run the entrypoint as Claude would; prints its stdout.
hook() {
  local rc=0 out
  out=$(printf '%s' "$2" | env -u FM_HOME -u FM_TASK_ID -u CLAUDE_PROJECT_DIR HOME="$FAKE_HOME" \
    "$1/bin/fm-delegation-pretool-check.sh") || rc=$?
  expect_code 0 "$rc" "hook exits 0"
  printf '%s' "$out"
}

payload() {  # <tool> <key> <value> [cwd]
  python3 -c 'import json,sys; t,k,v,c=sys.argv[1:5]; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":t,"tool_input":{k:v},"cwd":c}))' \
    "$1" "$2" "$3" "${4:-$H}"
}

decision() {  # <hook stdout> -> deny|allow, failing on a malformed deny object
  [ -n "$1" ] || { printf 'allow'; return; }
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"] == "PreToolUse"
assert d["permissionDecisionReason"].startswith("[delegate-guard]")
print(d["permissionDecision"], end="")'
}

expect() {  # <deny|allow> <label> <tool> <key> <value> [cwd]
  local want=$1 label=$2 out got
  shift 2
  out=$(hook "$H" "$(payload "$@")")
  got=$(decision "$out") || fail "$label: malformed hook output: $out"
  assert_equals "$got" "$want" "$label"
}

test_file_tools() {
  expect deny "Edit in a project clone" Edit file_path "$H/projects/app/README.md"
  expect deny "Write in another git work tree" Write file_path "$EXT/new.txt"
  expect deny "NotebookEdit in a project clone" NotebookEdit notebook_path "$H/projects/app/n.ipynb"
  expect deny "relative path resolved against cwd" Write file_path "README.md" "$EXT"
  expect allow "private data" Write file_path "$H/data/notes.md"
  expect allow "private state" Edit file_path "$H/state/x.txt"
  expect allow "private config" Write file_path "$H/config/flag"
  expect allow "scratch outside any repo" Write file_path "$TMP_ROOT/scratch/memo.md"
  expect allow "tracked material with no live worker" Edit file_path "$H/bin/fm-x.sh"
  : > "$H/state/w1.meta"
  expect deny "tracked material while a worker is live" Edit file_path "$H/bin/fm-x.sh"
  expect allow "private state still allowed while live" Write file_path "$H/data/notes.md"
  rm -f "$H/state/w1.meta"
  local out
  out=$(hook "$H" "$(payload Edit file_path "$H/projects/app/README.md")")
  assert_contains "$out" "project clone under projects/" "deny names the boundary"
  assert_contains "$out" "bin/fm-spawn.sh" "deny names the delegation route"
  expect allow "Read is never judged" Read file_path "$H/projects/app/README.md"
  pass "file-write tools: project and repo targets denied, private state allowed"
}

test_shell() {
  expect deny "git commit in a project" Bash command "git -C projects/app commit -m x"
  expect allow "git status in a project" Bash command "git -C projects/app status"
  expect allow "git log and branch listing" Bash command "git -C projects/app log --oneline; git -C projects/app branch -a"
  expect deny "git branch creation" Bash command "git -C projects/app branch feature"
  expect deny "test runner after cd" Bash command "cd projects/app && npm test"
  expect deny "build with a directory flag" Bash command "make -C projects/app"
  expect deny "pytest in another repo" Bash command "pytest -q" "$EXT"
  expect allow "subshell cd does not leak" Bash command "(cd projects/app && git log -1); git status"
  expect deny "redirect into a project" Bash command "echo hi > projects/app/f"
  expect allow "redirect into private data" Bash command "echo hi >> data/f 2>&1"
  expect allow "descriptor duplication" Bash command "ls projects/app 2>&1 | tee data/log"
  expect allow "sed -i on private data" Bash command "sed -i 's/a/b/' data/x.md"
  expect deny "sed -i in a project" Bash command "sed -i 's/a/b/' projects/app/README.md"
  expect allow "copy from a project into data" Bash command "cp projects/app/README.md data/copy"
  expect deny "copy into a project" Bash command "cp data/copy projects/app/README.md"
  expect allow "firstmate's own scripts" Bash command "bin/fm-merge-local.sh app-task"
  expect deny "a newline separates commands" Bash command "$(printf 'git status\ngit -C %s commit -m y' "$EXT")"
  expect allow "unparseable shell allows" Bash command 'echo "unterminated'
  pass "shell: project mutations and suites denied, reads and private work allowed"
}

test_grants() {
  local out rc gid
  expect deny "before any grant" Edit file_path "$H/projects/app/README.md"
  out=$(env -u FM_HOME HOME="$FAKE_HOME" "$H/bin/fm-delegation-guard.py" grant --path "$H/projects/app" \
    --ops edit --minutes 10 --reason "captain: fix the README typo now") || fail "grant refused"
  assert_contains "$out" "granted:" "grant recorded"
  gid=$(printf '%s' "$out" | awk '{print $2}')
  expect allow "granted edit" Edit file_path "$H/projects/app/README.md"
  expect deny "ungranted op on the same path" Bash command "git -C projects/app commit -m x"
  expect deny "granted op outside the path" Write file_path "$EXT/x"
  out=$(printf '%s' "$(payload Edit file_path "$H/projects/app/README.md")" \
    | env -u FM_HOME HOME="$FAKE_HOME" FM_DELEGATION_NOW_EPOCH=$(( $(date +%s) + 3600 )) "$H/bin/fm-delegation-pretool-check.sh")
  assert_equals "$(decision "$out")" "deny" "expired grant no longer allows"
  out=$(env -u FM_HOME HOME="$FAKE_HOME" "$H/bin/fm-delegation-guard.py" list)
  assert_contains "$out" "captain: fix the README typo now" "list shows the captain's words"
  env -u FM_HOME HOME="$FAKE_HOME" "$H/bin/fm-delegation-guard.py" revoke "$gid" >/dev/null || fail "revoke failed"
  expect deny "revoked grant no longer allows" Edit file_path "$H/projects/app/README.md"
  for bad in "--path / --ops edit --reason r" "--path $FAKE_HOME --ops edit --reason r" \
    "--path $H --ops edit --reason r" "--path $H/projects/app --ops edit,rm --reason r" \
    "--path $H/projects/app --ops edit --reason r --minutes 241" "--path $H/projects/app --ops edit" \
    "--path projects/app --ops edit --reason r" "--path $H/projects/missing --ops edit --reason r"; do
    rc=0
    # shellcheck disable=SC2086 # word splitting builds the argument list on purpose
    env -u FM_HOME HOME="$FAKE_HOME" "$H/bin/fm-delegation-guard.py" grant $bad >/dev/null 2>&1 || rc=$?
    expect_code 1 "$rc" "broad or malformed grant refused: $bad"
  done
  out=$(printf '%s' "$(payload Edit file_path "$H/projects/app/README.md")" \
    | env -u FM_HOME HOME="$FAKE_HOME" FM_ALLOW_DIRECT_EDIT=1 FM_ALLOW_SUBAGENT=1 "$H/bin/fm-delegation-pretool-check.sh")
  assert_equals "$(decision "$out")" "deny" "no environment variable bypasses the guard"
  pass "grants: bounded, op- and path-scoped, expiring, revocable; no env bypass"
}

test_malformed_grant_ops() {
  local out
  python3 - "$H" <<'PY' || fail "could not write malformed grant fixture"
import json
from pathlib import Path
import sys
import time

home = Path(sys.argv[1])
now = int(time.time())
grant = dict(id='g1-aaaaaa', path=str(home / 'projects' / 'app'), ops=['edit', {}],
             reason='synthetic fixture', granted_epoch=now, expires_epoch=now + 600)
with (home / 'state' / 'delegation-grants.json').open('w') as handle:
    json.dump({'schema': 'fm-delegation-grants.v1', 'grants': [grant]}, handle)
PY
  out=$(hook "$H" "$(payload Edit file_path "$H/projects/app/README.md")") \
    || fail "hook failed with a malformed grant operations item"
  assert_equals "$(decision "$out")" "deny" "a grant with a malformed operations item is ignored"
  rm -f "$H/state/delegation-grants.json"
  pass "malformed persisted grant operations preserve the wrapper deny decision"
}

test_standing_allow() {
  fm_git_init_commit "$H/projects/asks-log"
  expect deny "asks-log clone before listing" Write file_path "$H/projects/asks-log/INDEX.md"
  printf '# private record paths\nprojects/asks-log\n\n/\nprojects\n%s\n%s\n' "$H" "$FAKE_HOME" > "$H/config/delegation-guard-allow"
  expect allow "listed private record path" Write file_path "$H/projects/asks-log/INDEX.md"
  expect allow "listed path covers shell writes" Bash command "git -C projects/asks-log commit -am log"
  expect deny "broad entries are ignored" Edit file_path "$H/projects/app/README.md"
  expect deny "other repos stay guarded" Write file_path "$EXT/x"
  rm -f "$H/config/delegation-guard-allow"
  pass "standing allowlist: named private records only, broad entries ignored"
}

test_scope_and_transport() {
  local out
  out=$(hook "$WT" "$(payload Edit file_path "$WT/projects/x/README.md" "$WT")")
  assert_equals "$out" "" "linked worker worktree is inert"
  out=$(hook "$WT" "$(payload Write file_path "$EXT/x" "$WT")")
  assert_equals "$out" "" "worker may edit other repositories"
  out=$(hook "$H" 'not json')
  assert_equals "$out" "" "malformed payload allows"
  out=$(hook "$H" '{"tool_name":"Edit","tool_input":"oops"}')
  assert_equals "$out" "" "malformed tool_input allows"
  rm -rf "$H/state"
  out=$(hook "$H" "$(payload Edit file_path "$H/projects/app/README.md")")
  assert_equals "$out" "" "home without a state directory is inert"
  mkdir -p "$H/state"
  pass "scope: worker worktrees and broken input are inert"
}

test_review_counterexamples() {
  local out
  expect deny "npm with a --prefix value" Bash command "npm --prefix projects/app test"
  expect deny "cp --target-directory= form" Bash command "cp --target-directory=projects/app data/file"
  expect deny "mv into a --target-directory" Bash command "mv --target-directory=projects/app data/file"
  expect deny "bundled GNU sed -ni" Bash command "sed -ni 's/a/b/p' projects/app/README.md"
  expect deny "patch names its original file" Bash command "patch ../projects/app/README.md < tiny.diff" "$H/data"
  expect deny "popd restores a project cwd" Bash command "cd projects/app; pushd ../../data; popd; touch file"
  expect allow "pushd into private data" Bash command "cd projects/app; pushd ../../data; touch file"
  expect deny "removing the home holds its clones" Bash command "rm -r ."
  printf '#!/bin/sh\nexit 0\n' > "$H/projects/app/fm-build.sh"
  chmod +x "$H/projects/app/fm-build.sh"
  expect deny "a project script named like an owner" Bash command "projects/app/fm-build.sh"
  expect allow "the real owner script" Bash command "bin/fm-delegation-guard.py list"
  rm -f "$H/projects/app/fm-build.sh"
  fm_git_init_commit "$H/projects/other"
  out=$(env -u FM_HOME HOME="$FAKE_HOME" "$H/bin/fm-delegation-guard.py" grant --path "$H/projects" \
    --ops edit --minutes 10 --reason "captain: everything" 2>&1) && fail "a grant over every project was recorded: $out"
  python3 - "$H" <<'PY'
import json, sys, time
home = sys.argv[1]
now = int(time.time())
grant = lambda gid, path, **kw: dict(dict(id=gid, path=path, ops=['edit'], reason='replayed',
                                          granted_epoch=now, expires_epoch=now + 600), **kw)
json.dump({'schema': 'fm-delegation-grants.v1', 'grants': [
    grant('g1-aaaaaa', home + '/projects'),
    grant('g2-bbbbbb', home + '/projects/app', expires_epoch=now + 999999),
    grant('g3-cccccc', home + '/projects/app', reason=''),
    grant('g4-dddddd', '/')]}, open(home + '/state/delegation-grants.json', 'w'))
PY
  expect deny "replayed broad, overlong, and reasonless grants are ignored" Edit file_path "$H/projects/other/README"
  expect deny "replayed overlong grant on one project is ignored" Edit file_path "$H/projects/app/README.md"
  printf '{"schema":"wrong","grants":[{"id":"g1-aaaaaa","path":"/","ops":["edit"],"expires_epoch":9999999999}]}' \
    > "$H/state/delegation-grants.json"
  expect deny "a grants file with the wrong schema is ignored" Edit file_path "$H/projects/app/README.md"
  rm -f "$H/state/delegation-grants.json"
  printf '\377\n' > "$H/config/delegation-guard-allow"
  expect deny "an undecodable allowlist allows nothing and keeps the policy" Edit file_path "$H/projects/app/README.md"
  rm -f "$H/config/delegation-guard-allow"
  out=$(hook "$H" '{"tool_name":["Edit"],"tool_input":{"file_path":"projects/app/README.md"}}')
  assert_equals "$out" "" "a non-string tool name is not judged"
  out=$(printf "%s" "$(payload Edit file_path "$WT/AGENTS.md" "$WT")" | env -u FM_HOME HOME="$FAKE_HOME" FM_HOME="$H" FM_TASK_ID=worker \
    "$H/bin/fm-delegation-pretool-check.sh")
  assert_equals "$out" "" "a marked worker running the primary's absolute hook is inert"
  out=$(printf "%s" "$(payload Edit file_path "$WT/AGENTS.md" "$WT")" | env -u FM_HOME -u FM_TASK_ID HOME="$FAKE_HOME" FM_HOME="$H" \
    CLAUDE_PROJECT_DIR="$WT" "$H/bin/fm-delegation-pretool-check.sh")
  assert_equals "$out" "" "a session whose Claude project is a task worktree is inert"
  out=$(payload Edit file_path "$H/projects/app/README.md" | env -u FM_HOME -u FM_TASK_ID HOME="$FAKE_HOME" \
    CLAUDE_PROJECT_DIR="$H" "$H/bin/fm-delegation-pretool-check.sh")
  assert_equals "$(decision "$out")" "deny" "the primary's own Claude project stays guarded"
  pass "review counterexamples: ordinary mutation spellings, owner scripts, grant replay, worker binding"
}

setup_world
fm_test_run test_file_tools test_shell test_grants test_malformed_grant_ops test_standing_allow \
  test_scope_and_transport test_review_counterexamples
