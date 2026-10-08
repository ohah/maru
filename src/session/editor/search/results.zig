//! 파일별 결과 표시 모델. 행 소유권과 문서 신원은 UI가 아니라 요청 모델이 유지한다.
const std = @import("std");
const request = @import("request.zig");
pub const Visible = union(enum) { file: usize, hit: struct { row: usize, range: usize } };
pub const Window = struct { items: []const Visible, first: usize, shift: u32, offset: u32, content_height: u32, max_offset: u32 };
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
    matches: usize = 0,
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
        const path = try request.relativePath(row.match.path);
        const key = switch (row.source) {
            .disk => try std.fmt.allocPrint(a, "{d}:disk:{s}", .{ row.root_index, path }),
            .model => |s| try std.fmt.allocPrint(a, "{d}:model:{d}:{d}:{d}:{d}:{d}:{s}", .{ row.root_index, s.document.owner, s.document.slot, s.document.generation, s.revision, s.composition, path }),
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
        self.matches += row.match.ranges.len;
    }
    /// 전체 결과가 아니라 viewport와 겹치는 인덱스 창을 반환한다. 입력과 그리기가 같은 창을 쓴다.
    pub fn window(self: *const Model, row_height: u32, viewport: u32, requested_offset: u32) Window {
        const height = @max(row_height, 1);
        const content: u32 = @intCast(@min(@as(u64, self.visible.items.len) *| height, std.math.maxInt(u32)));
        const maximum = content -| viewport;
        const offset = @min(requested_offset, maximum);
        const shift = offset % height;
        const first = @min(@as(usize, offset / height), self.visible.items.len);
        const count = if (viewport == 0) 0 else (@as(u64, viewport) + shift + height - 1) / height;
        const end = @min(first + @as(usize, @intCast(count)), self.visible.items.len);
        return .{ .items = self.visible.items[first..end], .first = first, .shift = shift, .offset = offset, .content_height = content, .max_offset = maximum };
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

test "project search dock equivalent relative paths share the same file group" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    try model.append(a, try sample(a, .disk, 0));
    var row = try sample(a, .disk, 0);
    a.free(row.match.path);
    row.match.path = try a.dupe(u8, "./a.zig");
    try model.append(a, row);
    try model.rebuild(a);
    try std.testing.expectEqual(@as(usize, 1), model.groups.items.len);
    try std.testing.expectEqual(@as(usize, 3), model.visible.items.len);
}

test "project search dock all document identity dimensions preserve independent groups" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    const base: request.Source = .{ .model = .{ .document = .{ .owner = 1, .slot = 2, .generation = 3 }, .revision = 4, .composition = 5 } };
    try model.append(a, try sample(a, base, 0));
    for (0..5) |dimension| {
        var changed = base;
        switch (dimension) {
            0 => changed.model.document.owner += 1,
            1 => changed.model.document.slot += 1,
            2 => changed.model.document.generation += 1,
            3 => changed.model.revision += 1,
            4 => changed.model.composition += 1,
            else => unreachable,
        }
        try model.append(a, try sample(a, changed, 0));
    }
    try model.append(a, try sample(a, base, 1));
    try model.append(a, try sample(a, base, 0));
    try model.rebuild(a);
    try std.testing.expectEqual(@as(usize, 7), model.groups.items.len);
    try std.testing.expectEqual(@as(usize, 15), model.visible.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.groups.items[0].matches);
}
test "project search dock invalid relative paths retain caller row ownership" {
    const a = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(a);
    for ([_][]const u8{ "../a.zig", "/a.zig", "a//b", "a/../b", "" }) |path| {
        var row = try sample(a, .disk, 0);
        a.free(row.match.path);
        row.match.path = try a.dupe(u8, path);
        defer row.match.deinit(a);
        try std.testing.expectError(error.InvalidPath, model.append(a, row));
    }
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);
}

test "project search dock twenty thousand matches project only a viewport and release all retained memory" {
    for ([_]std.mem.Allocator{ std.testing.allocator, std.heap.smp_allocator }, 0..) |base, allocator_case| {
        var measured = std.testing.FailingAllocator.init(base, .{});
        const a = measured.allocator();
        var model: Model = .{};
        defer model.deinit(a);
        const started = std.Io.Timestamp.now(std.testing.io, .awake);
        for (0..20_000) |index| {
            var row = try sample(a, .disk, 0);
            a.free(row.match.path);
            row.match.path = try std.fmt.allocPrint(a, "file-{d}.zig", .{index});
            try model.append(a, row);
        }
        const append_ns = started.untilNow(std.testing.io, .awake).nanoseconds;
        const rebuilding = std.Io.Timestamp.now(std.testing.io, .awake);
        try model.rebuild(a);
        const rebuild_ns = rebuilding.untilNow(std.testing.io, .awake).nanoseconds;
        try std.testing.expectEqual(@as(usize, 40_000), model.visible.items.len);
        const retained = measured.allocated_bytes - measured.freed_bytes;
        const allocations_before = measured.allocations;
        for ([_]u32{ 28, 35, 56 }) |height| for ([_]u32{ 0, 1, 300, 800 }) |viewport| for ([_]u32{ 0, 11, 28, 500, std.math.maxInt(u32) }) |offset| {
            const window = model.window(height, viewport, offset);
            try std.testing.expect(window.offset <= window.max_offset);
            try std.testing.expect(window.items.len <= (@as(u64, viewport) + height - 1) / height + 1);
            try std.testing.expectEqual(model.visible.items[window.first .. window.first + window.items.len].ptr, window.items.ptr);
            if (viewport == 0) try std.testing.expectEqual(@as(usize, 0), window.items.len);
            if (window.items.len != 0) {
                try std.testing.expect(@as(u64, window.first) * height <= window.offset);
                try std.testing.expect(@as(u64, window.first + window.items.len) * height >= @min(@as(u64, window.content_height), @as(u64, window.offset) + viewport));
            }
        };
        try std.testing.expectEqual(allocations_before, measured.allocations);
        const freeing = std.Io.Timestamp.now(std.testing.io, .awake);
        model.deinit(a);
        const free_ns = freeing.untilNow(std.testing.io, .awake).nanoseconds;
        try std.testing.expectEqual(measured.allocated_bytes, measured.freed_bytes);
        std.debug.print("search-dock-model allocator={s} count=20000 retained_bytes={d} append_ns={d} rebuild_ns={d} free_ns={d} window_allocations=0\n", .{ if (allocator_case == 0) "testing" else "smp", retained, append_ns, rebuild_ns, free_ns });
    }
}
