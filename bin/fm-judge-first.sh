#!/usr/bin/env bash
# Judge-first: run a secondmate's new needs-decision:/blocked: status lines
# through the private decision judge before the supervisor spends a turn on them.
# Usage:
#   fm-judge-first.sh ingest <secondmate-id> <status-lines-file|->
#   fm-judge-first.sh summary [--since <epoch>]
# Called by bin/fm-procevent-remote-reply.sh right after it mirrors new remote
# status lines; also runnable by hand on any lines file. Always exits 0 from
# `ingest`: an error leaves today's ordinary wake. bin/fm-judge-first.py owns the
# decision order, the guard rules, dedupe, and the journal; docs/configuration.md
# "Judge-first" owns config/judge-first (absent = off, empty = shadow, on = live).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-judge-first: python3 required" >&2
  [ "${1:-}" = ingest ] && exit 0
  exit 1
fi
exec "$PY" "$SCRIPT_DIR/fm-judge-first.py" "$@"
