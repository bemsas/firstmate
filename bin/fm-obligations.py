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
#   match   optional case-insensitive matcher tested against the id and title
#           of the owner's live and queued work: up to 20 |-separated literal
#           fragments (letters, digits, space, ._/:#+-), each optionally anchored
#           with a leading ^ or trailing $; no regular expressions, so matching
#           stays linear on the hook path. refs are exact work ids. With
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
# read --snapshot FILE) and save the subset they need to
# <home>/state/obligations/evidence.json, keeping the snapshot's own generation
# time and each secondmate summary's observed_at. The snapshot remains the single
# owner of backlog parsing, captain-hold classification (hold_bucket), task
# records, inventory validity, and secondmate summaries. Per owner:
#   main          live = non-terminal task records with metadata (not
#                 secondmates) plus In flight rows whose role needs no child
#                 (program, held); an In flight worker row is proven only by its
#                 task record, and a done or failed task proves nothing; queued =
#                 unheld Queued rows; holds = captain-held rows. An unreadable
#                 backlog or unstructured current rows leave absence unknown.
#   secondmate    live = the summary's active_children; queued and holds from
#                 its bounded queued inventory. A registered, structured summary
#                 is required; one observed more than FM_OBLIGATIONS_REMOTE_MAX_AGE
#                 seconds (default 3600) before the moment a finding is computed,
#                 whatever its source, is unknown. A partial projection, an omitted
#                 surface, or a shortened field keeps visible matches but cannot
#                 prove absence, of work or of a hold, so it yields unknown.
# Each refresh takes an attempt ticket under the ledger lock before observing
# and publishes only if no later attempt has published, so a slow older check
# never replaces newer evidence; check keys its wake to the published record.
# A failed snapshot publishes an unavailable evidence record, so coverage turns
# unknown instead of reusing older facts. Evidence whose snapshot generation is
# older than FM_OBLIGATIONS_EVIDENCE_MAX_AGE seconds (default 7200) is stale.
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
#   match-invalid        the stored matcher is outside the supported form.
#
# Displayed finding text (digest, reconcile, check) passes through
# bin/fm-precompact-handoff.py's credential redaction; the ledger keeps the
# original text. digest prints the findings as stable, sorted, timestamp-free lines, capped at
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
MATCH_ALT_RE = re.compile(r'^\^?[A-Za-z0-9 ._/:#+-]+\$?$')
MAX_LEDGER_BYTES = 1024 * 1024
MAX_SNAPSHOT_BYTES = 16 * 1024 * 1024


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
        'attempt': home / 'state' / 'obligations' / 'attempt-seq',
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
        with open(path, 'rb') as handle:
            raw = handle.read(MAX_LEDGER_BYTES + 1)
    except FileNotFoundError:
        return {'schema': SCHEMA, 'obligations': []}
    except OSError as exc:
        raise LedgerError('ledger unreadable (%s)' % type(exc).__name__)
    if len(raw) > MAX_LEDGER_BYTES:
        raise LedgerError('ledger exceeds %d bytes' % MAX_LEDGER_BYTES)
    try:
        raw = raw.decode('utf-8')
    except UnicodeDecodeError:
        raise LedgerError('ledger is not valid UTF-8')
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError):
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


def check_match(pattern):
    problem = match_problem(pattern)
    if problem:
        raise LedgerError(problem)


# -------------------------------------------------------------- evidence


TERMINAL_STATES = ('done', 'failed')
ELLIPSIS = '\u2026'  # the snapshot's trunc() marker for a shortened field


def utc_epoch(value):
    if not isinstance(value, str):
        return None
    try:
        import calendar
        return calendar.timegm(time.strptime(value, '%Y-%m-%dT%H:%M:%SZ'))
    except ValueError:
        return None


def item(ident, title, proof='live'):
    """One piece of owner work; *_cut marks a field the snapshot shortened."""
    ident, title = str(ident), str(title or '')
    return {'id': ident, 'title': title, 'proof': proof,
            'id_cut': ident.endswith(ELLIPSIS), 'title_cut': title.endswith(ELLIPSIS)}


def main_evidence(snap, backlog, records):
    """Main-home owner facts from task records, In flight roles and inventory validity."""
    titles = {r['id']: r.get('title') or '' for r in records}
    work, holds, closed = [], {}, []
    for t in snap.get('tasks') or []:
        if not isinstance(t, dict) or not isinstance(t.get('id'), str) or t.get('kind') == 'secondmate':
            continue
        if ((t.get('paths') or {}).get('meta') or {}).get('present') is not True:
            continue
        state = (t.get('current_state') or {}).get('state') if isinstance(t.get('current_state'), dict) else None
        if state in TERMINAL_STATES:
            continue  # terminal metadata is no proof of live work
        # Present, non-terminal task metadata is the worker's assignment record.
        work.append(item(t['id'], titles.get(t['id'], '')))
    task_ids = {w['id'] for w in work}
    for r in records:
        state = r.get('state')
        if r.get('hold_kind') == 'captain' and state != 'done':
            holds[r['id']] = {'bucket': r.get('hold_bucket'), 'until': r.get('hold_until')}
        elif state == 'in_flight':
            role = r.get('current_role')
            if role == 'worker' or r.get('requires_child_metadata'):
                # A worker row is proven only by its task record above.
                if r['id'] not in task_ids:
                    work.append(item(r['id'], r.get('title'), 'indeterminate'))
            elif role in ('program', 'held'):
                work.append(item(r['id'], r.get('title')))  # coordinated or held work owns no child
            else:
                work.append(item(r['id'], r.get('title'), 'indeterminate'))
        elif state == 'queued' and not r.get('hold_kind'):
            work.append(item(r['id'], r.get('title'), 'queued'))
        elif state == 'done':
            closed.append(r['id'])
    inventory = snap.get('main_inventory')
    reason = None
    if not backlog.get('present'):
        reason = 'main backlog unreadable'
    elif not isinstance(inventory, dict) or not isinstance(inventory.get('valid'), bool):
        reason = 'main inventory validity missing from the snapshot'
    elif not inventory['valid'] and (inventory.get('unstructured_current_count') or 0) > 0:
        reason = 'main backlog has unstructured current rows'
    return {'known': True, 'reason': None, 'observed_epoch': None, 'work': work,
            'holds': holds, 'closed': closed, 'live_gap': reason, 'holds_gap': reason}


def mate_evidence(rec):
    """Secondmate owner facts with per-surface completeness."""
    cur = rec.get('current') if isinstance(rec.get('current'), dict) else {}
    prov = rec.get('provenance') if isinstance(rec.get('provenance'), dict) else {}
    fresh = rec.get('freshness') if isinstance(rec.get('freshness'), dict) else {}
    counts = rec.get('counts') if isinstance(rec.get('counts'), dict) else {}
    omitted = {o.get('surface') for o in rec.get('omitted') or [] if isinstance(o, dict)}
    reason = None
    if rec.get('registered') is not True:
        reason = 'owner %s is not a registered secondmate of this home' % rec['id']
    elif cur.get('state') == 'unknown' or prov.get('selected') != 'structured-home':
        reason = one_line(cur.get('reason') or 'secondmate summary unavailable', 160)
    observed = utc_epoch(fresh.get('observed_at'))
    if reason is None and observed is None:
        reason = 'secondmate summary observation time unknown'
    active = [a for a in rec.get('active_children') or [] if isinstance(a, dict) and a.get('id')]
    rq = [q for q in rec.get('queued') or [] if isinstance(q, dict) and q.get('id')]
    partial = None
    if prov.get('summary_valid') is not True or prov.get('trust') != 'complete':
        partial = 'owner summary is partial (%s)' % one_line(cur.get('reason') or prov.get('trust') or 'invalid', 120)
    live_gap = partial
    if live_gap is None and ('active_children' in omitted or counts.get('active_children') != len(active)):
        live_gap = 'owner summary omits active rows'
    holds_gap = partial
    if holds_gap is None and ('queued' in omitted or counts.get('queued') != len(rq)):
        holds_gap = 'owner summary omits queued rows'
    work = [item(a['id'], a.get('name')) for a in active]
    work += [item(q['id'], q.get('title'), 'queued') for q in rq if not q.get('hold_kind')]
    return {'known': reason is None, 'reason': reason, 'observed_epoch': observed, 'work': work,
            'holds': {q['id']: {'bucket': q.get('hold_bucket'), 'until': q.get('hold_until')}
                      for q in rq if q.get('hold_kind') == 'captain'},
            'cut_hold_ids': [q['id'][:-1] for q in rq if str(q['id']).endswith(ELLIPSIS)],
            'closed': [], 'live_gap': live_gap, 'holds_gap': holds_gap}


def extract_evidence(snap, now):
    """Reduce a fm-fleet-snapshot.v1 document to per-owner coverage facts."""
    def unavailable(reason):
        return {'schema': EVIDENCE_SCHEMA, 'recorded_epoch': now, 'snapshot_epoch': None,
                'available': False, 'reason': reason, 'owners': {}}
    if not isinstance(snap, dict) or snap.get('schema') != 'fm-fleet-snapshot.v1':
        return unavailable('fleet snapshot is not fm-fleet-snapshot.v1')
    generated = utc_epoch(snap.get('generated'))
    if generated is None:
        return unavailable('fleet snapshot has no generation time')
    if generated > now + 300:
        return unavailable('fleet snapshot generation time is in the future')
    backlog = snap.get('backlog') if isinstance(snap.get('backlog'), dict) else {}
    records = [r for r in backlog.get('records') or [] if isinstance(r, dict) and isinstance(r.get('id'), str)]
    owners = {'main': main_evidence(snap, backlog, records)}
    current = snap.get('secondmate_current') if isinstance(snap.get('secondmate_current'), dict) else {}
    for rec in current.get('records') or []:
        if isinstance(rec, dict) and isinstance(rec.get('id'), str) and rec['id'] != 'main':
            owners[rec['id']] = mate_evidence(rec)
    return {'schema': EVIDENCE_SCHEMA, 'recorded_epoch': now, 'snapshot_epoch': generated,
            'available': True, 'reason': None, 'owners': owners,
            'mates_truncated': current.get('truncated') is not False}


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


def next_attempt(home):
    """Take a strictly increasing attempt ticket; call under the ledger lock."""
    path = paths(home)['attempt']
    try:
        last = int(path.read_text(encoding='ascii').strip() or 0)
    except (OSError, ValueError):
        last = 0
    atomic_write(path, '%d\n' % (last + 1))
    return last + 1


def refresh_evidence(home, snapshot_file=None, on_published=None):
    """Observe the fleet, then publish under the ledger lock only if no attempt
    that started later has already published; on_published(evidence) runs under
    that same lock against whichever observation is actually published."""
    p = paths(home)
    with Locked(p['lock']):
        attempt = next_attempt(home)
    now = now_epoch()
    if snapshot_file:
        try:
            with open(snapshot_file, 'rb') as handle:
                raw = handle.read(MAX_SNAPSHOT_BYTES + 1)
            if len(raw) > MAX_SNAPSHOT_BYTES:
                raise ValueError('oversized')
            snap, err = json.loads(raw.decode('utf-8')), None
        except (OSError, ValueError, RecursionError) as exc:
            snap, err = None, 'snapshot file unreadable (%s)' % type(exc).__name__
    else:
        snap, err = run_snapshot(home)
    if err:
        evidence = {'schema': EVIDENCE_SCHEMA, 'recorded_epoch': now, 'snapshot_epoch': None,
                    'available': False, 'reason': err, 'owners': {}}
    else:
        evidence = extract_evidence(snap, now)
    evidence['attempt'] = attempt
    with Locked(p['lock']):
        current = load_evidence(home)
        if current is None or not isinstance(current.get('attempt'), int) or current['attempt'] < attempt:
            atomic_write(p['evidence'], json.dumps(evidence, sort_keys=True) + '\n')
            current = evidence
        return on_published(current) if on_published else current


def load_evidence(home):
    try:
        with open(paths(home)['evidence'], 'rb') as handle:
            raw = handle.read(MAX_SNAPSHOT_BYTES + 1)
        data = json.loads(raw.decode('utf-8')) if len(raw) <= MAX_SNAPSHOT_BYTES else None
    except (OSError, ValueError, RecursionError):
        return None
    if not isinstance(data, dict) or data.get('schema') != EVIDENCE_SCHEMA:
        return None
    return data


# ------------------------------------------------------------- reconcile


def match_problem(pattern):
    """None when pattern is a supported matcher, else why not."""
    if not isinstance(pattern, str) or not pattern or len(pattern) > 200:
        return 'match must be 1-200 characters'
    alts = pattern.split('|')
    if len(alts) > 20 or not all(MATCH_ALT_RE.match(a) for a in alts):
        return ('match takes up to 20 |-separated literal fragments of letters, digits, '
                'space and ._/:#+- with optional ^ and $ anchors')
    return None


def fragment_hit(alt, text):
    head, tail = alt.startswith('^'), alt.endswith('$')
    body = alt[1 if head else 0:len(alt) - 1 if tail else len(alt)].lower()
    text = text.lower()
    if head and tail:
        return text == body
    if head:
        return text.startswith(body)
    if tail:
        return text.endswith(body)
    return body in text


def match_result(rec, it):
    """True, False, or None when a shortened field leaves the answer open."""
    refs = rec.get('refs') or ([] if rec.get('match') else [rec['id']])
    if not it['id_cut'] and it['id'] in refs:
        return True
    pattern = rec.get('match')
    if pattern and any(fragment_hit(a, it['id']) or fragment_hit(a, it['title'])
                       for a in pattern.split('|')):
        return True
    if it['id_cut'] and any(r.startswith(it['id'][:-1]) for r in refs):
        return None
    if pattern and (it['id_cut'] or it['title_cut']):
        return None
    return False


def owner_unknown(owner, ev, evidence, now):
    if ev is None:
        if owner == 'main':
            return 'no main-home evidence'
        if evidence.get('mates_truncated', True):
            return 'owner %s is not in the shown secondmate records' % owner
        return 'owner %s is not a registered secondmate of this home' % owner
    if not ev.get('known'):
        return ev.get('reason') or 'owner evidence unknown'
    observed = ev.get('observed_epoch')
    if owner != 'main':
        if not isinstance(observed, int):
            return 'owner summary observation time unknown'
        age = now - observed
        if age > env_int('FM_OBLIGATIONS_REMOTE_MAX_AGE', 3600) or age < -300:
            return 'owner summary observed %ds ago is stale' % age
    return None


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
    elif (not isinstance(evidence.get('snapshot_epoch'), int)
          or now - evidence['snapshot_epoch'] > env_int('FM_OBLIGATIONS_EVIDENCE_MAX_AGE', 7200)):
        global_unknown = 'fleet evidence is stale'
        out.append(('evidence-stale', '-', '-', 'fleet evidence is stale; the reconcile check has not refreshed it', ''))
    owners = (evidence or {}).get('owners') or {}
    for rec in ledger['obligations']:
        status, oid, owner, title = rec['status'], rec['id'], rec['owner'], one_line(rec['title'], 90)

        def add(code, detail=''):
            out.append((code, oid, owner, title, detail))
        if status in ('done', 'dropped'):
            continue
        if rec.get('match') and match_problem(rec['match']):
            add('match-invalid', match_problem(rec['match']))
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
        unknown = global_unknown or owner_unknown(owner, ev, evidence, now)
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
                if ev.get('holds_gap'):
                    add('unknown', '%s; hold %s is not in the shown rows' % (ev['holds_gap'], hold))
                elif any(hold.startswith(c) for c in ev.get('cut_hold_ids') or []):
                    add('unknown', 'a shortened row id may be hold %s' % hold)
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
        hits = [(w, match_result(rec, w)) for w in ev.get('work') or []]
        if any(r is True and w['proof'] == 'live' for w, r in hits):
            continue
        open_rows = [w['id'] for w, r in hits
                     if (r is None and w['proof'] != 'queued') or (r is True and w['proof'] == 'indeterminate')]
        if open_rows:
            add('unknown', 'matching work %s has no proven live state' % one_line(', '.join(open_rows[:3]), 120))
        elif ev.get('live_gap'):
            add('unknown', '%s; no match in the shown rows' % ev['live_gap'])
        elif any(r is True and w['proof'] == 'queued' for w, r in hits):
            add('queued-only', 'matching work is queued, not live')
        else:
            add('uncovered', 'no live work by %s matches' % owner)
    out.sort(key=lambda f: (RANK.get(f[0], 99), f[1], f[2]))
    return out


_REDACT = []


def redact(text, limit):
    """Display redaction shared with bin/fm-precompact-handoff.py, its owner."""
    if not _REDACT:
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location(
                'fm_precompact_handoff', str(Path(__file__).resolve().parent / 'fm-precompact-handoff.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            _REDACT.append(module.clean)
        except Exception:
            _REDACT.append(None)
    if _REDACT[0] is None:
        return one_line('[finding text withheld: display redaction unavailable]', limit)
    return _REDACT[0](str(text), limit)


def render(finding, limit=240):
    code, oid, owner, title, detail = finding
    if oid == '-':
        return redact('%s: %s' % (code, title), limit)
    line = '%s: %s (%s) - %s' % (code, oid, owner, title)
    return redact(line + ('; ' + detail if detail else ''), limit)


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
        check_match(rec['match'])
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
        check_match(match)

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
    p = paths(home)

    def emit(evidence):
        # Runs under the ledger lock against the published observation, so a
        # slower, older check can neither republish nor re-key stale findings.
        findings = findings_for(home, evidence, now)
        keys = sorted({'%s:%s' % (f[0], f[1]) for f in findings})
        try:
            saved = json.loads(p['emitted'].read_text(encoding='utf-8'))
            before = set(saved.get('keys') if isinstance(saved, dict) else saved)
        except (OSError, ValueError, TypeError):
            before = set()
        atomic_write(p['emitted'], json.dumps({'attempt': evidence.get('attempt'), 'keys': keys}) + '\n')
        return [f for f in findings if '%s:%s' % (f[0], f[1]) not in before]
    new = refresh_evidence(home, snapshot, on_published=emit)
    if not new:
        return ''
    shown = '; '.join(render(f, 300) for f in new[:4])
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
            evidence = refresh_evidence(home, snapshot)
            out = '\n'.join(render(f) for f in findings_for(home, evidence, now))
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
    except Exception as exc:
        if command == 'check':
            print('obligations: check failed - internal error (%s)' % type(exc).__name__)
            return 0
        raise
    if out:
        print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
