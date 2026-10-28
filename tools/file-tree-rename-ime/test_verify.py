"""Synthetic proof corruption controls; actual GUI runs remain separate evidence."""
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path
import tempfile
import unittest
from verify import BODY,SOURCE,SENTINEL,CASES,h,validate_diagnostic

spec=importlib.util.spec_from_file_location('first_save_control_fixture',Path(__file__).resolve().parents[1]/'untitled-save-ime/test_verify.py')
shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)


def fixture(root,scene):
    report,model=shared.fixture(root,scene)
    project=root/'project'
    for p in project.iterdir():p.unlink()
    source=project/'base';source.write_bytes(SOURCE);info=source.stat()
    setup=dict(inode=info.st_ino,device=info.st_dev,source_sha256=hashlib.sha256(SOURCE).hexdigest())
    changed=scene in ('hanja','korean');name='base한' if scene=='korean' else 'base韓'
    before=dict(pid=123,inode=info.st_ino,source_sha256=setup['source_sha256'],
                names=['base','base韓'] if scene=='collision' else ['base'],
                destination_sha256=hashlib.sha256(SENTINEL).hexdigest() if scene=='collision' else None)
    if scene=='collision':(project/'base韓').write_bytes(SENTINEL)
    if changed:source.rename(project/name)
    report['schema']='maru.file-tree-rename-ime.v1'
    for row in report['observations']:
        row.update(untitled=1,dirty=1,target_hash=h(name if row['name']=='settled' and changed else 'base'))
        if row['name'] in ('selected','filename_ready'):
            row.update(document_hash=h(name),document_bytes=len(name.encode()))
    for row in report['composition']:row['document_hash']=h('base'+row['name'])
    model.update(schema='maru.file-tree-rename-model.v1',path=None,untitled=True,dirty=True,
                 selected_path=str(project/(name if changed else 'base')),notice=scene in ('collision','write-failure'))
    for label,value in (('model',model),('setup',setup),('before-commit',before)):
        (root/(label+'.json')).write_text(json.dumps(value))
    after=dict(pid=123,root=str(root),files=[dict(name=p.name,device=p.stat().st_dev,inode=p.stat().st_ino,
        sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in project.iterdir()])
    (root/'after-identity.json').write_text(json.dumps(after))
    return report,model,before,setup


class FileTreeRenameOracleTests(unittest.TestCase):
    def test_normal_matrix(self):
        for scene in CASES:
            with self.subTest(scene=scene),tempfile.TemporaryDirectory() as d:
                root=Path(d);report,*_=fixture(root,scene);self.assertTrue(validate_diagnostic(report)['passed'])

    def test_copied_artifact_identity_proof(self):
        with tempfile.TemporaryDirectory() as d:
            source=Path(d)/'original';source.mkdir();r,*_=fixture(source,'hanja')
            copied=Path(d)/'copy';shutil.copytree(source,copied)
            self.assertTrue(validate_diagnostic(r,copied)['passed'])
            after=json.loads((copied/'after-identity.json').read_text());after['files'][0]['inode']+=1
            (copied/'after-identity.json').write_text(json.dumps(after))
            with self.assertRaises(ValueError):validate_diagnostic(r,copied)

    def test_record_corruptions(self):
        attacks={
          'schema':lambda r,m,b,s:r.update(schema='other'),
          'failed_gui':lambda r,m,b,s:r.update(passed=False),
          'source_restore':lambda r,m,b,s:r.update(source_restored=False),
          'pid':lambda r,m,b,s:r.update(pid=124),
          'surface':lambda r,m,b,s:r['observations'][0].update(surface_id=0),
          'owner':lambda r,m,b,s:r['observations'][1].update(first_responder=False),
          'terminal':lambda r,m,b,s:r['observations'][1].update(terminal_bytes=1),
          'body':lambda r,m,b,s:r['observations'][1].update(body_hash=h('changed')),
          'early_pending':lambda r,m,b,s:r['observations'][1].update(navigate_pending=1),
          'early_target':lambda r,m,b,s:r['observations'][1].update(target_hash=h('base韓')),
          'early_confirm':lambda r,m,b,s:r['observations'][1].update(confirm=1),
          'early_owner':lambda r,m,b,s:r['observations'][1].update(palette_owner=0),
          'composition':lambda r,m,b,s:r.update(composition=[]),
          'wrong_name':lambda r,m,b,s:r['observations'][3].update(document_hash=h('base한')),
          'selected_marked':lambda r,m,b,s:r['observations'][3].update(has_marked=True),
          'candidate':lambda r,m,b,s:r['observations'][1].update(name='other'),
          'pre_inode':lambda r,m,b,s:b.update(inode=0),
          'pre_hash':lambda r,m,b,s:b.update(source_sha256='0'*64),
          'pre_names':lambda r,m,b,s:b.update(names=['base韓']),
          'pre_dest':lambda r,m,b,s:b.update(destination_sha256='0'*64),
          'setup_hash':lambda r,m,b,s:s.update(source_sha256='0'*64),
          'model_pid':lambda r,m,b,s:m.update(pid=124),
          'model_surface':lambda r,m,b,s:m.update(surface_id=5),
          'model_body':lambda r,m,b,s:m.update(body='wrong'),
          'model_clean':lambda r,m,b,s:m.update(dirty=False),
          'model_named':lambda r,m,b,s:m.update(untitled=False),
          'model_path':lambda r,m,b,s:m.update(path='/other'),
          'model_pending':lambda r,m,b,s:m.update(pending=1),
          'model_bool_pending':lambda r,m,b,s:m.update(pending=False),
          'selected_path':lambda r,m,b,s:m.update(selected_path='/other/base韓'),
          'candidate_capture':lambda r,m,b,s:r.update(candidate_window_id=r['main_window_id']),
        }
        for name,attack in attacks.items():
            with self.subTest(attack=name),tempfile.TemporaryDirectory() as d:
                root=Path(d);r,m,b,s=fixture(root,'hanja');attack(r,m,b,s)
                for label,value in (('model',m),('before-commit',b),('setup',s)):(root/(label+'.json')).write_text(json.dumps(value))
                with self.assertRaises(ValueError):validate_diagnostic(r)

    def test_disk_and_notice_corruptions(self):
        for scene in CASES:
            with self.subTest(scene=scene),tempfile.TemporaryDirectory() as d:
                root=Path(d);r,m,*_=fixture(root,scene)
                if scene in ('hanja','korean'):
                    path=next((root/'project').iterdir());data=path.read_bytes()
                    # Keep the old inode live while creating its replacement, so reuse cannot mask it.
                    replacement=root/'other';replacement.write_bytes(data);replacement.replace(path)
                elif scene=='collision':(root/'project/base韓').write_bytes(b'overwritten')
                elif scene=='cancel':(root/'project/base').write_bytes(b'changed')
                else:m['notice']=False;(root/'model.json').write_text(json.dumps(m))
                with self.assertRaises(ValueError):validate_diagnostic(r)


if __name__=='__main__':unittest.main()
