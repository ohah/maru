#!/usr/bin/env python3
"""완료 구간 판정이 누락·중복·인과 역전을 거절하고 실제 스레드 순서는 허용하는지 검사한다."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

path = Path(__file__).with_name('probe-editor-first-save-completion.py')
spec = importlib.util.spec_from_file_location('completion_probe', path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def valid():
    return dict(request=10, prepare_begin=20, prepare_end=30, worker_submitted=40,
                worker_enter=35, worker_done=45, collected=60, adopted=70,
                postprocess_end=75, finished=80, probe_ready=90)


def log(points):
    return '\n'.join(f'UNTITLED_PHASE name={name} ns={stamp}' for name, stamp in points.items())


class CompletionProbeTests(unittest.TestCase):
    def test_real_intervals_and_worker_before_submit_return(self):
        result = probe.parse_phases(log(valid()))
        self.assertEqual(result['start_wait_ns'], 10)
        self.assertEqual(result['completion_wait_ns'], 15)
        self.assertEqual(result['apply_ns'], 20)
        self.assertEqual(result['model_ready_ns'], 80)

    def test_stream_order_is_not_cross_thread_clock_order(self):
        points = dict(reversed(list(valid().items())))
        self.assertEqual(probe.parse_phases(log(points)), probe.parse_phases(log(valid())))

    def test_missing_and_unknown_phases(self):
        for name in valid():
            points = valid()
            del points[name]
            with self.assertRaises(ValueError):
                probe.parse_phases(log(points))
        with self.assertRaises(ValueError):
            probe.parse_phases(log(valid()) + '\nUNTITLED_PHASE name=other ns=90')

    def test_duplicate_and_malformed_record(self):
        for extra in ['UNTITLED_PHASE name=request ns=10', 'UNTITLED_PHASE name=request ns=-1',
                      'UNTITLED_PHASE name=request ns=10 suffix', 'x UNTITLED_PHASE name=request ns=10']:
            with self.assertRaises(ValueError):
                probe.parse_phases(log(valid()) + '\n' + extra)

    def test_causal_clock_reversals(self):
        for key, value in [('prepare_begin', 9), ('prepare_end', 19), ('worker_submitted', 29),
                           ('worker_enter', 29), ('worker_done', 34), ('collected', 44),
                           ('adopted', 59), ('postprocess_end', 69), ('finished', 74), ('probe_ready', 79)]:
            points = valid()
            points[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                probe.parse_phases(log(points))

    def test_tick_records_are_not_unique_job_phases(self):
        data = log(valid()) + '\nUNTITLED_PHASE name=tick_begin ns=20\nUNTITLED_PHASE name=tick_end ns=50'
        data += '\nUNTITLED_PHASE name=tick_begin ns=60\nUNTITLED_PHASE name=tick_end ns=90'
        self.assertEqual(probe.parse_phases(data), probe.parse_phases(log(valid())))

    def test_production_wake_source_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root / 'src/platform/macos/app_session/editor/save/wake.zig'
            marker.parent.mkdir(parents=True)
            marker.write_text('untouched')
            with self.assertRaisesRegex(ValueError, 'Historical probe'):
                probe.instrument(root)
            self.assertEqual(marker.read_text(), 'untouched')

    def test_copy_escape_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'copy'
            target = source / 'src/platform/macos/app_session/editor/save/as.zig'
            target.parent.mkdir(parents=True)
            outside = root / 'original.zig'
            outside.write_text('untouched')
            target.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'escapes'):
                probe.instrument(source)
            self.assertEqual(outside.read_text(), 'untouched')

    def test_summary_requires_actual_transport_identity_and_delay(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for mode in ('tick', 'event'):
                directory = root / mode
                directory.mkdir()
                rows = []
                for size in (65536, 1048576):
                    for delay in (0, 200):
                        for number in range(3):
                            sample = directory / f'{size}-{delay}-{number}'
                            sample.mkdir()
                            manifest = sample / 'manifest.json'
                            manifest.write_text(json.dumps({'binary_sha256': 'a' * 64}))
                            points = {key: value * 1_000_000 + (delay * 1_000_000 if key in ('worker_done', 'collected', 'adopted', 'postprocess_end', 'finished', 'probe_ready') else 0) for key, value in valid().items()}
                            record = log(points)
                            if mode == 'event':
                                record += '\nUNTITLED_EVENT_WAKE delivered=true' * 2
                            (sample / 'app.log').write_text(record)
                            rows.append(dict(manifest=str(manifest), bytes=size, injected_delay_ms=delay,
                                             call_ns=1_000_000, next_event_ns=2_000_000, settled_ns=80_000_000 + delay * 1_000_000))
                (directory / 'samples.json').write_text(json.dumps(rows))
            probe.summarize(root)
            result = json.loads((root / 'completion-phases.json').read_text())
            self.assertEqual(len(result['samples']), 24)
            self.assertEqual(len(result['groups']), 8)
            sample = root / 'event' / '65536-200-0'
            manifest = sample / 'manifest.json'
            original = manifest.read_text()
            for digest in ('', 'b' * 64):
                manifest.write_text(json.dumps({'binary_sha256': digest}))
                with self.assertRaises(ValueError):
                    probe.summarize(root)
            manifest.write_text(original)
            path = sample / 'app.log'
            original = path.read_text()
            path.write_text(original.replace('UNTITLED_EVENT_WAKE delivered=true', 'disabled'))
            with self.assertRaisesRegex(ValueError, 'transport'):
                probe.summarize(root)
            path.write_text(original.replace('name=worker_done ns=245000000', 'name=worker_done ns=35000001'))
            with self.assertRaisesRegex(ValueError, 'delay'):
                probe.summarize(root)

    def test_injection_anchor_requires_exactly_one_match(self):
        self.assertEqual(probe.replace_once('abc', 'b', 'x'), 'axc')
        for text in ['ac', 'abbc']:
            with self.assertRaises(ValueError):
                probe.replace_once(text, 'b', 'x')


if __name__ == '__main__':
    unittest.main()
