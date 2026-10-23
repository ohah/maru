// 격리 앱 사본에서만 뷰를 배치한다. 제품의 스크롤·헤더 계산·Metal 렌더를 그대로 호출한다.
var sticky_ancestor_session: ?*AppSession = null;
pub fn stickyAncestorObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_EDITOR_STICKY_CAPTURE") != null and self.dock_initialized) sticky_ancestor_session = self;
}
export fn maru_sticky_ancestor_prepare(stage: u32) callconv(.c) bool {
    const self = sticky_ancestor_session orelse return false;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_syntax.pending) return false;
    const doc = term.rt.editorDocument().opened orelse return false;
    const top: usize = if (stage == 0) 5 else 15;
    const caret = doc.file.lines.line(top + 20) orelse return false;
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(caret.start);
    @import("editor/mod.zig").setEditorTop(self, term, top, "sticky-capture");
    return true;
}
export fn maru_sticky_ancestor_probe(stage: u32) callconv(.c) i32 {
    const self = sticky_ancestor_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    const top: usize = if (stage == 0) 5 else 15;
    if (term.rt.editor_first_line != top) return 0;
    const count = term.rt.editor_sticky.drawn_len;
    std.debug.print("STICKY_CAPTURE stage={d} top={d} headers={d}\n", .{stage, top, count});
    return @intCast(count + 1);
}
