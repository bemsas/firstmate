#!/usr/bin/env bash
# Behavior tests for bin/fm-review-eligibility-preview.sh, its formatter
# bin/fm-review-eligibility-preview.py, and the reads they share with
# bin/fm-review-capacity-lib.sh and bin/fm-review-verdict.sh. The synthetic
# fixture lives in tests/warp-review-eligibility-preview.test.py.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in python3 jq git tasks-axi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

python3 "$ROOT/tests/warp-review-eligibility-preview.test.py" || fail "review eligibility preview fixture failed"
pass "fm-review-eligibility-preview: joins forge, verdict, hold, owner, and dispatch inputs read-only"
