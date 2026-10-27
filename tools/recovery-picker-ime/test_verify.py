"""Synthetic judge controls, separate from OS input or pixel evidence."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate, validate_diagnostic, h, FIXTURE, TARGET, RECOVERED
source=load('recovery_address_fixture',Path(__file__).resolve().parents[1]/'address-ime/test_verify.py')


def fixture():
    r,c,raw=source.fixture(prefix='',suffix='',initial_word='',owner_shift=51)
    r.update(schema='maru.recovery-picker-ime.v1',detached=False,input_window_id=50,owner_window_id=50,glyph_advances={'한':10.,'韓':10.})
    c['schema']='maru.recovery-picker-ime-candidate.v1'
    for row in r['observations']+r['composition']:
        row.update(window_key=True,window_id=50,tabs_count=1,active_workspace=0,active_surface=77,title_row=1,
                   file_hash=h(FIXTURE),file_bytes=len(FIXTURE.encode()),revision=0,editor_focus=0,history_count=0,target_offset=TARGET,recovered_dirty=0)
        if row['name'].startswith('opened_'):row.update(query_hash=h('한'),query_bytes=3)
    end=r['observations'][-1]
    end.update(name='editor_input',window_id=50,active_surface=78,terminal_bytes=0,query_hash=h('韓'),query_bytes=3,navigate_pending=1,history_count=1,revision=1,
               file_hash=h('/'+RECOVERED),file_bytes=len(RECOVERED.encode())+1,editor_focus=1,target_offset=1,recovered_dirty=1)
    nav=copy.deepcopy(end);nav.update(name='restored',revision=0,file_hash=h(RECOVERED),file_bytes=len(RECOVERED.encode()),editor_focus=0,target_offset=0,recovered_dirty=1)
    r['observations'].insert(-1,nav)
    owner=r['observations'][20]['owner_generation']
    r['input_receipts']=[dict(phase=phase,id=i+31,passed=True,kind='key',events=2,keycode=code,flags=0,generation=g,pid=77)
                         for i,(phase,code,g) in enumerate(zip(('candidate_return','restore_return','notice_escape','editor_slash'),(36,36,53,44),(owner,owner,'0','0')))]
    for triplet in raw:
        triplet['opened']['search'].update(query_hash=int(h('한')),query_bytes=3)
        for snap in triplet.values():
            snap['anchor_appkit']=dict(x=20,y=1,w=8,h=18)
            snap['windows'].append(dict(id=50,layer=0,on_screen=True,owner=dict(pid=77,bundle_id='dev.maru.apphost',signing_id='dev.maru.apphost',apple_signed=False),bounds=dict(x=0,y=0,w=640,h=480)))
    return r,c,raw


class ReferenceJudgeTests(unittest.TestCase):
    def check(self,r,c,w):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'window-transcript.json').write_text(json.dumps(w));validate(r,c,root)

    def test_normal(self):self.check(*fixture())

    def test_diagnostic_separation(self):
        r,c,w=fixture();r.update(mode='diagnostic',window_inventory_validated=False)
        validate_diagnostic(r)
        with self.assertRaises(ValueError):self.check(r,c,w)

    def test_corruptions(self):
        attacks={
            'schema':lambda r,c,w:r.update(schema='unknown'),
            'owner_namespace':lambda r,c,w:r['observations'][0].update(owner_generation=str(1<<53)),
            'owner_replay':lambda r,c,w:r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'preview_query':lambda r,c,w:r['observations'][2].update(query_hash=h('韓')),
            'preview_filter':lambda r,c,w:r['observations'][2].update(title_row=0),
            'cancel_query':lambda r,c,w:r['observations'][3].update(query_hash=h('')),
            'cancel_filter':lambda r,c,w:r['observations'][3].update(title_row=0),
            'partial_bytes':lambda r,c,w:r['observations'][3].update(query_bytes=2),
            'pty_composition_leak':lambda r,c,w:r['composition'][1].update(terminal_bytes=1),
            'premature_navigation':lambda r,c,w:r['observations'][2].update(navigate_pending=1),
            'candidate_navigation':lambda r,c,w:r['observations'][23].update(history_count=1),
            'candidate_document_edit':lambda r,c,w:r['observations'][23].update(revision=1),
            'preview_document_edit':lambda r,c,w:r['observations'][2].update(file_hash=h('changed')),
            'preview_selection':lambda r,c,w:r['observations'][2].update(editor_focus=1),
            'restore_dirty':lambda r,c,w:r['observations'][-2].update(recovered_dirty=0),
            'restore_no_document':lambda r,c,w:r['observations'][-2].update(history_count=0),
            'navigation_changes_document':lambda r,c,w:r['observations'][-2].update(file_hash=h('changed')),
            'editor_no_edit':lambda r,c,w:r['observations'][-1].update(revision=0),
            'editor_wrong_edit':lambda r,c,w:r['observations'][-1].update(file_hash=h(FIXTURE)),
            'editor_wrong_caret':lambda r,c,w:r['observations'][-1].update(editor_focus=TARGET),
            'editor_pty_leak':lambda r,c,w:r['observations'][-1].update(terminal_bytes=1),
            'missing_receipt':lambda r,c,w:r['input_receipts'].pop(),
            'wrong_key':lambda r,c,w:r['input_receipts'][-1].update(keycode=36),
            'wrong_pid':lambda r,c,w:r['input_receipts'][-1].update(pid=78),
            'receipt_replay':lambda r,c,w:r['input_receipts'][1].update(id=r['input_receipts'][0]['id']),
            'receipt_stale_generation':lambda r,c,w:r['input_receipts'][-1].update(generation='1'),
            'receipt_no_delivery':lambda r,c,w:r['input_receipts'][-1].update(passed=False),
            'receipt_wrong_flags':lambda r,c,w:r['input_receipts'][0].update(flags=1<<20),
            'restored_surface_reuse':lambda r,c,w:r['observations'][-2].update(active_surface=77),
            'editor_surface_switch':lambda r,c,w:r['observations'][-1].update(active_surface=79),
            'surface':lambda r,c,w:r['observations'][3].update(active_surface=78),
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
