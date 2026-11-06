"""외부 앱에서만 설치 후 프레임 요청을 대조한다. 제품 타이머 정책은 바꾸지 않는다."""


def client(source, once):
    anchor = '            if (!(dispatch.installView(&prepared, state, term.rt.editor_document_lease.?, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar)) catch unreachable)) return;'
    source = once(source, anchor, anchor+'\n            stream_installed +%= 1;')
    source = once(source, 'fn completed() void {\n    for (host.editorSaveWindows()) |session| window(session);\n}', '''fn completed() void {
    const before = stream_installed;
    for (host.editorSaveWindows()) |session| window(session);
    if (stream_installed != before) maru_stream_frame_wake_notice();
}''')
    return source+'\nvar stream_installed: u64 = 0;\nextern fn maru_stream_frame_wake_notice() void;\n'


def swift(source, once):
    source = once(source, '    private func tickAppSession() {', '    private func tickAppSession() {\n        FrameWake.ticks &+= 1')
    return once(source, '    private func drawMetalFrame(inspectorOnly: Bool = false) {', '    private func drawMetalFrame(inspectorOnly: Bool = false) {\n        FrameWake.draws &+= 1')


def driver(source, once):
    source = '''@_silgen_name("maru_stream_frame_cpu") private func frameWakeCPU(_ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_stream_frame_wake_register") private func frameWakeRegister(_ callback: @convention(c) () -> Void)
@MainActor private enum FrameWake {
    static var notices: UInt64=0, requests: UInt64=0, fired: UInt64=0, coalesced: UInt64=0
    static var ticks: UInt64=0, draws: UInt64=0
    static var queued=false
    static var request: (() -> Void)?
    static var inputStart=[UInt64](), idleStart=[UInt64](), idleEnd=[UInt64]()
    static var idleDue=0.0
    static func snapshot() -> [UInt64] {
        var cpu=[UInt64](repeating:0,count:3);frameWakeCPU(&cpu)
        return [UInt64(CACurrentMediaTime()*1e9),notices,requests,fired,coalesced,ticks,draws,cpu[0],cpu[1],cpu[2],queued ? 1 : 0]
    }
}
private func streamFrameWakeNotice() {
    MainActor.assumeIsolated {
        FrameWake.notices &+= 1
        guard InputStream.env["MARU_STREAM_IMMEDIATE_PARSE_FRAME"]=="1", InputStream.phase==2 else { return }
        FrameWake.requests &+= 1
        FrameWake.request?()
    }
}
''' + source
    anchor = '        if InputStream.phase==3 { bypassQuitConfirm=true;NSApp.terminate(nil);return }'
    source = once(source, anchor, '''        if FrameWake.request == nil {
            frameWakeRegister(streamFrameWakeNotice)
            FrameWake.request = { [weak self] in
                if FrameWake.queued { FrameWake.coalesced &+= 1;return }
                FrameWake.queued=true
                DispatchQueue.main.async { [weak self] in
                    FrameWake.queued=false
                    guard let self, InputStream.phase==2 else { return }
                    FrameWake.fired &+= 1
                    self.tickAppSession()
                }
            }
        }
'''+anchor)
    anchor = '            streamBegin(UInt64(InputStream.total),state[5],state[4],state[6]>>1)'
    source = once(source, anchor, anchor+'\n            FrameWake.inputStart=FrameWake.snapshot()')
    source = once(source, '                InputStream.finish(nil,session,view);return', '''                if FrameWake.queued { return }
                if FrameWake.idleDue==0 {
                    FrameWake.idleStart=FrameWake.snapshot();FrameWake.idleDue=now+2.0;return
                }
                guard now>=FrameWake.idleDue else { return }
                FrameWake.idleEnd=FrameWake.snapshot()
                InputStream.finish(nil,session,view);return''')
    return once(source, '        record["initial_tail_sha256"]=', '''        record["frame_wake_mode"]=InputStream.env["MARU_STREAM_IMMEDIATE_PARSE_FRAME"]=="1" ? "immediate" : "scheduled"
        record["wake_input_start"]=FrameWake.inputStart
        record["wake_idle_start"]=FrameWake.idleStart
        record["wake_idle_end"]=FrameWake.idleEnd
        record["initial_tail_sha256"]=''')


def present(source):
    return source+'''
static void (*stream_frame_wake_callback)(void);
void maru_stream_frame_wake_register(void (*callback)(void)) { stream_frame_wake_callback=callback; }
void maru_stream_frame_wake_notice(void) { if (stream_frame_wake_callback) stream_frame_wake_callback(); }
void maru_stream_frame_cpu(uint64_t *out) {
    struct rusage usage={0};
    const int result=getrusage(RUSAGE_SELF,&usage);
    out[0]=(uint64_t)usage.ru_utime.tv_sec*1000000000ULL+(uint64_t)usage.ru_utime.tv_usec*1000ULL;
    out[1]=(uint64_t)usage.ru_stime.tv_sec*1000000000ULL+(uint64_t)usage.ru_stime.tv_usec*1000ULL;
    out[2]=result==0?0:1;
}
'''


def analyze(app, meta, require):
    mode = meta.get('frame_wake_control')
    require(mode in ('scheduled','immediate') and app.get('frame_wake_mode') == mode, 'frame wake mode')
    snapshots = [app.get(name) for name in ('wake_input_start','wake_idle_start','wake_idle_end')]
    require(all(type(row) is list and len(row) == 11 and all(type(n) is int and 0 <= n < 2**64 for n in row) for row in snapshots), 'frame wake snapshots')
    require(all(row[0] > 0 and row[9] == row[10] == 0 for row in snapshots), 'frame wake cpu/queued status')
    require(all(a[0] < b[0] and all(x <= y for x,y in zip(a[1:9],b[1:9])) for a,b in zip(snapshots,snapshots[1:])), 'frame wake counters backwards')
    def interval(start, end):
        wall = (end[0]-start[0])/1e9
        cpu = (end[7]+end[8]-start[7]-start[8])/1e6
        return dict(wall_seconds=wall,cpu_ms=cpu,cpu_percent=cpu/(wall*10),notices=end[1]-start[1],requests=end[2]-start[2],fired=end[3]-start[3],coalesced=end[4]-start[4],ticks=end[5]-start[5],draw_calls=end[6]-start[6])
    active = interval(*snapshots[:2])
    idle = interval(*snapshots[1:])
    require(active['notices'] > 0 and active['ticks'] > 0 and active['draw_calls'] > 0, 'frame wake input activity absent')
    require(active['requests'] == active['fired']+active['coalesced'], 'frame wake queue accounting')
    if mode == 'scheduled':
        require(active['requests'] == 0, 'scheduled frame wake unexpectedly requested')
    else:
        require(active['requests'] > 0 and (meta.get('target_frame_control') is True or active['fired'] > 0) and active['requests'] <= active['notices'], 'immediate frame wake not observed')
    require(2 <= idle['wall_seconds'] <= 5 and idle['ticks'] > 0, 'frame wake idle window')
    require(all(idle[name] == 0 for name in ('notices','requests','fired','coalesced')), 'frame wake continues in idle')
    draws = app['display_draws']
    for result,start,end in ((active,snapshots[0][0],snapshots[1][0]),(idle,snapshots[1][0],snapshots[2][0])):
        selected = [row for row in draws if start <= row[3] < end]
        result['presented_draws'] = len(selected)
        result['repeat_generation_draws'] = len(selected)-len({row[0] for row in selected})
    return dict(mode=mode,active=active,idle=idle)
