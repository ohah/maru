"""진단 후보에서 투영 거절도 같은 대상 예약으로 인계한다."""


def present(source, once):
    source = once(source,'    return allowed;', '    if (!allowed && enabled && deadline!=UINT64_MAX && deadline>now && target_budget_errors==0) deferredRecord(owner,now,deadline,hz);\n    return allowed;')
    source=once(source,'static uint32_t target_permit_at(', 'static void deferredRecord(uint64_t owner,uint64_t at,uint64_t due,uint64_t hz);\nstatic uint32_t target_permit_at(')
    return source+'''
static uint64_t deferred_rows[4096][5],deferred_count,deferred_overflow;
static void (*deferred_callback)(uint64_t,uint64_t,uint64_t);
void maru_deferred_retry_register(void (*callback)(uint64_t,uint64_t,uint64_t)) { deferred_callback=callback; }
static void deferredRecord(uint64_t owner,uint64_t at,uint64_t due,uint64_t hz) {
    if (deferred_count==4096) { deferred_overflow=1;return; }
    const char *value=getenv("MARU_STREAM_DEFERRED_FRAME_RETRY");
    uint64_t *row=deferred_rows[deferred_count++];
    row[0]=owner;row[1]=at;row[2]=due;row[3]=hz;row[4]=value && strcmp(value,"1")==0;
    if (deferred_callback) deferred_callback(owner,at,due);
}
void maru_deferred_retry_copy(uint64_t *header,uint64_t *out) {
    header[0]=deferred_count;header[1]=deferred_overflow;
    memcpy(out,deferred_rows,sizeof(deferred_rows));
}
'''


def driver(source, once):
    source = '''@_silgen_name("maru_deferred_retry_register") private func deferredRegister(_ callback: @convention(c) (UInt64,UInt64,UInt64) -> Void)
@_silgen_name("maru_deferred_retry_copy") private func deferredCopy(_ header: UnsafeMutablePointer<UInt64>,_ rows: UnsafeMutablePointer<UInt64>)
@MainActor private enum DeferredRetry {
    static var notices:UInt64=0,requests:UInt64=0,errors:UInt64=0
    static var inputStart=[UInt64](),idleStart=[UInt64](),idleEnd=[UInt64]()
    static func snapshot() -> [UInt64] { [UInt64(CACurrentMediaTime()*1e9),notices,requests,errors] }
}
private func streamDeferredRetry(_ owner:UInt64,_ at:UInt64,_ due:UInt64) {
    MainActor.assumeIsolated {
        guard InputStream.phase==2 else { return }
        DeferredRetry.notices &+= 1
        guard owner>0 && due>at else { DeferredRetry.errors &+= 1;return }
        guard InputStream.env["MARU_STREAM_DEFERRED_FRAME_RETRY"]=="1" else { return }
        DeferredRetry.requests &+= 1;FrameWake.requests &+= 1
        TargetFrame.request?(owner)
    }
}
''' + source
    source = once(source,'            targetRegister(streamTargetFrameNotice)','            targetRegister(streamTargetFrameNotice)\n            deferredRegister(streamDeferredRetry)')
    source = once(source,'            ObserverCPU.inputStart=ObserverCPU.snapshot()','            ObserverCPU.inputStart=ObserverCPU.snapshot()\n            DeferredRetry.inputStart=DeferredRetry.snapshot()')
    source = once(source,'ObserverCPU.idleStart=ObserverCPU.snapshot();','ObserverCPU.idleStart=ObserverCPU.snapshot();DeferredRetry.idleStart=DeferredRetry.snapshot();')
    source = once(source,'                ObserverCPU.idleEnd=ObserverCPU.snapshot()','                ObserverCPU.idleEnd=ObserverCPU.snapshot()\n                DeferredRetry.idleEnd=DeferredRetry.snapshot()')
    return once(source,'        record["initial_tail_sha256"]=', '''        record["deferred_retry_mode"]=InputStream.env["MARU_STREAM_DEFERRED_FRAME_RETRY"]=="1" ? "with_retry" : "without_retry"
        record["retry_input_start"]=DeferredRetry.inputStart
        record["retry_idle_start"]=DeferredRetry.idleStart
        record["retry_idle_end"]=DeferredRetry.idleEnd
        var retryHeader=[UInt64](repeating:0,count:2),retryRows=[UInt64](repeating:0,count:4096*5)
        deferredCopy(&retryHeader,&retryRows)
        record["retry_header"]=retryHeader
        record["retry_events"]=(0..<min(4096,Int(retryHeader[0]))).map { Array(retryRows[$0*5..<($0+1)*5]) }
        record["initial_tail_sha256"]=''')


def parse(app, meta, require):
    mode=meta.get('deferred_retry_control')
    require(mode in ('without_retry','with_retry') and app.get('deferred_retry_mode')==mode,'retry mode')
    require(meta.get('frame_wake_control')=='immediate','retry requires target candidate in both arms')
    snapshots=[app.get(name) for name in ('retry_input_start','retry_idle_start','retry_idle_end')]
    require(all(type(row) is list and len(row)==4 and all(type(n) is int and 0<=n<2**64 for n in row) and row[0]>0 and row[3]==0 for row in snapshots),'retry snapshots')
    require(all(a[0]<b[0] and a[1]<=b[1] and a[2]<=b[2] for a,b in zip(snapshots,snapshots[1:])),'retry counters backwards')
    events=app.get('retry_events');header=app.get('retry_header')
    require(type(header) is list and len(header)==2 and all(type(n) is int for n in header) and type(events) is list and len(events)<=4096 and header==[len(events),0],'retry event header/overflow')
    enabled=mode=='with_retry'
    require(all(type(row) is list and len(row)==5 and all(type(n) is int and 0<=n<2**64 for n in row) and row[0]>0 and 0<row[1]<row[2] and row[3]==60 and row[4]==int(enabled) for row in events),'retry event shape/branch')
    denied=[row for row in app['target_budget_rows'] if row[3]==0]
    require(len(events)==len(denied),'retry denial population')
    for event,denial in zip(events,denied):
        owner,at,due,hz,_=event
        require([owner,at,hz,0]==denial,'retry source denial differs')
        previous=[row for row in app['target_budget_rows'] if row[3] and row[0]==owner and row[1]<at]
        require(previous and due==previous[-1][1]+(1000000000+hz-1)//hz,'retry deadline differs')
    result=dict(mode=mode)
    for name,start,end in zip(('active','idle'),snapshots,snapshots[1:]):
        notices=end[1]-start[1];requests=end[2]-start[2]
        selected=[row for row in events if start[0]<=row[1]<end[0]]
        require(notices==len(selected) and requests==(notices if enabled else 0),'retry request source accounting')
        result[name]=dict(notices=notices,requests=requests)
    if enabled:require(result['active']['requests']>0,'retry path not exercised')
    return result
