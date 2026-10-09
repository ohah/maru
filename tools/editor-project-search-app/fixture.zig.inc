// 격리 사본의 관측기. 입력·이동·취소는 제품 명령과 AppKit 이벤트가 수행한다.
var editor_project_search_session: ?*AppSession = null;
var editor_project_search_root_ready = false;
var editor_project_search_root_submitted = false;
var editor_project_search_original_surface: u64 = 0;
var editor_project_search_probe_stage: u32 = 0;
pub fn editorProjectSearchObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_CAPTURE") != null and self.dock_initialized) editor_project_search_session = self;
}
export fn maru_editor_project_search_probe(stage: u32) callconv(.c) i32 {
    if (stage != 100) editor_project_search_probe_stage = stage;
    const self = editor_project_search_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_syntax.pending or !self.file_tree_initialized) return 0;
    if (!editor_project_search_root_ready) {
        const path = term.rt.editorDocument().path orelse return -1;
        const root = std.fs.path.dirname(path) orelse return -1;
        if (!editor_project_search_root_submitted) {
            self.file_tree_root_picker_inflight = .replace;
            self.provideFileTreeRootPick(root);
            editor_project_search_root_submitted = true;
            return 0;
        }
        if (self.file_tree.rootCount() != 1 or !std.mem.eql(u8, self.file_tree.rootAt(0).?, root) or self.file_tree.rootCapabilityForPath(root) == null or self.editor_project_search_watch_generation != self.file_tree.rootGeneration()) return 0;
        editor_project_search_root_ready = true;
    }
    const state = &self.editor_search;
    if (stage == 0) editor_project_search_original_surface = term.surfaceId();
    if (stage == 100) {
        const unicode = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_UNICODE") orelse return -1), "1");
        const selected = state.fields[0].selection orelse return -1;
        return if (selected.lo() == (if (unicode) @as(usize, 3) else 2) and selected.hi() == (if (unicode) @as(usize, 10) else 5) and state.result.phase == .complete) 1 else -1;
    }

    if (stage == 2 and state.result.phase != .complete) {
        if (state.result.phase == .failed or state.result.phase == .partial) {
            std.debug.print("SEARCH_INCOMPLETE phase={s} failure={any} matches={d} excluded={d}\n", .{@tagName(state.result.phase), state.result.failure, state.result.model.matches, state.result.excluded});
            return -1;
        }
        return 0;
    }
    const expected = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_EXPECTED") orelse return -1), 10) catch return -1;
    if (stage == 2 and state.result.model.matches != expected) {
        std.debug.print("SEARCH_COUNT expected={d} actual={d} excluded={d}\n", .{expected, state.result.model.matches, state.result.excluded});
        return -1;
    }
    if (stage == 3 and (term.rt.editor_selection == null or term.rt.editor_selection.?.isEmpty())) return -1;
    if (stage == 4 and (self.dock.side != .bottom or state.scroll.offset_y_px != @min(@as(u32, 1000000), @import("editor/search/dock.zig").scrollExtent(self).max_offset_px))) return -1;
    if (stage == 5) {
        if (state.nav != null or state.result.phase != .complete) return 0;
        if (term.surfaceId() == editor_project_search_original_surface) return -1;
        const file = term.rt.editorDocument().opened orelse return -1;
        if (!std.mem.startsWith(u8, file.file.content, "sample disk\n") or term.rt.editor_selection == null or term.rt.editor_selection.?.isEmpty()) return -1;
    }
    if (stage == 6) {
        if (state.result.phase != .cancelled or !search_cancel_was_active) return -1;
        if (search_cancel_retired_ns == null) return 0;
        std.debug.print("SEARCH_METRICS first_ns={d} complete_ns={d} tick_max_ns={d} cancel_call_ns={d} cancel_retire_ns={d}\n", .{search_first_ns.? - search_started_ns.?, search_complete_ns.? - search_started_ns.?, search_tick_max_ns, search_cancel_return_ns.? - search_cancel_ns.?, search_cancel_retired_ns.? - search_cancel_ns.?});
    }
    std.debug.print("EDITOR_PROJECT_SEARCH stage={d} matches={d} scroll={d} phase={s}\n", .{stage, state.result.model.matches, state.scroll.offset_y_px, @tagName(state.result.phase)});
    return 1;
}
export fn maru_editor_project_search_action(stage: u32) callconv(.c) void {
    const self = editor_project_search_session orelse return;
    switch (stage) {
        0 => self.dispatchAppAction(.show_project_search),
        3 => {
            self.dispatchAppAction(.toggle_file_panel_dock_side);
            @import("editor/search/dock.zig").setScroll(self, 1000000);
        },
        4 => {
            const d = @import("editor/search/dock.zig");
            d.run(self);
            @import("editor/search/owner.zig").poll(self);
            search_cancel_was_active = if (self.editor_project_search_live) |*live| !live.job.done() else false;
            search_cancel_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
            d.cancel(self);
            search_cancel_return_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        },
        else => {},
    }
}
export fn maru_editor_project_search_coordinate(axis: u32) callconv(.c) f64 {
    const self = editor_project_search_session orelse return -1;
    const d = @import("editor/search/dock.zig");
    if (!d.publish(self)) return -1;
    for (self.editor_search.actions.items) |entry| {
        switch (entry.intent) {
            .row => |index| {
                if (index >= self.editor_search.result.model.visible.items.len or self.editor_search.result.model.visible.items[index] != .hit) continue;
                const hit = self.editor_search.result.model.visible.items[index].hit;
                const source = self.editor_search.result.model.rows.items[hit.row].source;
                // 디스크 fixture가 적어도 하단의 첫 표시 행을 디스크라고 가정하지 않는다.
                if (editor_project_search_probe_stage == 4 and source != .disk) continue;
                if (editor_project_search_probe_stage == 2 and source != .model) continue;
                for (self.editor_search.entries.items) |rect| if (rect.id == maru.chrome.components.project_search.build.rowId(index)) return if (axis == 0) rect.rect.x + rect.rect.width / 2 else rect.rect.y + rect.rect.height / 2;
            },
            else => {},
        }
    }
    return -1;
}

var search_started_ns: ?i128 = null;
var search_first_ns: ?i128 = null;
var search_complete_ns: ?i128 = null;
var search_tick_max_ns: i128 = 0;
var search_cancel_ns: ?i128 = null;
var search_cancel_return_ns: ?i128 = null;
var search_cancel_retired_ns: ?i128 = null;
var search_cancel_was_active = false;
pub fn editorProjectSearchTick(self: *AppSession) void {
    const before = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (self.editor_search.fields[0].text.items.len != 0 and search_started_ns == null) search_started_ns = before;
    @import("editor/search/owner.zig").poll(self);
    @import("editor/search/dock.zig").pump(self);
    const after = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (search_started_ns != null) search_tick_max_ns = @max(search_tick_max_ns, after - before);
    if (self.editor_search.result.model.matches != 0 and search_first_ns == null) search_first_ns = after;
    if (self.editor_search.result.phase == .complete and search_complete_ns == null) search_complete_ns = after;
    if (search_cancel_ns != null and search_cancel_retired_ns == null and self.editor_project_search_live == null and @import("editor/search/backend.zig").outstandingWorkers() == 0) search_cancel_retired_ns = after;
}

export fn maru_editor_project_search_field_coordinate(byte: u32, axis: u32) callconv(.c) f64 {
    const self = editor_project_search_session orelse return -1;
    const d = @import("editor/search/dock.zig");
    if (!d.publish(self)) return -1;
    const tree: maru.chrome.ui.tree.UiRectTree = .{ .entries = self.editor_search.entries.items, .generation = self.editor_search.published_generation };
    const rect = tree.entries[tree.find(maru.chrome.components.project_search.build.fieldId(0)) orelse return -1].rect;
    if (axis == 1) return rect.y + rect.height / 2;
    const m = d.metrics(self);
    const measured = d.measure(self, self.editor_search.fields[0].text.items, .{byte, byte, byte}, @as(u32, @intFromFloat(rect.width)) -| m.inset * 2) catch return -1;
    return rect.x + @as(f32, @floatFromInt(m.inset)) + measured[0] + 0.1;
}
