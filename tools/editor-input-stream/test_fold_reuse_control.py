"""워밍업 계수만으로 실제 입력의 접힘 재사용을 주장하지 않는지 검사한다."""
import copy
import unittest
import fold_reuse_control as control
import verify


class FoldReuse(unittest.TestCase):
    def validate(self, mode, final, baseline):
        control.validate({'fold_reuse_stats': final, 'fold_reuse_baseline_stats': baseline}, {'fold_reuse_control': mode}, verify.require)

    def test_normal_paths(self):
        self.validate('prepared', [12, 11, 0, 0, 9], [2, 2, 0, 0, 0])
        self.validate('disabled', [0, 0, 12, 0, 9], [0, 0, 2, 0, 0])
        self.validate('prepared', [12, 11, 0, 3, 9], [2, 2, 0, 3, 0])
        control.validate({}, {}, verify.require)

    def test_distinct_bad_paths(self):
        bad = [
            ('prepared', [2, 2, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('disabled', [0, 0, 2, 0, 0], [0, 0, 2, 0, 0]),
            ('prepared', [12, 2, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 13, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 1, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 1, 0, 0], [2, 2, 1, 0, 0]),
            ('disabled', [1, 0, 12, 0, 0], [0, 0, 2, 0, 0]),
            ('disabled', [0, 1, 12, 0, 0], [0, 0, 2, 0, 0]),
            ('prepared', [1, 1, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 1, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('disabled', [0, 0, 1, 0, 0], [0, 0, 2, 0, 0]),
            ('prepared', [12, 12, 0, 1, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 0, 0, 0], [2, 2, 0, 1, 0]),
            ('prepared', [], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 0, 0, 0], []),
            ('prepared', [True, 12, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12.0, 12, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 0, 0, -1], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 0, 0, 0], [2, 2, 0, 0, 2**64]),
            ('wrong', [12, 12, 0, 0, 0], [2, 2, 0, 0, 0]),
            ('prepared', [12, 12, 0, 0, 0], [2, 3, 0, 0, 0]),
        ]
        for index, args in enumerate(bad):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.validate(*args)

    def test_missing_observations(self):
        with self.assertRaises(ValueError):
            control.validate({}, {'fold_reuse_control': 'prepared'}, verify.require)

    def test_syntax_presentations_are_required(self):
        from test_bracket_control import SyntaxStages
        app, producer, meta = SyntaxStages().fixture()
        meta.pop('bracket_control')
        meta['fold_reuse_control'] = 'prepared'
        result = control.stages(app, producer, meta, verify.require)
        self.assertGreater(result['last_post_to_syntax_present_ms'], 0)
        broken = copy.deepcopy(app)
        del broken['syntax_presentations']
        with self.assertRaises(ValueError):
            control.stages(broken, producer, meta, verify.require)


if __name__ == '__main__':
    unittest.main()
