//! 입력 변환 중 CEF 헤더 없이 시험할 수 있는 부분(W4) — maru 수식자 → CEF `EVENTFLAG_*` 비트, IME 글자 사각형 합치기.
//! 비트 값은 CEF 헤더(`cef_types.h`)의 값을 옮긴 것이고, `input.zig` 가 sidecar 빌드에서 헤더 값과 같은지 comptime 으로
//! 확인한다(CEF 를 올려 값이 바뀌면 빌드가 멈춘다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const message = protocol.message;

pub const event_flag = struct {
    pub const caps_lock_on: u32 = 1 << 0;
    pub const shift_down: u32 = 1 << 1;
    pub const control_down: u32 = 1 << 2;
    pub const alt_down: u32 = 1 << 3;
    pub const left_mouse_button: u32 = 1 << 4;
    pub const middle_mouse_button: u32 = 1 << 5;
    pub const right_mouse_button: u32 = 1 << 6;
    pub const command_down: u32 = 1 << 7;
    pub const is_key_pad: u32 = 1 << 9;
    pub const is_left: u32 = 1 << 10;
    pub const is_right: u32 = 1 << 11;
    pub const is_repeat: u32 = 1 << 13;
    pub const precision_scrolling_delta: u32 = 1 << 14;
};

/// maru 의 수식자 → CEF `EVENTFLAG_*`.
pub fn flags(modifiers: message.Modifiers) u32 {
    var out: u32 = 0;
    if (modifiers.caps_lock) out |= event_flag.caps_lock_on;
    if (modifiers.shift) out |= event_flag.shift_down;
    if (modifiers.control) out |= event_flag.control_down;
    if (modifiers.alt) out |= event_flag.alt_down;
    if (modifiers.command) out |= event_flag.command_down;
    if (modifiers.left_button) out |= event_flag.left_mouse_button;
    if (modifiers.middle_button) out |= event_flag.middle_mouse_button;
    if (modifiers.right_button) out |= event_flag.right_mouse_button;
    if (modifiers.is_repeat) out |= event_flag.is_repeat;
    if (modifiers.precise_scroll) out |= event_flag.precision_scrolling_delta;
    if (modifiers.key_pad) out |= event_flag.is_key_pad;
    if (modifiers.is_left) out |= event_flag.is_left;
    if (modifiers.is_right) out |= event_flag.is_right;
    return out;
}

/// 조합이 아무리 길어도 이만큼만 본다(후보창 위치에는 앞 글자들이면 된다).
pub const max_bounds = 256;

/// 글자 사각형들(`x`·`y`·`width`·`height` 를 가진 아무 구조체 — CEF 의 `cef_rect_t`)을 합친다. 음수 크기는 0 으로 본다.
/// codec 상한(`max_pointer_extent`)을 넘으면 null — 보내 봐야 codec 이 거절한다.
pub fn unionOf(comptime R: type, rects: []const R) ?message.Rect {
    if (rects.len == 0) return null;
    var x0: i64 = rects[0].x;
    var y0: i64 = rects[0].y;
    var x1: i64 = x0 + @max(rects[0].width, 0);
    var y1: i64 = y0 + @max(rects[0].height, 0);
    for (rects[1..]) |r| {
        x0 = @min(x0, r.x);
        y0 = @min(y0, r.y);
        x1 = @max(x1, @as(i64, r.x) + @max(r.width, 0));
        y1 = @max(y1, @as(i64, r.y) + @max(r.height, 0));
    }
    const limit = message.max_pointer_extent;
    if (@abs(x0) > limit or @abs(y0) > limit or x1 - x0 > limit or y1 - y0 > limit) return null;
    return .{ .x = @intCast(x0), .y = @intCast(y0), .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
}

const TestRect = struct { x: c_int, y: c_int, width: c_int, height: c_int };

test "unionOf joins character boxes and refuses boxes the codec would reject" {
    const rects = [_]TestRect{ .{ .x = 10, .y = 20, .width = 8, .height = 16 }, .{ .x = 18, .y = 20, .width = 8, .height = 18 } };
    try std.testing.expectEqual(message.Rect{ .x = 10, .y = 20, .width = 16, .height = 18 }, unionOf(TestRect, &rects).?);
    try std.testing.expectEqual(@as(?message.Rect, null), unionOf(TestRect, &.{}));
    const huge = [_]TestRect{.{ .x = std.math.minInt(c_int), .y = 0, .width = 1, .height = 1 }};
    try std.testing.expectEqual(@as(?message.Rect, null), unionOf(TestRect, &huge));
    const wide = [_]TestRect{ .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .x = std.math.maxInt(c_int) - 1, .y = 0, .width = std.math.maxInt(c_int), .height = 1 } };
    try std.testing.expectEqual(@as(?message.Rect, null), unionOf(TestRect, &wide));
    const negative = [_]TestRect{.{ .x = 0, .y = 0, .width = -5, .height = 3 }};
    try std.testing.expectEqual(message.Rect{ .x = 0, .y = 0, .width = 0, .height = 3 }, unionOf(TestRect, &negative).?);
}

test "modifier flags map one to one and every defined modifier sets a distinct bit" {
    try std.testing.expectEqual(@as(u32, 0), flags(.{}));
    try std.testing.expectEqual(event_flag.control_down | event_flag.left_mouse_button, flags(.{ .control = true, .left_button = true }));
    var seen: u32 = 0;
    inline for (std.meta.fields(message.Modifiers)) |field| {
        if (field.type != bool) continue;
        var modifiers: message.Modifiers = .{};
        @field(modifiers, field.name) = true;
        const bit = flags(modifiers);
        try std.testing.expect(@popCount(bit) == 1);
        try std.testing.expect(seen & bit == 0);
        seen |= bit;
    }
}
