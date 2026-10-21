//! Only rectangles emitted by the painted header belong here. User text and
//! session/editor pointers stay with the host; inspection receives fixed roles.
const std = @import("std");
const tree = @import("../../ui/tree.zig");
const layout = @import("../../ui/layout.zig");
const Rect = @import("../file_header.zig").Rect;
pub const Part = enum(u8) { breadcrumb, modified, reload, previous, next };
pub const Model = struct { rect: Rect, identity: u64, parts: [5]?Rect = @splat(null) };
pub fn rootId(index: usize) u64 {
    return 0x4644000000000000 + @as(u64, @intCast(index)) * 0x100000000;
}
pub fn partId(index: usize, part: Part) u64 {
    return rootId(index) + 1 + @backingInt(part);
}
pub fn signature(models: []const Model, epoch: u64) u64 {
    var h = std.hash.Wyhash.init(epoch);
    for (models) |m| {
        const fields = [_]u64{ m.identity, m.rect.x, m.rect.y, m.rect.w, m.rect.h };
        h.update(std.mem.asBytes(&fields));
        for (m.parts, 0..) |r, i| {
            const v = [_]u64{ i, @intFromBool(r != null), if (r) |x| x.x else 0, if (r) |x| x.y else 0, if (r) |x| x.w else 0, if (r) |x| x.h else 0 };
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
            if (m.rect.w == 0 or m.rect.h == 0) continue;
            const parent = self.entries.items.len;
            // A zero-size group supplies hierarchy without inventing an empty
            // clickable area between the actual painted glyphs.
            try self.entries.append(a, .{ .id = rootId(mi), .parent_index = null, .kind = .container, .rect = .{}, .effective_clip = m.rect.ui(), .action = null, .semantics = .{ .role = .group, .label = "" } });
            for (m.parts, 0..) |maybe, i| if (maybe) |r| {
                const clipped = layout.intersectRect(r.ui(), m.rect.ui());
                if (clipped.width <= 0 or clipped.height <= 0) continue;
                const part: Part = @fromBackingInt(@intCast(i));
                const action = i >= @backingInt(Part.reload);
                try self.entries.append(a, .{ .id = partId(mi, part), .parent_index = parent, .kind = if (action) .button else .text, .rect = clipped, .effective_clip = m.rect.ui(), .action = if (action) .{ .id = partId(mi, part) } else null, .cursor = if (action) .press else .auto, .semantics = .{ .role = if (action) .button else .text, .label = "", .focusable = action } });
            };
        }
        self.stamp = stamp;
    }
};
test "inspector file header details preserve painted bounds roles pane identities and generations" {
    const a = std.testing.allocator;
    var f: Frame = .{};
    defer f.deinit(a);
    var m: Model = .{ .rect = .{ .x = 10, .y = 20, .w = 80, .h = 24 }, .identity = 42 };
    m.parts[0] = .{ .x = 0, .y = 20, .w = 50, .h = 24 };
    m.parts[1] = .{ .x = 70, .y = 20, .w = 10, .h = 24 };
    m.parts[2] = .{ .x = 80, .y = 20, .w = 20, .h = 24 };
    try f.publish(a, &.{ m, m }, 1);
    try std.testing.expectEqual(@as(usize, 8), f.entries.items.len);
    try std.testing.expectEqual(@as(f32, 10), f.entries.items[1].rect.x);
    try std.testing.expectEqual(@as(f32, 10), f.entries.items[3].rect.width);
    try std.testing.expect(f.entries.items[1].action == null and f.entries.items[2].action == null and f.entries.items[3].action != null);
    try std.testing.expectEqual(@as(?usize, 4), f.entries.items[7].parent_index);
    for (f.entries.items, 0..) |e, i| for (f.entries.items[i + 1 ..]) |other| try std.testing.expect(e.id != other.id);
    const inspect = @import("../../ui/inspection.zig");
    const old = inspect.identity(inspect.project(.file_header_details, f.snapshot(), 1, 0, 0));
    const g = f.generation;
    try f.publish(a, &.{ m, m }, 1);
    try std.testing.expectEqual(g, f.generation);
    m.identity += 1;
    try f.publish(a, &.{ m, m }, 1);
    try std.testing.expect(f.generation > g);
    try std.testing.expect(inspect.resolve(&.{inspect.project(.file_header_details, f.snapshot(), 1, 0, 0)}, old) == null);
    const g2 = f.generation;
    m.parts[1] = null;
    try f.publish(a, &.{m}, 1);
    try std.testing.expect(f.generation > g2 and f.snapshot().find(partId(0, .modified)) == null);
    const g3 = f.generation;
    try f.publish(a, &.{m}, 2);
    try std.testing.expect(f.generation > g3);
    m.rect.h = 0;
    try f.publish(a, &.{m}, 2);
    try std.testing.expectEqual(@as(usize, 0), f.entries.items.len);
}
test "inspector file header details discard partial allocation failure and recover" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const a = fail.allocator();
    var f: Frame = .{};
    defer f.deinit(a);
    const m: Model = .{ .rect = .{ .x = 0, .y = 0, .w = 80, .h = 24 }, .identity = 1, .parts = .{ .{ .x = 0, .y = 0, .w = 20, .h = 24 }, null, null, null, null } };
    try std.testing.expectError(error.OutOfMemory, f.publish(a, &.{ m, m, m, m, m }, 1));
    try std.testing.expect(f.stamp == null and f.entries.items.len == 0);
    fail.fail_index = std.math.maxInt(usize);
    try f.publish(a, &.{m}, 1);
    try std.testing.expectEqual(@as(usize, 2), f.entries.items.len);
}
