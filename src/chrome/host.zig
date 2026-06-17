//! ChromeHost — chrome 드라이버. 컴포넌트 State들 + ChromeState(상호작용) 소유, 매 프레임 각 컴포넌트
//! view를 수집(`[]ChromeDraw`)하고 입력을 라우팅한다. **session과 chrome의 유일 접점**: session이 props를
//! 빌드해 넘기고, host가 낸 ChromeDraw를 platform 백엔드가 lower한다(host는 백엔드·NativeMetalCell을 모름).
//! 입력은 handle이 의도(HostAction)를 내고 host가 그대로 돌려주면 session(platform)이 부수효과를 디스패치한다
//! — chrome은 session 메서드를 직접 안 부른다(경계). C0=Notice, C1=Find. C2~C3에서 palette/tabbar/sidebar 추가.
//! 단일 출처: docs/chrome-strategy.md §5.6, docs/layering-and-portability.md §2.

const std = @import("std");
const draw = @import("draw.zig");
const tokens = @import("tokens.zig");
const props = @import("props.zig");
const input = @import("input.zig");
const ChromeState = @import("state.zig").ChromeState;
const notice = @import("components/notice.zig");
const find = @import("components/find.zig");
const palette = @import("components/palette.zig");
const context_menu = @import("components/context_menu.zig");

/// 컴포넌트 handle이 낸 의도를 session이 디스패치할 형태로 host가 정규화한 것. chrome은 config.Action·session을
/// 모르므로(중립) 부수효과를 직접 안 하고 이 intent만 돌려준다 — platform이 받아 재검색·스크롤·닫기를 실행한다.
/// `none`=소비했지만 session이 할 일 없음(notice dismiss 등). null(handleInput 반환)=모달 없음(소비 안 함).
pub const HostAction = union(enum) {
    none,
    find_close,
    find_navigated,
    find_query_changed,
    palette_close,
    palette_accept,
    palette_query_changed,
    palette_selection_changed,
    context_menu_accept, // 우클릭 메뉴 항목 선택 — platform이 selected→대상 액션(rename) 해석·실행
    context_menu_close,
    context_menu_selection_changed,
};

pub const ChromeHost = struct {
    interaction: ChromeState = .{},
    notice: notice.State = .{},
    find: find.State = .{},
    palette: palette.State = .{},
    context_menu: context_menu.State = .{},

    /// 컴포넌트 State 중 heap을 든 것(find/palette의 query·preedit)을 해제한다. DevSession.deinit가 부른다.
    pub fn deinit(self: *ChromeHost, allocator: std.mem.Allocator) void {
        self.find.deinit(allocator);
        self.palette.deinit(allocator);
    }

    /// 각 컴포넌트 view를 호출해 (layer, ops) = ChromeDraw를 arena에 빌드한다. 빈(닫힌) 컴포넌트는 건너뛴다.
    /// 오버레이 컴포넌트(notice/find)는 라우팅상 배타적이라 현재 최대 1개만 ops를 낸다(platform lowering이 단일
    /// 오버레이 frame을 가정). out·ops 슬라이스는 호출자가 준 frame arena가 소유한다(lower 뒤 arena 리셋).
    pub fn collectDraws(
        self: *ChromeHost,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        {
            var ops: std.ArrayList(draw.Op) = .empty;
            try notice.view(&self.notice, p, tk, arena, &ops);
            if (ops.items.len > 0) try out.append(arena, .{ .layer = notice.layer, .ops = ops.items });
        }
        {
            var ops: std.ArrayList(draw.Op) = .empty;
            try find.view(&self.find, p, tk, arena, &ops);
            if (ops.items.len > 0) try out.append(arena, .{ .layer = find.layer, .ops = ops.items });
        }
    }

    /// palette는 필터된 행(Row: title·binding·selected)을 host가 주입해야 그릴 수 있다 — generic collectDraws는 rows가
    /// 없어 못 부른다. platform(catalog 소유)이 rows를 빌드해 이걸 부른다. palette 닫힘이면 무동작(빈 out). 다른 오버레이와
    /// 배타적이라 platform이 palette.open일 때만 부른다(단일 오버레이 frame 가정 유지).
    pub fn collectPaletteDraws(
        self: *ChromeHost,
        rows: []const palette.Row,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try palette.view(&self.palette, rows, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = palette.layer, .ops = ops.items });
    }

    /// context_menu도 항목 라벨을 platform이 주입해야 그릴 수 있다(palette와 동형 — generic collectDraws는 항목이
    /// 없어 못 부른다). platform(대상별 항목 소유)이 items를 빌드해 이걸 부른다. 닫힘이면 무동작(빈 out).
    pub fn collectContextMenuDraws(
        self: *ChromeHost,
        items: []const []const u8,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try context_menu.view(&self.context_menu, items, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = context_menu.layer, .ops = ops.items });
    }

    /// 입력을 모달 우선으로 라우팅한다. 열린 컴포넌트가 있으면 소비하고 의도(HostAction)를 돌려준다(session이
    /// 디스패치). 열린 게 없으면 null(소비 안 함 — 뒤 터미널로 흘림). 우선순위: Notice > Find(배타적이라 동시
    /// 열림은 라우팅이 막는다). find는 query 변형에 allocator가 필요해 받는다(notice는 안 씀).
    pub fn handleInput(self: *ChromeHost, allocator: std.mem.Allocator, ev: input.InputEvent) ?HostAction {
        if (self.notice.open) {
            _ = notice.handle(ev, &self.notice); // Enter/Esc면 닫음. session 부수효과 없음.
            return .none;
        }
        if (self.context_menu.open) {
            return switch (context_menu.handle(ev, &self.context_menu)) {
                .accept => .context_menu_accept,
                .close => .context_menu_close,
                .selection_changed => .context_menu_selection_changed,
            };
        }
        if (self.find.open) {
            return switch (find.handle(allocator, ev, &self.find)) {
                .close => .find_close,
                .navigated => .find_navigated,
                .query_changed => .find_query_changed,
            };
        }
        if (self.palette.open) {
            return switch (palette.handle(allocator, ev, &self.palette)) {
                .close => .palette_close,
                .accept => .palette_accept,
                .query_changed => .palette_query_changed,
                .selection_changed => .palette_selection_changed,
            };
        }
        return null;
    }
};

test "host: Notice 열리면 collectDraws가 modal 1개, handleInput 소비/닫기" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    var out: std.ArrayList(draw.ChromeDraw) = .empty;

    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘 → 빈 출력
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }) == null); // 닫힘 → 소비 안 함

    host.notice.show("corrupt");
    out.clearRetainingCapacity();
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(draw.Layer.modal, out.items[0].layer);

    try std.testing.expectEqual(HostAction.none, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?); // 열림 → 소비(.none)
    try std.testing.expect(!host.notice.open); // Esc로 닫힘
}

test "host: Find 라우팅 — 글자=query_changed·Enter=navigated·Esc=close, collectDraws가 오버레이 1개" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    host.find.show();

    // 글자 → query_changed + 검색어 누적.
    try std.testing.expectEqual(HostAction.find_query_changed, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'a' } }).?);
    try std.testing.expectEqualStrings("a", host.find.input.query.items);
    // 매치 수 동기화 후 Enter → navigated.
    host.find.setMatchCount(2);
    try std.testing.expectEqual(HostAction.find_navigated, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }).?);
    try std.testing.expectEqual(@as(usize, 1), host.find.current);

    // collectDraws가 find 오버레이 1개를 낸다.
    var out: std.ArrayList(draw.ChromeDraw) = .empty;
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);

    // Esc → close.
    try std.testing.expectEqual(HostAction.find_close, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?);
    try std.testing.expect(!host.find.open);
}

test "host: Palette 라우팅 — 글자=query_changed·Enter=accept·↑↓=selection_changed·Esc=close, collectPaletteDraws가 오버레이 1개" {
    const Rgb = @import("../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    host.palette.show();
    host.palette.setResultCount(3);

    // 글자 → query_changed + 검색어 누적.
    try std.testing.expectEqual(HostAction.palette_query_changed, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'a' } }).?);
    try std.testing.expectEqualStrings("a", host.palette.input.query.items);
    // ↓ → selection_changed + 이동.
    try std.testing.expectEqual(HostAction.palette_selection_changed, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .down } }).?);
    try std.testing.expectEqual(@as(usize, 1), host.palette.selected);
    // Enter → accept(실행은 platform).
    try std.testing.expectEqual(HostAction.palette_accept, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }).?);

    // collectPaletteDraws가 palette 오버레이 1개를 낸다(행 1개 주입).
    var out: std.ArrayList(draw.ChromeDraw) = .empty;
    const rows = [_]palette.Row{.{ .title = "New Terminal", .binding = "T", .selected = true }};
    try host.collectPaletteDraws(&rows, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);

    // Esc → close.
    try std.testing.expectEqual(HostAction.palette_close, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?);
    try std.testing.expect(!host.palette.open);
}
