"""외부 앱 사본에서만 접힘 재사용을 대조한다. 두 경로 모두 접힘 준비를 유지한다."""
import bracket_control


def worker(source, once):
    anchor = '                self.folds = (source.folds.copyMatchedOnto(allocator, original.parser, original.tree_gen, parsed.parser, parsed.tree_gen, parsed.tree) catch null) orelse .{};'
    replacement = '''                if (std.c.getenv("MARU_STREAM_SKIP_FOLD_REUSE") != null) {
                    _ = stream_fold_reuse_bypassed.fetchAdd(1, .monotonic);
                } else {
                    _ = stream_fold_reuse_attempted.fetchAdd(1, .monotonic);
ANCHOR
                    if (self.folds.tree != null) _ = stream_fold_reuse_copied.fetchAdd(1, .monotonic);
                }'''.replace('ANCHOR', anchor)
    return once(source, anchor, replacement) + '''
pub var stream_fold_reuse_attempted: std.atomic.Value(u64) = .init(0);
pub var stream_fold_reuse_copied: std.atomic.Value(u64) = .init(0);
pub var stream_fold_reuse_bypassed: std.atomic.Value(u64) = .init(0);
'''


def abi():
    return '''
pub export fn maru_stream_fold_reuse_stats(s: *AppSession, out: [*]u64) void {
    const worker = @import("app_session/editor/parse/worker.zig");
    out[0] = worker.stream_fold_reuse_attempted.load(.acquire);
    out[1] = worker.stream_fold_reuse_copied.load(.acquire);
    out[2] = worker.stream_fold_reuse_bypassed.load(.acquire);
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


def driver(source, once):
    source = bracket_control.driver(source, once).replace('maru_stream_bracket_stats', 'maru_stream_fold_reuse_stats').replace('streamBracketStats', 'streamFoldReuseStats').replace('"bracket_stats"', '"fold_reuse_stats"')
    source = once(source, '    static var phase=0', '    static var foldReuseBaseline=[UInt64](repeating:0,count:5)\n    static var phase=0')
    source = once(source, '            latencyState(session,&InputStream.baseline);latencyMemory(&InputStream.baselineMemory)', '            latencyState(session,&InputStream.baseline);latencyMemory(&InputStream.baselineMemory)\n            streamFoldReuseStats(session,&InputStream.foldReuseBaseline)')
    return once(source, '        record["fold_reuse_stats"]=summary', '        record["fold_reuse_stats"]=summary\n        record["fold_reuse_baseline_stats"]=InputStream.foldReuseBaseline')


present = bracket_control.present


def validate(app, meta, require):
    control = meta.get('fold_reuse_control')
    if control is None:
        return
    require(control in ('disabled', 'prepared'), 'fold reuse control mode')
    stats = app.get('fold_reuse_stats', [])
    baseline = app.get('fold_reuse_baseline_stats', [])
    require(all(type(row) is list and len(row) == 5 and all(type(n) is int and 0 <= n < 2**64 for n in row) for row in (stats, baseline)), 'fold reuse counters')
    require(baseline[1] <= baseline[0], 'fold reuse baseline copies exceed attempts')
    require(all(end >= start for start, end in zip(baseline[:3], stats[:3])), 'fold reuse counters went backwards')
    attempted, copied, bypassed = [end - start for start, end in zip(baseline[:3], stats[:3])]
    require(stats[3] == baseline[3], 'fold view unexpectedly rebuilt')
    if control == 'disabled':
        require(stats[0] == stats[1] == 0 and bypassed > 0, 'full fold path not observed during input')
    else:
        require(attempted > 0 and 0 < copied <= attempted and stats[1] <= stats[0] and stats[2] == 0, 'fold reuse path not observed during input')


def stages(app, producer, meta, require):
    return bracket_control.stages(app, producer, dict(meta, bracket_control=meta.get('fold_reuse_control')), require)
