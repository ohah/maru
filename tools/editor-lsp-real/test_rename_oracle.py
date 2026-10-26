"""Independent synthetic controls; these are not real SDK execution evidence."""
import copy
from pathlib import Path
import tempfile
import unittest

from oracle import InvalidEvidence
from rename_fixture import make_case, fixture
from rename_oracle import verify


def golden(language='rust', shape='documentChanges'):
    c = make_case(Path('/owned/rename'), language, 'a' * 32)
    files = c['files']
    uris = [Path(f['path']).as_uri() for f in files]
    wire = []
    def message(direction, **m):
        wire.append(dict(direction=direction, message=dict(jsonrpc='2.0', **m)))
    def notify(method, **params):
        message('client', method=method, params=params)
    def change(i, version, text):
        notify('textDocument/didChange', textDocument=dict(uri=uris[i], version=version), contentChanges=[dict(text=text)])
    def save(i):
        notify('textDocument/didSave', textDocument=dict(uri=uris[i]))
    def pos(text, at):
        prefix = text[:at]
        return dict(line=prefix.count('\n'), character=len(prefix.rsplit('\n', 1)[-1].encode('utf-16-le')) // 2)
    def rename(identity, version):
        message('client', id=identity, method='textDocument/rename', params=dict(textDocument=dict(uri=uris[0]), newName=c['new_name'], position=pos(c['good'], c['good'].index('produce'))))
        changes = {}
        for uri, f in zip(uris, files):
            at = f['good'].index('produce')
            changes[uri] = [dict(range=dict(start=pos(f['good'], at), end=pos(f['good'], at + 7)), newText='renamed_produce')]
        result = dict(changes=changes) if shape == 'changes' else dict(documentChanges=[dict(textDocument=dict(uri=u, version=version if i < 2 else None), edits=changes[u]) for i, u in enumerate(uris)])
        message('server', id=identity, result=result)
    message('client', id=1, method='initialize', params=dict(rootUri=Path(c['root']).as_uri()))
    message('server', id=1, result=dict(capabilities=dict(renameProvider=True, positionEncoding='utf-16')))
    notify('initialized')
    for i in range(2):
        notify('textDocument/didOpen', textDocument=dict(uri=uris[i], version=1, text=files[i]['good']))
    message('client', id=200000001, method='textDocument/definition', params=dict(textDocument=dict(uri=uris[0]), position=pos(c['good'], c['good'].index('produce')+2)))
    at = files[1]['good'].index('produce')
    message('server', id=200000001, result=[dict(uri=uris[1], range=dict(start=pos(files[1]['good'], at), end=pos(files[1]['good'], at+7)))])
    rename(500000001, 1)
    for i in range(2):
        change(i, 2, files[i]['renamed']); save(i)
    for i in range(2):
        change(i, 3, files[i]['good']); save(i)
    rename(500000002, 3)
    change(0, 4, c['local'])
    change(0, 5, c['good']); save(0)
    # The peer version remains 3 for the last request.
    rename(500000003, 5)
    if shape == 'documentChanges':
        wire[-1]['message']['result']['documentChanges'][1]['textDocument']['version'] = 3
    samples = []
    for phase in ('before', 'applied', 'undone', 'stale', 'rejected'):
        for i, f in enumerate(files):
            disk = f['renamed'] if phase == 'applied' else f['good']
            text = c['local'] if phase == 'stale' and i == 0 else disk
            version = dict(before=1, applied=2, undone=3, stale=4 if i == 0 else 3, rejected=5 if i == 0 else 3)[phase]
            undo = dict(before=0, applied=1, undone=2, stale=3 if i == 0 else 2, rejected=4 if i == 0 else 2)[phase]
            samples.append(dict(phase=phase, path=f['path'], disk=disk, buffer=text if i < 2 else None,
                                version=version if i < 2 else None, undo_len=undo if i < 2 else None,
                                dirty=(phase == 'stale' and i == 0) if i < 2 else None))
    n = dict(schema='maru.lsp-real.product.v1', scenario='rename', language=language, stage='complete', failure=None,
             result=dict(stage='complete', failure=None, request_ids=[500000001, 500000002, 500000003], samples=samples,
                         applied_files=3, saved_files=3, record_files=3, undone_files=3, stale_refusals=1, rejected_refusals=1,
                         baseline_definition=True, stale_response_observed=True, rejected_response_observed=True, closed_missing_at_apply=True))
    return c, n, wire


class RenameOracleTests(unittest.TestCase):
    def test_normal_profiles_and_both_edit_shapes(self):
        for lang in ('rust', 'go'):
            for shape in ('changes', 'documentChanges'):
                with self.subTest(lang=lang, shape=shape):
                    c,n,w = golden(lang, shape)
                    if lang == 'go' and shape == 'documentChanges':
                        for row in w:
                            m = row['message']
                            if row['direction']=='server' and isinstance(m.get('result'), dict) and 'documentChanges' in m['result']:
                                m['result']['documentChanges'][2]['textDocument']['version']=0
                    self.assertTrue(verify(c,n,w)['rename'])

    def test_fixture_ownership_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'case'
            c = fixture(root, 'rust')
            self.assertIn('\"produce\"', c['files'][0]['renamed'])
            self.assertIn('produce_extra', c['files'][1]['renamed'])
            self.assertIn('// produce in this comment stays unchanged.', c['files'][1]['renamed'])
            for f in c['files']:
                self.assertEqual(Path(f['path']).read_text(), f['good'])
            with self.assertRaises(FileExistsError):
                fixture(root, 'rust')

    def test_damaged_evidence(self):
        attacks = [
            ('no baseline definition', lambda c,n,w: n['result'].update(baseline_definition=False)),
            ('nested incomplete', lambda c,n,w: n['result'].update(stage='ready')),
            ('bad scenario', lambda c,n,w: n.update(scenario='single-file')),
            ('bad language', lambda c,n,w: n.update(language='go')),
            ('incomplete', lambda c,n,w: n.update(stage='rename_apply')),
            ('failure', lambda c,n,w: n.update(failure='failed')),
            ('applied count', lambda c,n,w: n['result'].update(applied_files=2)),
            ('saved count', lambda c,n,w: n['result'].update(saved_files=2)),
            ('record count', lambda c,n,w: n['result'].update(record_files=2)),
            ('undo count', lambda c,n,w: n['result'].update(undone_files=2)),
            ('boolean count', lambda c,n,w: n['result'].update(stale_refusals=True)),
            ('no stale', lambda c,n,w: n['result'].update(stale_refusals=0)),
            ('no rejection', lambda c,n,w: n['result'].update(rejected_refusals=0)),
            ('unobserved stale', lambda c,n,w: n['result'].update(stale_response_observed=False)),
            ('unobserved rejection', lambda c,n,w: n['result'].update(rejected_response_observed=False)),
            ('closed not removed', lambda c,n,w: n['result'].update(closed_missing_at_apply=False)),
            ('duplicate IDs', lambda c,n,w: n['result'].update(request_ids=[500000001]*3)),
            ('missing sample', lambda c,n,w: n['result']['samples'].pop()),
            ('wrong saved bytes', lambda c,n,w: n['result']['samples'][3].update(disk=c['good'])),
            ('closed opened', lambda c,n,w: n['result']['samples'][5].update(buffer='opened')),
            ('wrong undo', lambda c,n,w: n['result']['samples'][6].update(buffer='bad')),
            ('stale overwritten', lambda c,n,w: n['result']['samples'][9].update(buffer=c['good'])),
            ('partial rejected', lambda c,n,w: n['result']['samples'][12].update(buffer='partially applied')),
            ('two undo entries', lambda c,n,w: n['result']['samples'][3].update(undo_len=2)),
            ('boolean version', lambda c,n,w: n['result']['samples'][0].update(version=True)),
            ('renamed still dirty', lambda c,n,w: n['result']['samples'][3].update(dirty=True)),
            ('missing definition response', lambda c,n,w: w.__setitem__(slice(None), [x for x in w if x['message'].get('id') != 200000001 or x['direction'] != 'server'])),
            ('missing real response', lambda c,n,w: w.__setitem__(slice(None), [x for x in w if x['message'].get('id') != 500000001 or x['direction'] != 'server'])),
            ('empty real response', lambda c,n,w: next(x['message'] for x in w if x['direction']=='server' and x['message'].get('id')==500000002).update(result={})),
            ('closed boolean version', lambda c,n,w: next(x['message']['result']['documentChanges'] for x in w if x['direction']=='server' and x['message'].get('id')==500000001)[2]['textDocument'].update(version=True)),
            ('outside response URI', lambda c,n,w: next(x['message']['result']['documentChanges'] for x in w if x['direction']=='server' and x['message'].get('id')==500000001)[2]['textDocument'].update(uri='file:///outside/other.rs')),
            ('wrong response version', lambda c,n,w: next(x['message']['result']['documentChanges'] for x in w if x['direction']=='server' and x['message'].get('id')==500000001)[0]['textDocument'].update(version=99)),
            ('resource operation', lambda c,n,w: next(x['message']['result']['documentChanges'] for x in w if x['direction']=='server' and x['message'].get('id')==500000001).append(dict(kind='create',uri='file:///owned/rename/new.rs'))),
            ('overlapping edits', lambda c,n,w: next(x['message']['result']['documentChanges'] for x in w if x['direction']=='server' and x['message'].get('id')==500000001)[0]['edits'].__imul__(2)),
            ('missing closed edit', lambda c,n,w: next(x['message']['result']['documentChanges'] for x in w if x['direction']=='server' and x['message'].get('id')==500000001).pop()),
            ('wrong new name', lambda c,n,w: next(x['message']['params'] for x in w if x['message'].get('method')=='textDocument/rename').update(newName='other')),
            ('missing main change', lambda c,n,w: w.__setitem__(slice(None), [x for x in w if not (x['message'].get('method')=='textDocument/didChange' and x['message']['params']['textDocument'].get('version')==2 and x['message']['params']['textDocument']['uri'].endswith('main.rs'))])),
            ('missing save', lambda c,n,w: w.__setitem__(slice(None), [x for x in w if x['message'].get('method')!='textDocument/didSave'])),
        ]
        for label, attack in attacks:
            with self.subTest(label=label):
                c,n,w = golden()
                attack(c,n,w)
                with self.assertRaises(InvalidEvidence):
                    verify(c,n,w)

    def test_later_manual_save_cannot_prove_undo_autosave(self):
        c,n,w = golden()
        uri = Path(c['path']).as_uri()
        version = 1
        kept = []
        for row in w:
            m = row['message']; p = m.get('params', {})
            if m.get('method') == 'textDocument/didChange' and p['textDocument']['uri'] == uri:
                version = p['textDocument']['version']
            if m.get('method') == 'textDocument/didSave' and p['textDocument']['uri'] == uri and version == 3:
                continue
            kept.append(row)
        with self.assertRaises(InvalidEvidence):
            verify(c,n,kept)


if __name__ == '__main__':
    unittest.main()
