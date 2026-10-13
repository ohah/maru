// 격리 GUI 사본의 관측기. 닫기와 저장 선택은 Swift의 실제 NSEvent가 수행한다.
var native_close_surface: u64 = 0;
fn nativeCloseTerm(self: *AppSession) ?*app_session_mod.Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (term.surface.id == native_close_surface) return term;
    return null;
}
export fn maru_editor_native_close_probe(stage: u32) callconv(.c) i32 {
    const self = editor_project_search_session orelse return 0;
    if (stage == 0 or stage == 5 or stage == 10) return 1;
    if (stage == 4) {
        if (self.editor_save_close != null) return 0;
        return if (nativeCloseTerm(self) == null) 1 else -1;
    }
    const term = nativeCloseTerm(self) orelse return -1;
    const doc = term.rt.editorDocument().opened orelse return -1;
    if (stage == 1 or stage == 6 or stage == 11)
        return if (!editor_ops.isDirty(term) and std.mem.eql(u8, doc.file.content, "foo")) 1 else -1;
    if (stage == 2 or stage == 7 or stage == 12)
        return if (self.pending_confirm == .editor_save_close and self.chrome_host.confirm.open and editor_ops.isDirty(term)) 1 else 0;
    if (stage == 3 or stage == 8 or stage == 13) {
        std.debug.print("NATIVE_CLOSE_PENDING state={any} owner={s} modal={any} requests={d} dirty={any}\n", .{ self.editor_save_close != null, @tagName(self.pending_confirm), self.chrome_host.confirm.open, @import("editor/save/dispatch.zig").requestCount(), editor_ops.isDirty(term) });
        const pending = self.editor_save_close orelse return -1;
        const receipt = pending.receipt orelse return 0;
        if (receipt.result == .pending and @import("editor/save/dispatch.zig").requestCount() == 0) return 0;
        return if (receipt.result == .pending) 1 else -1;
    }
    if (stage == 9 or stage == 14) {
        if (self.editor_save_close != null or !self.chrome_host.notice.open) return 0;
        const body: []const u8 = if (stage == 9) "foo!x" else "foo!";
        return if (editor_ops.isDirty(term) and std.mem.eql(u8, doc.file.content, body)) 1 else -1;
    }
    return 1;
}
export fn maru_editor_native_close_action(action: u32) callconv(.c) void {
    const self = editor_project_search_session orelse return;
    if (action == 10) {
        const term = nativeCloseTerm(self) orelse return;
        const path = term.rt.editorDocument().path orelse return;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "outside" }) catch return;
        return;
    }
    if (action > 2) return;
    const root = self.file_tree.rootAt(0) orelse return;
    const names = [_][]const u8{ "native-close-saved.txt", "native-close-kept.txt", "native-close-conflict.txt" };
    const path = std.fs.path.join(self.allocator, &.{ root, names[action] }) catch return;
    defer self.allocator.free(path);
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "foo" }) catch return;
    self.chrome_host.notice.open = false;
    self.focusWorkspaceInput();
    const term = editor_ops.openPathInActivePane(self, path) catch return;
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(3);
    native_close_surface = term.surface.id;
    self.metal_dirty = true;
}
