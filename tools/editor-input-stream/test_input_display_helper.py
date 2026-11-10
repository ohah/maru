"""앱 포커스 없이 같은 Swift 기록기의 실제 시계·대조 모드·넘침을 실행한다."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


@unittest.skipUnless(sys.platform == 'darwin', 'macOS thread CPU clock and Swift helper')
class InputDisplayHelper(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='maru-input-display-helper-')
        cls.folder = Path(cls.temporary.name)
        c_prefix = '''#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
static uint64_t post_renderer_ns;
static uint64_t stream_now(void) { return 1; }
static int input_test_clock(clockid_t id,struct timespec *out) {
    if (getenv("MARU_TEST_CPU_FAILURE") && id==CLOCK_THREAD_CPUTIME_ID) return -1;
    return clock_gettime(id,out);
}
#define clock_gettime input_test_clock
'''
        (cls.folder / 'helper.c').write_text(c_prefix + (HERE / 'input_display.c.inc').read_text())
        swift = '''import Foundation
import QuartzCore
@MainActor private enum InputStream {
    static let env=ProcessInfo.processInfo.environment
    static var phase=0
}
'''+(HERE / 'input_display.swift.inc').read_text()+'''
@MainActor func exercise() {
let mode=CommandLine.arguments[1]
precondition(InputDisplay.begin(0)==nil)
InputStream.phase=2
precondition(InputDisplay.begin(1,0)==nil)
let count=mode=="overflow" ? 4097 : 100
for index in 0..<count {
    let ticket=InputDisplay.begin(1,0x4D41525500000000 | UInt64(index%36+1))
    var value=0
    for n in 0..<2000 { value &+= n }
    precondition(value>0)
    InputDisplay.end(ticket)
}
precondition(InputDisplay.started==[0,UInt64(count)])
precondition(InputDisplay.completed==[0,UInt64(count)])
if mode=="failure" {
    precondition(InputDisplay.errors==UInt64(count) && InputDisplay.events.isEmpty)
} else if mode=="overflow" {
    precondition(InputDisplay.errors==1 && InputDisplay.events.count==4096)
} else if InputDisplay.timed {
    precondition(InputDisplay.errors==0 && InputDisplay.events.count==count)
    precondition(InputDisplay.events.allSatisfy { $0[2]<$0[3] && $0[4]<=$0[3]-$0[2] && $0[5]>0 })
} else {
    precondition(InputDisplay.errors==0 && InputDisplay.events.isEmpty)
}
print("input_display_helper=pass mode=\\(mode)")
}
MainActor.assumeIsolated { exercise() }
'''
        (cls.folder / 'main.swift').write_text(swift)
        subprocess.run(['clang', '-c', str(cls.folder / 'helper.c'), '-o', str(cls.folder / 'helper.o')], check=True, capture_output=True, timeout=30)
        result = subprocess.run(['swiftc', str(cls.folder / 'main.swift'), str(cls.folder / 'helper.o'), '-framework', 'QuartzCore', '-o', str(cls.folder / 'helper')], capture_output=True, text=True, timeout=60)
        if result.returncode:raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def execute(self, mode, timed=True, failure=False):
        env = {k:v for k,v in os.environ.items() if not k.startswith('MARU_')}
        env['MARU_INPUT_DISPLAY_TIMED'] = '1' if timed else '0'
        if failure:env['MARU_TEST_CPU_FAILURE'] = '1'
        result = subprocess.run([str(self.folder / 'helper'), mode], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('input_display_helper=pass', result.stdout)

    def test_real_clock(self):self.execute('normal')
    def test_untimed_control(self):self.execute('normal', timed=False)
    def test_overflow_is_reported(self):self.execute('overflow')
    def test_clock_failure_is_reported(self):self.execute('failure', failure=True)


if __name__ == '__main__':unittest.main()
