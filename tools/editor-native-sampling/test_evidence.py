"""생산자가 실제로 읽는 스키마 어휘를 근거에서 빠뜨리지 못하게 한다."""
from pathlib import Path
import shutil
import tempfile
import unittest

import evidence


class EvidenceTests(unittest.TestCase):
    def test_summary_types_cannot_alias_integer_counts(self):
        expected = dict(counts=dict(missing=0, rows=2), scope='sample')
        self.assertTrue(evidence.same_summary(dict(scope='sample', counts=dict(rows=2, missing=0)), expected))
        for value in (False, 0.0, '0', None):
            with self.subTest(value=value):
                actual = dict(counts=dict(missing=value, rows=2), scope='sample')
                self.assertFalse(evidence.same_summary(actual, expected))

    def test_json_integer_versions_are_not_booleans_or_floats(self):
        evidence.strict(1, 1, 'schema')
        for value in (True, 1.0, '1', None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                evidence.strict(value, 1, 'schema')

    def test_executed_frame_vocabulary_cannot_disappear_with_its_hash(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            expected = evidence.producer_files()
            for name in expected:
                path = root / 'tool-snapshot' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(evidence.ROOT / name, path)
            evidence.checked_tools(root, expected)
            missing = 'tools/editor-frame-measure/contract.py'
            (root / 'tool-snapshot' / missing).unlink()
            del expected[missing]
            with self.assertRaisesRegex(ValueError, 'Missing captured sampling producer'):
                evidence.checked_tools(root, expected)


if __name__ == '__main__':
    unittest.main()
