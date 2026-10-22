//! Header control plates and the search band. The host retains badge-circle and
//! legacy cell-zone arbitration; this frame describes the shared plate geometry.
const std = @import("std");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
pub const Part = enum(u8) { search, options, new_workspace, toggle, notifications };
pub const root_id: u64 = 0x5348000000000000;
pub fn partId(part: Part) u64 {
    return root_id + 1 + @backingInt(part);
}
pub const Model = struct {
    viewport: layout.UiRect = .{},
    icon_clip: layout.UiRect = .{},
    rects: [5]?layout.UiRect = @splat(null),
    search_active: bool = false,
    identity: u64 = 0,
};
fn feed(h: *std.hash.Wyhash, r: layout.UiRect) void {
    const values = [_]u32{ @bitCast(r.x), @bitCast(r.y), @bitCast(r.width), @bitCast(r.height) };
    h.update(std.mem.asBytes(&values));
}
pub fn signature(m: Model) u64 {
    var h = std.hash.Wyhash.init(m.identity);
    feed(&h, m.viewport);
    feed(&h, m.icon_clip);
    const active: u8 = @intFromBool(m.search_active);
    h.update(std.mem.asBytes(&active));
    for (m.rects) |r| {
        const exists: u8 = @intFromBool(r != null);
        h.update(std.mem.asBytes(&exists));
        if (r) |v| feed(&h, v);
    }
    return h.final();
}
fn valid(r: layout.UiRect) bool {
    return std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.width) and std.math.isFinite(r.height) and r.width >= 0 and r.height >= 0;
}
pub const Frame = struct {
    entries: [6]tree.RectEntry = undefined,
    len: usize = 0,
    generation: u64 = 0,
    stamp: ?u64 = null,
    pub fn invalidate(self: *Frame) void {
        self.len = 0;
        self.stamp = null;
        self.generation +|= 1;
    }
    pub fn current(self: *const Frame, m: Model) bool {
        return self.stamp != null and self.stamp.? == signature(m);
    }
    pub fn snapshot(self: *const Frame) tree.UiRectTree {
        return .{ .entries = self.entries[0..self.len], .generation = self.generation };
    }
    pub fn rect(self: *const Frame, part: Part) ?layout.UiRect {
        const t = self.snapshot();
        return t.entries[t.find(partId(part)) orelse return null].rect;
    }
    pub fn contains(self: *const Frame, part: Part, x: f64, y: f64) bool {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        const t = self.snapshot();
        const e = t.entries[t.find(partId(part)) orelse return false];
        const r = layout.intersectRect(e.rect, e.effective_clip orelse e.rect);
        return x >= r.x and y >= r.y and x < @as(f64, r.x) + r.width and y < @as(f64, r.y) + r.height;
    }
    pub fn publish(self: *Frame, m: Model) !void {
        self.inner(m) catch |err| {
            self.invalidate();
            return err;
        };
    }
    fn inner(self: *Frame, m: Model) !void {
        if (!valid(m.viewport) or !valid(m.icon_clip)) return error.InvalidGeometry;
        for (m.rects) |r| if (r) |v| {
            if (!valid(v)) return error.InvalidGeometry;
        };
        const stamp = signature(m);
        if (self.stamp == null or self.stamp.? != stamp) self.generation +|= 1;
        self.len = 0;
        self.stamp = null;
        for (m.rects, 0..) |maybe, i| if (maybe) |r| {
            const part: Part = @fromBackingInt(@intCast(i));
            const clip = if (part == .search) m.viewport else layout.intersectRect(m.icon_clip, m.viewport);
            const visible = layout.intersectRect(r, clip);
            if (visible.width <= 0 or visible.height <= 0) continue;
            if (self.len == 0) {
                self.entries[0] = .{ .id = root_id, .parent_index = null, .kind = .container, .rect = .{}, .action = null, .effective_clip = m.viewport, .semantics = .{ .role = .group, .label = "" } };
                self.len = 1;
            }
            self.entries[self.len] = .{ .id = partId(part), .parent_index = 0, .kind = if (part == .search) .text else .button, .rect = r, .effective_clip = clip, .action = .{ .id = partId(part) }, .cursor = if (part == .search) .text else .press, .semantics = .{ .role = if (part == .search) .text else .button, .label = "", .focusable = true, .selected = part == .search and m.search_active } };
            self.len += 1;
        };
        self.stamp = stamp;
    }
};
fn sample() Model {
    return .{ .viewport = .{ .width = 200, .height = 100 }, .icon_clip = .{ .width = 200, .height = 30 }, .rects = .{ .{ .x = 0, .y = 30, .width = 200, .height = 30 }, .{ .x = 70, .y = -2, .width = 20, .height = 40 }, .{ .x = 100, .y = 0, .width = 20, .height = 30 }, .{ .x = 40, .y = 0, .width = 20, .height = 30 }, .{ .x = 10, .y = 0, .width = 20, .height = 30 } } };
}
test "inspector sidebar header keeps roles clipping identity and current selection generations" {
    const inspect = @import("../../ui/inspection.zig");
    var f: Frame = .{};
    var m = sample();
    try f.publish(m);
    try std.testing.expectEqual(@as(usize, 6), f.len);
    for (f.snapshot().entries[1..]) |e| {
        try std.testing.expect(e.parent_index == 0 and e.action != null);
        try std.testing.expectEqual(@as(tree.CursorHint, if (e.id == partId(.search)) .text else .press), e.cursor);
    }
    try std.testing.expect(f.contains(.options, 75, 0) and !f.contains(.options, 75, 30));
    try std.testing.expect(f.contains(.search, 199, 30) and !f.contains(.search, 200, 30));
    try std.testing.expect(!f.contains(.search, std.math.nan(f64), 40));
    const old = inspect.identity(inspect.project(.sidebar_header, f.snapshot(), 1, 0, 0));
    const g = f.generation;
    try f.publish(m);
    try std.testing.expectEqual(g, f.generation);
    m.search_active = true;
    try f.publish(m);
    try std.testing.expect(f.generation > g);
    try std.testing.expect(inspect.resolve(&.{inspect.project(.sidebar_header, f.snapshot(), 1, 0, 0)}, old) == null);
    try std.testing.expect(f.snapshot().entries[1].semantics.?.selected);
    const g2 = f.generation;
    m.identity += 1;
    try f.publish(m);
    try std.testing.expect(f.generation > g2);
}
test "inspector sidebar header hides absent controls and rejects malformed geometry atomically" {
    var f: Frame = .{};
    var m = sample();
    try f.publish(m);
    m.rects[@backingInt(Part.options)] = null;
    try f.publish(m);
    try std.testing.expect(f.rect(.options) == null and f.len == 5);
    m.rects[0].?.width = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGeometry, f.publish(m));
    try std.testing.expect(f.len == 0 and f.stamp == null);
    try f.publish(sample());
    try std.testing.expectEqual(@as(usize, 6), f.len);
    m = sample();
    m.viewport.width = 0;
    try f.publish(m);
    try std.testing.expectEqual(@as(usize, 0), f.len);
    m = sample();
    for (&m.rects) |*r| r.* = null;
    try f.publish(m);
    try std.testing.expectEqual(@as(usize, 0), f.len);
}
