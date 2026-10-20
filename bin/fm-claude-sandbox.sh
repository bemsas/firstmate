#!/usr/bin/env bash
# Generate the opt-in Claude worker Bash-sandbox policy as JSON on stdout.
# Usage: fm-claude-sandbox.sh --temp-parent
#        fm-claude-sandbox.sh <worktree> <code-root> <home> <state> <data> <config> <task-id> <temp-root>
# Called by fm-spawn.sh --claude-sandbox; creates the task status file and inbox
# before generating settings. Reads/writes no credentials or shared settings.
# The temp root must be a short, private spawn-owned directory (tasktmp in meta),
# cleaned by normal teardown. Never mask all of /tmp: the network bridge lives
# there. Mask /tmp/claude-<uid> and the per-user sandbox temp parent, reopening
# only this task's short child path. Home reads are masked except
# the worktree, git metadata, installed tools, and exact task plumbing paths.
# Status, reports and inbox acknowledgements stay inside the Bash sandbox.
# The optional fleet ledger is captured by a PostToolUse hook outside the Bash
# sandbox: its shared lock and atomic offset rename cannot use exact-file bind
# mounts. The worker receives no write grant to the shared ledger or state dir.
# Only standalone gh-axi issue list / pr list / pr view calls are excluded:
# these read operations need the host keyring and run OUTSIDE the sandbox.
# Pipelines, redirects and compound calls remain subject to Claude's matching.
# Other gh-axi operations receive no keyring exception. No token is copied.
# This is a Bash boundary, not isolation of file tools, hooks, MCP or Claude.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
sandbox_parent="/tmp/fs$(printf '%x' "$(id -u)")"
if [ "${1:-}" = --temp-parent ] && [ "$#" = 1 ]; then
  if ! (umask 077; mkdir "$sandbox_parent") 2>/dev/null; then
    if [ -L "$sandbox_parent" ] || [ ! -d "$sandbox_parent" ] || [ ! -O "$sandbox_parent" ] ||
      [ -n "$(find "$sandbox_parent" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
      ! chmod 700 "$sandbox_parent"; then
      echo 'error: Claude sandbox temp parent must be private, owned and non-symlink' >&2
      exit 1
    fi
  fi
  printf '%s\n' "$sandbox_parent"
  exit 0
fi
[ "$#" = 8 ] || { echo 'error: expected worktree, code-root, home, state, data, config, task-id, temp-root' >&2; exit 2; }
id=$7
temp=$8
case "$id" in ''|.*|*[!A-Za-z0-9._-]*) echo 'error: invalid sandbox task id' >&2; exit 2 ;; esac
case "$temp" in "$sandbox_parent/"*) ;; *) echo 'error: Claude sandbox temp must be beneath its private parent' >&2; exit 1 ;; esac
[ "${#temp}" -le 30 ] || { echo 'error: Claude sandbox temp root exceeds 30 bytes' >&2; exit 1; }
wt=$(cd "$1" && pwd -P)
root=$(cd "$2" && pwd -P)
home=$(cd "$3" && pwd -P)
state=$(cd "$4" && pwd -P)
data=$(cd "$5/$7" && pwd -P)
config=$(cd "$6" && pwd -P)
# Exact allowWrite file mounts need an existing inode; granting an absent status
# path cannot create it through the read-only parent. Do not truncate history.
status="$state/$id.status"
if [ -L "$status" ] || { [ -e "$status" ] && [ ! -f "$status" ]; }; then
  echo 'error: sandbox status must be a regular non-symlink file' >&2
  exit 1
fi
for dir in "$state/$id.inbox" "$state/$id.inbox/handled"; do
  [ ! -L "$dir" ] || { echo 'error: sandbox inbox cannot be a symlink' >&2; exit 1; }
done
(umask 077; : >> "$status"; mkdir -p "$state/$id.inbox/handled")
gitdir=$(git -C "$wt" rev-parse --git-common-dir)
case "$gitdir" in /*) ;; *) gitdir="$wt/$gitdir" ;; esac
gitdir=$(cd "$gitdir" && pwd -P)
ledgercmd=
if [ -e "$config/fleet-ledger" ]; then
  printf -v ledgercmd '%q ' /bin/bash "$home/bin/fm-fleet-ledger.sh" appended "$config" "$status"
  ledgercmd="$ledgercmd >/dev/null 2>&1 || true"
fi
jq -cn --arg wt "$wt" --arg root "$root" --arg home "$home" \
  --arg state "$state" --arg data "$data" --arg config "$config" \
  --arg id "$id" --arg temp "$temp" --arg gitdir "$gitdir" \
  --arg userhome "$HOME" --arg parent "$sandbox_parent" --arg uid "$(id -u)" --arg ledgercmd "$ledgercmd" '
  [$state + "/" + $id + ".status", $data, $state + "/" + $id + ".inbox"] as $task |
  ["gh-axi issue list *", "gh-axi pr list *", "gh-axi pr view *"] as $github |
  {sandbox: {enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false,
     autoAllowBashIfSandboxed: true,
     filesystem: {
       denyRead: [$userhome + "/", "/tmp/claude-" + $uid, $parent],
       allowRead: ([$wt, $gitdir, $root + "/bin", $home + "/bin", $config + "/fleet-ledger",
         $userhome + "/.local/bin", $userhome + "/.local/share/mise",
         $userhome + "/.no-mistakes", $userhome + "/.config/git", $root + "/.agents/skills", $temp] + $task | unique),
       allowWrite: ($task + [$temp]),
       denyWrite: [$state + "/operational-inbox", $root + "/.agents/skills"]},
     network: {allowedDomains: ["github.com", "api.github.com"], strictAllowlist: true},
     excludedCommands: $github},
   permissions: {allow: ($github | map("Bash(" + . + ")"))}}
  + (if $ledgercmd == "" then {} else
      {hooks: {PostToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $ledgercmd}]}]}} end)
'
