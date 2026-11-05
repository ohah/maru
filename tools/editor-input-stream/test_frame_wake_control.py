"""설치 사건·큐 정산·입력/유휴 CPU 구간과 잘못된 대조 라벨을 검사한다."""
import copy
import unittest
from pathlib import Path
import shutil
import subprocess
import tempfile
import frame_wake_control as control
import verify


def fixture(mode='immediate'):
    start = [1000000000,0,0,0,0,0,0,1000,1000,0,0]
    idle = [3000000000,10,10,9,1,120,30,100001000,20001000,0,0]
    end = [5000000000,10,10,9,1,240,34,110001000,25001000,0,0]
    if mode == 'scheduled':
        for row in (idle,end):row[2:5] = [0,0,0]
    return dict(frame_wake_mode=mode,wake_input_start=start,wake_idle_start=idle,wake_idle_end=end,
                display_draws=[[1,1,1,1500000000],[1,1,1,1600000000],[2,1,1,3500000000]])


class Wake(unittest.TestCase):
    def analyze(self, app, mode='immediate'):
        return control.analyze(app,{'frame_wake_control':mode},verify.require)

    def test_normal_modes_cpu_and_duplicate_generation(self):
        for mode in ('scheduled','immediate'):
            result = self.analyze(fixture(mode),mode)
            self.assertEqual(result['active']['cpu_ms'],120)
            self.assertEqual(result['idle']['cpu_ms'],15)
            self.assertEqual(result['active']['repeat_generation_draws'],1)
            self.assertEqual(result['idle']['presented_draws'],1)

    def test_distinct_bad_snapshots(self):
        def at(name,index,value):return lambda a:a[name].__setitem__(index,value)
        faults = [
            lambda a:a.update(frame_wake_mode='scheduled'),
            lambda a:a.update(wake_input_start=[]),
            lambda a:a['wake_idle_start'].pop(),
            at('wake_input_start',0,True),at('wake_input_start',0,0),
            at('wake_idle_start',9,1),at('wake_idle_start',10,1),
            at('wake_idle_end',9,1),at('wake_idle_end',10,1),
            at('wake_idle_start',0,1000000000),
            at('wake_idle_start',7,0),at('wake_idle_start',8,0),
            at('wake_idle_start',1,0),at('wake_idle_start',5,0),at('wake_idle_start',6,0),
            at('wake_idle_start',2,11),at('wake_idle_start',3,0),
            at('wake_idle_end',0,4000000000),at('wake_idle_end',0,9000000000),
            at('wake_idle_end',1,11),at('wake_idle_end',2,11),
            at('wake_idle_end',3,10),at('wake_idle_end',4,2),
            at('wake_idle_end',7,-1),at('wake_idle_end',8,2**64),
            at('wake_idle_end',7,100.0),at('wake_idle_end',7,True),
        ]
        for index,mutate in enumerate(faults):
            app = copy.deepcopy(fixture())
            mutate(app)
            with self.subTest(index=index),self.assertRaises(ValueError):self.analyze(app)

    def test_scheduled_requests_and_unknown_mode(self):
        with self.assertRaises(ValueError):self.analyze(fixture(),'scheduled')
        with self.assertRaises(ValueError):self.analyze(fixture(),'unknown')

    def test_optional_native_callback_registration_and_clear(self):
        compiler = shutil.which('cc')
        if compiler is None:self.skipTest('C compiler unavailable')
        source = '#include <stdint.h>\n#include <stddef.h>\n#include <sys/resource.h>\n'+control.present('')+'''
static int count;
static void callback(void) { count++; }
int main(void) {
    maru_stream_frame_wake_notice();
    if (count) return 1;
    maru_stream_frame_wake_register(callback);
    maru_stream_frame_wake_notice();maru_stream_frame_wake_notice();
    if (count!=2) return 2;
    maru_stream_frame_wake_register(NULL);maru_stream_frame_wake_notice();
    if (count!=2) return 3;
    uint64_t usage[3]={0};maru_stream_frame_cpu(usage);
    return usage[2]?4:0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path/'bridge.c').write_text(source)
            subprocess.run([compiler,'-Werror',str(path/'bridge.c'),'-o',str(path/'bridge')],check=True,capture_output=True)
            subprocess.run([str(path/'bridge')],check=True,capture_output=True)


if __name__ == '__main__':
    unittest.main()
