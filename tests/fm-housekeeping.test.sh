#!/usr/bin/env bash
# Exercise legacy process-event archival and SHA-bound VM handoffs in temp homes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-housekeeping)
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state/procevent-inbox"
export HOUSEKEEPING_ROOT="$ROOT"
python3 - <<'PY'
import os
import json
from pathlib import Path
import subprocess
import tarfile
import time

home = Path(os.environ['FM_HOME'])
root = Path(os.environ['HOUSEKEEPING_ROOT'])
inbox = home / 'state/procevent-inbox'

def run(script, *args, code=0, env=None):
    result = subprocess.run([str(root / 'bin' / script), *args],
                            capture_output=True, text=True, env=env)
    assert result.returncode == code, (args, result.stdout, result.stderr)
    return result.stdout

old = time.time() - 8 * 86400
for name in ['old.json', 'old.handled', 'pending.json', 'recent.json',
             'recent.handled', 'late-ack.json', 'late-ack.handled',
             'orphan.handled', 'current.result', 'current.handled']:
    path = inbox / name
    path.write_text('payload: ' + name)
    if not name.startswith('recent') and name != 'late-ack.handled':
        os.utime(path, (old, old))
(inbox / 'linked.json').symlink_to(inbox / 'pending.json')
(inbox / 'linked.handled').write_text('handled')
os.utime(inbox / 'linked.handled', (old, old))
before = {p.name: p.read_bytes() for p in inbox.iterdir()}
assert 'eligible_pairs=1' in run('fm-procevent-archive.sh')
assert {p.name: p.read_bytes() for p in inbox.iterdir()} == before
assert not (home / 'state/procevent-archive').exists()
assert 'archived_pairs=1' in run('fm-procevent-archive.sh', '--apply')
archives = list((home / 'state/procevent-archive').glob('*.tar.gz'))
assert len(archives) == 1
with tarfile.open(archives[0], 'r:gz') as bundle:
    assert set(bundle.getnames()) == {'old.json', 'old.handled'}
    for name in bundle.getnames():
        assert bundle.extractfile(name).read() == before[name]
assert {p.name for p in inbox.iterdir()} == set(before) - {'old.json', 'old.handled'}
assert 'eligible_pairs=0' in run('fm-procevent-archive.sh', '--apply')
assert len(list((home / 'state/procevent-archive').glob('*.tar.gz'))) == 1

ledger = home / 'state/vm-handed.txt'
ledger.write_text('42\n42\n')
a, b = 'a' * 40, 'b' * 40
run('fm-vm-handed.sh', 'check', '42', a, code=1)
run('fm-vm-handed.sh', 'record', '42', a.upper())
run('fm-vm-handed.sh', 'record', '42', a)
assert ledger.read_text() == f'42 {a}\n'
assert (home / 'state/vm-handed.legacy.txt').read_text() == '42\n42\n'
run('fm-vm-handed.sh', 'check', '42', a)
run('fm-vm-handed.sh', 'check', '42', b, code=1)
run('fm-vm-handed.sh', 'record', '42', b)
run('fm-vm-handed.sh', 'check', '42', b)
assert ledger.read_text() == f'42 {a}\n42 {b}\n'
run('fm-vm-handed.sh', 'record', '42', 'short', code=1)

fakebin = home / 'fakebin'
fakebin.mkdir()
gh = fakebin / 'gh-axi'
gh.write_text('#!/bin/sh\nprintf "api_response:\\n  body: %s\\n  truncated: false\\n" "$TEST_SHA"\n')
gh.chmod(0o700)
env = dict(os.environ, PATH=str(fakebin) + ':' + os.environ['PATH'], TEST_SHA=a)
assert run('fm-vm-handed.sh', 'pending', 'owner/repo', '42', env=env) == ''
env['TEST_SHA'] = 'c' * 40
assert run('fm-vm-handed.sh', 'pending', 'owner/repo', '42', env=env) == f'42 {"c" * 40}\n'
env['TEST_SHA'] = '""'
assert run('fm-vm-handed.sh', 'pending', 'owner/repo', '42', env=env) == ''
env['TEST_SHA'] = json.dumps('42\t' + a + '\n43\t' + b)
assert run('fm-vm-handed.sh', 'pending-open', 'owner/repo', env=env) == f'43 {b}\n'
env['TEST_SHA'] = 'unavailable'
run('fm-vm-handed.sh', 'pending', 'owner/repo', '42', env=env, code=1)

jobs = [subprocess.Popen([str(root / 'bin/fm-vm-handed.sh'), 'record', str(n), a],
                         stdout=subprocess.DEVNULL) for n in range(50, 58)]
assert all(job.wait() == 0 for job in jobs)
assert len(ledger.read_text().splitlines()) == 10

# A failed archive publication must leave both source files untouched.
for name in ['failed.json', 'failed.handled']:
    path = inbox / name
    path.write_text(name)
    os.utime(path, (old, old))
archive_dir = home / 'state/procevent-archive'
archive_dir.rename(home / 'saved-archive')
archive_dir.write_text('obstruction')
run('fm-procevent-archive.sh', '--apply', code=1)
assert (inbox / 'failed.json').read_text() == 'failed.json'
assert (inbox / 'failed.handled').read_text() == 'failed.handled'

ledger.write_text('invalid row here\n')
run('fm-vm-handed.sh', 'record', '42', a, code=1)
assert ledger.read_text() == 'invalid row here\n'
ledger.unlink()
external = home / 'outside'
external.write_text('untouched')
ledger.symlink_to(external)
run('fm-vm-handed.sh', 'record', '42', a, code=1)
assert external.read_text() == 'untouched'
run('fm-vm-handed.sh', 'check', '42', a, code=2,
    env=dict(os.environ, FM_HOME=''))
PY
pass 'archive preserves pending/recent/orphan/current files and verifies one recoverable bundle'
pass 'handoff readers bind full heads, preserve legacy history, and reject invalid writes'
