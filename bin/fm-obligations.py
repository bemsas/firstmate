#!/usr/bin/env -S python3 -I -S
# fm-obligations.py - a supervisor's structured obligations ledger and its
# deterministic reconciler against the home's own fleet records.
#
#   fm-obligations.py add --id ID --kind KIND --title TEXT --owner OWNER --source TEXT
#                         [--match REGEX] [--ref ID]... [--due YYYY-MM-DD]
#   fm-obligations.py update ID --evidence TEXT [--title TEXT] [--owner OWNER]
#                         [--match REGEX|none] [--ref ID]... [--clear-refs] [--due DATE|none]
#   fm-obligations.py set ID STATUS --evidence TEXT [--hold BACKLOG_ID] [--until DATE]
#   fm-obligations.py list [--all] [--json]
#   fm-obligations.py validate
#   fm-obligations.py reconcile [--snapshot FILE]
#   fm-obligations.py check [--snapshot FILE]
#   fm-obligations.py digest
#
# Every command accepts --home DIR; the home is --home, else $FM_HOME, else this
# script's own repository root. Python standard library only; no network.
#
# Ledger: <home>/data/obligations.json, schema "fm-obligations.v1":
#   {"schema": "fm-obligations.v1", "obligations": [RECORD, ...]}
# RECORD fields:
#   id      slug [a-z0-9][a-z0-9._-]{0,63}, unique, never reused or deleted.
#   kind    project | side_quest | ask | promise.
#   title   one line, at most 200 characters.
#   owner   "main" (this home) or a secondmate id registered in this home.
#   match   optional case-insensitive regex tested against the id and title of
#           the owner's live and queued work; refs are exact work ids. With
#           neither, the obligation id itself is the only exact ref.
#   status  active | waiting_captain | deferred | done | dropped.
#   hold    backlog id held through bin/fm-captain-hold.sh (waiting_captain).
#   until   YYYY-MM-DD the deferral ends (deferred, required).
#   due     optional YYYY-MM-DD deadline.
#   source  where the obligation came from (the captain's words, a record).
#   history append-only [{"date", "action", "evidence"}]; every status change
#           and edit records operator-supplied evidence. Nothing is inferred:
#           an obligation becomes done or dropped only through `set` with
#           --evidence, never from transcript or worker text.
# Writers hold an exclusive flock on <home>/state/.obligations.lock across the
# read-modify-write and replace the ledger atomically. A malformed ledger is
# never overwritten: every writer refuses, `validate` exits 1, `check` wakes
# once, and the digest reports it.
#
# Evidence: `reconcile` and `check` run bin/fm-fleet-snapshot.sh --json (or
# read --snapshot FILE) and atomically save the subset they need to
# <home>/state/obligations/evidence.json. The snapshot remains the single owner
# of backlog parsing, captain-hold classification (hold_bucket), task records,
# and secondmate summaries with their remote-cache freshness. Per owner:
#   main          live = task records with metadata (not secondmates) plus In
#                 flight backlog rows; queued = unheld Queued rows; holds =
#                 captain-held rows.
#   secondmate    live = the summary's active_children; queued and holds from
#                 its bounded queued inventory. An unknown summary, a cached
#                 copy older than FM_OBLIGATIONS_REMOTE_MAX_AGE seconds (default
#                 3600), an unregistered owner, or a truncated summary without a
#                 match makes the owner's evidence unknown - never empty.
# A failed snapshot saves an unavailable evidence record, so coverage turns
# unknown instead of reusing older facts. Evidence older than
# FM_OBLIGATIONS_EVIDENCE_MAX_AGE seconds (default 7200) is reported stale.
#
# Findings (code: meaning), in digest order:
#   ledger-malformed     the ledger cannot be read or fails the schema.
#   evidence-missing     no reconcile has run; evidence-unavailable / -stale.
#   overdue              active with due before today.
#   uncovered            active, owner evidence known, no matching live work.
#   hold-released        waiting_captain but the hold is gone or the item closed.
#   hold-expired         captain hold whose hold-until has passed.
#   defer-expired        deferred and its until date has arrived.
#   due-soon             active with due within two days.
#   queued-only          matching work exists but only Queued, not live.
#   unknown              the owner's evidence is unknown (reason given).
#   hold-unlinked        waiting_captain without a hold id.
#   hold-aged            undated captain hold the snapshot classifies as aged.
#   match-invalid        the stored match regex does not compile.
#
# digest prints the findings as stable, sorted, timestamp-free lines, capped at
# FM_OBLIGATIONS_DIGEST_LINES (default 12) lines, built from the ledger and the
# saved evidence only; bin/fm-precompact-handoff.py imports digest_lines() for
# its UserPromptSubmit/SessionStart digest and PreCompact handoff.
# check is a custom watcher check body: it prints one line only when a finding
# key (code:id) appears that was absent from its previous run, remembered in
# <home>/state/obligations/emitted.json; a finding that clears and returns wakes
# again. FM_OBLIGATIONS_NOW_EPOCH pins the clock for tests.
import json
import os
import re
import sys
import time
from pathlib import Path

SCHEMA = 'fm-obligations.v1'
EVIDENCE_SCHEMA = 'fm-obligations-evidence.v1'
KINDS = ('project', 'side_quest', 'ask', 'promise')
STATUSES = ('active', 'waiting_captain', 'deferred', 'done', 'dropped')
ID_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
OWNER_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
ORDER = ('ledger-malformed', 'evidence-missing', 'evidence-unavailable', 'evidence-stale',
         'overdue', 'uncovered', 'hold-released', 'hold-expired', 'defer-expired', 'due-soon',
         'queued-only', 'unknown', 'hold-unlinked', 'hold-aged', 'match-invalid')
RANK = {code: n for n, code in enumerate(ORDER)}


class LedgerError(Exception):
    pass


def env_int(name, default):
    raw = os.environ.get(name, '')
    return int(raw) if raw.isdigit() and int(raw) > 0 else default


def now_epoch():
    raw = os.environ.get('FM_OBLIGATIONS_NOW_EPOCH', '')
    return int(raw) if raw.isdigit() else int(time.time())


def day(epoch, offset_days=0):
    return time.strftime('%Y-%m-%d', time.gmtime(epoch + offset_days * 86400))


def resolve_home(arg=None):
    if arg:
        return Path(arg)
    env = os.environ.get('FM_HOME')
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def paths(home):
    home = Path(home)
    return {
        'ledger': home / 'data' / 'obligations.json',
        'lock': home / 'state' / '.obligations.lock',
        'evidence': home / 'state' / 'obligations' / 'evidence.json',
        'emitted': home / 'state' / 'obligations' / 'emitted.json',
    }


def one_line(text, limit):
    text = ' '.join(str(text).split())
    return text if len(text) <= limit else text[:limit - 3] + '...'


def atomic_write(path, text):
    import tempfile
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------- ledger


def valid_date(value):
    if not isinstance(value, str) or not DATE_RE.match(value):
        return False
    try:
        time.strptime(value, '%Y-%m-%d')
    except ValueError:
        return False
    return True


def validate_record(rec):
    if not isinstance(rec, dict):
        return 'record is not an object'
    if not isinstance(rec.get('id'), str) or not ID_RE.match(rec['id']):
        return 'invalid id %r' % rec.get('id')
    rid = rec['id']
    if rec.get('kind') not in KINDS:
        return '%s: invalid kind' % rid
    if rec.get('status') not in STATUSES:
        return '%s: invalid status' % rid
    if not isinstance(rec.get('owner'), str) or not OWNER_RE.match(rec['owner']):
        return '%s: invalid owner' % rid
    for key in ('title', 'source'):
        if not isinstance(rec.get(key), str) or not rec[key].strip():
            return '%s: %s is required' % (rid, key)
    if rec.get('match') is not None and not isinstance(rec['match'], str):
        return '%s: match must be a string' % rid
    refs = rec.get('refs', [])
    if not isinstance(refs, list) or not all(isinstance(r, str) and r for r in refs):
        return '%s: refs must be a list of ids' % rid
    for key in ('due', 'until'):
        if rec.get(key) is not None and not valid_date(rec[key]):
            return '%s: %s must be YYYY-MM-DD' % (rid, key)
    if rec.get('hold') is not None and not isinstance(rec['hold'], str):
        return '%s: hold must be a backlog id' % rid
    if rec['status'] == 'deferred' and not rec.get('until'):
        return '%s: deferred needs until' % rid
    if not isinstance(rec.get('history', []), list):
        return '%s: history must be a list' % rid
    return None


def load_ledger(home):
    path = paths(home)['ledger']
    try:
        raw = path.read_text(encoding='utf-8')
    except FileNotFoundError:
        return {'schema': SCHEMA, 'obligations': []}
    except OSError as exc:
        raise LedgerError('ledger unreadable (%s)' % type(exc).__name__)
    try:
        data = json.loads(raw)
    except ValueError:
        raise LedgerError('ledger is not valid JSON')
    if not isinstance(data, dict) or data.get('schema') != SCHEMA:
        raise LedgerError('ledger schema is not %s' % SCHEMA)
    rows = data.get('obligations')
    if not isinstance(rows, list):
        raise LedgerError('ledger obligations is not a list')
    seen = set()
    for rec in rows:
        problem = validate_record(rec)
        if problem:
            raise LedgerError(problem)
        if rec['id'] in seen:
            raise LedgerError('duplicate id %s' % rec['id'])
        seen.add(rec['id'])
    return data


def dump_ledger(data):
    data['obligations'].sort(key=lambda r: r['id'])
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + '\n'


class Locked:
    def __init__(self, path):
        self.path = path
        self.handle = None

    def __enter__(self):
        import fcntl
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = open(self.path, 'a')
        fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        self.handle.close()


def mutate(home, change):
    """Run change(data) under the ledger lock and replace the ledger atomically."""
    p = paths(home)
    with Locked(p['lock']):
        data = load_ledger(home)
        message = change(data)
        for rec in data['obligations']:
            problem = validate_record(rec)
            if problem:
                raise LedgerError('refusing to write: ' + problem)
        atomic_write(p['ledger'], dump_ledger(data))
    return message


def find(data, oid):
    for rec in data['obligations']:
        if rec['id'] == oid:
            return rec
    raise LedgerError('no obligation %s' % oid)


def check_regex(pattern):
    try:
        re.compile(pattern, re.IGNORECASE)
    except re.error as exc:
        raise LedgerError('match regex does not compile (%s)' % exc)


# -------------------------------------------------------------- evidence


def extract_evidence(snap, now, remote_max_age):
    """Reduce a fm-fleet-snapshot.v1 document to per-owner coverage facts."""
    if not isinstance(snap, dict) or snap.get('schema') != 'fm-fleet-snapshot.v1':
        return {'schema': EVIDENCE_SCHEMA, 'observed_epoch': now, 'available': False,
                'reason': 'fleet snapshot is not fm-fleet-snapshot.v1', 'owners': {}}
    backlog = snap.get('backlog') if isinstance(snap.get('backlog'), dict) else {}
    records = [r for r in backlog.get('records') or [] if isinstance(r, dict) and r.get('id')]
    tasks = [t for t in snap.get('tasks') or [] if isinstance(t, dict) and t.get('id')]
    titles = {r['id']: r.get('title') or '' for r in records}
    live, queued, holds, closed = [], [], {}, []
    for t in tasks:
        if t.get('kind') == 'secondmate':
            continue
        if ((t.get('paths') or {}).get('meta') or {}).get('present') is False:
            continue
        live.append({'id': t['id'], 'title': titles.get(t['id'], '')})
    for r in records:
        state = r.get('state')
        entry = {'id': r['id'], 'title': r.get('title') or ''}
        if r.get('hold_kind') == 'captain' and state != 'done':
            holds[r['id']] = {'bucket': r.get('hold_bucket'), 'until': r.get('hold_until')}
        elif state == 'in_flight':
            live.append(entry)
        elif state == 'queued' and not r.get('hold_kind'):
            queued.append(entry)
        elif state == 'done':
            closed.append(r['id'])
    owners = {'main': {'known': True, 'reason': None, 'backlog_known': bool(backlog.get('present')),
                       'live': live, 'queued': queued, 'holds': holds, 'closed': closed,
                       'truncated': False}}
    current = snap.get('secondmate_current') if isinstance(snap.get('secondmate_current'), dict) else {}
    for rec in current.get('records') or []:
        if not isinstance(rec, dict) or not rec.get('id'):
            continue
        cur = rec.get('current') if isinstance(rec.get('current'), dict) else {}
        prov = rec.get('provenance') if isinstance(rec.get('provenance'), dict) else {}
        fresh = rec.get('freshness') if isinstance(rec.get('freshness'), dict) else {}
        reason = None
        if cur.get('state') == 'unknown' or prov.get('selected') != 'structured-home':
            reason = one_line(cur.get('reason') or 'secondmate summary unavailable', 160)
        elif fresh.get('status') == 'cached':
            age = fresh.get('age_seconds')
            if not isinstance(age, int) or age > remote_max_age:
                reason = 'cached remote summary is stale'
        counts = rec.get('counts') if isinstance(rec.get('counts'), dict) else {}
        active = [a for a in rec.get('active_children') or [] if isinstance(a, dict) and a.get('id')]
        rq = [q for q in rec.get('queued') or [] if isinstance(q, dict) and q.get('id')]
        owners[rec['id']] = {
            'known': reason is None, 'reason': reason, 'backlog_known': reason is None,
            'live': [{'id': a['id'], 'title': a.get('name') or ''} for a in active],
            'queued': [{'id': q['id'], 'title': q.get('title') or ''} for q in rq if not q.get('hold_kind')],
            'holds': {q['id']: {'bucket': q.get('hold_bucket'), 'until': q.get('hold_until')}
                      for q in rq if q.get('hold_kind') == 'captain'},
            'closed': [],
            'truncated': bool(rec.get('omitted')) or counts.get('active_children', 0) > len(active),
        }
    return {'schema': EVIDENCE_SCHEMA, 'observed_epoch': now, 'available': True,
            'reason': None, 'owners': owners}


def run_snapshot(home):
    import subprocess
    script = Path(__file__).resolve().parent / 'fm-fleet-snapshot.sh'
    env = dict(os.environ, FM_HOME=str(home))
    try:
        proc = subprocess.run(['bash', str(script), '--json'], env=env, capture_output=True,
                              timeout=env_int('FM_OBLIGATIONS_SNAPSHOT_TIMEOUT', 25))
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, 'fleet snapshot did not finish (%s)' % type(exc).__name__
    if proc.returncode != 0:
        return None, 'fleet snapshot exited %d' % proc.returncode
    try:
        return json.loads(proc.stdout), None
    except ValueError:
        return None, 'fleet snapshot printed invalid JSON'


def refresh_evidence(home, snapshot_file=None):
    now = now_epoch()
    if snapshot_file:
        try:
            snap, err = json.loads(Path(snapshot_file).read_text(encoding='utf-8')), None
        except (OSError, ValueError) as exc:
            snap, err = None, 'snapshot file unreadable (%s)' % type(exc).__name__
    else:
        snap, err = run_snapshot(home)
    if err:
        evidence = {'schema': EVIDENCE_SCHEMA, 'observed_epoch': now, 'available': False,
                    'reason': err, 'owners': {}}
    else:
        evidence = extract_evidence(snap, now, env_int('FM_OBLIGATIONS_REMOTE_MAX_AGE', 3600))
    atomic_write(paths(home)['evidence'], json.dumps(evidence, sort_keys=True) + '\n')
    return evidence


def load_evidence(home):
    try:
        data = json.loads(paths(home)['evidence'].read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get('schema') != EVIDENCE_SCHEMA:
        return None
    return data


# ------------------------------------------------------------- reconcile


def matches(rec, item):
    refs = rec.get('refs') or ([] if rec.get('match') else [rec['id']])
    if item['id'] in refs:
        return True
    pattern = rec.get('match')
    if pattern:
        rx = re.compile(pattern, re.IGNORECASE)
        return bool(rx.search(item['id']) or rx.search(item.get('title') or ''))
    return False


def evaluate(ledger, evidence, now):
    """Return sorted findings [(code, id, owner, title, detail)] - pure."""
    today, soon = day(now), day(now, 2)
    out = []
    global_unknown = None
    if evidence is None:
        global_unknown = 'no fleet evidence has been reconciled yet'
        out.append(('evidence-missing', '-', '-', 'run fm-obligations.py reconcile', ''))
    elif not evidence.get('available'):
        global_unknown = 'fleet evidence unavailable: ' + one_line(evidence.get('reason') or '?', 120)
        out.append(('evidence-unavailable', '-', '-', one_line(evidence.get('reason') or '?', 120), ''))
    elif now - int(evidence.get('observed_epoch') or 0) > env_int('FM_OBLIGATIONS_EVIDENCE_MAX_AGE', 7200):
        global_unknown = 'fleet evidence is stale'
        out.append(('evidence-stale', '-', '-', 'fleet evidence is stale; the reconcile check has not refreshed it', ''))
    owners = (evidence or {}).get('owners') or {}
    for rec in ledger['obligations']:
        status, oid, owner, title = rec['status'], rec['id'], rec['owner'], one_line(rec['title'], 90)

        def add(code, detail=''):
            out.append((code, oid, owner, title, detail))
        if status in ('done', 'dropped'):
            continue
        if rec.get('match'):
            try:
                re.compile(rec['match'], re.IGNORECASE)
            except re.error:
                add('match-invalid')
                continue
        if status == 'deferred':
            if rec['until'] <= today:
                add('defer-expired', 'until ' + rec['until'])
            continue
        if status == 'active' and rec.get('due'):
            if rec['due'] < today:
                add('overdue', 'due ' + rec['due'])
            elif rec['due'] <= soon:
                add('due-soon', 'due ' + rec['due'])
        ev = owners.get(owner)
        if global_unknown:
            unknown = global_unknown
        elif ev is None:
            unknown = 'owner %s is not a registered secondmate of this home' % owner if owner != 'main' \
                else 'no main-home evidence'
        else:
            unknown = None if ev.get('known') else (ev.get('reason') or 'owner evidence unknown')
        if status == 'waiting_captain':
            hold = rec.get('hold')
            if not hold:
                add('hold-unlinked', 'no captain hold id recorded')
                continue
            if unknown:
                add('unknown', unknown)
                continue
            info = (ev.get('holds') or {}).get(hold)
            if info is None:
                if not ev.get('backlog_known'):
                    add('unknown', 'backlog unreadable')
                elif hold in (ev.get('closed') or []):
                    add('hold-released', 'held item %s is closed' % hold)
                else:
                    add('hold-released', 'item %s is no longer captain-held' % hold)
            elif info.get('until') and info['until'] <= today and info.get('bucket') == 'live':
                add('hold-expired', 'hold-until %s' % info['until'])
            elif info.get('bucket') == 'aged':
                add('hold-aged', 'undated hold aged')
            continue
        # active obligations need live work by their owner.
        if unknown:
            add('unknown', unknown)
            continue
        if any(matches(rec, item) for item in ev.get('live') or []):
            continue
        if any(matches(rec, item) for item in ev.get('queued') or []):
            add('queued-only', 'matching work is queued, not live')
        elif ev.get('truncated'):
            add('unknown', 'owner summary truncated; no match in the shown rows')
        elif owner == 'main' and not ev.get('backlog_known'):
            add('unknown', 'backlog unreadable and no live task matches')
        else:
            add('uncovered', 'no live work by %s matches' % owner)
    out.sort(key=lambda f: (RANK.get(f[0], 99), f[1], f[2]))
    return out


def render(finding):
    code, oid, owner, title, detail = finding
    if oid == '-':
        return '%s: %s' % (code, title)
    line = '%s: %s (%s) - %s' % (code, oid, owner, title)
    return line + ('; ' + detail if detail else '')


def findings_for(home, evidence=None, now=None):
    now = now_epoch() if now is None else now
    if not paths(home)['ledger'].exists():
        return []  # a home without a ledger has not opted in
    try:
        ledger = load_ledger(home)
    except LedgerError as exc:
        return [('ledger-malformed', '-', '-', 'obligations ledger unusable: ' + one_line(exc, 160), '')]
    if evidence is None:
        evidence = load_evidence(home)
    return evaluate(ledger, evidence, now)


def digest_lines(home, now=None):
    """Stable, sorted, bounded, timestamp-free lines - imported by hooks."""
    lines = [render(f) for f in findings_for(home, now=now)]
    cap = env_int('FM_OBLIGATIONS_DIGEST_LINES', 12)
    if len(lines) > cap:
        lines = lines[:cap] + ['... %d more obligation findings (fm-obligations.py digest)' % (len(lines) - cap)]
    return [one_line(line, 240) for line in lines]


# ------------------------------------------------------------------- CLI


def opt(argv, name, many=False):
    vals, rest, i = [], [], 0
    while i < len(argv):
        if argv[i] == name:
            if i + 1 >= len(argv):
                raise LedgerError('%s needs a value' % name)
            vals.append(argv[i + 1])
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    argv[:] = rest
    if many:
        return vals
    if len(vals) > 1:
        raise LedgerError('%s given twice' % name)
    return vals[0] if vals else None


def flag(argv, name):
    if name in argv:
        argv.remove(name)
        return True
    return False


def history(rec, now, action, evidence):
    rec.setdefault('history', []).append({'date': day(now), 'action': action,
                                          'evidence': one_line(evidence, 400)})


def cmd_add(home, argv, now):
    rec = {'id': opt(argv, '--id'), 'kind': opt(argv, '--kind'), 'title': opt(argv, '--title'),
           'owner': opt(argv, '--owner'), 'source': opt(argv, '--source'), 'status': 'active',
           'refs': opt(argv, '--ref', many=True), 'added': day(now)}
    for key, name in (('match', '--match'), ('due', '--due')):
        value = opt(argv, name)
        if value is not None:
            rec[key] = value
    if argv:
        raise LedgerError('unexpected arguments: %s' % ' '.join(argv))
    for key in ('title', 'source'):
        if rec[key] is not None:
            rec[key] = one_line(rec[key], 200 if key == 'title' else 400)
    if rec.get('match'):
        check_regex(rec['match'])
    history(rec, now, 'add', rec['source'] or '')

    def change(data):
        if any(r['id'] == rec['id'] for r in data['obligations']):
            raise LedgerError('obligation %s already exists; use update' % rec['id'])
        problem = validate_record(rec)
        if problem:
            raise LedgerError(problem)
        data['obligations'].append(rec)
        return 'added: %s' % rec['id']
    return mutate(home, change)


def cmd_update(home, argv, now):
    if not argv:
        raise LedgerError('update needs an id')
    oid = argv.pop(0)
    evidence = opt(argv, '--evidence')
    title, owner, match, due = opt(argv, '--title'), opt(argv, '--owner'), opt(argv, '--match'), opt(argv, '--due')
    refs, clear = opt(argv, '--ref', many=True), flag(argv, '--clear-refs')
    if argv:
        raise LedgerError('unexpected arguments: %s' % ' '.join(argv))
    if not evidence or not evidence.strip():
        raise LedgerError('update needs --evidence')
    if match not in (None, 'none'):
        check_regex(match)

    def change(data):
        rec = find(data, oid)
        changed = []
        if title is not None:
            rec['title'] = one_line(title, 200)
            changed.append('title')
        if owner is not None:
            rec['owner'] = owner
            changed.append('owner')
        if match is not None:
            rec.pop('match', None) if match == 'none' else rec.__setitem__('match', match)
            changed.append('match')
        if due is not None:
            rec.pop('due', None) if due == 'none' else rec.__setitem__('due', due)
            changed.append('due')
        if clear or refs:
            rec['refs'] = ([] if clear else list(rec.get('refs') or [])) + [r for r in refs if r]
            changed.append('refs')
        if not changed:
            raise LedgerError('update changed nothing')
        history(rec, now, 'update ' + ','.join(changed), evidence)
        return 'updated: %s' % oid
    return mutate(home, change)


def cmd_set(home, argv, now):
    if len(argv) < 2:
        raise LedgerError('set needs an id and a status')
    oid, status = argv.pop(0), argv.pop(0)
    evidence, hold, until = opt(argv, '--evidence'), opt(argv, '--hold'), opt(argv, '--until')
    if argv:
        raise LedgerError('unexpected arguments: %s' % ' '.join(argv))
    if status not in STATUSES:
        raise LedgerError('status must be one of %s' % ', '.join(STATUSES))
    if not evidence or not evidence.strip():
        raise LedgerError('set needs --evidence naming the record or captain words behind it')
    if status == 'deferred' and not until:
        raise LedgerError('deferred needs --until YYYY-MM-DD')
    if status == 'waiting_captain' and not hold:
        raise LedgerError('waiting_captain needs --hold <backlog id> (bin/fm-captain-hold.sh owns the hold)')

    def change(data):
        rec = find(data, oid)
        rec['status'] = status
        rec.pop('until', None)
        rec.pop('hold', None)
        if until:
            rec['until'] = until
        if hold:
            rec['hold'] = hold
        history(rec, now, 'set ' + status, evidence)
        return 'set: %s %s' % (oid, status)
    return mutate(home, change)


def cmd_list(home, argv):
    show_all, as_json = flag(argv, '--all'), flag(argv, '--json')
    if argv:
        raise LedgerError('unexpected arguments: %s' % ' '.join(argv))
    rows = [r for r in load_ledger(home)['obligations'] if show_all or r['status'] not in ('done', 'dropped')]
    if as_json:
        return json.dumps(rows, indent=2, sort_keys=True, ensure_ascii=False)
    return '\n'.join('%s\t%s\t%s\t%s\t%s' % (r['id'], r['status'], r['owner'], r['kind'], r['title'])
                     for r in rows)


def cmd_check(home, argv, now):
    snapshot = opt(argv, '--snapshot')
    if argv:
        raise LedgerError('unexpected arguments: %s' % ' '.join(argv))
    evidence = refresh_evidence(home, snapshot)
    findings = findings_for(home, evidence, now)
    keys = sorted({'%s:%s' % (f[0], f[1]) for f in findings})
    p = paths(home)
    with Locked(p['lock']):
        try:
            before = set(json.loads(p['emitted'].read_text(encoding='utf-8')))
        except (OSError, ValueError, TypeError):
            before = set()
        atomic_write(p['emitted'], json.dumps(keys) + '\n')
    new = [f for f in findings if '%s:%s' % (f[0], f[1]) not in before]
    if not new:
        return ''
    shown = '; '.join(render(f) for f in new[:4])
    more = ' (+%d more)' % (len(new) - 4) if len(new) > 4 else ''
    return one_line('obligations: %d new finding(s) - %s%s' % (len(new), shown, more), 900)


def usage():
    lines = []
    with open(__file__, encoding='utf-8') as handle:
        next(handle)
        for line in handle:
            if not line.startswith('#'):
                break
            lines.append(line[2:].rstrip('\n'))
    return '\n'.join(lines[:14])


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(usage())
        return 0 if argv else 2
    command, rest = argv[0], list(argv[1:])
    try:
        home = resolve_home(opt(rest, '--home'))
        now = now_epoch()
        if command == 'add':
            out = cmd_add(home, rest, now)
        elif command == 'update':
            out = cmd_update(home, rest, now)
        elif command == 'set':
            out = cmd_set(home, rest, now)
        elif command == 'list':
            out = cmd_list(home, rest)
        elif command == 'validate':
            n = len(load_ledger(home)['obligations'])
            out = 'ledger valid: %d obligation(s)' % n
        elif command == 'reconcile':
            snapshot = opt(rest, '--snapshot')
            if rest:
                raise LedgerError('unexpected arguments: %s' % ' '.join(rest))
            refresh_evidence(home, snapshot)
            out = '\n'.join(render(f) for f in findings_for(home, now=now))
        elif command == 'check':
            out = cmd_check(home, rest, now)
        elif command == 'digest':
            if rest:
                raise LedgerError('unexpected arguments: %s' % ' '.join(rest))
            out = '\n'.join(digest_lines(home, now))
        else:
            print(usage(), file=sys.stderr)
            return 2
    except LedgerError as exc:
        if command == 'check':
            # A watcher check reports through stdout; a broken ledger must wake.
            print('obligations: check failed - ' + one_line(exc, 300))
            return 0
        print('fm-obligations: error: %s' % exc, file=sys.stderr)
        return 1
    if out:
        print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
