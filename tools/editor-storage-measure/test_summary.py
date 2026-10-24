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


class AdditionalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        root = self.root
        (root / 'fixtures').mkdir()
        names = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
        inputs = {}
        for name in names:
            (root / 'fixtures' / name).write_bytes(b'original')
            inputs[name] = {'bytes': 8, 'sha256': hashlib.sha256(b'original').hexdigest()}
            for work, count in subject.COUNTS.items():
                rows = []
                for i in range(count):
                    edits = (i + 1) % 2 if work == 'undo' else i + 1
                    inserted = 3 if work == 'structure' else len('\nconst Pasted = struct {\n fn p() void {\n _ = 1;\n }\n};\n') * 100 if work == 'paste' else 1
                    added_lines = edits if work == 'structure' else 600 if work == 'paste' else 0
                    rows.append(f'STORAGE key={i} total_ns={100+i} delta_ns=10 copy_ns=20 index_ns=30 view_lines_ns=5 bytes={8+edits*inserted} lines={1+added_lines}\n')
                (root / f'run-0-1-{name}-{work}.log').write_text(''.join(rows) + 'All 5 tests passed.\n')
        (root / 'inputs.json').write_text(json.dumps(inputs))
        (root / 'binary').write_bytes(b'code')
        (root / 'binaries.json').write_text(json.dumps({'1': {'binary': str(root / 'binary'), 'sha256': hashlib.sha256(b'code').hexdigest()}}))
        (root / 'source-1').mkdir()
        (root / 'source-1/probe.zig').write_bytes(b'probe')
        (root / 'setup-1.json').write_text(json.dumps({'mode': 1, 'instrumented_sha256': {'probe.zig': hashlib.sha256(b'probe').hexdigest()}}))
        self.assertEqual(len(subject.summarize(root, 1)), 25)

    def test_empty_binary_manifest_is_rejected(self):
        (self.root / 'binaries.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Missing production measurement binary'):
            subject.summarize(self.root, 1)

    def test_changed_instrumented_source_is_rejected(self):
        (self.root / 'source-1/probe.zig').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Instrumented source changed'):
            subject.summarize(self.root, 1)

    def test_numeric_prefix_with_garbage_is_rejected(self):
        p = self.root / 'run-0-1-real-build.zig-typing.log'
        p.write_text(p.read_text().replace('lines=1\n', 'lines=1junk\n', 1))
        with self.assertRaises(ValueError):
            subject.summarize(self.root, 1)

    def test_wrong_document_bytes_are_rejected(self):
        p = self.root / 'run-0-1-real-build.zig-undo.log'
        p.write_text(p.read_text().replace('bytes=8 ', 'bytes=9 ', 1))
        with self.assertRaisesRegex(ValueError, 'Unexpected document bytes'):
            subject.summarize(self.root, 1)

    def test_percentile_and_units_match_independent_reference(self):
        group = next(g for g in subject.summarize(self.root, 1) if g['file'] == 'real-build.zig' and g['workload'] == 'typing')
        self.assertEqual(group['events'], 20)
        self.assertEqual(group['ms']['total_ns'], {'p50': 109.5 / 1000000, 'p95': 118 / 1000000})


if __name__ == '__main__':
    unittest.main()
