"""Synthetic judge controls; they prove rejection logic and make no pixel claim."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate,h,validate_diagnostic
source=load('inspector_fixture_source',Path(__file__).resolve().parents[1]/'address-ime/test_verify.py')


def fixture(detached=False):
    r,c,raw=source.fixture(prefix='',suffix='',initial_word='',owner_shift=55)
    r.update(schema='maru.inspector-search-ime.v1',detached=detached,input_window_id=51 if detached else 50,owner_window_id=50,glyph_advances={'한':10.,'韓':6.})
    c['schema']='maru.inspector-search-ime-candidate.v1'
    for row in r['observations']+r['composition']:
        row.update(window_key=True,label_hash=h('한'),tabs_count=1,active_workspace=0,active_surface=77,window_id=r['input_window_id'],title_row=0,filter_key_hash=h(''))
        if row['name'].startswith('opened_'):row.update(query_hash=h('한'),query_bytes=3)
        if row['name'].startswith(('han_','cancel_')):row.update(title_row=1,filter_key_hash=h('overview.title'))
    end=r['observations'][-1]
    end.update(query_hash=h('韓' if detached else ''),query_bytes=3 if detached else 0,window_id=50)
    for triplet in raw:
        triplet['opened']['search'].update(query_hash=int(h('한')),query_bytes=3)
        for name,snapshot in triplet.items():
            snapshot['anchor_appkit']=dict(x=16 if name=='opened' else 20,y=1,w=8,h=18)
            for id in (50,51) if detached else (50,):
                snapshot['windows'].append(dict(id=id,layer=0,on_screen=True,owner=dict(pid=77,bundle_id='dev.maru.apphost',signing_id='dev.maru.apphost',apple_signed=False),bounds=dict(x=0,y=0,w=640,h=480)))
    return r,c,raw


class InspectorJudgeTests(unittest.TestCase):
    def check(self,r,c,raw):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'window-transcript.json').write_text(json.dumps(raw));validate(r,c,root)

    def test_both_scene_normal_controls(self):
        for detached in (False,True):
            with self.subTest(detached=detached):self.check(*fixture(detached))

    def test_independent_corruptions(self):
        attacks={
            'wrong_schema':lambda r,c,w:r.update(schema='unknown'),
            'wrong_owner':lambda r,c,w:r['observations'][0].update(owner_generation=str(1<<56)),
            'replayed_owner':lambda r,c,w:r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'preview_publishes':lambda r,c,w:r['observations'][2].update(query_hash=h('韓')),
            'preview_keeps_title':lambda r,c,w:r['observations'][2].update(title_row=1),
            'preview_reuses_row':lambda r,c,w:r['observations'][2].update(filter_key_hash=h('overview.title')),
            'cancel_loses_title':lambda r,c,w:r['observations'][3].update(title_row=0),
            'cancel_loses_query':lambda r,c,w:r['observations'][3].update(query_hash=h('')),
            'partial_bytes':lambda r,c,w:r['observations'][3].update(query_bytes=2),
            'terminal_leak':lambda r,c,w:r['composition'][1].update(terminal_bytes=1),
            'inspector_action':lambda r,c,w:r['observations'][2].update(navigate_pending=1),
            'surface_changed':lambda r,c,w:r['observations'][3].update(active_surface=78),
            'extra_workspace':lambda r,c,w:r['observations'][0].update(tabs_count=2),
            'responder_lost':lambda r,c,w:r['observations'][1].update(first_responder=False),
            'selected_not_committed':lambda r,c,w:r['observations'][23].update(query_hash=h('한')),
            'still_marked':lambda r,c,w:r['observations'][3].update(has_marked=True),
            'terminal_window_wrong':lambda r,c,w:r['observations'][-1].update(window_id=51),
            'scene_swapped':lambda r,c,w:r.update(detached=True),
            'input_window_not_key':lambda r,c,w:r['observations'][1].update(window_key=False),
            'input_window_swapped':lambda r,c,w:r['observations'][1].update(window_id=51),
            'raw_owner_spoof':lambda r,c,w:w[0]['before']['windows'][0]['owner'].update(pid=88),
            'raw_query_spoof':lambda r,c,w:w[0]['opened']['search'].update(query_hash=int(h('韓'))),
            'raw_counter_spoof':lambda r,c,w:w[0]['closed']['counters'].update(pty_input_bytes=1),
            'wrong_source':lambda r,c,w:c.update(source_id='unknown'),
            'preview_anchor_stale':lambda r,c,w:w[0]['opened']['anchor_appkit'].update(x=20),
            'anchor_outside':lambda r,c,w:r['geometry'][0].update(field_w=1),
        }
        for name,attack in attacks.items():
            with self.subTest(attack=name):
                r,c,w=fixture();attack(r,c,w)
                with self.assertRaises(ValueError):self.check(r,c,w)

    def test_diagnostic_cannot_claim_pixels(self):
        r,c,w=fixture();r.update(mode='diagnostic',window_inventory_validated=False);validate_diagnostic(r)
        with self.assertRaises(ValueError):self.check(r,c,w)
