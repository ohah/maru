"""실제 프로세스 없이 격리 config·진단 태그·해시가 올바르게 기록되는지 검증한다."""
import contextlib
import hashlib
import io
import json
import pathlib
import runpy
import tempfile
import unittest
from unittest import mock
import cadence
import verify

HERE = pathlib.Path(__file__).resolve().parent


class CadenceContract(unittest.TestCase):
    def test_writer_uses_isolated_config_without_debug_redraw(self):
        for hz in [30, 60, 120]:
            with self.subTest(hz=hz), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                build = root/'build'
                app = build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'
                app.parent.mkdir(parents=True)
                app.write_bytes(b'unit fixture, never executed')
                (build/'source.json').write_text(json.dumps({'app_sha256': verify.sha(app)}))
                runner = root/'runner.py'
                runner.write_text(cadence.variant((HERE/'run.py').read_text(), HERE.parents[1], hz))

                class Child:
                    pid = 123
                    def __init__(self, command, env, **kwargs):
                        self.output = pathlib.Path(env['MARU_LATENCY_OUTPUT'])
                        if 'MARU_DEBUG' in env or env.get('MARU_LATENCY_DIAGNOSTIC') != '1':
                            raise AssertionError('diagnostic enables forced redraw')
                    def wait(self, timeout):
                        self.output.write_text(json.dumps({'error': None, 'restored': True}))
                        return 0

                args = [str(runner), '--build', str(build), '--output', str(root/'result'), '--sizes', '1',
                        '--flows', 'typing', '--repetitions', '1', '--events', '6', '--diagnostic']
                with mock.patch('sys.argv', args), mock.patch('subprocess.Popen', Child), mock.patch('os.getloadavg', return_value=(0, 0, 0), create=True), contextlib.redirect_stdout(io.StringIO()):
                    runpy.run_path(str(runner), run_name='__main__')
                manifest = json.loads((root/'result/manifest.json').read_text())
                self.assertIs(manifest['diagnostic'], True)
                self.assertEqual(manifest['requested_frame_rate_hz'], hz)
                for run in manifest['runs']:
                    config = root/'result'/run['path']/'config'
                    self.assertEqual(config.read_text(), 'session.keep-alive-after-quit = false\nlsp.enabled = false\neditor.wrap = false\nrender.frame-rate = '+str(hz)+'\n')
                    self.assertEqual(hashlib.sha256(config.read_bytes()).hexdigest(), run['config_sha256'])

    def test_invalid_cadence(self):
        for hz in [True, 60.0, 0, 144]:
            with self.subTest(hz=hz), self.assertRaises(ValueError):
                cadence.variant((HERE/'run.py').read_text(), HERE.parents[1], hz)

    def test_missing_or_duplicate_anchor(self):
        source = (HERE/'run.py').read_text()
        for marker in [r'editor.wrap = false\n', "env['MARU_DEBUG']='1'", "'diagnostic':a.diagnostic,", "record['result_sha256']="]:
            for changed in [source.replace(marker, ''), source+marker]:
                with self.subTest(marker=marker), self.assertRaises(ValueError):
                    cadence.variant(changed, HERE.parents[1], 60)

    def test_diagnostic_cannot_enter_default_population(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root/'manifest.json').write_text(json.dumps({'diagnostic': True}))
            with self.assertRaisesRegex(ValueError, 'diagnostic timing'):
                verify.verify(root)
            with self.assertRaisesRegex(ValueError, 'diagnostic request'):
                verify.verify(root, diagnostic=1)


if __name__ == '__main__':
    unittest.main()
