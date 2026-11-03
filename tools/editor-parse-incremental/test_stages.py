"""진단의 구간 누락·모집단 혼합·잘못된 시간/분기 수락을 거절한다."""
import unittest
import stages


def fixture(full=False):
    rows = []
    for revision in range(1, 22):
        values = {name: 10 for name in stages.NAMES}
        if revision == 1:
            for name in ('prior_copy', 'leaf_copy', 'change', 'shift', 'refresh'):
                values[name] = 0
        elif full:
            values['leaf_copy'] = 0
        fields = ' '.join(f'{key}_ns={value}' for key, value in values.items())
        rows.append(f'WORKER_STAGE revision={revision} mode={"cold" if revision == 1 else "incremental"} mask={929 if revision == 1 else (1019 if full else 1023)} total_ns=1000 {fields} other_ns={1000 - sum(values.values())}')
    return '\n'.join(rows) + '\n'


def remove_phase(source, name, row_index=1):
    # 합계는 보존해 누락 판정 자체를 공격한다.
    rows = source.splitlines()
    row = rows[row_index]
    import re
    old = int(re.search(r'other_ns=(\d+)', row).group(1))
    row = row.replace(name + '_ns=10', name + '_ns=0')
    mask = int(re.search(r'mask=(\d+)', row).group(1))
    mask &= ~(1 << stages.NAMES.index(name))
    row = re.sub(r'mask=\d+', 'mask=' + str(mask), row)
    row = re.sub(r'other_ns=\d+', 'other_ns=' + str(old + 10), row)
    rows[row_index] = row
    return '\n'.join(rows) + '\n'


MEASURES = [dict(complete_ns=2000) for _ in range(20)]


class Stages(unittest.TestCase):
    def test_normal(self):
        for full in (False, True):
            self.assertEqual(len(stages.read(fixture(full), MEASURES, full)), 21)

    def test_distinct_bad_observations(self):
        source = fixture()
        cases = [
            source.replace('revision=21 ', 'revision=20 '),
            '\n'.join(source.splitlines()[1:]) + '\n',
            source + source.splitlines()[-1] + '\n',
            source.replace('revision=2 ', 'revision=22 '),
            source.replace('mode=cold', 'mode=incremental'),
            source.replace('mode=incremental', 'mode=cold', 1),
            source.replace('total_ns=1000', 'total_ns=999', 1),
            source.replace('other_ns=900', 'other_ns=901'),
            remove_phase(source, 'current_copy'),
            remove_phase(source, 'native'),
            remove_phase(source, 'summary'),
            remove_phase(source, 'folds'),
            remove_phase(source, 'brackets'),
            remove_phase(source, 'prior_copy'),
            remove_phase(source, 'change'),
            remove_phase(source, 'shift'),
            remove_phase(source, 'refresh'),
            remove_phase(source, 'leaf_copy'),
            source.replace('leaf_copy_ns=0', 'leaf_copy_ns=10', 1),
            source.replace('total_ns=1000', 'total_ns=-1', 1),
        ]
        for index, bad in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(ValueError):
                stages.read(bad, MEASURES, False)

    def test_runner_prefix(self):
        self.assertEqual(len(stages.read('1/1 measure.test...'+fixture(), MEASURES, False)), 21)

    def test_missing_full_branch(self):
        with self.assertRaises(ValueError):
            stages.read(fixture(), MEASURES, True)

    def test_zero_duration_with_call_is_valid(self):
        source = fixture().replace('brackets_ns=10', 'brackets_ns=0').replace('other_ns=950', 'other_ns=960').replace('other_ns=900', 'other_ns=910')
        self.assertEqual(len(stages.read(source, MEASURES, False)), 21)

    def test_containment(self):
        with self.assertRaises(ValueError):
            stages.read(fixture(), [dict(complete_ns=999) for _ in range(20)], False)

    def test_ambiguous_anchor(self):
        with self.assertRaises(ValueError):
            stages.instrument('not a worker')

    def test_duplicate_anchor(self):
        with self.assertRaises(ValueError):
            stages.once('abc abc', 'abc', 'xyz')

    def test_malformed_extra_row(self):
        with self.assertRaises(ValueError):
            stages.read(fixture() + 'WORKER_STAGE damaged\n', MEASURES, False)

    def test_overflow(self):
        with self.assertRaises(ValueError):
            stages.read(fixture().replace('total_ns=1000', f'total_ns={2**64}', 1), MEASURES, False)


if __name__ == '__main__':
    unittest.main()
