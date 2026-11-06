"""측정 드라이버 자신의 main-thread CPU를 process CPU와 구분한다."""


def driver(source, once):
    source = '''@_silgen_name("maru_observer_thread_cpu") private func observerThreadCPU() -> UInt64
@MainActor private enum ObserverCPU {
    static var total:UInt64=0,start:UInt64=0,calls:UInt64=0,errors:UInt64=0
    static var inputStart=[UInt64](),idleStart=[UInt64](),idleEnd=[UInt64]()
    static func enter() -> Bool {
        guard start==0 else { errors &+= 1;return false }
        start=observerThreadCPU();if start==0 { errors &+= 1;return false };return true
    }
    static func leave() {
        let end=observerThreadCPU()
        if start>0 && end>=start { total &+= end-start } else { errors &+= 1 }
        start=0;calls &+= 1
    }
    static func snapshot() -> [UInt64] {
        let now=observerThreadCPU()
        if start==0 || now<start { errors &+= 1 }
        return [UInt64(CACurrentMediaTime()*1e9),total+(now>=start && start>0 ? now-start : 0),calls,start>0 ? 1 : 0,errors]
    }
}
''' + source
    source = once(source,'    private func maybeRunInputStream() {','    private func maybeRunInputStream() {\n        let observerEntered=ObserverCPU.enter()\n        defer { if observerEntered { ObserverCPU.leave() } }')
    source = once(source,'            TargetFrame.inputStart=TargetFrame.snapshot()','            TargetFrame.inputStart=TargetFrame.snapshot()\n            ObserverCPU.inputStart=ObserverCPU.snapshot()')
    source = once(source,'FrameWake.idleStart=FrameWake.snapshot();TargetFrame.idleStart=TargetFrame.snapshot();','FrameWake.idleStart=FrameWake.snapshot();TargetFrame.idleStart=TargetFrame.snapshot();ObserverCPU.idleStart=ObserverCPU.snapshot();')
    source = once(source,'                TargetFrame.idleEnd=TargetFrame.snapshot()','                TargetFrame.idleEnd=TargetFrame.snapshot()\n                ObserverCPU.idleEnd=ObserverCPU.snapshot()')
    return once(source,'        record["initial_tail_sha256"]=', '''        record["observer_cpu"]=true
        record["observer_input_start"]=ObserverCPU.inputStart
        record["observer_idle_start"]=ObserverCPU.idleStart
        record["observer_idle_end"]=ObserverCPU.idleEnd
        record["initial_tail_sha256"]=''')


def present(source):
    return source+'''
#include <time.h>
uint64_t maru_observer_thread_cpu(void) {
    struct timespec value={0};
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID,&value)!=0) return 0;
    return (uint64_t)value.tv_sec*1000000000ULL+(uint64_t)value.tv_nsec;
}
'''


def analyze(app, wake, require):
    require(app.get('observer_cpu') is True,'observer CPU actual branch')
    snapshots=[app.get(name) for name in ('observer_input_start','observer_idle_start','observer_idle_end')]
    require(all(type(row) is list and len(row)==5 and all(type(n) is int and 0<=n<2**64 for n in row) for row in snapshots),'observer CPU snapshots')
    require(all(row[0]>0 and row[3:]==[1,0] for row in snapshots),'observer CPU handler/error')
    require(all(a[0]<b[0] and a[1]<=b[1] and a[2]<b[2] for a,b in zip(snapshots,snapshots[1:])),'observer CPU counters backwards')
    result={}
    for name,start,end in zip(('active','idle'),snapshots,snapshots[1:]):
        cpu=(end[1]-start[1])/1e6
        process=wake[name]['cpu_ms']
        require(0<=cpu<=process and process>0,'observer CPU exceeds process CPU')
        result[name]=dict(driver_cpu_ms=cpu,other_process_cpu_ms=process-cpu,driver_process_share=cpu/process,completed_calls=end[2]-start[2])
    return result
