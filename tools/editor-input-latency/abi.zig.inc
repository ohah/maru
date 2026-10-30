// 측정 사본만 내보내는 읽기 API와 타이머 밖 초기 배치다. 제품 ABI에는 추가하지 않는다.
pub export fn maru_latency_state(s: *AppSession, out: [*]u64) void {
    @memcpy(out[0..7], session_mod.debug_fixtures.latencyState(s)[0..7]);
}
pub export fn maru_latency_frame(generation: u64, out: [*]u64) void {
    const value = session_mod.debug_fixtures.latency_frame;
    @memcpy(out[0..7], value[0..7]);
    if (value[0] != generation) out[0] = 0;
}
pub export fn maru_latency_setup(s: *AppSession, shared: bool) bool {
    if (!s.surface_initialized) return false;
    const term = @import("app_session/pane.zig").activePane(s).activeTerm();
    if (term.kind != .editor or term.rt.editorDocument().opened == null) return false;
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(3);
    if (shared and !s.runAction("split_editor_right")) return false;
    s.metal_dirty = true;
    return true;
}
