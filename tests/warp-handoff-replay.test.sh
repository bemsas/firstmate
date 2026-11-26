#!/usr/bin/env bash
# Offline replay of four handoff failures through the current owner entry points:
# a superseded head on a resumed task, repeated ready notices over a captain hold,
# a handoff killed after its first durable commit, and ready wording without a
# durable acceptance record. Fixtures and cases live in the Python file beside this one.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 -I "$ROOT/tests/warp-handoff-replay.test.py" ||
  fail "handoff replay cases failed"
pass "four durable handoff failure shapes stay refused or converge through their owners"
