// 격리 앱 사본에서만 붙이는 관측기다. 깜빡임 위상은 제품 타이머로 진행한다.
var editor_caret_activity_session: ?*AppSession = null;
pub fn editorCaretActivityObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_EDITOR_CARET_ACTIVITY_CAPTURE") != null and self.dock_initialized) editor_caret_activity_session = self;
}
export fn maru_editor_caret_activity_probe(expected: u32) callconv(.c) i32 {
    const self = editor_caret_activity_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editorDocument().opened == null) return 0;
    if (expected == 0) return if (!self.blink_visible) 1 else 0;
    const count = @import("editor/mod.zig").selections(term).count();
    const passed = self.blink_visible and self.metal_buffer.cursor_fade_milli == 1000 and count == expected;
    std.debug.print("EDITOR_CARET_ACTIVITY expected={d} passed={} visible={} phase={d} opacity={d} cursors={d}\n", .{ expected, passed, self.blink_visible, self.blink_phase_ns, self.metal_buffer.cursor_fade_milli, count });
    return if (passed) 1 else -1;
}
export fn maru_editor_caret_activity_prepare() callconv(.c) bool {
    const self = editor_caret_activity_session orelse return false;
    @import("editor/mod.zig").navigateTo(self, .{ .offset = 2 }) catch return false;
    return true;
}
