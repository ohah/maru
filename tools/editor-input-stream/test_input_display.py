"""첫 표시의 실제 소유권·구간 합·경계 CPU를 고정한다."""
import copy
import unittest
import input_display_report as report
import protocol


def fixture():
    app = dict(baseline=[1,10], display_frames=[[2,11,1,0,0,3000000,6000000,7000000,11]], display_draws=[[2,1,0,8000000,9000000,15000000,16000000,20000000,11]], input_drawables=[[2,1,0,9000000,10000000,11000000,12000000,13000000,11]], input_display_mode='timed', input_interval_started=[2,1], input_interval_completed=[1,1], input_interval_errors=0, input_finish_handler_begin=21000000, input_intervals=[[1,protocol.MAGIC|1,2100000,3000000,500000,11],[0,0,4000000,5000000,200000,11]])
    key = [1,protocol.MAGIC|1,1000000,2000000,0,0,20000000,2,1,0,0,1]
    return app, dict(post_ns=1000000), key


class InputDisplay(unittest.TestCase):
    def trace(self, app, event, key):
        return report.key_trace(app, event, key, 11)

    def test_pending_first_frame_and_exact_partition(self):
        result = self.trace(*fixture())
        self.assertEqual(result['total_ms'],19)
        self.assertEqual(result['native_to_present_ms'],18)
        self.assertEqual(result['parts_ms'],dict(post_to_native=1,native_to_tick=1,frame_prepare=3,tick_finalize=1,wait_for_swift=1,swift_prepare=1,renderer_before_drawable=1,terminal_drawable=1,overlay_drawable=1,renderer_other=3,arm_to_commit=1,commit_to_present=4))
        self.assertEqual(sum(result['parts_ms'].values()),19)

    def test_no_overlay_and_tick_already_running(self):
        app,event,key=fixture()
        app['input_drawables'][0][6:8]=[0,0]
        app['display_frames'][0][5]=1500000
        result=self.trace(app,event,key)
        self.assertEqual(result['parts_ms']['native_to_tick'],0)
        self.assertEqual(result['parts_ms']['frame_prepare'],4)
        self.assertEqual(result['parts_ms']['overlay_drawable'],0)
        self.assertEqual(result['parts_ms']['renderer_other'],4)
        self.assertEqual(sum(result['parts_ms'].values()),19)

    def test_coalesced_keys_share_frame_but_keep_individual_latency(self):
        app,event,key=fixture()
        app['display_frames'][0][1:3]=[12,2]
        app['display_draws'][0][1]=app['input_drawables'][0][1]=key[8]=2
        first=self.trace(app,event,key)
        second=copy.deepcopy(key)
        second[0:4]=[2,protocol.MAGIC|2,1500000,2500000]
        last=self.trace(app,dict(post_ns=1500000),second)
        self.assertEqual(first['total_ms'],19)
        self.assertEqual(last['total_ms'],18.5)

    def test_frame_and_acquisition_corruptions(self):
        def frame(column,value):return lambda a,e,k:a['display_frames'][0].__setitem__(column,value)
        def draw(column,value):return lambda a,e,k:a['display_draws'][0].__setitem__(column,value)
        def acquired(column,value):return lambda a,e,k:a['input_drawables'][0].__setitem__(column,value)
        faults=[frame(0,9),draw(0,9),frame(1,12),frame(2,2),draw(1,2),draw(2,1),frame(8,99),draw(8,99),acquired(0,9),acquired(1,2),acquired(2,1),acquired(3,9000001),acquired(8,99),acquired(4,8000000),acquired(5,16000000),acquired(6,10000000),acquired(7,16000000),acquired(4,True),frame(6,9000000),draw(3,6000000),draw(4,16000000),draw(6,21000000),lambda a,e,k:a['display_frames'].append(copy.deepcopy(a['display_frames'][0])),lambda a,e,k:a['input_drawables'].append(copy.deepcopy(a['input_drawables'][0]))]
        for mutate in faults:
            args=copy.deepcopy(fixture());mutate(*args)
            with self.subTest(mutation=faults.index(mutate)),self.assertRaises(ValueError):self.trace(*args)

    def test_interval_cpu_is_not_proportioned_at_boundary(self):
        app,event,key=fixture()
        own=report.intervals(app,[key],'timed',11)
        result=report.overlap(own[0],4500000,6000000)
        self.assertEqual(result,dict(wall_ms=.5,contained_cpu_ms=0,boundary_intervals=1))
        result=report.overlap(own[0],3000000,6000000)
        self.assertEqual(result,dict(wall_ms=1,contained_cpu_ms=.2,boundary_intervals=0))

    def test_interval_identity_counters_cpu_and_unfinished_handler(self):
        def row(index,column,value):return lambda a:a['input_intervals'][index].__setitem__(column,value)
        faults=[lambda a:a.update(input_display_mode='untimed'),lambda a:a.update(input_interval_errors=1),lambda a:a.update(input_interval_started=[1,1]),lambda a:a.update(input_interval_completed=[1,0]),lambda a:a.update(input_finish_handler_begin=19000000),row(0,1,protocol.MAGIC|2),row(0,2,1000000),row(0,3,2100000),row(0,4,1000000),row(0,5,99),row(1,1,1),row(1,2,True),lambda a:a['input_intervals'].pop()]
        for mutate in faults:
            app,event,key=fixture();mutate(app)
            with self.subTest(mutation=faults.index(mutate)),self.assertRaises(ValueError):report.intervals(app,[key],'timed',11)

    def test_untimed_control_keeps_counts_and_does_not_claim_cpu(self):
        app,event,key=fixture()
        app.update(input_display_mode='untimed',input_intervals=[],input_finish_handler_begin=0)
        self.assertEqual(report.intervals(app,[key],'untimed',11),{0:[],1:[]})
        app['input_intervals']=fixture()[0]['input_intervals']
        with self.assertRaises(ValueError):report.intervals(app,[key],'untimed',11)


if __name__ == '__main__':unittest.main()
