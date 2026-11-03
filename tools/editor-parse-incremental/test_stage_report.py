"""정규식 reader와 독립적인 원시 토큰/합계 대조의 손상 입력을 검사한다."""
import unittest
import stage_report
from test_stages import fixture


class Report(unittest.TestCase):
    def test_normal_and_runner_prefix(self):
        for full in (False, True):
            self.assertEqual(len(stage_report.raw_stages('1/1 test...'+fixture(full))), 21)

    def test_malformed_raw_rows(self):
        source = fixture()
        bad_rows = [
            source.replace('total_ns=1000', 'total_ns=999', 1),
            source.replace('other_ns=950', 'other_ns=0', 1),
            source.replace('native_ns=10', 'native_ns=-1', 1),
            source.replace('native_ns=10', 'native_ns=true', 1),
            source.replace('native_ns=10', 'native_ns=1.0', 1),
            source.replace('native_ns=10', 'unknown_ns=10', 1),
            source.replace('native_ns=10', 'native_ns=10 native_ns=10', 1),
            source.replace('revision=21 ', 'revision=20 '),
            source.replace('revision=2 ', 'revision=22 '),
            source + source.splitlines()[-1] + '\n',
            '\n'.join(source.splitlines()[1:]) + '\n',
            source.replace('total_ns=1000', f'total_ns={2**64}', 1),
        ]
        for index, bad in enumerate(bad_rows):
            with self.subTest(index=index), self.assertRaises(ValueError):
                stage_report.raw_stages(bad)


if __name__ == '__main__':
    unittest.main()
