"""Independent closed-file rename identity, input boundary and disk oracle."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unicodedata

spec=importlib.util.spec_from_file_location('first_save_evidence',Path(__file__).resolve().parents[1]/'untitled-save-ime/verify.py')
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
h,need,regular,capture=base.h,base.need,base.regular,base.capture
BODY=base.BODY
SOURCE=b'rename source\n'
SENTINEL=base.SENTINEL
CASES=('hanja','korean','cancel','collision','write-failure')


def validate_diagnostic(report,artifact_root=None):
    need(report['schema']=='maru.file-tree-rename-ime.v1' and report['passed'] is True and report['failures']==[], 'failed GUI')
    scene=report['scenario'];need(scene in CASES and report['mode']=='diagnostic','scene')
    need(type(report['pid']) is int and report['pid']>0 and report['source_restored'] is True,'process/source')
    rows=report['observations'];initial=rows[0];surface=initial['surface_id']
    need(type(surface) is int and surface>0,'surface')
    chosen=[r for r in rows if r['name']=='selected'];ready=[r for r in rows if r['name']=='filename_ready'];settled=[r for r in rows if r['name']=='settled']
    need(len(chosen)==len(ready)==len(settled)==1,'missing/duplicate stage')
    name='base한' if scene=='korean' else 'base韓';changed=scene in ('hanja','korean')
    for row in rows:
        need(row['surface_id']==surface and row['first_responder'] is True,'owner')
        need(row['body_hash']==h(BODY.decode()) and row['terminal_bytes']==initial['terminal_bytes'],'unrelated content')
        need(type(row['untitled']) is int and row['untitled']==1 and type(row['dirty']) is int and row['dirty']==1,'unrelated document')
        need(type(row['navigate_pending']) is int and row['navigate_pending']==0,'pending mutation')
        if row['name']!='settled':
            need(row['open']==1 and row['palette_owner']==1 and row['confirm']==0 and row['target_hash']==h('base'),'early mutation')
    for row in chosen+ready:
        need(row['document_hash']==h(name) and row['document_bytes']==len(name.encode()) and row['has_marked'] is False,'filename')
    for syllable in ('ㅎ','하','한'):
        need(any(r['name']==syllable and r['document_hash']==h('base'+syllable) for r in report['composition']),'physical composition')
    if scene!='korean':
        need(all(any(r['name'].startswith(prefix) for r in rows) for prefix in ('opened_','cancel_')),'candidate transitions')
    need(settled[0]['open']==0 and settled[0]['target_hash']==h(name if changed else 'base'),'settled selection')
    root=Path(artifact_root or report['root']);project=root/'project'
    need(not(root/'input-source.json').exists(),'source restore pending')
    captures={'filename':capture(root,'filename',report['main_window_id'],report['pid'])}
    if scene!='korean':
        need(report['candidate_window_id']!=report['main_window_id'],'candidate window')
        captures['candidate']=capture(root,'candidate',report['candidate_window_id'])
    setup=json.loads(regular(root/'setup.json'));before=json.loads(regular(root/'before-commit.json'));model=json.loads(regular(root/'model.json'))
    need(type(setup['inode']) is int and setup['inode']>0 and type(setup['device']) is int,'fixture identity')
    source_hash=hashlib.sha256(SOURCE).hexdigest();sentinel_hash=hashlib.sha256(SENTINEL).hexdigest()
    need(setup['source_sha256']==source_hash and before['pid']==report['pid'] and before['inode']==setup['inode'] and before['source_sha256']==source_hash,'source changed before confirmation')
    names_before=sorted(unicodedata.normalize('NFC',n) for n in before['names'])
    need(names_before==(['base','base韓'] if scene=='collision' else ['base']),'early filesystem mutation')
    need(before['destination_sha256']==(sentinel_hash if scene=='collision' else None),'early destination write')
    need(model['schema']=='maru.file-tree-rename-model.v1' and model['pid']==report['pid'] and model['surface_id']==surface,'model identity')
    need(model['path'] is None and model['untitled'] is True and model['dirty'] is True and model['body'].encode()==BODY,'unrelated model')
    need(type(model['pending']) is int and model['pending']==0,'model pending')
    expected=name if changed else 'base';path=Path(model['selected_path'])
    need(path.parent.resolve()==(Path(report['root'])/'project').resolve() and unicodedata.normalize('NFC',path.name)==expected,'selected path')
    files=list(project.iterdir());by_name={unicodedata.normalize('NFC',p.name):p for p in files}
    need(len(files)==len(by_name) and set(by_name)==({expected,'base韓'} if scene=='collision' else {expected}),'filesystem names')
    need(regular(by_name[expected])==SOURCE,'source bytes')
    after=json.loads(regular(root/'after-identity.json'))
    need(after['pid']==report['pid'] and Path(after['root']).resolve()==Path(report['root']).resolve(),'after-record provenance')
    after_files={unicodedata.normalize('NFC',row['name']):row for row in after['files']}
    need(len(after_files)==len(after['files']) and set(after_files)==set(by_name),'after-record names')
    identity=after_files[expected]
    need(identity['device']==setup['device'] and identity['inode']==setup['inode'] and identity['sha256']==source_hash,'rename replaced source identity')
    for key,path in by_name.items():need(hashlib.sha256(regular(path)).hexdigest()==after_files[key]['sha256'],'copied artifact bytes changed')
    if artifact_root is None:
        # The original runtime check uses actual stat. Copies necessarily have different inodes;
        # their offline proof binds captured original identity to the copied bytes instead.
        info=by_name[expected].stat()
        need(info.st_dev==setup['device'] and info.st_ino==setup['inode'],'live source identity')
    if scene=='collision':need(regular(by_name['base韓'])==SENTINEL,'collision overwritten')
    if scene in ('collision','write-failure'):need(model['notice'] is True,'failure not reported')
    return dict(scenario=scene,passed=True,renamed=changed,raw_names=[p.name for p in files],captures=captures)


def validate(*args,**kwargs):raise ValueError('No shared live/OCR claim for this scene')
