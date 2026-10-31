const std = @import("std");
const config = @import("../config/theme.zig");
const renderer = @import("../renderer.zig");

/// Maru's existing macOS policy: the user's false disables application blink;
/// steady DECSCUSR, hidden cursor, composition and a modal also stop blinking.
pub fn shouldBlink(enabled: bool, application: bool, visible: bool, preedit: bool, overlay: bool) bool {
    return enabled and application and visible and !preedit and !overlay;
}
pub fn unfocusedMode(focused: bool, overlay: bool, mode: config.UnfocusedCursor) renderer.CursorUnfocused {
    if (focused and !overlay) return .normal;
    return switch (mode) {
        .block => .normal,
        .hollow => .hollow,
        .hidden => .hidden,
    };
}
/// Shared symmetric end-of-half ramp. Config values are milliseconds; the
/// intermediate is wider so a long interval cannot overflow during scaling.
pub fn fadeMilli(ticks_into_half: u32, half_ticks: u32, fade_ticks: u32, visible_half: bool) u32 {
    const half = @max(half_ticks, @as(u32, 1));
    const fade = @min(fade_ticks, half); // 페이드는 반주기를 넘지 못함(넘으면 hold 0)
    if (fade == 0) return if (visible_half) 1000 else 0; // 페이드 끔 = 즉각 on/off
    const hold = half - fade; // 완전 표시/숨김 유지 tick 수
    const t = @min(ticks_into_half, half - 1); // 방어적 clamp([0, half))
    if (visible_half) {
        if (t < hold) return 1000; // 완전 표시 hold
        const into = t - hold + 1; // 램프 진행 [1, fade] — 마지막 tick에 정확히 0
        return @intCast(1000 - (@as(u64, 1000) * into) / fade); // 1000 → 0 (사라짐)
    } else {
        if (t < hold) return 0; // 완전 숨김 hold
        const into = t - hold + 1; // [1, fade] — 마지막 tick에 정확히 1000(다음 visible 반 시작에 이어짐)
        return @intCast((@as(u64, 1000) * into) / fade); // 0 → 1000 (나타남)
    }
}

pub const Phase = struct {
    baseline: ?i128 = null,
    visible: bool = true,
    pub fn reset(self: *Phase) void {
        self.* = .{};
    }
    pub fn sample(self: *Phase, now_ns: i128, interval_ms: u32, fade_ms: u32, enabled: bool) u32 {
        if (!enabled) {
            self.reset();
            return 1000;
        }
        const base = self.baseline orelse now_ns;
        if (now_ns < base) {
            self.reset();
            self.baseline = now_ns;
            return 1000;
        }
        const half_ms = @max(interval_ms, 1);
        const half_ns = @as(i128, half_ms) * std.time.ns_per_ms;
        const elapsed = now_ns - base;
        const steps = @divTrunc(elapsed, half_ns);
        if (@mod(steps, 2) == 1) self.visible = !self.visible;
        self.baseline = base + steps * half_ns;
        const into_ms: u32 = @intCast(@divTrunc(now_ns - self.baseline.?, std.time.ns_per_ms));
        return fadeMilli(into_ms, half_ms, fade_ms, self.visible);
    }
};

test "cursor presentation respects config application hidden preedit and modal gates" {
    try std.testing.expect(shouldBlink(true, true, true, false, false));
    try std.testing.expect(!shouldBlink(false, true, true, false, false));
    try std.testing.expect(!shouldBlink(true, false, true, false, false));
    try std.testing.expect(!shouldBlink(true, true, false, false, false));
    try std.testing.expect(!shouldBlink(true, true, true, true, false));
    try std.testing.expect(!shouldBlink(true, true, true, false, true));
}
test "cursor presentation focus and modal map the three existing policies" {
    try std.testing.expectEqual(renderer.CursorUnfocused.normal, unfocusedMode(true, false, .hidden));
    try std.testing.expectEqual(renderer.CursorUnfocused.hidden, unfocusedMode(false, false, .hidden));
    try std.testing.expectEqual(renderer.CursorUnfocused.hollow, unfocusedMode(true, true, .hollow));
    try std.testing.expectEqual(renderer.CursorUnfocused.normal, unfocusedMode(false, false, .block));
}
test "cursor presentation fade endpoints clamp and large intervals remain safe" {
    try std.testing.expectEqual(@as(u32, 1000), fadeMilli(399, 500, 100, true));
    try std.testing.expectEqual(@as(u32, 990), fadeMilli(400, 500, 100, true));
    try std.testing.expectEqual(@as(u32, 0), fadeMilli(499, 500, 100, true));
    try std.testing.expectEqual(@as(u32, 1000), fadeMilli(999, 500, 100, false));
    try std.testing.expectEqual(@as(u32, 0), fadeMilli(0, 0, 20, true));
    try std.testing.expectEqual(@as(u32, 0), fadeMilli(std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), true));
}
test "cursor presentation phase catches up without drift and accepts a zero clock" {
    var p: Phase = .{};
    try std.testing.expectEqual(@as(u32, 1000), p.sample(0, 500, 0, true));
    try std.testing.expectEqual(@as(u32, 0), p.sample(750 * std.time.ns_per_ms, 500, 0, true));
    try std.testing.expectEqual(@as(?i128, 500 * std.time.ns_per_ms), p.baseline);
    try std.testing.expectEqual(@as(u32, 1000), p.sample(2250 * std.time.ns_per_ms, 500, 0, true));
    try std.testing.expectEqual(@as(?i128, 2000 * std.time.ns_per_ms), p.baseline);
}
test "cursor presentation reset disabled and reversed clock restore full visibility" {
    var p: Phase = .{};
    _ = p.sample(0, 500, 0, true);
    _ = p.sample(500 * std.time.ns_per_ms, 500, 0, true);
    try std.testing.expectEqual(@as(u32, 1000), p.sample(600 * std.time.ns_per_ms, 500, 0, false));
    try std.testing.expect(p.baseline == null and p.visible);
    _ = p.sample(800 * std.time.ns_per_ms, 500, 0, true);
    try std.testing.expectEqual(@as(u32, 1000), p.sample(1, 500, 0, true));
    try std.testing.expectEqual(@as(?i128, 1), p.baseline);
    p.reset();
    try std.testing.expect(p.baseline == null and p.visible);
}
