#!/usr/bin/env python3
"""측정 결과가 다른 조건·실패·누락을 정상 표본으로 섞지 못하게 한다."""
import copy
import importlib.util
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
