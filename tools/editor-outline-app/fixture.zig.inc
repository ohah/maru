// 격리 검증 사본에만 붙이는 관측기다. 목록·선택은 제품 명령과 AppKit 입력으로만 바꾼다.
var editor_outline_session: ?*AppSession = null;
var editor_outline_owner: u64 = 0;
pub fn editorOutlineObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_EDITOR_OUTLINE_CAPTURE") != null and self.dock_initialized) editor_outline_session = self;
}
export fn maru_editor_outline_probe(stage: u32) callconv(.c) i32 {
    const self = editor_outline_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_syntax.pending) return 0;
    const doc = term.rt.editorDocument().opened orelse return 0;
    if (stage == 0 and term.rt.editor_selection == null) term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    if (stage == 0) editor_outline_owner = term.surfaceId();
    const outline = @import("editor/outline.zig");
    outline.refreshForFocus(self);
    const state = &self.editor_outline;
    if (stage > 0 and !outline.publish(self)) return -1;
    if (stage > 0 and stage < 9 and state.model.items.items.len != 63) return -1;
    if (stage == 2 and (state.active != 2 or self.editor_nav_back.items.len != 1)) return -1;
    if (stage == 3 and (state.model.visible.items.len != 61 or state.active != 0)) return -1;
    if (stage >= 4 and stage <= 8 and std.mem.indexOf(u8, doc.file.content, "renamed_") == null) return -1;
    if (stage >= 6 and stage <= 8 and std.mem.indexOf(u8, doc.file.content, "shared_") == null) return -1;
    if (stage == 5 and (term.surfaceId() == editor_outline_owner or state.key.?.source.surface_id != term.surfaceId())) return -1;
    if (stage == 7 and term.surfaceId() != editor_outline_owner) return -1;
    if (stage == 8 and (self.dock.side != .bottom or state.scroll.offset_y_px == 0)) return -1;
    if (stage == 9 and (state.status != .empty or state.model.items.items.len != 0)) return -1;
    std.debug.print("EDITOR_OUTLINE stage={d} surface={d} rows={d} visible={d} active={any} scroll={d} revision={d}\n", .{ stage, term.surfaceId(), state.model.items.items.len, state.model.visible.items.len, state.active, state.scroll.offset_y_px, doc.file.revision });
    return 1;
}
export fn maru_editor_outline_action(stage: u32) callconv(.c) void {
    const self = editor_outline_session orelse return;
    switch (stage) {
        0 => self.dispatchAppAction(.show_editor_outline),
        4 => self.dispatchAppAction(.split_editor_right),
        6 => self.dispatchAppAction(.focus_pane_left),
        7 => {
            self.dispatchAppAction(.toggle_file_panel_dock_side);
            @import("editor/outline.zig").setScroll(self, 1000000);
        },
        8 => self.dispatchAppAction(.new_editor_tab),
        else => {},
    }
}
export fn maru_editor_outline_coordinate(index: u32, disclosure: bool, axis: u32) callconv(.c) f64 {
    const self = editor_outline_session orelse return -1;
    if (!@import("editor/outline.zig").publish(self)) return -1;
    const component = maru.chrome.components.outline;
    const id = if (disclosure) component.build.disclosureId(index) else component.build.rowId(index);
    const tree = maru.chrome.ui.tree.UiRectTree{ .entries = self.editor_outline.entries.items };
    const entry = tree.find(id) orelse return -1;
    const rect = tree.entries[entry].rect;
    return if (axis == 0) rect.x + rect.width / 2 else rect.y + rect.height / 2;
}
