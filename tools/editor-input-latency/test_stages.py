"""부재인 색을 0ms로 바꾸거나 서로 다른 표본의 단계를 더하는 결론을 막는다."""
import copy
import unittest
import stages
import test_verify


class StageContract(unittest.TestCase):
    def setUp(self):
        fixture = test_verify.Contract()
        fixture.setUp()
        self.value = fixture.value
        self.run = dict(fixture.run, path='run')
        row = self.value['rows'][-1]
        gen = row['before'][0]
        row['timing'][8], row['timing'][10], row['after'][0] = gen+2, gen+3, gen+3

    def check(self, value):
        return stages.run_stages(value, self.run, 6)

    def test_components_and_no_steady_interval(self):
        value = copy.deepcopy(self.value)
        row = value['rows'][-1]
        t = row['timing']
        t[3], t[5], t[6], t[9] = (t[1]+delta for delta in [2, 7, 18, 43])
        gen = row['before'][0]
        t[7], t[8], t[10], row['after'][0] = gen+1, gen+2, gen+3, gen+3
        result = self.check(value)
        for name, ns in zip(stages.FIELDS, [2, 5, 11, 25, 43]):
            self.assertAlmostEqual(result[name], ns/1e6)
        self.assertAlmostEqual(result['post_to_full_ms'], sum(result[k] for k in stages.FIELDS[:-1]))
        self.assertIsNone(result['post_spacing_ms'])
        self.assertEqual(result['gap_samples'], 0)

    def test_warmup_cannot_be_the_entire_population(self):
        value = copy.deepcopy(self.value)
        value['rows'].pop()
        with self.assertRaisesRegex(ValueError, 'not enough post-warmup events'):
            stages.run_stages(value, self.run, 5)

    def test_same_frame_is_a_valid_zero_duration(self):
        value = copy.deepcopy(self.value)
        t = value['rows'][-1]['timing']
        t[6] = t[9] = t[5]
        t[8] = t[10] = t[7]
        result = self.check(value)
        self.assertEqual(result['first_to_syntax_ms'], 0)
        self.assertEqual(result['syntax_to_full_ms'], 0)

    def test_missing_final_color_is_not_zero_duration(self):
        value = copy.deepcopy(self.value)
        value['rows'][-1]['timing'][9] = 0
        with self.assertRaises(ValueError):
            self.check(value)

    def test_one_frame_cannot_have_different_readiness_times(self):
        for first, second in [(7, 8), (8, 10)]:
            value = copy.deepcopy(self.value)
            value['rows'][-1]['timing'][second] = value['rows'][-1]['timing'][first]
            with self.subTest(second=second), self.assertRaisesRegex(ValueError, 'one frame contradictory presentation times'):
                self.check(value)

    def test_observed_color_cannot_run_backward(self):
        value = copy.deepcopy(self.value)
        value['rows'][-1]['timing'][6] = value['rows'][-1]['timing'][5]-1
        with self.assertRaises(ValueError):
            self.check(value)

    def test_group_keeps_actual_process_components(self):
        result = self.check(self.value)
        value = copy.deepcopy(self.value)
        value['rows'][-1]['timing'][9] += 12_345_000_000
        other = self.check(value)
        group = stages.aggregate([result, other, result])
        self.assertEqual(group['per_process'][1]['post_to_full_ms'], other['post_to_full_ms'])
        self.assertIsNone(group['median_process_post_spacing_ms'])


if __name__ == '__main__':
    unittest.main()
