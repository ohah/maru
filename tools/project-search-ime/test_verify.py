"""Synthetic adversarial evidence controls; these never claim actual pixels."""
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate, h, CONTENT
source = load('project_search_fixture_source', Path(__file__).resolve().parents[1] / 'address-ime/test_verify.py')


def fixture(index=0):
    report,candidate,raw = source.fixture(prefix='',suffix='',initial_word='',owner_shift=58)
    report.update(schema='maru.project-search-ime.v1',target_field=index,tabs=[])
    candidate['schema']='maru.project-search-ime-candidate.v1'
    for pos,row in enumerate(report['observations']):
        row.update(field_index=index,file_hash=h(CONTENT*2),file_bytes=30,composing=0,complete=1,request_active=1,result_generation=str(100+pos),filter_count=2 if index in (1,2) else 4)
        cycle=min(pos//4,5)
        row['owner_generation']=str((1<<58)+100+cycle*4)
        if row['name'].startswith('selected_fixture_'):
            row.update(filter_count=0 if index==0 else 4,complete=0 if index==0 else 1)
        if row['name'].startswith('opened_') and index != 3:
            row.update(composing=1,complete=0,request_active=0,filter_count=0)
        row.update(query_input_hash=h('한') if index else row['query_hash'],query_input_bytes=3 if index else row['query_bytes'])
    report['observations'][-1].update(owner_generation='0',field_index=99)
    for pos,row in enumerate(report['composition']):
        row.update(field_index=index,file_hash=h(CONTENT*2),file_bytes=30,composing=0,complete=1,request_active=1,result_generation=str(100+pos),filter_count=4 if index==3 else 0)
        row['owner_generation']=str((1<<58)+100+(pos//3)*4)
        row.update(query_input_hash=h('한') if index else row['query_hash'],query_input_bytes=3 if index else row['query_bytes'])
    route=[] if index==0 else [(0,3)] if index==3 else [(0,3),(3,1)] if index==1 else [(0,3),(3,1),(1,2)]
    for i in range(6):
        owner=(1<<58)+100+i*4
        for j,(a,b) in enumerate(route):
            report['tabs'].append(dict(cycle=i,**{'from':a,'to':b},ack_id=i*16+j+1,generation=str(owner-len(route)+j+1)))
        if i<5:
            for snap in raw[i].values():snap['search']['owner_generation']=owner
    return report,candidate,raw


class ProjectSearchVerifierTests(unittest.TestCase):
    def check(self,r,c,w,change_file=False):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'window-transcript.json').write_text(json.dumps(w))
            files=root/'ime-search-root';files.mkdir()
            for name in ('한','韓'):(files/name).write_text(CONTENT)
            if change_file:(files/'한').write_text('wrong')
            validate(r,c,root)

    def test_all_four_normal_controls(self):
        for index in range(4):
            with self.subTest(field=index):self.check(*fixture(index))

    def test_independent_corruptions(self):
        attacks={
            'schema':lambda r,c,w:r.update(schema='maru.find-ime.v1'),
            'owner_domain':lambda r,c,w:r['observations'][0].update(owner_generation=str(1<<59)),
            'owner_reuse':lambda r,c,w:r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'field_changed':lambda r,c,w:r['observations'][2].update(field_index=3),
            'preview_keeps_results':lambda r,c,w:r['observations'][2].update(filter_count=4),
            'preview_keeps_request':lambda r,c,w:r['observations'][2].update(request_active=1),
            'preview_not_composing':lambda r,c,w:r['observations'][2].update(composing=0),
            'generation_not_invalidated':lambda r,c,w:r['observations'][2].update(result_generation=r['observations'][1]['result_generation']),
            'preview_wrong_word':lambda r,c,w:r['observations'][2].update(document_hash=h('한')),
            'cancel_not_restored':lambda r,c,w:r['observations'][3].update(query_hash=h('韓')),
            'selection_not_committed':lambda r,c,w:r['observations'][23].update(query_hash=h('한')),
            'file_changed':lambda r,c,w:r['observations'][23].update(file_hash=h('changed')),
            'apply_started':lambda r,c,w:r['observations'][2].update(navigate_pending=1),
            'focus_lost':lambda r,c,w:r['observations'][1].update(first_responder=False),
            'composition_terminal_leak':lambda r,c,w:r['composition'][0].update(terminal_bytes=1),
            'cancel_marked':lambda r,c,w:r['observations'][3].update(has_marked=True),
            'terminal_not_restored':lambda r,c,w:r['observations'][-1].update(terminal_bytes=0),
            'anchor_outside':lambda r,c,w:r['geometry'][0].update(x=1000),
            'anchor_backwards':lambda r,c,w:r['geometry'][1].update(x=0),
            'window_reuse':lambda r,c,w:c['rows'][1].update(window_id=c['rows'][0]['window_id']),
            'raw_owner':lambda r,c,w:w[0]['opened']['search'].update(owner_generation=1),
            'raw_text':lambda r,c,w:w[0]['opened']['search'].update(query_hash=1),
            'raw_screen':lambda r,c,w:w[0]['opened']['counters'].update(base_screen_generation=99),
            'wrong_source':lambda r,c,w:c.update(source_id='com.apple.keylayout.ABC'),
        }
        for name,attack in attacks.items():
            r,c,w=fixture();attack(r,c,w)
            with self.subTest(attack=name),self.assertRaises(ValueError):self.check(r,c,w)

    def test_missing_physical_tab_route(self):
        r,c,w=fixture(2);r['tabs'].pop()
        with self.assertRaises(ValueError):self.check(r,c,w)

    def test_replacement_never_changes_search_query(self):
        r,c,w=fixture(3);r['observations'][2]['query_input_hash']=h('韓')
        with self.assertRaises(ValueError):self.check(r,c,w)

    def test_files_are_independently_read(self):
        with self.assertRaises(ValueError):self.check(*fixture(),change_file=True)


if __name__=='__main__':unittest.main()
