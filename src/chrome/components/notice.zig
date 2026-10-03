//! Notice — 손상/오류 알림 모달(키보드 전용, hit-test 없음). chrome 컴포넌트 **계약의 exemplar**:
//!   State(순수 데이터+전이) + view(state, props, tokens → ChromeDraw, 순수) + handle(event, *state → ?Action).
//! 규칙(기존 palette/find 패턴 승계): State는 렌더를 모르고, view는 State를 읽기만, handle은 State를
//! mutate + intent(Action) 반환. 라이프사이클(언제 열고)은 host가 소유. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const input = @import("../input.zig");
const modal_box = @import("modal_box.zig");

/// 이 컴포넌트가 그리는 레이어(최상위 모달, modal_box 공유). host가 ops와 짝지어 백엔드에 넘긴다.
pub const layer = modal_box.layer;

/// 순수 상태 — message 슬롯 + open 플래그. host(또는 복원 손상 감지)가 show를 부른다.
pub const State = struct {
    open: bool = false,
    message: []const u8 = "",

    pub fn show(self: *State, message: []const u8) void {
        self.message = message;
        self.open = true;
    }

    pub fn dismiss(self: *State) void {
        self.open = false;
    }
};

/// handle이 돌려주는 intent. host가 받아 후처리(여기선 닫기 외 부수효과 없음).
pub const Action = enum { dismissed };

/// 키 이벤트 처리. 열려 있을 때만 동작 — notice는 **비-인터랙티브 정보 토스트**(자동 닫힘 타이머 없음)라 **아무 키로나
/// 닫고** `dismissed`를 돌려준다(Enter/Esc 전용이던 것을 넓힘 — 그 외 키는 소비만 하고 안 닫혀, 토스트가 떠 있는 동안
/// 키 입력이 막힌 것처럼 보이던 회귀를 푼다). 닫는 키는 host가 소비한다(셸로 안 흘림 — 토스트 확인 제스처). 닫혀 있으면
/// null(라우팅 안 가로챔). host가 `.key`/`.pointer`를 가르므로(CS-4-0) 이 handle은 KeyEvent만 받는다 — 포인터는 mouse().
pub fn handle(k: input.InputEvent.KeyEvent, state: *State) ?Action {
    _ = k; // 키 종류 무관 — 모든 키가 동일하게 토스트를 닫는다(입력 대상이 아닌 정보 토스트)
    if (!state.open) return null;
    state.dismiss();
    return .dismissed;
}

/// 메시지를 중앙 모달 박스로 그린다 — 박스에 한 줄로 안 들어가면 `modal_box.wrap` 으로 여러 줄로 나눈다(한 줄로만 그리던
/// 때는 긴 안내가 박스 밖으로 넘쳐 끝이 안 보였다 — 예: Chromium 엔진 「버전 불일치」 146 칸). 박스 기하·폭 clamp·soft-lock
/// 가드·배경 quad+테두리는 modal_box.view 단일 출처에 위임한다(notice/confirm 공유). 안 열렸으면 무동작. 순수: state·
/// props·tokens만 읽는다.
pub fn view(
    state: *const State,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (!state.open) return;
    const texts = try modal_box.wrap(state.message, p, tk, arena) orelse return;
    const lines = try arena.alloc(modal_box.Line, texts.len);
    for (texts, lines) |t, *ln| ln.* = .{ .text = t, .role = .surface_fg };
    try modal_box.view(lines, p, tk, arena, out);
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// Notice는 chrome 컴포넌트 계약의 첫 구현이라, 헤드리스로 (1) 상태 전이 (2) 입력→intent (3) view가
// 기대 ops를 내는지를 증명한다 — macOS·렌더 없이.

test "notice state: show/dismiss" {
    var s = State{};
    try std.testing.expect(!s.open);
    s.show("손상됨");
    try std.testing.expect(s.open);
    try std.testing.expectEqualStrings("손상됨", s.message);
    s.dismiss();
    try std.testing.expect(!s.open);
}

test "notice handle: 아무 키로나 닫고 dismissed, 닫힘이면 null" {
    var s = State{};
    try std.testing.expect(handle(.{ .key = .enter }, &s) == null); // 닫혀 있으면 무동작
    s.show("x");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .escape }, &s).?); // Esc로 닫힘
    try std.testing.expect(!s.open);
    s.show("y");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .enter }, &s).?); // Enter로 닫힘
    try std.testing.expect(!s.open);
    // 평문 글자도 토스트를 닫는다(비-인터랙티브 토스트 — Enter/Esc 전용이 아니다, 회귀 수정).
    s.show("z");
    try std.testing.expectEqual(Action.dismissed, handle(.{ .key = .char, .codepoint = 'a' }, &s).?);
    try std.testing.expect(!s.open);
}

test "notice view: 닫힘이면 ops 0, 열림이면 quad+text(modal)" {
    const Rgb = @import("../../color.zig").Rgb;
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
    var out: std.ArrayList(draw.Op) = .empty;

    var s = State{};
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 닫힘

    s.show("file corrupt");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .text);
    try std.testing.expectEqualStrings("file corrupt", out.items[1].text.runs[0].text);
    // 모달 박스는 전체 작업영역(사이드바·titlebar 제외, dock 포함) 안, 화면 중앙쯤. 박스 기하 엣지케이스(soft-lock 가드·폭 clamp·
    // rich 패딩 침범)는 modal_box.zig 테스트가 단일 출처로 커버한다(notice/confirm 공유 — 여기선 위임만 확인).
    try std.testing.expect(out.items[0].quad.rect.x >= 40);
    try std.testing.expect(out.items[0].quad.rect.w > 0);
}

test "notice view: a message wider than the workspace wraps into lines that stay inside the box" {
    const Rgb = @import("../../color.zig").Rgb;
    const overlay_input = @import("overlay_input.zig");
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // 작업영역 80 칸(8px × 640) — 146 칸짜리 안내.
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 640,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;
    var s = State{};
    s.show("The installed Chromium engine (maru-chromium) does not match this maru. Update maru and maru-chromium to their latest versions, then restart maru.");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expect(out.items.len >= 3); // quad + 두 줄 이상
    const box = out.items[0].quad.rect;
    for (out.items[1..]) |op| {
        try std.testing.expect(op == .text);
        const right = op.text.origin.x + @as(i32, @intCast(overlay_input.displayCols(op.text.runs[0].text) * 8));
        try std.testing.expect(op.text.origin.x >= box.x and right <= box.x + @as(i32, @intCast(box.w)));
        try std.testing.expect(op.text.origin.y + 16 <= box.y + @as(i32, @intCast(box.h)));
    }
}

test "notice view: a line that fills the width stays inside the box's side margins" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 0,
            .backing_width_px = 320, // 40 칸
            .backing_height_px = 600,
        },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;
    var s = State{};
    s.show("x" ** 200); // 공백 없는 긴 단어 — 줄이 폭을 꽉 채운다
    try view(&s, p, &tk, arena, &out);
    const box = out.items[0].quad.rect;
    const margin: i32 = @intCast(tk.space.modal_margin_cells * 8);
    for (out.items[1..]) |op| {
        const right = op.text.origin.x + @as(i32, @intCast(op.text.runs[0].text.len * 8));
        try std.testing.expect(op.text.origin.x >= box.x + margin);
        try std.testing.expect(right <= box.x + @as(i32, @intCast(box.w)) - margin);
    }
}

test "notice view: NFD Korean, emoji and combining marks are measured as the painter draws them — lines stay inside the box" {
    const Rgb = @import("../../color.zig").Rgb;
    const overlay_input = @import("overlay_input.zig");
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 320, .backing_height_px = 600 } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const margin: i32 = @intCast(tk.space.modal_margin_cells * 8);
    for ([_][]const u8{
        "/Users/x/" ++ "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}" ** 8 ++ ".txt", // NFD 한글 경로
        "\u{2764}\u{FE0F}" ** 30, // VS16
        "cafe\u{301} " ** 12, // 결합 문자
        "bad \xff\xfe bytes " ** 6, // 손상 UTF-8
    }) |msg| {
        var out: std.ArrayList(draw.Op) = .empty;
        var s = State{};
        s.show(msg);
        try view(&s, p, &tk, arena, &out);
        const box = out.items[0].quad.rect;
        try std.testing.expect(out.items.len >= 2);
        for (out.items[1..]) |op| {
            const t = op.text.runs[0].text;
            try std.testing.expect(std.unicode.utf8ValidateSlice(t)); // 그리는 쪽이 버리지 않게
            try std.testing.expectEqual(tokens.ColorRole.surface_fg, op.text.role);
            const right = op.text.origin.x + @as(i32, @intCast(overlay_input.displayCols(t) * 8));
            try std.testing.expect(right <= box.x + @as(i32, @intCast(box.w)) - margin);
        }
    }
}

test "notice view: in a short workspace the wrapped lines are cut to the rows so the box stays inside" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // 작업영역 40 칸 × 5 행(8×16px, 320×80) — 콘텐츠 3 행.
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = 320,
        .backing_height_px = 80,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;
    var s = State{};
    s.show("The installed Chromium engine (maru-chromium) does not match this maru. Update maru and maru-chromium to their latest versions, then restart maru.");
    try view(&s, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len); // quad + 세 줄
    const box = out.items[0].quad.rect;
    try std.testing.expect(box.y >= 0 and box.y + @as(i32, @intCast(box.h)) <= 80);
    try std.testing.expect(std.mem.endsWith(u8, out.items[3].text.runs[0].text, "…"));
}
