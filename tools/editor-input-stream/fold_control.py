"""외부 사본에서만 접힘 byte 후보 준비를 끄고 실제 경로를 확인한다."""
import summary_control


def worker(source,once):
    anchor='        if (complete and !self.cancellation.isRequested()) parsed.prepareFoldCache(allocator, &self.folds, &self.cancellation) catch {};'
    replacement='''        if (complete and !self.cancellation.isRequested()) {
            if (std.c.getenv("MARU_STREAM_SKIP_FOLD_PREPARATION") != null) {
                _ = stream_fold_bypassed.fetchAdd(1, .monotonic);
            } else {
                _ = stream_fold_attempted.fetchAdd(1, .monotonic);
                parsed.prepareFoldCache(allocator, &self.folds, &self.cancellation) catch {};
                if (self.folds.tree != null) _ = stream_fold_ready.fetchAdd(1, .monotonic);
            }
        }'''
    return once(source,anchor,replacement)+'''
pub var stream_fold_attempted: std.atomic.Value(u64) = .init(0);
pub var stream_fold_ready: std.atomic.Value(u64) = .init(0);
pub var stream_fold_bypassed: std.atomic.Value(u64) = .init(0);
'''


def abi():
    return '''
pub export fn maru_stream_fold_stats(s: *AppSession, out: [*]u64) void {
    const worker = @import("app_session/editor/parse/worker.zig");
    out[0] = worker.stream_fold_attempted.load(.acquire);
    out[1] = worker.stream_fold_ready.load(.acquire);
    out[2] = worker.stream_fold_bypassed.load(.acquire);
    out[3] = 0;
    out[4] = 0;
    const target = @import("app_session/pane.zig").activePane(s).activeTerm();
    if (target.kind != .editor) return;
    for (s.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |peer| {
        if (peer.kind != .editor or peer.rt.editorDocument() != target.rt.editorDocument()) continue;
        out[3] +|= peer.rt.editor_syntax.folds.nodes;
        out[4] +|= peer.rt.editor_syntax.folds.scanned_records;
    };
}
'''


def driver(source,once):
    # 같은 다섯 정수 계약을 쓰되 결과와 ABI 이름은 심볼 요약과 섞지 않는다.
    return summary_control.driver(source,once).replace('maru_stream_summary_stats','maru_stream_fold_stats').replace('streamSummaryStats','streamFoldStats').replace('"summary_stats"','"fold_stats"')


def validate(app,meta,require):
    # 분기 계수의 형식/배타성과 최종 뷰 순회 0 규칙은 두 실험에서 같은 계약이다.
    summary_control.validate({'summary_stats':app.get('fold_stats',[])},{'summary_control':meta.get('fold_control')},require)
