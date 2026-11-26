"""Run the shell reconciliation step with inert JSON exceeding Linux argv limits."""
from pathlib import Path
import json
import re
import subprocess
import tempfile


script = Path('bin/fm-fleet-snapshot.sh').read_text()
definition = re.search(r'^parent_evidence_reconciliation_json\(\) \{[^\n]*\n.*?^\}', script, re.M | re.S)
if definition is None:
    raise SystemExit(1)
with tempfile.TemporaryDirectory(prefix='fm-json-size-') as directory:
    root = Path(directory)
    library = root / 'reconcile.sh'
    library.write_text(definition[0] + '\n')
    summary = root / 'summary.json'
    summary.write_text(json.dumps({'active_children': [], 'decisions_open': [], 'holds': [], 'counts': {'active_children': 0, 'decisions_open': 0, 'holds': 0}}))
    summary_text = 'synthetic' * 20000
    activity = root / 'activity.json'
    activity.write_text(json.dumps([{'key': 'fixture', 'verb': 'working', 'summary': summary_text}]))
    decisions = root / 'decisions.json'
    decisions.write_text(json.dumps([{'key': 'fixture', 'verb': 'needs-decision', 'summary': summary_text}]))
    command = ['bash', '-ec', '. "$1"; parent_evidence_reconciliation_json "$2" "$(cat "$3")" "$(cat "$4")"', '_', str(library), str(summary), str(activity), str(decisions)]
    result = subprocess.run(command, text=True, capture_output=True, check=False, timeout=12)
    if result.returncode == 126 and 'Argument list too long' in result.stderr:
        raise SystemExit(10)
    if result.returncode:
        raise SystemExit(1)
    payload = json.loads(result.stdout)
    if payload.get('contradiction') is not True or payload.get('inconclusive') is not False:
        raise SystemExit(1)
    for field in ('activities','decisions'):
        rows = payload.get(field, [])
        if len(rows) != 1 or rows[0].get('summary') != summary_text or rows[0].get('verdict') != 'contradicts':
            raise SystemExit(1)
