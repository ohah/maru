// 격리 앱에만 붙인다. 편집 생성은 새 API, Undo/Redo 선택은 제품 AppKit 입력을 사용한다.
var editor_linked_history_session: ?*AppSession = null;
var editor_linked_history_first: ?*app_session_mod.Term = null;
var editor_linked_history_second: ?*app_session_mod.Term = null;
pub fn editorLinkedHistoryObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_EDITOR_LINKED_HISTORY_CAPTURE") != null and self.dock_initialized) editor_linked_history_session = self;
}
export fn maru_editor_linked_history_probe(stage: u32) callconv(.c) i32 {
    const self = editor_linked_history_session orelse return 0;
    if (stage == 0 and editor_linked_history_first == null) {
        const a = pane_ops.activePane(self).activeTerm();
        if (a.kind != .editor or a.rt.editorDocument().opened == null) return 0;
        const path = std.mem.span(std.c.getenv("MARU_EDITOR_LINKED_HISTORY_SECOND") orelse return -1);
        _ = pane_ops.splitSharedEditorPane(self, .horizontal, false) catch return -1;
        const b = editor_ops.openPathInActivePane(self, path) catch return -1;
        editor_linked_history_first = a;
        editor_linked_history_second = b;
        _ = self.activateExistingFileTerm(a);
        a.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
        b.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
        _ = editor_ops.linked_history.apply(self, &.{
            .{ .term = a, .changes = &.{.{ .start = 0, .end = 5, .text = "FIRST EDITED" }} },
            .{ .term = b, .changes = &.{.{ .start = 0, .end = 6, .text = "SECOND EDITED" }} },
        }) catch return -1;
    }
    const a = editor_linked_history_first orelse return 0;
    const b = editor_linked_history_second orelse return 0;
    const original_a = stage == 3 or stage == 4 or stage == 7;
    const original_b = stage == 3 or stage == 4;
    if (!std.mem.eql(u8, a.rt.editorDocument().opened.?.file.content, if (original_a) "first original\n" else "FIRST EDITED original\n")) return -1;
    if (!std.mem.eql(u8, b.rt.editorDocument().opened.?.file.content, if (original_b) "second original\n" else "SECOND EDITED original\n")) return -1;
    if (self.chrome_host.confirm.open != (stage == 1 or stage == 4 or stage == 6)) return -1;
    std.debug.print("EDITOR_LINKED_HISTORY stage={d} A_undo={d} B_undo={d} confirm={}\n", .{stage, a.rt.editorDocument().history.undo_len, b.rt.editorDocument().history.undo_len, self.chrome_host.confirm.open});
    return 1;
}
export fn maru_editor_linked_history_coordinate(current: bool, axis: u32) callconv(.c) f64 {
    const self = editor_linked_history_session orelse return -1;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var ops: std.ArrayList(chrome.draw.Op) = .empty;
    const tk = self.buildChromeTokens();
    chrome.components.confirm.view(&self.chrome_host.confirm, self.buildChromeProps(), &tk, arena.allocator(), &ops) catch return -1;
    for (ops.items) |op| switch (op) {
        .fill => |fill| {
            const x: f64 = @floatFromInt(fill.rect.x + @as(i32, @intCast(fill.rect.w / 2)));
            const y: f64 = @floatFromInt(fill.rect.y + @as(i32, @intCast(fill.rect.h / 2)));
            const action = chrome.components.confirm.buttonAtPoint(&self.chrome_host.confirm, self.buildChromeProps(), &tk, x, y) orelse continue;
            if (action == (if (current) chrome.components.confirm.Action.alternate else .confirmed)) return if (axis == 0) x else y;
        },
        else => {},
    };
    return -1;
}
