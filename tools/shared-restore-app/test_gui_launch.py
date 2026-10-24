"""Exercise ownership fences on actual controlled process identities, without a GUI job."""
import os
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from gui_launch import GUIApp, process_identity, stage_app


# PID가 생긴 시점에는 Python launcher가 아직 실제 interpreter로 exec하기 전일 수 있다.
# 자식이 최종 interpreter에서 원자적으로 게시한 준비 신호 뒤에만 실행 파일을 관측한다.
READY_CODE = ('import os,sys,time; from pathlib import Path; '
              'marker=Path(sys.argv[1]); temp=marker.with_suffix(".tmp"); '
              'temp.write_text(str(os.getpid())); temp.replace(marker); time.sleep(30)')


def stop_owned_process(process):
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=5)
    if process.stdin is not None and not process.stdin.closed:
        process.stdin.close()


def ready_identity(process, marker, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        if process.poll() is not None:
            raise RuntimeError('fixture exited before readiness')
        try:
            ready_pid = marker.read_text()
        except FileNotFoundError:
            pass
        else:
            if ready_pid != str(process.pid):
                raise RuntimeError('fixture ready PID mismatch')
            identity = process_identity(process.pid)
            if identity is not None:
                return identity
        if time.monotonic() >= deadline:
            raise TimeoutError('fixture readiness/identity timeout')
        time.sleep(.005)


@unittest.skipUnless(sys.platform == 'darwin', 'libproc identity is macOS-specific')
class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        marker = self.output / 'ready'
        self.process = subprocess.Popen([sys.executable, '-c', READY_CODE, str(marker)])
        self.addCleanup(stop_owned_process, self.process)
        self.identity = ready_identity(self.process, marker)
        self.app = GUIApp.__new__(GUIApp)
        self.app.output = self.output
        self.app.executable = Path(self.identity[2])
        self.app._pid = None
        self.app._identity = None
        self.app._loaded = False
        self.app.returncode = None
        (self.output/'app.stderr.txt').write_text(f'warning(app): maru build: mtime=1 pid={self.process.pid}\n')

    def test_observation_binds_real_uid_birth_and_executable(self):
        self.assertEqual(self.app.pid,self.process.pid)
        self.assertEqual(self.app._identity,self.identity)

    def test_wrong_executable_does_not_kill(self):
        self.app.executable = self.output/'wrong-app'
        with patch('gui_launch.os.kill') as kill:
            with self.assertRaises(RuntimeError): self.app.kill()
            kill.assert_not_called()
        self.assertIsNone(self.process.poll())

    def test_reused_birth_does_not_kill(self):
        self.app.pid
        uid,(seconds,microseconds),path = self.identity
        self.app._identity = (uid,(seconds+1,microseconds),path)
        with patch('gui_launch.os.kill') as kill:
            with self.assertRaises(RuntimeError): self.app.kill()
            kill.assert_not_called()
        self.assertIsNone(self.process.poll())

    def test_changed_pid_does_not_kill(self):
        self.app.pid
        (self.output/'app.stderr.txt').write_text(f'warning(app): maru build: mtime=1 pid={os.getpid()}\n')
        with patch('gui_launch.os.kill') as kill:
            with self.assertRaises(RuntimeError): self.app.kill()
            kill.assert_not_called()
        self.assertIsNone(self.process.poll())

    def test_waiter_success_without_app_is_rejected(self):
        self.app.domain = 'gui/501/test-only-placeholder'
        (self.output/'app.stderr.txt').write_text('launcher-only output\n')
        result = subprocess.CompletedProcess([],0,stdout='last exit code = 0\n',stderr='')
        with patch('gui_launch.subprocess.run',return_value=result):
            with self.assertRaises(RuntimeError): self.app.poll()

    def test_waiter_exit_does_not_hide_live_application(self):
        self.app.domain = 'gui/501/test-only-placeholder'
        self.app.pid
        result = subprocess.CompletedProcess([],0,stdout='last exit code = 0\n',stderr='')
        with patch('gui_launch.subprocess.run',return_value=result):
            self.assertIsNone(self.app.poll())
        self.assertIsNone(self.process.poll())

    def test_cleanup_rejects_remaining_owned_job(self):
        self.app.domain = 'gui/501/test-only-placeholder'
        self.app._loaded = True
        result = subprocess.CompletedProcess([],0,stdout='',stderr='')
        with patch('gui_launch.subprocess.run',return_value=result):
            with self.assertRaises(RuntimeError): self.app.close()

    def test_exact_owned_process_can_be_killed(self):
        self.app.pid
        self.app.kill()
        self.assertEqual(self.process.wait(timeout=5),-9)

    def test_staged_cli_drift_is_rejected_before_gui_launch(self):
        staged = self.output / 'maru-macos-app'
        staged.write_bytes(b'expected-gui')
        (self.output / 'maru').write_bytes(b'foreign-cli')
        expected = { 'maru-macos-app': hashlib.sha256(b'expected-gui').hexdigest(),
                     'maru': hashlib.sha256(b'expected-cli').hexdigest() }
        with patch('gui_launch.stage_app', return_value=staged), patch('gui_launch.subprocess.run') as launch:
            with self.assertRaisesRegex(RuntimeError, 'staged GUI binary differs.*maru'):
                GUIApp(staged, {}, self.output, expected_binaries=expected)
            launch.assert_not_called()


@unittest.skipUnless(sys.platform == 'darwin', 'libproc identity is macOS-specific')
class StartupTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.marker = Path(temp.name) / 'ready'

    def spawn(self, command, **kwargs):
        process = subprocess.Popen(command, **kwargs)
        self.addCleanup(stop_owned_process, process)
        return process

    def test_exec_transition_is_observed_only_after_child_ready(self):
        process = self.spawn(['/bin/sh', '-c', 'IFS= read -r line; exec "$@"',
                              'fixture-launcher', sys.executable, '-c', READY_CODE,
                              str(self.marker)], stdin=subprocess.PIPE)
        before = process_identity(process.pid)
        self.assertIsNotNone(before)
        released = False
        real_sleep = time.sleep

        def release_after_wait(_):
            nonlocal released
            if not released:
                process.stdin.write(b'go\n')
                process.stdin.flush()
                process.stdin.close()
                released = True
            real_sleep(.005)

        with patch(__name__ + '.time.sleep', side_effect=release_after_wait):
            after = ready_identity(process, self.marker)
        self.assertTrue(released)
        self.assertEqual(before[:2], after[:2])
        self.assertNotEqual(before[2], after[2])
        self.assertEqual(after, process_identity(process.pid))

    def test_exit_before_ready_is_rejected(self):
        process = self.spawn([sys.executable, '-c', 'pass'])
        process.wait(timeout=5)
        with patch(__name__ + '.process_identity') as observe:
            with self.assertRaisesRegex(RuntimeError, 'exited before'):
                ready_identity(process, self.marker)
            observe.assert_not_called()

    def test_wrong_ready_pid_is_rejected(self):
        process = self.spawn([sys.executable, '-c', 'import time; time.sleep(30)'])
        self.marker.write_text(str(process.pid + 1))
        with patch(__name__ + '.process_identity') as observe:
            with self.assertRaisesRegex(RuntimeError, 'PID mismatch'):
                ready_identity(process, self.marker)
            observe.assert_not_called()

    def test_missing_ready_times_out_without_observing_or_killing(self):
        process = self.spawn([sys.executable, '-c', 'import time; time.sleep(30)'])
        with patch(__name__ + '.process_identity') as observe:
            with self.assertRaises(TimeoutError):
                ready_identity(process, self.marker, timeout=.02)
            observe.assert_not_called()
        self.assertIsNone(process.poll())

    def test_missing_identity_after_ready_remains_failure(self):
        process = self.spawn([sys.executable, '-c', 'import time; time.sleep(30)'])
        self.marker.write_text(str(process.pid))
        with patch(__name__ + '.process_identity', return_value=None) as observe:
            with self.assertRaises(TimeoutError):
                ready_identity(process, self.marker, timeout=.02)
            self.assertGreater(observe.call_count, 0)
        self.assertIsNone(process.poll())


class StageTests(unittest.TestCase):
    def test_private_stage_does_not_consult_home_and_clone_failure_falls_back(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            root = Path(temp)
            app = root / 'source/Maru.app/Contents/MacOS/maru-macos-app'
            app.parent.mkdir(parents=True)
            app.write_bytes(b'controlled-byte-identical-app')
            base = root / 'private-stage'
            commands = []
            def execute(command, **kwargs):
                commands.append(command)
                return subprocess.CompletedProcess(command, 1 if command[0] == 'cp' else 0)
            with patch('gui_launch.Path.home', side_effect=AssertionError('protected HOME consulted')), \
                 patch('gui_launch.subprocess.run', side_effect=execute):
                binary = stage_app(app, base)
            self.assertEqual(binary.read_bytes(), app.read_bytes())
            self.assertTrue(binary.is_relative_to(base))
            self.assertEqual([command[0] for command in commands], ['cp', 'codesign'])
            self.assertEqual(base.stat().st_mode & 0o777, 0o700)


if __name__ == '__main__': unittest.main()
