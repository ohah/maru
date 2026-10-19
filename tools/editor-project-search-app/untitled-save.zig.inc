// 격리 앱에서 첫 저장 호출의 모델 결과를 확인한다. 제품 저장 정책은 바꾸지 않는다.
var untitled_benchmark_surface: u64 = 0;
var untitled_benchmark_size: usize = 0;
export fn maru_untitled_benchmark_setup() callconv(.c) i32 {
    const self = editor_project_search_session orelse return -1;
    const size = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_UNTITLED_BYTES") orelse "65536"), 10) catch return -1;
    std.debug.print("UNTITLED_BUILD mode={s}\n", .{@tagName(builtin.mode)});
    untitled_benchmark_size = size;
    const data = self.allocator.alloc(u8, size) catch return -1;
    defer self.allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'x' else '\n';
    self.focusWorkspaceInput();
    const term = editor_ops.openUntitledInActivePane(self) catch return -1;
    untitled_benchmark_surface = term.surface.id;
    return if (editor_ops.insertText(self, term, data)) 1 else -1;
}
export fn maru_untitled_benchmark_save() callconv(.c) i32 {
    const self = editor_project_search_session orelse return -1;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.surface.id != untitled_benchmark_surface or term.rt.editorDocument().untitled == null) return -1;
    if (!app_session_mod.editor_untitled_save_ops.begin(self, term)) return -1;
    self.rename_input.setText(self.allocator, "untitled-benchmark.txt") catch return -1;
    @import("settings.zig").commitRename(self);
    return 1;
}

// 전문/표시 신원 검사는 stopwatch 밖에서 수행해 검사 비용을 저장 지연에 섞지 않는다.
export fn maru_untitled_benchmark_probe() callconv(.c) i32 {
    const self = editor_project_search_session orelse return -1;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.surface.id != untitled_benchmark_surface) return -1;
    const doc = term.rt.editorDocument();
    if (doc.untitled != null or doc.path == null or term.file_entry == null or editor_ops.isDirty(term) or self.rename != null) return -1;
    const entry = term.file_entry.?;
    if (entry.surface_id != term.surface.id or !std.mem.eql(u8, entry.path, doc.path.?)) return -1;
    const root = self.file_tree.rootAt(0) orelse return -1;
    const expected = std.fs.path.join(self.allocator, &.{ root, "untitled-benchmark.txt" }) catch return -1;
    defer self.allocator.free(expected);
    if (!std.mem.eql(u8, expected, doc.path.?)) return -1;
    const opened = doc.opened orelse return -1;
    if (opened.file.content.len != untitled_benchmark_size) return -1;
    for (opened.file.content, 0..) |byte, index| {
        if (byte != @as(u8, if (index % 2 == 0) 'x' else '\n')) return -1;
    }
    return 1;
}
