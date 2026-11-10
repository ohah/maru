"""실제 표시와 예상 경계·늦은 callback·관측 공백을 혼동하지 않는다."""
import copy
import unittest
from unittest.mock import patch
import display_timing_report as report


def sample():
    return dict(mode='enabled',started=1,ended=100,errors=0,overflow=0,observations=3,
        context=[1,120,77,1,0,3,60],rows=[[12,10,20,10,13],[23,20,30,10,24],[35,30,40,10,36]])


class DisplayTiming(unittest.TestCase):
    def test_late_callback_is_not_an_actual_refresh_boundary(self):
        value=sample();value['rows'][0][0]=21;value['rows'][0][4]=22
        context,rows=report.timing(value,'enabled')
        self.assertEqual(rows[0]['timestamp'],10)
        self.assertGreater(rows[0]['begin'],rows[0]['target'])
        self.assertEqual(context['frame_loop_hz'],60)

    def test_distinct_outcome_clock_schema_and_runtime_faults(self):
        mutations=[lambda x:x.update(mode='disabled'),lambda x:x.update(errors=1),lambda x:x.update(overflow=1),
            lambda x:x.update(started=0),lambda x:x.update(ended=1),lambda x:x.update(observations=1),
            lambda x:x.update(rows=[]),lambda x:x.update(rows=x['rows']*1400),lambda x:x.update(context=[]),
            lambda x:x['context'].__setitem__(0,0),lambda x:x['context'].__setitem__(1,0),lambda x:x['context'].__setitem__(2,0),
            lambda x:x['context'].__setitem__(3,2),lambda x:x['context'].__setitem__(4,2),lambda x:x['context'].__setitem__(5,1),
            lambda x:x['context'].__setitem__(6,0),lambda x:x['rows'][0].pop(),lambda x:x['rows'][0].__setitem__(0,False),
            lambda x:x['rows'][0].__setitem__(1,0),lambda x:x['rows'][0].__setitem__(2,10),lambda x:x['rows'][0].__setitem__(3,-1),
            lambda x:x['rows'][0].__setitem__(4,101),lambda x:x['rows'][0].__setitem__(0,14),
            lambda x:x['rows'][1].__setitem__(1,9)]
        for i,mutate in enumerate(mutations):
            value=sample();mutate(value)
            with self.subTest(fault=i),self.assertRaises(ValueError):report.timing(value,'enabled')
            report.timing(sample(),'enabled')

    def test_disabled_observer_keeps_runtime_context(self):
        value=sample();value.update(mode='disabled',rows=[])
        self.assertEqual(report.timing(value,'disabled')[1],[])
        value['rows']=sample()['rows']
        with self.assertRaises(ValueError):report.timing(value,'disabled')

    def test_coverage_missing_and_overlapping_brackets_are_explicit(self):
        _,rows=report.timing(sample(),'enabled')
        gpu=[dict(generation=1,renderer=5,gpu_end=25,presented=50)]
        result=report.associate(rows,gpu)[0]
        self.assertEqual(result['observed_brackets'],1)
        self.assertEqual(result['gpu_end_to_next_observed_timestamp_ms'],5e-6)
        self.assertEqual(result['next_observed_timestamp_to_present_ms'],20e-6)
        rows[1]['target']=24
        self.assertEqual(report.associate(rows,gpu)[0]['observed_brackets'],0)
        rows[0]['target']=26
        self.assertEqual(report.associate(rows,gpu)[0]['observed_brackets'],1)
        rows[1]['target']=30
        self.assertEqual(report.associate(rows,gpu)[0]['observed_brackets'],2)
        for stamp in (9,31):
            with self.assertRaises(ValueError):report.associate(rows,[dict(gpu[0],gpu_end=stamp)])

    def test_repeated_timestamp_and_negative_residual_are_not_hidden(self):
        _,rows=report.timing(sample(),'enabled');rows[1]['timestamp']=10
        result=report.associate(rows,[dict(generation=1,renderer=1,gpu_end=15,presented=18)])[0]
        self.assertEqual(result['observed_brackets'],2)
        self.assertEqual(result['next_observed_timestamp_to_present_ms'],-12e-6)

    def test_analyze_preserves_first_drawable_join_and_disabled_mode(self):
        value=sample();app=dict(display_timing=value,submit_rows=[],keys=[])
        parent=dict(keys=[])
        with patch.object(report.submit,'analyze',return_value=parent):
            result=report.analyze(app,{}, {},'enabled');self.assertEqual(result['callbacks'],3)
            app['keys']=[[1,0,0,0,0,0,50,7]]
            with self.assertRaises(ValueError):report.analyze(app,{}, {},'enabled')
