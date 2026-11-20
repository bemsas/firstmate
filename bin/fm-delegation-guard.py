#!/usr/bin/env -S python3 -I -S
# fm-delegation-guard.py - policy owner for the supervisor delegation guard and
# its bounded, expiring captain-operation grants.
#
#   fm-delegation-guard.py check --home DIR          (PreToolUse JSON on stdin)
#   fm-delegation-guard.py grant --path PATH --ops OPS --reason TEXT [--minutes N] [--home DIR]
#   fm-delegation-guard.py revoke ID [--home DIR]
#   fm-delegation-guard.py list [--home DIR]
#
# bin/fm-delegation-pretool-check.sh is the hook entrypoint: it confirms a
# genuine primary home first and only then runs `check`, so a crewmate or scout
# task worktree never reaches this policy. Python standard library only.
#
# check classifies one Claude PreToolUse payload (tool_name, tool_input, cwd)
# and prints nothing to allow, or one Claude deny object
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#    "permissionDecisionReason":"[delegate-guard] ..."}}
# on stdout; it always exits 0. Malformed payloads (including a non-string
# tool_name) and unparseable shell allow.
#
# A target path (realpath, nearest existing ancestor) is classed as:
#   private  under <home>/data, <home>/state, or <home>/config, under a standing
#            entry of <home>/config/delegation-guard-allow, or outside every git
#            work tree - always allowed (operational state, memory, scratch);
#   project  under <home>/projects - denied (AGENTS.md hard rule 1);
#   tracked  elsewhere under <home> - denied only while any <home>/state/*.meta
#            task record exists, because AGENTS.md routes shared tracked changes
#            through a worker whenever one is live;
#   repo     inside another git work tree (a product repository or a task
#            worktree; a work tree rooted at $HOME or / is ignored) - denied.
# Guarded operations:
#   edit  Edit, Write, MultiEdit, and NotebookEdit targets (file_path,
#         notebook_path, path), plus shell file mutators (sed -i, tee, cp, mv,
#         rm, touch, mkdir, ln, install, rsync, truncate, patch, chmod) and
#         output redirections, judged by their path arguments;
#   git   mutating git subcommands, judged by -C/--work-tree or the shell cwd;
#   test  test and build runners (npm/pnpm/yarn/bun test|build|run, npx,
#         pytest, playwright, vitest, jest, cargo, go test|build, make,
#         gradle, mvn, tox), judged by the shell cwd or their directory flag.
# Option values are read in their -x V, -xV, --long V and --long=V forms (for
# example npm --prefix, cp/mv --target-directory, bundled sed -ni, patch's
# original-file argument), mv judges its sources as well as its target, and
# removing or moving a directory that contains the home or its projects/ is
# denied. Running a program file whose path lies in a guarded place is a test
# operation. The shell cwd starts at the payload cwd and follows literal
# cd, cd -, pushd, and popd words, scoped by subshell parentheses.
# A command whose first word is a path to an existing fm-*.sh or fm-*.py in this
# guard's own bin/ directory is allowed: those owners carry their own guarded
# project paths; a same-named script elsewhere gets no exemption. Nested shells
# (bash -c, eval, python -c), variable or command expansion, and aliases are not
# evaluated; the guard is a mistake seatbelt for an orchestrating supervisor,
# not a sandbox.
#
# config/delegation-guard-allow is the operator's standing list of private
# record paths that happen to sit in a guarded place, such as an asks log kept
# as a clone under projects/: one path per line, relative to the home or
# absolute; blank lines and # comments are skipped. An entry that is /, $HOME,
# the home, <home>/projects, or an ancestor of any of them is ignored, and an
# unreadable or undecodable list allows nothing extra.
# There is no environment bypass. A concrete captain-approved operation is
# recorded as a grant in <home>/state/delegation-grants.json (flock on
# <home>/state/.delegation-grants.lock, atomic replace): an absolute existing
# PATH that is not /, $HOME, the home itself, <home>/projects, or an ancestor of
# any of them, so a grant reaches at most one project clone; an operation subset
# of edit,git,test; the captain's words as --reason; and a lifetime of --minutes
# (default 30, at most 240). The same validator runs when a grant is written and
# every time the file is read: a file without schema fm-delegation-grants.v1 is
# ignored, and a record with a bad id, a non-canonical or too-broad path, unknown
# ops, no reason, or a lifetime outside 1..240 minutes is skipped with a
# one-line stderr diagnostic. A grant allows exactly the named operations on
# targets inside PATH until it expires. `list` prints the
# live grants; `revoke` removes one early. FM_DELEGATION_NOW_EPOCH pins the
# clock for tests.
import json
import os
import re
import sys
import time
from pathlib import Path

WRITE_TOOLS = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'}
PATH_KEYS = ('file_path', 'notebook_path', 'path')
OPS = ('edit', 'git', 'test')
GIT_MUTATING = {'add', 'am', 'apply', 'checkout', 'cherry-pick', 'clean', 'commit', 'merge', 'mv',
                'pull', 'push', 'rebase', 'reset', 'restore', 'revert', 'rm', 'stash', 'switch',
                'update-ref', 'worktree', 'submodule', 'filter-branch', 'notes', 'init'}
GIT_BRANCHY = {'branch', 'tag'}
GIT_VALUE_OPTS = {'-c', '--git-dir', '--namespace', '--exec-path', '--config-env'}
FILE_MUTATORS = {'tee', 'cp', 'mv', 'rm', 'touch', 'mkdir', 'ln', 'install', 'rsync', 'truncate',
                 'patch', 'chmod', 'rmdir', 'dd'}
PKG_RUNNERS = {'npm', 'pnpm', 'yarn', 'bun'}
PKG_HEAVY = {'test', 't', 'build', 'run', 'run-script', 'exec', 'e2e', 'ci', 'install', 'i', 'add'}
DIRECT_RUNNERS = {'pytest', 'playwright', 'vitest', 'jest', 'make', 'gradle', 'gradlew', 'mvn', 'tox',
                  'npx', 'pnpx', 'bunx'}
LANG_RUNNERS = {'cargo': {'test', 'build', 'run', 'bench'}, 'go': {'test', 'build', 'run', 'generate'}}
DIR_FLAGS = {'--prefix', '--dir', '-C', '--cwd', '--manifest-path', '--rootdir', '--project'}
MAX_MINUTES = 240
GRANTS_SCHEMA = 'fm-delegation-grants.v1'
GRANT_ID_RE = re.compile(r'^g[0-9]{1,12}-[0-9a-f]{6}$')
FM_SCRIPT_RE = re.compile(r'^fm-[A-Za-z0-9._-]+\.(sh|py)$')


def now_epoch():
    raw = os.environ.get('FM_DELEGATION_NOW_EPOCH', '')
    return int(raw) if raw.isdigit() else int(time.time())


def real(path):
    """realpath of the nearest existing ancestor joined with the missing tail."""
    path = os.path.abspath(path)
    tail = []
    probe = path
    while not os.path.lexists(probe) and probe != os.path.dirname(probe):
        tail.append(os.path.basename(probe))
        probe = os.path.dirname(probe)
    base = os.path.realpath(probe)
    for part in reversed(tail):
        base = os.path.join(base, part)
    return base


def inside(path, root):
    return path == root or path.startswith(root.rstrip('/') + '/')


class Policy:
    def __init__(self, home, now):
        self.home = real(str(home))
        self.root = real(str(Path(__file__).resolve().parent.parent))
        self.now = now
        self.user_home = real(os.path.expanduser('~'))
        self.fleet_live = None
        self.grants = None
        self.allow = self.standing_allow()

    def standing_allow(self):
        try:
            with open(os.path.join(self.home, 'config', 'delegation-guard-allow'), 'rb') as handle:
                lines = handle.read(64 * 1024).decode('utf-8').splitlines()
        except (OSError, ValueError):
            return []  # a missing or malformed optional list allows nothing extra
        broad = ('/', self.user_home, self.home, os.path.join(self.home, 'projects'))
        out = []
        for line in lines:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            entry = real(line if os.path.isabs(line) else os.path.join(self.home, line))
            if not any(inside(b, entry) for b in broad):
                out.append(entry)
        return out

    def live(self):
        if self.fleet_live is None:
            try:
                self.fleet_live = any(n.endswith('.meta') for n in os.listdir(os.path.join(self.home, 'state')))
            except OSError:
                self.fleet_live = False
        return self.fleet_live

    def repo_root(self, path):
        probe = path if os.path.isdir(path) else os.path.dirname(path)
        while True:
            if os.path.lexists(os.path.join(probe, '.git')):
                return None if probe in ('/', self.user_home) else probe
            parent = os.path.dirname(probe)
            if parent == probe:
                return None
            probe = parent

    def classify(self, raw_path, cwd):
        if not isinstance(raw_path, str) or not raw_path:
            return None, None
        path = os.path.expanduser(raw_path)
        if not os.path.isabs(path):
            path = os.path.join(cwd, path)
        path = real(path)
        home = self.home
        for private in ('data', 'state', 'config'):
            if inside(path, os.path.join(home, private)):
                return 'private', path
        if any(inside(path, entry) for entry in self.allow):
            return 'private', path
        if inside(path, os.path.join(home, 'projects')):
            return 'project', path
        if inside(path, home) or inside(path, self.root):
            return ('tracked' if self.live() else 'private'), path
        return ('repo' if self.repo_root(path) else 'private'), path

    def trusted_script(self, word, cwd):
        """True only for an existing fm-* script in this guard's own bin directory."""
        if '/' not in word or not FM_SCRIPT_RE.match(os.path.basename(word)):
            return False
        path = os.path.realpath(os.path.join(cwd, os.path.expanduser(word)))
        return os.path.dirname(path) == os.path.join(self.root, 'bin') and os.path.isfile(path)

    def destructive(self, raw_path, cwd):
        """Removing or moving a directory that holds the home or its project clones."""
        if not isinstance(raw_path, str) or not raw_path:
            return None
        path = os.path.expanduser(raw_path)
        path = real(path if os.path.isabs(path) else os.path.join(cwd, path))
        for protected in (os.path.join(self.home, 'projects'), self.home, self.root):
            if inside(protected, path) and os.path.isdir(path):
                return 'edit on %s (a directory containing %s)' % (path, protected)
        return None

    def granted(self, op, path):
        if self.grants is None:
            self.grants = live_grants(load_grants(Path(self.home)), self.now)
        return any(op in g['ops'] and inside(path, g['path']) for g in self.grants)

    def verdict(self, op, raw_path, cwd):
        cls, path = self.classify(raw_path, cwd)
        if cls in (None, 'private') or self.granted(op, path):
            return None
        return '%s on %s (%s)' % (op, path, {'project': 'a project clone under projects/',
                                             'tracked': 'shared tracked firstmate material while a worker is live',
                                             'repo': 'another git work tree'}[cls])


# ------------------------------------------------------------ shell parse


def tokens_of(command):
    import shlex
    # A newline ends a command; shlex would otherwise read it as plain space.
    lexer = shlex.shlex(command.replace('\n', ' ; '), posix=True, punctuation_chars=';&|()<>')
    lexer.whitespace_split = True
    lexer.commenters = ''
    return list(lexer)


def positionals(args, value_opts=()):
    out, skip, ended = [], False, False
    for a in args:
        if ended:
            out.append(a)
        elif skip:
            skip = False
        elif a == '--':
            ended = True
        elif a in value_opts:
            skip = True
        elif not a.startswith('-') or a == '-':
            out.append(a)
    return out


def option_values(args, short, long):
    """Values of one option in its -x V, -xV, --long V and --long=V forms."""
    out = []
    for n, a in enumerate(args):
        if a in (short, long):
            if n + 1 < len(args):
                out.append(args[n + 1])
        elif a.startswith(long + '='):
            out.append(a.split('=', 1)[1])
        elif short and a.startswith(short) and not a.startswith('--') and len(a) > len(short):
            out.append(a[len(short):])
    return out


def sed_targets(args):
    """Files GNU/BSD sed edits in place: none unless -i/--in-place is given,
    including inside a bundled short cluster such as -ni."""
    inplace, scripted, pos, i = False, False, [], 0
    while i < len(args):
        a = args[i]
        if a == '--':
            pos.extend(args[i + 1:])
            break
        if a.startswith('--'):
            name = a.split('=', 1)[0]
            if name == '--in-place':
                inplace = True
            elif name in ('--expression', '--file', '--line-length'):
                scripted = scripted or name != '--line-length'
                i += 0 if '=' in a else 1
        elif a.startswith('-') and len(a) > 1:
            for j, c in enumerate(a[1:], 1):
                if c == 'i':
                    inplace = True
                    break  # the rest of the cluster is a backup suffix
                if c in 'efl':
                    scripted = scripted or c != 'l'
                    i += 1 if j == len(a) - 1 else 0
                    break
        else:
            pos.append(a)
        i += 1
    if not inplace:
        return []
    return pos if scripted else pos[1:]


def mutated_paths(cmd, args):
    """The path arguments a file-mutating command writes, never its sources."""
    if cmd == 'sed':
        return sed_targets(args)
    if cmd in ('cp', 'install', 'ln', 'rsync', 'mv'):
        pos = positionals(args, ('-t', '-m', '-o', '-g', '-S', '--target-directory', '-e', '--suffix'))
        target = option_values(args, '-t', '--target-directory')
        if cmd == 'mv':
            return pos + target  # mv also removes its sources
        return target or pos[-1:]
    if cmd in ('chmod', 'chown'):
        return positionals(args)[1:]
    if cmd == 'truncate':
        return positionals(args, ('-s', '--size', '-r', '--reference'))
    if cmd == 'dd':
        return [a[3:] for a in args if a.startswith('of=')]
    if cmd == 'patch':
        where = option_values(args, '-d', '--directory') or ['.']
        named = positionals(args, ('-p', '-i', '--input', '-o', '--output', '-d', '--directory', '-D',
                                   '--ifdef', '-F', '--fuzz', '-V', '-z', '--suffix', '-B', '-Y',
                                   '-r', '--reject-file', '-g', '--get'))
        return where + named[:1] + option_values(args, '-o', '--output')
    return positionals(args)


def shell_problems(policy, command, cwd):
    try:
        tokens = tokens_of(command)
    except ValueError:
        return []  # unparseable shell allows: transport, not policy
    problems, saved, words, i = [], [], [], 0
    shell = {'cwd': cwd, 'dirs': [], 'old': cwd}

    def flush(words):
        run_segment(policy, words, shell, problems)
    while i < len(tokens):
        tok = tokens[i]
        if tok and all(c in ';&|()\n' for c in tok):
            flush(words)
            words = []
            for c in tok:
                if c == '(':
                    saved.append(dict(shell, dirs=list(shell['dirs'])))
                elif c == ')' and saved:
                    shell = saved.pop()
            i += 1
            continue
        if tok and all(c in '<>&|0123456789' for c in tok) and ('<' in tok or '>' in tok):
            if words and words[-1].isdigit():
                words.pop()
            target = tokens[i + 1] if i + 1 < len(tokens) else ''
            # '>&' duplicates a descriptor; every other '>' form writes a file.
            if '>' in tok and '&' not in tok.replace('&>', '') and target and target != '/dev/null':
                problems.append(policy.verdict('edit', target, shell['cwd']))
            i += 2
            continue
        words.append(tok)
        i += 1
    flush(words)
    return [p for p in problems if p]


def run_segment(policy, words, shell, problems):
    """Judge one simple command and apply its literal cd/pushd/popd to shell."""
    cwd = shell['cwd']
    words = list(words)
    while words and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0]):
        words.pop(0)
    while words and words[0] in ('sudo', 'env', 'command', 'nice', 'time', 'timeout', 'exec', 'xargs'):
        words.pop(0)
        while words and (words[0].startswith('-') or re.match(r'^\d+[smh]?$', words[0])
                         or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0])):
            words.pop(0)
    if not words or policy.trusted_script(words[0], cwd):
        return
    cmd, args = os.path.basename(words[0]), words[1:]
    if cmd in ('cd', 'pushd', 'popd'):
        target = next((a for a in args if not a.startswith('-') or a == '-'), None)
        if cmd == 'popd':
            if shell['dirs']:
                shell['old'], shell['cwd'] = cwd, shell['dirs'].pop()
            return
        if cmd == 'pushd' and target is None:
            if shell['dirs']:
                shell['dirs'][-1], shell['cwd'] = cwd, shell['dirs'][-1]
            return
        if target == '-':
            new = shell['old']
        else:
            new = real(os.path.join(cwd, os.path.expanduser(target or '~')))
        if cmd == 'pushd':
            shell['dirs'].append(cwd)
        shell['old'], shell['cwd'] = cwd, new
        return
    if '/' in words[0]:
        # Executing a program file that lives in a guarded place runs project code.
        problems.append(policy.verdict('test', words[0], cwd))
    if cmd == 'git':
        problems.append(git_problem(policy, args, cwd))
    elif cmd == 'sed' or cmd in FILE_MUTATORS:
        targets = mutated_paths(cmd, args)
        problems.extend(policy.verdict('edit', a, cwd) for a in targets)
        if cmd in ('rm', 'rmdir', 'mv'):
            problems.extend(policy.destructive(a, cwd) for a in targets)
    else:
        where = runner_dir(cmd, args, cwd)
        if where:
            problems.append(policy.verdict('test', where, cwd))


def git_problem(policy, args, cwd):
    where = cwd
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-C' and i + 1 < len(args):
            where = os.path.join(where, os.path.expanduser(args[i + 1]))
            i += 2
        elif a.startswith('--work-tree='):
            where = os.path.join(where, os.path.expanduser(a.split('=', 1)[1]))
            i += 1
        elif a == '--work-tree' and i + 1 < len(args):
            where = os.path.join(where, os.path.expanduser(args[i + 1]))
            i += 2
        elif a in GIT_VALUE_OPTS:
            i += 2
        elif a.startswith('-'):
            i += 1
        else:
            break
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    mutating = sub in GIT_MUTATING
    if sub in GIT_BRANCHY:
        changing = {'-d', '-D', '-m', '-M', '-c', '-C', '-f', '--delete', '--move', '--copy', '--force',
                    '-u', '--set-upstream-to', '--unset-upstream', '-a', '-s', '--annotate', '--sign'}
        listing = {'-l', '--list'}
        if sub == 'branch':
            changing = changing - {'-a'}
        mutating = bool(changing & set(rest)) or (
            not (listing & set(rest)) and any(not a.startswith('-') for a in rest))
    if (sub, rest[:1]) in (('stash', ['list']), ('stash', ['show']), ('worktree', ['list']),
                           ('submodule', ['status']), ('submodule', ['summary'])):
        mutating = False
    if not mutating:
        return None
    return policy.verdict('git', os.path.join(where, '.'), cwd)


def first_word(args):
    """The subcommand: the first argument that is neither an option nor a value."""
    skip = False
    for a in args:
        if skip:
            skip = False
        elif a in DIR_FLAGS:
            skip = True
        elif not a.startswith('-'):
            return a
    return ''


def runner_dir(cmd, args, cwd):
    heavy = False
    if cmd in PKG_RUNNERS:
        first = first_word(args)
        heavy = first in PKG_HEAVY or (cmd == 'yarn' and first not in ('', 'info', 'why', 'list', 'config'))
    elif cmd in DIRECT_RUNNERS:
        heavy = True
    elif cmd in LANG_RUNNERS:
        first = first_word(args)
        heavy = first in LANG_RUNNERS[cmd]
    elif cmd in ('python', 'python3') and args[:2] == ['-m', 'pytest']:
        heavy = True
    if not heavy:
        return None
    for n, a in enumerate(args):
        if a in DIR_FLAGS and n + 1 < len(args):
            return os.path.join(cwd, os.path.expanduser(args[n + 1]))
        for f in DIR_FLAGS:
            if a.startswith(f + '='):
                return os.path.join(cwd, os.path.expanduser(a.split('=', 1)[1]))
    return os.path.join(cwd, '.')


# ----------------------------------------------------------------- check


def deny(reason):
    route = ('Route hands-on work to a worker (bin/fm-brief.sh then bin/fm-spawn.sh) or to the owning '
             'second mate (bin/fm-send.sh). For a concrete operation the captain approved in the moment, '
             'record it first: bin/fm-delegation-guard.py grant --path <dir> --ops <edit,git,test> '
             '--reason "<captain words>".')
    text = '[delegate-guard] This supervisor home orchestrates; it does not do hands-on project work. ' \
           'Blocked: %s. %s' % (reason, route)
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                             'permissionDecisionReason': text}}))


def cmd_check(home):
    try:
        payload = json.loads(sys.stdin.read() or 'null')
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict):
        return 0
    tool = payload.get('tool_name')
    if not isinstance(tool, str):
        return 0  # malformed payload: not a tool this guard judges
    tool_input = payload.get('tool_input') if isinstance(payload.get('tool_input'), dict) else {}
    cwd = payload.get('cwd') if isinstance(payload.get('cwd'), str) and os.path.isabs(payload.get('cwd', '')) else str(home)
    policy = Policy(home, now_epoch())
    problems = []
    if tool in WRITE_TOOLS:
        problems = [policy.verdict('edit', tool_input.get(k), cwd) for k in PATH_KEYS if tool_input.get(k)]
    elif tool == 'Bash' and isinstance(tool_input.get('command'), str):
        problems = shell_problems(policy, tool_input['command'], real(cwd))
    problems = [p for p in problems if p]
    if problems:
        deny('; '.join(dict.fromkeys(problems)))
    return 0


# ---------------------------------------------------------------- grants


def grants_path(home):
    return Path(home) / 'state' / 'delegation-grants.json'


def scope_problem(target, home):
    """Why a grant path is too broad: it holds /, $HOME, the home, or every project."""
    home_real = os.path.realpath(str(home))
    for broad in ('/', os.path.realpath(os.path.expanduser('~')), home_real,
                  os.path.join(home_real, 'projects')):
        if inside(broad, target):
            return '--path %s is too broad: it contains %s' % (target, broad)
    return None


def grant_problem(g, home, now):
    """The single grant validator, applied when a grant is written and read."""
    if not isinstance(g, dict):
        return 'grant is not an object'
    if not isinstance(g.get('id'), str) or not GRANT_ID_RE.match(g['id']):
        return 'grant id is invalid'
    path = g.get('path')
    if not isinstance(path, str) or not os.path.isabs(path) or os.path.realpath(path) != path \
            or not os.path.exists(path):
        return 'grant path must be an existing canonical absolute path'
    problem = scope_problem(path, home)
    if problem:
        return problem
    ops = g.get('ops')
    if not isinstance(ops, list) or not ops or len(set(ops)) != len(ops) or any(o not in OPS for o in ops):
        return 'grant ops must be a list from %s' % ','.join(OPS)
    if not isinstance(g.get('reason'), str) or not g['reason'].strip() or len(g['reason']) > 400:
        return 'grant needs the captain words as its reason'
    start, end = g.get('granted_epoch'), g.get('expires_epoch')
    if not isinstance(start, int) or not isinstance(end, int) or isinstance(start, bool) \
            or isinstance(end, bool) or start > now + 300 or not 0 < end - start <= MAX_MINUTES * 60:
        return 'grant lifetime is outside 1..%d minutes from its start' % MAX_MINUTES
    return None


def load_grants(home):
    try:
        with open(grants_path(home), 'rb') as handle:
            data = json.loads(handle.read(1024 * 1024).decode('utf-8'))
    except (OSError, ValueError, RecursionError):
        return []
    if not isinstance(data, dict) or data.get('schema') != GRANTS_SCHEMA or not isinstance(data.get('grants'), list):
        print('fm-delegation-guard: ignored a grants file without schema %s' % GRANTS_SCHEMA, file=sys.stderr)
        return []
    now = now_epoch()
    out = [g for g in data['grants'] if grant_problem(g, home, now) is None]
    if len(out) != len(data['grants']):
        print('fm-delegation-guard: ignored %d invalid grant record(s)' % (len(data['grants']) - len(out)),
              file=sys.stderr)
    return out


def live_grants(grants, now):
    return [g for g in grants if g['expires_epoch'] > now]


def save_grants(home, mutate):
    import fcntl
    import tempfile
    state = Path(home) / 'state'
    with open(state / '.delegation-grants.lock', 'a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        grants = mutate(live_grants(load_grants(home), now_epoch()))
        fd, tmp = tempfile.mkstemp(prefix='.delegation-grants.', dir=str(state))
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump({'schema': GRANTS_SCHEMA, 'grants': grants}, handle, indent=2, sort_keys=True)
            handle.write('\n')
        os.replace(tmp, grants_path(home))


def cmd_grant(home, opts):
    path, ops, reason = opts.get('--path'), opts.get('--ops'), opts.get('--reason')
    minutes = opts.get('--minutes', '30')
    if not path or not ops or not reason or not reason.strip():
        raise ValueError('grant needs --path, --ops, and --reason')
    if not os.path.isabs(path) or not os.path.exists(path):
        raise ValueError('--path must be an existing absolute path')
    target = os.path.realpath(path)
    problem = scope_problem(target, home)
    if problem:
        raise ValueError(problem)
    op_list = sorted(set(o.strip() for o in ops.split(',') if o.strip()))
    if not op_list or any(o not in OPS for o in op_list):
        raise ValueError('--ops must be a comma list from %s' % ','.join(OPS))
    if not minutes.isdigit() or not 1 <= int(minutes) <= MAX_MINUTES:
        raise ValueError('--minutes must be 1..%d' % MAX_MINUTES)
    now = now_epoch()
    grant = {'id': 'g%d-%s' % (now, os.urandom(3).hex()), 'path': target, 'ops': op_list,
             'reason': ' '.join(reason.split())[:400], 'granted_epoch': now,
             'expires_epoch': now + int(minutes) * 60}
    problem = grant_problem(grant, home, now)
    if problem:
        raise ValueError(problem)
    save_grants(home, lambda grants: grants + [grant])
    return 'granted: %s %s on %s for %s minute(s)' % (grant['id'], ','.join(op_list), target, minutes)


def parse_opts(argv, allowed):
    opts, rest = {}, []
    while argv:
        a = argv.pop(0)
        if a in allowed:
            if not argv:
                raise ValueError('%s needs a value' % a)
            opts[a] = argv.pop(0)
        else:
            rest.append(a)
    return opts, rest


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        with open(__file__, encoding='utf-8') as handle:
            next(handle)
            print('\n'.join(line[2:].rstrip('\n') for line in handle if line.startswith('#'))
                  .split('\n\n')[0])
        return 0 if argv else 2
    command = argv[0]
    try:
        opts, rest = parse_opts(list(argv[1:]), {'--home', '--path', '--ops', '--reason', '--minutes'})
        home = Path(opts.get('--home') or os.environ.get('FM_HOME') or Path(__file__).resolve().parent.parent)
        if command == 'check':
            return cmd_check(home)
        if command == 'grant' and not rest:
            print(cmd_grant(home, opts))
        elif command == 'revoke' and len(rest) == 1:
            gid = rest[0]
            found = []
            save_grants(home, lambda grants: [g for g in grants if g['id'] != gid or found.append(g)])
            if not found:
                raise ValueError('no live grant %s' % gid)
            print('revoked: %s' % gid)
        elif command == 'list' and not rest:
            for g in live_grants(load_grants(home), now_epoch()):
                left = max(0, (g['expires_epoch'] - now_epoch()) // 60)
                print('%s\t%s\t%s\t%dm left\t%s' % (g['id'], ','.join(g['ops']), g['path'], left, g.get('reason', '')))
        else:
            raise ValueError('unknown command or arguments')
    except (ValueError, OSError) as exc:
        print('fm-delegation-guard: error: %s' % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
