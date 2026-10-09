// 격리 사본의 관측기. 입력·이동·취소는 제품 명령과 AppKit 이벤트가 수행한다.
var editor_project_search_session: ?*AppSession = null;
var editor_project_search_root_ready = false;
var editor_project_search_root_submitted = false;
var editor_project_search_original_surface: u64 = 0;
var editor_project_search_probe_stage: u32 = 0;
var editor_project_search_ime_observed: u64 = 0;
var editor_project_search_matrix_surface: u64 = 0;
var editor_project_search_matrix_history: usize = 0;
pub fn editorProjectSearchObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_CAPTURE") != null and self.dock_initialized) editor_project_search_session = self;
}
export fn maru_editor_project_search_probe(stage: u32) callconv(.c) i32 {
    if (stage < 100) editor_project_search_probe_stage = stage;
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
    if (stage >= 7 and stage <= 11) {
        if (state.result.phase != .complete or state.nav != null) return 0;
        const base = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_EXPECTED") orelse return -1), 10) catch return -1;
        const wanted = if (stage == 8) base * 2 else if (stage >= 10) @as(usize, 1) else base;
        if (state.result.model.matches != wanted) return -1;
        if (stage == 7 and (term.rt.editor_document_lease == null or self.editor_documents.viewCount(term.rt.editor_document_lease.?).? != 2)) return -1;
        if (stage == 8 and state.result.model.groups.items.len != 2) return -1;
        if (stage == 9) {
            if (state.result.model.groups.items.len != 1 or state.result.model.groups.items[0].source != .model) return -1;
            if (!std.mem.eql(u8, term.rt.editorDocument().opened.?.file.content, "no results")) return -1;
        }
        if (stage >= 10) {
            if (state.result.model.groups.items.len != 1 or state.result.model.groups.items[0].source != .disk or !std.mem.eql(u8, state.result.model.groups.items[0].path, "fresh.txt")) return -1;
            if (term.surfaceId() != editor_project_search_matrix_surface or self.editor_nav_back.items.len != editor_project_search_matrix_history) return -1;
        }
        std.debug.print("SEARCH_MATRIX stage={d} matches={d} groups={d}\n", .{stage, state.result.model.matches, state.result.model.groups.items.len});
        return 1;
    }
    if (stage == 23) return if (state.result.phase == .complete) 1 else 0;
    if (stage == 24) return if (state.preview.phase == .ready) 1 else if (state.preview.phase == .conflict or state.preview.phase == .failed) -1 else 0;
    if (stage == 25) {
        const report = term.rt.editor_search_report orelse return 0;
        return if (report.hits.items.len == 0 and term.rt.editorDocument().opened.?.file.read_only) 1 else -1;
    }
    if (stage == 21) {
        const report = term.rt.editor_search_report orelse return 0;
        if (report.hits.items.len == 0 or !term.rt.editorDocument().opened.?.file.read_only or term.rt.editor_recovery != null) return -1;
        return 1;
    }
    if (stage == 22) {
        if (term.surfaceId() != editor_project_search_original_surface or term.rt.editor_selection == null) return 0;
        return if (term.rt.editor_selection.?.focus > term.rt.editor_selection.?.anchor_start) 1 else -1;
    }
    if (stage >= 12 and stage <= 20) {
        const preview = &state.preview;
        if (stage >= 18 and self.dock.side != .right) return -1;
        if (stage == 12) return if (state.result.phase == .complete) 1 else 0;
        if (stage == 13) return if (state.result.phase == .complete and state.replacing and state.focused == 3) 1 else -1;
        if (stage == 15 or stage == 20) return if (preview.phase == .conflict and preview.plan != null) 1 else -1;
        if (preview.phase == .building or preview.phase == .verifying) return 0;
        if (preview.phase != .ready or preview.plan == null) {
            std.debug.print("REPLACE_FAILURE stage={d} phase={s} failure={any}\n", .{stage, @tagName(preview.phase), preview.failure});
            return -1;
        }
        const expected_count = if (stage == 14 or stage == 19) std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_MODEL_MATCHES") orelse return -1), 10) catch return -1 else 1;
        if (preview.plan.?.replacements != expected_count or std.mem.indexOf(u8, preview.plan.?.after, "renamed") == null) return -1;
        if (std.mem.indexOf(u8, term.rt.editorDocument().opened.?.file.content, "renamed") != null) return -1;
        std.debug.print("REPLACE_READY stage={d} replacements={d} source_bytes={d} modified_bytes={d}\n", .{stage, preview.plan.?.replacements, preview.plan.?.before.len, preview.plan.?.after.len});
        return 1;
    }
    if (stage == 101) {
        var h = std.hash.Wyhash.init(0);
        h.update(state.fields[0].text.items);
        h.update(state.fields[0].preedit.items);
        const stamp = h.final();
        if (stamp != editor_project_search_ime_observed) {
            editor_project_search_ime_observed = stamp;
            std.debug.print("PHYSICAL_STATE text={s} preedit={s} phase={s} focus={any}\n", .{state.fields[0].text.items, state.fields[0].preedit.items, @tagName(state.result.phase), state.focused});
        }
    }
    if (stage == 101) return if (std.mem.eql(u8, state.fields[0].preedit.items, "글") and state.result.phase == .composing and self.editor_project_search_query == null) 1 else 0;
    if (stage == 103) return if (!@import("editor/search/dock.zig").ownsInput(self) and state.focused == null and self.editor_project_search_query == null and state.entries.items.len == 0) 1 else -1;
    if (stage == 102) return if (std.mem.eql(u8, state.fields[0].text.items, "한글") and state.fields[0].preedit.items.len == 0) 1 else -1;
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
        22 => {
            const d = @import("editor/search/dock.zig");
            d.open(self);
            self.editor_search.fields[3].selectAll();
            self.editor_search.focused = 3;
            _ = d.commitText(self, "renamed");
            self.editor_search.replacing = true;
            d.run(self);
        },
        23 => {
            for (self.editor_search.result.model.visible.items, 0..) |visible, index| if (visible == .file and self.editor_search.result.model.groups.items[visible.file].source == .model) {
                @import("editor/search/preview.zig").start(self, index) catch return;
                break;
            };
        },
        20 => {
            @import("editor/search/preview.zig").back(self);
            self.editor_search.replacing = false;
            self.editor_search.focused = null;
            self.editor_search.invalidate();
        },
        21 => {
            const active = pane_ops.activePane(self).activeTerm();
            const report = active.rt.editor_search_report orelse return;
            for (report.hits.items) |hit| if (report.rows.items[hit.row].source == .model) {
                const at = active.rt.editorDocument().opened.?.file.lines.line(hit.line).?.start;
                active.rt.editor_selection = maru.session.editor.selection.Selection.at(at);
                _ = self.handleKeyEvent(.{ .key = .enter }) catch return;
                break;
            };
        },
        17 => self.dispatchAppAction(.toggle_file_panel_dock_side),
        18 => {
            @import("editor/search/preview.zig").back(self);
            for (self.editor_search.result.model.visible.items, 0..) |visible, index| if (visible == .file and self.editor_search.result.model.groups.items[visible.file].source == .model) {
                @import("editor/search/preview.zig").start(self, index) catch return;
                break;
            };
        },
        19 => _ = @import("editor/search/dock.zig").commitText(self, "x"),
        12 => {
            const d = @import("editor/search/dock.zig");
            d.open(self);
            d.run(self);
        },
        14 => {
            self.editor_search.focused = 3;
            _ = @import("editor/search/dock.zig").commitText(self, "x");
        },
        15 => {
            const d = @import("editor/search/dock.zig");
            @import("editor/search/preview.zig").back(self);
            self.editor_search.fields[3].selectAll();
            _ = d.commitText(self, "renamed");
            for (self.editor_search.result.model.visible.items, 0..) |visible, index| if (visible == .hit) {
                const row = self.editor_search.result.model.rows.items[visible.hit.row];
                if (row.source == .model) {
                    @import("editor/search/preview.zig").start(self, index) catch return;
                    break;
                }
            };
        },
        16 => {
            @import("editor/search/preview.zig").back(self);
            for (self.editor_search.result.model.visible.items, 0..) |visible, index| if (visible == .file) {
                if (self.editor_search.result.model.groups.items[visible.file].source == .disk) {
                    @import("editor/search/preview.zig").start(self, index) catch return;
                    break;
                }
            };
        },
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
        6 => {
            self.dispatchAppAction(.split_editor_right);
            self.dispatchAppAction(.show_project_search);
            @import("editor/search/dock.zig").run(self);
        },
        7 => {
            const active = pane_ops.activePane(self).activeTerm();
            _ = editor_ops.openPathInActivePane(self, active.rt.editorDocument().path.?) catch return;
            self.dispatchAppAction(.show_project_search);
            @import("editor/search/dock.zig").run(self);
        },
        8 => self.focusWorkspaceInput(),
        9 => {
            editor_project_search_matrix_surface = pane_ops.activePane(self).activeTerm().surfaceId();
            editor_project_search_matrix_history = self.editor_nav_back.items.len;
            self.file_tree_root_picker_inflight = .replace;
            self.provideFileTreeRootPick(std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_SEARCH_OTHER_ROOT") orelse return));
        },
        else => {},
    }
}
export fn maru_editor_project_search_coordinate(axis: u32) callconv(.c) f64 {
    const self = editor_project_search_session orelse return -1;
    if (!@import("editor/search/dock.zig").publish(self)) return -1;
    if (editor_project_search_probe_stage == 20 or editor_project_search_probe_stage == 24) {
        for (self.editor_search.entries.items) |entry| if (entry.id == maru.chrome.components.project_search.build.optionId(8)) return if (axis == 0) entry.rect.x + entry.rect.width / 2 else entry.rect.y + entry.rect.height / 2;
        return -1;
    }
    if (editor_project_search_probe_stage == 12) {
        if (!self.editor_search.replacing) {
            for (self.editor_search.entries.items) |entry| if (entry.id == maru.chrome.components.project_search.build.optionId(6)) return if (axis == 0) entry.rect.x + entry.rect.width / 2 else entry.rect.y + entry.rect.height / 2;
            return -1;
        }
        for (self.editor_search.entries.items) |entry| if (entry.id == maru.chrome.components.project_search.build.fieldId(3)) return if (axis == 0) entry.rect.x + 20 else entry.rect.y + entry.rect.height / 2;
        return -1;
    }
    if (editor_project_search_probe_stage == 13) {
        for (self.editor_search.result.model.visible.items, 0..) |visible, index| if (visible == .file and self.editor_search.result.model.groups.items[visible.file].source == .model) {
            for (self.editor_search.entries.items) |entry| if (entry.id == maru.chrome.components.project_search.build.rowId(index)) return if (axis == 0) entry.rect.x + entry.rect.width / 2 else entry.rect.y + entry.rect.height / 2;
        };
        return -1;
    }

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
