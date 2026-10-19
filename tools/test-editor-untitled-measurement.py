#!/usr/bin/env python3
"""실패하거나 서로 다른 실측을 성공 표본으로 집계하지 않는 반례 검사."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / 'editor-project-search-app'))
from untitled_oracle import parse_metrics, validate_report, parse_build_mode

TEXT = 'UNTITLED_SERIALIZE ns=10\nUNTITLED_IO ns=20\nUNTITLED_SAVE_METRIC call_ns=200000100 next_event_ns=200000200 passed=true\n'


def report():
    return dict(product_passed=True, untitled_save_benchmark=parse_metrics(TEXT, 65536, 200),
                binary_sha256='binary', untitled_prepared_source_sha256={'writer': 'source'},
                harness_sha256={'driver': 'driver'}, runner_sha256='runner',
                untitled_oracle_sha256='oracle', optimize='Debug')


class MeasurementTests(unittest.TestCase):
    def test_actual_build_mode_is_unique_and_recognized(self):
        for raw, mode in [('debug', 'Debug'), ('release_fast', 'ReleaseFast')]:
            self.assertEqual(parse_build_mode('UNTITLED_BUILD mode=' + raw), mode)
        for text in ['', 'UNTITLED_BUILD mode=debugX', 'UNTITLED_BUILD mode=release_safe',
                     'UNTITLED_BUILD mode=debug\nUNTITLED_BUILD mode=release_fast']:
            with self.subTest(text=text), self.assertRaises(ValueError): parse_build_mode(text)

    def test_async_response_may_precede_io_but_not_settlement(self):
        text = TEXT.replace('call_ns=200000100 next_event_ns=200000200', 'call_ns=100 next_event_ns=200') + 'UNTITLED_SETTLED ns=210000000\n'
        self.assertEqual(parse_metrics(text, 65536, 200, require_settled=True)['settled_ns'], 210000000)
        for changed in [text.replace('ns=210000000', 'ns=100'), TEXT]:
            with self.assertRaises(ValueError): parse_metrics(changed, 65536, 200, require_settled=True)

    def test_success_control_and_exact_records(self):
        self.assertEqual(parse_metrics(TEXT, 65536, 200)['call_ns'], 200000100)
        for changed in [TEXT.replace('passed=true', 'passed=trueX'), TEXT.replace('passed=true', 'passed=false'),
                        TEXT.replace('ns=10', 'ns=-10'), TEXT.replace('ns=10', 'ns=1.0')]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                parse_metrics(changed, 65536, 200)

    def test_each_record_missing_or_duplicated_fails(self):
        for line in TEXT.splitlines():
            for changed in [TEXT.replace(line + '\n', ''), TEXT + line + '\n']:
                with self.subTest(line=line), self.assertRaises(ValueError):
                    parse_metrics(changed, 65536, 200)

    def test_phase_sum_and_next_event_order(self):
        for changed in [TEXT.replace('UNTITLED_IO ns=20\n', 'UNTITLED_IO ns=200\n'), TEXT.replace('next_event_ns=200000200', 'next_event_ns=1'),
                        TEXT.replace('call_ns=200000100', 'call_ns=100')]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                parse_metrics(changed, 65536, 200)

    def test_success_is_boolean_not_truthy(self):
        for value in ['false', 'true', 1, None, False]:
            r = report(); r['product_passed'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_report(r, 65536, 200)

    def test_wrong_condition_or_invalid_clock_fails(self):
        for key, value in [('bytes', 1048576), ('injected_delay_ms', 0), ('bytes', 65536.0),
                           ('call_ns', True), ('io_ns', -1), ('serialize_ns', 300000000),
                           ('next_event_ns', 1), ('call_ns', float('nan'))]:
            r = report(); r['untitled_save_benchmark'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate_report(r, 65536, 200)

    def test_mixed_or_missing_provenance_fails(self):
        _, first = validate_report(report(), 65536, 200)
        validate_report(report(), 65536, 200, first)
        for key in first:
            for mode in ['missing', 'changed']:
                r = copy.deepcopy(report())
                if mode == 'missing': del r[key]
                else: r[key] = {'different': 'source'} if isinstance(r[key], dict) else 'different'
                with self.subTest(key=key, mode=mode), self.assertRaises(ValueError):
                    validate_report(r, 65536, 200, first)


if __name__ == '__main__':
    unittest.main()
