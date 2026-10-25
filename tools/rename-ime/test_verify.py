"""Synthetic negative controls; these are not live GUI or pixel evidence."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate, h

address = load('address_fixture_tests', Path(__file__).resolve().parents[1] / 'address-ime/test_verify.py')


def fixture():
    report, candidate, raw = address.fixture(prefix="a/")
    report['schema'] = 'maru.rename-ime.v1'
    candidate['schema'] = 'maru.rename-ime-candidate.v1'
    for row in report['observations'] + report['composition']:
        row['target_hash'] = h('a//z')
        if int(row['owner_generation']):
            row['owner_generation'] = str(int(row['owner_generation']) - (1 << 61))
        if row['name'].startswith('selected_fixture_'):
            text = 'a//z'
            row.update(query_bytes=len(text), query_hash=h(text), document_bytes=len(text), document_hash=h(text))
    for triplet in raw:
        for phase in triplet.values():
            phase['search']['owner_generation'] -= 1 << 61
    committed = copy.deepcopy(report['observations'][-1])
    committed.update(name='target_committed', terminal_bytes=0, target_hash=h('a/韓/z'))
    report['observations'].insert(-1, committed)
    return report, candidate, raw


class RenameVerifierTests(unittest.TestCase):
    def check(self, report, candidate, raw):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'window-transcript.json').write_text(json.dumps(raw))
            validate(report, candidate, root)

    def test_valid_control(self):
        self.check(*fixture())

    def test_twenty_independent_corruptions(self):
        attacks = {
            'address_schema': lambda r,c,w: r.update(schema='maru.address-ime.v1'),
            'wrong_domain': lambda r,c,w: r['observations'][0].update(owner_generation=str(1 << 62)),
            'generation_replay': lambda r,c,w: r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'suffix_loss': lambda r,c,w: r['observations'][1].update(document_hash=h('한')),
            'early_target_write': lambda r,c,w: r['observations'][2].update(target_hash=h('a/韓/z')),
            'missing_target_write': lambda r,c,w: r['observations'][-2].update(target_hash=h('a//z')),
            'commit_keeps_open': lambda r,c,w: r['observations'][-2].update(open=1),
            'commit_leaks_terminal': lambda r,c,w: r['observations'][-2].update(terminal_bytes=1),
            'wrong_focus': lambda r,c,w: r['observations'][1].update(first_responder=False),
            'wrong_owner': lambda r,c,w: r['observations'][1].update(palette_owner=0),
            'candidate_navigates': lambda r,c,w: r['observations'][2].update(navigate_pending=1),
            'composition_leaks_terminal': lambda r,c,w: r['composition'][0].update(terminal_bytes=1),
            'cancel_still_marked': lambda r,c,w: r['observations'][3].update(has_marked=True),
            'terminal_not_restored': lambda r,c,w: r['observations'][-1].update(terminal_bytes=0),
            'anchor_outside': lambda r,c,w: r['geometry'][0].update(x=1000),
            'anchor_does_not_advance': lambda r,c,w: r['geometry'][1].update(x=0),
            'replayed_window': lambda r,c,w: c['rows'][1].update(window_id=c['rows'][0]['window_id']),
            'raw_owner_drift': lambda r,c,w: w[0]['opened']['search'].update(owner_generation=1),
            'raw_text_drift': lambda r,c,w: w[0]['opened']['search'].update(query_hash=1),
            'raw_screen_change': lambda r,c,w: w[0]['opened']['counters'].update(base_screen_generation=99),
        }
        self.assertEqual(len(attacks), 20)
        for name, attack in attacks.items():
            r,c,w = fixture()
            attack(r,c,w)
            with self.subTest(attack=name), self.assertRaises(ValueError):
                self.check(r,c,w)


if __name__ == '__main__':
    unittest.main()
