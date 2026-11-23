#!/usr/bin/env python3
# fm-judge-first.py - the decision engine behind bin/fm-judge-first.sh.
#
#   fm-judge-first.py ingest <secondmate-id> <status-lines-file|->
#   fm-judge-first.py summary [--since <epoch>] [--reversals <verified-answer-receipts.jsonl>]
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
#   2. captain holds or no recommendation -> escalate, no guessing;
#   3. the guard rules below (the gaps the backtest found) -> escalate;
#   4. judge.py --opinion-only (its own hard rules plus the second opinion);
#      in `on` mode a missing or disagreeing second opinion escalates;
#   5. a cluster of lines that are one decision (same secondmate, same key
#      family, within DEDUPE_SECONDS) is judged together, auto only when every
#      member is auto and a final hold lookup still permits the send.
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
# Summary optionally takes an explicit JSONL export from the operator verifying
# human answers against the answer source. Each fm-judge-reversal.v1 record
# has actor, outcome ("reversed" or "upheld"), unchanged_premises, a stable
# event_id for the original human answer, its epoch at, and the original
# sent hook's auto_send object with its decisions array replaced by one
# exact decision object under "decision". The decision's original corr is
# null if structurally absent from the opening. The send's delivery_corr
# remains mandatory. Only an unconflicted captain reversal on unchanged
# premises counts, once per exact delivered decision occurrence. Malformed
# nonblank receipts refuse the report. Without input the count is null.
#
# Environment (tests and relocated homes): FM_HOME, FM_JUDGE_PY, FM_JUDGE_LOG,
# FM_JUDGE_FIRST_BUDGET (total judge seconds per ingest, default 40),
# FM_JUDGE_FIRST_TIMEOUT (seconds per judge call, default 20), FM_SEND_BIN,
# FM_CAPTAIN_HOLD_BIN.
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
HOLD_BIN = os.environ.get('FM_CAPTAIN_HOLD_BIN') or os.path.join(HERE, 'fm-captain-hold.sh')
BUDGET = float(os.environ.get('FM_JUDGE_FIRST_BUDGET', '40'))
CALL_TIMEOUT = float(os.environ.get('FM_JUDGE_FIRST_TIMEOUT', '20'))
DEDUPE_SECONDS = 120
POLICIES = ('recommended-v1',)
VERBS = ('needs-decision', 'blocked')
CORR = re.compile(r'[0-9a-f]{16}')
DELIVERY_RECEIPT = re.compile(
    r'^fm-send: confirmed decision delivery corr=([0-9a-f]{16}) key=(\S+) opening-sha256=([0-9a-f]{64})$', re.M)


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
    # Opening correlations are metadata, so a correlation mentioned later in
    # question prose does not make an otherwise uncorrelated opening ambiguous.
    corr_tokens = re.findall(r'(?:^|\s|\[)corr=([^\s\]]*)', head.lower())
    body_header = re.sub(r'^\[key=[^\]]+\]\s*', '', body, count=1)
    body_corr = re.match(r'^\[?corr=([^\s\]]*)', body_header.lower())
    if body_corr:
        corr_tokens.append(body_corr[1])
    correlation = corr[1].lower() if corr else None
    if re.match(r'corr=[0-9A-Fa-f]{16}\s*', body):
        body = re.sub(r'^corr=[0-9A-Fa-f]{16}\s*', '', body)
    key = key.group(1) if key else None
    # The documented alternate form puts the token right after the colon.
    lead = re.match(r'\[key=([^\]]+)\]\s*', body)
    if lead:
        key = key or lead.group(1)
        body = body[lead.end():]
    return {'verb': verb, 'key': key, 'at': int(at.group(1)) if at else None,
            'corr': correlation, 'corr_unambiguous': set(corr_tokens) == ({correlation} if corr else set()),
            'body': body.strip()}


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
# "decision" scans the key and the entire status body, including alternatives.
# A past-tense abort in the context is the situation, not the ask.
GUARD = [
    ('irreversible_destructive', r'\b(?:discard(?:s|ed|ing)?|forc(?:e[ds]?|ing)|tear[ -]?downs?)\b', 'decision'),
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
    body = synth['body']
    key = synth['card'].get('title', '')
    selected = synth['selected'].lower()
    both = (synth['selected'] + ' ' + synth['preamble']).lower()
    targets = {
        'selected': selected,
        'both': both,
        'action': (synth['selected'] + ' ' + key).lower(),
        'decision': (key.replace('_', ' ') + '\n' + body).lower(),
    }
    for name, pattern, scope in GUARD:
        target = targets[scope]
        # A generic refresh authorization names its target only in the context.
        if name == 'shared_state' and re.search(r'\b(?:authori[sz]e|perform|run)\s+(?:the\s+)?(?:documented\s+)?refresh\b', selected):
            target = both
        if re.search(pattern, target) and name not in hits:
            hits.append(name)
    if BUNDLE_RANGE.search(body) or len(set(BUNDLE_ID.findall(body))) > 2:
        hits.append('bundle_card')
    if synth['rec_sentence'] and CONDITIONAL.search(synth['rec_sentence']):
        hits.append('conditional_recommendation')
    return hits


# ---- captain holds: the judge never answers one ---------------------------------

CAPTAIN_CALL = re.compile(r'^(?:captain[- ](?:call|only|hold|held)|held for the captain)\b', re.I)


def is_captain_hold(secondmate, key):
    """True when `key` names a captain-held task. A cannot-tell result counts as held."""
    if not key:
        return False
    if key.startswith('captain-hold-'):
        return True
    try:
        done = subprocess.run([HOLD_BIN, 'select', secondmate, key], capture_output=True, text=True,
                              timeout=CALL_TIMEOUT, env=dict(os.environ, FM_HOME=HOME_DIR))
    except (OSError, subprocess.TimeoutExpired):
        return True
    return done.returncode != 1


def held_verdict():
    return {'auto': False, 'rules_hit': ['captain_hold'], 'chosen': None, 'source': 'hook'}


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
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                              env=dict(os.environ, FM_HOME=HOME_DIR, FM_SEND_REPORT_DELIVERY='1'))
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {'ok': False, 'detail': 'send %s' % type(exc).__name__}
    tail = [l for l in (done.stdout + done.stderr).splitlines() if 'FM_PENDING_REPLY_EXISTING_CORR' in l or l.startswith('error')]
    result = {'ok': done.returncode == 0, 'exit': done.returncode, 'detail': ' | '.join(tail[:3])}
    receipts = DELIVERY_RECEIPT.findall(done.stdout)
    correlations = {corr for corr, _, _ in receipts}
    if result['ok'] and len(correlations) == 1:
        result['delivery_corr'] = correlations.pop()
        result['openings'] = [[key, digest] for _, key, digest in receipts]
    return result


def auto_send_identity(secondmate, cluster, result):
    if 'delivery_corr' not in result:
        return {}
    decisions = []
    for item in cluster:
        parsed = item['parsed']
        if (parsed['key'] and parsed['at'] and parsed['corr_unambiguous']
                and result['openings'].count([parsed['key'], item['opening']]) == 1):
            decisions.append({'key': parsed['key'], 'at': parsed['at'], 'corr': parsed['corr'],
                              'opening_sha256': item['opening']})
    return {'auto_send': {'home': os.path.realpath(HOME_DIR), 'task': secondmate,
                          'delivery_corr': result['delivery_corr'], 'decisions': decisions}}


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
        items.append({'parsed': parsed, 'synth': synthesize(parsed, secondmate),
                      'opening': hashlib.sha256(line.encode(errors='surrogateescape')).hexdigest()})
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
        keys = [i['parsed']['key'] for i in cluster if i['parsed']['key']]
        keys = list(dict.fromkeys(keys))
        if any(CAPTAIN_CALL.match(i['parsed']['body']) for i in cluster) or any(
                is_captain_hold(secondmate, k) for k in keys):
            verdicts = [held_verdict() for _ in cluster]
        else:
            verdicts = [judge_one(i['synth'], current == 'on', started) for i in cluster]
        auto = all(v.get('auto') is True for v in verdicts)
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
        if action == 'auto' and any(is_captain_hold(secondmate, k) for k in keys):
            # A hold placed after the verdict was journaled: never send.
            append_log({'at': int(time.time()), 'card': head['synth']['card'], 'verdict': held_verdict(),
                        'hook': dict(row_base['hook'], action='escalate', card_hash=head['synth']['digest'],
                                     key=head['parsed']['key'])})
            summary['escalate'] += len(cluster)
        elif action == 'auto':
            result = send_answer(secondmate, keys, text)
            final = 'sent' if result['ok'] else 'send-failed'
            append_log({'at': int(time.time()), 'card': head['synth']['card'], 'verdict': verdicts[0],
                        'hook': dict(row_base['hook'], action=final, card_hash=head['synth']['digest'],
                                     key=head['parsed']['key'], send=result,
                                     **auto_send_identity(secondmate, cluster, result))})
            summary['auto' if result['ok'] else 'error'] += len(cluster)
        elif action == 'would-auto':
            summary['auto'] += len(cluster)
        else:
            summary['error' if errored else 'escalate'] += len(cluster)
    return summary


def nonblank(value):
    return isinstance(value, str) and bool(value.strip())


def valid_corr(value):
    return isinstance(value, str) and CORR.fullmatch(value) is not None


def valid_decision(decision):
    return (isinstance(decision, dict) and nonblank(decision.get('key'))
            and type(decision.get('at')) is int and decision['at'] > 0
            and 'corr' in decision and (decision['corr'] is None or valid_corr(decision['corr']))
            and isinstance(decision.get('opening_sha256'), str)
            and re.fullmatch(r'[0-9a-f]{64}', decision['opening_sha256']) is not None)


def linked_decision(decision, openings):
    return valid_decision(decision) and openings.count([decision['key'], decision['opening_sha256']]) == 1


def confirmed_auto_send(hook):
    sent, send = hook.get('auto_send'), hook.get('send')
    if not (hook.get('mode') == 'on' and hook.get('action') == 'sent'
            and isinstance(sent, dict) and isinstance(send, dict)
            and send.get('ok') is True and type(send.get('exit')) is int and send['exit'] == 0
            and sent.get('home') == os.path.realpath(HOME_DIR)
            and isinstance(sent.get('task'), str) and sent['task'] == hook.get('secondmate')
            and valid_corr(sent.get('delivery_corr'))
            and sent['delivery_corr'] == send.get('delivery_corr')
            and isinstance(sent.get('decisions'), list) and isinstance(send.get('openings'), list)
            and all(linked_decision(decision, send['openings']) for decision in sent['decisions'])):
        return None
    return sent


def receipt_object(pairs):
    record = dict(pairs)
    if len(record) != len(pairs):
        raise ValueError('duplicate JSON field')
    return record


def read_answer_receipts(receipt_path):
    events = {}
    with open(receipt_path, encoding='utf-8') as receipts:
        for number, line in enumerate(receipts, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line, object_pairs_hook=receipt_object)
                identity = record.get('auto_send') if isinstance(record, dict) else None
                if not (isinstance(identity, dict) and nonblank(identity.get('home'))
                        and nonblank(identity.get('task')) and valid_corr(identity.get('delivery_corr'))
                        and valid_decision(identity.get('decision'))
                        and record.get('schema') == 'fm-judge-reversal.v1'
                        and nonblank(record.get('event_id')) and nonblank(record.get('actor'))
                        and record.get('outcome') in ('reversed', 'upheld')
                        and type(record.get('unchanged_premises')) is bool
                        and type(record.get('at')) is int and record['at'] > 0):
                    raise ValueError
            except (ValueError, RecursionError):
                raise ValueError(f'malformed answer receipt on line {number}') from None
            events.setdefault(record['event_id'], []).append(record)
    return events


def count_human_reversals(rows, since, receipt_path):
    if receipt_path is None:
        return None
    deliveries, occurrences = {}, {}
    for row, hook in rows:
        sent = confirmed_auto_send(hook)
        if sent is not None:
            deliveries.setdefault(sent['delivery_corr'], []).append((row, sent))
    for same_event in read_answer_receipts(receipt_path).values():
        event_unambiguous = all(record == same_event[0] for record in same_event)
        for receipt in same_event:
            identity = receipt['auto_send']
            matches = deliveries.get(identity['delivery_corr'], [])
            if len(matches) != 1:
                continue
            row, sent = matches[0]
            decision = identity['decision']
            if (row['at'] < since or receipt['at'] < row['at'] or identity['home'] != sent['home']
                    or identity['task'] != sent['task'] or sent['decisions'].count(decision) != 1):
                continue
            occurrence = (sent['delivery_corr'], decision['key'], decision['at'],
                          decision['opening_sha256'], decision['corr'])
            qualifies = (event_unambiguous and receipt['actor'] == 'captain'
                         and receipt['outcome'] == 'reversed' and receipt['unchanged_premises'])
            occurrences[occurrence] = occurrences.get(occurrence, True) and qualifies
    return sum(occurrences.values())


def summarize(since, receipt_path=None):
    counts, autos = {}, []
    rows = []
    unlinked = 0
    for row in read_log():
        if not isinstance(row, dict):
            continue
        hook = row.get('hook')
        if (not isinstance(hook, dict) or hook.get('name') != 'judge-first'
                or not isinstance(hook.get('action'), str) or type(row.get('at')) is not int):
            continue
        rows.append((row, hook))
        if row['at'] < since:
            continue
        counts[hook['action']] = counts.get(hook['action'], 0) + 1
        sent = confirmed_auto_send(hook)
        if hook['action'] == 'sent' and (sent is None or not sent.get('decisions')):
            unlinked += 1
        if hook['action'] in ('would-auto', 'sent'):
            autos.append('%s\t%s\t%s' % (row['at'], hook.get('key') or hook.get('identity', ''), hook.get('answer') or ''))
    try:
        reversals = count_human_reversals(rows, since, receipt_path)
    except (OSError, UnicodeError):
        print('judge-first: cannot read the supplied answer receipts', file=sys.stderr)
        return 2
    except ValueError as exc:
        print(f'judge-first: {exc}', file=sys.stderr)
        return 2
    print(json.dumps({'counts': counts, 'confirmed_human_reversals': reversals,
                      'reversal_source': 'operator-attested' if receipt_path is not None else None,
                      'live_sends_without_reversal_linkage': unlinked}, sort_keys=True))
    for line in autos:
        print(line)
    return 0


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
    if len(argv) >= 2 and argv[1] == 'summary':
        import argparse
        parser = argparse.ArgumentParser(prog='fm-judge-first.sh summary')
        parser.add_argument('--since', type=int, default=0, metavar='EPOCH')
        parser.add_argument('--reversals', metavar='VERIFIED-ANSWER-RECEIPTS.jsonl')
        args = parser.parse_args(argv[2:])
        return summarize(args.since, args.reversals)
    print('usage: fm-judge-first.sh ingest <secondmate-id> <status-lines-file|->\n'
          '       fm-judge-first.sh summary [--since <epoch>] [--reversals <receipts.jsonl>]', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
