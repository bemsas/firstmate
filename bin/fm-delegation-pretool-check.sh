#!/usr/bin/env bash
# Claude PreToolUse entrypoint for the supervisor delegation guard.
#
# A supervising firstmate home routes hands-on project work to workers; this
# guard turns that rule into a deterministic deny for the edits, git mutations,
# and test or build runs a supervisor should delegate. bin/fm-delegation-guard.py
# is the single owner of the classification, the deny payload, and the bounded
# captain-operation grants; run it with --help for that contract.
#
# This wrapper only scopes the guard: it runs the policy solely in a genuine
# primary home (a plain checkout or a marked secondmate home, per
# bin/fm-primary-scope-lib.sh) whose state directory exists. In a crewmate or
# scout task worktree, which is a linked worktree, it exits 0 with no output
# before reading the payload, so ordinary workers are never affected.
# It is opt-in per home: register it by absolute path in that home's private
# .claude/settings.local.json under PreToolUse, never in the tracked settings.
# There is deliberately no environment bypass.
#
# Usage: <Claude PreToolUse JSON on stdin> | bin/fm-delegation-pretool-check.sh
# Output: nothing (allow) or one Claude deny object on stdout; always exit 0.
set -u

case "${1:-}" in
  -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
HOME_DIR=${FM_HOME:-$FM_ROOT}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$HOME_DIR/state" || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

exec python3 -I -S "$SCRIPT_DIR/fm-delegation-guard.py" check --home "$HOME_DIR"
