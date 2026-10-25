import hashlib
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from oracle import InvalidEvidence, PROFILES, verify_directory
from run import PROXY, stop_owned_proxy_groups
from test_oracle import golden


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.case_root = root / 'case-rust'
        self.case_root.mkdir()
        sources = root / 'sources'
        sources.mkdir()
        case, native, records = golden()
        fingerprints = []
        for name in ('real_lsp_judge.zig', 'mod.zig', 'lsp.zig', 'completion.zig', 'hover.zig', 'definition.zig', 'semantic.zig'):
            data = ('frozen controller ' + name).encode()
            (sources / name).write_bytes(data)
            fingerprints.append(dict(name=name, sha256=hashlib.sha256(data).hexdigest()))
        native['source_fingerprints'] = fingerprints
        (self.case_root / 'case.json').write_text(json.dumps(case))
        (self.case_root / 'product.json').write_text(json.dumps(native))
        (self.case_root / 'wire.ndjson').write_text(''.join(json.dumps(r) + '\n' for r in records))
        (self.case_root / 'protocol.ndjson').write_text('')

    def test_frozen_controller_normal_control(self):
        self.assertEqual(7, verify_directory(self.case_root, 0)['compiled_controller_sources'])

    def test_stale_binary_source_snapshot_is_rejected(self):
        (self.case_root.parent / 'sources/mod.zig').write_text('changed after build')
        with self.assertRaises(InvalidEvidence):
            verify_directory(self.case_root, 0)

    def test_missing_controller_fingerprint_is_rejected(self):
        p = self.case_root / 'product.json'
        d = json.loads(p.read_text())
        d['source_fingerprints'].pop()
        p.write_text(json.dumps(d))
        with self.assertRaises(InvalidEvidence):
            verify_directory(self.case_root, 0)

    def test_observer_failure_cannot_be_ignored(self):
        (self.case_root / 'protocol.ndjson').write_text('{"event":"observer_error"}\n')
        with self.assertRaises(InvalidEvidence):
            verify_directory(self.case_root, 0)

    def test_nonzero_process_exit_cannot_pass_saved_report(self):
        with self.assertRaises(InvalidEvidence):
            verify_directory(self.case_root, 1)

    def test_pinned_zig_017_mode_names(self):
        self.assertEqual({'Debug': 'debug', 'ReleaseFast': 'fast'}, PROFILES)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.group = 88123
        (self.root / 'protocol.ndjson').write_text(json.dumps(dict(event='spawn', proxy_pid=self.group, pgid=self.group)) + '\n')

    def test_unknown_process_command_is_never_signalled(self):
        with patch('run.os.getpgrp', return_value=7), patch('run.os.getpgid', return_value=self.group), patch('run.subprocess.run', return_value=subprocess.CompletedProcess([], 0, 'unrelated process', '')), patch('run.os.killpg') as kill:
            with self.assertRaises(RuntimeError):
                stop_owned_proxy_groups(self.root)
            kill.assert_not_called()

    def test_runner_group_is_never_signalled(self):
        with patch('run.os.getpgrp', return_value=self.group), patch('run.os.killpg') as kill:
            with self.assertRaises(RuntimeError):
                stop_owned_proxy_groups(self.root)
            kill.assert_not_called()

    def test_only_owned_proxy_group_is_signalled(self):
        command = 'python3 ' + str(PROXY) + ' ' + str(self.root / 'proxy.json')
        with patch('run.os.getpgrp', return_value=7), patch('run.os.getpgid', return_value=self.group), patch('run.subprocess.run', return_value=subprocess.CompletedProcess([], 0, command, '')), patch('run.os.killpg') as kill:
            self.assertEqual([self.group], stop_owned_proxy_groups(self.root))
            kill.assert_called_once_with(self.group, signal.SIGTERM)

    def test_already_exited_proxy_needs_no_signal(self):
        with patch('run.os.getpgrp', return_value=7), patch('run.os.getpgid', side_effect=ProcessLookupError), patch('run.os.killpg') as kill:
            self.assertEqual([], stop_owned_proxy_groups(self.root))
            kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
