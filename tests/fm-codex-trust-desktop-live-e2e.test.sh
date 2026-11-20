#!/usr/bin/env bash
# Read-only guard for an attended native dialog in an already launched worker.
# FM_CODEX_TRUST_* inputs describe the same homes and executables as the CLI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_TRUST_LIVE python3
: "${FM_CODEX_TRUST_MAIN:?set FM_CODEX_TRUST_MAIN to the canonical Main home}"
: "${FM_CODEX_TRUST_OPS:?set FM_CODEX_TRUST_OPS to the canonical Ops home}"
: "${FM_CODEX_TRUST_HERDR:?set FM_CODEX_TRUST_HERDR to the Herdr executable}"
: "${FM_CODEX_TRUST_CODEX:?set FM_CODEX_TRUST_CODEX to the native Codex executable}"
: "${FM_CODEX_TRUST_TASK:?set FM_CODEX_TRUST_TASK to the recorded HOME_ID/TASK with a pending dialog}"
: "${FM_CODEX_TRUST_PROMPT:?set FM_CODEX_TRUST_PROMPT to folder or hooks}"
test -x "$FM_CODEX_TRUST_HERDR" || fail "Herdr binary is absent"
test -x "$FM_CODEX_TRUST_CODEX" || fail "native Codex binary is absent"
versions="$("$FM_CODEX_TRUST_CODEX" --version), $("$FM_CODEX_TRUST_HERDR" --version)"
if ! out=$("$ROOT/bin/fm-codex-trust-desktop.py" --dry-run \
    --main-home "$FM_CODEX_TRUST_MAIN" --ops-home "$FM_CODEX_TRUST_OPS" \
    --herdr-bin "$FM_CODEX_TRUST_HERDR" --codex-bin "$FM_CODEX_TRUST_CODEX" --task "$FM_CODEX_TRUST_TASK"); then
  fail "$versions refused the native dialog: $out"
fi
python3 - "$out" "$FM_CODEX_TRUST_PROMPT" "$versions" <<'PY'
import json
import sys

raw, kind, versions = sys.argv[1:]
keys = {"hooks": ["down", "enter"], "folder": ["enter"]}
assert kind in keys, (versions, "unsupported expected dialog")
assert raw, (versions, f"no live {kind} dialog was verified")
row = json.loads(raw)
assert row.get("dialog") == kind and row.get("planned_keys") == keys[kind], (versions, row)
print(f"ok - {versions}: native {kind} dialog and affirmative key plan verified without input")
PY
