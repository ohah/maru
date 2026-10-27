// 명령과 저장 대화상자의 동작은 AppKit이 수행한다. 이 관측기는 모델과 디스크를 검증한다.
var save_as_surface: u64 = 0;
var save_as_history_verified = false;
fn saveAsCancelled() bool {
    const scenario = std.mem.span(std.c.getenv("MARU_EDITOR_SAVE_AS_SCENARIO") orelse "save");
    const overwrite = std.mem.span(std.c.getenv("MARU_EDITOR_SAVE_AS_OVERWRITE") orelse "accept");
    return std.mem.eql(u8, scenario, "cancel") or std.mem.eql(u8, overwrite, "cancel");
}
fn saveAsModel(self: *AppSession, term: *app_session_mod.Term) !void {
    const root = std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_OUTPUT") orelse return error.MissingRoot);
    const path = try std.fs.path.join(self.allocator, &.{ root, "save-as-model.json" });
    defer self.allocator.free(path);
    const doc = term.rt.editorDocument();
    const bytes = try std.json.Stringify.valueAlloc(self.allocator, .{
        .schema = "maru.save-as-model.v1", .pid = std.c.getpid(),
        .surface_id = term.surface.id, .path = doc.path.?,
        .body = doc.opened.?.file.content, .dirty = editor_ops.isDirty(term),
        .pending = @import("editor/save/as.zig").pending(), .history_verified = save_as_history_verified,
    }, .{});
    defer self.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
}
export fn maru_editor_save_as_probe(stage: u32) callconv(.c) i32 {
    const self = editor_project_search_session orelse return 0;
    if (stage == 0) return 1;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.surface.id != save_as_surface or term.kind != .editor) return -1;
    const doc = term.rt.editorDocument();
    if (stage == 1) return if (std.mem.eql(u8, doc.opened.?.file.content, "foo")) 1 else -1;
    const scenario = std.mem.span(std.c.getenv("MARU_EDITOR_SAVE_AS_SCENARIO") orelse "save");
    if (stage == 6) return if (std.mem.eql(u8, term.rt.editor_preedit, "한")) 1 else 0;
    if (stage == 5) return if (@import("editor/save/as.zig").pending() != 0 and std.mem.endsWith(u8, doc.path.?, "save-as-source.txt") and std.mem.eql(u8, doc.opened.?.file.content, "foo!")) 1 else -1;
    if (stage == 4) {
        if (@import("editor/save/as.zig").pending() != 0) return 0;
        std.debug.print("SAVE_AS_RESULT name={s} dirty={any} bytes={d}\n", .{ std.fs.path.basename(doc.path.?), editor_ops.isDirty(term), doc.opened.?.file.content.len });
        const cancelled = saveAsCancelled();
        const edited = std.mem.eql(u8, scenario, "edit-during-write");
        const name = if (cancelled) "save-as-source.txt" else std.mem.span(std.c.getenv("MARU_EDITOR_SAVE_AS_NAME") orelse "save-as-destination.txt");
        const physical = std.c.getenv("MARU_EDITOR_SAVE_AS_PHYSICAL_IME") != null;
        if (physical and term.rt.editor_preedit.len != 0) return -1;
        const content = if (physical) "foo한" else if (edited) "foo!?" else "foo!";
        saveAsModel(self, term) catch return -1;
        const actual_name = maru.grapheme.composeHangul(self.allocator, std.fs.path.basename(doc.path.?)) catch return -1;
        defer self.allocator.free(actual_name);
        const wanted_name = maru.grapheme.composeHangul(self.allocator, name) catch return -1;
        defer self.allocator.free(wanted_name);
        return if (std.mem.eql(u8, actual_name, wanted_name) and editor_ops.isDirty(term) == (cancelled or edited) and std.mem.eql(u8, doc.opened.?.file.content, content)) 1 else -1;
    }
    return 1;
}
export fn maru_editor_save_as_history() callconv(.c) i32 {
    const self = editor_project_search_session orelse return -1;
    const term = pane_ops.activePane(self).activeTerm();
    const doc = term.rt.editorDocument();
    const before = self.allocator.dupe(u8, doc.opened.?.file.content) catch return -1;
    defer self.allocator.free(before);
    if (!editor_ops.undoEdit(self, term) or std.mem.eql(u8, before, doc.opened.?.file.content)) return -1;
    if (!editor_ops.redoEdit(self, term) or !std.mem.eql(u8, before, doc.opened.?.file.content)) return -1;
    save_as_history_verified = true;
    std.debug.print("SAVE_AS_HISTORY undo=true redo=true\n", .{});
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
