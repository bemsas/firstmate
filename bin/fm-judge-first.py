#!/usr/bin/env python3
# fm-judge-first.py - the decision engine behind bin/fm-judge-first.sh.
#
#   fm-judge-first.py ingest <secondmate-id> <status-lines-file|->
#   fm-judge-first.py summary [--since <epoch>]
#
# Judge-first runs every new needs-decision: / blocked: line a secondmate
# mirrors into this home's status stream through the private judge
# (data/fleet-bridge/judge.py) before the supervisor spends a turn on it.
#
# Modes come from config/judge-first (absent = the hook does nothing):
#   shadow (default, also empty or any unknown value) - compute everything, send
#          nothing, log the verdict it WOULD send;
#   on     - answer an auto verdict through bin/fm-send.sh with --resolve-key.
# The environment never selects live mode; only the config file does.
#
# Order of decisions for each line (every step may only ESCALATE, never answer):
#   1. parse the line and synthesize a card (a recommendation, or none);
#   2. no recommendation -> escalate, no guessing;
#   3. the guard rules below (the gaps the backtest found) -> escalate;
#   4. judge.py --opinion-only (its own hard rules plus the second opinion);
#      in `on` mode a missing or disagreeing second opinion escalates;
#   5. a cluster of lines that are one decision (same secondmate, same key
#      family, within DEDUPE_SECONDS) is judged together, auto only when every
#      member is auto, and gets exactly one answer.
# Any error (unparseable line, judge failure or timeout, budget spent, log
# unwritable, send refused) leaves today's ordinary wake: this script never
# exits nonzero from `ingest`, and never retries a send (the printed
# FM_PENDING_REPLY_EXISTING_CORR line is recorded for the supervisor instead).
#
# Every verdict is appended to judge-log.jsonl beside judge.py, in the existing
# {card, verdict, at} shape plus hook fields; this script is the only writer
# for hook-judged cards because judge.py runs --opinion-only (no journal write,
# no Langfuse write). After fsync, --record-langfuse exports the final hook
# verdict, including local escalations, without another evaluation or journal row.
# Telemetry failures never prevent the ordinary decision/send path.
#
# Environment (tests and relocated homes): FM_HOME, FM_JUDGE_PY, FM_JUDGE_LOG,
# FM_JUDGE_FIRST_BUDGET (total judge seconds per ingest, default 40),
# FM_JUDGE_FIRST_TIMEOUT (seconds per judge call, default 20), FM_SEND_BIN.
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOME_DIR = os.environ.get('FM_HOME') or os.path.dirname(HERE)
CONFIG = os.path.join(HOME_DIR, 'config', 'judge-first')
JUDGE_PY = os.environ.get('FM_JUDGE_PY') or os.path.join(HOME_DIR, 'data', 'fleet-bridge', 'judge.py')
JUDGE_LOG = os.environ.get('FM_JUDGE_LOG') or os.path.join(os.path.dirname(JUDGE_PY), 'judge-log.jsonl')
SEND_BIN = os.environ.get('FM_SEND_BIN') or os.path.join(HERE, 'fm-send.sh')
BUDGET = float(os.environ.get('FM_JUDGE_FIRST_BUDGET', '40'))
CALL_TIMEOUT = float(os.environ.get('FM_JUDGE_FIRST_TIMEOUT', '20'))
DEDUPE_SECONDS = 120
POLICIES = ('recommended-v1',)
VERBS = ('needs-decision', 'blocked')


def mode():
    """off | shadow | on, from config/judge-first only."""
    try:
        with open(CONFIG, encoding='utf-8') as fh:
            value = fh.read().strip().lower()
    except OSError:
        return 'off'
    return 'on' if value == 'on' else 'shadow'


# ---- parsing and card synthesis ------------------------------------------------

HEAD = re.compile(r'^(needs-decision|blocked)((?:\s+(?:\[[^\]]*\]|corr=[0-9A-Fa-f]{16}))*)\s*:?\s*(.*)$', re.S)


def parse_line(line):
    m = HEAD.match(line.strip())
    if not m:
        return None
    verb, head, body = m.group(1), m.group(2), m.group(3)
    key = re.search(r'\[key=([^\]]+)\]', head)
    at = re.search(r'\[at=(\d+)\]', head)
    corr = re.search(r'corr=([0-9A-Fa-f]{16})', head) or re.match(r'corr=([0-9A-Fa-f]{16})\s*', body)
    if re.match(r'corr=[0-9A-Fa-f]{16}\s*', body):
        body = re.sub(r'^corr=[0-9A-Fa-f]{16}\s*', '', body)
    key = key.group(1) if key else None
    # The documented alternate form puts the token right after the colon.
    lead = re.match(r'\[key=([^\]]+)\]\s*', body)
    if lead:
        key = key or lead.group(1)
        body = body[lead.end():]
    return {'verb': verb, 'key': key, 'at': int(at.group(1)) if at else None,
            'corr': corr.group(1).lower() if corr else None, 'body': body.strip()}


def key_family(key):
    if not key:
        return None
    family = re.sub(r'^captain-hold-', '', key)
    return re.sub(r'-\d+$', '', family)


MARK = re.compile(r'\(\s*([A-Za-z0-9])\s*(?:,\s*recommended\s*)?\)')
TRAIL_REC = re.compile(r'\(\s*recommended(?:\s*[;:,\-].*?)?\)', re.I)
SENTENCE = re.compile(r'(?<=[.;!?])\s+(?=[A-Z(])')
NEGATED = re.compile(r"\b(?:not|never|no|don't|do not|cannot|can't)\s+(?:\w+\s+){0,2}recommend", re.I)
REC_LETTER = re.compile(r'(?i:recommend\w*)\s*[:\-]?\s*(?:\(([A-Za-z0-9])\)|([A-Z0-9]))(?=[.:,;)]|$|\s+(?:if|else|and|or|because|since|\())')


def split_options(body):
    """Enumerated options "(a) ... (b) ..." -> (preamble, [(letter, text, flagged)])."""
    anchor = re.search(r'\bOptions\s*:\s*', body, re.I)
    context = body[:anchor.start()].strip() if anchor else ''
    body = body[anchor.end():] if anchor else body
    # A "Recommend (a)" reference to an option is not an option marker itself.
    marks = [m for m in MARK.finditer(body) if not re.search(r'(?i)recommend\w*\s*[:\-]?\s*$', body[max(0, m.start() - 24):m.start()])]
    letters = [m.group(1).lower() for m in marks]
    if len(marks) < 2 or len(set(letters)) != len(letters):
        return (context + ' ' + body).strip(), []
    options = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
        text = body[m.end():end].strip(' ;,')
        if i + 1 == len(marks):
            text = SENTENCE.split(text, 1)[0].strip()
        options.append((m.group(1).lower(), text, 'recommended' in m.group(0).lower() or bool(TRAIL_REC.search(text))))
    return (context + ' ' + body[:marks[0].start()]).strip(), options


def recommendation_sentence(body):
    for sentence in SENTENCE.split(body):
        if re.search(r'recommend', sentence, re.I):
            return sentence.strip()
    return None


def synthesize(parsed, secondmate):
    """The judge card for one parsed line, plus the guard inputs."""
    body = parsed['body']
    preamble, options = split_options(body)
    rec_sentence = recommendation_sentence(body)
    negated = bool(rec_sentence and NEGATED.search(rec_sentence))
    letter = None
    flagged_letters = [value for value, _text, flagged in options if flagged]
    if len(flagged_letters) > 1:
        negated = True  # Conflicting recommendations are never an auto-choice.
    elif flagged_letters:
        letter = flagged_letters[0]
    if letter is None and rec_sentence and not negated:
        m = REC_LETTER.search(rec_sentence)
        if m:
            letter = (m.group(1) or m.group(2)).lower()
    by_letter = {l: t for l, t, _f in options}
    selected = ''
    if options and letter in by_letter and not negated:
        card_options = [{'value': l, 'label': t} for l, t, _f in options]
        recommended, selected, question = letter, by_letter[letter], preamble
    elif not options and rec_sentence and not negated and not letter:
        card_options = [{'value': 'recommended', 'label': rec_sentence}, {'value': 'other', 'label': 'Any other path'}]
        recommended, selected, question = 'recommended', rec_sentence, body
    else:
        # Nothing the judge can take: no recommendation, a negated one, or a
        # letter that names no option.
        card_options, recommended, selected, question = [], None, '', body
    ident = key_family(parsed['key'])
    digest = hashlib.sha256(re.sub(r'\s+', ' ', body).encode()).hexdigest()
    card = {'decision_id': '%s:%s' % (secondmate, parsed['key'] or 'line-' + digest[:12]),
            'task_id': secondmate, 'title': parsed['key'] or '', 'question': question,
            'options': card_options, 'recommended': recommended, 'origin': {'lane': secondmate}}
    return {'card': card, 'selected': selected, 'preamble': preamble, 'body': body,
            'rec_sentence': rec_sentence, 'identity': '%s:%s' % (secondmate, ident or '~' + digest[:12]),
            'digest': digest}


# ---- guard rules: the gaps the backtest found --------------------------------
# These add to judge.py's own hard rules and only ever escalate. They scan the
# selected action plus the card title for topical guards, never defect narrative
# or alternatives. Destructive/security context keeps its existing guard.

# (rule, pattern, scope): "both" scans the selected option and its context,
# "selected" only scans the recommended action; "action" adds the card title.
# A past-tense abort in the context is the situation, not the ask.
GUARD = [
    ('irreversible_destructive', r"force[- ]with[- ]lease|\brewrit\w*\s+(?:the\s+|this\s+)?(?:branch(?:'s)?\s+)?history|history\s+rewrite|\breset\s+--hard", 'both'),
    ('irreversible_destructive', r'\babort(?:s|ing)?\b', 'selected'),
    ('pipeline_bypass', r'\b(?:bypass|skip\w*)\s+(?:the\s+)?(?:\w+\s+)?(?:pipeline|validation|no-mistakes|document|review|rebase|gate|tests?|checks?|ci)\b|--skip\b|--no-verify\b', 'action'),
    ('security_access', r'\brevocation\b|\bbot[- ]protection\b|\bturnstile\b|\bcaptcha\b|\bdisabl\w*\b.{0,30}\b(?:auth\w*|protection|verification|mfa|2fa)\b', 'both'),
    ('shared_state', r'\b(?:run|apply|execute)\b[^\n.;]{0,30}\bmigrat\w*|\bmigrat(?:e|ing)\b[^\n.;]{0,30}\b(?:database|db|postgres|staging|production)\b|\bshared\s+(?:vm\s+)?staging\b|\bstaging\s+(?:refresh|database|postgres)\b|\brebuild\w*\b.{0,40}\b(?:staging|production|prod)\b', 'action'),
    ('restricted_topic', r'\blegal\b|\bseller\s+identity\b|\bvat\b|\bpricing\b|\b(?:change|enable|disable|configure|activate|update|raise)\b[^\n.;]{0,30}\b(?:vat|pricing|billing)\b|\brefund\b|\bpaid\s+launch\b|\b(?:deploy|push|write|migrate|point)\b[^\n.;]{0,30}\b(?:production|prod)\b|\b(?:production|prod)\s+(?:db|database|env|secret|credentials|cutover|switch)\b', 'action'),
]
CONDITIONAL = re.compile(r'\bif\b.*\b(?:else|otherwise|unless)\b|\beither\b.*\bor\b|\bdepending\s+on\b|\bwhether\b', re.I)
BUNDLE_ID = re.compile(r'\b[DQ]\d{1,2}\b')
BUNDLE_RANGE = re.compile(r'\b[DQ]\d{1,2}\s*[-–]\s*[DQ]?\d{1,2}\b')


def guard_rules(synth):
    hits = []
    selected = synth['selected'].lower()
    both = (synth['selected'] + ' ' + synth['preamble']).lower()
    action = (synth['selected'] + ' ' + synth['card'].get('title', '')).lower()
    for name, pattern, scope in GUARD:
        target = {'selected': selected, 'both': both, 'action': action}[scope]
        # A generic refresh authorization names its target only in the context.
        if name == 'shared_state' and re.search(r'\b(?:authori[sz]e|perform|run)\s+(?:the\s+)?(?:documented\s+)?refresh\b', selected):
            target = both
        if re.search(pattern, target) and name not in hits:
            hits.append(name)
    body = synth['body']
    if BUNDLE_RANGE.search(body) or len(set(BUNDLE_ID.findall(body))) > 2:
        hits.append('bundle_card')
    if synth['rec_sentence'] and CONDITIONAL.search(synth['rec_sentence']):
        hits.append('conditional_recommendation')
    return hits


# ---- journal, dedupe, judge, send ----------------------------------------------

def read_log():
    rows = []
    try:
        with open(JUDGE_LOG, encoding='utf-8') as fh:
            for raw in fh:
                try:
                    rows.append(json.loads(raw))
                except ValueError:
                    continue
    except OSError:
        pass
    return rows


def append_log(entry):
    """One locked, fsynced append; True only when the row is durable."""
    try:
        with open(JUDGE_LOG, 'a', encoding='utf-8') as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.write(json.dumps(entry, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n')
            fh.flush()
            os.fsync(fh.fileno())
        return True
    except OSError:
        return False


def record_langfuse(row):
    """Export the durable final verdict; never evaluate or append another row."""
    try:
        subprocess.run([sys.executable, JUDGE_PY, '-', '--record-langfuse'],
                       input=json.dumps({k: row[k] for k in ('card', 'verdict', 'at')}),
                       capture_output=True, text=True, timeout=CALL_TIMEOUT,
                       cwd=os.path.dirname(JUDGE_PY))
    except (OSError, subprocess.TimeoutExpired):
        pass


def prior_cluster(rows, secondmate, identity, at):
    """A hook row for the same decision already journaled (same identity, near in time)."""
    for row in rows:
        hook = row.get('hook')
        if not isinstance(hook, dict) or hook.get('identity') != identity:
            continue
        if hook.get('action') not in ('auto', 'would-auto', 'escalate', 'sending', 'sent'):
            continue
        if at is None or hook.get('at') is None or abs(hook['at'] - at) <= DEDUPE_SECONDS:
            return row
    return None


def run_judge(card, started):
    if time.monotonic() - started > BUDGET:
        return None, 'budget spent'
    if not os.path.isfile(JUDGE_PY):
        return None, 'judge.py not found'
    try:
        done = subprocess.run([sys.executable, JUDGE_PY, '-', '--opinion-only'], input=json.dumps(card),
                              capture_output=True, text=True, timeout=CALL_TIMEOUT, cwd=os.path.dirname(JUDGE_PY))
        if done.returncode:
            return None, 'judge exit %d' % done.returncode
        verdict = json.loads(done.stdout.strip().splitlines()[-1])
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None, 'judge failed or timed out'
    if not isinstance(verdict, dict) or verdict.get('policy') not in POLICIES:
        return None, 'unknown judge policy'
    return verdict, None


def judge_one(synth, live, started):
    """verdict dict for one line; auto is True only when nothing escalates."""
    card = synth['card']
    if card['recommended'] is None:
        return {'auto': False, 'rules_hit': ['no_recommendation'], 'chosen': None, 'source': 'hook'}
    hits = guard_rules(synth)
    if hits:
        return {'auto': False, 'rules_hit': hits, 'chosen': None, 'source': 'hook'}
    verdict, error = run_judge(card, started)
    if verdict is None:
        return {'auto': False, 'rules_hit': ['judge_error'], 'chosen': None, 'source': 'hook', 'error': error}
    if verdict.get('auto') is not True or verdict.get('chosen') != card['recommended']:
        verdict['auto'] = False
        return verdict
    opinion = verdict.get('second_opinion')
    agreed = isinstance(opinion, dict) and opinion.get('agree') is True
    if not agreed:
        # An unattended answer needs a positive second opinion; a missing one
        # suits a manual check, not a hook (the backtest's section 3.1 step 4).
        verdict = dict(verdict, auto=False, chosen=None, rules_hit=list(verdict.get('rules_hit', [])) + ['second_opinion_missing'])
    return verdict


def answer_text(synth, verdict):
    label = re.sub(r'\s+', ' ', synth['selected']).strip()
    if len(label) > 300:
        label = label[:297] + '...'
    agreed = isinstance(verdict.get('second_opinion'), dict) and verdict['second_opinion'].get('agree') is True
    urls = list(dict.fromkeys(re.findall(r'https://github\.com/[^/\s]+/[^/\s]+/pull/\d+', synth['body'])))
    context = (' [' + ', '.join(urls) + ']') if urls else ''
    return 'judge auto-decided (recommended%s): %s - %s%s' % (', Jev agreed' if agreed else '', synth['card']['recommended'], label, context)


def send_answer(secondmate, keys, text):
    cmd = [SEND_BIN, secondmate]
    for key in keys:
        cmd += ['--resolve-key', key]
    cmd.append(text)
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=120, env=dict(os.environ, FM_HOME=HOME_DIR))
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {'ok': False, 'detail': 'send %s' % type(exc).__name__}
    tail = [l for l in (done.stdout + done.stderr).splitlines() if 'FM_PENDING_REPLY_EXISTING_CORR' in l or l.startswith('error')]
    return {'ok': done.returncode == 0, 'exit': done.returncode, 'detail': ' | '.join(tail[:3])}


def cluster_lines(items):
    """Group items (sorted by time) that are one decision."""
    clusters = []
    for item in items:
        for cluster in clusters:
            head = cluster[0]
            if head['synth']['identity'] == item['synth']['identity'] and (
                    head['parsed']['at'] is None or item['parsed']['at'] is None
                    or abs(head['parsed']['at'] - item['parsed']['at']) <= DEDUPE_SECONDS):
                cluster.append(item)
                break
        else:
            clusters.append([item])
    return clusters


def ingest(secondmate, lines):
    current = mode()
    summary = {'mode': current, 'lines': 0, 'auto': 0, 'escalate': 0, 'deduped': 0, 'error': 0}
    if current == 'off':
        return summary
    items = []
    for line in lines:
        parsed = parse_line(line)
        if parsed is None:
            continue
        items.append({'parsed': parsed, 'synth': synthesize(parsed, secondmate)})
    summary['lines'] = len(items)
    items.sort(key=lambda i: i['parsed']['at'] or 0)
    rows = read_log()
    started = time.monotonic()
    for cluster in cluster_lines(items):
        head = cluster[0]
        identity, at = head['synth']['identity'], head['parsed']['at']
        if prior_cluster(rows, secondmate, identity, at):
            summary['deduped'] += len(cluster)
            continue
        verdicts = [judge_one(i['synth'], current == 'on', started) for i in cluster]
        auto = all(v.get('auto') is True for v in verdicts)
        keys = [i['parsed']['key'] for i in cluster if i['parsed']['key']]
        keys = list(dict.fromkeys(keys))
        action = ('auto' if current == 'on' else 'would-auto') if auto else 'escalate'
        text = answer_text(head['synth'], verdicts[0]) if auto else None
        errored = any('judge_error' in v.get('rules_hit', []) for v in verdicts)
        now = int(time.time())
        row_base = {'at': now, 'hook': {'name': 'judge-first', 'mode': current, 'secondmate': secondmate,
                                        'identity': identity, 'keys': keys, 'at': at, 'lines': len(cluster),
                                        'verbs': [i['parsed']['verb'] for i in cluster], 'answer': text}}
        rows_out = []
        for i, v in zip(cluster, verdicts):
            hook = dict(row_base['hook'], action=action, card_hash=i['synth']['digest'], key=i['parsed']['key'])
            rows_out.append({'at': now, 'card': i['synth']['card'], 'verdict': v, 'hook': hook})
        if action == 'auto':
            for r in rows_out:
                r['hook']['action'] = 'sending'
        if not all(append_log(r) for r in rows_out):
            summary['error'] += len(cluster)
            continue
        rows.extend(rows_out)
        for row in rows_out:
            record_langfuse(row)
        if action == 'auto':
            result = send_answer(secondmate, keys, text)
            final = 'sent' if result['ok'] else 'send-failed'
            append_log({'at': int(time.time()), 'card': head['synth']['card'], 'verdict': verdicts[0],
                        'hook': dict(row_base['hook'], action=final, card_hash=head['synth']['digest'],
                                     key=head['parsed']['key'], send=result)})
            summary['auto' if result['ok'] else 'error'] += len(cluster)
        elif action == 'would-auto':
            summary['auto'] += len(cluster)
        else:
            summary['error' if errored else 'escalate'] += len(cluster)
    return summary


def summarize(since):
    counts, autos = {}, []
    for row in read_log():
        hook = row.get('hook')
        if not isinstance(hook, dict) or hook.get('name') != 'judge-first' or row.get('at', 0) < since:
            continue
        counts[hook['action']] = counts.get(hook['action'], 0) + 1
        if hook['action'] in ('would-auto', 'sent'):
            autos.append('%s\t%s\t%s' % (row['at'], hook.get('key') or hook['identity'], hook.get('answer') or ''))
    print(json.dumps({'counts': counts}, sort_keys=True))
    for line in autos:
        print(line)


def main(argv):
    if len(argv) >= 2 and argv[1] == 'ingest' and len(argv) == 4:
        try:
            raw = sys.stdin.read() if argv[3] == '-' else open(argv[3], encoding='utf-8', errors='replace').read()
            summary = ingest(argv[2], raw.splitlines())
        except Exception as exc:  # never let the hook break the ingest
            print('judge-first: error %s' % type(exc).__name__, file=sys.stderr)
            return 0
        print('judge-first: ' + ' '.join('%s=%s' % kv for kv in summary.items()))
        return 0
    if len(argv) in (2, 4) and argv[1] == 'summary':
        since = int(argv[3]) if len(argv) == 4 and argv[2] == '--since' and argv[3].isdigit() else 0
        summarize(since)
        return 0
    print('usage: fm-judge-first.sh ingest <secondmate-id> <status-lines-file|->\n'
          '       fm-judge-first.sh summary [--since <epoch>]', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
