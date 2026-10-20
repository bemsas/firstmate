#!/usr/bin/env bash
# Exercise the model router's public CLI: classification, quota gates, Jev and replay.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHONDONTWRITEBYTECODE=1 python3 - "$FM_ROOT/bin/fm-model-router.py" <<'PY'
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROUTER = sys.argv.pop()


class RouterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fm-model-router-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'config').mkdir()
        (self.home / 'data/fleet-bridge').mkdir(parents=True)
        self.a = {'harness': 'codex', 'model': 'strong-a', 'effort': 'high', 'provider': 'openai'}
        self.b = {'harness': 'claude', 'model': 'strong-b', 'effort': 'high', 'provider': 'claude'}
        self.cheap = {'harness': 'opencode', 'model': 'cheap', 'provider': 'zai'}
        self.rules = [
            {'when': text, 'use': [self.a.copy(), self.b.copy(), self.cheap.copy()]}
            for text in ('Routine implementation', 'IMPORTANT implementation - load-bearing',
                         'Design, architecture', 'Research', 'Code review', 'Documentation',
                         'Genuinely complex implementation where design is not settled',
                         'High-volume or swarm work', 'Git workflow')]
        self.rules[6]['approval'] = 'captain'
        self.config = {'rules': self.rules, 'default': [self.cheap]}
        self.policy = {'provider_aliases': {'openai': 'codex'}, 'bindings': {},
                       'strong_profiles': ['codex|strong-a|high', 'claude|strong-b|high'],
                       'approval_profiles': [], 'allowed_openrouter_models': ['openrouter/deepseek/deepseek-v4.1-flash']}
        self.rows = [self.row('codex', 2), self.row('claude', 1), self.row('zai', 9)]
        self.extra = []
        self.attention = []
        self.stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.brief = 'Fix the parser bug and add tests.'

    def row(self, provider, priority, runway='through_reset', scope='all_models', **extra):
        return {'provider': provider, 'scope': scope, 'effectivePercentRemaining': 50,
                'spendPriority': priority, 'runway': runway, 'confidence': 'established',
                'limitedBy': 'weekly', 'resetsAt': self.stamp if hasattr(self, 'stamp') else '2030-01-01T00:00:00Z', **extra}

    def save(self):
        (self.home / 'config/crew-dispatch.json').write_text(json.dumps(self.config))
        (self.home / 'policy.json').write_text(json.dumps(self.policy))
        (self.home / 'brief.md').write_text(self.brief)
        def block(name, rows, fields):
            import csv
            import io
            out = io.StringIO()
            out.write(f'{name}[{len(rows)}]{{{",".join(fields)}}}:\n')
            for row in rows:
                line = io.StringIO()
                csv.writer(line, lineterminator='').writerow(['unknown' if row.get(f) is None else row[f] for f in fields])
                out.write('  ' + line.getvalue() + '\n')
            return out.getvalue()
        fields = ['provider'] + (['accountKey'] if any('accountKey' in r for r in self.rows) else [])
        (self.home / 'quota.toon').write_text('bin: quota-axi\ngeneratedAt: ' + json.dumps(self.stamp) + '\n'
            + block('quota', self.rows, fields + ['scope', 'effectivePercentRemaining', 'spendPriority', 'runway', 'confidence', 'limitedBy', 'resetsAt'])
            + block('exhaustion', self.extra, fields + ['scope', 'usableRunwaySeconds', 'projectedExhaustedAt', 'limitingWindowId'])
            + block('attention', self.attention, fields + ['scope', 'kind', 'detail', 'remedy']))

    def run_router(self, *extra, expected=0, rules_only=True, snapshot=True):
        self.save()
        command = [sys.executable, ROUTER, str(self.home / 'brief.md'), '--home', str(self.home),
                   '--policy', str(self.home / 'policy.json'), '--json']
        if rules_only:
            command.append('--rules-only')
        if snapshot:
            command.extend(['--snapshot', str(self.home / 'quota.toon')])
        proc = subprocess.run(command + list(extra), capture_output=True, text=True,
                              env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(proc.returncode, expected, proc.stderr + proc.stdout)
        return json.loads(proc.stdout) if proc.stdout else proc.stderr

    def test_classification_and_higher_priority(self):
        cases = [('Fix the parser bug and add tests.', 'routine_code', 'routine', 0),
                 ('Implement an authentication endpoint with tests.', 'important_code', 'high', 1),
                 ('Design the architecture and compare trade-offs.', 'design', 'high', 2),
                 ('Research published pricing sources.', 'research', 'moderate', 3),
                 ('Verify the deployment and run tests.', 'review_verify', 'moderate', 4),
                 ('Fix a typo in the README documentation.', 'docs', 'routine', 5)]
        for text, kind, difficulty, index in cases:
            with self.subTest(kind=kind):
                self.brief = text
                result = self.run_router()
                self.assertEqual(result['classification']['kind'], kind)
                self.assertEqual(result['classification']['difficulty'], difficulty)
                self.assertEqual(result['rule']['index'], index)
                self.assertEqual(result['choice']['model'], 'strong-a' if kind in ('important_code', 'design') else 'cheap')

    def test_scaffold_cannot_change_task_class(self):
        self.brief = '# Worker role\nDesign a security architecture.\n# Task\nFix the parser bug.\n# Setup\nResearch docs and audit billing.\n# Home brief additions\nIMPORTANT implementation.'
        result = self.run_router()
        self.assertEqual(result['classification']['kind'], 'routine_code')

    def test_unknown_does_not_silently_default(self):
        self.brief = 'Please handle it.'
        self.assertEqual(self.run_router(expected=1)['candidates'], [])

    def test_mixed_deliverable_abstains(self):
        self.brief = 'Research options and review their documentation.'
        self.assertIsNone(self.run_router(expected=1)['choice'])

    def test_rule_matching_is_not_position_based(self):
        self.config['rules'].reverse()
        self.assertEqual(self.run_router()['rule']['when'], 'Routine implementation')

    def test_unknown_rule_mapping_abstains(self):
        self.rules[0]['when'] = 'Operator-specific unclear words'
        self.assertIn('no unique', self.run_router(expected=1)['reason'])

    def test_docs_fall_back_to_routine_rule(self):
        self.config['rules'] = [r for r in self.rules if r['when'] != 'Documentation']
        self.brief = 'Update the README docs.'
        self.assertEqual(self.run_router()['rule']['when'], 'Routine implementation')

    def test_spend_priority_and_negative_values(self):
        self.rows[0]['spendPriority'] = -2
        self.rows[1]['spendPriority'] = -1
        self.rows[2]['spendPriority'] = -3
        self.assertEqual(self.run_router()['choice']['model'], 'strong-b')

    def test_strongest_class_is_never_downgraded(self):
        self.brief = 'Implement a security-critical API endpoint.'
        self.rows[0]['runway'] = self.rows[1]['runway'] = 'exhausted_now'
        result = self.run_router(expected=1)
        self.assertIsNone(result['choice'])
        self.assertTrue(any('strongest' in c['reason'] for c in result['candidates']))

    def test_runway_horizon_gates_high_priority(self):
        self.rows[2]['runway'] = 'projected_exhaustion'
        self.extra = [{'provider': 'zai', 'scope': 'all_models', 'usableRunwaySeconds': 60,
                       'projectedExhaustedAt': self.stamp, 'limitingWindowId': 'weekly'}]
        result = self.run_router()
        self.assertEqual(result['choice']['model'], 'strong-a')
        self.assertIn('shorter', next(c for c in result['candidates'] if c['profile']['model'] == 'cheap')['reason'])

    def test_through_reset_passes_even_when_reset_is_imminent(self):
        self.rows[2]['resetsAt'] = self.stamp
        self.assertEqual(self.run_router()['choice']['model'], 'cheap')

    def test_unknown_is_unranked_not_zero(self):
        self.rows[2]['spendPriority'] = None
        self.rows[0]['spendPriority'] = -2
        self.rows[1]['spendPriority'] = -1
        self.assertEqual(self.run_router()['choice']['model'], 'strong-b')

    def test_unknown_runway_never_proves_completion(self):
        for row in self.rows:
            row['runway'] = 'unknown'
        self.assertIsNone(self.run_router(expected=1)['choice'])

    def test_ties_require_decision(self):
        for row in self.rows:
            row['spendPriority'] = 1
        self.assertIn('tie', self.run_router(expected=1)['reason'])

    def test_explicit_profile_and_rule_approval(self):
        self.policy['approval_profiles'] = ['opencode|cheap|']
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')
        self.assertEqual(self.run_router('--approved')['choice']['model'], 'cheap')
        self.brief = 'Implement a genuinely complex feature; the design is not settled.'
        self.assertIsNone(self.run_router(expected=1)['choice'])
        self.assertEqual(self.run_router('--approved')['choice']['model'], 'strong-a')

    def test_unmeasured_account_cannot_borrow_quota(self):
        self.policy['bindings']['opencode|cheap|'] = {'unmeasured': 'worker account differs from measured account'}
        result = self.run_router()
        self.assertEqual(result['choice']['model'], 'strong-a')
        self.assertTrue(any('account differs' in c['reason'] for c in result['candidates']))

    def test_provider_alias_and_multi_account_join(self):
        for row in self.rows:
            row['accountKey'] = 'default'
        self.rows += [self.row('codex', 12, accountKey='other'), self.row('codex', 10, accountKey='codex-home')]
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')
        self.rows[-1]['spendPriority'] = 0
        self.assertEqual(self.run_router()['choice']['model'], 'cheap')

    def test_provider_and_model_scopes_both_bound(self):
        self.rows.append(self.row('zai', 20, runway='exhausted_now', scope='model:cheap'))
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')

    def test_unrelated_model_scope_does_not_block(self):
        self.rows.append(self.row('zai', 20, runway='exhausted_now', scope='model:unrelated'))
        self.assertEqual(self.run_router()['choice']['model'], 'cheap')

    def test_floor_and_stale_attention(self):
        self.rules[0]['use'][2]['floor'] = {'scope': 'all_models', 'min_percent': 60}
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')
        del self.rules[0]['use'][2]['floor']
        self.attention = [{'provider': 'zai', 'scope': 'all', 'kind': 'stale', 'detail': 'stale sample', 'remedy': 'none'}]
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')

    def test_openrouter_allowlist(self):
        self.rules[0]['use'][2].update(model='openrouter/unapproved/model', provider='openrouter')
        self.rows.append(self.row('openrouter', 100))
        result = self.run_router()
        self.assertEqual(result['choice']['model'], 'strong-a')
        self.assertTrue(any('allowlist' in c['reason'] for c in result['candidates']))

    def test_duplicate_profile_and_invalid_number_fail(self):
        self.rules[0]['use'].append(self.a.copy())
        self.assertIn('no recommendation', self.run_router(expected=2))
        self.rules[0]['use'].pop()
        self.rows[0]['spendPriority'] = 'NaN'
        self.assertIn('no recommendation', self.run_router(expected=2))

    def test_stale_snapshot_fails(self):
        self.stamp = '2020-01-01T00:00:00+00:00'
        self.assertIn('no recommendation', self.run_router(expected=2))

    def json_snapshot(self, providers):
        path = self.home / 'quota.json'
        path.write_text(json.dumps({'schemaVersion': 6, 'generatedAt': self.stamp, 'providers': providers}))
        return path

    def json_provider(self, provider='codex', account='codex-home', priority=5, **extra):
        return {'provider': provider, 'accountKey': account, 'quotaSemantics': {'status': 'known', 'effectiveAvailability': [
            {'scope': 'all_models', 'status': 'known', 'effectivePercentRemaining': 50,
             'selection': {'status': 'known', 'spendPriority': priority}, 'runway': {'status': 'through_reset'}}]}, **extra}

    def test_real_json_projection_shape(self):
        path = self.json_snapshot([self.json_provider()])
        self.assertEqual(self.run_router('--snapshot', str(path))['choice']['model'], 'strong-a')

    def test_json_stale_provider_and_unknown_selection_abstain(self):
        provider = self.json_provider(state={'stale': True, 'status': 'stale'})
        path = self.json_snapshot([provider])
        self.assertIsNone(self.run_router('--snapshot', str(path), expected=1)['choice'])
        del provider['state']
        provider['quotaSemantics']['effectiveAvailability'][0]['selection']['status'] = 'unknown'
        self.json_snapshot([provider])
        self.assertIsNone(self.run_router('--snapshot', str(path), expected=1)['choice'])

    def test_json_account_does_not_match_other_account(self):
        path = self.json_snapshot([self.json_provider(account='unrelated')])
        self.assertIsNone(self.run_router('--snapshot', str(path), expected=1)['choice'])

    def test_json_account_default_fallback(self):
        path = self.json_snapshot([self.json_provider(account='default')])
        self.assertEqual(self.run_router('--snapshot', str(path))['choice']['model'], 'strong-a')

    def test_json_empty_exact_account_never_borrows_default(self):
        exact = self.json_provider()
        exact['quotaSemantics'] = {'status': 'unknown', 'effectiveAvailability': []}
        path = self.json_snapshot([exact, self.json_provider(account='default', priority=100)])
        self.assertIsNone(self.run_router('--snapshot', str(path), expected=1)['choice'])

    def test_malformed_empty_json_account_is_rejected(self):
        invalid = self.json_provider(account='bad account')
        invalid['quotaSemantics']['effectiveAvailability'] = []
        path = self.json_snapshot([invalid, self.json_provider(account='default')])
        self.run_router('--snapshot', str(path), expected=2)

    def test_profile_floor_unknown_cannot_select(self):
        self.rules[0]['use'][2]['floor'] = {'scope': 'unmeasured', 'min_percent': 10}
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')

    def test_rule_floor_preserves_strong_requirement(self):
        self.brief = 'Implement a security-critical API endpoint.'
        self.rules[1]['floor'] = {'scope': 'all_models', 'min_percent': 90, 'provider': 'codex'}
        self.assertIsNone(self.run_router(expected=1)['choice'])

    def test_explicit_difficulty_requires_strong_class(self):
        self.rules[0]['router_difficulty'] = 'high'
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')

    def test_boundary_runway_subtracts_snapshot_age(self):
        self.stamp = datetime.datetime.fromtimestamp(time.time()-30, datetime.timezone.utc).isoformat()
        self.rows[2]['runway'] = 'projected_exhaustion'
        self.extra = [{'provider': 'zai', 'scope': 'all_models', 'usableRunwaySeconds': 3610,
                       'projectedExhaustedAt': self.stamp, 'limitingWindowId': 'weekly'}]
        self.assertEqual(self.run_router()['choice']['model'], 'strong-a')

    def test_malformed_counted_tables_fail_closed(self):
        self.save()
        bad = self.home / 'bad.toon'
        source = (self.home / 'quota.toon').read_text()
        for content in [source.replace('quota[3]', 'quota[4]'), source+'  rogue,row\n',
                        source.replace('spendPriority,runway', 'spendPriority,spendPriority'),
                        source.replace('generatedAt:', 'missingAt:')]:
            with self.subTest(content=content[-30:]):
                bad.write_text(content)
                self.run_router('--snapshot', str(bad), expected=2)

    def fake_jev(self, choice='rule_0', confidence=0.9):
        # Public client seam: identical signatures, no credentials or network.
        (self.home / 'data/fleet-bridge/second_opinion.py').write_text('''
import json
from pathlib import Path
canonical = json.dumps
def load_config():
    return {'JEV_API_KEY': 'synthetic-fixture', 'OPENROUTER_API_KEY': 'never-use-this-transport'}
def jev(card, options, config, history):
    assert set(config) == {'JEV_API_KEY', 'OPENROUTER_API_KEY'}
    path = Path(__file__).with_name('calls')
    path.write_text(path.read_text() + 'call\\n' if path.exists() else 'call\\n')
    choice = CHOICE
    confidence = CONFIDENCE
    return {'choice': choice, 'confidence': confidence, 'cost_usd': 0.0001,
            'answered_model': 'jev-fixture',
            'probabilities': {o['value']: confidence if o['value'] == choice else (1-confidence)/(len(options)-1) for o in options}}
'''.replace('CHOICE', repr(choice)).replace('CONFIDENCE', repr(confidence)))

    def test_jev_only_for_ambiguous_task_once(self):
        self.fake_jev()
        self.run_router(rules_only=False)
        calls = self.home / 'data/fleet-bridge/calls'
        self.assertFalse(calls.exists())
        self.brief = 'Please handle it.'
        result = self.run_router(rules_only=False)
        self.assertEqual(result['classification']['source'], 'jev')
        self.assertEqual(calls.read_text(), 'call\n')

    def test_jev_abstains_on_uncertainty_and_size_cap(self):
        self.fake_jev(confidence=0.4)
        self.brief = 'Please handle it.'
        self.run_router(rules_only=False, expected=1)
        calls = self.home / 'data/fleet-bridge/calls'
        calls.unlink()
        self.brief = 'unclear ' * 2000
        self.run_router(rules_only=False, expected=1)
        self.assertFalse(calls.exists())

    def test_jev_missing_transport_is_safe(self):
        self.brief = 'Please handle it.'
        self.run_router(rules_only=False, expected=1)

    def test_single_toon_capture_and_only_one_json_fallback(self):
        self.save()
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        quota = fakebin / 'quota-axi'
        quota.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\np=Path(' + repr(str(self.home)) + ')\n'
                         'with (p/"quota-calls").open("a") as f: f.write(" ".join(sys.argv[1:])+"\\n")\n'
                         'print((p/"quota.toon").read_text())\n')
        quota.chmod(0o755)
        old_path = os.environ['PATH']
        self.addCleanup(lambda: os.environ.__setitem__('PATH', old_path))
        os.environ['PATH'] = str(fakebin) + os.pathsep + old_path
        self.run_router(snapshot=False)
        calls = self.home / 'quota-calls'
        self.assertEqual(calls.read_text(), '\n')
        calls.unlink()
        self.rows[2]['spendPriority'] = None
        result = self.run_router(snapshot=False)
        self.assertTrue(result['quota_json_fallback'])
        self.assertEqual(calls.read_text(), '\n--json\n')

    def test_backtest_last_50_and_actual_unknowns(self):
        for i in range(55):
            path = self.home / 'data' / f'task-{i}' / 'brief.md'
            path.parent.mkdir()
            path.write_text(self.brief)
            os.utime(path, (i + 1, i + 1))
        actuals = self.home / 'actuals.json'
        actuals.write_text(json.dumps({'task-54': {**self.cheap, 'source': 'retained dispatch export'},
                                      'task-53': {'harness': 'codex', 'model': 'default'}}))
        result = self.run_router('--backtest', '--actuals', str(actuals))
        self.assertEqual(result['total'], 50)
        self.assertEqual(result['actual_known'], 1)
        self.assertEqual(result['harness_model_matches'], 1)
        self.assertNotIn('task-0', [r['task'] for r in result['rows']])
        self.assertIsNone(result['rows'][0]['exact_profile_match'])
        self.assertFalse((self.home / 'data/fleet-bridge/calls').exists())


unittest.main()
PY
