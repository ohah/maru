//! Dropdown — enum(선택 목록) 값 위젯. 두 부분으로 이뤄진다:
//!   ① **축소 표시**(State 없는 순수 `view`/`hitTest`) — 현재 변형을 텍스트 + ▾로 보여준다.
//!   ② **열리는 팝업 목록**(`State` + `viewPopup`/`handle`/`itemAt`) — Enter/클릭으로 열어 전체 변형을 목록으로
//!      깔고 ↑↓(wrap)로 고른 뒤 Enter로 선택한다. context_menu와 같은 modal 오버레이 규율(항목 라벨·선택 적용은
//!      platform이 주입/실행, 컴포넌트는 open·selected·anchor만 안다). 팝업은 축소 control 아래에 뜨고 화면 안으로 clamp.
//! CS-4-1c 첫 컷은 사이클러였으나(←→ 순환), 사용자 요청으로 **실제 드롭다운 목록**으로 승격(config-gui §6 후속 실현).
//! 단일 출처: docs/config-gui.md §2·§6, docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW) 단일 출처 — 팝업 항목 폭 측정에 재사용

const chevron = " \u{25BE}"; // " ▾"(BLACK DOWN-POINTING SMALL TRIANGLE) — dropdown 표식

/// 현재 변형 텍스트 + ▾를 control rect 좌상단에 그린다(Op.text). 색=surface_fg. 빈 current면 ▾만(방어). 순수:
/// rect·current·tokens만 읽는다. runs/op은 호출자(셸) frame arena 소유. 사이클링은 platform(schema.cycleEnum).
pub fn view(
    rect: draw.Rect,
    current: []const u8,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (rect.w == 0 or rect.h == 0) return;
    // 표시 토큰의 '_'→'-'(config 규약 — current는 정적 @tagName이라 여기 frame arena에서 변환). 그다음 " ▾" 붙임.
    const disp = try arena.dupe(u8, current);
    for (disp) |*c| {
        if (c.* == '_') c.* = '-';
    }
    const label = try std.fmt.allocPrint(arena, "{s}{s}", .{ disp, chevron });
    const runs = try arena.alloc(draw.Run, 1);
    runs[0] = .{ .text = label };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x, .y = rect.y }, .runs = runs, .role = .surface_fg } });
}

/// (x,y)가 dropdown control rect 안인가 — 클릭(사이클) hit-test. 셀 0/비유한 가드.
pub fn hitTest(rect: draw.Rect, x_px: f64, y_px: f64) bool {
    if (rect.w == 0 or rect.h == 0 or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and
        y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

// ── 열리는 팝업 목록 ─────────────────────────────────────────────────────────────
// context_menu와 같은 최상위 modal 레이어(열려 있으면 키를 잡는다). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = draw.Layer.modal;

/// 팝업 순수 UI 상태 — open + selected(강조 항목) + item_count(키 nav clamp/wrap용). **기하(앵커 rect)는 저장하지
/// 않는다** — 팝업은 '선택된 행의 축소 control 아래'에 뜨므로, 셸(settings.view/handlePointer)이 렌더/hit-test 시점에
/// 그 control rect를 anchor로 넘긴다(플랫폼 rect 배선 불요). 항목 라벨·선택 적용 대상은 platform이 든다(chrome 중립).
/// heap 없음. settings.State가 한 개 품어 enum/font 행 활성 시 연다(HSV picker 모드 선례).
pub const State = struct {
    open: bool = false,
    selected: usize = 0,
    /// 열 때의 현재 인덱스 — Esc/바깥 클릭 취소 시 platform이 이 변형으로 **복원**한다(↑↓ 라이브 프리뷰를 되돌린다).
    original: usize = 0,
    item_count: usize = 0,

    /// 항목 수·현재 변형 인덱스로 연다 — 선택은 현재값에서 시작(사용자가 지금 값을 바로 본다). original도 현재값으로.
    pub fn show(self: *State, item_count: usize, current: usize) void {
        self.item_count = item_count;
        self.selected = if (item_count == 0) 0 else @min(current, item_count - 1);
        self.original = self.selected;
        self.open = true;
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }

    /// 선택을 delta만큼 **wrap** 이동(드롭다운 관례 — 마지막에서 ↓면 처음으로). item_count 0이면 무동작.
    pub fn moveSelection(self: *State, delta: i64) void {
        if (self.item_count == 0) return;
        const n: i64 = @intCast(self.item_count);
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(@mod(cur + delta, n)); // @mod: 결과는 [0, n)(음수 delta도 안전)
    }
};

/// handle이 돌려주는 intent. host가 받아 platform에 디스패치(accept=selected 변형 적용, close=닫기).
pub const Action = enum {
    accept, // Enter/항목 클릭 — selected 변형을 적용(platform이 selected→enum set)
    close, // Esc — 닫기(값 안 바꿈)
    selection_changed, // ↑↓ — selected 이동(렌더 갱신)
    consumed, // ←→·글자 등 — 무시(팝업 유지, 뒤로 안 샘). 모달이라 모든 키를 잡는다.
};

/// 팝업 키 처리(열려 있을 때만 host가 호출). **전략(모달 캡처)**: 열려 있으면 모든 키를 이 팝업이 잡아 뒤(폼·터미널)로
/// 흘리지 않는다. ↑↓=이동(wrap), Enter=accept(선택 확정), **Esc만 close**(취소). ←→·글자 등은 **consumed**(팝업 유지)
/// — context_menu가 잡키에 닫는 것과 달리, ←→가 섹션 전환으로 새거나 실수로 dismiss되지 않게 한다. 마우스(항목 클릭·
/// 밖 클릭)는 platform이 itemAt으로 따로 처리한다. (글자→변형 type-ahead 점프는 후속 여지.)
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) Action {
    switch (k.key) {
        .up => {
            state.moveSelection(-1);
            return .selection_changed;
        },
        .down => {
            state.moveSelection(1);
            return .selection_changed;
        },
        .enter => return .accept,
        .escape => {
            state.hide();
            return .close;
        },
        else => return .consumed, // ←→·글자 등은 무시(팝업 유지 — 섹션 전환 누수·실수 dismiss 방지)
    }
}

/// 팝업 박스 rect(px) — 앵커(선택 행의 축소 control) **바로 아래**(anchor.y+anchor.h)에서 시작하되 화면(backing)
/// 우/하단을 넘으면 당겨 안에 들게 clamp한다. 폭 = max(최대 항목 표시폭+좌우 1칸, 앵커 control 폭). **viewPopup·itemAt
/// 단일 출처**라 "보이는 항목 == 클릭되는 항목". 항목 0이거나 cell 0이면 null.
fn popupRect(anchor: draw.Rect, items: []const []const u8, p: props.ChromeProps) ?draw.Rect {
    if (items.len == 0) return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    var max_cols: u32 = 0;
    for (items) |it| {
        const w = overlay_input.displayCols(it);
        if (w > max_cols) max_cols = w;
    }
    const box_w = @max((max_cols + 2) * cw, anchor.w); // 최소 앵커 control 폭
    const box_h = @as(u32, @intCast(items.len)) * ch;
    var x = anchor.x;
    var y = anchor.y + @as(i32, @intCast(anchor.h)); // control 아래로 드롭
    const workspace = props.workspaceRect(m);
    const bw_px: i32 = @intCast(workspace.x + workspace.w);
    const bh_px: i32 = @intCast(workspace.y + workspace.h);
    if (x + @as(i32, @intCast(box_w)) > bw_px) x = bw_px - @as(i32, @intCast(box_w)); // 우단 넘으면 왼쪽으로
    if (y + @as(i32, @intCast(box_h)) > bh_px) y = bh_px - @as(i32, @intCast(box_h)); // 하단 넘으면 위로(당겨 fit)
    const sidebar: i32 = @intCast(workspace.x);
    if (x < sidebar) x = sidebar; // 사이드바 chrome 위로 안 겹치게
    if (y < @as(i32, @intCast(workspace.y))) y = @intCast(workspace.y);
    return .{ .x = x, .y = y, .w = box_w, .h = box_h };
}

/// 마우스 px가 팝업 박스 안의 어느 항목 행인지([0, item_count)). 박스 밖이면 null(호출자가 close). viewPopup과 같은
/// popupRect(같은 anchor)를 써 "보이는 == 클릭되는". 안 열렸거나 비유한 좌표는 null.
pub fn itemAt(state: *const State, anchor: draw.Rect, items: []const []const u8, p: props.ChromeProps, x_px: f64, y_px: f64) ?usize {
    if (!state.open or !std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const rect = popupRect(anchor, items, p) orelse return null;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    if (x_px < x0 or x_px >= x0 + @as(f64, @floatFromInt(rect.w))) return null;
    if (y_px < y0 or y_px >= y0 + @as(f64, @floatFromInt(rect.h))) return null;
    const ch: f64 = @floatFromInt(@max(p.metrics.cell_height_px, 1));
    const row: usize = @intFromFloat((y_px - y0) / ch);
    return @min(row, items.len - 1);
}

/// 팝업 목록(행별 **불투명 배경** + 항목 텍스트, selected 행 강조)을 `out`에 append한다. 안 열렸거나 항목 0이면
/// 무동작. 순수: state·items·props·tokens만 읽는다. ops·runs는 호출자 frame arena 소유.
///
/// **불투명 렌더링(뒤 폼 텍스트를 덮는다)**: 모달은 셀 그리드라 `.fill`이 셀 **배경만** 칠하고 **글리프는 안 지운다** —
/// 배경만 덮으면 팝업 뒤 폼 행 글리프가 비친다. 또 rich 모달은 배경이 surface_bg인 셀을 투명화해 뒤가 비친다. 그래서
/// (1) 각 행 배경을 surface_bg가 **아닌** 색(tab_hover_bg/선택=tab_active_bg)으로 칠해 투명화 pass에 안 지워지게 하고,
/// (2) 항목 텍스트를 **박스 폭까지 공백 패딩**해 그 행의 **모든 셀에 글리프**를 놓아 뒤 폼 글리프를 지운다. context_menu는
/// 터미널 위(다른 레이어)라 불투명하지만, 이 팝업은 설정 폼과 같은 modal 레이어라 이 방식으로 직접 덮는다.
pub fn viewPopup(
    state: *const State,
    anchor: draw.Rect,
    items: []const []const u8,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    _ = tk;
    if (!state.open) return;
    const rect = popupRect(anchor, items, p) orelse return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const box_cols: u32 = rect.w / cw; // 박스 폭(칸) — 항목 패딩 기준
    for (items, 0..) |it, i| {
        const row_y = rect.y + @as(i32, @intCast(i)) * @as(i32, @intCast(ch));
        // 행 배경(불투명) — 선택 행은 강조, 나머지는 elevated 패널색. surface_bg가 아니라 rich 투명화 pass를 피한다.
        const bg_role: tokens.ColorRole = if (i == state.selected) .tab_active_bg else .tab_hover_bg;
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = row_y, .w = rect.w, .h = ch }, .role = bg_role } });
        // " " + 항목('_'→'-') + (박스 폭까지 채우는 공백) — 행 전체 셀에 글리프를 깔아 뒤 폼 글리프를 지운다.
        var line: std.ArrayList(u8) = .empty;
        try line.append(arena, ' '); // 좌패딩 1칸
        for (it) |c| try line.append(arena, if (c == '_') '-' else c);
        var pad: u32 = box_cols -| (1 + overlay_input.displayCols(it)); // 좌패딩 + 항목 표시폭을 뺀 우측 채움
        while (pad > 0) : (pad -= 1) try line.append(arena, ' ');
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = line.items };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x, .y = row_y }, .runs = runs, .role = .surface_fg } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

const test_rect = draw.Rect{ .x = 100, .y = 50, .w = 100, .h = 20 };

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "dropdown view: 현재값 + ▾ 텍스트(surface_fg, control rect 좌상단)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(test_rect, "block", &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0] == .text);
    try std.testing.expectEqual(tokens.ColorRole.surface_fg, out.items[0].text.role);
    try std.testing.expectEqual(@as(i32, 100), out.items[0].text.origin.x);
    try std.testing.expect(std.mem.startsWith(u8, out.items[0].text.runs[0].text, "block")); // 현재값으로 시작
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].text.runs[0].text, "\u{25BE}") != null); // ▾ 포함

    // 0폭 rect → 무동작.
    out.clearRetainingCapacity();
    try view(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, "x", &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "dropdown view: 표시 토큰의 '_'→'-' 변환(config dashed 규약 — 테마 프리셋·commit_only 등)" {
    // @tagName은 underscore(rose_pine·commit_only), config 파일·문서는 dash(rose-pine·commit-only). 드롭다운은
    // 표시 시점에 변환한다(schema.appendEnumField 주석의 설계 — 여기서 검증). underscore가 남으면 회귀.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = testTokens();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(test_rect, "rose_pine", &tk, arena, &out);
    const label = out.items[0].text.runs[0].text;
    try std.testing.expect(std.mem.startsWith(u8, label, "rose-pine")); // dashed로 표시
    try std.testing.expect(std.mem.indexOfScalar(u8, label, '_') == null); // underscore 잔존 없음

    // 다중 underscore(가상 토큰)도 전부 변환.
    out.clearRetainingCapacity();
    try view(test_rect, "a_b_c", &tk, arena, &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items[0].text.runs[0].text, "a-b-c"));
}

test "dropdown hitTest: rect 안=true, 밖/비유한=false" {
    try std.testing.expect(hitTest(test_rect, 150, 60));
    try std.testing.expect(hitTest(test_rect, 100, 50));
    try std.testing.expect(!hitTest(test_rect, 200, 60));
    try std.testing.expect(!hitTest(test_rect, 150, 70));
    try std.testing.expect(!hitTest(test_rect, std.math.inf(f64), 60));
    try std.testing.expect(!hitTest(.{ .x = 0, .y = 0, .w = 0, .h = 20 }, 0, 0));
}

// ── 팝업 목록 테스트 ──────────────────────────────────────────────────────────────

test "dropdown popup State: show(현재값 시작)·hide·moveSelection wrap" {
    // 증명: 팝업은 현재 변형 인덱스에서 열려(사용자가 지금 값을 바로 봄), ↑↓가 wrap 이동(드롭다운 관례 —
    // 마지막↓→처음)하며, current가 범위를 넘으면 clamp된다. 설정에서 enum 값을 목록으로 고르는 핵심 상태.
    var s: State = .{};
    try std.testing.expect(!s.open);
    s.show(3, 1); // 항목 3, 현재=1
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 1), s.selected); // 현재값에서 시작
    s.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.moveSelection(1); // 마지막에서 ↓ → wrap 처음
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    s.moveSelection(-1); // 처음에서 ↑ → wrap 마지막
    try std.testing.expectEqual(@as(usize, 2), s.selected);
    s.hide();
    try std.testing.expect(!s.open);
    s.show(2, 9); // current 범위 밖 → clamp
    try std.testing.expectEqual(@as(usize, 1), s.selected);
}

test "dropdown popup handle: ↑↓ 이동·Enter=accept·Esc=close·←→/글자=consumed(유지)" {
    // 증명: 모달 캡처 전략 — 열려 있으면 ↑↓만 이동, Enter만 확정(accept, 컴포넌트는 안 닫음 — host가 hide),
    // Esc만 취소(close), ←→·글자는 consumed로 팝업 유지(섹션 전환 누수·실수 dismiss 방지). ←→가 닫지 '않는' 게 회귀 가드.
    var s: State = .{};
    s.show(3, 0);
    try std.testing.expectEqual(Action.selection_changed, handle(.{ .key = .down }, &s));
    try std.testing.expectEqual(@as(usize, 1), s.selected);
    try std.testing.expectEqual(Action.accept, handle(.{ .key = .enter }, &s));
    try std.testing.expect(s.open); // accept는 컴포넌트가 안 닫는다
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .left }, &s));
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .right }, &s));
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Action.consumed, handle(.{ .key = .char, .codepoint = 'x' }, &s));
    try std.testing.expect(s.open);
    try std.testing.expectEqual(Action.close, handle(.{ .key = .escape }, &s)); // Esc만 닫는다
    try std.testing.expect(!s.open);
}

test "dropdown popup popupRect/itemAt/viewPopup: control 아래 박스·항목 행 hit·최소 control 폭·닫히면 무동작" {
    // 증명: 팝업 박스는 축소 control 바로 아래에서 시작하고 폭은 control 폭 이상(값이 잘리지 않게), viewPopup과
    // itemAt이 같은 popupRect를 써 "보이는 행 == 클릭되는 행", 닫히면 아무것도 안 그린다.
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var s: State = .{};
    const items = [_][]const u8{ "top", "bottom", "center" };
    const anchor = draw.Rect{ .x = 200, .y = 100, .w = 160, .h = 16 }; // 선택 행의 축소 control — 팝업 y=116부터, 폭>=160
    s.show(items.len, 0);

    try std.testing.expectEqual(@as(usize, 0), itemAt(&s, anchor, &items, p, 210, 120).?); // 첫 행
    try std.testing.expectEqual(@as(usize, 2), itemAt(&s, anchor, &items, p, 210, 116 + 16 * 2 + 2).?); // 세 번째 행
    try std.testing.expect(itemAt(&s, anchor, &items, p, 210, 116 - 4) == null); // 박스 위 → null
    try std.testing.expect(itemAt(&s, anchor, &items, p, 210, 116 + 16 * 3 + 4) == null); // 박스 아래 → null

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(draw.Op) = .empty;
    try viewPopup(&s, anchor, &items, p, &tk, arena_state.allocator(), &out);
    // 항목마다 불투명 배경 fill + 패딩 텍스트 = 2 op. 3항목 = 6 op. 첫 op은 행0 배경 fill(불투명 — 뒤 폼 텍스트를 덮음).
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
    try std.testing.expect(out.items[0] == .fill);
    try std.testing.expectEqual(tokens.ColorRole.tab_active_bg, out.items[0].fill.role); // 행0=선택 → 강조 배경
    try std.testing.expect(out.items[1] == .text); // 행0 항목(패딩된 전체 폭 텍스트)
    try std.testing.expectEqual(tokens.ColorRole.tab_hover_bg, out.items[2].fill.role); // 행1=비선택 → 패널 배경

    s.hide();
    out.clearRetainingCapacity();
    try viewPopup(&s, anchor, &items, p, &tk, arena_state.allocator(), &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫히면 무동작
}
