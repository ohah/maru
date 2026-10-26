"""Synthetic hostile evidence controls; no GUI input or pixel claim."""
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate,h
address = load('sidebar_fixture_source', Path(__file__).resolve().parents[1] / 'address-ime/test_verify.py')


def fixture():
    report,candidate,raw = address.fixture(prefix='',suffix='',initial_word='',owner_shift=57)
    report['schema']='maru.sidebar-search-ime.v1'
    candidate['schema']='maru.sidebar-search-ime-candidate.v1'
    for row in report['observations'] + report['composition']:
        row.update(filter_count=1,label_hash=h('한韓'),tabs_count=2,active_surface=77,active_workspace=0)
        if row['name'].startswith('opened_'):
            row.update(query_hash=h('한'),query_bytes=3)
    report['observations'][-1].update(query_hash=h(''),query_bytes=0)
    for row in report['observations'] + report['composition']:
        mask={h(''):3,h('ㅎ'):0,h('하'):0,h('한'):1,h('韓'):2}[row['query_hash']]
        row.update(visible_mask=str(mask),filter_count=bin(mask).count('1'))
    report['glyph_advances']={'한':10.0,'韓':6.0}
    report['observations'][23]['filter_count']=1
    for triplet in raw:
        triplet['opened']['search'].update(query_hash=int(h('한')),query_bytes=3)
        for name,snapshot in triplet.items():
            snapshot['anchor_appkit']=dict(x=16 if name=='opened' else 20,y=1,w=8,h=18)
    return report,candidate,raw


class SidebarVerifierTests(unittest.TestCase):
    def check(self,report,candidate,raw):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'window-transcript.json').write_text(json.dumps(raw))
            validate(report,candidate,root)

    def test_normal_control(self):
        self.check(*fixture())

    def test_independent_corruptions(self):
        attacks={
            'label_changed':lambda r,c,w:r['observations'][2].update(label_hash=h('changed')),
            'tab_created':lambda r,c,w:r['observations'][2].update(tabs_count=3),
            'active_surface_changed':lambda r,c,w:r['observations'][2].update(active_surface=99),
            'selection_keeps_filter':lambda r,c,w:r['observations'][23].update(visible_mask='1'),
            'opened_anchor_not_advanced':lambda r,c,w:w[0]['opened']['anchor_appkit'].update(x=20),
            'closed_anchor_drift':lambda r,c,w:w[0]['closed']['anchor_appkit'].update(x=21),
            'wrong_schema':lambda r,c,w:r.update(schema='maru.rename-ime.v1'),
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
        self.assertEqual(len(attacks),26)
        for name,attack in attacks.items():
            r,c,w=fixture();attack(r,c,w)
            with self.subTest(attack=name), self.assertRaises(ValueError):self.check(r,c,w)


if __name__=='__main__':unittest.main()
