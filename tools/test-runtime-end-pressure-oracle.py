#!/usr/bin/env python3
"""Negative controls for the pressure probe's independent visible-text oracle.
These fixtures test only the judge, not a real daemon, socket, PTY, or GUI.
"""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('pressure', Path(__file__).with_name('test-runtime-end-pressure.py'))
pressure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pressure)


def record(kind, body):
    header = struct.pack('!HHQQII', 2, kind, 1, 0, 0, 1)
    return struct.pack('!I', len(header) + len(body)) + header + body


def run(text, width=1, count=1):
    return struct.pack('!I', len(text)) + text + struct.pack('!BI4I', width, count, 0, 0, 0, 0)


def row(runs, index=0):
    return record(2, struct.pack('!HI', index, len(runs)) + b''.join(runs))


class OracleTests(unittest.TestCase):
    def test_visible_positive_and_metadata_only_negative(self):
        self.assertEqual(pressure.text_rows(row([run(b'Z', count=80)])), ['Z' * 80])
        self.assertEqual(pressure.text_rows(record(5, b'Z' * 80)), [])

    def test_truncated_record_is_rejected(self):
        payload = row([run(b'Z', count=80)])
        for cut in (1, 4, 28, len(payload) - 1):
            with self.assertRaises(AssertionError):
                pressure.text_rows(payload[:cut])

    def test_invalid_utf8_is_rejected(self):
        with self.assertRaises(UnicodeDecodeError):
            pressure.text_rows(row([run(b'\xff', count=80)]))

    def test_zero_width_marker_cannot_create_visible_text(self):
        with self.assertRaises(AssertionError):
            pressure.text_rows(row([run(b'Z', width=0, count=80)]))

    def test_outside_viewport_and_overfull_rows_are_rejected(self):
        for payload in (row([run(b'Z', count=80)], index=24),
                        row([run(b'Z', width=2, count=80)]),
                        row([run(b'Z', count=79)])):
            with self.assertRaises(AssertionError):
                pressure.text_rows(payload)


if __name__ == '__main__':
    unittest.main()
