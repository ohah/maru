"""Synthetic judge controls; they prove rejection logic and make no pixel claim."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate,h,validate_diagnostic
source=load('activity_fixture_source',Path(__file__).resolve().parents[1]/'address-ime/test_verify.py')


def fixture(detached=False):
    r,c,raw=source.fixture(prefix='',suffix='',initial_word='',owner_shift=54)
    r.update(schema='maru.activity-search-ime.v1',detached=detached,input_window_id=51 if detached else 50,owner_window_id=50,glyph_advances={'한':10.,'韓':10.})
    c['schema']='maru.activity-search-ime-candidate.v1'
    for row in r['observations']+r['composition']:
        row.update(window_key=True,label_hash=h('printf 한'),tabs_count=1,active_workspace=0,active_surface=77,window_id=r['input_window_id'],title_row=0,filter_key_hash=h(''))
        if row['name'].startswith('opened_'):row.update(query_hash=h('한'),query_bytes=3)
        if row['name'].startswith(('han_','cancel_','opened_')):row.update(title_row=1,filter_key_hash=h('overview.title'))
    end=r['observations'][-1]
    end.update(query_hash=h('韓'),query_bytes=3,window_id=50)
    for row in r['observations']+r['composition']:
        row.update(body_query_hash=h(''),body_answered=0,body_matches=0,body_read_bytes=0,activity_focus=1)
    body=copy.deepcopy(end)
    body.update(name='body_applied',terminal_bytes=0)
    r['observations'].insert(-1,body)
    for row in (body,end):row.update(navigate_pending=1,body_query_hash=h('韓'),body_answered=1,body_matches=1,body_read_bytes=100)
    end['activity_focus']=0
    r['pointer_observations']=[dict(passed=True,kind='pointer',action='click',target='terminal',generation='0',events=2,pid=77)]
    for triplet in raw:
        triplet['opened']['search'].update(query_hash=int(h('한')),query_bytes=3)
        for name,snapshot in triplet.items():
            snapshot['anchor_appkit']=dict(x=20,y=1,w=8,h=18)
            for id in (50,51) if detached else (50,):
                snapshot['windows'].append(dict(id=id,layer=0,on_screen=True,owner=dict(pid=77,bundle_id='dev.maru.apphost',signing_id='dev.maru.apphost',apple_signed=False),bounds=dict(x=0,y=0,w=640,h=480)))
    return r,c,raw


class ActivityJudgeTests(unittest.TestCase):
    def check(self,r,c,raw):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'window-transcript.json').write_text(json.dumps(raw));validate(r,c,root)

    def test_normal_control(self):self.check(*fixture())

    def test_diagnostic_separation(self):
        r,c,raw=fixture();r.update(mode='diagnostic',window_inventory_validated=False)
        validate_diagnostic(r)
        with self.assertRaises(ValueError):self.check(r,c,raw)

    def test_independent_corruptions(self):
        attacks={
            'schema':lambda r,c,w:r.update(schema='unknown'),
            'owner_namespace':lambda r,c,w:r['observations'][0].update(owner_generation=str(1<<55)),
            'owner_replay':lambda r,c,w:r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'preview_query':lambda r,c,w:r['observations'][2].update(query_hash=h('韓')),
            'preview_filter':lambda r,c,w:r['observations'][2].update(title_row=0),
            'cancel_query':lambda r,c,w:r['observations'][3].update(query_hash=h('')),
            'cancel_filter':lambda r,c,w:r['observations'][3].update(title_row=0),
            'query_bytes':lambda r,c,w:r['observations'][3].update(query_bytes=2),
            'pty_leak':lambda r,c,w:r['composition'][1].update(terminal_bytes=1),
            'early_worker':lambda r,c,w:r['observations'][2].update(navigate_pending=1),
            'early_body_answer':lambda r,c,w:r['observations'][2].update(body_answered=1),
            'early_body_read':lambda r,c,w:r['observations'][2].update(body_read_bytes=1),
            'body_query':lambda r,c,w:r['observations'][-2].update(body_query_hash=h('한')),
            'body_no_read':lambda r,c,w:r['observations'][-2].update(body_read_bytes=0),
            'body_no_match':lambda r,c,w:r['observations'][-2].update(body_matches=0),
            'body_lost_focus':lambda r,c,w:r['observations'][-2].update(activity_focus=0),
            'terminal_no_click':lambda r,c,w:r.update(pointer_observations=[]),
            'terminal_wrong_click':lambda r,c,w:r['pointer_observations'][0].update(target='address'),
            'terminal_stale_click':lambda r,c,w:r['pointer_observations'][0].update(generation='1'),
            'terminal_wrong_pid':lambda r,c,w:r['pointer_observations'][0].update(pid=78),
            'terminal_no_input':lambda r,c,w:r['observations'][-1].update(terminal_bytes=0),
            'terminal_focus':lambda r,c,w:r['observations'][-1].update(activity_focus=1),
            'surface':lambda r,c,w:r['observations'][3].update(active_surface=78),
            'fixture_label':lambda r,c,w:r['observations'][0].update(label_hash=h('fake')),
            'responder':lambda r,c,w:r['observations'][1].update(first_responder=False),
            'raw_hash':lambda r,c,w:w[0]['opened']['search'].update(query_hash=0),
            'capture_swap':lambda r,c,w:c['rows'][0].update(app_capture=c['rows'][1]['app_capture']),
            'window_replay':lambda r,c,w:c['rows'][1].update(window_id=c['rows'][0]['window_id']),
            'composition_missing':lambda r,c,w:r['composition'].pop(),
            'caret_wrong':lambda r,c,w:r['geometry'][1].update(x=10),
        }
        for name,attack in attacks.items():
            r,c,w=fixture();attack(r,c,w)
            with self.subTest(name=name),self.assertRaises(ValueError):self.check(r,c,w)

if __name__=='__main__':unittest.main()
