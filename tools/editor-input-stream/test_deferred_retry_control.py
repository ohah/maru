"""거절 기록·예약 정산의 위조를 거절하고 실제 C 콜백 경계를 실행한다."""
import copy
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import deferred_retry_control as control
import verify
from test_prepare import prepare


def fixture(enabled=True):
    mode='with_retry' if enabled else 'without_retry'
    return dict(deferred_retry_mode=mode,retry_input_start=[2000000000,0,0,0],
        retry_idle_start=[4000000000,1,int(enabled),0],retry_idle_end=[6000000000,1,int(enabled),0],
        retry_header=[1,0],retry_events=[[7,2100000001,2116666667,60,int(enabled)]],
        target_budget_rows=[[7,2100000000,60,1],[7,2100000001,60,0],[7,2116666667,60,1]]),dict(deferred_retry_control=mode,frame_wake_control='immediate')


class Retry(unittest.TestCase):
    def test_distinct_faults_and_positive_controls(self):
        for enabled in (False,True):
            a,m=fixture(enabled)
            self.assertEqual(control.parse(a,m,verify.require)['active']['requests'],int(enabled))
        def at(name,index,value):return lambda a,m:a[name].__setitem__(index,value)
        faults=[
            lambda a,m:m.update(deferred_retry_control='scheduled'),
            lambda a,m:a.update(deferred_retry_mode='without_retry'),
            lambda a,m:m.update(frame_wake_control='scheduled'),
            lambda a,m:a.update(retry_input_start=[]),
            at('retry_input_start',0,True),at('retry_input_start',0,0),
            at('retry_idle_start',0,2000000000),at('retry_idle_end',1,0),
            at('retry_idle_end',2,0),at('retry_idle_end',3,1),
            at('retry_header',0,0),at('retry_header',1,1),
            lambda a,m:a['retry_events'][0].pop(),
            lambda a,m:a['retry_events'][0].__setitem__(0,0),
            lambda a,m:a['retry_events'][0].__setitem__(1,True),
            lambda a,m:a['retry_events'][0].__setitem__(2,2116666668),
            lambda a,m:a['retry_events'][0].__setitem__(3,120),
            lambda a,m:a['retry_events'][0].__setitem__(4,0),
            lambda a,m:a['target_budget_rows'][1].__setitem__(1,2100000002),
            lambda a,m:a['target_budget_rows'].pop(1),
            at('retry_idle_start',1,2),at('retry_idle_start',2,0),
            at('retry_idle_end',1,2**64),
        ]
        for index,mutate in enumerate(faults):
            a,m=copy.deepcopy(fixture());mutate(a,m)
            with self.subTest(index=index),self.assertRaises(ValueError):control.parse(a,m,verify.require)
        # 새로운 유휴 dirty 요청도 같은 거절 원시 행에 귀속해야 한다.
        a,m=fixture();a['target_budget_rows'] += [[7,5000000000,60,1],[7,5000000001,60,0]]
        a['retry_events'].append([7,5000000001,5016666667,60,1]);a['retry_header'][0]=2
        a['retry_idle_end'][1:3]=[2,2]
        self.assertEqual(control.parse(a,m,verify.require)['idle']['requests'],1)

    def test_combined_queue_accounting_keeps_old_idle_contract(self):
        import frame_wake_control
        from test_frame_wake_control import fixture as wake_fixture
        a=wake_fixture();m=dict(frame_wake_control='immediate',target_frame_control=True)
        retry=dict(mode='with_retry',active=dict(requests=2),idle=dict(requests=1))
        # 활성 요청 열에 retry 두 건, 유휴 요청/실행 열에 한 건을 함께 정산한다.
        for name in ('wake_idle_start','wake_idle_end'):
            a[name][2]+=2;a[name][3]+=2
        a['wake_idle_end'][2]+=1;a['wake_idle_end'][3]+=1
        self.assertEqual(frame_wake_control.analyze(a,m,verify.require,retry)['idle']['requests'],1)
        with self.assertRaises(ValueError):frame_wake_control.analyze(a,m,verify.require)
        bad=copy.deepcopy(retry);bad['idle']['requests']=0
        with self.assertRaises(ValueError):frame_wake_control.analyze(a,m,verify.require,bad)
        a['wake_idle_end'][1]+=1
        with self.assertRaises(ValueError):frame_wake_control.analyze(a,m,verify.require,retry)

    def test_runner_rejects_unlabelled_or_mixed_baseline_before_launch(self):
        import json
        import run
        for capability,mode,wake in ((True,None,'immediate'),(True,'unknown','immediate'),(True,'with_retry','scheduled'),(False,'with_retry','immediate')):
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory);build=root/'build';build.mkdir()
                (build/'source.json').write_text(json.dumps(dict(deferred_retry_control=capability)))
                with self.subTest(mode=mode,wake=wake),self.assertRaises(ValueError):
                    run.trial(build,root/'trial',3000,'async','typing',50,30,'normal',0,
                              frame_wake_control=wake,deferred_retry_control=mode)
                self.assertFalse((root/'trial/app.log').exists())

    def test_native_callback_and_deadline(self):
        cc=shutil.which('cc')
        if cc is None:self.skipTest('C compiler unavailable')
        source='''#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
static uint64_t stream_now(void) { return 1000000000ULL; }
'''+Path(__file__).with_name('target_frame_budget.c.inc').read_text()
        source=control.present(source,prepare.once)+'''
static uint64_t received;
static void callback(uint64_t owner,uint64_t at,uint64_t due) {
    if(owner==7 && at==1000000002ULL && due==1016666667ULL) received++;
}
int main(void) {
    if(!target_permit_at(7,60,1000000000ULL,1) || deferred_count) return 1;
    if(target_permit_at(7,60,1000000001ULL,1) || deferred_count!=1) return 2;
    maru_deferred_retry_register(callback);
    if(target_permit_at(7,60,1000000002ULL,1) || received!=1) return 3;
    if(deferred_rows[1][2]!=1016666667ULL || deferred_rows[1][4]!=0) return 4;
    if(!target_permit_at(7,60,1016666667ULL,1) || deferred_count!=2) return 5;
    setenv("MARU_STREAM_DEFERRED_FRAME_RETRY","1",1);
    target_permit_at(7,60,1016666668ULL,1);
    if(deferred_rows[2][4]!=1) return 6;
    maru_deferred_retry_register(NULL);
    target_permit_at(7,60,1016666669ULL,1);if(received!=1) return 7;
    if(!target_permit_at(7,60,1016666670ULL,0) || deferred_count!=4) return 8;
    deferred_count=4096;target_permit_at(7,60,1016666671ULL,1);
    if(!deferred_overflow || deferred_count!=4096) return 9;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);(p/'retry.c').write_text(source)
            subprocess.run([cc,'-Werror',str(p/'retry.c'),'-o',str(p/'retry')],check=True,capture_output=True)
            subprocess.run([str(p/'retry')],check=True,capture_output=True)
