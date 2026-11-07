"""진단 사본의 대상 창 요청을 기존 renderTick과 합치고 투영 예산을 대조한다."""
from pathlib import Path


def client(source, once):
    return once(source, '''    const before = stream_installed;
    for (host.editorSaveWindows()) |session| window(session);
    if (stream_installed != before) maru_stream_frame_wake_notice();''', '''    for (host.editorSaveWindows()) |session| {
        const before = stream_installed;
        window(session);
        if (stream_installed != before) maru_target_frame_notice(@intFromPtr(session));
    }''')+'\nextern fn maru_target_frame_notice(owner: u64) void;\n'


def session(source, once):
    anchor = '        const will_project = shouldProjectFrame(self.metal_dirty, sync_active, self.sync_hold_ticks, self.syncTimeoutTicks(), active_view_offset, self.last_rendered_view_offset, esu_advanced, self.force_reproject);'
    source = once(source,anchor,anchor.replace('const will_project','const stream_wanted_project')+'\n        const stream_project_allowed = debug_fixtures.targetFramePermit(self, stream_wanted_project or self.chrome_dirty);\n        const will_project = stream_wanted_project and stream_project_allowed;')
    return once(source,'        const project_chrome = self.chrome_dirty and !will_project;','        const project_chrome = self.chrome_dirty and !will_project and stream_project_allowed;')


def witness(source):
    return source+'''
extern fn maru_target_frame_permit(owner: u64, hz: u64) u32;
pub fn targetFramePermit(self: *AppSession, wanted: bool) bool {
    if (!wanted) return true;
    return maru_target_frame_permit(@intFromPtr(self), self.frameRateHz()) != 0;
}
'''


def swift(source, once):
    anchor = '    private func renderTick(presentMetalFrame: Bool = true) -> Int32 {'
    source = once(source,anchor,anchor+"\n        TargetFrame.sessionTicks &+= 1\n        if TargetFrame.inExtra { TargetFrame.extraTicks &+= 1 }")
    anchor = '        let status = maru_macos_app_session_tick(appSession, currentFrameLoopRateHz(), &summary)\n        appSessionStatus = status\n        if status == Self.statusOK {\n            latestFrameSummary = summary'
    return once(source,anchor,anchor+'''
            if !TargetFrame.inExtra, summary.metal_generation != lastSeenMetalGeneration,
               let owner=activeSurface,let pending=TargetFrame.pending[owner.token] {
                pending.item.cancel();TargetFrame.pending.removeValue(forKey:owner.token)
                FrameWake.coalesced &+= 1;TargetFrame.existingConsumed &+= 1
                FrameWake.queued = !TargetFrame.pending.isEmpty
            }
''')



def driver(source, once):
    if source.count('        if FrameWake.request == nil {') != 1 or source.count('        if InputStream.phase==3 {') != 1:raise ValueError('target frame driver anchors ambiguous')
    start = source.index('        if FrameWake.request == nil {')
    end = source.index('        if InputStream.phase==3 {',start)
    source = source[:start]+'''        if TargetFrame.request == nil {
            targetRegister(streamTargetFrameNotice)
            TargetFrame.request = { [weak self] raw in self?.streamTargetRequest(raw) }
        }
'''+source[end:]
    source = once(source,'            FrameWake.inputStart=FrameWake.snapshot()','            FrameWake.inputStart=FrameWake.snapshot()\n            TargetFrame.inputStart=TargetFrame.snapshot()')
    source = once(source,'                    FrameWake.idleStart=FrameWake.snapshot();FrameWake.idleDue=now+2.0;return','                    FrameWake.idleStart=FrameWake.snapshot();TargetFrame.idleStart=TargetFrame.snapshot();FrameWake.idleDue=now+2.0;return')
    source = once(source,'                FrameWake.idleEnd=FrameWake.snapshot()','                FrameWake.idleEnd=FrameWake.snapshot()\n                TargetFrame.idleEnd=TargetFrame.snapshot()')
    source = once(source,'        record["initial_tail_sha256"]=', '''        record["target_frame_control"]=true
        record["target_input_start"]=TargetFrame.inputStart
        record["target_idle_start"]=TargetFrame.idleStart
        record["target_idle_end"]=TargetFrame.idleEnd
        var targetStats=[UInt64](repeating:0,count:4),targetRows=[UInt64](repeating:0,count:4096*4)
        targetStatsCopy(&targetStats);targetRowsCopy(&targetRows)
        record["target_budget_header"]=targetStats
        record["target_budget_rows"]=(0..<min(4096,Int(targetStats[0]))).map { Array(targetRows[$0*4..<($0+1)*4]) }
        record["initial_tail_sha256"]=''')
    return '''@_silgen_name("maru_target_frame_register") private func targetRegister(_ callback: @convention(c) (UInt64) -> Void)
@_silgen_name("maru_target_frame_deadline") private func targetDeadline(_ owner: UInt64,_ hz: UInt64) -> UInt64
@_silgen_name("maru_target_frame_stats") private func targetStatsCopy(_ out: UnsafeMutablePointer<UInt64>)
@_silgen_name("maru_target_frame_copy") private func targetRowsCopy(_ out: UnsafeMutablePointer<UInt64>)
@MainActor private enum TargetFrame {
    struct Pending { let ticket: UInt64;let item: DispatchWorkItem }
    static var pending=[UInt64:Pending](), nextTicket:UInt64=0
    static var inExtra=false
    static var sessionTicks:UInt64=0,extraTicks:UInt64=0,existingConsumed:UInt64=0,merged:UInt64=0,dropped:UInt64=0,rearmed:UInt64=0
    static var request: ((UInt64) -> Void)?
    static var inputStart=[UInt64](),idleStart=[UInt64](),idleEnd=[UInt64]()
    static func snapshot() -> [UInt64] {
        var stats=[UInt64](repeating:0,count:4);targetStatsCopy(&stats)
        return [UInt64(CACurrentMediaTime()*1e9),sessionTicks,extraTicks,existingConsumed,merged,dropped,rearmed,UInt64(pending.count),stats[0],stats[1],stats[2]]
    }
}
private func streamTargetFrameNotice(_ raw: UInt64) {
    MainActor.assumeIsolated {
        FrameWake.notices &+= 1
        guard InputStream.env["MARU_STREAM_IMMEDIATE_PARSE_FRAME"]=="1",InputStream.phase==2 else { return }
        FrameWake.requests &+= 1;TargetFrame.request?(raw)
    }
}
extension MaruAppHostController {
    private func streamTargetSurface(_ token:UInt64) -> TerminalSurface? {
        if let quick,quick.token==token { return quick }
        return windows.first { $0.token==token }
    }
    private func streamTargetRequest(_ raw:UInt64) {
        let owners=windows+(quick.map { [$0] } ?? [])
        guard let owner=owners.first(where:{ $0.appSession.map { UInt64(UInt(bitPattern:$0))==raw } ?? false }),
              owner.window?.isVisible==true,owner.window?.isMiniaturized==false else {
            TargetFrame.dropped &+= 1;FrameWake.coalesced &+= 1;return
        }
        if TargetFrame.pending[owner.token] != nil {
            TargetFrame.merged &+= 1;FrameWake.coalesced &+= 1;return
        }
        guard TargetFrame.nextTicket<UInt64.max else { TargetFrame.dropped &+= 1;FrameWake.coalesced &+= 1;return }
        TargetFrame.nextTicket &+= 1
        streamTargetSchedule(owner.token,TargetFrame.nextTicket)
    }
    private func streamTargetSchedule(_ token:UInt64,_ ticket:UInt64) {
        guard let owner=streamTargetSurface(token),let session=owner.appSession else {
            TargetFrame.pending.removeValue(forKey:token);TargetFrame.dropped &+= 1
            FrameWake.coalesced &+= 1;FrameWake.queued = !TargetFrame.pending.isEmpty;return
        }
        let now=UInt64(CACurrentMediaTime()*1e9)
        let deadline=targetDeadline(UInt64(UInt(bitPattern:session)),UInt64(currentFrameLoopRateHz()))
        let delay=deadline>now ? Double(deadline-now)/1e9 : 0
        let item=DispatchWorkItem { [weak self] in
            guard let self,TargetFrame.pending[token]?.ticket==ticket else { return }
            guard let owner=self.streamTargetSurface(token),let session=owner.appSession,
                  owner.window?.isVisible==true,owner.window?.isMiniaturized==false else {
                TargetFrame.pending.removeValue(forKey:token);TargetFrame.dropped &+= 1
                FrameWake.coalesced &+= 1;FrameWake.queued = !TargetFrame.pending.isEmpty;return
            }
            let due=targetDeadline(UInt64(UInt(bitPattern:session)),UInt64(self.currentFrameLoopRateHz()))
            if due>UInt64(CACurrentMediaTime()*1e9) {
                TargetFrame.rearmed &+= 1;self.streamTargetSchedule(token,ticket);return
            }
            TargetFrame.pending.removeValue(forKey:token);FrameWake.queued = !TargetFrame.pending.isEmpty
            FrameWake.fired &+= 1;TargetFrame.inExtra=true
            defer { TargetFrame.inExtra=false }
            self.withSurface(owner) { if self.renderTick() != Self.statusOK { TargetFrame.dropped &+= 1 } }
        }
        TargetFrame.pending[token] = .init(ticket:ticket,item:item);FrameWake.queued=true
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:item)
    }
}
''' + source


def present(source):
    return source+'\n'+Path(__file__).with_name('target_frame_budget.c.inc').read_text()


def analyze(app, meta, wake, require, retry=None):
    require(app.get('target_frame_control') is True, 'target frame actual branch')
    snapshots = [app.get(name) for name in ('target_input_start','target_idle_start','target_idle_end')]
    require(all(type(row) is list and len(row) == 11 and all(type(n) is int and 0 <= n < 2**64 for n in row) for row in snapshots), 'target frame snapshots')
    require(all(row[0] > 0 and row[5] == row[7] == row[10] == 0 for row in snapshots), 'target dropped/pending/error')
    require(all(a[0] < b[0] and all(x <= y for x,y in zip(a[1:7]+a[8:],b[1:7]+b[8:])) for a,b in zip(snapshots,snapshots[1:])), 'target counters backwards')
    header = app.get('target_budget_header')
    rows = app.get('target_budget_rows')
    require(type(header) is list and len(header) == 4 and all(type(n) is int and 0 <= n < 2**64 for n in header), 'target budget header')
    require(type(rows) is list and 0 < len(rows) <= 4096 and header[0] == len(rows) and header[2:] == [0,1], 'target budget overflow/owners')
    require(all(type(row) is list and len(row) == 4 and all(type(n) is int and 0 <= n < 2**64 for n in row) and row[0] > 0 and row[1] > 0 and row[2] == 60 and row[3] in (0,1) for row in rows), 'target budget row shape')
    require(len({row[0] for row in rows}) == 1 and all(a[1] <= b[1] for a,b in zip(rows,rows[1:])), 'target budget owner/time')
    require(header[1] == sum(row[3] == 0 for row in rows), 'target budget denial count')
    require(header[0] == snapshots[-1][8] and header[1] == snapshots[-1][9], 'target final budget snapshot')
    enabled = meta['frame_wake_control'] == 'immediate'
    previous = None
    for owner,at,hz,allowed in rows:
        if not enabled:require(allowed == 1, 'baseline unexpectedly budget limited')
        if allowed:
            if previous is not None and enabled:require(at-previous >= (1000000000+hz-1)//hz, 'target cadence exceeded')
            previous = at
    def interval(start,end,base):
        result = dict(session_ticks=end[1]-start[1],extra_session_ticks=end[2]-start[2],existing_consumed=end[3]-start[3],merged_requests=end[4]-start[4],rearmed=end[6]-start[6],projection_attempts=end[8]-start[8],budget_denied=end[9]-start[9])
        require(result['extra_session_ticks'] == base['fired'] and result['existing_consumed']+result['merged_requests'] == base['coalesced'], 'target request accounting')
        require(result['session_ticks'] >= result['extra_session_ticks'], 'target session tick count')
        selected = [row for row in rows if start[0] <= row[1] < end[0]]
        require(len(selected) == result['projection_attempts'] and sum(row[3] == 0 for row in selected) == result['budget_denied'], 'target interval budget accounting')
        result['permitted_projections'] = sum(row[3] for row in selected)
        return result
    active = interval(*snapshots[:2],wake['active'])
    idle = interval(*snapshots[1:],wake['idle'])
    require(active['session_ticks'] > 0 and active['permitted_projections'] > 0, 'target activity absent')
    if not retry or retry['mode']!='with_retry':
        require(all(idle[name] == 0 for name in ('extra_session_ticks','existing_consumed','merged_requests','rearmed')), 'target continues in idle')
    else:
        require(idle['extra_session_ticks']+idle['existing_consumed']+idle['merged_requests']==retry['idle']['requests'], 'target idle retry accounting')
    if not enabled:require(active['extra_session_ticks'] == active['existing_consumed'] == active['merged_requests'] == active['rearmed'] == active['budget_denied'] == 0, 'target baseline branch')
    return dict(hz=60,active=active,idle=idle)
