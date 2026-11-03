"""앱의 상대 출력과 생산자/복원 환경이 측정 대상 안에 격리되는지 검사한다."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import protocol
import run
import verify


class RunIsolation(unittest.TestCase):
    def trial(self, restored):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            build = root/'build'
            app = build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'
            app.parent.mkdir(parents=True)
            app.write_bytes(b'app')
            producer = build/'producer'
            producer.write_bytes(b'producer')
            (build/'source.json').write_text(json.dumps({'fold_reuse_control': True, 'app_sha256': verify.sha(app), 'producer_sha256': verify.sha(producer)}))
            target = root/'trial'
            calls = []
            recoveries = []

            def launch(command, **kwargs):
                calls.append(kwargs)
                self.assertEqual(kwargs['cwd'], target)
                self.assertNotIn('PRIVATE_TEST_TOKEN', kwargs['env'])
                if command[0] == str(app):
                    data = protocol.fixture(3000)
                    (target/'ready.json').write_text(json.dumps({'pid': 123, 'count': 4, 'source': 'com.apple.keylayout.ABC', 'initial_tail_sha256': __import__('hashlib').sha256(data[3:]).hexdigest()}))
                    (target/'source-record.json').write_text('{}')
                    (target/'app.json').write_text(json.dumps({'restored': restored}))
                    (target/'relative-output').write_text('private')
                else:
                    self.assertNotIn('CFFIXED_USER_HOME', kwargs['env'])
                    self.assertNotIn('MARU_CONFIG', kwargs['env'])
                    (target/'posts.json').write_text('{}')
                return SimpleNamespace(pid=123 if len(calls) == 1 else 456, wait=lambda **kw: 0, poll=lambda: 0)

            def recover(command, **kwargs):
                recoveries.append(kwargs)
                self.assertEqual(kwargs['cwd'], target)
                self.assertNotIn('PRIVATE_TEST_TOKEN', kwargs['env'])
                self.assertNotIn('CFFIXED_USER_HOME', kwargs['env'])
                return SimpleNamespace(returncode=0, stdout='{}', stderr='')

            allow = lambda env: {key: value for key, value in env.items() if key in ('PATH', 'HOME')}
            with patch.dict('os.environ', {'HOME': str(root), 'PATH': '/usr/bin', 'PRIVATE_TEST_TOKEN': 'synthetic'}, clear=True), patch.object(run, 'provider_fingerprints', return_value={'a': None, 'b': None, 'c': None}), patch.object(run.subprocess, 'Popen', side_effect=launch), patch.object(run.subprocess, 'run', side_effect=recover), patch.object(run.verify, 'classify', return_value={}):
                result = run.trial(build, target, 3000, 'async', 'typing', 100, 4, 'normal', 0, environment_filter=allow, fold_reuse_control='prepared')
            self.assertIsNone(result['error'])
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0]['env']['CFFIXED_USER_HOME'], str(target/'profile'))
            self.assertEqual(len(recoveries), int(not restored))
            self.assertTrue((target/'relative-output').is_file())

    def test_profile_and_relative_output(self):
        self.trial(True)

    def test_recovery_uses_auxiliary_environment(self):
        self.trial(False)


if __name__ == '__main__':
    unittest.main()
