// 외부 측정 사본 전용. 입력을 대신 실행하지 않고 모델과 성공한 full-frame 게시를 읽는다.
pub var latency_frame: [7]u64 = @splat(0);
pub fn latencyState(self: *AppSession) [7]u64 {
    if (!self.surface_initialized) return @splat(0);
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return @splat(0);
    const state = term.rt.editorDocument();
    const doc = state.opened orelse return @splat(0);
    var ready = true;
    var views: u64 = 0;
    var brackets = true;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |peer| {
        if (peer.kind != .editor or peer.rt.editorDocument() != state) continue;
        views += 1;
        brackets = brackets and @import("editor/syntax.zig").bracketSource(&peer.rt.editor_syntax) != null;
        const s = &peer.rt.editor_syntax;
        ready = ready and !s.pending and s.provider != null and s.provider.?.tree != null;
        if (s.async_view.enabled) ready = ready and s.parse_result != null and s.parse_result.?.tag().input.revision == doc.file.revision;
    };
    return .{ self.metal_buffer.generation, doc.file.revision,
        if (term.rt.editor_preedit.len == 0) 0 else std.hash.Wyhash.hash(0, term.rt.editor_preedit),
        @intFromBool(ready), views, doc.file.content.len, @as(u64, @intFromBool(brackets)) | (@as(u64, @intFromBool(term.rt.editor_syntax.async_view.enabled)) << 1) };
}
pub fn latencyStamp(self: *AppSession) void { latency_frame = latencyState(self); }
