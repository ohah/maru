"""Rename archives retain their own controller/tool inventory and scenario."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock
from types import SimpleNamespace

import run
from oracle import InvalidEvidence
from test_rename_oracle import golden
from verify import verify_run


class RenameArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        c,n,w = golden()
        n['build_mode'] = 'debug'
        case = self.root / 'case-rust'
        case.mkdir()
        sources = self.root / 'sources'
        sources.mkdir()
        n['source_fingerprints'] = []
        for name in ('rename_judge.zig','real_lsp_judge.zig','mod.zig','lsp.zig','completion.zig','hover.zig','definition.zig','semantic.zig','rename.zig','workspace_edit.zig'):
            data = ('compiled unit fixture '+name).encode()
            (sources/name).write_bytes(data)
            n['source_fingerprints'].append(dict(name=name,sha256=hashlib.sha256(data).hexdigest()))
        (case/'case.json').write_text(json.dumps(c))
        (case/'product.json').write_text(json.dumps(n))
        (case/'wire.ndjson').write_text(''.join(json.dumps(x)+'\n' for x in w))
        (case/'protocol.ndjson').write_text('')
        (case/'judge.log').write_text('unit archive; not actual SDK execution')
        (case/'server.stderr').write_text('')
        (self.root/'judge').write_text('unit executable fixture')
        tools = self.root/'tool-sources'
        tools.mkdir()
        for name in ('run.py','oracle.py','verify.py','lsp_proxy.py','rename_fixture.py','rename_oracle.py'):
            (tools/name).write_text('unit tool '+name)
        sha = lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
        self.report = dict(schema='maru.lsp-real.run.v1',scenario='rename',optimize='Debug',judge_sha256=sha(self.root/'judge'),
                           tool_sources={p.name:sha(p) for p in tools.iterdir()},
                           languages=[dict(language='rust',exit_code=0,artifacts={p.name:sha(p) for p in case.iterdir()})])
        self.save()

    def save(self):
        (self.root/'result.json').write_text(json.dumps(self.report))

    def test_normal_ten_controller_archive(self):
        self.assertEqual(verify_run(self.root)['rust']['compiled_controller_sources'],10)

    def test_missing_rename_tool(self):
        del self.report['tool_sources']['rename_oracle.py']
        self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_wrong_scenario(self):
        self.report['scenario'] = 'multi-file'
        self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_missing_controller(self):
        p=self.root/'case-rust/product.json';n=json.loads(p.read_text())
        n['source_fingerprints'].pop()
        p.write_text(json.dumps(n))
        self.report['languages'][0]['artifacts']['product.json']=hashlib.sha256(p.read_bytes()).hexdigest()
        self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_stale_workspace_edit_source(self):
        (self.root/'sources/workspace_edit.zig').write_text('stale source')
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_wrong_language(self):
        self.report['languages'][0]['language']='go'
        (self.root/'case-rust').rename(self.root/'case-go')
        self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_failed_product_exit(self):
        self.report['languages'][0]['exit_code']=1
        self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_unsupported_language_before_output(self):
        output=self.root/'forbidden'
        with patch('sys.argv',['run.py','--scenario','rename','--languages','scala','--servers-json','/unused','--output',str(output)]), patch('run.sys.platform','darwin'), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as stop:run.main()
        self.assertEqual(stop.exception.code,2)
        self.assertFalse(output.exists())


class RenameRunCaseTests(unittest.TestCase):
    def test_rust_pull_requirement_only_applies_to_diagnostic_scenarios(self):
        for scenario in ('single-file', 'multi-file', 'rename'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                args=SimpleNamespace(output=root,scenario=scenario,phase_timeout=1,judge=Path('/usr/bin/true'),optimize='Debug')
                real_popen=run.subprocess.Popen
                def child(*a,**kw):
                    if a[0][0] == "/usr/bin/git":return real_popen(*a,**kw)
                    (root/'case-rust/product.json').write_text(json.dumps(dict(build_mode='debug')))
                    process=MagicMock();process.wait.return_value=0;process.poll.return_value=0
                    return process
                validation={'rename':True} if scenario=='rename' else {'diagnostic_transport':'push'}
                with patch('run.subprocess.Popen',side_effect=child), patch('run.stop_owned_proxy_groups',return_value=[]), patch('run.verify_directory',return_value=validation):
                    result=run.run_case(args,'rust',dict(argv=['/usr/bin/true']))
                if scenario=='rename':self.assertNotIn('failure',result)
                else:self.assertIn('not obtained through pull',result['failure'])


if __name__=='__main__':unittest.main()
