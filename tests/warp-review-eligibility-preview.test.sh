#!/usr/bin/env bash
# Behavior tests for bin/fm-review-eligibility-preview.sh, its formatter
# bin/fm-review-eligibility-preview.py, and the reads they share with
# bin/fm-review-capacity-lib.sh and bin/fm-review-verdict.sh. The fixture lives in
# tests/warp-review-eligibility-preview.test.py; this runs it with its synthetic
# tasks-axi and again with the installed one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for backend in synthetic real; do
  FM_PREVIEW_TASKS_AXI=$backend python3 "$ROOT/tests/warp-review-eligibility-preview.test.py" ||
    fail "review eligibility preview fixture failed with the $backend tasks-axi"
done
pass "fm-review-eligibility-preview: joins forge, verdict, hold, owner, and dispatch inputs read-only"
