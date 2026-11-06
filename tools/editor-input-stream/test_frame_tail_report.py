"""첫 키를 버리지 않고 같은 producing frame과 실제 표시를 연결하는지 검사한다."""
import copy
import unittest
import frame_tail_report as report
import verify


def fixture():
    app=dict(baseline=[0,0],display_frames=[[10,1,1,0,2,1200,1500,1600,7]],
        display_draws=[[10,1,0,1700,1800,1900,2000,2500,7]],
        target_budget_rows=[[9,1060,1000,1],[9,1150,1000,0],[9,1300,1000,1]],parse_stages=[[1,1150,9,0,1,1,1,0,7],[5,1400,9,0,1,1,1,0,7]],state=[0,1])
    for row in app['display_frames']:
        row[5:8]=[n*10000 for n in row[5:8]]
    for row in app['display_draws']:
        row[3:8]=[n*10000 for n in row[3:8]]
    for row in app['target_budget_rows']:row[1]*=10000
    for row in app['parse_stages']:row[1]*=10000
    return app,dict(post_ns=10000000),[1,123,10000000,11000000,0,0,25000000,10,1,0,0,1]


class Tail(unittest.TestCase):
    def analyze(self, values):return report.key_trace(*values,verify.require)

    def test_positive_denial_and_tick_already_started(self):
        values=fixture()
        result=self.analyze(values)
        self.assertEqual(result['denied_before_first_frame'],1)
        self.assertAlmostEqual(result['total_ms'],15)
        values[0]['display_frames'][0][5]=10500000
        values[0]['target_budget_rows']=values[0]['target_budget_rows'][2:]
        self.assertEqual(self.analyze(values)['parts_ms']['native_to_tick'],0)

    def test_distinct_bad_connections(self):
        def frame(index,value):return lambda a,p,k:a['display_frames'][0].__setitem__(index,value)
        def draw(index,value):return lambda a,p,k:a['display_draws'][0].__setitem__(index,value)
        faults=[
            lambda a,p,k:a.update(display_frames=[]),
            lambda a,p,k:a['display_frames'].append(copy.deepcopy(a['display_frames'][0])),
            frame(0,11),draw(0,11),draw(7,2501),frame(1,2),frame(2,2),draw(1,2),frame(3,1),
            frame(8,8),draw(8,8),
            lambda a,p,k:a['parse_stages'][0].__setitem__(8,8),
            lambda a,p,k:a['parse_stages'].append([1,1150,9,0,1,1,1,0,8]),
            lambda a,p,k:a.update(target_budget_rows=[]),
            lambda a,p,k:a['target_budget_rows'].append([9,14000000,1000,1]),
            lambda a,p,k:a['target_budget_rows'].append([9,14000000,1000,0]),
            lambda a,p,k:k.__setitem__(0,0),
            lambda a,p,k:k.__setitem__(0,True),
            lambda a,p,k:p.update(post_ns=12000000),
            lambda a,p,k:p.update(post_ns=1000.0),
            lambda a,p,k:k.__setitem__(3,0),
            frame(5,1550),frame(7,1400),draw(3,1550),draw(4,1650),draw(5,1750),draw(6,1850),draw(6,2600),
        ]
        for index,mutate in enumerate(faults):
            values=copy.deepcopy(fixture());mutate(*values)
            with self.subTest(index=index),self.assertRaises(ValueError):self.analyze(values)
