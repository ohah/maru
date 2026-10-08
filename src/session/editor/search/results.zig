//! 파일별 결과 표시 모델. 행 소유권과 문서 신원은 UI가 아니라 요청 모델이 유지한다.
const std = @import("std");
const request = @import("request.zig");
pub const Visible = union(enum) { file: usize, hit: struct { row: usize, range: usize } };
pub const Group = struct {
    root_index: usize,
    path: []const u8,
    source: request.Source,
    rows: std.ArrayList(usize) = .empty,
    matches: usize = 0,
    collapsed: bool = false,
};
pub const Model = struct {
    rows: std.ArrayList(request.Row) = .empty,
    groups: std.ArrayList(Group) = .empty,
    keys: std.StringHashMapUnmanaged(usize) = .{},
    visible: std.ArrayList(Visible) = .empty,
    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        for (self.groups.items) |*group| group.rows.deinit(a);
        self.groups.deinit(a);
        var keys = self.keys.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.keys.deinit(a);
        for (self.rows.items) |*row| row.match.deinit(a);
        self.rows.deinit(a);
        self.visible.deinit(a);
        self.* = .{};
    }
    /// 실패해도 caller의 row는 그대로다. 모든 capacity를 예약한 뒤에만 소유권을 받는다.
    pub fn append(self: *Model, a: std.mem.Allocator, row: request.Row) !void {
        const key = switch (row.source) {
            .disk => try std.fmt.allocPrint(a, "{d}:disk:{s}", .{ row.root_index, row.match.path }),
            .model => |s| try std.fmt.allocPrint(a, "{d}:model:{d}:{d}:{d}:{d}:{d}:{s}", .{ row.root_index, s.document.owner, s.document.slot, s.document.generation, s.revision, s.composition, row.match.path }),
        };
        errdefer a.free(key);
        try self.rows.ensureUnusedCapacity(a, 1);
        if (self.keys.get(key)) |index| {
            try self.groups.items[index].rows.ensureUnusedCapacity(a, 1);
            a.free(key);
            self.groups.items[index].rows.appendAssumeCapacity(self.rows.items.len);
            self.groups.items[index].matches += row.match.ranges.len;
        } else {
            try self.groups.ensureUnusedCapacity(a, 1);
            try self.keys.ensureUnusedCapacity(a, 1);
            var indices: std.ArrayList(usize) = .empty;
            errdefer indices.deinit(a);
            try indices.ensureUnusedCapacity(a, 1);
            indices.appendAssumeCapacity(self.rows.items.len);
            self.keys.putAssumeCapacity(key, self.groups.items.len);
            self.groups.appendAssumeCapacity(.{ .root_index = row.root_index, .path = row.match.path, .source = row.source, .rows = indices, .matches = row.match.ranges.len });
        }
        self.rows.appendAssumeCapacity(row);
    }
    /// 행이 바뀔 때만 표시 인덱스를 다시 만든다. 그리기는 보이는 창만 투영한다.
    pub fn rebuild(self: *Model, a: std.mem.Allocator) !void {
        var count = self.groups.items.len;
        for (self.groups.items) |group| if (!group.collapsed) for (group.rows.items) |index| {
            count += self.rows.items[index].match.ranges.len;
        };
        try self.visible.ensureTotalCapacity(a, count);
        self.visible.clearRetainingCapacity();
        for (self.groups.items, 0..) |group, index| {
            self.visible.appendAssumeCapacity(.{ .file = index });
            if (!group.collapsed) for (group.rows.items) |row| for (0..self.rows.items[row].match.ranges.len) |range| {
                self.visible.appendAssumeCapacity(.{ .hit = .{ .row = row, .range = range } });
            };
        }
    }
};

fn sample(a: std.mem.Allocator, source: request.Source, root: usize) !request.Row {
    const path = try a.dupe(u8, "a.zig");
    errdefer a.free(path);
    const text = try a.dupe(u8, "foo");
    errdefer a.free(text);
    const ranges = try a.alloc(@import("event.zig").Range, 1);
    ranges[0] = .{ .start = .{ .line = 0, .byte = 0 }, .end = .{ .line = 0, .byte = 3 } };
    return .{ .root_index = root, .source = source, .match = .{ .path = path, .text = text, .ranges = ranges } };
}
test "project search dock groups disk rows but keeps independent documents and roots separate" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    try model.append(a, try sample(a, .disk, 0));
    try model.append(a, try sample(a, .disk, 0));
    try model.append(a, try sample(a, .disk, 1));
    const one: request.Source = .{ .model = .{ .document = .{ .owner = 1, .slot = 0, .generation = 1 }, .revision = 1, .composition = 0 } };
    const two: request.Source = .{ .model = .{ .document = .{ .owner = 2, .slot = 0, .generation = 1 }, .revision = 1, .composition = 0 } };
    try model.append(a, try sample(a, one, 0));
    try model.append(a, try sample(a, two, 0));
    try model.rebuild(a);
    try std.testing.expectEqual(@as(usize, 4), model.groups.items.len);
    try std.testing.expectEqual(@as(usize, 9), model.visible.items.len);
    model.groups.items[0].collapsed = true;
    try model.rebuild(a);
    try std.testing.expectEqual(@as(usize, 7), model.visible.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.groups.items[0].matches);
}
fn failureCase(a: std.mem.Allocator) !void {
    var model: Model = .{};
    defer model.deinit(a);
    for (0..40) |index| {
        var row = try sample(a, .disk, index / 20);
        model.append(a, row) catch |err| {
            row.match.deinit(a);
            return err;
        };
    }
    try model.rebuild(a);
}
test "project search dock allocation failure preserves caller ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failureCase, .{});
}
