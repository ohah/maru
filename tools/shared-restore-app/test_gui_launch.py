"""Exercise ownership fences on actual controlled process identities, without a GUI job."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from gui_launch import GUIApp, process_identity


@unittest.skipUnless(sys.platform == 'darwin', 'libproc identity is macOS-specific')
class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.output = Path(self.temp.name)
        self.process = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
        for _ in range(100):
            self.identity = process_identity(self.process.pid)
            if self.identity is not None: break
            time.sleep(.01)
        self.assertIsNotNone(self.identity)
        self.app = GUIApp.__new__(GUIApp)
        self.app.output = self.output
        self.app.executable = Path(self.identity[2])
        self.app._pid = None
        self.app._identity = None
        self.app._loaded = False
        self.app.returncode = None
        (self.output/'app.stderr.txt').write_text(f'warning(app): maru build: mtime=1 pid={self.process.pid}\n')

    def tearDown(self):
        if self.process.poll() is None: self.process.terminate()
        self.process.wait(timeout=5)
        self.temp.cleanup()

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


if __name__ == '__main__': unittest.main()
