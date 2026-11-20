#!/usr/bin/env -S python3 -I -S
# fm-precompact-handoff.py - supervisor continuity hooks for a Claude primary:
# a PreCompact handoff into the home's session-progress file, and a cached,
# timestamp-free turn digest for UserPromptSubmit and SessionStart.
#
#   fm-precompact-handoff.py precompact [--home DIR] [--out FILE]
#   fm-precompact-handoff.py inject [--home DIR] [--event NAME]
#   fm-precompact-handoff.py --help
#
# The shebang runs Python isolated and without site packages (-I -S): a
# site-packages .pth import alone can exceed the 50 ms hook budget, and the
# script needs only the standard library. Register it by its absolute path.
#
# Both modes read the native Claude hook payload as JSON on stdin, always exit
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
        return '\n'.join(x.get('text', '') for x in content
                         if isinstance(x, dict) and x.get('type') == 'text')
    return ''


def tail_entries(path, max_bytes):
    import stat  # deferred: only the precompact path reads a transcript
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NONBLOCK', 0))
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
        except ValueError:
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


USAGE = """usage: fm-precompact-handoff.py precompact [--home DIR] [--out FILE]
       fm-precompact-handoff.py inject [--home DIR] [--event NAME]
Supervisor continuity hooks: PreCompact handoff and cached turn digest.
The header comment of this script owns the full contract."""


class Args:
    def __init__(self, mode):
        self.mode, self.home, self.out, self.event = mode, None, None, None


def parse(argv):
    # Hand-rolled on purpose: argparse alone costs a measurable share of the
    # 50 ms hook budget.
    if not argv or argv[0] in ('-h', '--help') or argv[0] not in ('precompact', 'inject'):
        return None
    args = Args(argv[0])
    allowed = {'--home'} | ({'--out'} if args.mode == 'precompact' else {'--event'})
    rest = argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag not in allowed or not rest:
            return None
        setattr(args, flag[2:], rest.pop(0))
    return args


def main():
    args = parse(sys.argv[1:])
    if args is None:
        print(USAGE)
        return 0 if sys.argv[1:2] in (['-h'], ['--help']) else 2
    try:
        return cmd_precompact(args) if args.mode == 'precompact' else cmd_inject(args)
    except Exception as exc:  # never block a hook event
        warn('internal error (%s)' % type(exc).__name__)
        return 0


if __name__ == '__main__':
    sys.exit(main())
