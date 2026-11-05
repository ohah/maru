"""다른 프레임·세대·drawable이나 미완료 callback을 표시 비용으로 섞지 않는다."""
import copy
import unittest
import display_stages as stages
import verify


def fixture():
    return dict(display_stage_header=[1,1,0,0],
                display_frames=[[2,31,30,1,3,1000000,4000000,5000000,11]],
                display_draws=[[2,30,1,6000000,7000000,8000000,9000000,10000000,11]],
                baseline=[0,1],syntax_presentations=[[10000000,2,30]])


class Display(unittest.TestCase):
    def analyze(self, app):
        return stages.analyze(app,{'count':30},2000000,11,verify.require)

    def test_tick_already_running(self):
        result = self.analyze(fixture())
        self.assertTrue(result['tick_in_progress_at_install'])
        self.assertEqual(result['elapsed_ms']['wait_for_tick'],0)
        self.assertEqual(result['elapsed_ms']['frame_prepare'],2)
        self.assertEqual(result['elapsed_ms']['installed_to_present'],8)

    def test_tick_starts_later(self):
        app = fixture()
        app['display_frames'][0][5] = 3000000
        result = self.analyze(app)
        self.assertFalse(result['tick_in_progress_at_install'])
        self.assertEqual(result['elapsed_ms']['wait_for_tick'],1)
        self.assertEqual(result['elapsed_ms']['frame_prepare'],1)

    def test_distinct_corruptions(self):
        def f(column,value):return lambda a:a['display_frames'][0].__setitem__(column,value)
        def d(column,value):return lambda a:a['display_draws'][0].__setitem__(column,value)
        faults = [
            lambda a:a.update(display_stage_header=[]),
            lambda a:a['display_stage_header'].__setitem__(0,True),
            lambda a:a['display_stage_header'].__setitem__(2,1),
            lambda a:a['display_stage_header'].__setitem__(3,1),
            lambda a:a.update(display_frames=[]),
            lambda a:a.update(display_draws=[]),
            lambda a:a['display_frames'][0].pop(),
            lambda a:a['display_draws'][0].pop(),
            f(0,9),d(0,9),f(1,32),f(2,29),d(1,29),
            f(3,0),d(2,0),f(4,2),f(8,99),d(8,99),
            f(5,0),f(6,0),f(7,0),d(3,0),d(4,0),d(5,0),d(6,0),
            f(5,6000000),f(6,6000000),f(7,7000000),
            d(3,8000000),d(4,9000000),d(5,11000000),d(6,11000000),d(7,11000000),
            f(1,-1),f(1,2**64),d(2,True),d(2,1.0),
            f(6,1000000),
        ]
        for index, mutate in enumerate(faults):
            app = copy.deepcopy(fixture())
            mutate(app)
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.analyze(app)

    def test_duplicate_frame_and_drawable(self):
        for field,index in [('display_frames',0),('display_draws',1)]:
            app = fixture()
            app[field].append(copy.deepcopy(app[field][0]))
            app['display_stage_header'][index] = 2
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.analyze(app)


if __name__ == '__main__':
    unittest.main()
