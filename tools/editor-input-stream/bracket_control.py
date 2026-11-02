"""외부 사본에서만 괄호 잎 준비를 끄고 실제 경로를 확인한다."""
import summary_control


def worker(source,once):
    anchor='        if (complete and !self.cancellation.isRequested()) parsed.prepareBracketIndex(allocator, &self.brackets, bytes, &self.cancellation) catch {};'
    replacement='''        if (complete and !self.cancellation.isRequested()) {
            if (std.c.getenv("MARU_STREAM_SKIP_BRACKET_PREPARATION") != null) {
                _ = stream_bracket_bypassed.fetchAdd(1, .monotonic);
            } else {
                _ = stream_bracket_attempted.fetchAdd(1, .monotonic);
                parsed.prepareBracketIndex(allocator, &self.brackets, bytes, &self.cancellation) catch {};
                if (self.brackets.ready) _ = stream_bracket_ready.fetchAdd(1, .monotonic);
            }
        }'''
    return once(source,anchor,replacement)+'''
pub var stream_bracket_attempted: std.atomic.Value(u64) = .init(0);
pub var stream_bracket_ready: std.atomic.Value(u64) = .init(0);
pub var stream_bracket_bypassed: std.atomic.Value(u64) = .init(0);
'''


def abi():
    return '''
pub export fn maru_stream_bracket_stats(s: *AppSession, out: [*]u64) void {
    const worker = @import("app_session/editor/parse/worker.zig");
    out[0] = worker.stream_bracket_attempted.load(.acquire);
    out[1] = worker.stream_bracket_ready.load(.acquire);
    out[2] = worker.stream_bracket_bypassed.load(.acquire);
    out[3] = 0;
    out[4] = 0;
    const target = @import("app_session/pane.zig").activePane(s).activeTerm();
    if (target.kind != .editor) return;
    for (s.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |peer| {
        if (peer.kind != .editor or peer.rt.editorDocument() != target.rt.editorDocument()) continue;
        out[3] +|= peer.rt.editor_syntax.brackets.rebuilds;
        out[4] +|= peer.rt.editor_syntax.brackets.partials;
    };
}
'''


def driver(source,once):
    source = summary_control.driver(source,once)
    source = '@_silgen_name("maru_stream_syntax_copy") private func streamSyntaxCopy(_ out: UnsafeMutablePointer<UInt64>)\n'+source
    source = once(source,'        record["initial_tail_sha256"]=', '        var stage=[UInt64](repeating:0,count:108);streamSyntaxCopy(&stage)\n        let syntaxRows=(0..<max(0,min(36,InputStream.total))).map { Array(stage[($0*3)..<($0*3+3)]) }\n        record["syntax_presentations"]=syntaxRows\n        if let last=syntaxRows.last { record["syntax_presentation"]=Array(last.prefix(2)) } else { record["syntax_presentation"]=[UInt64](repeating:0,count:2) }\n        record["initial_tail_sha256"]=')
    return source.replace('maru_stream_summary_stats','maru_stream_bracket_stats').replace('streamSummaryStats','streamBracketStats').replace('"summary_stats"','"bracket_stats"')


def validate(app,meta,require):
    # 분기 계수의 형식/배타성과 최종 뷰 순회 0 규칙은 두 실험에서 같은 계약이다.
    summary_control.validate({'summary_stats':app.get('bracket_stats',[])},{'summary_control':meta.get('bracket_control')},require)


def present(source,once):
    source=once(source,'static uint64_t stream_base_len, stream_views, stream_suppressed;', 'static uint64_t stream_base_len, stream_views, stream_suppressed;\nstatic uint64_t stream_syntax[36][3];')
    source=once(source,'    stream_suppressed=0;', '    stream_suppressed=0;memset(stream_syntax,0,sizeof(stream_syntax));')
    anchor='            if (!r[6] || at<r[6]) {'
    source=once(source,anchor, '            if (ready && (!stream_syntax[i][0] || at<stream_syntax[i][0])) { stream_syntax[i][0]=at;stream_syntax[i][1]=gen;stream_syntax[i][2]=prefix; }\n'+anchor)
    return source+'\nvoid maru_stream_syntax_copy(uint64_t *out) { pthread_mutex_lock(&stream_lock);memcpy(out,stream_syntax,sizeof(stream_syntax));pthread_mutex_unlock(&stream_lock); }\n'


def stages(app,producer,meta,require):
    if meta.get('bracket_control') is None:return {}
    stage=app.get('syntax_presentation',[]);rows=app.get('syntax_presentations',[])
    require(type(stage) is list and len(stage)==2 and all(type(x) is int and 0<x<2**64 for x in stage),'syntax presentation shape')
    keys=app['keys'];header=app['header'];events=producer['events'];n=len(keys)
    require(type(rows) is list and len(rows)==n,'syntax row population')
    for i,(row,key) in enumerate(zip(rows,keys)):
        require(type(row) is list and len(row)==3 and all(type(x) is int and 0<x<2**64 for x in row),'syntax row shape')
        at,gen,prefix=row
        require(key[6]<=at<=header[4] and key[7]<=gen<=header[5] and i+1<=prefix<=n,'syntax presentation order')
        if key[9]:require(row==[key[6],key[7],key[8]],'ready first frame differs')
        if i:require(rows[i-1][0]<=at and rows[i-1][1]<=gen,'syntax row order')
    for row in rows:require(rows[row[2]-1]==row,'syntax coalesced prefix')
    require(stage==rows[-1][:2],'last syntax row differs')
    at,gen=stage;posted=events[-1]['post_ns']
    return dict(last_post_to_syntax_present_ms=(at-posted)/1e6,syntax_to_full_color_ms=(header[4]-at)/1e6,
                syntax_ready_before_next_post=sum(row[0]<events[i+1]['post_ns'] for i,row in enumerate(rows[:-1])),
                syntax_ready_on_first_present_count=sum(key[9] for key in keys),full_ready_on_first_present_count=sum(key[10] for key in keys))
