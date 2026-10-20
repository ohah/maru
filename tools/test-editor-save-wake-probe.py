#!/usr/bin/env python3
"""안전망이 먼저 이긴 유효 표본과 조건이 섞인 잘못된 표본을 구분한다."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('probe-editor-save-wake.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def report():
    return dict(binary_sha256='a' * 64, optimize='Debug', product_passed=True,
                untitled_save_benchmark=dict(bytes=65536, injected_delay_ms=0))

class ProbeTests(unittest.TestCase):
    def check(self, mode, count, value=None):
        return probe.validate_sample(value or report(), 65536, 0, mode, count, 'a' * 64)
    def test_fallback_can_win_before_second_callback(self):
        self.check('event', 1)
        self.check('event', 3)
        self.check('tick', 0)
    def test_no_delivery_is_not_event_evidence(self):
        with self.assertRaises(ValueError): self.check('event', 0)
        with self.assertRaises(ValueError): self.check('tick', 1)
        with self.assertRaises(ValueError): self.check('unknown', 0)
    def test_binary_build_and_product_must_match(self):
        for key, value in [('binary_sha256', 'b' * 64), ('optimize', 'ReleaseFast'), ('product_passed', False)]:
            data = report(); data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check('event', 2, data)
    def test_size_and_injection_must_match(self):
        for key, value in [('bytes', 1048576), ('injected_delay_ms', 200)]:
            data = report(); data['untitled_save_benchmark'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check('event', 2, data)
    def test_instrumentation_anchor_must_be_unique(self):
        self.assertEqual(probe.once('abc', 'b', 'd'), 'adc')
        for text in ['', 'bb']:
            with self.assertRaises(ValueError): probe.once(text, 'b', 'd')

if __name__ == '__main__': unittest.main()
