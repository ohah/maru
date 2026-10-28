"""Synthetic input/wire/model controls, separate from real GUI and real SDK evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from verify import CASES,MAIN,OTHER,LOCAL,h,validate_diagnostic

spec=importlib.util.spec_from_file_location('symbol_capture_fixture',Path(__file__).resolve().parents[1]/'untitled-save-ime/test_verify.py')
shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)


def fixture(root,scene):
    r,_=shared.fixture(root,scene);project=root/'project'
    for path in project.iterdir():path.unlink()
    original=('// RENAMEFAIL\n' if scene=='server-error' else '')+MAIN
    (project/'main.c').write_text(original);(project/'other.c').write_text(OTHER)
    (root/'case.json').write_text(json.dumps(dict(scenario=scene,main=original,other=OTHER,root=str(project))))
    name='base한' if scene=='korean' else 'base韓';applied=scene in ('hanja','korean');sent=int(applied or scene=='server-error')
    r['schema']='maru.symbol-rename-ime.v1';rows=r['observations']
    for row in rows:
        row.update(untitled=0,dirty=0,body_hash=h(original),target_hash=h('base'),document_version=1,undo_len=0,
                   rename_sent=0,rename_done=0,rename_error=0,refused_stale=0)
        if row['name'] in ('selected','filename_ready'):row.update(document_hash=h(name),document_bytes=len(name.encode()))
    for row in r['composition']:row['document_hash']=h('base'+row['name'])
    final=rows.pop()
    if scene=='stale':
        invalid=copy.deepcopy(rows[-1]);invalid.update(name='invalidated',body_hash=h(LOCAL+original),document_version=2,undo_len=1,dirty=1);rows.append(invalid)
    final.update(rename_sent=sent,rename_done=int(applied),rename_error=int(scene=='server-error'),refused_stale=int(scene=='stale'),palette_owner=0)
    if applied:
        first=copy.deepcopy(final);first.update(name='applied',body_hash=h(original.replace(' base(',' '+name+'(')),document_version=2,undo_len=1);rows.append(first)
        final.update(name='undone',document_version=3,undo_len=2)
    rows.append(final)
    common=dict(schema='maru.symbol-rename-model.v1',pid=123,surface_id=9,path=str(project/'main.c'),pending=False,
                other_open=False,sent=sent,done=int(applied),errors=int(scene=='server-error'),refused_stale=int(scene=='stale'),
                applied_files=2 if applied else 0,saved_files=2 if applied else 0,undone_files=2 if applied else 0,
                notice=scene in ('server-error','stale'))
    common['surface_id']=rows[0]['surface_id']
    model=dict(common,body=LOCAL+original if scene=='stale' else original,main_disk=original,other_disk=OTHER,
               dirty=scene=='stale',undo_len=2 if applied else int(scene=='stale'),version=3 if applied else 2 if scene=='stale' else 1)
    if applied:model.update(applied_files=4,saved_files=4)
    (root/'model.json').write_text(json.dumps(model))
    changed_main=original.replace(' base(',' '+name+'(');changed_other=OTHER.replace('base()',name+'()')
    if applied:
        first=dict(common,body=changed_main,main_disk=changed_main,other_disk=changed_other,dirty=False,undo_len=1,undone_files=0,version=2)
        (root/'applied.json').write_text(json.dumps(first))
    records=[]
    def add(direction,**message):records.append(dict(direction=direction,message=dict(jsonrpc='2.0',**message)))
    add('client',id=1,method='initialize',params={})
    add('server',id=1,result=dict(capabilities=dict(renameProvider=True,positionEncoding='utf-16' if scene=='korean' else 'utf-8')))
    uris=[(project/'main.c').resolve().as_uri(),(project/'other.c').resolve().as_uri()]
    add('client',method='textDocument/didOpen',params=dict(textDocument=dict(uri=uris[0],version=1,text=original)))
    if sent:
        add('client',id=500000001,method='textDocument/rename',params=dict(textDocument=dict(uri=uris[0]),newName=name,position=dict(line=1 if scene=='server-error' else 0,character=4)))
        if scene=='server-error':add('server',id=500000001,error=dict(code=-32602,message='fake: cannot rename'))
        else:
            changes={}
            for uri,text in zip(uris,(original,OTHER)):
                start=text.index('base');changes[uri]=[dict(range=dict(start=dict(line=0,character=start),end=dict(line=0,character=start+4)),newText=name)]
            result=dict(changes=changes) if scene=='hanja' else dict(documentChanges=[dict(textDocument=dict(uri=uri,version=1 if index==0 else None),edits=changes[uri]) for index,uri in enumerate(uris)])
            add('server',id=500000001,result=result)
    (root/'wire.ndjson').write_text(''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in records))
    return r,model,records


def publish(root,model,records):
    (root/'model.json').write_text(json.dumps(model))
    (root/'wire.ndjson').write_text(''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in records))


class SymbolRenameOracleTests(unittest.TestCase):
    def test_normal_matrix(self):
        for scene in CASES:
            with self.subTest(scene=scene),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);r,*_=fixture(root,scene);self.assertTrue(validate_diagnostic(r)['passed'])

    def test_record_corruptions(self):
        attacks={
          'schema':lambda r,m,w:r.update(schema='other'),
          'failure':lambda r,m,w:r.update(passed=False),
          'restore':lambda r,m,w:r.update(source_restored=False),
          'pid':lambda r,m,w:r.update(pid=0),
          'surface':lambda r,m,w:r['observations'][0].update(surface_id=0),
          'responder':lambda r,m,w:r['observations'][1].update(first_responder=False),
          'terminal':lambda r,m,w:r['observations'][1].update(terminal_bytes=1),
          'early_body':lambda r,m,w:r['observations'][1].update(body_hash=h('changed')),
          'early_version':lambda r,m,w:r['observations'][1].update(document_version=2),
          'early_history':lambda r,m,w:r['observations'][1].update(undo_len=1),
          'early_request':lambda r,m,w:r['observations'][1].update(rename_sent=1),
          'early_pending':lambda r,m,w:r['observations'][1].update(navigate_pending=1),
          'early_clean':lambda r,m,w:r['observations'][1].update(dirty=1),
          'early_owner':lambda r,m,w:r['observations'][1].update(palette_owner=0),
          'selection':lambda r,m,w:r['observations'][3].update(document_hash=h('wrong')),
          'marked':lambda r,m,w:r['observations'][3].update(has_marked=True),
          'composition':lambda r,m,w:r.update(composition=[]),
          'candidate':lambda r,m,w:r['observations'][1].update(name='other'),
          'model_pid':lambda r,m,w:m.update(pid=124),
          'model_surface':lambda r,m,w:m.update(surface_id=10),
          'model_pending':lambda r,m,w:m.update(pending=True),
          'model_closed':lambda r,m,w:m.update(other_open=True),
          'model_sent':lambda r,m,w:m.update(sent=2),
          'model_path':lambda r,m,w:m.update(path='/other/main.c'),
          'undo_body':lambda r,m,w:m.update(body='wrong'),
          'undo_dirty':lambda r,m,w:m.update(dirty=True),
          'undo_history':lambda r,m,w:m.update(undo_len=0),
          'undo_count':lambda r,m,w:m.update(undone_files=1),
          'init':lambda r,m,w:w.pop(1),
          'wire_name':lambda r,m,w:w[3]['message']['params'].update(newName='base한'),
          'wire_position':lambda r,m,w:w[3]['message']['params'].update(position=dict(line=0,character=0)),
          'response':lambda r,m,w:w.pop(),
          'wire_edit':lambda r,m,w:next(iter(w[4]['message']['result']['changes'].values()))[0].update(newText='wrong'),
          'wire_uri':lambda r,m,w:w[3]['message']['params']['textDocument'].update(uri='file:///other/main.c'),
          'capability':lambda r,m,w:w[1]['message']['result']['capabilities'].update(renameProvider=False),
          'duplicate_request':lambda r,m,w:w.append(copy.deepcopy(w[3])),
          'opened_text':lambda r,m,w:w[2]['message']['params']['textDocument'].update(text='wrong'),
          'boolean_sent':lambda r,m,w:m.update(sent=True),
          'boolean_version':lambda r,m,w:r['observations'][1].update(document_version=True),
        }
        for name,attack in attacks.items():
            with self.subTest(attack=name),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);r,m,w=fixture(root,'hanja');attack(r,m,w);publish(root,m,w)
                with self.assertRaises(ValueError):validate_diagnostic(r)

    def test_disk_and_application_corruptions(self):
        for label in ('applied_body','applied_history','disk','stale_version','cancel_request','response_version','resource_operation'):
            with self.subTest(label=label),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);scene='stale' if label=='stale_version' else 'cancel' if label=='cancel_request' else 'korean' if label in ('response_version','resource_operation') else 'hanja';r,m,w=fixture(root,scene)
                if label.startswith('applied_'):
                    p=root/'applied.json';value=json.loads(p.read_text());value.update(body='wrong') if label=='applied_body' else value.update(undo_len=0);p.write_text(json.dumps(value))
                elif label=='disk':(root/'project/other.c').write_text('wrong')
                elif label=='stale_version':next(row for row in r['observations'] if row['name']=='invalidated')['document_version']=1
                elif label=='response_version':w[4]['message']['result']['documentChanges'][0]['textDocument']['version']=0;publish(root,m,w)
                elif label=='resource_operation':w[4]['message']['result']['documentChanges'].append(dict(kind='create',uri='file:///outside'));publish(root,m,w)
                else:w.append(dict(direction='client',message=dict(jsonrpc='2.0',id=500000001,method='textDocument/rename',params={})));publish(root,m,w)
                with self.assertRaises(ValueError):validate_diagnostic(r)


if __name__=='__main__':unittest.main()
