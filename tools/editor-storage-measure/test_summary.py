"""누락·중복·시간 오염·미완료·원문 변경을 정상 대조군과 함께 공격한다."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import summarize as subject


def record(i):
    return f'STORAGE key={i} total_ns=100 delta_ns=10 copy_ns=20 index_ns=30 view_lines_ns=5 bytes=10 lines=2\n'


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.good = ''.join(record(i) for i in range(20)) + 'All 5 tests passed.\n'
        self.assertEqual(len(subject.validate(self.good, 'typing')), 20)

    def test_missing_event_is_rejected(self):
        with self.assertRaises(ValueError):
            subject.validate(self.good.replace(record(7), ''), 'typing')

    def test_duplicate_event_cannot_replace_missing_event(self):
        with self.assertRaises(ValueError):
            subject.validate(self.good.replace(record(7), record(6)), 'typing')

    def test_overlapping_or_wrong_unit_clocks_are_rejected(self):
        with self.assertRaises(ValueError):
            subject.validate(self.good.replace('copy_ns=20', 'copy_ns=20000000', 1), 'typing')

    def test_incomplete_product_run_is_rejected(self):
        with self.assertRaises(ValueError):
            subject.validate(self.good.replace('All 5 tests passed.', ''), 'typing')

    def test_changed_fixture_is_rejected_before_aggregation(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / 'fixtures').mkdir()
            names = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
            for name in names:
                (root / 'fixtures' / name).write_bytes(b'original')
            (root / 'fixtures/real-build.zig').write_bytes(b'changed')
            (root / 'inputs.json').write_text(json.dumps({name: {'bytes': 8, 'sha256': hashlib.sha256(b'original').hexdigest()} for name in names}))
            with self.assertRaisesRegex(ValueError, 'Fixture hash changed'):
                subject.summarize(root)


if __name__ == '__main__':
    unittest.main()
