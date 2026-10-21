//! Published file mode controls. The host supplies domain-free rectangles and
//! opaque owner identity; this layer never imports the session's file model.
pub const details = @import("file_header/details.zig");
const std = @import("std");
const tree = @import("../ui/tree.zig");
const layout = @import("../ui/layout.zig");
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    pub fn ui(r: Rect) layout.UiRect {
        return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(r.h) };
    }
};
pub const Control = struct { tag: u64, rect: Rect, active: bool };
pub const Model = struct { rect: Rect, identity: u64, controls: [3]Control = undefined, count: usize = 0 };
pub fn rootId(index: usize) u64 {
    return 0x4648000000000000 + @as(u64, @intCast(index)) * 0x100000000;
}
pub fn controlId(index: usize, tag: u64) u64 {
    return rootId(index) + 1 + tag;
}
pub fn signature(models: []const Model, epoch: u64) u64 {
    var h = std.hash.Wyhash.init(epoch);
    for (models) |m| {
        const fields = [_]u64{ m.identity, m.rect.x, m.rect.y, m.rect.w, m.rect.h, m.count };
        h.update(std.mem.asBytes(&fields));
        // Rejecting an oversized model must not inspect its uninitialized tail.
        if (m.count > m.controls.len) continue;
        for (m.controls[0..m.count]) |c| {
            const v = [_]u64{ c.tag, c.rect.x, c.rect.y, c.rect.w, c.rect.h, @intFromBool(c.active) };
            h.update(std.mem.asBytes(&v));
        }
    }
    return h.final();
}
pub const Frame = struct {
    entries: std.ArrayList(tree.RectEntry) = .empty,
    generation: u64 = 0,
    stamp: ?u64 = null,
    pub fn deinit(self: *Frame, a: std.mem.Allocator) void {
        self.entries.deinit(a);
        self.* = .{};
    }
    pub fn invalidate(self: *Frame) void {
        self.entries.clearRetainingCapacity();
        self.stamp = null;
        self.generation +|= 1;
    }
    pub fn snapshot(self: *const Frame) tree.UiRectTree {
        return .{ .entries = self.entries.items, .generation = self.generation };
    }
    pub fn rect(self: *const Frame, id: u64) ?Rect {
        const t = self.snapshot();
        const r = t.entries[t.find(id) orelse return null].rect;
        return .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(r.width), .h = @intFromFloat(r.height) };
    }
    pub fn publish(self: *Frame, a: std.mem.Allocator, models: []const Model, epoch: u64) !void {
        self.inner(a, models, epoch) catch |err| {
            self.invalidate();
            return err;
        };
    }
    fn inner(self: *Frame, a: std.mem.Allocator, models: []const Model, epoch: u64) !void {
        const stamp = signature(models, epoch);
        if (self.stamp == null or self.stamp.? != stamp) self.generation +|= 1;
        self.entries.clearRetainingCapacity();
        self.stamp = null;
        for (models, 0..) |m, mi| {
            if (m.count > 3) return error.InvalidControls;
            var tags: u8 = 0;
            for (m.controls[0..m.count]) |c| {
                if (c.tag > 2) return error.InvalidControls;
                const bit: u8 = @as(u8, 1) << @as(u3, @intCast(c.tag));
                if (tags & bit != 0) return error.InvalidControls;
                tags |= bit;
            }
            if (m.count == 0 or m.rect.w == 0 or m.rect.h == 0) continue;
            const clip = m.rect.ui();
            // Only the mode strip is inspectable. Breadcrumb and status controls
            // have separate owners and must not acquire a synthetic hit region.
            var bounds = layout.intersectRect(m.controls[0].rect.ui(), clip);
            for (m.controls[0..m.count]) |c| {
                const r = layout.intersectRect(c.rect.ui(), clip);
                const right = @max(bounds.x + bounds.width, r.x + r.width);
                bounds.x = @min(bounds.x, r.x);
                bounds.width = right - bounds.x;
            }
            const parent = self.entries.items.len;
            try self.entries.append(a, .{ .id = rootId(mi), .parent_index = null, .kind = .container, .rect = bounds, .effective_clip = clip, .action = null, .semantics = .{ .role = .group, .label = "" } });
            for (m.controls[0..m.count]) |c| {
                if (c.tag > 2) return error.InvalidControls;
                const r = layout.intersectRect(c.rect.ui(), clip);
                if (r.width <= 0 or r.height <= 0) continue;
                try self.entries.append(a, .{ .id = controlId(mi, c.tag), .parent_index = parent, .kind = .button, .rect = r, .effective_clip = clip, .action = .{ .id = controlId(mi, c.tag) }, .cursor = .press, .semantics = .{ .role = .tab, .label = "", .selected = c.active, .focusable = true } });
            }
        }
        self.stamp = stamp;
    }
};
fn sample() Model {
    return .{ .rect = .{ .x = 10, .y = 20, .w = 101, .h = 24 }, .identity = 9, .count = 3, .controls = .{ .{ .tag = 0, .rect = .{ .x = 60, .y = 20, .w = 16, .h = 24 }, .active = true }, .{ .tag = 2, .rect = .{ .x = 76, .y = 20, .w = 16, .h = 24 }, .active = false }, .{ .tag = 1, .rect = .{ .x = 92, .y = 20, .w = 24, .h = 24 }, .active = false } } };
}
test "inspector file header publication clips modes isolates panes and retires semantic selections" {
    const inspect = @import("../ui/inspection.zig");
    const a = std.testing.allocator;
    var f: Frame = .{};
    defer f.deinit(a);
    var m = sample();
    try f.publish(a, &.{ m, m }, 1);
    const t = f.snapshot();
    try std.testing.expectEqual(@as(usize, 8), t.entries.len);
    for (t.entries, 0..) |entry, i| for (t.entries[i + 1 ..]) |other| try std.testing.expect(entry.id != other.id);
    try std.testing.expectEqual(@as(u32, 19), f.rect(controlId(0, 1)).?.w);
    try std.testing.expectEqual(@as(u32, 60), f.rect(rootId(0)).?.x);
    try std.testing.expectEqual(@as(?usize, 4), t.entries[7].parent_index);
    try std.testing.expect(t.entries[1].semantics.?.selected and !t.entries[2].semantics.?.selected);
    const old = inspect.identity(inspect.project(.file_header, t, 1, 0, 0));
    const generation = f.generation;
    try f.publish(a, &.{ m, m }, 1);
    try std.testing.expectEqual(generation, f.generation);
    m.identity += 1;
    try f.publish(a, &.{ m, m }, 1);
    try std.testing.expect(inspect.resolve(&.{inspect.project(.file_header, f.snapshot(), 1, 0, 0)}, old) == null);
    const before = f.generation;
    m.controls[0].active = false;
    try f.publish(a, &.{ m, m }, 1);
    try std.testing.expect(f.generation > before);
    const g = f.generation;
    try f.publish(a, &.{ m, m }, 2);
    try std.testing.expect(f.generation > g);
    m.controls[1].tag = m.controls[0].tag;
    try std.testing.expectError(error.InvalidControls, f.publish(a, &.{m}, 2));
    try std.testing.expect(f.stamp == null and f.entries.items.len == 0);
    m = sample();
    m.rect.h = 0;
    try f.publish(a, &.{m}, 2);
    try std.testing.expectEqual(@as(usize, 0), f.entries.items.len);
    m.rect.h = 24;
    m.count = 0;
    try f.publish(a, &.{m}, 2);
    try std.testing.expectEqual(@as(usize, 0), f.entries.items.len);
    m = sample();
    try f.publish(a, &.{m}, 2);
    m.count = 4;
    const invalid_stamp = signature(&.{m}, 2);
    m.controls[0].rect.w += 1;
    try std.testing.expectEqual(invalid_stamp, signature(&.{m}, 2));
    try std.testing.expectError(error.InvalidControls, f.publish(a, &.{m}, 2));
    try std.testing.expect(f.stamp == null and f.entries.items.len == 0);
}
test "inspector file header publication allocation failures clear partial frames and recover" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const a = fail.allocator();
    var f: Frame = .{};
    defer f.deinit(a);
    const m = sample();
    const models = [_]Model{ m, m, m, m };
    try std.testing.expectError(error.OutOfMemory, f.publish(a, &models, 1));
    try std.testing.expect(f.stamp == null and f.entries.items.len == 0);
    fail.fail_index = std.math.maxInt(usize);
    try f.publish(a, &models, 1);
    try std.testing.expectEqual(@as(usize, 16), f.entries.items.len);
}
