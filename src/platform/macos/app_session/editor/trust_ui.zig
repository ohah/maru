//! 언어 서버 목록 상자 — 두 가지를 같은 피커 컴포넌트·같은 행 모양으로 보인다(복구 목록 `recovery.zig` 와 같은 모양):
//! - 저장소 신뢰 결정 목록(계획 WT4 — 팔레트 「Language Server: Repository Trust…」). 앱 전역 신뢰 표(`trust_store`)의 결정을 보이고,
//!   고르면 신뢰 관리 확인 상자(`lsp.manageListed` — 철회·잊기)로 간다. 신뢰를 **주는** 길은 여기 없다(신뢰 시트의 답뿐 — LSPB23).
//! - 서버에 넘기는 환경 변수 **이름** 목록(계획 WT5b-1 — 팔레트 「Language Server: Show Environment Variable Names」). 값은 보이지
//!   않는다. 사용자 제외 목록(`lsp.environment-exclude`)에 걸린 이름은 「제외됨」. 읽기 전용이라 고르면 닫힌다.
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const trust_store = @import("trust_store.zig");
const lsp_client = @import("lsp.zig");
const tool_env = @import("../../tool_env.zig");
const chrome = maru.chrome;
const trust = maru.session.editor.lsp.trust;

pub const Mode = enum { trust, env_names };

pub const State = struct {
    mode: Mode = .trust,
    /// 연 순간의 사본 — 신뢰 표는 다른 창의 답으로, 환경은 다시 읽기로 바뀌므로 행이 그 밑에서 움직이지 않게 찍어 둔다.
    items: std.ArrayList(Item) = .empty,
    shown: std.ArrayList(usize) = .empty,
    scroll: chrome.ui.scroll_area.State = .{},
    followed: ?usize = null,
    /// 환경 목록을 열 때 셸 환경을 아직 안 담았다(「읽은 뒤에 보입니다」).
    env_pending: bool = false,

    /// `text` 는 저장소의 실제 경로(신뢰) 또는 변수 이름(환경)이다. `dest` 는 원격 키의 목적지(로컬·환경이면 빈 조각 — 계획 WT7a).
    pub const Item = struct { text: []u8, volume: u64 = 0, dest: []u8 = &.{}, decision: trust.Decision = .deny, excluded: bool = false };

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.items.items) |it| {
            allocator.free(it.text);
            allocator.free(it.dest);
        }
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
        const dest = self.allocator.dupe(u8, e.key.dest) catch {
            self.allocator.free(path);
            break;
        };
        state.items.append(self.allocator, .{ .text = path, .volume = e.key.volume, .dest = dest, .decision = e.decision }) catch {
            self.allocator.free(path);
            self.allocator.free(dest);
            break;
        };
    }
    self.chrome_host.trust_picker.show();
    recompute(self);
    self.metal_dirty = true;
}

/// 팔레트 「Language Server: Show Environment Variable Names」(계획 WT5b-1) — 담아 둔 환경의 이름들(시스템 위생을 지난 것)과 제외 여부.
pub fn openEnvNames(self: *AppSession) void {
    if (!self.loaded_config.config.lsp.enabled) return self.showNoticeKey(.lsp_info_disabled);
    self.dismissMessageOverlays();
    tool_env.initExcluded(self.loaded_config.config.lsp.environment_exclude); // 아직 아무도 정하지 않았으면 이 창의 설정으로
    // 아직 아무도 안 읽었으면 읽기를 시작한다 — 서버가 필요한 문서를 열지 않았어도(사용자의 명시 행동 — 다시 읽기 명령과 같다). 셸을
    // 읽는 동안은 「읽는 중 — 다 읽은 뒤 다시 여세요」(스위치를 껐으면 앱 환경으로 바로 선다).
    tool_env.tick(self.loaded_config.config.lsp.shell_environment);
    const state = &self.editor_trust_list;
    state.deinit(self.allocator);
    state.mode = .env_names;
    if (tool_env.names()) |names| {
        var it = names;
        while (it.next()) |n| {
            const name = self.allocator.dupe(u8, n.name) catch break;
            state.items.append(self.allocator, .{ .text = name, .excluded = n.excluded }) catch {
                self.allocator.free(name);
                break;
            };
        }
    } else state.env_pending = true;
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
        if (q.len == 0 or std.ascii.indexOfIgnoreCase(it.text, q) != null) {
            state.shown.appendAssumeCapacity(i);
            continue;
        }
        if (state.mode != .trust) continue;
        // 보이는 그대로(`~/…`·원격은 `목적지:경로` — `rows`)로도 거른다 — 사용자는 화면의 이름을 친다.
        var shown_buf: [std.fs.max_path_bytes + trust.max_dest_bytes + 1]u8 = undefined;
        const shown = if (it.dest.len > 0)
            lsp_client.trustKeyLabel(.{ .volume = it.volume, .path = it.text, .dest = it.dest }, &shown_buf)
        else
            app_session_mod.homeTilde(it.text, home, &shown_buf);
        if (std.ascii.indexOfIgnoreCase(shown, q) != null) state.shown.appendAssumeCapacity(i);
    }
    picker.setResultCount(state.shown.items.len);
    const empty = state.items.items.len == 0;
    picker.prompt = maru.i18n.t(switch (state.mode) {
        .trust => if (empty) .lsp_trust_list_empty else .lsp_trust_list_prompt,
        .env_names => if (state.env_pending) .lsp_env_list_pending else if (empty) .lsp_env_list_empty else .lsp_env_list_prompt,
    });
    self.metal_dirty = true;
}

/// 고른 저장소의 관리 상자를 띄운다(목록은 닫는다 — 상자는 하나뿐이다). 환경 목록은 읽기 전용이라 닫기만 한다.
pub fn accept(self: *AppSession) void {
    const state = &self.editor_trust_list;
    if (state.mode == .env_names) return closed(self);
    const selected = self.chrome_host.trust_picker.selected;
    if (selected >= state.shown.items.len) return;
    const it = state.items.items[state.shown.items[selected]];
    // 상자를 띄우면 목록이 닫히며 사본이 풀린다 — 키를 먼저 떠 둔다.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buf: [trust.max_dest_bytes]u8 = undefined;
    if (it.text.len > path_buf.len or it.dest.len > dest_buf.len) return;
    @memcpy(path_buf[0..it.text.len], it.text);
    @memcpy(dest_buf[0..it.dest.len], it.dest);
    const key: trust.Key = .{ .volume = it.volume, .path = path_buf[0..it.text.len], .dest = dest_buf[0..it.dest.len] };
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

/// 행 — 저장소 경로(`~` 로 줄이고 넘치면 앞을 줄인다)와 결정(허용/거부), 또는 변수 이름과 「제외됨」.
pub fn rows(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.palette.Row {
    const state = &self.editor_trust_list;
    const total = state.shown.items.len;
    const count = @min(total, chrome.components.palette.max_visible);
    const start = @min(state.scroll.offset_y_px / @max(self.cell_height_px, 1), total -| count);
    const result = try arena.alloc(chrome.components.palette.Row, count);
    const layout = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return &.{};
    for (result, 0..) |*row, i| {
        const it = state.items.items[state.shown.items[start + i]];
        const detail: []const u8 = switch (state.mode) {
            .trust => maru.i18n.t(if (it.decision == .allow) .lsp_trust_list_allowed else .lsp_trust_list_denied),
            .env_names => if (it.excluded) maru.i18n.t(.lsp_env_list_excluded) else "",
        };
        const shown: []const u8 = switch (state.mode) {
            .trust => if (it.dest.len > 0)
                lsp_client.trustKeyLabel(.{ .volume = it.volume, .path = it.text, .dest = it.dest }, try arena.alloc(u8, it.dest.len + it.text.len + 1))
            else
                app_session_mod.homeTilde(it.text, std.mem.span(std.c.getenv("HOME") orelse ""), try arena.alloc(u8, it.text.len + 1)),
            .env_names => it.text,
        };
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
