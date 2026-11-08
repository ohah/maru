"""작업별 CPU·wall 기록과 경계에 걸친 첫 입력의 오귀속을 검사한다."""
import copy,json,os,shutil,uuid,subprocess,sys,tempfile,unittest
from pathlib import Path
import observer_work_control as control
import verify


def fixture(timed=True):
    mode='timed' if timed else 'untimed';events=[]
    if timed:
        for call,at in ((1,1100),(2,2100)):
            events.extend([[part,at+part*20,at+part*20+10,5,call] for part in range(6)])
    rows=[[t,0,n]+[v for part in range(6) for v in (calls,calls*5 if timed else 0)] for t,n,calls in ((1000,0,0),(2000,6 if timed else 0,1),(3000,12 if timed else 0,2))]
    return dict(observer_work_mode=mode,work_input_start=rows[0],work_idle_start=rows[1],work_idle_end=rows[2],work_errors=0,work_events=events),dict(observer_work_control=mode,observer_posts_control='cached_posts',deferred_retry_control='with_retry'),dict(active=dict(completed_calls=1,driver_cpu_ms=.001),idle=dict(completed_calls=1,driver_cpu_ms=.001)),dict(active=dict(posts_cpu_ms=.00001),idle=dict(posts_cpu_ms=.00001))


class Work(unittest.TestCase):
    def test_positive_and_distinct_corruptions(self):
        for timed in (False,True):
            a,m,o,p=fixture(timed);self.assertEqual(control.analyze(a,m,o,p,verify.require)['mode'],m['observer_work_control'])
        def at(name,index,value):return lambda a,m,o,p:a[name].__setitem__(index,value)
        def event(index,value):return lambda a,m,o,p:a['work_events'][0].__setitem__(index,value)
        faults=[
            lambda a,m,o,p:m.update(observer_work_control='unknown'),lambda a,m,o,p:a.update(observer_work_mode='untimed'),
            lambda a,m,o,p:m.update(observer_posts_control='repeated_posts'),lambda a,m,o,p:m.update(deferred_retry_control='without_retry'),
            lambda a,m,o,p:a.update(work_input_start=[]),at('work_input_start',0,True),at('work_input_start',0,0),
            at('work_idle_start',0,1000),at('work_idle_end',3,0),at('work_idle_end',1,1),
            lambda a,m,o,p:a.update(work_errors=1),lambda a,m,o,p:a.update(work_errors=True),
            lambda a,m,o,p:a['work_events'][0].pop(),event(0,6),event(0,True),event(1,0),event(2,1100),event(3,11),event(4,0),event(4,2),
            lambda a,m,o,p:a['work_events'][1].__setitem__(1,1109),event(3,4),at('work_idle_start',4,6),
            at('work_idle_start',3,0),at('work_idle_end',2,11),
            lambda a,m,o,p:o['active'].update(completed_calls=2),lambda a,m,o,p:o['idle'].update(driver_cpu_ms=.000001),
            lambda a,m,o,p:a['work_events'][5].__setitem__(2,2001),at('work_idle_end',4,2**64),
        ]
        for index,mutate in enumerate(faults):
            a,m,o,p=copy.deepcopy(fixture());mutate(a,m,o,p)
            with self.subTest(index=index),self.assertRaises(ValueError):control.analyze(a,m,o,p,verify.require)

    def test_overlap_never_prorates_boundary_cpu(self):
        events=[[0,100,200,20,1],[1,250,350,30,1]]
        r=control.overlap(events,150,300)
        self.assertEqual(r['tracked_wall_overlap_ms'],100/1e6);self.assertEqual(r['fully_contained_cpu_ms'],0)
        self.assertEqual(r['boundary_events'],2);self.assertEqual(r['unattributed_wall_ms'],50/1e6)
        self.assertEqual(control.overlap(events,90,360)['fully_contained_cpu_ms'],50/1e6)
        self.assertEqual(control.overlap(events,150,150)['boundary_events'],0)
        for bounds in ((0,1),(10,9)):
            with self.assertRaises(ValueError):control.overlap(events,*bounds)

    def test_runner_requires_label_and_fixed_comparison_conditions(self):
        import run
        cases=((True,None,'cached_posts','with_retry'),(True,'unknown','cached_posts','with_retry'),
               (True,'timed','repeated_posts','with_retry'),(True,'timed','cached_posts','without_retry'),
               (False,'timed','cached_posts','with_retry'))
        for capability,mode,posts,retry in cases:
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory);build=root/'build';build.mkdir()
                (build/'source.json').write_text(json.dumps(dict(observer_work_control=capability)))
                with self.subTest(mode=mode,posts=posts,retry=retry),self.assertRaises(ValueError):
                    run.trial(build,root/'trial',3000,'async','typing',50,30,'normal',0,
                              observer_work_control=mode,observer_posts_control=posts,deferred_retry_control=retry)
                self.assertFalse((root/'trial/app.log').exists())

    def test_swift_preserves_returns_short_circuit_and_failure_work(self):
        if sys.platform!='darwin':self.skipTest('macOS QuartzCore helper')
        swift=shutil.which('swiftc')
        if swift is None:self.skipTest('Swift compiler unavailable')
        # CPU만 가짜면 실제 wall의 하드웨어 tick보다 짧아져 거짓 실패한다. 두 시계의 결정적 대조와 실제 대조를 나눈다.
        source='''import Foundation
import QuartzCore
import Darwin
@MainActor private enum InputStream { static let env=ProcessInfo.processInfo.environment;static var phase=1 }
@MainActor private enum TestClock { static var value:UInt64=0,wall:UInt64=1000000000;static let real=CommandLine.arguments.contains("real") }
@MainActor private func observerThreadCPU() -> UInt64 {
    if TestClock.real {
        var value=timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID,&value)==0 else { return 0 }
        return UInt64(value.tv_sec)*1000000000+UInt64(value.tv_nsec)
    }
    TestClock.value+=1;return TestClock.value
}
@MainActor private func testWall() -> Double {
    if TestClock.real { return CACurrentMediaTime() }
    TestClock.wall+=1000;return Double(TestClock.wall)/1e9
}
'''+Path(control.__file__).with_name('observer_work.swift.inc').read_text().replace('CACurrentMediaTime()','testWall()')+'''
@main struct TestMain {
    @MainActor static func main() {
        precondition(ObserverWork.measure(0) { 42 }==42 && ObserverWork.calls[0]==0)
        InputStream.phase=2
        var later=false
        let accepted=ObserverWork.measure(0) { false } && ObserverWork.measure(1) { later=true;return true }
        precondition(!accepted && !later && ObserverWork.calls[0]==1 && ObserverWork.calls[1]==0)
        for part in 0..<6 { precondition(ObserverWork.measure(part) { part+1 }==part+1) }
        var value=0;ObserverWork.measure(4) { value=42 };precondition(value==42)
        precondition(ObserverWork.calls.reduce(0,+)==8 && ObserverWork.snapshot().count==15)
        if ObserverWork.enabled {
            precondition(ObserverWork.events.count==8 && ObserverWork.cpu.reduce(0,+)>0)
            let kept=ObserverWork.measure(0) { ObserverWork.measure(1) { 9 } }
            precondition(kept==9 && ObserverWork.errors==1)
            ObserverWork.events=Array(repeating:[0,1,2,0,1],count:4096)
            precondition(ObserverWork.measure(0) { 17 }==17 && ObserverWork.events.count==4096 && ObserverWork.errors==2)
        } else { precondition(ObserverWork.events.isEmpty && ObserverWork.cpu.reduce(0,+)==0) }
        let errors=ObserverWork.errors
        precondition(ObserverWork.measure(6) { 33 }==33 && ObserverWork.errors==errors+1)
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);(p/'work.swift').write_text(source)
            result=subprocess.run([swift,'-parse-as-library',str(p/'work.swift'),'-o',str(p/'probe')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            for clock,enabled in ((c,e) for c in ('fake','real') for e in ('0','1')):
                env=dict(os.environ,MARU_STREAM_OBSERVER_WORK=enabled)
                result=subprocess.run([str(p/'probe'),clock],env=env,capture_output=True,text=True)
                if result.returncode:
                    evidence=Path.home()/'.cache/maru-agent-artifacts'/('observer-work-helper-failure-'+uuid.uuid4().hex)
                    evidence.mkdir(parents=True)
                    shutil.copy2(p/'probe',evidence/'probe');shutil.copy2(p/'work.swift',evidence/'work.swift')
                    (evidence/'failure.json').write_text(json.dumps(dict(mode=enabled,clock=clock,exit=result.returncode,platform=sys.platform,stdout=result.stdout,stderr=result.stderr),indent=2))
                    self.fail(str(evidence)+'\n'+result.stderr[:4000])
