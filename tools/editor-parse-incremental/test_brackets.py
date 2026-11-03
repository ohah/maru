"""실측 reader가 빠진 입력과 잘못된 실행 분기를 통과시키지 않는지 검사한다."""
import unittest
import brackets


def sample(full=False, accuracy=0):
    rows = [f'PARSE_MEASURE index={i} mode=incremental accuracy={accuracy} submit_ns=10 complete_ns=20 nodes={100 if accuracy else 0} bracket_rebuilds={int(full)} bracket_partials={int(not full)} bracket_leaves=50' for i in range(20)]
    return '\n'.join(rows) + '\nAll 1 tests passed.\n'


class Reader(unittest.TestCase):
    def test_normal_controls(self):
        for full in (False, True):
            for accuracy in (0, 1):
                self.assertEqual(len(brackets.read_rows(sample(full, accuracy), accuracy, full)), 20)

    def test_missing_row(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample().replace('index=19 ', 'index=18 '), 0, False)

    def test_wrong_branch(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample(True), 0, False)

    def test_mixed_branch(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample().replace('bracket_rebuilds=0', 'bracket_rebuilds=1', 1), 0, False)

    def test_missing_accuracy(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample(accuracy=1).replace('nodes=100', 'nodes=0'), 1, False)

    def test_wrong_accuracy(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample(), 1, False)

    def test_empty_leaves(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample().replace('bracket_leaves=50', 'bracket_leaves=0'), 0, False)

    def test_inverted_times(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample().replace('submit_ns=10', 'submit_ns=30'), 0, False)

    def test_unsuccessful_run(self):
        with self.assertRaises(ValueError):
            brackets.read_rows(sample().replace('All 1 tests passed.', 'failed'), 0, False)


if __name__ == '__main__':
    unittest.main()
