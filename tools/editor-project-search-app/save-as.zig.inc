// 명령과 저장 대화상자의 동작은 AppKit이 수행한다. 이 관측기는 모델과 디스크를 검증한다.
var save_as_surface: u64 = 0;
export fn maru_editor_save_as_probe(stage: u32) callconv(.c) i32 {
    const self = editor_project_search_session orelse return 0;
    if (stage == 0) return 1;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.surface.id != save_as_surface or term.kind != .editor) return -1;
    const doc = term.rt.editorDocument();
    if (stage == 1) return if (std.mem.eql(u8, doc.opened.?.file.content, "foo")) 1 else -1;
    if (stage == 4) {
        if (@import("editor/save/as.zig").pending() != 0) return 0;
        return if (std.mem.endsWith(u8, doc.path.?, "save-as-destination.txt") and !editor_ops.isDirty(term) and std.mem.eql(u8, doc.opened.?.file.content, "foo!")) 1 else -1;
    }
    return 1;
}
export fn maru_editor_save_as_setup() callconv(.c) void {
    const self = editor_project_search_session orelse return;
    const root = self.file_tree.rootAt(0) orelse return;
    const path = std.fs.path.join(self.allocator, &.{ root, "save-as-source.txt" }) catch return;
    defer self.allocator.free(path);
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "foo" }) catch return;
    self.focusWorkspaceInput();
    const term = editor_ops.openPathInActivePane(self, path) catch return;
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(3);
    save_as_surface = term.surface.id;
    self.metal_dirty = true;
}
