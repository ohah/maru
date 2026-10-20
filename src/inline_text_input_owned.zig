//! Allocation and deep snapshots for an unbounded inline IME projection.
//! Edit/range semantics stay in inline_text_input; reserve never publishes partial storage.
const std = @import("std");
const model = @import("inline_text_input.zig");
pub const OwnedContext = struct {
    value: model.DynamicContext = .{},
    allocation: []u8 = &.{},

    pub fn deinit(self: *OwnedContext, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
        self.* = .{};
    }

    pub fn reserve(self: *OwnedContext, allocator: std.mem.Allocator, query: usize, marked: usize) !void {
        if (query <= self.value.base.len and marked <= self.value.storage.len - self.value.base.len) return;
        const q = grow(self.value.base.len, query);
        const m = grow(self.value.storage.len - self.value.base.len, marked);
        const projected = try std.math.add(usize, q, m);
        const twice_q = try std.math.mul(usize, q, 2);
        const twice_projected = try std.math.mul(usize, projected, 2);
        const total = try std.math.add(usize, twice_q, twice_projected);
        const allocation = try allocator.alloc(u8, total);
        // Allocate every slice together before retiring old pointers. Metadata and
        // committed bytes survive allocation failure and a successful relocation.
        var next = self.value;
        next.base = allocation[0..q];
        next.committed = allocation[q..][0..q];
        next.storage = allocation[twice_q..][0..projected];
        next.scratch = allocation[twice_q + projected ..][0..projected];
        @memcpy(next.base[0..next.base_len], self.value.base[0..next.base_len]);
        @memcpy(next.committed[0..next.committed_len], self.value.committed[0..next.committed_len]);
        @memcpy(next.storage[0..next.len], self.value.storage[0..next.len]);
        allocator.free(self.allocation);
        self.* = .{ .value = next, .allocation = allocation };
    }

    pub fn clone(self: *const OwnedContext, allocator: std.mem.Allocator) !OwnedContext {
        var result: OwnedContext = .{};
        errdefer result.deinit(allocator);
        try result.reserve(allocator, self.value.base.len, self.value.storage.len - self.value.base.len);
        const storage = result.value;
        result.value = self.value;
        result.value.base = storage.base;
        result.value.committed = storage.committed;
        result.value.storage = storage.storage;
        result.value.scratch = storage.scratch;
        @memcpy(result.value.base[0..self.value.base_len], self.value.base[0..self.value.base_len]);
        @memcpy(result.value.committed[0..self.value.committed_len], self.value.committed[0..self.value.committed_len]);
        @memcpy(result.value.storage[0..self.value.len], self.value.storage[0..self.value.len]);
        return result;
    }

    fn grow(current: usize, required: usize) usize {
        if (required <= current) return current;
        return @max(required, @max(32, std.math.mul(usize, current, 2) catch required));
    }
};

test "owned inline context preserves long query and UTF16 replacement" {
    var owned: OwnedContext = .{};
    defer owned.deinit(std.testing.allocator);
    var query: [1024]u8 = undefined;
    @memset(&query, 'x');
    try owned.reserve(std.testing.allocator, 2048, 1024);
    try std.testing.expect(owned.value.reset(&query, ""));
    try std.testing.expect(owned.value.insert("😀한", null));
    try std.testing.expectEqual(@as(?u64, 1027), if (owned.value.selectedRange()) |r| r.location else null);
    try std.testing.expect(owned.value.setMarked("韓", .{ .location = 1, .length = 0 }, .{ .location = 1026, .length = 1 }));
    try std.testing.expectEqualStrings("韓", owned.value.preedit());
}

test "owned inline context snapshot is independent across edits and relocation" {
    var owned: OwnedContext = .{};
    defer owned.deinit(std.testing.allocator);
    try owned.reserve(std.testing.allocator, 32, 32);
    try std.testing.expect(owned.value.reset("keep", "한"));
    var before = try owned.clone(std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    try std.testing.expect(owned.value.insert("韓", null));
    try owned.reserve(std.testing.allocator, 4096, 4096);
    try std.testing.expectEqualStrings("keep韓", owned.value.text());
    var committed: [7]u8 = undefined;
    owned.value.copyCommitted(&committed);
    try std.testing.expectEqualStrings("keep韓", &committed);
    try std.testing.expectEqualStrings("keep한", before.value.text());
    try std.testing.expectEqualStrings("한", before.value.preedit());
}

test "owned inline context reserve and clone allocation failure preserve the original" {
    var owned: OwnedContext = .{};
    defer owned.deinit(std.testing.allocator);
    try owned.reserve(std.testing.allocator, 32, 32);
    try std.testing.expect(owned.value.reset("keep", "한"));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, owned.reserve(failing.allocator(), 4096, 4096));
    try std.testing.expectEqualStrings("keep한", owned.value.text());
    try std.testing.expectError(error.OutOfMemory, owned.clone(failing.allocator()));
    try std.testing.expectEqualStrings("keep한", owned.value.text());
    try owned.reserve(std.testing.allocator, 4096, 4096);
    try std.testing.expect(owned.value.insert("韓", null));
    try std.testing.expectEqualStrings("keep韓", owned.value.text());
}

test "owned inline context preserves aliased replacement and surrogate rejection" {
    var owned: OwnedContext = .{};
    defer owned.deinit(std.testing.allocator);
    try owned.reserve(std.testing.allocator, 32, 32);
    try std.testing.expect(owned.value.reset("a😀z", ""));
    try std.testing.expect(!owned.value.insert("bad", .{ .location = 2, .length = 0 }));
    try std.testing.expectEqualStrings("a😀z", owned.value.text());
    const alias = owned.value.text()[1..5];
    try std.testing.expect(owned.value.insert(alias, .{ .location = 4, .length = 0 }));
    try std.testing.expectEqualStrings("a😀z😀", owned.value.text());
}

test "owned inline context rejects capacity overflow without changing bytes" {
    var owned: OwnedContext = .{};
    defer owned.deinit(std.testing.allocator);
    try owned.reserve(std.testing.allocator, 32, 32);
    try std.testing.expect(owned.value.reset("keep", ""));
    try std.testing.expectError(error.Overflow, owned.reserve(std.testing.allocator, std.math.maxInt(usize), 1));
    try std.testing.expectEqualStrings("keep", owned.value.text());
}
