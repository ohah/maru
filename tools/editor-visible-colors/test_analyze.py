"""독립 손상 다섯 종류를 정상 대조와 같은 읽기 경로로 거절한다."""
import unittest
from analyze import HEIGHTS, read_log


def normal():
    lines = []
    for height in HEIGHTS:
        upper = (height + 19) // 20
        lines.append(f'VISIBLE_COLOR file=flat-3000.zig height={height} body_h={height} cell_h=20 first=31 queried_rows=256 visible_upper={upper} bounded_rows={upper+1} full_oracle=1 wrap=0 folded=0 ime=0')
        for rep in range(6):
            for bounded in range(2):
                lines.append(f'VISIBLE_COLOR_COST file=flat-3000.zig height={height} rep={rep} bounded={bounded} calls=32 ns=32000')
    return '\n'.join(lines) + '\nAll 5 tests passed.\n'


class Contract(unittest.TestCase):
    def test_normal_and_unrelated_output(self):
        self.assertEqual(read_log(normal(), 'flat-3000.zig'), read_log('unrelated\n' + normal(), 'flat-3000.zig'))

    def test_real_runner_prefix(self):
        text = normal().replace('VISIBLE_COLOR ', '2/5 app_session.editor.mod.test.visible color query 실제 검사...VISIBLE_COLOR ', 1)
        self.assertEqual(read_log(text, 'flat-3000.zig'), read_log(normal(), 'flat-3000.zig'))

    def test_missing_height(self):
        self.reject('\n'.join(line for line in normal().splitlines() if 'height=640 ' not in line))

    def test_absolute_index_mistaken_for_count(self):
        self.reject(normal().replace('queried_rows=256', 'queried_rows=287'))

    def test_candidate_ignores_height(self):
        self.reject(normal().replace('bounded_rows=10', 'bounded_rows=256'))

    def test_colour_oracle_missing(self):
        self.reject(normal().replace('full_oracle=1', 'full_oracle=0'))

    def test_cost_population_corrupt(self):
        self.reject(normal().replace('calls=32', 'calls=31', 1))

    def reject(self, text):
        self.assertEqual(len(read_log(normal(), 'flat-3000.zig')), 3)
        with self.assertRaises(AssertionError):
            read_log(text, 'flat-3000.zig')
        self.assertEqual(len(read_log(normal(), 'flat-3000.zig')), 3)


if __name__ == '__main__':
    unittest.main()
