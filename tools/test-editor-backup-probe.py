#!/usr/bin/env python3
"""측정 결과가 다른 조건·실패·누락을 정상 표본으로 섞지 못하게 한다."""
import copy
import importlib.util
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('probe-editor-backup.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def matrix():
    return [dict(route=route, bytes=size, action=action, sample=sample, total_ns=100,
                 write_ns=0 if action == 'drop' else 80,
                 encode_ns=0 if action == 'drop' else 20,
                 read_ns=10 if route == 'local-id' and action == 'rewrite' else 0,
                 verified=True)
            for route in ['untitled', 'local-id'] for size in [65536, 1048576, 8388608]
            for action, samples in [('first', [0]), ('rewrite', [1, 2, 3]), ('drop', [0])]
            for sample in samples]


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.rows = matrix()
        probe.validate(self.rows)

    def test_incomplete_or_empty_measurement_is_rejected(self):
        for rows in [[], self.rows[:-1]]:
            with self.assertRaises(ValueError):
                probe.validate(rows)

    def test_duplicate_or_wrong_condition_is_rejected(self):
        with self.assertRaises(ValueError):
            probe.validate(self.rows + [copy.deepcopy(self.rows[0])])
        self.rows[0]['bytes'] = 42
        with self.assertRaises(ValueError):
            probe.validate(self.rows)

    def test_failed_content_verification_is_rejected(self):
        self.rows[0]['verified'] = False
        with self.assertRaises(ValueError):
            probe.validate(self.rows)

    def test_impossible_timing_or_missing_encoding_is_rejected(self):
        for value in [-1, True, 101, 0]:
            rows = copy.deepcopy(self.rows)
            rows[0]['write_ns'] = value
            with self.assertRaises(ValueError):
                probe.validate(rows)

    def test_wrong_stage_attribution_is_rejected(self):
        for route, action, read in [('untitled', 'first', 1), ('local-id', 'first', 1), ('local-id', 'rewrite', 0), ('local-id', 'drop', 1)]:
            rows = copy.deepcopy(self.rows)
            next(r for r in rows if r['route'] == route and r['action'] == action)['read_ns'] = read
            with self.assertRaises(ValueError):
                probe.validate(rows)


class ExtraProbeTests(unittest.TestCase):
    @staticmethod
    def log(failed=13):
        lines = [f'{i}/18 fixture.test.U4a-{i} contract...' + ('\nFAIL (TestExpectedEqual)' if i == failed else 'OK') for i in range(1, 19)]
        return '\n'.join(lines) + '\n17 passed; 0 skipped; 1 failed.\n'

    def test_boolean_and_float_conditions_are_not_integer_samples(self):
        probe.validate(matrix())
        for field, bad in [('sample', True), ('sample', 1.0), ('bytes', 65536.0)]:
            rows = matrix()
            row = next(r for r in rows if r['sample'] == 1)
            row[field] = bad
            with self.assertRaises(ValueError):
                probe.validate(rows)

    def test_unrelated_failure_does_not_prove_target_mutation(self):
        self.assertTrue(probe.mutation_failed(self.log(), 1, 13))
        self.assertFalse(probe.mutation_failed(self.log(failed=10), 1, 13))
        self.assertFalse(probe.mutation_failed(self.log().replace('TestExpectedEqual', 'OutOfMemory'), 1, 13))
        self.assertFalse(probe.mutation_failed(self.log(), 0, 13))

    def test_interrupted_or_compilation_failure_is_not_detection(self):
        text = self.log()
        for bad in [text.split('14/18')[0], text.replace('18/18', '17/18'), text.replace('17 passed;', '16 passed;'), 'error: expected expression']:
            self.assertFalse(probe.mutation_failed(bad, 1, 13))

    def test_hash_guard_survives_optimized_python(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'input').write_bytes(b'original')
            probe.ensure_hashes(root, {'input': hashlib.sha256(b'original').hexdigest()})
            code = ('import importlib.util; from pathlib import Path; '
                    's=importlib.util.spec_from_file_location("probe",' + repr(str(Path(probe.__file__).resolve())) + '); '
                    'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                    'm.ensure_hashes(Path(' + repr(temp) + '), {"input":"wrong"})')
            result = subprocess.run([sys.executable, '-O', '-c', code], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Source identity mismatch', result.stderr)

    def test_missing_or_duplicate_anchor_does_not_modify_source(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'input'
            for text in ['absent', 'anchor anchor']:
                path.write_text(text)
                with self.assertRaises(ValueError):
                    probe.once(path, 'anchor', 'changed')
                self.assertEqual(path.read_text(), text)
            path.write_text('anchor')
            probe.once(path, 'anchor', 'changed')
            self.assertEqual(path.read_text(), 'changed')


if __name__ == '__main__':
    unittest.main()
