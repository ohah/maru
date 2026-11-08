"""JSON 재사용의 실제 읽기·원본 신원·CPU 정산을 검증한다."""
import base64,copy,hashlib,json
from pathlib import Path
import shutil,subprocess,tempfile,unittest,sys
import observer_posts_control as control
import verify


def fixture(cached=True):
    data=b'{"error":null}'
    mode='cached_posts' if cached else 'repeated_posts'
    start=[1000,0,0,0,0,0,0,0]
    idle=[2000,4,2,1,1,2,1000,0] if cached else [2000,4,4,3,3,0,1000,0]
    end=[3000,8,2,1,1,6,2000,0] if cached else [3000,8,8,7,7,0,2000,0]
    return dict(observer_posts_mode=mode,posts_input_start=start,posts_idle_start=idle,posts_idle_end=end,posts_errors=0,posts_accepted_base64=base64.b64encode(data).decode()),dict(observer_posts_control=mode,**{'posts.json_sha256':hashlib.sha256(data).hexdigest()}),dict(active=dict(driver_cpu_ms=.01,completed_calls=4),idle=dict(driver_cpu_ms=.01,completed_calls=4))


class Posts(unittest.TestCase):
    def test_two_modes_and_distinct_faults(self):
        for cached in (False,True):
            a,m,o=fixture(cached);self.assertEqual(control.analyze(a,m,o,verify.require)['mode'],m['observer_posts_control'])
        def at(name,index,value):return lambda a,m,o:a[name].__setitem__(index,value)
        faults=[
            lambda a,m,o:m.update(observer_posts_control='unknown'),
            lambda a,m,o:a.update(observer_posts_mode='repeated_posts'),
            lambda a,m,o:a.update(posts_input_start=[]),
            at('posts_input_start',0,True),at('posts_input_start',0,0),
            at('posts_idle_start',0,1000),at('posts_idle_end',1,0),
            at('posts_input_start',7,1),at('posts_idle_end',7,1),
            lambda a,m,o:a.update(posts_errors=1),lambda a,m,o:a.update(posts_errors=True),
            lambda a,m,o:a.update(posts_accepted_base64=None),lambda a,m,o:a.update(posts_accepted_base64='!'),
            lambda a,m,o:a.update(posts_accepted_base64=''),
            lambda a,m,o:m.update(**{'posts.json_sha256':'0'*64}),
            at('posts_idle_start',1,5),at('posts_idle_start',2,0),at('posts_idle_start',3,3),
            at('posts_idle_start',4,2),at('posts_idle_end',5,5),
            at('posts_idle_start',6,2**64),at('posts_idle_start',6,-1),
            lambda a,m,o:o['idle'].update(driver_cpu_ms=0),
            lambda a,m,o:o['active'].update(completed_calls=3),
            at('posts_idle_start',6,0.5),at('posts_idle_start',4,True),
        ]
        for index,mutate in enumerate(faults):
            a,m,o=copy.deepcopy(fixture());mutate(a,m,o)
            with self.subTest(index=index),self.assertRaises(ValueError):control.analyze(a,m,o,verify.require)

    def test_cached_build_requires_explicit_runtime_label(self):
        import run
        for capability,mode in ((True,None),(True,'unknown'),(False,'cached_posts')):
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory);build=root/'build';build.mkdir()
                (build/'source.json').write_text(json.dumps(dict(observer_posts_control=capability)))
                with self.subTest(capability=capability,mode=mode),self.assertRaises(ValueError):
                    run.trial(build,root/'trial',3000,'async','typing',50,30,'normal',0,observer_posts_control=mode)
                self.assertFalse((root/'trial/app.log').exists())

    def test_native_swift_file_semantics(self):
        if sys.platform!='darwin':self.skipTest('macOS QuartzCore helper')
        swift=shutil.which('swiftc')
        if swift is None:self.skipTest('Swift compiler unavailable')
        helper=Path(control.__file__).with_name('observer_posts.swift.inc').read_text()
        source='''import Foundation
import QuartzCore
@MainActor private enum TestClock { static var value:UInt64=1 }
@MainActor private func observerThreadCPU() -> UInt64 { TestClock.value+=1;return TestClock.value }
'''+helper+'''
@main struct TestMain {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);let file=root.appendingPathComponent("posts.json")
        for cached in [false,true] {
            ObserverPosts.accepted=nil;ObserverPosts.checks=0;ObserverPosts.attempts=0;ObserverPosts.reads=0
            ObserverPosts.parses=0;ObserverPosts.hits=0;ObserverPosts.cpu=0;ObserverPosts.errors=0
            try? FileManager.default.removeItem(at:file)
            precondition(ObserverPosts.complete(file.path,cache:cached)==nil)
            try Data("bad-json".utf8).write(to:file,options:.atomic)
            precondition(ObserverPosts.complete(file.path,cache:cached)==nil && ObserverPosts.accepted==nil)
            try Data("{\\"error\\":\\"failure\\"}".utf8).write(to:file,options:.atomic)
            precondition(ObserverPosts.complete(file.path,cache:cached)==false && ObserverPosts.accepted==nil)
            let normal=Data("{\\"error\\":null}".utf8);try normal.write(to:file,options:.atomic)
            for _ in 0..<4 { precondition(ObserverPosts.complete(file.path,cache:cached)==true) }
            precondition(ObserverPosts.hits==(cached ? 3 : 0))
            precondition(ObserverPosts.accepted==normal && ObserverPosts.checks==7)
            ObserverPosts.finish(file.path);precondition(ObserverPosts.errors==0)
            // 재사용 중 원본이 바뀌어도 종료 대조에서 정상으로 받지 않는다.
            try Data("{\\"error\\":null,\\"changed\\":1}".utf8).write(to:file,options:.atomic)
            if cached { precondition(ObserverPosts.complete(file.path,cache:true)==true) }
            else { precondition(ObserverPosts.complete(file.path,cache:false)==false) }
            ObserverPosts.finish(file.path);precondition(ObserverPosts.errors>0)
        }
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'posts.swift').write_text(source)
            result=subprocess.run([swift,'-parse-as-library',str(root/'posts.swift'),'-o',str(root/'probe')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            subprocess.run([str(root/'probe'),str(root)],check=True,capture_output=True)
