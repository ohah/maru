//! 심볼 이름 바꾸기 상자(docs/editor-surface-tooling.md §8.2f) — 낱말 첫 글자 셀 **아래**에 뜨는 한 줄 입력 상자. 기하는 `popup_box`(호버
//! 상자와 같은 규율 — 아래, 안 들어가면 위로, 모달 padding 만큼 띄움), 안은 `input_box`(테두리 + 글 + 끝 caret). 글(query+조합)은 platform
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
    }, p) orelse return null;
    return .{ .x = placed.rect.x, .y = placed.rect.y, .w = box_w, .h = ch };
}

/// 상자를 그린다 — 닫혔거나 자리가 없으면 무동작. 글이 상한을 넘으면 꼬리(caret 쪽)를 보인다(입력줄 규율).
pub fn view(state: *const State, text: []const u8, p: props.ChromeProps, _: *const tokens.Tokens, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const rect = boxRect(state, text, p) orelse return;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const shown = overlay_input.tailWindow(text, max_cols - 3).text;
    try input_box.view(rect, shown, true, false, cw, ch, p.shape.corner_radius_px, p.shape.border_width_px, arena, out);
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
    try view(&st, "add", p, &tk, arena, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    st.show(100, 200, 20);
    const r = boxRect(&st, "add", p).?;
    try testing.expectEqual(@as(u32, 160), r.w); // min 16칸
    try testing.expect(r.y >= 200 + 20); // 앵커 아래
    try testing.expectEqual(@as(i32, 100), r.x);
    try view(&st, "add", p, &tk, arena, &out);
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
