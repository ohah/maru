"""Controlled processes test the harness failure contract; these are not AppKit evidence."""
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('archive_runner', ROOT / 'tools/run-macos-archive-app.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@unittest.skipUnless(sys.platform == 'darwin', 'signed bundles and clonefile require macOS')
class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='maru-archive-contract-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.output = self.root / 'runs/control'
        self.app = self.root / 'app'
        self.app.write_text('#!/bin/sh\necho controlled-stderr >&2\nexit 7\n')
        self.app.chmod(0o700)

    def tearDown(self):
        self.temp.cleanup()

    def run_main(self):
        with patch.object(sys, 'argv', ['runner', str(self.app), str(self.output)]):
            return runner.main()

    def test_direct_exit_and_stderr_are_preserved(self):
        with patch.dict(os.environ, {'MARU_AGENT_SESSION_ARCHIVE_GUI': '0'}):
            self.assertEqual(self.run_main(), 7)
        self.assertIn('controlled-stderr', (self.output / 'app.stderr.txt').read_text())

    def test_capture_error_cannot_pass_on_waiter_zero(self):
        self.app.write_text('#!/bin/sh\necho "MARU_SCREENSHOT: PPM 쓰기 실패 stage=close errno=28" >&2\nexit 0\n')
        with patch.dict(os.environ, {'MARU_AGENT_SESSION_ARCHIVE_GUI': '0'}):
            self.assertEqual(self.run_main(), 1)

    def test_gui_uses_private_stage_and_closes_job(self):
        calls = []
        output = self.output
        class ControlledGUI:
            def __init__(self, app, env, out, stage_root):
                calls.append(stage_root)
                (out / 'app.stderr.txt').write_text('controlled-GUI\n')
            def wait(self, timeout): return 0
            def poll(self): return 0
            def close(self): calls.append('closed')
        with patch.dict(os.environ, {'MARU_AGENT_SESSION_ARCHIVE_GUI': '1'}), patch.object(runner, 'GUIApp', ControlledGUI):
            self.assertEqual(self.run_main(), 0)
        self.assertEqual(calls, [output.resolve().parent.parent / 'gui-stage', 'closed'])

    def test_timeout_kills_owned_child_and_waits(self):
        class ControlledChild:
            killed = waited = False
            def wait(self, timeout):
                if not self.killed: raise subprocess.TimeoutExpired('controlled', timeout)
                self.waited = True
                return -9
            def poll(self): return None
            def kill(self): self.killed = True
        child = ControlledChild()
        with patch.dict(os.environ, {'MARU_AGENT_SESSION_ARCHIVE_GUI': '0'}), patch.object(runner.subprocess, 'Popen', return_value=child):
            self.assertEqual(self.run_main(), 1)
        self.assertTrue(child.killed and child.waited)

    def test_shell_exports_failed_capture_and_isolates_all_child_paths(self):
        workspace = self.root / 'workspace with spaces'
        (workspace / 'tools').mkdir(parents=True)
        shutil.copytree(ROOT / 'tests/fixtures/agent-session-archive', workspace / 'tests/fixtures/agent-session-archive')
        for name in ('test-macos-agent-session-archive.sh', 'run-macos-archive-app.py'):
            shutil.copy2(ROOT / 'tools' / name, workspace / 'tools' / name)
        shutil.copytree(ROOT / 'tools/shared-restore-app', workspace / 'tools/shared-restore-app')
        bundle = workspace / 'Input.app'
        executable = bundle / 'Contents/MacOS/maru-macos-app'
        executable.parent.mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleExecutable='maru-macos-app', CFBundleIdentifier='dev.maru.test.archive-controlled',
            CFBundlePackageType='APPL')))
        source = self.root / 'child.c'
        source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char cwd[4096]; getcwd(cwd, sizeof cwd);
    fprintf(stderr, "cwd=%s\nbundle=%s\n", cwd, argv[0]);
    const char *keys[] = {"HOME", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "MARU_APP_SUMMARY_PATH", "MARU_SESSION_HOST_ROOT", "MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR"};
    for (int i=0; i<9; i++) fprintf(stderr, "%s=%s\n", keys[i], getenv(keys[i]));
    FILE *f = fopen(getenv("MARU_APP_SUMMARY_PATH"), "w");
    fputs("agent_session_archive_smoke_stage=not_started\n", f); fclose(f);
    char path[4096]; snprintf(path, sizeof path, "%s/captures/partial.ppm", getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR"));
    f=fopen(path,"w"); fputs("P6\n",f); fclose(f);
    fputs("MARU_SCREENSHOT: PPM 쓰기 실패 stage=pixels errno=28\n", stderr);
    return 1;
}
''')
        subprocess.run(['clang', str(source), '-o', str(executable)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        result = subprocess.run(['sh', 'tools/test-macos-agent-session-archive.sh', str(executable)], cwd=workspace,
                                env=dict(os.environ, MARU_AGENT_SESSION_ARCHIVE_GUI='0'), text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        match = re.search(r'private evidence retained at (/(?:private/)?tmp/maru-agent-session-archive\.\w+)', result.stderr)
        self.assertIsNotNone(match, result.stderr)
        private = Path(match.group(1))
        try:
            published = workspace / 'zig-out/maru-agent-session-archive-smoke'
            self.assertEqual((published / 'captures/partial.ppm').read_bytes(), b'P6\n')
            self.assertIn('not_started', (published / 'app.summary.txt').read_text())
            text = (published / 'runs/resume-pointer/app.stderr.txt').read_text()
            lines = dict(line.split('=', 1) for line in text.splitlines() if '=' in line and not line.startswith('MARU_SCREENSHOT'))
            self.assertEqual(len(lines), 11)
            artifact = Path(lines['MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR'])
            # Keep the product capture allowlist intact: parent of HOME and this exact suffix.
            self.assertEqual(artifact.name, 'maru-agent-session-archive-smoke')
            self.assertEqual(artifact.parent.name, 'zig-out')
            self.assertEqual(Path(lines['HOME']).parent, artifact)
            socket = Path(lines['MARU_SESSION_HOST_ROOT']) / 'sh' / ('f' * 32 + '.sock')
            self.assertLess(len(os.fsencode(socket)), 104)
            for value in lines.values():
                self.assertTrue(Path(value).resolve().is_relative_to(private.resolve()), value)
            self.assertEqual(hashlib.sha256((private / 'zig-out/maru-agent-session-archive-smoke/Maru.app/Contents/MacOS/maru-macos-app').read_bytes()).hexdigest(), digest)
            self.assertEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), digest)
            self.assertEqual((private / 'host').stat().st_mode & 0o777, 0o700)
        finally:
            shutil.rmtree(private)


if __name__ == '__main__':
    unittest.main()
