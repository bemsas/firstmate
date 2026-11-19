#!/usr/bin/env bash
# fm-agy-worker-hooks.sh - write an agy ship or scout worker's workspace hooks.
#
# Usage: fm-agy-worker-hooks.sh <worktree> <state-dir> <task-id> <busy-gen> <turn-ended-path|->
#
# agy loads <worktree>/.agents/hooks.json (docs/verification/agy.md). This
# writes it with one named spec, `firstmate`:
#   PreInvocation  busy  (source agy-hook, event pre-invocation)
#   Stop           idle  (event stop) only when the payload's fullyIdle is
#                  true, so a pending continuation keeps the turn open; it
#                  also touches <turn-ended-path> unless that is `-`
#   PostToolUse    bin/fm-tool-ring.py append (matcher .*)
# Every command prints nothing (agy reads a printed object as a decision that
# can deny or end the turn) and exits 0. An Escape interrupt fires no hook at
# all; bin/fm-control.sh and fm_busy_agy_record_contradicted
# (bin/fm-busy-lib.sh) cover that gap. bin/fm-spawn.sh owns when to call this
# (a verified agy version, a templated launch, and a worktree without its own
# .agents/hooks.json) and keeps the file out of the worker's commits.
# Refuses to overwrite an existing file.
set -eu
[ "$#" -eq 5 ] || { echo "usage: fm-agy-worker-hooks.sh <worktree> <state-dir> <task-id> <busy-gen> <turn-ended-path|->" >&2; exit 2; }
wt=$1 state=$2 id=$3 gen=$4 turnend=$5
root=$(cd "$(dirname "$0")/.." && pwd -P)
hooks="$wt/.agents/hooks.json"
if [ -e "$hooks" ] || [ -L "$hooks" ]; then
  echo "error: $hooks already exists; agy worker hooks never overwrite it" >&2
  exit 1
fi
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
busy="$(q "$root/bin/fm-busy-event.sh") apply $(q "$state") $(q "$id")"
suffix="--gen $(q "$gen") --source agy-hook"
touch_turnend=
[ "$turnend" = - ] || touch_turnend="touch $(q "$turnend"); "
mkdir -p "$wt/.agents"
jq -n \
  --arg open "$busy busy $suffix --event pre-invocation >/dev/null 2>&1; exit 0" \
  --arg close "python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get(\"fullyIdle\") is True else 1)' >/dev/null 2>&1 && { ${touch_turnend}$busy idle $suffix --event stop; } >/dev/null 2>&1; exit 0" \
  --arg ring "$(q "$root/bin/fm-tool-ring.py") append $(q "$state") $(q "$id") >/dev/null 2>&1; exit 0" \
  '{firstmate: {
     PreInvocation: [{type: "command", command: $open, timeout: 10}],
     Stop: [{type: "command", command: $close, timeout: 10}],
     PostToolUse: [{matcher: ".*", hooks: [{type: "command", command: $ring, timeout: 10}]}]}}' \
  > "$hooks"
