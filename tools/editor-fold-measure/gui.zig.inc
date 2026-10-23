// 격리한 실제 앱의 관측기다. 입력과 렌더는 AppKit 제품 경로를 사용한다.
const ew2_syntax = @import("syntax");
var ew2_initial_len: usize = 0;
var ew2_session: ?*AppSession = null;
fn ew2Now() i64 {
    const self = ew2_session orelse return 0;
    return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
}
pub fn ew2Observe(self: *AppSession) void {
    if (std.c.getenv("MARU_EW2_GUI") == null or !self.dock_initialized) return;
    ew2_session = self;
    ew2_syntax.FoldProbe.wall_clock = &ew2Now;
    ew2_syntax.FoldProbe.clock_ns = ew2Now();
}
export fn maru_ew2_stamp() callconv(.c) void {
    ew2_syntax.FoldProbe.clock_ns = ew2Now();
}
export fn maru_ew2_ready() callconv(.c) bool {
    const self = ew2_session orelse return false;
    const term = pane_ops.activePane(self).activeTerm();
    return term.kind == .editor and term.rt.editor_syntax_folds_applied and !term.rt.editor_syntax.pending;
}
export fn maru_ew2_prepare() callconv(.c) bool {
    if (!maru_ew2_ready()) return false;
    const self = ew2_session.?;
    const term = pane_ops.activePane(self).activeTerm();
    const doc = term.rt.editorDocument().opened orelse return false;
    ew2_initial_len = doc.file.content.len;
    const line = doc.file.lineCount()/2;
    const at = doc.file.lines.line(line+2) orelse return false;
    @import("editor/mod.zig").navigateTo(self, .{.offset=@intCast(at.start)}) catch return false;
    @import("editor/mod.zig").setEditorTop(self,term,line,"fold-gui-probe");
    return true;
}
export fn maru_ew2_due_ns() callconv(.c) i64 {
    const self = ew2_session orelse return 16_666_667;
    const term = pane_ops.activePane(self).activeTerm();
    const p = term.rt.editor_syntax.provider orelse return 16_666_667;
    if (term.rt.editor_syntax.pending) return 16_666_667;
    return @max(0,p.fold_probe.deadline-ew2Now());
}
export fn maru_ew2_mode() callconv(.c) u32 {
    return ew2_syntax.FoldProbe.mode;
}

export fn maru_ew2_inserted_bytes() callconv(.c) i64 {
    const self = ew2_session orelse return -1;
    const term = pane_ops.activePane(self).activeTerm();
    const doc = term.rt.editorDocument().opened orelse return -1;
    return @as(i64,@intCast(doc.file.content.len)) - @as(i64,@intCast(ew2_initial_len));
}
export fn maru_ew2_validate() callconv(.c) bool {
    if (!maru_ew2_ready() or maru_ew2_inserted_bytes() != 20) return false;
    const self = ew2_session.?;
    const term = pane_ops.activePane(self).activeTerm();
    const p = if (term.rt.editor_syntax.provider) |*value| value else return false;
    var expected: std.ArrayList(ew2_syntax.Provider.FoldSpan) = .empty;
    defer expected.deinit(self.allocator);
    p.foldSpansFull(self.allocator,&expected) catch return false;
    if (term.rt.editor_fold_ranges.len != expected.items.len) return false;
    for (term.rt.editor_fold_ranges,expected.items) |got,want| {
        if (got.head != want.start_row or got.last_hidden != want.end_row) return false;
    }
    return true;
}

// Swift 쪽 Metal 재칠 표시만으로는 Zig의 프레임 투영이 일어나지 않는다.
// 만기에는 제품 backend도 무효화해야 새 접힘 목록을 설치할 수 있다.
export fn maru_ew2_wake() callconv(.c) void {
    maru_ew2_stamp();
    if (ew2_session) |self| self.metal_dirty = true;
}
