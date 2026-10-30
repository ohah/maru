"""시계 값은 입력 자료다. 벽시계 속도를 CI 통과 조건으로 삼지 않는다."""
import copy
import unittest
import verify

class Contract(unittest.TestCase):
    def setUp(self):
        self.run={'mode':'sync','flow':'typing','pid':123}
        self.value={'schema':1,'error':None,'restored':True,'mode':'sync','flow':'typing','pid':123,
            'memory':[200000000,190000000],'baseline_memory':[180000000,170000000],'rows':[]}
        for i in range(6):
            gen=10+i*3;at=1000000000+i*1000
            self.value['rows'].append({'seq':i+1,'foreground':True,'text_verified':True,'visible_line':'// '+'x'*(i+1),
                'before':[gen,20+i,0,1,1,100+i,1],'after':[gen+2,21+i,0,1,1,101+i,1],
                'timing':[i+1,at,at-1,at+1,7,at+3,at+4,gen+1,gen+1,at+5,gen+2]})
    def check(self,value):verify.validate(value,self.run,6)
    def test_control(self):self.check(self.value)
    def rejects(self,change):
        value=copy.deepcopy(self.value);change(value)
        with self.assertRaises(ValueError):self.check(value)
        self.check(self.value)
    def test_foreground(self):self.rejects(lambda v:v['rows'][0].__setitem__('foreground',False))
    def test_stale_frame(self):self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(7,9))
    def test_missing_presentation(self):self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(5,0))
    def test_claimed_mode(self):self.rejects(lambda v:v['rows'][0]['after'].__setitem__(6,3))
    def test_wrong_visible_text(self):self.rejects(lambda v:v['rows'][0].__setitem__('visible_line','// xx'))
    def test_actual_clock_slowness_is_not_rejected(self):
        v=copy.deepcopy(self.value)
        for i,r in enumerate(v['rows']):
            for index in [1,2,3,5,6,9]:r['timing'][index]+=i*10_000_000_000
            for index in [5,6,9]:r['timing'][index]+=5_000_000_000
        self.check(v)
    def test_preedit_without_committed_revision_is_valid(self):
        v=copy.deepcopy(self.value);v['rows'][0]['after'][1]=20;v['rows'][0]['after'][2]=555;self.check(v)
    def test_duplicate_sequence(self):self.rejects(lambda v:v['rows'][1].__setitem__('seq',1))
    def test_ready_before_color(self):self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(9,1))
    def test_superseded_color_is_not_claimed_complete(self):
        v=copy.deepcopy(self.value);v['mode']='async';r=dict(self.run,mode='async')
        for row in v['rows']:row['before'][6]=3;row['after'][6]=3
        row=v['rows'][0]
        for k in [6,8,9,10]:row['timing'][k]=0
        row['after'][3]=0;row['after'][6]=2
        verify.validate(v,r,6)
    def test_last_color_cannot_be_censored(self):
        self.rejects(lambda v:v['rows'][-1]['timing'].__setitem__(9,0))
    def test_late_receipt_cannot_be_credited_to_old_input(self):
        self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(9,v['rows'][1]['timing'][1]+1))
    def test_float_schema(self):self.rejects(lambda v:v.__setitem__('schema',1.0))
    def test_missing_event(self):self.rejects(lambda v:v['rows'].pop())
    def test_wrong_process(self):self.rejects(lambda v:v.__setitem__('pid',124))
    def test_unrestored_input_source(self):self.rejects(lambda v:v.__setitem__('restored',False))
    def test_error_with_complete_rows(self):self.rejects(lambda v:v.__setitem__('error','timeout'))
    def test_peak_rss_reversal(self):self.rejects(lambda v:v['memory'].__setitem__(0,1))
    def test_wrong_hid_key(self):self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(4,49))
    def test_unchanged_document(self):self.rejects(lambda v:v['rows'][0]['after'].__setitem__(1,20))
    def test_wrong_shared_view_count(self):self.rejects(lambda v:v['rows'][0]['after'].__setitem__(4,2))
    def test_float_clock(self):self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(3,1.0))
    def test_native_arrival_before_post(self):self.rejects(lambda v:v['rows'][0]['timing'].__setitem__(3,1))
if __name__=='__main__':unittest.main()
