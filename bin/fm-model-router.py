#!/usr/bin/env python3
"""Recommend a configured worker; never spawn, change config, or read runtime state.

Usage: fm-model-router.py BRIEF --home HOME --policy POLICY [--snapshot TOON_OR_JSON]
       fm-model-router.py --backtest --home HOME --policy POLICY [--actuals JSON]

Python 3.10+, stdlib only. Rules classify task text before worker scaffolding.
Ambiguous tasks get at most one Jev Choice through HOME/data/fleet-bridge/
second_opinion.py's existing client (Gateway/direct/OpenRouter Decisions).
--rules-only forbids model calls; backtests default to rules-only unless --with-jev.
No OpenRouter router or chat endpoint is invoked. Jev's serialized input is capped
at 12,000 bytes, estimated conservatively at $0.042/M input tokens plus overhead,
below $0.01 per call (prices checked 2026-10-20); output is free.

POLICY is operator-owned JSON: provider_aliases maps config provider IDs to quota
IDs; bindings maps 'harness|model|effort' to provider/accountKey/scopes or an
unmeasured reason; strong_profiles lists that same identity for important/design
work; approval_profiles lists reserved identities; allowed_openrouter_models is
an exact allowlist. No model tier is inferred from a model name.
Each rule's natural-language `when` is matched conservatively to known task
categories; unrecognized/overlapping rules abstain. Optional router_kind and
router_difficulty fields make a rule explicit; docs fall back to routine_code
only if there is no docs rule. Floors and approval fields retain their gates.

Quota: capture default quota-axi TOON once; at most one JSON fallback for genuine
uncertainty/ties. --snapshot uses only that file. Account joins follow the shared
contract in fm-quota-axi-lib.sh, scopes are exact plus policy binding scopes.
spendPriority alone ranks candidates after reasoning, approval, floors and the
completion horizon; ties and terminal uncertainty abstain. Horizon defaults to
60 minutes and is always disclosed. Snapshots older than 300 seconds are refused.
Catalog support and vendor authentication remain unprobed; fm-spawn validation
and firstmate's quota-array-dispatch intake remain mandatory.

Backtest: latest 50 data/*/brief.md by mtime, one current quota snapshot and policy.
--actuals is an optional JSON task-id -> {harness,model,effort,source} export.
It never scans state/ or guesses an actual from a task name, author or model
mentioned in task text. Missing identities and missing effort stay unknown.
This is current-policy replay, not historical reconstruction or a quality score.
Exit 0: recommendation/backtest; 1: abstain; 2: invalid input/tool failure.
"""
import argparse
import csv
import datetime as dt
import importlib.util
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path


sys.dont_write_bytecode = True
KINDS = ('routine_code', 'important_code', 'design', 'research', 'review_verify', 'docs')
DIFFICULTIES = ('routine', 'moderate', 'high')
TOKEN = re.compile(r'^[A-Za-z0-9._/:+-]+$')
PROVIDER = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
MAX_JEV_BYTES = 12000
JEV_INPUT_USD_PER_M = 0.042


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def identity(profile):
    return '|'.join(profile.get(k, '') for k in ('harness', 'model', 'effort'))


def profiles(value):
    return value if isinstance(value, list) else [value]


def validate_config(config, policy):
    if not isinstance(config, dict) or not isinstance(config.get('rules'), list):
        raise ValueError('dispatch config needs a rules array')
    if not isinstance(policy, dict):
        raise ValueError('policy must be an object')
    for key in ('strong_profiles', 'approval_profiles', 'allowed_openrouter_models'):
        if not isinstance(policy.get(key), list) or any(not isinstance(x, str) for x in policy[key]):
            raise ValueError('policy needs string array ' + key)
    for key in ('bindings', 'provider_aliases'):
        if not isinstance(policy.get(key, {}), dict):
            raise ValueError('invalid policy ' + key)
    for source, target in policy.get('provider_aliases', {}).items():
        if not PROVIDER.fullmatch(source) or not isinstance(target, str) or not PROVIDER.fullmatch(target):
            raise ValueError('invalid provider alias')
    for key, binding in policy.get('bindings', {}).items():
        if not isinstance(key, str) or not isinstance(binding, dict):
            raise ValueError('invalid quota binding')
        if 'provider' in binding and (not isinstance(binding['provider'], str) or not PROVIDER.fullmatch(binding['provider'])):
            raise ValueError('invalid binding provider')
        if 'scopes' in binding and (not isinstance(binding['scopes'], list) or any(not isinstance(x, str) or not x for x in binding['scopes'])):
            raise ValueError('invalid binding scopes')
        if 'accountKey' in binding and (not isinstance(binding['accountKey'], str) or not binding['accountKey']):
            raise ValueError('invalid binding account')
        if 'unmeasured' in binding and (not isinstance(binding['unmeasured'], str) or not binding['unmeasured']):
            raise ValueError('invalid unmeasured reason')
    rules = config['rules']
    for rule in rules:
        if not isinstance(rule, dict) or not isinstance(rule.get('when'), str) or not rule['when'].strip():
            raise ValueError('each rule needs a nonempty when')
        if rule.get('approval') not in (None, 'captain'):
            raise ValueError('unsupported rule approval')
        if rule.get('router_kind') not in (None, *KINDS):
            raise ValueError('invalid router_kind')
        if rule.get('router_difficulty') not in (None, *DIFFICULTIES):
            raise ValueError('invalid router_difficulty')
        validate_floor(rule.get('floor'), provider_required=True)
    for rule in rules + [{'use': config.get('default', [])}]:
        candidates = profiles(rule.get('use'))
        if not candidates or not all(isinstance(p, dict) for p in candidates):
            raise ValueError('use/default needs one or more profiles')
        seen = set()
        for p in candidates:
            for key in ('harness', 'model', 'effort'):
                if not isinstance(p.get(key), str) or not TOKEN.fullmatch(p[key]):
                    if key == 'effort' and key not in p:
                        continue
                    raise ValueError('profiles must name a concrete harness/model and valid effort')
            if 'provider' in p and (not isinstance(p['provider'], str) or not PROVIDER.fullmatch(p['provider'])):
                raise ValueError('invalid profile provider')
            if p.get('approval') not in (None, 'captain'):
                raise ValueError('unsupported profile approval')
            validate_floor(p.get('floor'))
            if identity(p) in seen:
                raise ValueError('duplicate concrete profile within rule')
            seen.add(identity(p))


def validate_floor(floor, provider_required=False):
    if floor is None:
        return
    if (not isinstance(floor, dict) or not isinstance(floor.get('scope'), str) or not floor['scope']
            or not number(floor.get('min_percent')) or not 0 <= floor['min_percent'] <= 100
            or (provider_required and not isinstance(floor.get('provider'), str))
            or ('provider' in floor and not PROVIDER.fullmatch(str(floor['provider'])))):
        raise ValueError('invalid quota floor')


def task_text(brief):
    """Exclude worker role, setup, delivery defaults and standing additions."""
    match = re.search(r'^# Task\s*$', brief, re.M)
    text = brief[match.end():] if match else brief
    return re.split(r'^# (?:Setup|Rules|Herdr lifecycle|Firstmate instruction inbox|Project memory|Definition of done|Home brief additions)\b', text, maxsplit=1, flags=re.M)[0].strip()


def classify_rules(text):
    """Conservative action cues; mixed deliverables and underspecified text abstain."""
    text = task_text(text).lower()
    has = lambda pattern: bool(re.search(pattern, text))
    coding = has(r'\b(?:implement|build|fix|refactor|patch|add|repair|extend)\b')
    code_object = has(r'\b(?:code|function|endpoint|api|script|helper|tests?|bug|component|class|parser|feature|router|classifier|migration)\b')
    important = has(r'\b(?:load-bearing|security[- ](?:relevant|critical)|authentication|authorization|credentials?|encryption|billing|payment|hard to reverse|data loss|database migration|production migration)\b')
    design = has(r'\b(?:design|architect(?:ure)?|exhaustive planning|adversarial review|deep investigation|compare (?:the )?(?:options|architectures)|trade[- ]offs?|design is not settled)\b')
    research = has(r'\b(?:research|investigate|survey|measure|benchmark|labelling|labeling|corpus|scout|find sources|literature)\b')
    review = has(r'\b(?:review|verify|validate|audit|inspect|screenshots?|browser check|run (?:the )?tests)\b')
    docs = has(r'\b(?:documentation|readme|docs|guide|tutorial|copy edit|proofread)\b')
    complex_work = has(r'\b(?:design is not settled|cannot be specified|unsettled design|genuinely complex)\b')
    variant = 'complex' if complex_work and coding else 'bulk' if has(r'\b(?:high.volume|swarm|many small independent|bulk)\b') else 'git' if has(r'\b(?:git workflow|branch management|merge conflict|rebase strategy)\b') else None
    if coding and code_object:
        if design and not important and not complex_work:
            return {'kind': None, 'difficulty': None, 'variant': variant, 'source': 'rules', 'reason': 'mixed design and code deliverables'}
        kind = 'important_code' if important or complex_work else 'routine_code'
    elif design:
        kind = 'design'
    elif sum((research, review, docs)) > 1:
        return {'kind': None, 'difficulty': None, 'variant': variant, 'source': 'rules', 'reason': 'mixed non-code deliverables'}
    elif review:
        kind = 'review_verify'
    elif research:
        kind = 'research'
    elif docs:
        kind = 'docs'
    elif variant:
        kind = 'routine_code'
    else:
        return {'kind': None, 'difficulty': None, 'variant': None, 'source': 'rules', 'reason': 'no clear action and deliverable'}
    difficulty = 'high' if kind in ('important_code', 'design') else 'routine' if kind in ('routine_code', 'docs') else 'moderate'
    return {'kind': kind, 'difficulty': difficulty, 'variant': variant, 'source': 'rules', 'reason': 'explicit task action and deliverable'}


def rule_category(rule):
    if rule.get('router_kind'):
        return rule['router_kind']
    text = rule['when'].lower()
    # Ordered, narrow descriptions of the existing config vocabulary, not rule positions.
    for kind, pattern in (
        ('complex', r'genuinely complex implementation|design is not settled'),
        ('important_code', r'important implementation|load-bearing|security-relevant'),
        ('bulk', r'high-volume|swarm work'),
        ('git', r'git workflow|branch management|merge conflict'),
        ('design', r'^design[, ]|architecture|exhaustive planning|adversarial review'),
        ('review_verify', r'code review|visual checking|general inspection|review/verify'),
        ('research', r'corpus survey|scout task|knowledge deliverable|^research'),
        ('docs', r'documentation|^docs\b'),
        ('routine_code', r'routine implementation|routine code'),
    ):
        if re.search(pattern, text):
            return kind
    return None


def matching_rule(classification, config):
    target = classification.get('variant') or classification['kind']
    indexes = [i for i, r in enumerate(config['rules']) if rule_category(r) == target]
    if not indexes and target == 'docs':
        indexes = [i for i, r in enumerate(config['rules']) if rule_category(r) == 'routine_code']
    return indexes[0] if len(indexes) == 1 else None


def jev_classify(text, config, home):
    """Use judge.py's exact client path; no chat fallback and no secret diagnostics."""
    path = home / 'data/fleet-bridge/second_opinion.py'
    spec = importlib.util.spec_from_file_location('fleet_router_second_opinion', path)
    stage = 'client unavailable'
    try:
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Invoke only Jev's typed classifier, never evaluate() or chat fallback.
        keys = module.load_config()
        keys = {k: v for k, v in keys.items() if k in ('AI_GATEWAY_API_KEY', 'JEV_API_KEY', 'OPENROUTER_API_KEY')}
        stage = 'no configured Jev transport'
        if not keys:
            raise ValueError('no permitted Jev transport')
        options = []
        for i, rule in enumerate(config['rules']):
            category = rule_category(rule)
            if category is not None:
                options.append({'value': 'rule_' + str(i), 'description': rule['when']})
        options.append({'value': 'docs', 'description': 'Documentation-only writing or correction.'})
        options.append({'value': 'unknown', 'description': 'No rule fits, contradictory requirements, or insufficient task information.'})
        card = {'question': 'Classify the task by its primary deliverable. Select the most specific matching rule; '
                'important/security-sensitive code outranks routine code. Ignore worker scaffold and model preferences. '
                'Return unknown for mixed or unclear deliverables.', 'brief': task_text(text), 'recommended': 'unknown'}
        # Include slack for the existing client's fixed instructions/JSON envelope.
        size = len(module.canonical({'card': card, 'options': options}).encode()) + 2048
        estimate = size * JEV_INPUT_USD_PER_M / 1e6
        stage = 'input exceeds classification budget'
        if size > MAX_JEV_BYTES or estimate > 0.01:
            raise ValueError('over budget')
        stage = 'provider unavailable or invalid response'
        result = module.jev(card, options, keys, {})
        if any(secret and secret in module.canonical(result) for secret in keys.values()):
            raise ValueError('credential echo')
        cost = result.get('cost_usd')
        if cost is not None and (not number(cost) or cost > 0.01):
            raise ValueError('reported over budget')
        choice = result['choice']
        probabilities = result['probabilities']
        evidence = {'source': 'jev', 'model': result['answered_model'], 'transport': result.get('transport'),
                    'probability': result['confidence'], 'cost_usd': cost, 'usage': result.get('usage'),
                    'cost_upper_estimate_usd': estimate}
        if result['confidence'] < 0.60 or sum(v == probabilities[choice] for v in probabilities.values()) != 1 or choice == 'unknown':
            return {**evidence, 'kind': None, 'difficulty': None, 'variant': None,
                    'reason': 'Jev abstained: unknown class, tied options or top probability below 0.60'}
        category = 'docs' if choice == 'docs' else rule_category(config['rules'][int(choice[5:])])
        kind = 'important_code' if category == 'complex' else 'routine_code' if category in ('bulk', 'git') else category
        difficulty = 'high' if kind in ('important_code', 'design') else 'routine' if kind in ('docs', 'routine_code') else 'moderate'
        if choice != 'docs':
            difficulty = config['rules'][int(choice[5:])].get('router_difficulty', difficulty)
        return {**evidence, 'kind': kind, 'difficulty': difficulty, 'variant': category if category in ('complex', 'bulk', 'git') else None,
                'rule_index': None if choice == 'docs' else int(choice[5:]),
                'reason': 'Jev classified an ambiguous task; code retains all policy gates'}
    except (OSError, ValueError, TypeError, KeyError, AttributeError, IndexError, ImportError) as error:
        status = getattr(error, 'status', None)
        return {'kind': None, 'difficulty': None, 'variant': None, 'source': 'jev',
                'http_status': status if type(status) is int else None, 'reason': 'Jev abstained: ' + stage}


def timestamp(text):
    value = dt.datetime.fromisoformat(text.replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('quota timestamp needs a timezone')
    return value.timestamp()


def validate_snapshot_age(snapshot, maximum):
    age = time.time() - timestamp(snapshot['generatedAt'])
    if age < -60 or age > maximum:
        raise ValueError('quota snapshot is stale or future-dated')


def parse_snapshot(text):
    """Decode the public counted tables or the JSON availability projection."""
    if text.lstrip().startswith('{'):
        raw = json.loads(text)
        if raw.get('schemaVersion') not in (5, 6) or not isinstance(raw.get('providers'), list):
            raise ValueError('unsupported quota JSON schema')
        rows, attention = [], []
        accounts = set()
        for p in raw['providers']:
            key = (p['provider'], p.get('accountKey', ''))
            if (not isinstance(key[0], str) or not PROVIDER.fullmatch(key[0])
                    or not isinstance(key[1], str) or re.search(r'\s', key[1])
                    or key in accounts or (raw['schemaVersion'] == 6 and not key[1])
                    or p['quotaSemantics']['status'] not in ('known', 'partial', 'unknown')):
                raise ValueError('duplicate or missing quota account')
            accounts.add(key)
            base = {'provider': key[0], **({'accountKey': key[1]} if key[1] else {})}
            if p.get('state', {}).get('stale') or p.get('state', {}).get('status') == 'stale':
                attention.append({**base, 'scope': 'all', 'kind': 'stale'})
            for a in p['quotaSemantics']['effectiveAvailability']:
                rows.append({**base, 'scope': a['scope'], 'effectivePercentRemaining': a.get('effectivePercentRemaining'),
                             'spendPriority': a.get('selection', {}).get('spendPriority') if a.get('selection', {}).get('status') == 'known' else None,
                             'runway': a.get('runway', {}).get('status', 'unknown'),
                             'usableRunwaySeconds': a.get('runway', {}).get('usableRunwaySeconds'),
                             'status': a.get('status', 'unknown') if p['quotaSemantics']['status'] != 'unknown' else 'unknown'})
        snapshot = {'generatedAt': raw['generatedAt'], 'quota': rows, 'attention': attention, 'format': 'json',
                    'keyed': raw['schemaVersion'] == 6, 'accounts': [
                        {'provider': p['provider'], 'accountKey': p.get('accountKey', '')} for p in raw['providers']]}
    else:
        lines = text.splitlines()
        stamp = next((line.partition(': ')[2].strip('"') for line in lines if line.startswith('generatedAt: ')), None)
        if not stamp or not lines or not lines[0].startswith('bin: '):
            raise ValueError('invalid quota TOON header')
        tables = {}
        expected_fields = {
            'quota': ['provider', 'scope', 'effectivePercentRemaining', 'spendPriority', 'runway', 'confidence', 'limitedBy', 'resetsAt'],
            'exhaustion': ['provider', 'scope', 'usableRunwaySeconds', 'projectedExhaustedAt', 'limitingWindowId'],
            'attention': ['provider', 'scope', 'kind', 'detail', 'remedy'],
        }
        i = 0
        while i < len(lines):
            line = lines[i]
            match = re.fullmatch(r'(quota|exhaustion|attention)\[(\d+)\](?:\{([^}]+)\})?:', line)
            inline = re.fullmatch(r'(quota|exhaustion|attention): (\[.*\])', line)
            if inline:
                name, value = inline.groups()
                if name in tables:
                    raise ValueError('duplicate quota table')
                tables[name] = json.loads(value)
            elif match:
                name, count, columns = match.groups()
                if name in tables or (int(count) and not columns):
                    raise ValueError('invalid counted table')
                fields = columns.split(',') if columns else []
                expected = expected_fields[name]
                if columns and fields not in (expected, [expected[0], 'accountKey', *expected[1:]]):
                    raise ValueError('unexpected quota columns')
                rows = []
                for _ in range(int(count)):
                    i += 1
                    if i >= len(lines) or not lines[i].startswith('  '):
                        raise ValueError('truncated quota table')
                    values = next(csv.reader([lines[i].strip()], strict=True))
                    if len(values) != len(fields) or any(not v for v in values):
                        raise ValueError('invalid quota row')
                    rows.append(dict(zip(fields, values)))
                tables[name] = rows
            elif line.startswith(('quota', 'exhaustion', 'attention')) or (
                    line and not line.startswith(('bin: ', 'description: ', 'generatedAt: ', 'help[', '  '))):
                raise ValueError('invalid quota table or unexpected content')
            elif line.startswith('  ') and not any(previous.startswith('help[') for previous in lines[:i]):
                raise ValueError('unexpected table row')
            i += 1
        if set(tables) != {'quota', 'exhaustion', 'attention'}:
            raise ValueError('missing quota table')
        exhaustion = {(r['provider'], r.get('accountKey', ''), r['scope']): r for r in tables['exhaustion']}
        if len(exhaustion) != len(tables['exhaustion']):
            raise ValueError('duplicate exhaustion row')
        for row in tables['quota']:
            extra = exhaustion.get((row['provider'], row.get('accountKey', ''), row['scope']), {})
            row['usableRunwaySeconds'] = extra.get('usableRunwaySeconds')
        snapshot = {'generatedAt': stamp, 'quota': tables['quota'], 'attention': tables['attention'], 'format': 'toon',
                    'keyed': any('accountKey' in r for r in tables['quota'] + tables['attention']),
                    'accounts': [{'provider': r['provider'], 'accountKey': r.get('accountKey', '')}
                                 for r in tables['quota'] + tables['attention']]}
    timestamp(snapshot['generatedAt'])
    seen = set()
    keyed_rows = ['accountKey' in r for r in snapshot['quota'] + snapshot['attention']]
    if any(keyed_rows) and not all(keyed_rows):
        raise ValueError('mixed keyed and unkeyed quota rows')
    for row in snapshot['quota']:
        key = (row['provider'], row.get('accountKey', ''), row['scope'])
        if key in seen or not PROVIDER.fullmatch(key[0]) or not key[2]:
            raise ValueError('duplicate/invalid quota identity')
        seen.add(key)
        for field in ('effectivePercentRemaining', 'spendPriority', 'usableRunwaySeconds'):
            value = row.get(field)
            if value in (None, 'unknown'):
                row[field] = None
            else:
                if isinstance(value, bool):
                    raise ValueError('invalid numeric quota value')
                row[field] = float(value)
                if not number(row[field]):
                    raise ValueError('non-finite quota')
        pct, seconds = row['effectivePercentRemaining'], row['usableRunwaySeconds']
        if (pct is not None and not 0 <= pct <= 100) or (seconds is not None and seconds < 0):
            raise ValueError('quota out of range')
        if row.get('runway') not in ('unknown', 'through_reset', 'projected_exhaustion', 'exhausted_now'):
            raise ValueError('invalid runway')
    return snapshot


def capture_quota(json_fallback=False):
    result = subprocess.run(['quota-axi'] + (['--json'] if json_fallback else []), capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError('quota-axi failed')
    return parse_snapshot(result.stdout)


def quota_rows(profile, policy, snapshot, extra_scopes=()):
    binding = policy.get('bindings', {}).get(identity(profile), {})
    if binding.get('unmeasured'):
        return [], binding['unmeasured']
    provider = binding.get('provider', policy.get('provider_aliases', {}).get(profile.get('provider'), profile.get('provider')))
    lane = binding.get('accountKey')
    if lane is None:
        lane = 'codex-home' if profile['harness'] == 'codex' else profile['model'].split('/')[0] if profile['harness'] in ('pi', 'pi-signed') and '/' in profile['model'] else ''
        if lane == 'codex-native':
            lane = 'codex-home'
    rows = [r for r in snapshot['quota'] if r['provider'] == provider]
    if snapshot['keyed']:
        # Match provider rows before scopes, never fall back to a different account.
        selected = lane if any(r['provider'] == provider and r['accountKey'] == lane for r in snapshot['accounts']) else 'default'
        rows = [r for r in rows if r.get('accountKey') == selected]
    else:
        selected = ''
    scopes = {'all_models', 'all_products', 'model:' + profile['model'], 'product:' + profile['model'], *binding.get('scopes', []), *extra_scopes}
    rows = [r for r in rows if r['scope'] in scopes]
    notices = [a for a in snapshot['attention'] if a['provider'] == provider and a.get('accountKey', '') == selected
               and a['scope'] in scopes | {'all'} and a.get('kind') in ('stale', 'auth_required', 'headroom_unknown')]
    if notices:
        return [], 'quota attention: ' + ', '.join(a['kind'] + '/' + a['scope'] for a in notices)
    return rows, 'provider=' + str(provider or 'unknown') + ' account=' + (selected or 'unkeyed')


def floor_state(floor, rows):
    if not floor:
        return 'pass'
    found = [r for r in rows if r['scope'] == floor['scope'] and r.get('effectivePercentRemaining') is not None]
    if not found:
        return 'unknown'
    return 'below' if min(r['effectivePercentRemaining'] for r in found) < floor['min_percent'] else 'pass'


def route(classification, config, policy, snapshot, horizon, approved=False):
    result = {'status': 'abstain', 'classification': classification, 'horizon_seconds': horizon,
              'snapshot_generated_at': snapshot['generatedAt'], 'candidates': [], 'choice': None,
              'validation': 'recommendation only; catalog/auth unprobed; firstmate intake and spawn validation required'}
    if classification.get('kind') is None:
        return {**result, 'reason': classification['reason']}
    index = classification.get('rule_index')
    if index is None:
        index = matching_rule(classification, config)
    if index is None:
        return {**result, 'reason': 'no unique matching dispatch rule'}
    rule = config['rules'][index]
    result['rule'] = {'index': index, 'when': rule['when']}
    rule_gate = None
    if rule.get('approval') == 'captain' and not approved:
        rule_gate = 'rule requires explicit approval'
    if rule.get('floor'):
        floor = rule['floor']
        pseudo = {'harness': '', 'model': '', 'provider': floor['provider']}
        rows, _ = quota_rows(pseudo, policy, snapshot, (floor['scope'],))
        state = floor_state(floor, rows)
        if state != 'pass':
            rule_gate = 'rule quota floor ' + state + '; no silent fallback'
    age = max(0, time.time() - timestamp(snapshot['generatedAt']))
    strong = classification['kind'] in ('important_code', 'design') or classification['difficulty'] == 'high'
    for profile in profiles(rule['use']):
        reasons = []
        rows, relation = quota_rows(profile, policy, snapshot, (profile['floor']['scope'],) if profile.get('floor') else ())
        gate = rule_gate
        if profile['model'].startswith('openrouter/') or profile.get('provider') == 'openrouter':
            if profile['model'] not in policy['allowed_openrouter_models']:
                gate = 'OpenRouter model outside operator allowlist'
        if strong and identity(profile) not in policy['strong_profiles']:
            gate = 'outside required strongest reasoning class'
        if (identity(profile) in policy['approval_profiles'] or profile.get('approval') == 'captain') and not approved:
            gate = 'profile requires explicit approval'
        if floor_state(profile.get('floor'), rows) != 'pass':
            gate = 'profile quota floor ' + floor_state(profile['floor'], rows)
        priorities = [r['spendPriority'] for r in rows]
        priority = min(priorities) if priorities and all(number(p) for p in priorities) else None
        feasible = bool(rows)
        for row in rows:
            runway = row['runway']
            seconds = row.get('usableRunwaySeconds')
            if runway == 'exhausted_now':
                gate = 'exhausted_now at ' + row['scope']
            elif runway == 'projected_exhaustion':
                if seconds is None:
                    feasible = False
                elif seconds - age < horizon:
                    gate = 'runway shorter than completion horizon at ' + row['scope']
            elif runway != 'through_reset':
                feasible = False
            if row.get('status', 'known') != 'known' or row.get('effectivePercentRemaining') is None:
                feasible = False
            reasons.append(row['scope'] + ':' + runway + (('/' + str(seconds) + 's') if seconds is not None else ''))
        rankable = gate is None and feasible and priority is not None
        why = gate or ('proven horizon; rank by spendPriority' if rankable else 'eligible with unmeasured priority/runway; cannot rank')
        row = {'profile': profile, 'eligible': gate is None, 'rankable': rankable, 'spendPriority': priority,
               'runway': reasons, 'reason': relation + '; ' + why}
        result['candidates'].append(row)
    result['candidates'].sort(key=lambda c: (c['rankable'], c['spendPriority'] if c['spendPriority'] is not None else -math.inf), reverse=True)
    ranked = [c for c in result['candidates'] if c['rankable']]
    if not ranked:
        result['reason'] = 'no candidate has proven reasoning fit, approval, priority and completion runway'
    elif len(ranked) > 1 and ranked[0]['spendPriority'] == ranked[1]['spendPriority']:
        result['reason'] = 'genuine spendPriority tie; supervisor decision required'
    else:
        result.update(status='recommended', choice=ranked[0]['profile'], reason='highest spendPriority among candidates with proven completion runway and required reasoning class')
    return result


def classify(text, config, home, with_jev):
    value = classify_rules(text)
    if with_jev and value['kind'] is None:
        return jev_classify(text, config, home)
    if value['kind'] is not None:
        index = matching_rule(value, config)
        if index is not None and config['rules'][index].get('router_difficulty'):
            value['difficulty'] = config['rules'][index]['router_difficulty']
    return value


def backtest(home, config, policy, snapshot, horizon, actuals, with_jev=False):
    paths = sorted((home / 'data').glob('*/brief.md'), key=lambda p: (p.stat().st_mtime_ns, str(p)), reverse=True)[:50]
    rows = []
    for path in paths:
        text = path.read_text()
        classification = classify(text, config, home, with_jev)
        routed = route(classification, config, policy, snapshot, horizon)
        actual = actuals.get(path.parent.name)
        known = isinstance(actual, dict) and all(isinstance(actual.get(k), str) and actual[k] and actual[k] != 'default' for k in ('harness', 'model'))
        comparable = known and routed['choice'] is not None
        match = (actual['harness'], actual['model']) == (routed['choice']['harness'], routed['choice']['model']) if comparable else None
        effort_known = known and 'effort' in actual and actual['effort'] != 'default'
        rows.append({'task': path.parent.name, 'brief': str(path), 'classification': classification,
                     'status': routed['status'], 'reason': routed['reason'], 'pick': routed['choice'],
                     'actual': actual if known else None, 'actual_status': 'recorded' if known else 'unknown: no concrete retained dispatch export',
                     'harness_model_match': match, 'exact_profile_match': match and actual['effort'] == routed['choice'].get('effort', '') if comparable and effort_known else None})
    comparable = [r for r in rows if r['harness_model_match'] is not None]
    return {'mode': 'current-policy replay; not historical reconstruction or model quality', 'total': len(rows),
            'actual_known': sum(r['actual'] is not None for r in rows), 'comparable': len(comparable),
            'harness_model_matches': sum(r['harness_model_match'] for r in comparable),
            'snapshot_generated_at': snapshot['generatedAt'], 'horizon_seconds': horizon, 'rows': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('brief', nargs='?', help='brief path or - for stdin')
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--policy', type=Path, required=True)
    parser.add_argument('--snapshot', type=Path)
    parser.add_argument('--horizon-minutes', type=float, default=60)
    parser.add_argument('--max-snapshot-age', type=float, default=300)
    parser.add_argument('--approved', action='store_true', help='operator attests explicit approval for this task, including reserved profiles')
    parser.add_argument('--rules-only', action='store_true')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--backtest', action='store_true')
    parser.add_argument('--with-jev', action='store_true', help='allow up to one paid Jev call per ambiguous backtest brief')
    parser.add_argument('--actuals', type=Path)
    args = parser.parse_args()
    if not args.backtest and not args.brief:
        parser.error('brief required unless --backtest')
    if not number(args.horizon_minutes) or args.horizon_minutes <= 0 or not number(args.max_snapshot_age) or args.max_snapshot_age <= 0:
        parser.error('horizon and maximum snapshot age must be finite and positive')
    try:
        config = json.loads((args.home / 'config/crew-dispatch.json').read_text())
        policy = json.loads(args.policy.read_text())
        validate_config(config, policy)
        snapshot = parse_snapshot(args.snapshot.read_text()) if args.snapshot else capture_quota()
        validate_snapshot_age(snapshot, args.max_snapshot_age)
        horizon = args.horizon_minutes * 60
        actuals = json.loads(args.actuals.read_text()) if args.actuals else {}
        if not isinstance(actuals, dict):
            raise ValueError('actuals must be an object')
        if args.backtest:
            result = backtest(args.home, config, policy, snapshot, horizon, actuals, args.with_jev and not args.rules_only)
        else:
            text = sys.stdin.read() if args.brief == '-' else Path(args.brief).read_text()
            classification = classify(text, config, args.home, not args.rules_only)
            result = route(classification, config, policy, snapshot, horizon, args.approved)
            uncertain_quota = any(c['eligible'] and not c['rankable'] for c in result['candidates'])
            tied_quota = result['status'] == 'abstain' and 'tie' in result['reason']
            if not args.snapshot and (uncertain_quota or tied_quota):
                fallback = capture_quota(json_fallback=True)
                validate_snapshot_age(fallback, args.max_snapshot_age)
                # JSON's availability projection omits some auth/stale attention.
                # Preserve the original TOON evidence instead of upgrading it away.
                fallback['attention'].extend(snapshot['attention'])
                snapshot = fallback
                result = route(classification, config, policy, snapshot, horizon, args.approved)
                result['quota_json_fallback'] = True
        if args.json or args.backtest:
            print(json.dumps(result, indent=2, allow_nan=False))
        else:
            c = result['classification']
            print(f"{result['status']}: {c['kind'] or 'unknown'}/{c['difficulty'] or 'unknown'} via {c['source']}; horizon={horizon:g}s; {result['reason']}")
            print(result['validation'])
            for candidate in result['candidates']:
                priority = candidate['spendPriority']
                print(f"candidate {identity(candidate['profile'])}: spendPriority={priority if priority is not None else 'unknown'}; runway={','.join(candidate['runway']) or 'unknown'}; {candidate['reason']}")
            if result['choice']:
                print('choice: ' + ' '.join(f'--{k} {result["choice"][k]}' for k in ('harness', 'model', 'effort') if k in result['choice']))
        return 0 if args.backtest or result['status'] == 'recommended' else 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError, IndexError, csv.Error, subprocess.TimeoutExpired):
        # Input or transport errors can embed payloads/credentials. Never echo them.
        print('model-router: invalid/unreadable input, stale quota, or unavailable quota tool; no recommendation', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
