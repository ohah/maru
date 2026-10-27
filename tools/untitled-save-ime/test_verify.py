"""Synthetic controls distinguish state/file proof from actual GUI input."""
import json
import hashlib
import struct
import zlib
from pathlib import Path
import tempfile
import unittest
from verify import BODY, SENTINEL, CASES, h, validate_diagnostic


def fixture(root, scenario):
    project = root / 'project'; project.mkdir()
    saved = scenario in ('hanja', 'korean', 'overwrite')
    word = '한' if scenario == 'korean' else '韓'
    if saved or scenario == 'reject':
        (project / word).write_bytes(BODY if saved else SENTINEL)
    def row(name, text='', **changes):
        value = dict(name=name, surface_id=3, first_responder=True, terminal_bytes=0,
                     body_hash=h(BODY.decode()), untitled=1, dirty=1, navigate_pending=0,
                     target_hash=h(''), document_hash=h(text), document_bytes=len(text.encode()),
                     open=1, palette_owner=1, has_marked=False, confirm=0)
        value.update(changes); return value
    rows = [row('selected_fixture_0')]
    if scenario != 'korean':
        rows += [row('opened_0', '韓'), row('cancel_0', '한')]
    rows += [row('selected', word), row('filename_ready', word)]
    if scenario in ('overwrite', 'reject'):
        rows += [row('overwrite_prompt', confirm=1, open=0)]
    rows += [row('settled', open=0, untitled=int(not saved), dirty=int(not saved))]
    report = dict(schema='maru.untitled-first-save-ime.v1', passed=True, failures=[], scenario=scenario,
                  mode='diagnostic', pid=123, root=str(root), observations=rows, source_restored=True,
                  composition=[row(s,s) for s in ('ㅎ','하','한')])
    model = dict(schema='maru.untitled-first-save-model.v1', pid=123, surface_id=3,
                 body=BODY.decode(), untitled=not saved, dirty=not saved, pending=0,
                 path=str(project/word) if saved else None,
                 history_verified=True, notice=scenario == 'write-failure')
    (root/'model.json').write_text(json.dumps(model))
    report.update(main_window_id=10,candidate_window_id=11)
    (root/'captures').mkdir()
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    for label in ('filename','candidate','overwrite'):
        width,height=(89,266) if label=='candidate' else (128,128)
        data=(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+
              chunk(b'IDAT',zlib.compress((b'\0'+b'\x20\x40\x60'*width)*height))+chunk(b'IEND',b''))
        (root/'captures'/('native-'+label+'.png')).write_bytes(data)
        proof=dict(window_id=11 if label=='candidate' else 10,owner_pid=456 if label=='candidate' else 123,
                   sha256=hashlib.sha256(data).hexdigest())
        (root/'captures'/('native-'+label+'.json')).write_text(json.dumps(proof))
    return report, model


class FirstSaveOracleTests(unittest.TestCase):
    def test_normal_matrix(self):
        for scene in CASES:
            with self.subTest(scene=scene), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);report,_=fixture(root,scene)
                self.assertTrue(validate_diagnostic(report)['passed'])

    def test_record_corruptions(self):
        attacks = {
            'schema':lambda r,m:r.update(schema='other'),
            'passed':lambda r,m:r.update(passed=False),
            'failures':lambda r,m:r.update(failures=['source_restore']),
            'scene':lambda r,m:r.update(scenario='other'),
            'mode':lambda r,m:r.update(mode='live'),
            'pid':lambda r,m:r.update(pid=0),
            'source':lambda r,m:r.update(source_restored=False),
            'main_window':lambda r,m:r.update(main_window_id=99),
            'candidate_window':lambda r,m:r.update(candidate_window_id=10),
            'state_boolean':lambda r,m:r['observations'][1].update(untitled=True),
            'selected_missing':lambda r,m:r['observations'].pop(3),
            'surface':lambda r,m:r['observations'][0].update(surface_id=0),
            'owner':lambda r,m:r['observations'][1].update(first_responder=False),
            'terminal':lambda r,m:r['observations'][1].update(terminal_bytes=1),
            'body':lambda r,m:r['observations'][1].update(body_hash=h('changed')),
            'early_confirm':lambda r,m:r['observations'][1].update(confirm=1),
            'owner_loss':lambda r,m:r['observations'][1].update(palette_owner=0),
            'early_untitled':lambda r,m:r['observations'][1].update(untitled=0),
            'early_clean':lambda r,m:r['observations'][1].update(dirty=0),
            'early_pending':lambda r,m:r['observations'][1].update(navigate_pending=1),
            'early_path':lambda r,m:r['observations'][1].update(target_hash=h('韓')),
            'wrong_selection':lambda r,m:r['observations'][3].update(document_hash=h('한')),
            'marked_selection':lambda r,m:r['observations'][3].update(has_marked=True),
            'candidate':lambda r,m:r['observations'][1].update(name='other'),
            'composition':lambda r,m:r.update(composition=[]),
            'model_schema':lambda r,m:m.update(schema='other'),
            'model_pid':lambda r,m:m.update(pid=124),
            'model_surface':lambda r,m:m.update(surface_id=9),
            'model_body':lambda r,m:m.update(body='wrong'),
            'model_dirty':lambda r,m:m.update(dirty=True),
            'model_untitled':lambda r,m:m.update(untitled=True),
            'model_pending':lambda r,m:m.update(pending=1),
            'pending_boolean':lambda r,m:m.update(pending=False),
            'history':lambda r,m:m.update(history_verified=False),
            'path':lambda r,m:m.update(path='/other/韓'),
        }
        for name, attack in attacks.items():
            with self.subTest(attack=name), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);report,model=fixture(root,'hanja');attack(report,model)
                (root/'model.json').write_text(json.dumps(model))
                with self.assertRaises(ValueError):validate_diagnostic(report)

    def test_capture_corruptions(self):
        for attack in ('window', 'owner', 'hash', 'png', 'missing', 'restore_record'):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);report,_=fixture(root,'hanja')
                path=root/'captures/native-filename.json'
                record=json.loads(path.read_text())
                if attack=='window': record['window_id']=99
                if attack=='owner': record['owner_pid']=999
                if attack=='hash': record['sha256']='0'*64
                path.write_text(json.dumps(record))
                if attack=='png': (root/'captures/native-filename.png').write_bytes(b'bad')
                if attack=='missing': path.unlink()
                if attack=='restore_record': (root/'input-source.json').write_text('{}')
                with self.assertRaises((ValueError,FileNotFoundError)):validate_diagnostic(report)

    def test_disk_and_failed_state_controls(self):
        for scene in CASES:
            with self.subTest(scene=scene), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);report,model=fixture(root,scene)
                if scene in ('hanja','korean','overwrite','reject'):
                    next((root/'project').iterdir()).write_bytes(b'corrupt')
                elif scene=='cancel':
                    (root/'project'/'韓').write_bytes(BODY)
                else:
                    model['notice']=False;(root/'model.json').write_text(json.dumps(model))
                with self.assertRaises(ValueError):validate_diagnostic(report)


if __name__ == '__main__':unittest.main()
