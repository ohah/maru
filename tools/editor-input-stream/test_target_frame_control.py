"""요청 정산·범위별 예산과 실제 C 경계에서 cadence 제한을 검사한다."""
import copy
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import target_frame_control as control
import verify
from test_prepare import prepare


def fixture():
    app = dict(target_frame_control=True,
        target_input_start=[2000000000,0,0,0,0,0,0,0,1,0,0],
        target_idle_start=[4000000000,122,2,1,1,0,1,0,4,1,0],
        target_idle_end=[6000000000,242,2,1,1,0,1,0,5,1,0],
        target_budget_header=[5,1,0,1],
        target_budget_rows=[[7,1000000000,60,1],[7,2100000000,60,1],[7,2100000001,60,0],[7,2116666667,60,1],[7,5000000000,60,1]])
    wake = dict(active=dict(fired=2,coalesced=2),idle=dict(fired=0,coalesced=0))
    return app,wake


class Target(unittest.TestCase):
    def analyze(self, app, wake):
        return control.analyze(app,{'frame_wake_control':'immediate'},wake,verify.require)

    def test_normal_and_scheduled(self):
        app,wake = fixture()
        result = self.analyze(app,wake)
        self.assertEqual(result['active']['permitted_projections'],2)
        self.assertEqual(result['active']['budget_denied'],1)
        for row in app['target_budget_rows']:row[3]=1
        app['target_budget_header'][1]=0
        for name in ('target_idle_start','target_idle_end'):
            for column in (2,3,4,6,9):app[name][column]=0
        wake['active']=dict(fired=0,coalesced=0)
        self.assertEqual(control.analyze(app,{'frame_wake_control':'scheduled'},wake,verify.require)['active']['extra_session_ticks'],0)

    def test_distinct_corruptions(self):
        def at(name,index,value):return lambda a,w:a[name].__setitem__(index,value)
        faults = [
            lambda a,w:a.update(target_frame_control=False),
            lambda a,w:a.update(target_input_start=[]),
            at('target_input_start',0,True),at('target_input_start',0,0),
            at('target_idle_start',5,1),at('target_idle_start',7,1),at('target_idle_end',10,1),
            at('target_idle_start',0,2000000000),at('target_idle_end',1,1),
            lambda a,w:a.update(target_budget_header=[]),
            at('target_budget_header',0,4),at('target_budget_header',1,0),
            at('target_budget_header',2,1),at('target_budget_header',3,2),
            lambda a,w:a['target_budget_rows'][0].pop(),
            lambda a,w:a['target_budget_rows'][0].__setitem__(0,0),
            lambda a,w:a['target_budget_rows'][0].__setitem__(1,0),
            lambda a,w:a['target_budget_rows'][0].__setitem__(2,120),
            lambda a,w:a['target_budget_rows'][0].__setitem__(3,2),
            lambda a,w:a['target_budget_rows'][0].__setitem__(3,True),
            lambda a,w:a['target_budget_rows'][1].__setitem__(0,8),
            lambda a,w:a['target_budget_rows'][3].__setitem__(1,2116666666),
            lambda a,w:w['active'].update(fired=1),
            lambda a,w:w['active'].update(coalesced=1),
            at('target_idle_start',1,1),at('target_idle_start',8,3),
            at('target_idle_end',6,2),at('target_idle_end',1,2**64),
        ]
        for index,mutate in enumerate(faults):
            app,wake = copy.deepcopy(fixture())
            mutate(app,wake)
            with self.subTest(index=index),self.assertRaises(ValueError):self.analyze(app,wake)

    def test_existing_request_is_consumed_after_new_generation(self):
        path=Path(__file__).resolve().parents[2]/'src/platform/macos/MaruAppHost.swift'
        original=path.read_text()
        changed=control.swift(original,prepare.once)
        body=changed[changed.index('    private func renderTick(presentMetalFrame:'):]
        self.assertLess(body.index('maru_macos_app_session_tick('),body.index('pending.item.cancel()'))
        self.assertLess(body.index('summary.metal_generation != lastSeenMetalGeneration'),body.index('pending.item.cancel()'))
        self.assertLess(body.index('pending.item.cancel()'),body.index('drawMetalFrame()'))
        with self.assertRaises(ValueError):control.swift(original+original,prepare.once)

    def test_native_budget_edges_and_optional_callback(self):
        compiler=shutil.which('cc')
        if compiler is None:self.skipTest('C compiler unavailable')
        code='''#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
static uint64_t stream_now(void) { return 1000000000ULL; }
'''+Path(control.__file__).with_name('target_frame_budget.c.inc').read_text()+'''
static void reset(void) {
    memset(target_budgets,0,sizeof(target_budgets));target_budget_count=0;
    target_budget_errors=0;target_budget_denied=0;target_budget_row_count=0;
}
static uint64_t received;
static void callback(uint64_t owner) { received=owner; }
int main(void) {
    reset();if(target_deadline_at(1,60)!=0) return 1;
    if(!target_permit_at(1,60,1000000000ULL,1)) return 2;
    if(target_permit_at(1,60,1000000000ULL,1)) return 3;
    if(target_permit_at(1,60,1016666666ULL,1)) return 4;
    if(!target_permit_at(1,60,1016666667ULL,1)) return 5;
    if(!target_permit_at(2,60,1000000000ULL,1)) return 6;
    reset();if(!target_permit_at(1,120,1000000000ULL,1)) return 7;
    if(target_permit_at(1,120,1008333333ULL,1)) return 8;
    if(!target_permit_at(1,120,1008333334ULL,1)) return 9;
    reset();if(!target_permit_at(1,1,1,1) || !target_permit_at(1,1,1000000001ULL,1)) return 10;
    reset();if(!target_permit_at(1,1000,1,1) || !target_permit_at(1,1000,1000001,1)) return 11;
    reset();if(target_permit_at(0,60,1,1) || !target_budget_errors) return 12;
    reset();if(target_permit_at(1,0,1,1) || !target_budget_errors) return 13;
    reset();if(target_permit_at(1,1001,1,1) || !target_budget_errors) return 14;
    reset();if(!target_permit_at(1,60,1000000000ULL,0) || !target_permit_at(1,60,1000000001ULL,0)) return 15;
    reset();target_permit_at(1,60,UINT64_MAX-2,1);if(target_deadline_at(1,60)!=UINT64_MAX || !target_budget_errors) return 16;
    reset();target_permit_at(1,60,100,1);target_permit_at(1,60,99,1);if(!target_budget_errors) return 17;
    reset();for(uint64_t i=1;i<=16;i++) if(!target_permit_at(i,60,1,1)) return 18;
    if(target_permit_at(17,60,1,1) || !target_budget_errors) return 19;
    reset();for(uint64_t i=1;i<=4097;i++) target_permit_at(1,60,i,0);
    if(target_budget_row_count!=4096 || !target_budget_errors) return 20;
    maru_target_frame_notice(9);if(received) return 21;
    maru_target_frame_register(callback);maru_target_frame_notice(1234);if(received!=1234) return 22;
    maru_target_frame_register(NULL);maru_target_frame_notice(99);if(received!=1234) return 23;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory);(path/'budget.c').write_text(code)
            subprocess.run([compiler,'-Werror',str(path/'budget.c'),'-o',str(path/'budget')],check=True,capture_output=True)
            subprocess.run([str(path/'budget')],check=True,capture_output=True)


if __name__ == '__main__':unittest.main()
