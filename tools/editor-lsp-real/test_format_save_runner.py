"""Format/save archives must keep the full controller and tool evidence."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import run
from oracle import InvalidEvidence
from test_format_save_oracle import golden
from verify import verify_run


class FormatSaveArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        c,n,w=golden()
        n['build_mode']='debug'
        case=self.root/'case-rust';case.mkdir()
        sources=self.root/'sources';sources.mkdir()
        n['source_fingerprints']=[]
        for name in ('format_save_judge.zig','real_lsp_judge.zig','mod.zig','lsp.zig','completion.zig','hover.zig','definition.zig','semantic.zig','format.zig','save_dispatch.zig','local_save.zig'):
            data=('compiled unit fixture '+name).encode();(sources/name).write_bytes(data)
            n['source_fingerprints'].append(dict(name=name,sha256=hashlib.sha256(data).hexdigest()))
        (case/'case.json').write_text(json.dumps(c))
        (case/'product.json').write_text(json.dumps(n))
        (case/'wire.ndjson').write_text(''.join(json.dumps(x)+'\n' for x in w))
        (case/'protocol.ndjson').write_text('')
        (case/'judge.log').write_text('unit archive; not real SDK execution')
        (case/'server.stderr').write_text('')
        (self.root/'judge').write_text('unit executable fixture')
        tools=self.root/'tool-sources';tools.mkdir()
        for name in ('run.py','oracle.py','verify.py','lsp_proxy.py','format_save_fixture.py','format_save_oracle.py'):
            (tools/name).write_text('unit tool '+name)
        sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
        self.report=dict(schema='maru.lsp-real.run.v1',scenario='format-save',optimize='Debug',judge_sha256=sha(self.root/'judge'),
                         tool_sources={p.name:sha(p) for p in tools.iterdir()},
                         languages=[dict(language='rust',exit_code=0,artifacts={p.name:sha(p) for p in case.iterdir()})])
        self.save()

    def save(self):
        (self.root/'result.json').write_text(json.dumps(self.report))

    def test_normal_eleven_controller_archive(self):
        self.assertEqual(verify_run(self.root)['rust']['compiled_controller_sources'],11)

    def test_missing_format_save_tool(self):
        del self.report['tool_sources']['format_save_oracle.py'];self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_scenario_downgrade(self):
        self.report['scenario']='rename';self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_missing_save_controller(self):
        p=self.root/'case-rust/product.json';n=json.loads(p.read_text());n['source_fingerprints'].pop()
        p.write_text(json.dumps(n));self.report['languages'][0]['artifacts']['product.json']=hashlib.sha256(p.read_bytes()).hexdigest();self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_stale_save_dispatch_source(self):
        (self.root/'sources/save_dispatch.zig').write_text('stale source')
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_wrong_language(self):
        self.report['languages'][0]['language']='go';(self.root/'case-rust').rename(self.root/'case-go');self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_wrong_compiled_profile(self):
        self.report['optimize']='ReleaseFast';self.save()
        with self.assertRaises(InvalidEvidence):verify_run(self.root)

    def test_unsupported_language_before_output(self):
        output=self.root/'forbidden'
        with patch('sys.argv',['run.py','--scenario','format-save','--languages','scala','--servers-json','/unused','--output',str(output)]),patch('run.sys.platform','darwin'),contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as stop:run.main()
        self.assertEqual(stop.exception.code,2);self.assertFalse(output.exists())


class FormatSaveRunCaseTests(unittest.TestCase):
    def test_rust_pull_requirement_keeps_both_diagnostic_scenarios(self):
        for scenario in ('single-file','multi-file','rename','format-save'):
            with self.subTest(scenario=scenario),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);args=SimpleNamespace(output=root,scenario=scenario,phase_timeout=1,judge=Path('/usr/bin/true'),optimize='Debug')
                real_popen=run.subprocess.Popen
                def child(*a,**kw):
                    if a[0][0]=='/usr/bin/git':return real_popen(*a,**kw)
                    (root/'case-rust/product.json').write_text(json.dumps(dict(build_mode='debug')))
                    process=MagicMock();process.wait.return_value=0;process.poll.return_value=0
                    return process
                with patch('run.subprocess.Popen',side_effect=child),patch('run.stop_owned_proxy_groups',return_value=[]),patch('run.verify_directory',return_value={'diagnostic_transport':'push'}):
                    result=run.run_case(args,'rust',dict(argv=['/usr/bin/true']))
                if scenario in ('rename','format-save'):self.assertNotIn('failure',result)
                else:self.assertIn('not obtained through pull',result['failure'])


if __name__=='__main__':unittest.main()
