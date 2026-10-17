"""Synthetic judge contract and real owned-process failure cleanup; no GUI evidence claim."""
import importlib.util, json, subprocess, sys, tempfile, unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('ended_probe', Path(__file__).with_name('run.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'shared-restore-app'))
from gui_launch import GUIApp, process_identity

class JudgeTests(unittest.TestCase):
    runtime = '1' * 32
    host = '2' * 32
    def trace(self):
        return '\n'.join([
            f'REMOTE_ENDED_DISCONNECTED host={self.host} runtime={self.runtime}',
            f'REMOTE_ENDED_JOB host={self.host} state=replacement_published',
            f'REMOTE_ENDED_JOB host={self.host} state=candidate_ended',
            f'REMOTE_ENDED_TERMINAL host={self.host} total=1 published_old=0 published_new=0 frozen=0 ended=1 retry_reserved=0',
            'REMOTE_ENDED_GUI visible=true', ''])
    def test_identity_and_order(self):
        text = self.trace()
        probe.verify_runtime_ended_gui(text, self.runtime)
        for changed in [text.replace('runtime=' + self.runtime, 'runtime=' + '3' * 32),
                        text.replace('REMOTE_ENDED_TERMINAL host=' + self.host, 'REMOTE_ENDED_TERMINAL host=' + '3' * 32),
                        text.replace('state=candidate_ended', 'state=candidate_staged'),
                        '\n'.join(reversed(text.splitlines()))]:
            with self.assertRaises(RuntimeError): probe.verify_runtime_ended_gui(changed, self.runtime)
    def test_old_retained_result_and_contradictory_terminal_are_rejected(self):
        valid = self.trace()
        terminal = next(line for line in valid.splitlines() if line.startswith('REMOTE_ENDED_TERMINAL '))
        old = valid.replace('state=candidate_ended', 'state=candidate_rejected').replace(
            'frozen=0 ended=1 retry_reserved=0', 'frozen=1 ended=0 retry_reserved=1')
        for changed in [old,
                        valid.replace('ended=1', 'ended=0'),
                        valid.replace('retry_reserved=0', 'retry_reserved=1'),
                        valid + terminal.replace('ended=1', 'ended=0') + '\n',
                        terminal.replace('frozen=0', 'frozen=1') + '\n' + valid]:
            with self.assertRaises(RuntimeError): probe.verify_runtime_ended_gui(changed, self.runtime)
        # Repeated identical read-only terminal observations are valid.
        probe.verify_runtime_ended_gui(valid + terminal + '\n', self.runtime)
    def test_late_errors_and_embedded_success(self):
        for changed in [self.trace() + 'fatal integrity: late quit failure\n',
                        self.trace() + 'error: reconnect product coordinator turn failed: late\n',
                        self.trace().replace('REMOTE_ENDED_GUI visible=true', 'payload REMOTE_ENDED_GUI visible=true')]:
            with self.assertRaises(RuntimeError): probe.verify_runtime_ended_gui(changed, self.runtime)
    def test_success_waits_for_cleanup_and_failed_body_has_no_result(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            probe.finish_probe([], None, root)
            self.assertFalse((root / 'result.json').exists())
            def cleanup(): self.assertFalse((root / 'result.json').exists())
            probe.finish_probe([cleanup], {'case': 'synthetic-judge'}, root)
            self.assertTrue(json.loads((root / 'result.json').read_text())['cleanup_verified'])
    def test_artifact_mutation_runner_with_explicit_synthetic_trace(self):
        # Exercise the CLI without presenting this fixture as evidence of a real GUI run.
        with tempfile.TemporaryDirectory(prefix='maru-ended-synthetic-') as raw:
            root = Path(raw)
            (root / 'seed').mkdir()
            (root / 'seed/app.stderr.txt').write_text(self.trace())
            (root / 'result.json').write_text(json.dumps({'runtime_id': self.runtime}))
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('test_ended_oracle.py')),
                                     '--artifact', str(root)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('rejected old_retained', result.stdout)
            self.assertIn('rejected unexpected_retry', result.stdout)
    @unittest.skipUnless(sys.platform == 'darwin', 'libproc identity is macOS-specific')
    def test_cleanup_error_still_settles_owned_child_and_preserves_control(self):
        owned = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        control = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            with tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                identity = process_identity(owned.pid)
                self.assertIsNotNone(identity)
                app = GUIApp.__new__(GUIApp)
                app.output = root; app.executable = Path(identity[2])
                app._pid = None; app._identity = None; app._loaded = False
                (root / 'app.stderr.txt').write_text(f'warning(app): maru build: test pid={owned.pid}\n')
                def diagnostic_error(): raise OSError('injected diagnostic failure')
                with self.assertRaises(RuntimeError):
                    probe.finish_probe([diagnostic_error, app.kill], {'case': 'synthetic-judge'}, root)
                self.assertEqual(owned.wait(timeout=5), -9)
                self.assertIsNone(control.poll())
                self.assertFalse((root / 'result.json').exists())
        finally:
            for process in [owned, control]:
                if process.poll() is None: process.terminate()
                process.wait(timeout=5)

if __name__ == '__main__': unittest.main()
