"""비교가 다른 fixture·표본을 섞거나 느린 마지막 색을 누락하지 않는지 검사한다."""
import copy
import unittest
import compare


class Comparison(unittest.TestCase):
    def setUp(self):
        self.value = {'host': {'macos': '26.5.1', 'logical_cpus': 16}, 'events': 30, 'repetitions': 3, 'groups': {'3000-typing-sync': {'fixture_sha256': 'same'}}}

    def test_control(self):
        compare.matched(self.value, copy.deepcopy(self.value))

    def test_fixture_drift(self):
        other = copy.deepcopy(self.value)
        other['groups']['3000-typing-sync']['fixture_sha256'] = 'changed'
        with self.assertRaisesRegex(ValueError, 'comparison fixture'):
            compare.matched(self.value, other)

    def test_population_drift(self):
        other = copy.deepcopy(self.value)
        other['events'] = 6
        with self.assertRaisesRegex(ValueError, 'comparison population'):
            compare.matched(self.value, other)

    def test_missing_case(self):
        other = copy.deepcopy(self.value)
        other['groups'] = {}
        with self.assertRaisesRegex(ValueError, 'comparison cases'):
            compare.matched(self.value, other)

    def test_host_drift(self):
        other = copy.deepcopy(self.value)
        other['host']['logical_cpus'] = 8
        with self.assertRaisesRegex(ValueError, 'comparison host'):
            compare.matched(self.value, other)

    def test_tail_and_gap_populations_stay_separate(self):
        runs = [{'last_full_color_ms': x, 'last_syntax_ms': 1, 'post_to_present_ms': {'median': 2, 'p95': 3},
                 'peak_rss_mib': 100, 'gap_samples': 24, 'full_color_observed_in_gap': 0} for x in [500, 600, 29000]]
        result = compare.aggregate(runs, 'same')
        self.assertEqual(result['last_full_color_median_ms'], 600)
        self.assertEqual(result['last_full_color_range_ms'], [500, 29000])
        self.assertEqual(result['gap_samples'], 72)
        self.assertEqual(result['full_color_observed_in_gap'], 0)


if __name__ == '__main__':
    unittest.main()
