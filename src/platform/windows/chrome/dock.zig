const std = @import("std");
const maru = @import("maru");
const Rect = maru.session.split_tree.Rect;

/// The launcher remains available when content is hidden. Reserve it before
/// placing view icons so neither control overlaps native caption buttons.
pub fn buttonRect(width: u32, sidebar: u32, height: u32, caption_width: u32) Rect {
    const right = width -| caption_width * 3;
    if (height == 0 or caption_width == 0 or @as(u64, right) < @as(u64, sidebar) + caption_width)
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .x = right - caption_width, .y = 0, .w = caption_width, .h = height };
}

pub fn contains(r: Rect, x: i32, y: i32) bool {
    return r.w != 0 and r.h != 0 and @as(i64, x) >= r.x and @as(i64, y) >= r.y and
        @as(i64, x) < @as(i64, r.x) + r.w and @as(i64, y) < @as(i64, r.y) + r.h;
}

pub const Gesture = struct {
    pressed: bool = false,

    pub fn down(self: *Gesture, hit: bool) void {
        self.pressed = hit;
    }

    pub fn up(self: *Gesture, hit: bool) bool {
        const activate = self.pressed and hit;
        self.pressed = false;
        return activate;
    }

    pub fn cancel(self: *Gesture) void {
        self.pressed = false;
    }
};

test "Windows editor host dock launcher remains before captions with exact hit edges" {
    const r = buttonRect(1000, 180, 38, 46);
    try std.testing.expectEqual(@as(u32, 816), r.x);
    try std.testing.expectEqual(@as(u32, 862), r.x + r.w);
    try std.testing.expect(contains(r, 816, 0));
    try std.testing.expect(contains(r, 861, 37));
    try std.testing.expect(!contains(r, 862, 19));
    try std.testing.expect(!contains(r, 830, 38));
    try std.testing.expect(!contains(r, -1, 19));
    try std.testing.expectEqual(@as(u32, 0), buttonRect(300, 180, 38, 46).w);
    try std.testing.expectEqual(@as(u32, 0), buttonRect(1000, 180, 0, 46).w);
}

test "Windows editor host dock launcher requires owned press and discards interrupted release" {
    var g: Gesture = .{};
    try std.testing.expect(!g.up(true));
    g.down(true);
    try std.testing.expect(!g.up(false));
    g.down(true);
    g.cancel();
    try std.testing.expect(!g.up(true));
    g.down(true);
    try std.testing.expect(g.up(true));
    try std.testing.expect(!g.up(true));
}
