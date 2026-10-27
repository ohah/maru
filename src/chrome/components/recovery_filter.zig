//! Recovery search comparison and selected-row identity. No catalog, filesystem or host dependency.
const std = @import("std");
const grapheme = @import("../../grapheme.zig");
pub const Plan = struct {
    query: []u8,
    shown: std.ArrayList(usize) = .empty,
    selected: ?usize = null,
    pub fn init(a: std.mem.Allocator, count: usize, raw_query: []const u8) !Plan {
        var plan: Plan = .{ .query = try grapheme.composeHangul(a, raw_query) };
        errdefer plan.deinit(a);
        try plan.shown.ensureTotalCapacity(a, count);
        return plan;
    }
    pub fn deinit(self: *Plan, a: std.mem.Allocator) void {
        a.free(self.query);
        self.shown.deinit(a);
    }
    /// Call once per candidate; capacity was prepared for the complete source.
    /// The query stays raw in its input owner: composition applies only to comparison.
    pub fn consider(self: *Plan, index: usize, name: []const u8, label: []const u8, excluded: bool, selected_name: []const u8) void {
        if (excluded) return;
        if (self.query.len > 0 and std.ascii.findIgnoreCase(label, self.query) == null and std.ascii.findIgnoreCase(name, self.query) == null) return;
        if (selected_name.len > 0 and std.mem.eql(u8, name, selected_name)) self.selected = self.shown.items.len;
        self.shown.appendAssumeCapacity(index);
    }
};

test "recovery picker IME model NFD comparison leaves input bytes intact" {
    const a = std.testing.allocator;
    const raw = "한";
    var p = try Plan.init(a, 3, raw);
    defer p.deinit(a);
    p.consider(0, "first", "/tmp/한.txt", false, "first");
    p.consider(1, "second", "/tmp/한.txt", true, "first");
    p.consider(2, "third", "/tmp/韓.txt", false, "first");
    try std.testing.expectEqualStrings("한", raw);
    try std.testing.expectEqualStrings("한", p.query);
    try std.testing.expectEqualSlices(usize, &.{0}, p.shown.items);
    try std.testing.expectEqual(@as(?usize, 0), p.selected);
}

test "recovery picker IME model matches names ASCII fold and remaps selected identity" {
    const a = std.testing.allocator;
    var p = try Plan.init(a, 3, "bak");
    defer p.deinit(a);
    p.consider(0, "none", "label", false, "c.BAK");
    p.consider(1, "b.bak", "label", false, "c.BAK");
    p.consider(2, "c.BAK", "label", false, "c.BAK");
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, p.shown.items);
    try std.testing.expectEqual(@as(?usize, 1), p.selected);
}

test "recovery picker IME model preparation unwinds every allocation failure" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            var p = try Plan.init(a, 50, "한");
            defer p.deinit(a);
            p.consider(0, "a.bak", "한", false, "");
            try std.testing.expectEqualSlices(usize, &.{0}, p.shown.items);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
