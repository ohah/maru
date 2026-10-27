"""Synthetic evidence controls; these are not native GUI or physical-input proof."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from save_as_lifecycle import Case, SOURCE, SENTINEL, canonical, png_proof, valid_name, verify


def png(path):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 128, 128, 8, 2, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress((b'\0'+b'\x33\x66\x99'*128)*128)) + chunk(b'IEND', b''))


def fixture(root, case):
    p=root/'project';p.mkdir();a=root/'artifacts';a.mkdir()
    (p/SOURCE).write_bytes(b'foo')
    if not case.cancelled or case.existing:
        (p/case.name).write_bytes(SENTINEL if case.cancelled else case.saved_body)
    panel=dict(pid=123,window_id=100,panel_id=101,name_before=SOURCE,directory=str(p))
    action=dict(pid=123,requested_name=case.name,name_before=SOURCE,name_after=case.name,finished=True,
                main_cancelled=case.cancelled,replace_seen=case.existing and case.scenario!='cancel',
                overwrite_choice=case.overwrite,input_mode=case.input_mode,keys=[],restoration='not-needed')
    if case.input_mode!='ax':
        action.update(keys=[5,40,1,124] if case.input_mode=='korean' else [5,40,1,36,36],restoration='restored',
                      typed_hangul='한',typed_word='한' if case.input_mode=='korean' else '韓')
    model=dict(schema='maru.save-as-model.v1',pid=123,path=str(p/(SOURCE if case.cancelled else case.name)),
               pending=0,body=case.model_body,dirty=case.cancelled or case.scenario=='edit-during-write',
               surface_id=9,history_verified=True)
    capture=dict(window_id=101,owner_pid=123)
    for label in ('save-as-panel','save-as-name','save-as-overwrite'):
        png(a/(label+'.png'));capture[label]=png_proof(a/(label+'.png'))
    records=dict(panel=panel,action=action,model=model,capture=capture)
    publish(root, records)
    return records


def publish(root, records):
    for key,value in records.items():
        name={'panel':'panel-state','action':'action','model':'model','capture':'capture-proof'}[key]
        (root/'artifacts'/('save-as-'+name+'.json')).write_text(json.dumps(value))


class SaveAsLifecycleTests(unittest.TestCase):
    def test_valid_file_names_and_options(self):
        for name in ('한.txt','韓.txt','한.txt','a b.txt','plain.txt'):
            self.assertEqual(name,valid_name(name))
        for name in ('','.', '..','a/b','a\\b','a:b','a\n','a\0',SOURCE,SOURCE.upper(),'x'*129):
            with self.subTest(name=name),self.assertRaises(ValueError): valid_name(name)
        for options in (dict(overwrite='cancel'),dict(input_mode='hanja',name='한.txt'),dict(input_mode='other'),dict(scenario='other'),dict(existing=1),dict(physical_body=1),dict(scenario='edit-during-write',existing=True,overwrite='cancel')):
            with self.assertRaises(ValueError):Case(**options)

    def test_normal_matrix(self):
        cases=[Case(name=n,scenario=s,existing=e,overwrite=o)
               for n in ('한.txt','韓.txt','한.txt')
               for s,e,o in (('save',False,'accept'),('cancel',False,'accept'),('save',True,'accept'),('save',True,'cancel'),('cancel',True,'accept'))]
        cases += [Case(name='한.txt',input_mode='korean'),Case(name='韓.txt',input_mode='hanja'),Case(scenario='edit-during-write'),Case(physical_body=True)]
        for case in cases:
            with self.subTest(case=case),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);fixture(root,case);self.assertTrue(verify(root,case,123)['passed'])

    def test_independent_record_corruptions(self):
        attacks={
            'model_schema':lambda r:r['model'].update(schema='other'),
            'model_pid':lambda r:r['model'].update(pid=124),
            'model_pending':lambda r:r['model'].update(pending=1),
            'pending_bool':lambda r:r['model'].update(pending=False),
            'no_surface':lambda r:r['model'].update(surface_id=0),
            'history_unproven':lambda r:r['model'].update(history_verified=False),
            'wrong_body':lambda r:r['model'].update(body='foo'),
            'wrong_dirty':lambda r:r['model'].update(dirty=True),
            'wrong_path':lambda r:r['model'].update(path='/other/韓.txt'),
            'source_adopted':lambda r:r['model'].update(path=r['panel']['directory']+'/'+SOURCE),
            'panel_pid':lambda r:r['panel'].update(pid=124),
            'panel_directory':lambda r:r['panel'].update(directory='/other'),
            'panel_initial_name':lambda r:r['panel'].update(name_before='other.txt'),
            'panel_no_id':lambda r:r['panel'].update(panel_id=0),
            'capture_window_swap':lambda r:r['capture'].update(window_id=999),
            'capture_no_owner':lambda r:r['capture'].update(owner_pid=0),
            'capture_hash':lambda r:r['capture']['save-as-name'].update(sha256='0'*64),
            'capture_size':lambda r:r['capture']['save-as-name'].update(width=129),
            'action_pid':lambda r:r['action'].update(pid=124),
            'wrong_requested_name':lambda r:r['action'].update(requested_name='한.txt'),
            'wrong_field_value':lambda r:r['action'].update(name_after='한.txt'),
            'not_finished':lambda r:r['action'].update(finished=False),
            'wrong_cancellation':lambda r:r['action'].update(main_cancelled=True),
            'no_replace_prompt':lambda r:r['action'].update(replace_seen=False),
            'wrong_replace_choice':lambda r:r['action'].update(overwrite_choice='cancel'),
            'mode_swap':lambda r:r['action'].update(input_mode='ax'),
            'fake_hangul':lambda r:r['action'].update(typed_hangul='gks'),
            'wrong_hanja':lambda r:r['action'].update(typed_word='한'),
            'no_real_keys':lambda r:r['action'].update(keys=[]),
            'source_not_restored':lambda r:r['action'].update(restoration='superseded'),
        }
        case=Case(name='韓.txt',existing=True,input_mode='hanja')
        for name,attack in attacks.items():
            with self.subTest(name=name),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);records=fixture(root,case);attack(records);publish(root,records)
                with self.assertRaises(ValueError):verify(root,case,123)

    def test_disk_and_artifact_corruptions(self):
        attacks=(
            lambda root:(root/'project'/SOURCE).write_bytes(b'changed'),
            lambda root:(root/'project'/'韓.txt').write_bytes(b'wrong'),
            lambda root:(root/'artifacts'/'save-as-name.png').write_bytes(b'bad'),
            lambda root:(root/'project'/'韓.txt').unlink(),
        )
        case=Case(name='韓.txt')
        for attack in attacks:
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory);fixture(root,case);attack(root)
                with self.assertRaises((ValueError,FileNotFoundError)):verify(root,case,123)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);case=Case(name='韓.txt',scenario='cancel');fixture(root,case)
            (root/'project'/case.name).write_bytes(b'foo!')
            with self.assertRaises(ValueError):verify(root,case,123)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);case=Case(name='韓.txt',existing=True,overwrite='cancel');fixture(root,case)
            (root/'project'/case.name).write_bytes(b'overwritten')
            with self.assertRaises(ValueError):verify(root,case,123)

    def test_symlink_destination_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);case=Case(name='韓.txt');fixture(root,case)
            target=root/'project'/case.name;target.unlink()
            try:
                target.symlink_to(SOURCE)
            except (OSError, NotImplementedError) as error:
                self.skipTest(f'symlink creation unavailable: {error}')
            with self.assertRaises(ValueError):verify(root,case,123)

if __name__=='__main__':unittest.main()
