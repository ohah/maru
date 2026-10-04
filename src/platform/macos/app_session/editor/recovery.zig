//! 복구 목록의 사용자 흐름. 파일 열거는 discovery, 문서 게시는 editor가 소유한다.
const std = @import("std");
const maru = @import("maru");
const AppSession = @import("../../app_session.zig").AppSession;
const editor = @import("mod.zig");
const backup = @import("backup.zig");
const discovery = @import("discovery.zig");
const chrome = maru.chrome;

pub const State = struct {
    catalog: ?discovery.Catalog = null,
    shown: std.ArrayList(usize) = .empty,
    scroll: chrome.ui.scroll_area.State = .{},
    followed: ?usize = null,
    filter_failed: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit();
        self.shown.deinit(allocator);
        self.* = .{};
    }
};

pub fn open(self: *AppSession) void {
    self.dismissMessageOverlays();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = backup.dirPath(&buffer) orelse {
        self.showNoticeKey(.editor_recovery_failed);
        return;
    };
    self.editor_recovery.catalog = discovery.Catalog.init(self.allocator, self.io, root) catch {
        self.showNoticeKey(.editor_recovery_failed);
        return;
    };
    self.chrome_host.recovery_picker.show();
    recompute(self);
    self.metal_dirty = true;
}

pub fn closed(self: *AppSession) void {
    self.chrome_host.recovery_picker.hide();
    self.editor_recovery.deinit(self.allocator);
    self.metal_dirty = true;
}

pub fn tick(self: *AppSession) void {
    if (!self.chrome_host.recovery_picker.open) return;
    if (self.editor_recovery.catalog == null) return;
    if (self.editor_recovery.catalog.?.tick(self.editor_documents)) refresh(self);
}

pub fn recompute(self: *AppSession) void {
    self.chrome_host.recovery_picker.selected = 0;
    self.editor_recovery.scroll = .{};
    self.editor_recovery.followed = null;
    refresh(self);
}

fn refresh(self: *AppSession) void {
    const state = &self.editor_recovery;
    const catalog = &(state.catalog orelse return);
    const picker = &self.chrome_host.recovery_picker;
    // 용량부터 확보해야 OOM에서 이전 선택이 다른 후보를 가리키지 않는다.
    state.shown.ensureTotalCapacity(self.allocator, catalog.candidates.items.len) catch {
        state.filter_failed = true;
        picker.prompt = maru.i18n.t(.editor_recovery_partial);
        self.metal_dirty = true;
        return;
    };
    state.filter_failed = false;
    const query = maru.grapheme.composeHangul(self.allocator, picker.input.query.items) catch {
        state.filter_failed = true;
        picker.prompt = maru.i18n.t(.editor_recovery_partial);
        self.metal_dirty = true;
        return;
    };
    defer self.allocator.free(query);
    state.shown.clearRetainingCapacity();
    for (catalog.candidates.items, 0..) |*candidate, i| {
        if (self.editor_documents.usesBackupName(candidate.name())) continue;
        if (query.len == 0 or std.ascii.indexOfIgnoreCase(candidate.label, query) != null or std.ascii.indexOfIgnoreCase(candidate.name(), query) != null)
            state.shown.appendAssumeCapacity(i);
    }
    picker.setResultCount(state.shown.items.len);
    picker.prompt = maru.i18n.t(if (catalog.failure != null) .editor_recovery_partial else if (!catalog.complete) .editor_recovery_scanning else if (state.shown.items.len == 0) .editor_recovery_empty else .editor_recovery_prompt);
    self.metal_dirty = true;
}

pub fn accept(self: *AppSession) void {
    const state = &self.editor_recovery;
    const selected = self.chrome_host.recovery_picker.selected;
    if (state.filter_failed) {
        self.showNoticeKey(.editor_recovery_failed);
        return;
    }
    if (selected >= state.shown.items.len) return;
    const index = state.shown.items[selected];
    if (state.catalog == null) return;
    // 이후 알림은 목록을 닫을 수 있다. 원본 권한을 먼저 별도 값으로 분리한다.
    var source = state.catalog.?.select(index) catch {
        self.showNoticeKey(.editor_recovery_failed);
        return;
    };
    _ = editor.openRecoveredSource(self, &source) catch {
        source.deinit();
        self.showNoticeKey(.editor_recovery_failed);
        return;
    };
    closed(self);
    self.showNoticeKey(.editor_recovery_opened);
}

/// 렌더와 같은 창 시작·셀 크기로 행을 선택한다. 바깥 클릭은 원본을 소비하지 않고 닫는다.
pub fn click(self: *AppSession, x: f64, y: f64) void {
    const layout = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return;
    const total = self.editor_recovery.shown.items.len;
    const count = @min(total, chrome.components.palette.max_visible);
    const left: f64 = @floatFromInt(layout.x);
    const top: f64 = @floatFromInt(layout.y);
    if (x < left or x >= left + @as(f64, @floatFromInt(layout.panel_cols * layout.cw)) or
        y < top or y >= top + @as(f64, @floatFromInt((count + 1) * layout.ch)))
    {
        closed(self);
        return;
    }
    const row: usize = @intFromFloat((y - top) / @as(f64, @floatFromInt(layout.ch)));
    if (row == 0) return;
    const start = @min(self.editor_recovery.scroll.offset_y_px / layout.ch, total -| count);
    self.chrome_host.recovery_picker.selected = start + row - 1;
    accept(self);
}

pub fn rows(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.palette.Row {
    const state = &self.editor_recovery;
    const catalog = &(state.catalog orelse return &.{});
    const total = state.shown.items.len;
    const count = @min(total, chrome.components.palette.max_visible);
    const start = @min(state.scroll.offset_y_px / @max(self.cell_height_px, 1), total -| count);
    const result = try arena.alloc(chrome.components.palette.Row, count);
    const layout = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return &.{};
    for (result, 0..) |*row, i| {
        const index = state.shown.items[start + i];
        const candidate = &catalog.candidates.items[index];
        const name = candidate.name();
        const short_id = if (std.mem.startsWith(u8, name, "d-")) name[2..10] else name[0 .. name.len - 4];
        const detail = if (candidate.failure != null)
            try std.fmt.allocPrint(arena, "#{d} {s}", .{ index + 1, maru.i18n.t(.editor_recovery_unavailable) })
        else
            try std.fmt.allocPrint(arena, "#{d} {s} {d} B", .{ index + 1, short_id, candidate.bytes });
        const available = layout.panel_cols -| (chrome.components.overlay_input.displayCols(detail) + 5);
        const title = chrome.components.overlay_input.tailWindow(candidate.label, available -| 1);
        row.* = .{
            .title = if (title.truncated) try std.fmt.allocPrint(arena, "…{s}", .{title.text}) else title.text,
            .binding = detail,
            .selected = start + i == self.chrome_host.recovery_picker.selected,
        };
    }
    return result;
}
