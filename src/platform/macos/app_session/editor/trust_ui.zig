//! 저장소 신뢰 결정 목록(계획 WT4 — 팔레트 「Language Server: Repository Trust…」). 앱 전역 신뢰 표(`trust_store`)의 결정을 보이고,
//! 고르면 신뢰 관리 확인 상자(`lsp.manageListed` — 철회·잊기)로 간다. 신뢰를 **주는** 길은 여기 없다(신뢰 시트의 답뿐 — LSPB23).
//! 복구 목록(`recovery.zig`)과 같은 피커 컴포넌트·같은 행 모양이다.
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const trust_store = @import("trust_store.zig");
const lsp_client = @import("lsp.zig");
const chrome = maru.chrome;
const trust = maru.session.editor.lsp.trust;

pub const State = struct {
    /// 연 순간의 표 사본 — 표는 다른 창의 답으로 바뀌므로 행이 그 밑에서 움직이지 않게 찍어 둔다.
    items: std.ArrayList(Item) = .empty,
    shown: std.ArrayList(usize) = .empty,
    scroll: chrome.ui.scroll_area.State = .{},
    followed: ?usize = null,

    pub const Item = struct { volume: u64, path: []u8, decision: trust.Decision };

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.items.items) |it| allocator.free(it.path);
        self.items.deinit(allocator);
        self.shown.deinit(allocator);
        self.* = .{};
    }
};

pub fn open(self: *AppSession) void {
    self.dismissMessageOverlays();
    lsp_client.loadTrustForList(self);
    const state = &self.editor_trust_list;
    state.deinit(self.allocator);
    var it = trust_store.decided();
    while (it.next()) |e| {
        const path = self.allocator.dupe(u8, e.key.path) catch break;
        state.items.append(self.allocator, .{ .volume = e.key.volume, .path = path, .decision = e.decision }) catch {
            self.allocator.free(path);
            break;
        };
    }
    self.chrome_host.trust_picker.show();
    recompute(self);
    self.metal_dirty = true;
}

pub fn closed(self: *AppSession) void {
    self.chrome_host.trust_picker.hide();
    self.editor_trust_list.deinit(self.allocator);
    self.metal_dirty = true;
}

pub fn recompute(self: *AppSession) void {
    self.chrome_host.trust_picker.selected = 0;
    self.editor_trust_list.scroll = .{};
    self.editor_trust_list.followed = null;
    refresh(self);
}

fn refresh(self: *AppSession) void {
    const state = &self.editor_trust_list;
    const picker = &self.chrome_host.trust_picker;
    state.shown.clearRetainingCapacity();
    state.shown.ensureTotalCapacity(self.allocator, state.items.items.len) catch {
        picker.setResultCount(0);
        self.metal_dirty = true;
        return;
    };
    // 조합 중 한글을 붙여 거른다. 메모리가 모자라면 입력 그대로 거른다(전부 보이는 것보다 낫다).
    const composed = maru.grapheme.composeHangul(self.allocator, picker.input.query.items) catch null;
    defer if (composed) |q| self.allocator.free(q);
    const q = composed orelse picker.input.query.items;
    const home = std.mem.span(std.c.getenv("HOME") orelse "");
    for (state.items.items, 0..) |it, i| {
        // 보이는 그대로(`~/…` — `rows`)로도 거른다 — 사용자는 화면의 경로를 친다.
        var shown_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const shown = app_session_mod.homeTilde(it.path, home, &shown_buf);
        if (q.len == 0 or std.ascii.indexOfIgnoreCase(it.path, q) != null or std.ascii.indexOfIgnoreCase(shown, q) != null) state.shown.appendAssumeCapacity(i);
    }
    picker.setResultCount(state.shown.items.len);
    picker.prompt = maru.i18n.t(if (state.items.items.len == 0) .lsp_trust_list_empty else .lsp_trust_list_prompt);
    self.metal_dirty = true;
}

/// 고른 저장소의 관리 상자를 띄운다(목록은 닫는다 — 상자는 하나뿐이다).
pub fn accept(self: *AppSession) void {
    const state = &self.editor_trust_list;
    const selected = self.chrome_host.trust_picker.selected;
    if (selected >= state.shown.items.len) return;
    const it = state.items.items[state.shown.items[selected]];
    // 상자를 띄우면 목록이 닫히며 사본이 풀린다 — 키를 먼저 떠 둔다.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (it.path.len > path_buf.len) return;
    @memcpy(path_buf[0..it.path.len], it.path);
    const key: trust.Key = .{ .volume = it.volume, .path = path_buf[0..it.path.len] };
    closed(self);
    lsp_client.manageListed(self, key); // 사본의 결정이 아니라 지금 표의 결정으로
}

/// 렌더와 같은 창 시작·셀 크기로 행을 고른다. 바깥 클릭은 닫는다.
pub fn click(self: *AppSession, x: f64, y: f64) void {
    const layout = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return;
    const total = self.editor_trust_list.shown.items.len;
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
    const start = @min(self.editor_trust_list.scroll.offset_y_px / layout.ch, total -| count);
    self.chrome_host.trust_picker.selected = start + row - 1;
    accept(self);
}

/// 행 — 저장소 경로(`~` 로 줄이고 넘치면 앞을 줄인다)와 결정(허용/거부).
pub fn rows(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.palette.Row {
    const state = &self.editor_trust_list;
    const total = state.shown.items.len;
    const count = @min(total, chrome.components.palette.max_visible);
    const start = @min(state.scroll.offset_y_px / @max(self.cell_height_px, 1), total -| count);
    const result = try arena.alloc(chrome.components.palette.Row, count);
    const layout = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return &.{};
    for (result, 0..) |*row, i| {
        const it = state.items.items[state.shown.items[start + i]];
        const detail = maru.i18n.t(if (it.decision == .allow) .lsp_trust_list_allowed else .lsp_trust_list_denied);
        const shown_buf = try arena.alloc(u8, it.path.len + 1);
        const shown = app_session_mod.homeTilde(it.path, std.mem.span(std.c.getenv("HOME") orelse ""), shown_buf);
        const available = layout.panel_cols -| (chrome.components.overlay_input.displayCols(detail) + 5);
        const title = chrome.components.overlay_input.tailWindow(shown, available -| 1);
        row.* = .{
            .title = if (title.truncated) try std.fmt.allocPrint(arena, "…{s}", .{title.text}) else try arena.dupe(u8, title.text),
            .binding = detail,
            .selected = start + i == self.chrome_host.trust_picker.selected,
        };
    }
    return result;
}
