"""관측기 CPU가 process CPU를 넘거나 잘못된 경계를 쓰는 것을 거절한다."""
import copy
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import observer_cpu
import verify


def fixture():
    return dict(observer_cpu=True,observer_input_start=[1000,100,5,1,0],observer_idle_start=[2000,1000100,10,1,0],observer_idle_end=[3000,2000100,15,1,0]),dict(active=dict(cpu_ms=2),idle=dict(cpu_ms=3))


class Observer(unittest.TestCase):
    def test_positive_and_bad_snapshots(self):
        app,wake=fixture()
        self.assertEqual(observer_cpu.analyze(app,wake,verify.require)['idle']['other_process_cpu_ms'],2)
        faults=[
            lambda a,w:a.update(observer_cpu=False),lambda a,w:a.update(observer_input_start=[]),
            lambda a,w:a['observer_input_start'].__setitem__(0,True),
            lambda a,w:a['observer_idle_start'].__setitem__(0,1000),
            lambda a,w:a['observer_idle_start'].__setitem__(1,0),
            lambda a,w:a['observer_idle_start'].__setitem__(2,5),
            lambda a,w:a['observer_idle_start'].__setitem__(3,0),
            lambda a,w:a['observer_idle_end'].__setitem__(4,1),
            lambda a,w:a['observer_idle_end'].__setitem__(1,2**64),
            lambda a,w:a['observer_idle_end'].__setitem__(1,-1),
            lambda a,w:w['idle'].update(cpu_ms=.5),
            lambda a,w:w['active'].update(cpu_ms=0),
        ]
        for index,mutate in enumerate(faults):
            a,w=copy.deepcopy(fixture());mutate(a,w)
            with self.subTest(index=index),self.assertRaises(ValueError):observer_cpu.analyze(a,w,verify.require)

    def test_native_thread_cpu_clock(self):
        compiler=shutil.which('cc')
        if compiler is None:self.skipTest('C compiler unavailable')
        code='#include <stdint.h>\n'+observer_cpu.present('')+'''
int main(void) {
    uint64_t before=maru_observer_thread_cpu();volatile uint64_t sum=0;
    for(uint64_t i=0;i<100000;i++) sum+=i;
    uint64_t after=maru_observer_thread_cpu();
    return !before || after<before || sum==0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder);(p/'cpu.c').write_text(code)
            subprocess.run([compiler,'-Werror',str(p/'cpu.c'),'-o',str(p/'cpu')],check=True,capture_output=True)
            subprocess.run([str(p/'cpu')],check=True,capture_output=True)
