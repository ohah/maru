"""The multi-file profile must retain its extra source/tool evidence and scope."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from multi_fixture import fixture
from oracle import InvalidEvidence, verify_directory
import run
from test_multi_oracle import golden
from verify import verify_run


class MultiRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_owned_fixture_documents_and_byte_caret(self):
        for language in ('rust', 'go'):
            case = fixture(self.root / language, language)
            self.assertEqual(Path(case['path']).read_text(), case['good'])
            self.assertEqual(Path(case['peer_path']).read_text(), case['peer_good'])
            prefix = case['partial'].encode()[:case['completion_offset']].decode()
            self.assertTrue(prefix.endswith('ImportedTok' if language == 'rust' else 'Durat'))
            for support in case['support']:
                self.assertEqual(Path(support['path']).read_text(), support['good'])

    def test_existing_fixture_cannot_be_overwritten(self):
        target = self.root / 'existing'
        target.mkdir()
        (target / 'keep').write_text('owned elsewhere')
        with self.assertRaises(FileExistsError):
            fixture(target, 'rust')
        self.assertEqual((target / 'keep').read_text(), 'owned elsewhere')

    def test_unsupported_language_rejected_before_output(self):
        output = self.root / 'output'
        args = ['run.py', '--scenario', 'multi-file', '--languages', 'scala', '--servers-json', '/unused', '--output', str(output)]
        with patch('sys.argv', args), patch('run.sys.platform', 'darwin'), contextlib.redirect_stderr(io.StringIO()) as err:
            with self.assertRaises(SystemExit) as stop:
                run.main()
        self.assertEqual(stop.exception.code, 2)
        self.assertIn('multi-file supports Rust and Go only', err.getvalue())
        self.assertFalse(output.exists())


class MultiArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        case_root = self.root / 'case-rust'
        case_root.mkdir()
        case, native, wire = golden()
        native['build_mode'] = 'debug'
        sources = self.root / 'sources'
        sources.mkdir()
        names = ('real_lsp_judge.zig', 'real_lsp_multi_judge.zig', 'mod.zig', 'lsp.zig', 'completion.zig', 'hover.zig', 'definition.zig', 'semantic.zig')
        native['source_fingerprints'] = []
        for name in names:
            data = ('compiled fixture ' + name).encode()
            (sources / name).write_bytes(data)
            native['source_fingerprints'].append(dict(name=name, sha256=hashlib.sha256(data).hexdigest()))
        (case_root / 'case.json').write_text(json.dumps(case))
        (case_root / 'product.json').write_text(json.dumps(native))
        (case_root / 'wire.ndjson').write_text(''.join(json.dumps(x) + '\n' for x in wire))
        (case_root / 'protocol.ndjson').write_text('')
        (case_root / 'judge.log').write_text('unit fixture, not a real SDK execution')
        (case_root / 'server.stderr').write_text('')
        (self.root / 'judge').write_text('unit executable fixture')
        tools = self.root / 'tool-sources'
        tools.mkdir()
        for name in ('run.py', 'oracle.py', 'verify.py', 'lsp_proxy.py', 'multi_fixture.py', 'multi_oracle.py'):
            (tools / name).write_text('tool fixture ' + name)
        sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        self.report = dict(schema='maru.lsp-real.run.v1', scenario='multi-file', optimize='Debug',
                           judge_sha256=sha(self.root / 'judge'), tool_sources={p.name: sha(p) for p in tools.iterdir()},
                           languages=[dict(language='rust', exit_code=0, artifacts={p.name: sha(p) for p in case_root.iterdir()})])
        self.save()

    def save(self):
        (self.root / 'result.json').write_text(json.dumps(self.report))

    def test_normal_eight_controller_profile(self):
        self.assertEqual(verify_run(self.root)['rust']['compiled_controller_sources'], 8)

    def test_missing_multi_tool_rejected(self):
        del self.report['tool_sources']['multi_oracle.py']
        self.save()
        with self.assertRaises(InvalidEvidence):
            verify_run(self.root)

    def test_run_cannot_claim_single_file(self):
        self.report['scenario'] = 'single-file'
        self.save()
        with self.assertRaises(InvalidEvidence):
            verify_run(self.root)

    def test_run_language_must_match_case(self):
        self.report['languages'][0]['language'] = 'go'
        (self.root / 'case-rust').rename(self.root / 'case-go')
        self.save()
        with self.assertRaises(InvalidEvidence):
            verify_run(self.root)

    def test_compiled_multi_source_cannot_be_replaced(self):
        (self.root / 'sources/real_lsp_multi_judge.zig').write_text('stale executable')
        with self.assertRaises(InvalidEvidence):
            verify_directory(self.root / 'case-rust', 0)

    def test_missing_multi_fingerprint_rejected(self):
        p = self.root / 'case-rust/product.json'
        d = json.loads(p.read_text())
        d['source_fingerprints'] = [x for x in d['source_fingerprints'] if x['name'] != 'real_lsp_multi_judge.zig']
        p.write_text(json.dumps(d))
        with self.assertRaises(InvalidEvidence):
            verify_directory(self.root / 'case-rust', 0)
