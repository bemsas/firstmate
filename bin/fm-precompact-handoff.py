#!/usr/bin/env -S python3 -I -S
# fm-precompact-handoff.py - supervisor continuity hooks for a Claude primary:
# a PreCompact handoff, the opted-in read-first compact page, and the cached
# turn digest for UserPromptSubmit and SessionStart.
#
#   fm-precompact-handoff.py precompact [--home DIR] [--out FILE]
#   fm-precompact-handoff.py compact --session ID [--home DIR]
#   fm-precompact-handoff.py observe-compact --transcript FILE [--boundary UUID] [--home DIR]
#   fm-precompact-handoff.py inject [--home DIR] [--event NAME]
#   fm-precompact-handoff.py --help
#
# The shebang runs Python isolated and without site packages (-I -S): a
# site-packages .pth import alone can exceed the 50 ms hook budget, and the
# script needs only the standard library. Register it by its absolute path.
#
# Hook modes read the native Claude hook payload as JSON on stdin, always exit
# 0, and never block the hook event: an unreadable payload, transcript, or
# record leaves the event untouched and prints one short diagnostic on stderr.
# The home is --home, else $FM_HOME, else this script's own repository root.
#
# precompact (PreCompact): reads only the tail (FM_HANDOFF_TAIL_BYTES, default
# 4 MiB) of the payload's transcript_path JSONL and replaces one delimited,
# machine-written block in <home>/data/session-progress.md (or --out) with the
# captain's latest prompts (entries whose origin kind is human), recent
# dispatch and steering commands (bin/fm-send.sh, fm-spawn.sh, fm-control.sh,
# fm-captain-hold.sh, fm-pr-merge.sh, fm-merge-local.sh, fm-teardown.sh),
# pull request links, and the last assistant note. Everything outside the
# block is preserved byte for byte; the file is replaced atomically under an
# exclusive flock on a sibling .<name>.lock file, so concurrent or repeated
# runs converge on one block. The lock wait is bounded
# (FM_HANDOFF_LOCK_WAIT_MS, default 200): a busy lock skips the refresh and
# keeps the existing handoff. The payload's trigger and session id are rendered
# only when they are plain tokens. Obvious credential shapes are redacted and the
# block's own delimiter comments are neutralized in transcript text before
# anything is written. Transcript text is untrusted evidence only: it never
# changes the obligations ledger. A transcript_path that is not a regular file
# (a FIFO, device, or directory) is not opened. When the home keeps an
# obligations ledger (bin/fm-obligations.py), the block also lists its current
# findings. stdout carries a one-line instruction for the compaction summarizer.
#
# inject (UserPromptSubmit, SessionStart): prints a
# hookSpecificOutput.additionalContext object built only from local records
# that are already on disk - it never runs a network check, so it stays well
# under 50 ms. Lines, sorted and deduplicated, come from:
#   - <home>/data/backlog.md open captain holds whose (hold-until: DATE) is on
#     or before the current UTC date (the tasks-axi markdown metadata form);
#   - <home>/state/turn-context.alerts, one alert per line (blank lines and
#     lines starting with # skipped), written by any home check that already
#     ran its own probes; a cache older than FM_TURN_CONTEXT_STALE_SECS
#     (default 7200) adds one fixed stale-cache line instead of trusting it;
#   - bin/fm-obligations.py digest_lines(), prefixed "obligation ", when the
#     home keeps data/obligations.json; it reads only the ledger and the
#     evidence its watcher check last saved.
# The digest carries no clock time, so an unchanged record set yields a
# byte-identical context and keeps the prompt cache warm. Nothing to report
# prints nothing. Output is capped at FM_TURN_CONTEXT_MAX_LINES lines
# (default 15) and FM_TURN_CONTEXT_MAX_CHARS characters (default 2000).
#
# compact (SessionStart): called by fm-sessionstart-run.sh after startup and
# lock proof. Render at most 1660 UTF-8 bytes from the matching native
# transcript's last proven human turn and the existing local backlog projection.
# Dependencies and the hold inventory provide decision pointers. Only a
# matching captain resolution record supplies a decision excerpt. Task state
# limits the next step; it never supplies authorization. Wakes, assistant
# notes, free-form progress and cached alerts supply neither intent nor
# readiness. Do not drain here: the page points to the ordinary wake drain
# before fleet action, which retains ownership of presentation and ack state.
#
# The compact renderer retains only the expected content digest, keyed by the
# session and its pre-boundary transcript tip. observe-compact reads a bounded
# native transcript tail and prints one result for the selected boundary
# (latest by default). Only a matching SessionStart:compact attachment in
# that boundary's chain establishes delivery. No transcript text is printed.
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

BEGIN = '<!-- fm-precompact-handoff:begin - machine-written before compaction; edit outside this block -->'
END = '<!-- fm-precompact-handoff:end -->'
DISPATCH = re.compile(r'fm-(send|spawn|control|captain-hold|pr-merge|merge-local|teardown)\.sh')
PR_URL = re.compile(r'https://[A-Za-z0-9.-]+/[^\s)\]>"\']+/pull/[0-9]+')
SECRET = re.compile(
    r'(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
    r'|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})')
SECRET_ASSIGN = re.compile(r'(?i)\b((?:api[_-]?key|token|secret|password|passwd)\s*[=:]\s*)\S+')
MARKER = re.compile(r'<!--\s*fm-precompact-handoff', re.IGNORECASE)
HOLD = re.compile(r'^- \[ \] (\S+) - .*\(hold-kind: captain\).*\(hold-until: (\d{4}-\d{2}-\d{2})\)')
SCRIPT_DIR = Path(__file__).resolve().parent
COMPACT_BYTES = 1660
COMPACT_TAIL_BYTES = 4 * 1024 * 1024
UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
UTC_STAMP = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z', re.ASCII)
TASK_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}')


def warn(msg):
    print('fm-precompact-handoff: ' + msg, file=sys.stderr)


def resolve_home(arg):
    if arg:
        return Path(arg)
    env = os.environ.get('FM_HOME')
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def env_int(name, default):
    raw = os.environ.get(name, '')
    return int(raw) if raw.isdigit() and int(raw) > 0 else default


def read_payload():
    try:
        raw = sys.stdin.read()
    except OSError:
        return {}
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        warn('hook payload is not JSON')
        return {}
    return data if isinstance(data, dict) else {}


def clean(text, limit):
    text = MARKER.sub('<!- fm-precompact-handoff', text)
    text = SECRET.sub('[redacted]', text)
    text = SECRET_ASSIGN.sub(r'\1[redacted]', text)
    text = ' '.join(text.split())
    return text if len(text) <= limit else text[:limit - 3] + '...'


def entry_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(x['text'] for x in content
                         if isinstance(x, dict) and x.get('type') == 'text'
                         and isinstance(x.get('text'), str))
    return ''


def tail_entries(path, max_bytes, *, nofollow=False, strict=False):
    import stat  # deferred: only the precompact path reads a transcript
    flags = os.O_RDONLY | getattr(os, 'O_NONBLOCK', 0)
    if nofollow:
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise IsADirectoryError('transcript_path is not a regular file')
    with os.fdopen(fd, 'rb') as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        start = max(0, size - max_bytes)
        handle.seek(start)
        blob = handle.read(size - start)  # never past the measured tail, even if it grows
    lines = blob.split(b'\n')
    if start > 0:
        lines = lines[1:]
    for line in lines:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except (ValueError, RecursionError):
            if strict:
                raise
            continue
        if isinstance(entry, dict):
            yield entry


def is_human_prompt(entry, text):
    origin = entry.get('origin')
    if isinstance(origin, dict) and 'kind' in origin:
        return origin.get('kind') == 'human'
    if entry.get('isMeta') or entry.get('isCompactSummary'):
        return False
    return bool(text.strip()) and not text.lstrip().startswith('<')


def extract(path, max_bytes):
    prompts, commands, prs, note = [], [], [], ''
    for entry in tail_entries(path, max_bytes):
        kind = entry.get('type')
        message = entry.get('message') if isinstance(entry.get('message'), dict) else {}
        content = message.get('content')
        if kind == 'user':
            text = entry_text(content)
            if text and is_human_prompt(entry, text):
                prompts.append(clean(text, 300))
        elif kind == 'assistant' and isinstance(content, list):
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get('type') == 'text' and item.get('text', '').strip():
                    note = item['text']
                    prs.extend(PR_URL.findall(item['text']))
                elif item.get('type') == 'tool_use':
                    tool_input = item.get('input') if isinstance(item.get('input'), dict) else {}
                    command = tool_input.get('command')
                    if isinstance(command, str) and DISPATCH.search(command):
                        commands.append(clean(command, 200))
    return prompts, commands, prs, note


def newest_unique(items, limit):
    seen, out = set(), []
    for item in reversed(items):
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
        if len(out) == limit:
            break
    return out


def obligation_lines(home):
    if not (home / 'data' / 'obligations.json').exists():
        return []
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            'fm_obligations', str(Path(__file__).resolve().parent / 'fm-obligations.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module._REDACT[:] = [clean]  # this script owns display redaction
        return [clean(line, 240) for line in module.digest_lines(home)]
    except Exception as exc:  # never let the ledger break a hook
        warn('obligations digest unavailable (%s)' % type(exc).__name__)
        return ['obligations digest unavailable; run bin/fm-obligations.py validate']


def render_block(payload, prompts, commands, prs, note, obligations=()):
    stamp = time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime())
    session = payload.get('session_id')
    session = session[:8] if isinstance(session, str) and re.match(r'^[A-Za-z0-9_-]{1,128}$', session) else '-'
    trigger = payload.get('trigger')
    trigger = trigger if isinstance(trigger, str) and re.match(r'^[a-z_-]{1,32}$', trigger) else '-'
    out = [BEGIN, '## Pre-compaction handoff',
           '- Saved %s, trigger %s, session %s' % (stamp, trigger, session)]
    sections = [
        ("Captain's latest prompts (newest first)", ['"%s"' % p for p in newest_unique(prompts, 6)]),
        ('Recent dispatch and steering commands (newest first)', ['`%s`' % c.replace('`', "'") for c in newest_unique(commands, 10)]),
        ('Pull request links seen (newest first)', [clean(u, 300) for u in newest_unique(prs, 8)]),
        ('Obligation ledger findings (derived; the ledger, not this list, is authoritative)',
         list(obligations)),
    ]
    for title, rows in sections:
        out.append('### ' + title)
        empty = '- none' if title.startswith('Obligation') else '- none in the read transcript tail'
        out.extend('- ' + row for row in rows) if rows else out.append(empty)
    out.append('### Last assistant note')
    out.append('> ' + (clean(note, 500) if note else 'none in the read transcript tail'))
    out.append(END)
    return '\n'.join(out) + '\n'


def splice(existing, block):
    if BEGIN in existing and END in existing and existing.index(BEGIN) < existing.index(END):
        head = existing[:existing.index(BEGIN)]
        tail = existing[existing.index(END) + len(END):]
        return head + block.rstrip('\n') + tail
    if existing.startswith('# '):
        first, _, rest = existing.partition('\n')
        return first + '\n' + block + ('\n' + rest if rest else '')
    return block + ('\n' + existing if existing else '')


def atomic_write(path, text):
    import tempfile  # deferred: only the precompact path writes
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', errors='surrogateescape', newline='') as handle:
            handle.write(text)
        if path.exists():
            os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_precompact(args):
    payload = read_payload()
    out = Path(args.out) if args.out else resolve_home(args.home) / 'data' / 'session-progress.md'
    transcript = payload.get('transcript_path')
    prompts, commands, prs, note = [], [], [], ''
    if isinstance(transcript, str) and transcript:
        try:
            prompts, commands, prs, note = extract(transcript, env_int('FM_HANDOFF_TAIL_BYTES', 4 * 1024 * 1024))
        except OSError as exc:
            warn('transcript unreadable (%s)' % type(exc).__name__)
    else:
        warn('payload has no transcript_path')
    home = resolve_home(args.home)
    obligations = obligation_lines(home)
    try:
        import fcntl
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out.parent / ('.' + out.name + '.lock'), 'a') as lock:
            # Bounded wait: a held sibling lock skips this refresh and keeps the
            # existing handoff rather than stalling compaction.
            deadline = time.monotonic() + env_int('FM_HANDOFF_LOCK_WAIT_MS', 200) / 1000.0
            while True:
                try:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        warn('handoff lock busy; kept the existing handoff')
                        return 0
                    time.sleep(0.01)
            existing = ''
            if out.exists():
                # newline='' and surrogateescape keep every byte outside the block.
                with open(out, encoding='utf-8', errors='surrogateescape', newline='') as handle:
                    existing = handle.read()
            atomic_write(out, splice(existing, render_block(payload, prompts, commands, prs, note, obligations)))
    except OSError as exc:
        warn('could not write %s (%s)' % (out, type(exc).__name__))
        return 0
    print('Compaction note: the pre-compaction handoff in %s lists the captain\'s latest prompts, '
          'dispatch commands and PR links; keep open asks, promises and task assignments verbatim.' % out)
    if obligations:
        print('Keep every obligation id below and its finding verbatim in the summary:')
        for line in obligations:
            print('- ' + line)
    return 0


def expired_holds(backlog, today):
    rows = []
    try:
        lines = backlog.read_text(encoding='utf-8').splitlines()
    except OSError:
        return rows
    for line in lines:
        match = HOLD.match(line)
        if match and match.group(2) <= today:
            rows.append('expired captain hold: %s (hold-until %s)' % (match.group(1), match.group(2)))
    return rows


def cached_alerts(path, stale_after):
    try:
        stat = path.stat()
        lines = path.read_text(encoding='utf-8').splitlines()
    except OSError:
        return []
    if time.time() - stat.st_mtime > stale_after:
        return ['turn-context alert cache is stale; the check that writes it has not refreshed it']
    return [clean(line, 240) for line in lines if line.strip() and not line.lstrip().startswith('#')]


def cmd_inject(args):
    payload = read_payload()
    event = str(payload.get('hook_event_name') or args.event or 'UserPromptSubmit')
    home = resolve_home(args.home)
    today = time.strftime('%Y-%m-%d', time.gmtime())
    rows = expired_holds(home / 'data' / 'backlog.md', today)
    rows += cached_alerts(home / 'state' / 'turn-context.alerts', env_int('FM_TURN_CONTEXT_STALE_SECS', 7200))
    rows += ['obligation ' + line for line in obligation_lines(home)]
    rows = sorted(set(rows))
    if not rows:
        return 0
    max_lines = env_int('FM_TURN_CONTEXT_MAX_LINES', 15)
    max_chars = env_int('FM_TURN_CONTEXT_MAX_CHARS', 2000)
    extra = len(rows) - max_lines
    rows = rows[:max_lines] + (['... %d more' % extra] if extra > 0 else [])
    text = '[FIRSTMATE TURN DIGEST - derived from cached local records]\n' + '\n'.join('- ' + r for r in rows)
    if len(text) > max_chars:
        text = text[:max_chars - 3] + '...'
    print(json.dumps({'hookSpecificOutput': {'hookEventName': event, 'additionalContext': text}}))
    return 0


def byte_count(text):
    return len(text.encode('utf-8'))


def excerpt(text, limit):
    import unicodedata
    text = clean(text, len(text) + 32)
    text = ''.join(char for char in text if not unicodedata.category(char).startswith('C'))
    text = json.dumps(text, ensure_ascii=False)[1:-1].replace('<', '‹').replace('>', '›')
    if byte_count(text) > limit:
        text = text.encode('utf-8')[:limit - 3].decode('utf-8', 'ignore') + '...'
    return '"' + text + '"'


def compact_transcript(path, session):
    path = Path(path or '')
    config = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
    if (not path.is_absolute() or path.name != session + '.jsonl'
            or path.parent.resolve().parent != (config / 'projects').resolve()):
        return None
    return path.resolve(strict=True) if not path.is_symlink() else None


def compact_human_prompt(entries, session):
    import subprocess
    for entry in reversed(entries):
        origin = entry.get('origin')
        if (entry.get('type') != 'user' or entry.get('sessionId') != session
                or entry.get('isMeta') or entry.get('isCompactSummary')
                or entry.get('isSidechain') or not isinstance(origin, dict) or origin.get('kind') != 'human'):
            continue
        stamp, identity = entry.get('timestamp'), entry.get('uuid')
        if (not isinstance(stamp, str) or not UTC_STAMP.fullmatch(stamp)
                or not isinstance(identity, str) or not UUID.fullmatch(identity)):
            continue
        message = entry.get('message')
        text = entry_text(message.get('content')) if isinstance(message, dict) else ''
        stripped = text.lstrip()
        if not stripped or stripped.startswith('<') or re.match(r'^/compact(?:\s|$)', stripped):
            continue
        # Claude may record terminal-injected doorbells as human turns. Use
        # the operational protocol owner's classifier, including its carrier
        # shape when the corresponding wake record has already been pruned.
        operational = subprocess.run(
            ['bash', '-c', '. "$1"; text=$(cat); '
             'fm_operational_input_classify "$text" kind || fm_operational_doorbell_path "$text" record',
             'compact-classify', str(SCRIPT_DIR / 'fm-operational-input.sh')],
            input=text.encode('utf-8', 'replace'),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if operational.returncode == 1:
            return stamp, identity, text
        if operational.returncode != 0:
            return None
    return None


def compact_read(home, command, *args):
    import subprocess
    return subprocess.run(
        [command, *args], env={**os.environ, 'FM_HOME': str(home)},
        capture_output=True, encoding='utf-8', check=True).stdout


def compact_backlog(home):
    # The local projection owns Markdown row identity, blockers and hold
    # buckets. Its contribution input has no worker or cross-home probes.
    output = compact_read(home, 'bash', '-c', '''
        . "$1/fm-tasks-axi-lib.sh"
        data=${FM_DATA_OVERRIDE:-$FM_HOME/data}
        [ -f "$data/backlog.md" ] && [ ! -L "$data/backlog.md" ] || exit 1
        fm_backlog_backend_manual "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" ||
          [ "$(fm_tasks_axi_backend_resolve "$data/..")" = markdown ] || exit 1
        exec "$1/fm-fleet-snapshot.sh" --contribution-input
        ''', 'compact-backlog', str(SCRIPT_DIR))
    tasks = {}
    unknown = 0
    backlog = json.loads(output)['backlog']
    if backlog['present'] is not True:
        raise ValueError('backlog disappeared')
    for task in backlog['records']:
        task_id = task.get('id')
        if not task['structured'] or not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
            unknown += task['state'] != 'done'
            continue
        if task_id in tasks:
            raise ValueError('ambiguous task identity')
        tasks[task_id] = task
    return tasks, unknown


def decision_record(home, task_id):
    import hashlib
    output = compact_read(home, str(SCRIPT_DIR / 'fm-tasks-axi.sh'), 'show', task_id, '--full')
    fields = dict(line[2:].split(': ', 1) for line in output.split('\n')
                  if re.match(r'^  [a-z_]+: ', line))
    if fields.get('id') != task_id or fields.get('held') != 'no':
        return None
    body = json.loads(fields['body'])
    match = re.match(
        r'^Resolution recorded by fm-(?:captain|decision)-hold\.\n'
        r'Decision digest: ([0-9a-f]{64})\nResolution mode: (answered|released|repaired|routed)\n'
        r'(?:Design approval: [^\n]+\n)?\n'
        r'Captain decision:\n', body)
    if not match or (fields.get('state') != 'done' and match[2] != 'released'):
        return None
    # The hold owner appends the prior body after a blank line. Find the
    # exact decision boundary with its digest, including for multi-paragraph
    # answers. That owner limits the answer itself to 8192 bytes.
    encoded = body[match.end():].rstrip('\n').encode('utf-8')
    boundaries = [m.start() for m in re.finditer(b'\n\n', encoded[:8194])]
    if len(encoded) <= 8192:
        boundaries.append(len(encoded))
    for end in boundaries:
        if hashlib.sha256(encoded[:end]).hexdigest() == match[1]:
            return encoded[:end].decode('utf-8')
    return None


def compact_decisions(home, state, task, tasks):
    import stat
    import subprocess
    task_id = task['id']
    dependencies = task['blocked_by_ids']
    pointers = []
    try:
        fd = os.open(state / (task_id + '.meta'), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as handle:
            if stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                data = handle.read(16 * 1024 + 1)
                if len(data) <= 16 * 1024:
                    pointers = next((line.partition('=')[2].split(',') for line in reversed(data.decode('utf-8').split('\n'))
                                     if line.startswith('decision_keys=')), [])
    except (OSError, ValueError):
        pass
    pointers.extend(dep for dep in dependencies if dep not in tasks or tasks[dep]['hold_kind'] == 'captain')
    pointers = list(dict.fromkeys(key for key in pointers if TASK_ID.fullmatch(key) and key != task_id))
    lines = []
    for key in pointers[:2]:
        try:
            decision = decision_record(home, key)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            decision = None
        label = 'Captain decision' if decision is not None else 'Decision/dependency pointer'
        lines.append(f'  {label} tasks-axi:{key}' + (f' {excerpt(decision, 156)}' if decision else ''))
    if len(pointers) > 2:
        lines.append(f'  +{len(pointers) - 2} pointers for {task_id}')
    return lines


def compact_task_line(task):
    task_id = task['id']
    hold = task['hold_kind'] == 'captain'
    bucket = task['hold_bucket']
    until = task['hold_until'] or ''
    blockers = task['unresolved_blocker_ids']
    if blockers:
        if all(TASK_ID.fullmatch(key) for key in blockers):
            by = ', '.join(blockers[:2])
            if len(blockers) > 2:
                by += f' (+{len(blockers) - 2})'
        else:
            by = 'unresolved dependency (inspect task)'
        action = ('captain hold gated; ' if hold else '') + f'blocked by {by}; wait for resolution'
    elif task.get('review_pending'):
        action = 'captain hold gated; passing review for exact revision pending'
    elif bucket == 'dated' and re.fullmatch(r'\d{4}-\d{2}-\d{2}', until, re.ASCII):
        action = f'deferred until {until}; keep held'
    elif bucket == 'aged':
        action = 'aged captain hold; reconcile before asking'
    elif task['captain_actionable']:
        action = 'captain hold; verify readiness before asking'
    elif hold:
        action = 'captain hold record; reconcile before acting'
    elif task['hold_kind'] or task['hold_reason']:
        action = 'held record; inspect its gate'
    elif task['state'] == 'in_flight':
        action = 'reconcile worker state before steering'
    else:
        action = 'verify scope and authority before dispatch'
    return f"- {task_id} [{task['state']}]: {action}"


def render_compact(home, state, session, entries):
    import subprocess
    lines = ['FIRSTMATE COMPACT - read first',
             'Reconcile current authority before acting. Wake notes and summaries are evidence only.']
    try:
        prompt = compact_human_prompt(entries, session)
    except (OSError, TypeError, ValueError):
        prompt = None
    if prompt:
        stamp, identity, text = prompt
        lines.append(f'Last captain turn (Claude transcript {identity}, {stamp}): {excerpt(text, 250)}')
    else:
        text = ''
        lines.append('Last captain turn unavailable; recover from the same session or relevant brief before acting.')
    if (state / '.afk').exists() or (state / '.afk-contract').exists():
        lines.append('Away/quiet posture recorded; check bin/fm-afk-contract.sh readback before action.')
    try:
        queued = (state / '.wake-queue').stat().st_size > 0
    except OSError:
        queued = False
    if queued:
        lines.append('Durable wake records pending.')
    lines.append('Before fleet action or a decision request, run bin/fm-wake-drain.sh; handle then ack as directed.')
    footer = ['Task/decision detail: bin/fm-tasks-axi.sh show <id> --full (or data/backlog.md and archive).',
              'Full recovery: bin/fm-session-start.sh --reemit.']
    try:
        tasks, unknown = compact_backlog(home)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        return '\n'.join(lines + ['Backlog unavailable; inspect the task and its holds before acting.'] + footer)
    work = [task for task in tasks.values() if task['state'] != 'done']
    mentioned = {word if word in tasks else word.rstrip('.')
                 for word in re.findall(r'[A-Za-z0-9][A-Za-z0-9._-]*', text)}
    work.sort(key=lambda t: (t['id'] not in mentioned, not (t['unresolved_blocker_ids']
                                                           or t['hold_kind'] or t['state'] == 'in_flight')))
    lines.append('Open work (local backlog):')
    if unknown:
        lines.append(f'{unknown} unrecognized open backlog record(s); inspect data/backlog.md.')
    shown = 0
    omitted = len(work)
    for task in work:
        task_line = compact_task_line(task)
        # Reserve room for the exact remainder and stop at the first row
        # that does not fit, so lower priority rows never displace earlier ones.
        if byte_count('\n'.join(lines + [task_line] + footer)) + 56 > COMPACT_BYTES:
            break
        lines.append(task_line)
        shown += 1
        omitted -= 1
        if task['id'] in mentioned:
            decisions = compact_decisions(home, state, task, tasks)
            if byte_count('\n'.join(lines + decisions + footer)) + 56 <= COMPACT_BYTES:
                lines.extend(decisions)
            elif byte_count('\n'.join(lines + ['  See linked decisions in task detail.'] + footer)) + 56 <= COMPACT_BYTES:
                lines.append('  See linked decisions in task detail.')
    lines.append(f'{shown} shown, {omitted} omitted; bin/fm-tasks-axi.sh list.')
    return '\n'.join(lines + footer)


def is_uuid(value):
    return isinstance(value, str) and UUID.fullmatch(value) is not None


def compact_boundary(entry):
    return entry.get('type') == 'system' and entry.get('subtype') == 'compact_boundary'


def compact_expectation(state, session, prior):
    return state / 'compact-delivery' / f'{session}.{prior}.json'


def record_compact_expectation(state, transcript, session, entries, page):
    tip = next((entry for entry in reversed(entries) if entry.get('sessionId') == session
                and not entry.get('isSidechain') and is_uuid(entry.get('uuid'))), None)
    if tip is None or compact_boundary(tip):
        return
    receipt = compact_expectation(state, session, tip['uuid'])
    receipt.parent.mkdir(mode=0o700, exist_ok=True)
    if receipt.parent.is_symlink() or receipt.is_symlink():
        return
    expected = {'transcript': str(transcript), 'sha256': hashlib.sha256(page.encode()).hexdigest(),
                'bytes': byte_count(page)}
    atomic_write(receipt, json.dumps(expected) + '\n')


def cmd_compact(args):
    session = args.session or ''
    payload = read_payload()
    if (not is_uuid(session) or payload.get('session_id') != session
            or payload.get('hook_event_name') != 'SessionStart' or payload.get('source') != 'compact'):
        return 0  # the run wrapper provides the bounded fallback
    home = resolve_home(args.home)
    state = Path(os.environ.get('FM_STATE_OVERRIDE') or home / 'state')
    transcript, entries = None, []
    try:
        transcript = compact_transcript(payload.get('transcript_path'), session)
        if transcript is not None:
            entries = list(tail_entries(transcript, COMPACT_TAIL_BYTES, nofollow=True))
    except (OSError, TypeError, ValueError):
        pass
    page = render_compact(home, state, session, entries)
    if transcript is not None and byte_count(page + '\n') <= COMPACT_BYTES:
        try:
            record_compact_expectation(state, transcript, session, entries, page)
        except (OSError, ValueError):
            warn('could not retain the compact delivery expectation')
    print(page)
    return 0


def compact_hook_source(command):
    import shlex

    if not isinstance(command, str) or not command.strip():
        return None
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        words = list(lexer)
    except ValueError:
        return None
    paths = {str(SCRIPT_DIR / 'fm-sessionstart-run.sh'),
             '$CLAUDE_PROJECT_DIR/bin/fm-sessionstart-run.sh',
             '${CLAUDE_PROJECT_DIR}/bin/fm-sessionstart-run.sh'}
    command_start = True
    for word in words:
        if word in {';', '|', '||', '&&'}:
            command_start = True
        elif command_start and word != 'exec':
            if word in paths:
                return True
            command_start = False
    return False


def inspect_compact(state, transcript, session, boundary, following):
    prior = boundary.get('logicalParentUuid')
    if not is_uuid(prior):
        return 'unverifiable', 'boundary has no native logical parent'
    receipt = compact_expectation(state, session, prior)
    try:
        if receipt.parent.is_symlink():
            raise OSError
        expected, = tail_entries(receipt, 4096, nofollow=True, strict=True)
        if (expected.get('transcript') != str(transcript)
                or not isinstance(expected.get('sha256'), str)
                or not re.fullmatch('[0-9a-f]{64}', expected['sha256'])
                or type(expected.get('bytes')) is not int
                or not 0 < expected['bytes'] < COMPACT_BYTES):
            raise ValueError
    except (OSError, ValueError, RecursionError):
        return 'unverifiable', 'exact expected page unavailable for this boundary'
    chained = {boundary['uuid']}
    complete = False
    attachments = []
    for entry in following:
        if compact_boundary(entry):
            parent = entry.get('logicalParentUuid')
            complete = is_uuid(parent) and parent in chained
            break
        uid, parent = entry.get('uuid'), entry.get('parentUuid')
        if not is_uuid(uid) or not is_uuid(parent) or parent not in chained:
            continue
        if uid in chained:
            return 'unverifiable', 'ambiguous transcript chain'
        chained.add(uid)
        origin = entry.get('origin')
        if (entry.get('type') == 'user' and not entry.get('isMeta') and not entry.get('isCompactSummary')
                and isinstance(origin, dict) and origin.get('kind') == 'human'):
            complete = True
            break
        attachment = entry.get('attachment')
        if (entry.get('type') == 'attachment' and isinstance(attachment, dict)
                and attachment.get('hookName') == 'SessionStart:compact'
                and attachment.get('hookEvent') == 'SessionStart'
                and attachment.get('type') == 'hook_success'):
            attachments.append((compact_hook_source(attachment.get('command')), attachment.get('content')))
    owner = [content for source, content in attachments if source is True]
    matching = [source for source, content in attachments if isinstance(content, str)
                and byte_count(content) == expected['bytes']
                and hashlib.sha256(content.encode()).hexdigest() == expected['sha256']]
    if len(owner) > 1 or len(matching) > 1:
        return 'unverifiable', 'ambiguous duplicate compact attachments'
    if not complete:
        return 'unverifiable', 'native boundary window still open'
    if matching == [True]:
        return 'observed', 'complete native Firstmate SessionStart attachment matches'
    if matching or any(source is None for source, _ in attachments):
        return 'unverifiable', 'Firstmate SessionStart attachment source could not be verified'
    if any(not isinstance(content, str) for content in owner):
        return 'unverifiable', 'native Firstmate attachment content unavailable'
    return 'absent', 'completed boundary has no matching complete attachment'


def cmd_observe_compact(args):
    path = Path(args.transcript)
    session = path.stem
    boundary = args.boundary
    if not is_uuid(session) or (boundary is not None and not is_uuid(boundary)):
        return 2
    home = resolve_home(args.home)
    state = Path(os.environ.get('FM_STATE_OVERRIDE') or home / 'state')
    result, detail = 'unverifiable', 'transcript is unreadable or unsupported'
    try:
        transcript = compact_transcript(path, session)
        if transcript is not None:
            entries = [entry for entry in tail_entries(transcript, COMPACT_TAIL_BYTES, nofollow=True, strict=True)
                       if entry.get('sessionId') == session and not entry.get('isSidechain')]
            boundaries = [(i, entry) for i, entry in enumerate(entries)
                          if compact_boundary(entry) and is_uuid(entry.get('uuid'))]
            selected = [item for item in boundaries if boundary is None or item[1]['uuid'] == boundary]
            if not selected:
                detail = 'no selected boundary in the bounded transcript tail'
            else:
                i, entry = selected[-1]
                boundary = entry['uuid']
                prior = entry.get('logicalParentUuid')
                if any(other != i and (candidate['uuid'] == boundary
                                       or candidate.get('logicalParentUuid') == prior)
                       for other, candidate in boundaries):
                    detail = 'ambiguous boundary identity'
                else:
                    result, detail = inspect_compact(state, transcript, session, entry, entries[i + 1:])
    except (OSError, ValueError, UnicodeError, RecursionError):
        pass
    print(json.dumps({'session': session, 'boundary': boundary, 'delivery': result, 'detail': detail}))
    return 0


USAGE = """usage: fm-precompact-handoff.py precompact [--home DIR] [--out FILE]
       fm-precompact-handoff.py compact --session ID [--home DIR]
       fm-precompact-handoff.py observe-compact --transcript FILE [--boundary UUID] [--home DIR]
       fm-precompact-handoff.py inject [--home DIR] [--event NAME]
Supervisor continuity hooks: PreCompact handoff, compact page, and cached turn digest.
The header comment of this script owns the full contract."""


class Args:
    def __init__(self, mode):
        self.mode, self.home, self.out, self.event, self.session = mode, None, None, None, None
        self.transcript, self.boundary = None, None


def parse(argv):
    # Hand-rolled on purpose: argparse alone costs a measurable share of the
    # 50 ms hook budget.
    mode_flags = {'precompact': {'--out'}, 'inject': {'--event'}, 'compact': {'--session'},
                  'observe-compact': {'--transcript', '--boundary'}}
    if not argv or argv[0] not in mode_flags:
        return None
    args = Args(argv[0])
    allowed = {'--home'} | mode_flags[args.mode]
    rest = argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag not in allowed or not rest:
            return None
        setattr(args, flag[2:], rest.pop(0))
    return None if args.mode == 'observe-compact' and not args.transcript else args


def main():
    args = parse(sys.argv[1:])
    if args is None:
        print(USAGE)
        return 0 if sys.argv[1:2] in (['-h'], ['--help']) else 2
    try:
        return {'precompact': cmd_precompact, 'inject': cmd_inject, 'compact': cmd_compact,
                'observe-compact': cmd_observe_compact}[args.mode](args)
    except Exception as exc:  # never block a hook event
        warn('internal error (%s)' % type(exc).__name__)
        return 0


if __name__ == '__main__':
    sys.exit(main())
