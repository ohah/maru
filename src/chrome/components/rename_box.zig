//! 심볼 이름 바꾸기 상자(docs/editor-surface-tooling.md §8.2f) — 낱말 첫 글자 셀 **아래**에 뜨는 한 줄 입력 상자. 기하는 `popup_box`(호버
//! 상자와 같은 규율 — 아래, 안 들어가면 위로, 모달 padding 만큼 띄움), 안은 `input_box`(테두리 + 글 + caret — caret 은 편집 위치, `viewCaretAt`). 글(caret 자리에 조합을 끼운 편집 글)은 platform
//! 의 인라인 rename 입력(`rename_input`)이 든다 — 이 모듈은 자리와 모양만 안다.
//!
//! 입력 라우팅은 platform 의 인라인 rename 모달(`inputFocus() == .rename`)이 이미 한다 — `modalInputRole` 에는 `.not_an_overlay` 로 선다
//! (호버 상자와 같은 자리 · 키를 여기서 가로채지 않는다).

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");
const popup_box = @import("popup_box.zig");
const input_box = @import("input_box.zig");
const overlay_input = @import("overlay_input.zig");
const grapheme = @import("../../grapheme.zig"); // UAX#29 글자 묶음 경계(`text_field` 와 같은 출처)

pub const layer = draw.Layer.modal;

/// 최소 폭(칸) — 짧은 이름도 상자로 보이게. 좌패딩 1칸 + 글 + caret 1칸 + 우여백 1칸이 그 안에 들어가면 그대로, 넘치면 글만큼.
pub const min_cols: u32 = 16;
/// 폭 상한(칸) — 호버 상자와 같다.
pub const max_cols: u32 = 80;

pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    anchor_h: u32 = 0,

    pub fn show(self: *State, x: i32, y: i32, h: u32) void {
        self.* = .{ .open = true, .anchor_x = x, .anchor_y = y, .anchor_h = h };
    }

    pub fn hide(self: *State) void {
        self.open = false;
    }
};

/// 글 폭으로 상자 칸수 — 좌패딩 1 + 글 + caret 1 + 우여백 1, `min_cols`..`max_cols`.
pub fn cols(text: []const u8) u32 {
    const need: u64 = @as(u64, overlay_input.displayCols(text)) + 3;
    return @intCast(@min(@max(need, @as(u64, min_cols)), @as(u64, max_cols)));
}

pub fn boxRect(state: *const State, text: []const u8, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const w_wide: u64 = @as(u64, cols(text)) * @as(u64, cw);
    const box_w: u32 = @intCast(@min(w_wide, @as(u64, std.math.maxInt(u32))));
    const placed = popup_box.place(box_w, ch, .{
        .anchor = .{ .x = state.anchor_x, .y = state.anchor_y, .w = 0, .h = state.anchor_h },
        .vertical = .below_flip_up,
        .gap_px = p.shape.modal_padding_px,
        // 입력 상자(`input_box`)는 rich 모양에서 둥근 패널 quad 를 내고, 그것이 이 draw(= 이 오버레이)의 첫 둥근 quad 라
        // 사방 패딩만큼 커져 그려진다 — 다른 오버레이가 같은 프레임에 있어도 그렇다(`metal_lowering` 은 draw 마다 센다,
        // 2026-10-07 — 예전에는 프레임 단위라 먼저 온 오버레이가 그 자리를 가져갔다). 경계 여백은 보이는 테두리에서 센다
        // (적대적 검증 2026-10-07: 「패널 없음」으로 잘못 분류됐었다).
        .visible_outset_px = p.shape.modal_padding_px,
    }, p) orelse return null;
    return .{ .x = placed.rect.x, .y = placed.rect.y, .w = box_w, .h = ch };
}

/// 상자를 그린다 — 닫혔거나 자리가 없으면 무동작. 글이 상한을 넘으면 꼬리를 보인다(입력줄 규율).
/// `caret_cols` 는 글 앞에서부터 caret 까지의 표시폭이다 — 편집기(`TextField`)가 caret 을 글 안으로 옮길 수
/// 있어서 끝에 고정해 그리면 타이핑이 들어가는 자리와 caret 이 어긋난다. 꼬리를 자르면 잘린 만큼 당긴다.
pub fn view(state: *const State, text: []const u8, caret_cols: u32, p: props.ChromeProps, _: *const tokens.Tokens, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const rect = boxRect(state, text, p) orelse return;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const shown = overlay_input.tailWindow(text, max_cols - 3).text;
    try input_box.viewCaretAt(rect, shown, true, false, shownCaretCols(text, caret_cols), cw, ch, p.shape.corner_radius_px, p.shape.border_width_px, arena, out);
}

/// 상자 안에서 caret 이 그려지는 칸(좌패딩 뒤 기준). 글이 상한을 넘으면 앞이 잘리므로 잘린 만큼 당긴다 — 그리기와
/// IME 후보창(`renameCaretRect`)이 **이 함수 하나**를 쓴다. 둘이 따로 셈하면 넘친 이름에서 후보창이 caret 과 갈린다.
pub fn shownCaretCols(text: []const u8, caret_cols: u32) u32 {
    const shown = overlay_input.tailWindow(text, max_cols - 3).text;
    const hidden_cols = overlay_input.displayCols(text) - overlay_input.displayCols(shown);
    return @min(caret_cols -| hidden_cols, overlay_input.displayCols(shown));
}

/// **누른 x 를 글의 바이트 위치로**(`view` 의 역함수). 그리는 쪽과 같은 셈 — 상자 왼쪽 + 좌패딩 1칸에서 글이 시작하고,
/// 길면 `tailWindow` 의 꼬리만 보인다(앞이 잘린 만큼 바이트를 더한다). 글자 묶음 경계 중 누른 칸에 가장 가까운 곳이고,
/// 같으면 뒤다(셀 경계를 누르면 다음 글자 앞 — `TextField.caretAtColumn` 과 같은 규칙). 상자가 없으면 null.
/// `TextField.caretAtColumn` 을 쓰지 않는 이유: 그쪽은 텍스트 필드 자신의 가로 스크롤(`scrollWindow`)로 그려진 글의 역이다 —
/// 이 상자는 그 모델로 그리지 않으므로 같은 함수를 쓰면 그려진 caret 과 누른 caret 이 갈린다.
pub fn caretOffsetAt(state: *const State, text: []const u8, x_px: f64, p: props.ChromeProps) ?usize {
    const rect = boxRect(state, text, p) orelse return null;
    const cw = @max(p.metrics.cell_width_px, 1);
    const shown = overlay_input.tailWindow(text, max_cols - 3).text;
    const hidden = text.len - shown.len; // 꼬리 창은 원본의 뒤쪽 부분 슬라이스다
    const text_x: f64 = @floatFromInt(rect.x + @as(i32, @intCast(cw)));
    const target = (x_px - text_x) / @as(f64, @floatFromInt(cw)); // 칸 단위(소수) — 왼쪽 패딩이면 음수
    var best: usize = 0;
    var best_dist = std.math.inf(f64);
    var b: usize = 0;
    var acc: u32 = 0;
    while (true) {
        const dist = @abs(@as(f64, @floatFromInt(acc)) - target);
        if (dist <= best_dist) { // <= — 같으면 뒤 경계
            best_dist = dist;
            best = b;
        }
        if (b >= shown.len) break;
        const e = grapheme.clusterEnd(shown, b);
        acc += overlay_input.displayCols(shown[b..e]);
        b = e;
    }
    return hidden + best;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "RNB1 rename_box — 닫히면 무동작, 열리면 앵커 아래 입력 상자(테두리·글·caret), 폭은 최소 16칸·글이 길면 그만큼 (§8.2f)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
    p.shape.border_width_px = 1;
    const Rgb = @import("../../color.zig").Rgb;
    const tk: tokens.Tokens = .{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var st = State{};
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, "add", 3, p, &tk, arena, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    st.show(100, 200, 20);
    const r = boxRect(&st, "add", p).?;
    try testing.expectEqual(@as(u32, 160), r.w); // min 16칸
    try testing.expect(r.y >= 200 + 20); // 앵커 아래
    try testing.expectEqual(@as(i32, 100), r.x);
    try view(&st, "add", 3, p, &tk, arena, &out);
    try testing.expect(out.items.len >= 3); // quad + text + caret
    var has_quad = false;
    var has_text = false;
    var has_caret = false;
    for (out.items) |op| switch (op) {
        .quad => has_quad = true,
        .text => |t| {
            has_text = true;
            try testing.expectEqualStrings("add", t.runs[0].text);
        },
        .fill => |f| {
            has_caret = f.role == .cursor;
            try testing.expectEqual(r.x + 10 + 30, f.rect.x); // 좌패딩 1칸 + 3글자
        },
        else => {},
    };
    try testing.expect(has_quad and has_text and has_caret);
    const long = "a_very_long_identifier_name_x";
    try testing.expectEqual(@as(u32, (29 + 3) * 10), boxRect(&st, long, p).?.w);
}

test "RNB4 rename_box — 오른쪽 끝 낱말에서 연 상자도 **보이는 테두리**가 창 끝에서 한 셀 떨어진다" {
    // 입력 상자는 rich 모양에서 둥근 패널 quad 를 내고 lowering 이 그것을 사방 패딩만큼 키운다. rect 를 한 셀(10)만 띄우면
    // 보이는 패널이 2px 넘쳐 테두리가 창 끝에 먹혔다(적대적 검증 2026-10-07 — `popup_box.Placement.visible_outset_px`).
    var p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
    p.shape.border_width_px = 1;
    p.shape.modal_padding_px = 12;
    var st = State{};
    st.show(1190, 200, 20);
    const r = boxRect(&st, "add", p).?;
    try testing.expectEqual(@as(i32, 1200 - 10), r.x + @as(i32, @intCast(r.w)) + 12); // 보이는 우단 = 창 끝 − 한 셀
    st.show(0, 200, 20);
    try testing.expectEqual(@as(i32, 10), boxRect(&st, "add", p).?.x - 12); // 보이는 좌단 = 한 셀
}

test "RNB2 rename_box — caret 은 편집 위치에 그린다(끝 고정이 아니다)" {
    // 증명: 편집기가 caret 을 글 안으로 옮기면 상자도 그 칸에 caret 을 그린다. 끝에 고정하면 타이핑이 들어가는
    // 자리(caret)와 보이는 caret 이 어긋난다 — 2026-09-29 이전의 모양이다.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
    const Rgb = @import("../../color.zig").Rgb;
    const tk: tokens.Tokens = .{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var st = State{};
    st.show(100, 200, 20);
    const r = boxRect(&st, "add", p).?;
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, "add", 1, p, &tk, arena, &out);
    var caret_x: ?i32 = null;
    for (out.items) |op| switch (op) {
        .fill => |f| if (f.role == .cursor) {
            caret_x = f.rect.x;
        },
        else => {},
    };
    try testing.expectEqual(@as(?i32, r.x + 10 + 10), caret_x); // 좌패딩 1칸 + 'a' 뒤
}

test "RNB3 rename_box — 글이 상한을 넘어 앞이 잘리면 caret 도 잘린 만큼 당겨 그린다" {
    // 꼬리만 보이는 상자에서 caret 칸을 그대로 쓰면 caret 이 실제보다 오른쪽(대개 끝)으로 밀린다.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 4000, .backing_height_px = 800 } };
    const Rgb = @import("../../color.zig").Rgb;
    const tk: tokens.Tokens = .{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    var st = State{};
    st.show(100, 200, 20);
    const long = "a" ** 100;
    const shown_cols = max_cols - 3;
    const hidden = 100 - shown_cols;
    const r = boxRect(&st, long, p).?;
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, long, 90, p, &tk, arena, &out);
    var caret_x: ?i32 = null;
    for (out.items) |op| switch (op) {
        .fill => |f| if (f.role == .cursor) {
            caret_x = f.rect.x;
        },
        else => {},
    };
    try testing.expectEqual(@as(?i32, r.x + 10 + @as(i32, @intCast((90 - hidden) * 10))), caret_x);
}

test "RNB5 caretOffsetAt — 그리는 쪽의 역함수: 좌패딩은 0, 글자 가운데 기준 가까운 경계(같으면 뒤), 끝 너머는 끝, 넓은 글자는 두 칸, 꼬리 창은 잘린 바이트를 더한다 (§8.2f)" {
    var p: props.ChromeProps = .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
    p.shape.border_width_px = 1;
    var st = State{};
    try testing.expect(caretOffsetAt(&st, "add", 0, p) == null); // 닫히면 없다
    st.show(100, 200, 20);
    const r = boxRect(&st, "add", p).?;
    const tx: f64 = @floatFromInt(r.x + 10); // 글 시작 = 상자 + 좌패딩 1칸
    try testing.expectEqual(@as(?usize, 0), caretOffsetAt(&st, "add", @floatFromInt(r.x + 2), p)); // 좌패딩 → 처음
    try testing.expectEqual(@as(?usize, 0), caretOffsetAt(&st, "add", tx + 4, p)); // 첫 글자 왼쪽 절반 → 그 앞
    try testing.expectEqual(@as(?usize, 1), caretOffsetAt(&st, "add", tx + 6, p)); // 오른쪽 절반 → 그 뒤
    try testing.expectEqual(@as(?usize, 1), caretOffsetAt(&st, "add", tx + 5, p)); // 정확히 가운데 → 같으면 뒤
    try testing.expectEqual(@as(?usize, 2), caretOffsetAt(&st, "add", tx + 20, p)); // 셀 경계 → 그 경계
    try testing.expectEqual(@as(?usize, 3), caretOffsetAt(&st, "add", tx + 200, p)); // 끝 너머 → 끝
    // 넓은 글자(한글 — 두 칸, 3바이트): 경계는 칸 0·2·4 = 바이트 0·3·6.
    try testing.expectEqual(@as(?usize, 3), caretOffsetAt(&st, "가나", tx + 21, p)); // 칸 2.1 → 첫 글자 뒤
    try testing.expectEqual(@as(?usize, 0), caretOffsetAt(&st, "가나", tx + 9, p)); // 칸 0.9 → 앞(1.0 은 가운데라 뒤)
    try testing.expectEqual(@as(?usize, 6), caretOffsetAt(&st, "가나", tx + 35, p));
    // 꼬리 창 — 90칸 글은 앞 13칸이 잘려 77칸만 보인다. 보이는 첫 칸을 누르면 13(잘린 바이트), 보이는 셋째 칸 경계면 15.
    const long = "a" ** 90;
    const lr = boxRect(&st, long, p).?;
    const ltx: f64 = @floatFromInt(lr.x + 10);
    try testing.expectEqual(@as(?usize, 13), caretOffsetAt(&st, long, ltx + 1, p));
    try testing.expectEqual(@as(?usize, 15), caretOffsetAt(&st, long, ltx + 20, p));
    try testing.expectEqual(@as(?usize, 90), caretOffsetAt(&st, long, ltx + 2000, p));
}
