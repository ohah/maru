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

pub const PreparedFilter = struct {
    filter: chrome.components.recovery_filter.Plan,
    prompt: maru.i18n.Key,
    pub fn deinit(self: *PreparedFilter, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
    }
};

/// Prepare the existing normalized comparison without changing input or UI state.
/// Discovery may append between keys; a synchronous preparation reads its latest rows.
pub fn prepareFilter(self: *AppSession, raw_query: []const u8) !PreparedFilter {
    const state = &self.editor_recovery;
    const catalog = &(state.catalog orelse return error.NoCatalog);
    const picker = &self.chrome_host.recovery_picker;
    var prepared: PreparedFilter = .{ .filter = try chrome.components.recovery_filter.Plan.init(self.allocator, catalog.candidates.items.len, raw_query), .prompt = .editor_recovery_prompt };
    errdefer prepared.deinit(self.allocator);
    var name_buf: [maru.session.editor.backup.max_file_name_len]u8 = undefined;
    var selected_name: []const u8 = "";
    if (picker.selected < state.shown.items.len) {
        const index = state.shown.items[picker.selected];
        if (index < catalog.candidates.items.len) {
            const name = catalog.candidates.items[index].name();
            @memcpy(name_buf[0..name.len], name);
            selected_name = name_buf[0..name.len];
        }
    }
    for (catalog.candidates.items, 0..) |*candidate, i| {
        prepared.filter.consider(i, candidate.name(), candidate.label, self.editor_documents.usesBackupName(candidate.name()), selected_name);
    }
    prepared.prompt = if (catalog.failure != null) .editor_recovery_partial else if (!catalog.complete) .editor_recovery_scanning else if (prepared.filter.shown.items.len == 0) .editor_recovery_empty else .editor_recovery_prompt;
    return prepared;
}

/// Publish only a complete result. Same-catalog refresh follows the selected identity;
/// changing the committed query keeps the existing reset-to-first-row policy.
pub fn publishFilter(self: *AppSession, prepared: *PreparedFilter, reset: bool) void {
    const state = &self.editor_recovery;
    const picker = &self.chrome_host.recovery_picker;
    const old_selected = picker.selected;
    std.mem.swap(std.ArrayList(usize), &state.shown, &prepared.filter.shown);
    state.filter_failed = false;
    if (reset) {
        picker.selected = 0;
        state.scroll = .{};
        state.followed = null;
    }
    picker.setResultCount(state.shown.items.len);
    if (!reset) {
        if (prepared.filter.selected) |selected| picker.selected = selected;
        if (picker.selected != old_selected) state.followed = null;
    }
    picker.prompt = maru.i18n.t(prepared.prompt);
    self.metal_dirty = true;
}

fn update(self: *AppSession, reset: bool) void {
    if (self.editor_recovery.catalog == null) return;
    var prepared = prepareFilter(self, self.chrome_host.recovery_picker.input.query.items) catch {
        // Legacy discovery failure stays visible and cannot become a restore grant.
        self.editor_recovery.filter_failed = true;
        self.chrome_host.recovery_picker.prompt = maru.i18n.t(.editor_recovery_partial);
        self.metal_dirty = true;
        return;
    };
    defer prepared.deinit(self.allocator);
    publishFilter(self, &prepared, reset);
}

pub fn recompute(self: *AppSession) void {
    update(self, true);
}

/// Same-catalog discovery progress must not interrupt a live IME composition.
pub fn refresh(self: *AppSession) void {
    update(self, false);
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
    const props = self.buildChromeProps();
    const layout = chrome.components.overlay_input.panelLayout(props) orelse return;
    const total = self.editor_recovery.shown.items.len;
    const count = @min(total, chrome.components.palette.max_visible);
    // 보이는 패널 밖이면 닫고, 패딩 띠·프롬프트 줄은 소비만 한다(`palette.panelHit` — 그리는 상자와 같은 출처).
    switch (chrome.components.palette.panelHit(props, count, x, y) orelse return) {
        .outside => closed(self),
        .panel => {},
        .row => |row| {
            const start = @min(self.editor_recovery.scroll.offset_y_px / layout.ch, total -| count);
            self.chrome_host.recovery_picker.selected = start + row;
            accept(self);
            self.swallow_multi_click = true; // 같은 겹클릭의 둘째 누름이 이동한 문서로 새지 않게
        },
    }
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
