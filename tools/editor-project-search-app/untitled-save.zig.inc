// 격리 앱에서 첫 저장 호출의 모델 결과를 확인한다. 제품 저장 정책은 바꾸지 않는다.
var untitled_benchmark_surface: u64 = 0;
export fn maru_untitled_benchmark_setup() callconv(.c) i32 {
    const self = editor_project_search_session orelse return -1;
    const size = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_UNTITLED_BYTES") orelse "65536"), 10) catch return -1;
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
    const doc = term.rt.editorDocument();
    if (doc.untitled != null or doc.path == null or term.file_entry == null or editor_ops.isDirty(term)) return -1;
    return if (std.mem.endsWith(u8, doc.path.?, "/untitled-benchmark.txt")) 1 else -1;
}
