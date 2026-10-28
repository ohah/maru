"""Synthetic real-server provenance and legal response forms; never actual SDK proof."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from test_verify import fixture,publish
from verify import MAIN,OTHER,validate_diagnostic
from server import prepare_clangd,describe_clangd


def real_fixture(root,scene='hanja',documents=False):
    report,model,wire=fixture(root,scene)
    server=dict(kind='clangd',path='/synthetic/clangd',sha256='a'*64,version='clangd version synthetic')
    case=json.loads((root/'case.json').read_text());case.update(server=server,other='int base(void);\n'+OTHER)
    (root/'case.json').write_text(json.dumps(case));(root/'server.json').write_text(json.dumps(server))
    (root/'proxy.json').write_text(json.dumps(dict(argv=[server['path'],'--background-index','--log=verbose'],server_environment={})))
    (root/'project/other.c').write_text(case['other']);model['other_disk']=case['other']
    wire[1]['message']['result']['serverInfo']=dict(name='clangd',version=server['version'])
    wire[1]['message']['result']['capabilities']['renameProvider']={}
    if scene in ('hanja','korean'):
        name='base韓' if scene=='hanja' else 'base한';result=wire[4]['message']['result']
        changes=result.get('changes') or {item['textDocument']['uri']:item['edits'] for item in result['documentChanges']}
        uri=(root/'project/other.c').resolve().as_uri()
        def edit(line,start):return dict(range=dict(start=dict(line=line,character=start),end=dict(line=line,character=start+4)),newText=name)
        changes[uri]=[edit(0,4),edit(1,27)]
        wire[4]['message']['result']=dict(documentChanges=[dict(textDocument=dict(uri=u,version=1 if u.endswith('/main.c') else None),edits=e) for u,e in changes.items()]) if documents else dict(changes=changes)
        applied=json.loads((root/'applied.json').read_text());applied['other_disk']=case['other'].replace('base(',name+'(')
        (root/'applied.json').write_text(json.dumps(applied))
    publish(root,model,wire)
    return report,model,wire


class RealServerControls(unittest.TestCase):
    def test_legal_sdk_forms(self):
        for scene in ('hanja','korean','cancel','stale'):
            for documents in (False,True):
                with self.subTest(scene=scene,documents=documents),tempfile.TemporaryDirectory() as directory:
                    root=Path(directory);r,*_=real_fixture(root,scene,documents)
                    self.assertEqual(validate_diagnostic(r)['server'],'clangd')

    def test_twenty_distinct_real_server_corruptions(self):
        labels=('unknown_kind','missing_version','wrong_version','relative_binary','bad_hash','missing_manifest','manifest_hash',
                'wrong_argv','fake_environment','missing_info','wrong_name','wire_version','disabled_capability','invalid_capability',
                'missing_closed_file','extra_uri','wrong_closed_edit','ambiguous_edit','closed_save','closed_undo')
        for label in labels:
            with self.subTest(label=label),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);r,m,w=real_fixture(root);case=json.loads((root/'case.json').read_text())
                server=case['server'];result=w[4]['message']['result'];changes=result['changes'];uri=(root/'project/other.c').resolve().as_uri()
                if label=='unknown_kind':server['kind']='fake'
                elif label=='missing_version':server.pop('version')
                elif label=='wrong_version':server['version']='other'
                elif label=='relative_binary':server['path']='clangd'
                elif label=='bad_hash':server['sha256']='z'*64
                elif label=='missing_manifest':(root/'server.json').unlink()
                elif label=='manifest_hash':(root/'server.json').write_text(json.dumps(dict(server,sha256='b'*64)))
                elif label in ('wrong_argv','fake_environment'):
                    p=root/'proxy.json';v=json.loads(p.read_text())
                    if label=='wrong_argv':v['argv'][0]='/other/fake-lsp'
                    else:v['server_environment']['MARU_FAKE_LSP_UTF16']='1'
                    p.write_text(json.dumps(v))
                elif label=='missing_info':w[1]['message']['result'].pop('serverInfo')
                elif label=='wrong_name':w[1]['message']['result']['serverInfo']['name']='fake'
                elif label=='wire_version':w[1]['message']['result']['serverInfo']['version']='clangd version other'
                elif label in ('disabled_capability','invalid_capability'):w[1]['message']['result']['capabilities']['renameProvider']=False if label=='disabled_capability' else []
                elif label=='missing_closed_file':changes.pop(uri)
                elif label=='extra_uri':changes['file:///unowned.c']=copy.deepcopy(changes[uri])
                elif label=='wrong_closed_edit':changes[uri][1]['newText']='wrong'
                elif label=='ambiguous_edit':result['documentChanges']=[]
                elif label=='closed_save':
                    p=root/'applied.json';v=json.loads(p.read_text());v['other_disk']=case['other'];p.write_text(json.dumps(v))
                elif label=='closed_undo':m['other_disk']='wrong'
                (root/'case.json').write_text(json.dumps(case));publish(root,m,w)
                with self.assertRaises((ValueError,FileNotFoundError)):validate_diagnostic(r)

    def test_compilation_database_is_owned_and_canonical(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);prepare_clangd(root)
            commands=json.loads((root/'compile_commands.json').read_text())
            self.assertEqual({c['file'] for c in commands},{str(root.resolve()/name) for name in ('main.c','other.c')})
            self.assertTrue(all(c['directory']==str(root.resolve()) and '-std=c11' in c['arguments'] for c in commands))
            with self.assertRaises(ValueError):describe_clangd('relative/clangd')


if __name__=='__main__':unittest.main()
