"""GPU 구간, callback 신원과 독립 시각의 계약을 고정한다."""
import copy
import unittest
from unittest.mock import patch
import submit_display as schema
import submit_display_report as report


def row():
    return dict(generation=2,prefix=1,ready=0,renderer=9000000,commit=10000000,returned=10100000,kernel_start=10200000,kernel_end=10400000,gpu_start=10800000,gpu_end=11800000,scheduled_cb=10500000,completed_cb=13000000,presented=30000000,status=4,error=0,main_thread=11,scheduled_thread=22,completed_thread=23,presented_thread=24,presented_cb=31000000,command_buffer=1111,drawable=2222,scheduled_buffer=1111,completed_buffer=1111,presented_drawable=2222)


def raw(value):return [value[name] for name in schema.FIELDS]


class SubmitDisplay(unittest.TestCase):
    def analyze(self,value):return report.partition(report.decode(raw(value)))

    def test_gpu_timeline_and_kernel_serial_partition(self):
        result=self.analyze(row())
        self.assertEqual(result['parts_ms'],dict(commit_to_gpu_start=.8,gpu_execution=1,gpu_end_to_present=18.2))
        self.assertEqual(sum(result['parts_ms'].values()),20)
        self.assertEqual(result['serial_parts_ms'],dict(commit_to_kernel_start=.2,kernel_schedule=.2,kernel_end_to_gpu_start=.4))
        self.assertEqual(result['commit_call_ms'],.1)

    def test_callbacks_and_commit_return_are_not_gpu_execution_boundaries(self):
        value=row();value.update(returned=15000000,scheduled_cb=25000000,completed_cb=32000000)
        result=self.analyze(value)
        self.assertTrue(result['gpu_started_before_commit_return'])
        self.assertEqual(result['parts_ms']['gpu_execution'],1)
        self.assertEqual(result['parts_ms']['gpu_end_to_present'],18.2)
        self.assertEqual(result['completed_callback_after_gpu_ms'],20.2)

    def test_kernel_can_overlap_gpu_without_negative_queue_time(self):
        value=row();value.update(kernel_start=10700000,kernel_end=11000000)
        result=self.analyze(value)
        self.assertFalse(result['serial_kernel_before_gpu'])
        self.assertIsNone(result['serial_parts_ms'])
        self.assertEqual(result['kernel_inside_pre_gpu_ms'],.1)
        self.assertEqual(result['pre_gpu_outside_kernel_ms'],.7)
        self.assertEqual(sum(result['parts_ms'].values()),20)

    def test_object_ids_can_be_reused_after_a_completed_invocation(self):
        original=row();later=copy.deepcopy(original)
        for name in ['renderer','commit','returned','kernel_start','kernel_end','gpu_start','gpu_end','scheduled_cb','completed_cb','presented','presented_cb']:later[name]+=40000000
        later['generation']=3
        self.assertEqual(self.analyze(original)['parts_ms'],self.analyze(later)['parts_ms'])

    def test_distinct_clock_outcome_and_ownership_faults(self):
        faults=[('status',5),('error',1),('gpu_start',0),('gpu_end',0),('gpu_start',9000000),('gpu_end',10000000),('gpu_end',31000000),('presented',10000000),('returned',9000000),('kernel_start',11000000),('kernel_end',0),('completed_cb',11000000),('scheduled_cb',9000000),('presented_cb',29000000),('scheduled_buffer',99),('completed_buffer',99),('presented_drawable',99),('command_buffer',0),('drawable',0),('main_thread',0),('scheduled_thread',0),('completed_thread',0),('presented_thread',0),('gpu_start',True),('gpu_end',-1),('gpu_end',2**64),('ready',2),('prefix',0)]
        for name,value in faults:
            changed=row();changed[name]=value
            with self.subTest(field=name,value=value),self.assertRaises(ValueError):self.analyze(changed)
        for changed in [raw(row())[:-1],raw(row())+[1]]:
            with self.assertRaises(ValueError):report.decode(changed)

    def test_complete_row_matches_same_drawable_and_first_input(self):
        value=row();app=dict(submit_display_mode='enabled',submit_fields=list(schema.FIELDS),submit_header=[1,0,0,1,0],submit_rows=[raw(value)],display_draws=[[2,1,0,8000000,9000000,9900000,10000000,30000000,11]],keys=[[1,0,0,0,0,0,30000000,2,1,0,0,1]])
        parent=dict(keys=[dict(sequence=1,parts_ms=dict(commit_to_present=20))])
        with patch.object(report.base,'analyze',return_value=parent):
            self.assertEqual(report.analyze(app,{}, {},'enabled')['keys'][0]['parts_ms']['gpu_execution'],1)
            for mutate in [lambda a:a['submit_header'].__setitem__(2,1),lambda a:a['submit_header'].__setitem__(1,1),lambda a:a['submit_header'].__setitem__(4,1),lambda a:a['submit_rows'][0].__setitem__(schema.FIELDS.index('renderer'),1),lambda a:a['submit_rows'][0].__setitem__(schema.FIELDS.index('commit'),9999999),lambda a:a['submit_rows'][0].__setitem__(schema.FIELDS.index('presented'),29999999),lambda a:a['submit_rows'][0].__setitem__(schema.FIELDS.index('main_thread'),99),lambda a:a['submit_fields'].reverse()]:
                changed=copy.deepcopy(app);mutate(changed)
                with self.assertRaises(ValueError):report.analyze(changed,{}, {},'enabled')
            disabled=copy.deepcopy(app);disabled.update(submit_display_mode='disabled',submit_header=[0,0,0,0,0],submit_rows=[])
            self.assertEqual(report.analyze(disabled,{}, {},'disabled')['keys'],[])
            disabled['submit_rows']=[raw(value)]
            with self.assertRaises(ValueError):report.analyze(disabled,{}, {},'disabled')


if __name__=='__main__':unittest.main()
