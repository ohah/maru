"""같은 실행 파일에서 워커 요약 준비만 끄는 외부 사본용 대조다. 제품에는 주입하지 않는다."""


def worker(source,once):
    anchor='        if (complete and !self.cancellation.isRequested()) parsed.prepareStickySummary(allocator, &self.cancellation) catch {};'
    replacement='''        if (complete and !self.cancellation.isRequested()) {
            if (std.c.getenv("MARU_STREAM_SKIP_SUMMARY_PREPARATION") != null) {
                _ = stream_summary_bypassed.fetchAdd(1, .monotonic);
            } else {
                _ = stream_summary_attempted.fetchAdd(1, .monotonic);
                parsed.prepareStickySummary(allocator, &self.cancellation) catch {};
                if (parsed.sticky_summary.tree != null and parsed.sticky_summary.generation == parsed.tree_gen and parsed.sticky_summary.edits == 0)
                    _ = stream_summary_ready.fetchAdd(1, .monotonic);
            }
        }'''
    return once(source,anchor,replacement)+'''
pub var stream_summary_attempted: std.atomic.Value(u64) = .init(0);
pub var stream_summary_ready: std.atomic.Value(u64) = .init(0);
pub var stream_summary_bypassed: std.atomic.Value(u64) = .init(0);
'''


def abi():
    return '''
pub export fn maru_stream_summary_stats(s: *AppSession, out: [*]u64) void {
    const worker = @import("app_session/editor/parse/worker.zig");
    out[0] = worker.stream_summary_attempted.load(.acquire);
    out[1] = worker.stream_summary_ready.load(.acquire);
    out[2] = worker.stream_summary_bypassed.load(.acquire);
    out[3] = 0;
    out[4] = 0;
    const target = @import("app_session/pane.zig").activePane(s).activeTerm();
    for (s.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |peer| {
        if (peer.kind != .editor or peer.rt.editorDocument() != target.rt.editorDocument()) continue;
        if (peer.rt.editor_syntax.provider) |p| {
            out[3] +|= p.sticky_work.rebuild_nodes;
            out[4] +|= p.sticky_work.summary_nodes;
        }
    };
}
'''


def driver(source,once):
    declaration='@_silgen_name("maru_stream_summary_stats") private func streamSummaryStats(_ s: OpaquePointer,_ out: UnsafeMutablePointer<UInt64>)\n'
    return declaration+once(source,'        var record=value\n','        var record=value\n        var summary=[UInt64](repeating:0,count:5);streamSummaryStats(session,&summary)\n        record["summary_stats"]=summary\n')


def validate(app,meta,require):
    control=meta.get('summary_control')
    if control is None:return
    require(control in ('disabled','prepared'),'summary control mode')
    stats=app.get('summary_stats',[])
    require(len(stats)==5 and all(type(n) is int and 0<=n<2**64 for n in stats),'summary control counters')
    attempted,ready,bypassed,rebuild,_=stats
    if control=='disabled':require(attempted==ready==0 and bypassed>0 and rebuild>0,'summary baseline path not observed')
    else:require(attempted>0 and ready>0 and bypassed==0 and rebuild==0,'prepared summary path not observed')
