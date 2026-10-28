"""Independent controlled-server GUI/wire/model/disk oracle; not real SDK evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import stat


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


TOOLS=Path(__file__).resolve().parents[1]
base=load('symbol_capture_oracle',TOOLS/'untitled-save-ime/verify.py')
wire_oracle=load('symbol_wire_application',TOOLS/'editor-lsp-real/oracle.py')
h,need,regular,capture=base.h,base.need,base.regular,base.capture
CASES=('hanja','korean','cancel','server-error','stale')
SENTINEL=base.SENTINEL
MAIN='int base(void) { return 41; }\nint baseline = 0;\n'
OTHER='int consume(void) { return base(); }\n'
LOCAL='// local change\n'
BODY=MAIN.encode()


def validate_diagnostic(report,artifact_root=None):
    need(report['schema']=='maru.symbol-rename-ime.v1' and report['passed'] is True and report['failures']==[],'failed GUI')
    scene=report['scenario'];need(scene in CASES and report['mode']=='diagnostic','scene')
    need(type(report['pid']) is int and report['pid']>0 and report['source_restored'] is True,'process/source')
    root=Path(artifact_root or report['root']);case=json.loads(regular(root/'case.json'))
    original=('// RENAMEFAIL\n' if scene=='server-error' else '')+MAIN
    need(case['scenario']==scene and case['main']==original and case['other']==OTHER,'fixture')
    name='base한' if scene=='korean' else 'base韓';applied=scene in ('hanja','korean')
    rows=report['observations'];initial=rows[0];surface=initial['surface_id']
    need(type(surface) is int and surface>0,'surface')
    selected=[r for r in rows if r['name']=='selected'];ready=[r for r in rows if r['name']=='filename_ready']
    need(len(selected)==len(ready)==1,'missing/duplicate selection')
    pre=[]
    for row in rows:
        need(all(type(row[k]) is int and row[k]>=0 for k in ('surface_id','terminal_bytes','document_version','undo_len','rename_sent','rename_done','rename_error','refused_stale','untitled','dirty','navigate_pending','open','palette_owner')), 'state types')
        need(row['surface_id']==surface and row['first_responder'] is True and row['terminal_bytes']==initial['terminal_bytes'],'owner/terminal')
        if row['name'] not in ('applied','undone','settled','invalidated'):
            pre.append(row)
            need(row['body_hash']==h(original) and row['document_version']==initial['document_version'] and row['undo_len']==0,'early document edit')
            need(row['rename_sent']==0 and row['navigate_pending']==0 and row['rename_done']==0,'early request')
            need(row['open']==1 and row['palette_owner']==1 and row['untitled']==0 and row['dirty']==0 and row['target_hash']==h('base'),'early owner mutation')
    for row in selected+ready:
        need(row['document_hash']==h(name) and row['document_bytes']==len(name.encode()) and row['has_marked'] is False,'selected name')
    for syllable in ('ㅎ','하','한'):
        need(any(r['name']==syllable and r['document_hash']==h('base'+syllable) for r in report['composition']),'physical composition')
    if scene!='korean':need(all(any(r['name'].startswith(p) for r in pre) for p in ('opened_','cancel_')),'candidate transitions')
    need(not(root/'input-source.json').exists(),'source restore pending')
    captures={'filename':capture(root,'filename',report['main_window_id'],report['pid'])}
    if scene!='korean':
        need(report['candidate_window_id']!=report['main_window_id'],'candidate window')
        captures['candidate']=capture(root,'candidate',report['candidate_window_id'])
    path=root/'wire.ndjson';info=path.lstat()
    need(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=4*1024*1024,'unsafe wire')
    records=[json.loads(line) for line in path.read_text().splitlines() if line]
    initializations=[r['message'] for r in records if r['direction']=='client' and r['message'].get('method')=='initialize']
    need(len(initializations)==1,'initialization count')
    init_id=initializations[0]['id']
    capabilities=[r['message']['result']['capabilities'] for r in records if r['direction']=='server' and r['message'].get('id')==init_id and 'result' in r['message']]
    need(len(capabilities)==1 and capabilities[0].get('renameProvider') is True,'rename capability')
    encoding=capabilities[0].get('positionEncoding','utf-16');need(encoding in ('utf-8','utf-16'),'position encoding')
    requests=[r['message'] for r in records if r['direction']=='client' and r['message'].get('method')=='textDocument/rename']
    need(all(row.get('direction') in ('client','server') and isinstance(row.get('message'),dict) and row['message'].get('jsonrpc')=='2.0' for row in records),'wire shape')
    expected_sent=1 if applied or scene=='server-error' else 0
    need(len(requests)==expected_sent,'rename request count')
    original_project=Path(report['root'])/'project'
    need(Path(case['root']).resolve()==original_project.resolve(), 'fixture root')
    main_uri=(original_project/'main.c').resolve().as_uri();other_uri=(original_project/'other.c').resolve().as_uri()
    opens=[r['message']['params']['textDocument'] for r in records if r['direction']=='client' and r['message'].get('method')=='textDocument/didOpen']
    need(len(opens)==1 and opens[0]['uri']==main_uri and opens[0]['text']==original and type(opens[0]['version']) is int and opens[0]['version']==ready[0]['document_version'],'opened document/version')
    if requests:
        request=requests[0];need(type(request['id']) is int and request['params']['newName']==name and request['params']['textDocument']['uri']==main_uri,'rename request payload')
        need(request['params']['position']==dict(line=1 if scene=='server-error' else 0,character=4),'rename position')
        responses=[r['message'] for r in records if r['direction']=='server' and r['message'].get('id')==request['id']]
        need(len(responses)==1,'rename response')
        if scene=='server-error':need(isinstance(responses[0].get('error'),dict),'server error missing')
        else:
            result=responses[0].get('result');need(isinstance(result,dict),'workspace edit missing')
            edits={}
            if 'changes' in result:
                need(scene=='hanja','unexpected edit shape');edits=result['changes']
            else:
                need(scene=='korean' and isinstance(result.get('documentChanges'),list),'documentChanges shape')
                for item in result['documentChanges']:
                    need('kind' not in item and isinstance(item.get('textDocument'),dict),'resource operation')
                    td=item['textDocument'];need(td['uri'] not in edits,'duplicate document')
                    version=td.get('version')
                    need((type(version) is int and version==ready[0]['document_version']) if td['uri']==main_uri else version is None,'response version')
                    edits[td['uri']]=item['edits']
            need(set(edits)=={main_uri,other_uri},'unowned/missing edits')
            renamed_main=original.replace(' base(', ' '+name+'(')
            renamed_other=OTHER.replace('base()',name+'()')
            for uri,before,after in ((main_uri,original,renamed_main),(other_uri,OTHER,renamed_other)):
                need(wire_oracle.apply_edits(before,edits[uri],encoding)==after,'wire edit differs')
    model=json.loads(regular(root/'model.json'))
    def common(m):
        need(all(type(m[k]) is int and m[k]>=0 for k in ('pid','surface_id','sent','done','errors','refused_stale','applied_files','saved_files','undone_files','undo_len','version')), 'model counter types')
        need(m['schema']=='maru.symbol-rename-model.v1' and m['pid']==report['pid'] and m['surface_id']==surface,'model identity')
        need(m['pending'] is False and m['other_open'] is False and m['sent']==expected_sent,'pending/closed file/sent')
        need(Path(m['path']).resolve()==(original_project/'main.c').resolve(),'document path')
    common(model)
    if applied:
        first=json.loads(regular(root/'applied.json'));common(first)
        need(first['body']==renamed_main and first['main_disk']==renamed_main and first['other_disk']==renamed_other and first['dirty'] is False,'applied content/save')
        need(first['version']>ready[0]['document_version'] and model['version']>first['version'], 'apply/Undo version')
        need(first['applied_files']==first['saved_files']==2 and first['undo_len']==1 and first['done']==1 and first['undone_files']==0,'applied history/counts')
        need(model['body']==original and model['main_disk']==original and model['other_disk']==OTHER and model['dirty'] is False and model['undo_len']==first['undo_len']+1 and model['undone_files']==2,'workspace Undo')
        need(model['applied_files']==model['saved_files']==4 and model['done']==1 and model['errors']==model['refused_stale']==0, 'Undo bookkeeping')
        need(sum(r['name']=='applied' for r in rows)==sum(r['name']=='undone' for r in rows)==1,'applied/undone stage')
    else:
        need(not(root/'applied.json').exists() and model['applied_files']==model['saved_files']==model['undone_files']==0,'unexpected apply')
        wanted=LOCAL+original if scene=='stale' else original
        need(model['body']==wanted and model['main_disk']==original and model['other_disk']==OTHER and model['dirty'] is (scene=='stale'),'preserved document')
        need(model['undo_len']==int(scene=='stale') and model['version']>=ready[0]['document_version'], 'preserved history/version')
        need(model['errors']==int(scene=='server-error') and model['refused_stale']==int(scene=='stale'),'error/refusal')
        if scene=='stale':
            invalid=[r for r in rows if r['name']=='invalidated'];need(len(invalid)==1 and invalid[0]['document_version']>ready[0]['document_version'],'stale invalidation absent')
    need(regular(root/'project/main.c').decode()==original and regular(root/'project/other.c').decode()==OTHER,'final disk')
    return dict(passed=True,scenario=scene,rename_requests=len(requests),workspace_undo=applied,captures=captures,server='controlled fixture, not SDK')


def validate(*args,**kwargs):raise ValueError('No shared live/OCR claim for this scene')
