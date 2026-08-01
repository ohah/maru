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
            adapter_generation: u64,
        };

        allocator: std.mem.Allocator,
        entries: std.AutoHashMapUnmanaged(u128, Entry) = .empty,
        spawn_host_id: ?u128 = null,
        adapter_generation: u64 = 1,
        adapter_generation_exhausted: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var values = self.entries.valueIterator();
            while (values.next()) |entry| {
                if (entry.runtime_refs != 0)
                    @panic("session host pool deinit while runtime leases are active");
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
            const generation = try self.nextAdapterGeneration();
            try self.entries.put(self.allocator, host_id, .{
                .adapter = adapter,
                .owned = true,
                .adapter_generation = generation,
            });
            self.adapter_generation = generation;
        }

        /// 같은 `host_id`의 owned adapter를 새 것으로 **원자적으로** 교체하고 옛 adapter를 돌려준다. 연결이
        /// 무효화된 host를 다시 붙일 때 쓴다(§7 사용 중 연결이 끊겼을 때의 재연결).
        ///
        /// `remove` + `addOwned`로 쪼개면 안 되는 이유: 그 사이 `addOwned`가 실패하면 옛 adapter는 이미
        /// 해제됐는데 새 것은 등록되지 않아 host 슬롯이 통째로 사라지고, 그 host의 runtime들은 해제된
        /// `Client`를 가리킨 채 남는다(use-after-free). 여기서는 기존 entry를 제자리에서 고쳐 쓰므로 할당이
        /// 없고 따라서 실패 지점도 없다. `runtime_refs`와 `spawn_host_id`도 그대로 유지된다 — 교체는 참조
        /// 관계를 바꾸지 않는다.
        ///
        /// 돌려받은 옛 adapter는 **재부착을 모두 끝낸 뒤** `destroyReplaced`로 해제한다. 먼저 해제하면 아직
        /// 옛 연결을 참조하는 runtime이 dangling된다.
        pub fn replaceOwned(self: *Self, host_id: u128, adapter: *Adapter) !*Adapter {
            if (self.adapter_generation_exhausted) return error.AdapterGenerationExhausted;
            if (host_id == 0) return error.UnknownHost;
            if (comptime @hasDecl(Adapter, "hostId")) {
                if (adapter.hostId() != host_id) return error.HostIdentityMismatch;
            }
            const entry = self.entries.getPtr(host_id) orelse return error.UnknownHost;
            // borrowed adapter는 수명을 caller가 쥐고 있으므로 pool이 교체·해제를 대신할 수 없다.
            if (!entry.owned) return error.BorrowedHost;
            const generation = try self.nextAdapterGeneration();
            const previous = entry.adapter;
            entry.adapter = adapter;
            entry.adapter_generation = generation;
            self.adapter_generation = generation;
            return previous;
        }

        /// `replaceOwned`가 돌려준 옛 adapter를 해제한다. pool이 소유했던 메모리이므로 **pool의 allocator로**
        /// 반납해야 한다 — caller의 allocator와 같다는 보장이 없다.
        pub fn destroyReplaced(self: *Self, adapter: *Adapter) void {
            adapter.deinit();
            self.allocator.destroy(adapter);
        }

        /// 연결이 무효화된 host를 찾는다(없으면 null). **runtime이 하나도 없는 host도 포함해야 한다** — pane을
        /// 모두 닫았지만 pool에 남아 있는 host의 연결이 죽으면, 그 host로 새 pane을 spawn할 때 비로소
        /// `ConnectionClosed`로 실패한다. runtime 목록에서 host 건강을 유도하면 그 경우를 영영 놓친다.
        pub fn degradedHostId(self: *Self) ?u128 {
            if (!@hasDecl(Adapter, "logicalClient")) return null;
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.adapter.logicalClient().isDegraded()) return entry.key_ptr.*;
            }
            return null;
        }

        /// Adapter lifetime을 caller가 pool보다 길게 보장할 때만 사용한다.
        pub fn addBorrowed(self: *Self, host_id: u128, adapter: *Adapter) !void {
            try validateInsert(self, host_id, adapter);
            const generation = try self.nextAdapterGeneration();
            try self.entries.put(self.allocator, host_id, .{
                .adapter = adapter,
                .owned = false,
                .adapter_generation = generation,
            });
            self.adapter_generation = generation;
        }

        fn validateInsert(self: *Self, host_id: u128, adapter: *Adapter) !void {
            if (self.adapter_generation_exhausted) return error.AdapterGenerationExhausted;
            if (host_id == 0 or self.entries.contains(host_id)) return error.DuplicateHost;
            // 실제 session Client/HostAdapter는 handshake에서 확정한 host_id를 1급 필드로 가진다. 외부 descriptor
            // key와 adapter identity가 다르면 pool에 잠시라도 잘못된 routing entry를 publish하지 않는다.
            if (comptime @hasDecl(Adapter, "hostId")) {
                if (adapter.hostId() != host_id)
                    return error.HostIdentityMismatch;
            } else if (comptime @hasField(Adapter, "host_id")) {
                @compileError("session host pool adapters with identity must expose hostId(); raw host_id fields are not a stable adapter contract");
            }
        }

        fn nextAdapterGeneration(self: *const Self) !u64 {
            return std.math.add(u64, self.adapter_generation, 1) catch
                error.AdapterGenerationExhausted;
        }

        pub fn get(self: *Self, host_id: u128) ?*Adapter {
            const entry = self.entries.get(host_id) orelse return null;
            return entry.adapter;
        }

        pub fn adapterGeneration(self: *const Self, host_id: u128) ?u64 {
            return (self.entries.get(host_id) orelse return null).adapter_generation;
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
            if (entry.runtime_refs == 0)
                @panic("session host runtime lease released more than once");
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
            if (self.adapter_generation == std.math.maxInt(u64)) {
                self.adapter_generation_exhausted = true;
            } else {
                self.adapter_generation += 1;
            }
            return true;
        }
    };
}

test "host pool: adapter 원자적 교체가 lease와 spawn host를 보존한다" {
    // 무효화된 연결을 갈아끼울 때 `remove` + `addOwned`로 쪼개면, 그 사이 addOwned 실패가 host 슬롯을 통째로
    // 잃게 하고 그 host의 runtime들은 이미 해제된 Client를 가리킨 채 남는다(use-after-free). 교체는 참조 관계를
    // 바꾸지 않으므로 lease와 spawn host가 그대로 살아 있어야 한다.
    const FakeAdapter = struct {
        id: u8,
        deinit_count: *usize,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Pool = HostPool(FakeAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();

    var deinits: usize = 0;
    const first = try allocator.create(FakeAdapter);
    first.* = .{ .id = 1, .deinit_count = &deinits };
    try pool.addOwned(7, first);
    try pool.setSpawnHost(7);
    _ = try pool.retain(7); // runtime 하나가 이 host를 참조하는 중이다.
    const generation_before = pool.adapterGeneration(7).?;

    const second = try allocator.create(FakeAdapter);
    second.* = .{ .id = 2, .deinit_count = &deinits };
    const previous = try pool.replaceOwned(7, second);

    try std.testing.expectEqual(@as(u8, 1), previous.id);
    try std.testing.expectEqual(@as(u8, 2), pool.get(7).?.id);
    // lease가 살아 있어야 재부착 후 균형이 맞는다. spawn host가 비면 새 pane spawn이 막힌다.
    try std.testing.expectEqual(@as(?u128, 7), pool.spawnHostId());
    try std.testing.expect(pool.adapterGeneration(7).? > generation_before);
    // 옛 adapter는 **재부착이 끝난 뒤** caller가 해제한다 — 교체 시점에 해제하면 재부착 대상이 dangling된다.
    try std.testing.expectEqual(@as(usize, 0), deinits);
    pool.destroyReplaced(previous);
    try std.testing.expectEqual(@as(usize, 1), deinits);

    pool.release(7);
}

test "host pool: 없는 host나 borrowed adapter는 교체하지 않는다" {
    const FakeAdapter = struct {
        id: u8,
        deinit_count: *usize,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Pool = HostPool(FakeAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();

    var deinits: usize = 0;
    var replacement: FakeAdapter = .{ .id = 9, .deinit_count = &deinits };
    try std.testing.expectError(error.UnknownHost, pool.replaceOwned(7, &replacement));

    // borrowed는 수명을 caller가 쥐고 있어 pool이 교체·해제를 대신할 수 없다.
    var borrowed: FakeAdapter = .{ .id = 1, .deinit_count = &deinits };
    try pool.addBorrowed(7, &borrowed);
    try std.testing.expectError(error.BorrowedHost, pool.replaceOwned(7, &replacement));
    try std.testing.expectEqual(@as(u8, 1), pool.get(7).?.id); // 실패는 pool을 바꾸지 않는다.
    try std.testing.expectEqual(@as(usize, 0), deinits);
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
    const first_generation = pool.adapterGeneration(0xAA).?;
    const pinned_first = pool.get(0xAA).?;

    const second = try std.testing.allocator.create(FakeAdapter);
    errdefer std.testing.allocator.destroy(second);
    second.* = .{ .id = 2, .deinit_count = &deinit_count };
    try pool.addOwned(0xBB, second);
    try std.testing.expect(pool.adapterGeneration(0xBB).? > first_generation);

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

test "host pool reconnect gets a fresh adapter generation and overflow fail-closes new publication" {
    const FakeAdapter = struct {
        fn deinit(_: *@This()) void {}
    };
    const Pool = HostPool(FakeAdapter);
    var first: FakeAdapter = .{};
    var second: FakeAdapter = .{};
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    try pool.addBorrowed(1, &first);
    const before = pool.adapterGeneration(1).?;
    try std.testing.expect(try pool.remove(1));
    try pool.addBorrowed(1, &second);
    try std.testing.expect(pool.adapterGeneration(1).? > before);
    try std.testing.expect(try pool.remove(1));
    pool.adapter_generation = std.math.maxInt(u64);
    pool.adapter_generation_exhausted = true;
    try std.testing.expectError(error.AdapterGenerationExhausted, pool.addBorrowed(1, &first));
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
        fn hostId(self: *const @This()) u128 {
            return self.host_id;
        }
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
