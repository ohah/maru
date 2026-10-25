"""Synthetic hostile evidence controls; no GUI input or pixel claim."""
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate,h
address = load('find_fixture_source', Path(__file__).resolve().parents[1] / 'address-ime/test_verify.py')


def fixture():
    report,candidate,raw = address.fixture(prefix='',suffix='',initial_word='',owner_shift=59)
    report['schema']='maru.find-ime.v1'
    candidate['schema']='maru.find-ime-candidate.v1'
    for row in report['observations'] + report['composition']:
        row['filter_count']=2
        row.update(file_hash=h('한 한 韓 韓'), file_bytes=len('한 한 韓 韓'.encode()), match_index=0, replacement_field=0)
        if row['name'].startswith('opened_'):
            row.update(query_hash=h('한'),query_bytes=3)
    for triplet in raw:
        triplet['opened']['search'].update(query_hash=int(h('한')),query_bytes=3)
    return report,candidate,raw


class FindVerifierTests(unittest.TestCase):
    def check(self,report,candidate,raw):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'window-transcript.json').write_text(json.dumps(raw))
            validate(report,candidate,root)

    def test_normal_control(self):
        self.check(*fixture())

    def test_twenty_independent_corruptions(self):
        attacks={
            'wrong_schema':lambda r,c,w:r.update(schema='maru.rename-ime.v1'),
            'replacement_mutates_file':lambda r,c,w:r['observations'][23].update(file_hash=h('韓 한 韓 韓')),
            'candidate_navigates':lambda r,c,w:r['observations'][23].update(match_index=1),
            'focus_field_changes':lambda r,c,w:r['observations'][2].update(replacement_field=1),
            'wrong_owner_domain':lambda r,c,w:r['observations'][0].update(owner_generation=str(1<<61)),
            'replayed_owner':lambda r,c,w:r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'preview_publishes_query':lambda r,c,w:r['observations'][2].update(query_hash=h('韓')),
            'preview_changes_filter':lambda r,c,w:r['observations'][2].update(filter_count=0),
            'cancel_loses_query':lambda r,c,w:r['observations'][3].update(query_hash=h('')),
            'cancel_keeps_stale_filter':lambda r,c,w:r['observations'][3].update(filter_count=0),
            'selected_not_committed':lambda r,c,w:r['observations'][23].update(query_hash=h('한')),
            'preview_changes_document':lambda r,c,w:r['observations'][2].update(document_hash=h('한韓')),
            'wrong_focus':lambda r,c,w:r['observations'][1].update(first_responder=False),
            'candidate_activates_row':lambda r,c,w:r['observations'][2].update(navigate_pending=1),
            'composition_leaks_terminal':lambda r,c,w:r['composition'][0].update(terminal_bytes=1),
            'cancel_still_marked':lambda r,c,w:r['observations'][3].update(has_marked=True),
            'terminal_not_restored':lambda r,c,w:r['observations'][-1].update(terminal_bytes=0),
            'anchor_outside':lambda r,c,w:r['geometry'][0].update(x=1000),
            'anchor_backwards':lambda r,c,w:r['geometry'][1].update(x=0),
            'replayed_window':lambda r,c,w:c['rows'][1].update(window_id=c['rows'][0]['window_id']),
            'raw_owner_drift':lambda r,c,w:w[0]['opened']['search'].update(owner_generation=1),
            'raw_text_drift':lambda r,c,w:w[0]['opened']['search'].update(query_hash=1),
            'raw_screen_drift':lambda r,c,w:w[0]['opened']['counters'].update(base_screen_generation=99),
        }
        self.assertEqual(len(attacks),23)
        for name,attack in attacks.items():
            r,c,w=fixture();attack(r,c,w)
            with self.subTest(attack=name), self.assertRaises(ValueError):self.check(r,c,w)


if __name__=='__main__':unittest.main()
