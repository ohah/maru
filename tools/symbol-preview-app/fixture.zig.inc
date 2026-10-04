// 검증 사본에만 붙인다. 제품 API로 관측하고 배포 ABI는 늘리지 않는다.
var symbol_preview_session: ?*AppSession = null;
pub fn symbolPreviewObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_SYMBOL_PREVIEW_CAPTURE") != null and self.dock_initialized) symbol_preview_session = self;
}
export fn maru_symbol_preview_probe(stage: u32) callconv(.c) i32 {
    const self = symbol_preview_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_syntax.pending) return 0;
    const doc = term.rt.editorDocument().opened orelse return 0;
    // 파일 뷰어는 처음엔 caret이 없다. 목록 탐색 전 시작 위치만 한 번 정한다.
    if (stage == 0 and term.rt.editor_selection == null) {
        term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
        self.metal_dirty = true;
    }
    const focus = if (term.rt.editor_selection) |sel| sel.focus else return -1;
    const open = self.chrome_host.symbol_picker.open;
    if (doc.file.revision != 0) return -1;
    if (stage < 7 and (focus != 0 or term.rt.editor_first_line != 0 or self.editor_nav_back.items.len != 0)) return -1;
    if ((stage == 1 or stage == 2 or stage == 3 or stage == 5 or stage == 6) and !open) return -1;
    if ((stage == 0 or stage == 4 or stage == 7) and open) return -1;
    if (stage == 2 or stage == 3 or stage == 6) {
        const p = term.rt.editor_symbol_preview orelse return -1;
        if (p.target_line < 150) return -1;
    }
    if (stage == 7) {
        const expected = std.mem.indexOf(u8, doc.file.content, "pub fn sample40()") orelse return -1;
        if (focus != expected or self.editor_nav_back.items.len != 1) return -1;
    }
    std.debug.print("SYMBOL_PREVIEW stage={d} open={any} focus={d} top={d} revision={d} history={d} rows={d} selected={d}\n", .{ stage, open, focus, term.rt.editor_first_line, doc.file.revision, self.editor_nav_back.items.len, self.symbol_picker_rows.rows.items.len, self.chrome_host.symbol_picker.selected });
    return 1;
}
