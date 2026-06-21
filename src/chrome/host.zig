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
const confirm = @import("components/confirm.zig");
const find = @import("components/find.zig");
const palette = @import("components/palette.zig");
const context_menu = @import("components/context_menu.zig");
const settings = @import("components/settings.zig");

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
    confirm_accept, // 확인 모달 Enter/Y — platform이 보류한 닫기(pending_close)를 실행
    confirm_cancel, // 확인 모달 Esc/N — platform이 보류한 닫기를 버린다
    settings_close, // 세팅 모달 Esc/바깥클릭 — platform이 hide
    settings_toggle, // 세팅 행 Space/Enter/toggle 클릭 — platform이 rows[selected](bool) flip + 적용
    settings_slider_set, // 세팅 슬라이더 드래그/클릭 — platform이 settings.pending_ratio→값 매핑 + 적용
    settings_adjust_left, // 세팅 행 ← — platform이 rows[selected](slider) 한 스텝 감소(toggle이면 무시)
    settings_adjust_right, // 세팅 행 → — platform이 한 스텝 증가
    settings_selection_changed, // 세팅 행 ↑↓/행 클릭 — platform이 재렌더(부수효과 없음)
};

pub const ChromeHost = struct {
    interaction: ChromeState = .{},
    notice: notice.State = .{},
    confirm: confirm.State = .{},
    find: find.State = .{},
    palette: palette.State = .{},
    context_menu: context_menu.State = .{},
    settings: settings.State = .{},

    /// 컴포넌트 State 중 heap을 든 것(find/palette의 query·preedit)을 해제한다. AppSession.deinit가 부른다.
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
            try confirm.view(&self.confirm, p, tk, arena, &ops);
            if (ops.items.len > 0) try out.append(arena, .{ .layer = confirm.layer, .ops = ops.items });
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

    /// settings도 행(FieldRow)을 platform이 config 스키마에서 빌드해 주입해야 그릴 수 있다(palette/context_menu와
    /// 동형). 닫힘이면 무동작(빈 out).
    pub fn collectSettingsDraws(
        self: *ChromeHost,
        fields: []const settings.FieldRow,
        p: props.ChromeProps,
        tk: *const tokens.Tokens,
        arena: std.mem.Allocator,
        out: *std.ArrayList(draw.ChromeDraw),
    ) !void {
        var ops: std.ArrayList(draw.Op) = .empty;
        try settings.view(&self.settings, fields, p, tk, arena, &ops);
        if (ops.items.len > 0) try out.append(arena, .{ .layer = settings.layer, .ops = ops.items });
    }

    /// 입력을 모달 우선으로 라우팅한다. `.key`는 활성 컴포넌트의 키 handle로, `.pointer`는 handlePointer로
    /// 가른다(CS-4-0 — docs/config-gui.md §3). 열린 컴포넌트가 있으면 소비하고 의도(HostAction)를 돌려준다
    /// (session이 디스패치). 열린 게 없으면 null(소비 안 함 — 뒤 터미널로 흘림). 우선순위: Confirm > Notice >
    /// ContextMenu > Find > Palette(배타적이라 동시 열림은 라우팅이 막는다). find/palette는 query 변형에
    /// allocator가 필요해 받는다.
    pub fn handleInput(self: *ChromeHost, allocator: std.mem.Allocator, ev: input.InputEvent) ?HostAction {
        switch (ev) {
            .key => |k| {
                if (self.confirm.open) {
                    // 확인 모달은 파괴적 동작(닫기) 게이트라 최우선. Enter/Y=accept·Esc/N=cancel, 그 외는 소비(.none).
                    return switch (confirm.handle(k, &self.confirm) orelse return .none) {
                        .confirmed => .confirm_accept,
                        .cancelled => .confirm_cancel,
                    };
                }
                if (self.notice.open) {
                    _ = notice.handle(k, &self.notice); // Enter/Esc면 닫음. session 부수효과 없음.
                    return .none;
                }
                if (self.context_menu.open) {
                    return switch (context_menu.handle(k, &self.context_menu)) {
                        .accept => .context_menu_accept,
                        .close => .context_menu_close,
                        .selection_changed => .context_menu_selection_changed,
                    };
                }
                if (self.find.open) {
                    return switch (find.handle(allocator, k, &self.find)) {
                        .close => .find_close,
                        .navigated => .find_navigated,
                        .query_changed => .find_query_changed,
                    };
                }
                if (self.palette.open) {
                    return switch (palette.handle(allocator, k, &self.palette)) {
                        .close => .palette_close,
                        .accept => .palette_accept,
                        .query_changed => .palette_query_changed,
                        .selection_changed => .palette_selection_changed,
                    };
                }
                if (self.settings.open) {
                    return switch (settings.handle(k, &self.settings)) {
                        .close => .settings_close,
                        .toggle => .settings_toggle,
                        .adjust_left => .settings_adjust_left,
                        .adjust_right => .settings_adjust_right,
                        .slider_set => .none, // 키 경로엔 안 옴(슬라이더 ratio 설정은 포인터 드래그 전용) — exhaustiveness
                        .selection_changed => .settings_selection_changed,
                        .consumed => .none,
                    };
                }
                return null;
            },
            .pointer => |p| return self.handlePointer(p),
        }
    }

    /// 포인터(마우스/트랙패드)를 활성 모달에 라우팅한다(CS-4-0 — docs/config-gui.md §3의 선결 plumbing).
    /// 슬라이더 드래그·토글/색 클릭 같은 모달 위젯이 쓸 진입점이다. 아직 포인터를 소비하는 위젯은 없으므로
    /// (위젯 컴포넌트는 CS-4-1+), 모달이 하나라도 열려 있으면 **소비만** 한다(`.none`) — 모달 위에서의 클릭이
    /// 뒤 터미널/divider/tabbar 마우스 처리로 새지 않게(키가 모달에서 `.none`으로 소비되는 것과 같은 규율).
    /// 열린 모달이 없으면 null(소비 안 함 — platform이 기존 터미널/chrome 마우스 경로로 흘려보낸다).
    /// 위젯별 hit-test·드래그(divider `dragRatio` 패턴)는 위젯 컴포넌트가 들어오는 후속 PR에서 추가한다.
    pub fn handlePointer(self: *ChromeHost, ev: input.PointerEvent) ?HostAction {
        _ = ev; // 위젯이 좌표/버튼을 소비하는 건 CS-4-1+; 지금은 모달 열림 여부만으로 소비/통과를 가른다.
        if (self.confirm.open or self.notice.open or self.context_menu.open or self.find.open or self.palette.open) {
            return .none;
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

test "host: Confirm 라우팅 — Enter=confirm_accept·Esc=confirm_cancel·다른 키=none, collectDraws가 modal 1개" {
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

    // 닫힘 → 라우팅 안 가로챔, 빈 출력.
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }) == null);
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    host.confirm.show("running: vim — 닫을까요?", .{ .confirm = "닫기", .cancel = "취소" });
    out.clearRetainingCapacity();
    try host.collectDraws(p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(draw.Layer.modal, out.items[0].layer);

    // 다른 글자는 소비(.none)하되 안 닫힘.
    try std.testing.expectEqual(HostAction.none, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .char, .codepoint = 'a' } }).?);
    try std.testing.expect(host.confirm.open);
    // Esc → cancel + 닫힘.
    try std.testing.expectEqual(HostAction.confirm_cancel, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .escape } }).?);
    try std.testing.expect(!host.confirm.open);
    // Enter → accept + 닫힘.
    host.confirm.show("x", .{});
    try std.testing.expectEqual(HostAction.confirm_accept, host.handleInput(std.testing.allocator, .{ .key = .{ .key = .enter } }).?);
    try std.testing.expect(!host.confirm.open);
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

test "host: handlePointer — 모달 열리면 소비(.none), 닫히면 null(통과)" {
    var host = ChromeHost{};
    defer host.deinit(std.testing.allocator);
    const down = input.PointerEvent{ .phase = .down, .x_px = 10, .y_px = 10 };

    // 열린 모달 없음 → null(소비 안 함, 터미널/chrome 마우스 경로로 통과). handleInput(.pointer)도 같은 결과.
    try std.testing.expect(host.handlePointer(down) == null);
    try std.testing.expect(host.handleInput(std.testing.allocator, .{ .pointer = down }) == null);

    // 모달 열림 → 소비(.none) — 클릭이 뒤로 안 샌다. 포인터는 모달을 닫지 않는다(위젯 소비는 CS-4-1+).
    host.notice.show("x");
    try std.testing.expectEqual(HostAction.none, host.handlePointer(down).?);
    const up = input.PointerEvent{ .phase = .up, .x_px = 10, .y_px = 10 };
    try std.testing.expectEqual(HostAction.none, host.handleInput(std.testing.allocator, .{ .pointer = up }).?);
    try std.testing.expect(host.notice.open);
}
