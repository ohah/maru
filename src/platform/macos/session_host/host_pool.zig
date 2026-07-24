//! 앱 프로세스가 old/current host를 동시에 유지하기 위한 host-id keyed owner.
//! Protocol 선택과 discovery 정책은 밖에 두고, heap-pinned adapter lifetime과 명시적 spawn host만 소유한다.

const std = @import("std");

pub fn HostPool(comptime Adapter: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            adapter: *Adapter,
            owned: bool,
            runtime_refs: usize = 0,
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
                std.debug.assert(entry.runtime_refs == 0);
                if (!entry.owned) continue;
                entry.adapter.deinit();
                self.allocator.destroy(entry.adapter);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// 성공하면 `adapter`의 소유권을 pool이 가져간다. 실패하면 caller가 계속 소유한다.
        pub fn addOwned(self: *Self, host_id: u128, adapter: *Adapter) !void {
            try validateInsert(self, host_id, adapter);
            try self.entries.put(self.allocator, host_id, .{ .adapter = adapter, .owned = true });
        }

        /// Adapter lifetime을 caller가 pool보다 길게 보장할 때만 사용한다.
        pub fn addBorrowed(self: *Self, host_id: u128, adapter: *Adapter) !void {
            try validateInsert(self, host_id, adapter);
            try self.entries.put(self.allocator, host_id, .{ .adapter = adapter, .owned = false });
        }

        fn validateInsert(self: *Self, host_id: u128, adapter: *Adapter) !void {
            if (host_id == 0 or self.entries.contains(host_id)) return error.DuplicateHost;
            // 실제 session Client/HostAdapter는 handshake에서 확정한 host_id를 1급 필드로 가진다. 외부 descriptor
            // key와 adapter identity가 다르면 pool에 잠시라도 잘못된 routing entry를 publish하지 않는다.
            if (comptime @hasField(Adapter, "host_id")) {
                if (@as(u128, @intCast(@field(adapter.*, "host_id"))) != host_id)
                    return error.HostIdentityMismatch;
            }
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

        pub fn spawnHostId(self: *const Self) ?u128 {
            return self.spawn_host_id;
        }

        pub fn retain(self: *Self, host_id: u128) !*Adapter {
            const entry = self.entries.getPtr(host_id) orelse return error.UnknownHost;
            entry.runtime_refs = std.math.add(usize, entry.runtime_refs, 1) catch return error.TooManyReferences;
            return entry.adapter;
        }

        pub fn release(self: *Self, host_id: u128) void {
            const entry = self.entries.getPtr(host_id) orelse unreachable;
            std.debug.assert(entry.runtime_refs > 0);
            entry.runtime_refs -= 1;
        }

        pub fn remove(self: *Self, host_id: u128) !bool {
            if (self.entries.get(host_id)) |entry| {
                if (entry.runtime_refs != 0) return error.HostInUse;
            } else return false;
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
    try std.testing.expect(try pool.remove(0xBB));
    try std.testing.expect(pool.spawnHost() == null);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "host pool refuses removal while a runtime lease is active" {
    const FakeAdapter = struct {
        deinit_count: *usize,
        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Pool = HostPool(FakeAdapter);
    var deinit_count: usize = 0;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    const adapter = try std.testing.allocator.create(FakeAdapter);
    adapter.* = .{ .deinit_count = &deinit_count };
    try pool.addOwned(1, adapter);
    try std.testing.expect(try pool.retain(1) == adapter);
    try std.testing.expectError(error.HostInUse, pool.remove(1));
    pool.release(1);
    try std.testing.expect(try pool.remove(1));
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

test "host pool rejects a descriptor key that differs from adapter handshake host id" {
    const FakeAdapter = struct {
        host_id: u128,
        deinit_count: *usize,
        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Pool = HostPool(FakeAdapter);
    var deinit_count: usize = 0;
    var adapter: FakeAdapter = .{ .host_id = 0xAA, .deinit_count = &deinit_count };
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    try std.testing.expectError(error.HostIdentityMismatch, pool.addBorrowed(0xBB, &adapter));
    try std.testing.expect(pool.get(0xBB) == null);
    try pool.addBorrowed(0xAA, &adapter);
}
