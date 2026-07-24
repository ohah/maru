//! 앱 프로세스가 old/current host를 동시에 유지하기 위한 host-id keyed owner.
//! Protocol 선택과 discovery 정책은 밖에 두고, heap-pinned adapter lifetime과 명시적 spawn host만 소유한다.

const std = @import("std");

pub fn HostPool(comptime Adapter: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            adapter: *Adapter,
            owned: bool,
        };

        allocator: std.mem.Allocator,
        entries: std.AutoHashMapUnmanaged(u128, Entry) = .empty,
        spawn_host_id: ?u128 = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var values = self.entries.valueIterator();
            while (values.next()) |entry| {
                if (!entry.owned) continue;
                entry.adapter.deinit();
                self.allocator.destroy(entry.adapter);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// 성공하면 `adapter`의 소유권을 pool이 가져간다. 실패하면 caller가 계속 소유한다.
        pub fn addOwned(self: *Self, host_id: u128, adapter: *Adapter) !void {
            if (host_id == 0 or self.entries.contains(host_id)) return error.DuplicateHost;
            try self.entries.put(self.allocator, host_id, .{ .adapter = adapter, .owned = true });
        }

        /// Adapter lifetime을 caller가 pool보다 길게 보장할 때만 사용한다.
        pub fn addBorrowed(self: *Self, host_id: u128, adapter: *Adapter) !void {
            if (host_id == 0 or self.entries.contains(host_id)) return error.DuplicateHost;
            try self.entries.put(self.allocator, host_id, .{ .adapter = adapter, .owned = false });
        }

        pub fn get(self: *Self, host_id: u128) ?*Adapter {
            const entry = self.entries.get(host_id) orelse return null;
            return entry.adapter;
        }

        pub fn setSpawnHost(self: *Self, host_id: u128) !void {
            if (!self.entries.contains(host_id)) return error.UnknownHost;
            self.spawn_host_id = host_id;
        }

        pub fn spawnHost(self: *Self) ?*Adapter {
            return self.get(self.spawn_host_id orelse return null);
        }

        pub fn remove(self: *Self, host_id: u128) bool {
            const removed = self.entries.fetchRemove(host_id) orelse return false;
            if (removed.value.owned) {
                removed.value.adapter.deinit();
                self.allocator.destroy(removed.value.adapter);
            }
            if (self.spawn_host_id == host_id) self.spawn_host_id = null;
            return true;
        }
    };
}

test "host pool pins two hosts and selects spawn host explicitly" {
    const FakeAdapter = struct {
        id: u8,
        deinit_count: *usize,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Pool = HostPool(FakeAdapter);
    var deinit_count: usize = 0;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const first = try std.testing.allocator.create(FakeAdapter);
    errdefer std.testing.allocator.destroy(first);
    first.* = .{ .id = 1, .deinit_count = &deinit_count };
    try pool.addOwned(0xAA, first);
    const pinned_first = pool.get(0xAA).?;

    const second = try std.testing.allocator.create(FakeAdapter);
    errdefer std.testing.allocator.destroy(second);
    second.* = .{ .id = 2, .deinit_count = &deinit_count };
    try pool.addOwned(0xBB, second);

    try std.testing.expect(pool.get(0xAA).? == pinned_first);
    try std.testing.expectEqual(@as(u8, 1), pool.get(0xAA).?.id);
    try std.testing.expectEqual(@as(u8, 2), pool.get(0xBB).?.id);
    try std.testing.expectError(error.DuplicateHost, pool.addOwned(0xAA, second));
    try std.testing.expectError(error.UnknownHost, pool.setSpawnHost(0xCC));
    try pool.setSpawnHost(0xBB);
    try std.testing.expect(pool.spawnHost().? == second);
    try std.testing.expect(pool.remove(0xBB));
    try std.testing.expect(pool.spawnHost() == null);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "host pool never deinitializes a borrowed adapter" {
    const FakeAdapter = struct {
        deinit_count: *usize,
        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Pool = HostPool(FakeAdapter);
    var deinit_count: usize = 0;
    var borrowed: FakeAdapter = .{ .deinit_count = &deinit_count };
    {
        var pool = Pool.init(std.testing.allocator);
        try pool.addBorrowed(1, &borrowed);
        pool.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), deinit_count);
}
