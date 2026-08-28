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

        pub const AdapterSnapshot = struct {
            adapter: *Adapter,
            adapter_generation: u64,
        };

        allocator: std.mem.Allocator,
        entries: std.AutoHashMapUnmanaged(u128, Entry) = .empty,
        spawn_host_id: ?u128 = null,
        adapter_generation: u64 = 1,
        adapter_generation_exhausted: bool = false,
        owner_state: std.atomic.Value(u8) = .init(0),
        owner_addr: usize = 0,
        owner_pid: u32 = 0,
        owner_process_nonce: u64 = 0,
        owner_thread_id: u64 = 0,
        active_publication: ActivePublication = .{},

        const ActivePublicationLifecycle = enum(u8) { inactive, preparing, prepared };
        const PublicationIdentity = struct { pid: u32, process_nonce: u64 };
        const ActivePublication = struct {
            pool_addr: usize = 0,
            pid: u32 = 0,
            process_nonce: u64 = 0,
            thread_id: u64 = 0,
            permit_addr: usize = 0,
            host_id: u128 = 0,
            adapter_addr: usize = 0,
            adapter_generation: u64 = 0,
            lifecycle: ActivePublicationLifecycle = .inactive,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.requireOwner();
            if (self.active_publication.permit_addr != 0)
                @panic("session host pool deinit while publication is active");
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
            if (!@import("builtin").is_test) return error.ManagedPublicationRequired;
            try self.ensureOwner();
            try validateInsert(self, host_id, adapter);
            const generation = try self.nextAdapterGeneration();
            try self.entries.put(self.allocator, host_id, .{
                .adapter = adapter,
                .owned = true,
                .adapter_generation = generation,
            });
            self.adapter_generation = generation;
        }

        /// semantic row를 게시하기 전에 capacity와 exact adapter generation을 final-address permit에 봉인한다.
        pub fn prepareOwnedPublication(
            self: *Self,
            host_id: u128,
            adapter: *Adapter,
            permit_out: anytype,
        ) !void {
            if (!@import("builtin").is_test) return error.ManagedPublicationRequired;
            return self.prepareOwnedPublicationInternal(host_id, adapter, null, permit_out);
        }

        /// 제품 transaction은 아직 authoritative인 source extent도 함께 보호한다. permit은 이 API의 sole 제품
        /// caller가 소유한 stack scratch이며 map backing을 제품 권위로 노출하지 않는다.
        pub fn prepareManagedOwnedPublication(
            self: *Self,
            host_id: u128,
            adapter: *Adapter,
            source: anytype,
            permit_out: anytype,
        ) !void {
            return self.prepareOwnedPublicationInternal(host_id, adapter, source, permit_out);
        }

        fn prepareOwnedPublicationInternal(
            self: *Self,
            host_id: u128,
            adapter: *Adapter,
            source: anytype,
            permit_out: anytype,
        ) !void {
            if (comptime !@hasDecl(Adapter, "sealPreparedHostPublication"))
                @compileError("managed host publication requires the adapter sealing facade");
            try self.ensureOwner();
            if (self.active_publication.lifecycle != .inactive) return error.PublicationBusy;
            if (objectsOverlap(permit_out, adapter) or objectsOverlap(permit_out, self))
                return error.InvalidDestination;
            if (comptime @TypeOf(source) != @TypeOf(null)) {
                if (objectsOverlap(permit_out, source)) return error.InvalidDestination;
            }
            if (!std.mem.allEqual(u8, std.mem.asBytes(permit_out), 0)) return error.InvalidDestination;
            if (self.adapter_generation_exhausted) return error.AdapterGenerationExhausted;
            if (host_id == 0 or self.entries.contains(host_id)) return error.DuplicateHost;
            if (@intFromPtr(adapter) == 0) return error.InvalidDestination;
            const identity = Adapter.publicationProcessIdentity() orelse return error.ProcessSealUnavailable;
            const thread_id: u64 = @intCast(std.Thread.getCurrentId());
            if (thread_id == 0) return error.ProcessSealUnavailable;
            const generation = try self.nextAdapterGeneration();
            // allocator가 재진입할 수 있는 capacity 확보보다 먼저 owner를 게시해야 같은 generation의 두 permit이
            // 동시에 준비되지 않는다. 이후 실패는 이 exact preparing row만 되돌린다.
            self.active_publication = .{
                .pool_addr = @intFromPtr(self),
                .pid = identity.pid,
                .process_nonce = identity.process_nonce,
                .thread_id = thread_id,
                .permit_addr = @intFromPtr(permit_out),
                .host_id = host_id,
                .adapter_addr = @intFromPtr(adapter),
                .adapter_generation = generation,
                .lifecycle = .preparing,
            };
            errdefer self.active_publication = .{};
            try self.entries.ensureUnusedCapacity(self.allocator, 1);
            permit_out.* = .{
                .self_addr = @intFromPtr(permit_out),
                .pool_addr = @intFromPtr(self),
                .host_id = host_id,
                .adapter_addr = @intFromPtr(adapter),
                .adapter_generation = generation,
                .owned_raw = 1,
            };
            try Adapter.sealPreparedHostPublication(permit_out);
            if (!self.validActivePublication(permit_out, adapter, .preparing))
                @panic("managed host publication preparing proof loss");
            self.active_publication.lifecycle = .prepared;
        }

        /// Client binding publication이 permit과 일치할 때만 map row와 generation을 한 no-fail suffix로 게시한다.
        pub fn commitOwnedPublication(self: *Self, adapter: *Adapter, permit: anytype) void {
            self.requireOwner();
            if (comptime !@hasDecl(Adapter, "validPreparedHostPublication") or
                !@hasDecl(Adapter, "incidentBindingPublication") or
                !@hasDecl(Adapter, "consumePreparedHostPublicationNoFail"))
                @compileError("managed host publication requires the adapter validation facade");
            const expected_generation = self.nextAdapterGeneration() catch
                @panic("managed host publication generation exhausted after prepare");
            if (!self.validActivePublication(permit, adapter, .prepared) or
                self.active_publication.host_id != permit.host_id or
                self.active_publication.adapter_addr != @intFromPtr(adapter) or
                self.active_publication.adapter_generation != permit.adapter_generation or
                !Adapter.hostPublicationBound(permit) or
                !Adapter.validPreparedHostPublication(permit, @intFromPtr(self), @intFromPtr(adapter)) or
                self.entries.contains(permit.host_id) or self.adapter_generation_exhausted or
                expected_generation != permit.adapter_generation)
                @panic("managed host publication proof loss");
            const publication = adapter.incidentBindingPublication();
            if (!adapter.incidentBindingMatchesPermit(permit) or
                publication.client_addr == 0 or
                std.mem.allEqual(u8, &publication.binding_seal, 0))
                @panic("managed Client binding was not published");
            self.entries.putAssumeCapacityNoClobber(permit.host_id, .{
                .adapter = adapter,
                .owned = true,
                .adapter_generation = permit.adapter_generation,
            });
            self.adapter_generation = permit.adapter_generation;
            Adapter.consumePreparedHostPublicationNoFail(permit);
            self.active_publication = .{};
        }

        /// Client 이동 전 실패만 reserved capacity를 semantic publication 없이 폐기할 수 있다.
        pub fn abortOwnedPublication(self: *Self, adapter: *Adapter, permit: anytype) void {
            self.requireOwner();
            if (!self.validActivePublication(permit, adapter, .prepared) or
                self.active_publication.host_id != permit.host_id or
                self.active_publication.adapter_addr != @intFromPtr(adapter) or
                permit.adapter_addr != @intFromPtr(adapter) or
                self.active_publication.adapter_generation != permit.adapter_generation or
                !Adapter.hostPublicationPrepared(permit) or
                !Adapter.validPreparedHostPublication(permit, @intFromPtr(self), @intFromPtr(adapter)) or
                self.entries.contains(permit.host_id))
                @panic("managed host publication abort proof loss");
            permit.* = .{};
            self.active_publication = .{};
        }

        /// Adapter lifetime을 caller가 pool보다 길게 보장할 때만 사용한다.
        pub fn addBorrowed(self: *Self, host_id: u128, adapter: *Adapter) !void {
            if (!@import("builtin").is_test) return error.ManagedPublicationRequired;
            try self.ensureOwner();
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
            if (self.active_publication.lifecycle != .inactive) return error.PublicationBusy;
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

        fn validActivePublication(self: *const Self, permit: anytype, adapter: *Adapter, lifecycle: ActivePublicationLifecycle) bool {
            const active = self.active_publication;
            const identity = Adapter.publicationProcessIdentity() orelse return false;
            return active.lifecycle == lifecycle and active.pool_addr == @intFromPtr(self) and
                active.pid == identity.pid and active.process_nonce == identity.process_nonce and
                active.thread_id == @as(u64, @intCast(std.Thread.getCurrentId())) and
                active.permit_addr == @intFromPtr(permit) and active.host_id == permit.host_id and
                active.adapter_addr == @intFromPtr(adapter) and
                active.adapter_generation == permit.adapter_generation;
        }

        fn objectsOverlap(a: anytype, b: anytype) bool {
            const a_start = @intFromPtr(a);
            const b_start = @intFromPtr(b);
            const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
            const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
            return a_start < b_end and b_start < a_end;
        }

        fn ensureOwner(self: *Self) !void {
            const state = self.owner_state.load(.acquire);
            if (state == 2) {
                if (!self.ownerValid()) return error.InvalidOwner;
                return;
            }
            if (state != 0 or self.owner_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null)
                return error.PublicationBusy;
            const identity = publicationIdentity() orelse {
                self.owner_state.store(0, .release);
                return error.ProcessSealUnavailable;
            };
            const thread_id: u64 = @intCast(std.Thread.getCurrentId());
            if (thread_id == 0) {
                self.owner_state.store(0, .release);
                return error.ProcessSealUnavailable;
            }
            self.owner_addr = @intFromPtr(self);
            self.owner_pid = identity.pid;
            self.owner_process_nonce = identity.process_nonce;
            self.owner_thread_id = thread_id;
            self.owner_state.store(2, .release);
        }

        fn ownerValid(self: *const Self) bool {
            if (self.owner_state.load(.acquire) != 2 or self.owner_addr != @intFromPtr(self) or
                self.owner_thread_id != @as(u64, @intCast(std.Thread.getCurrentId()))) return false;
            const identity = publicationIdentity() orelse return false;
            return self.owner_pid == identity.pid and self.owner_process_nonce == identity.process_nonce;
        }

        fn publicationIdentity() ?PublicationIdentity {
            if (comptime @hasDecl(Adapter, "publicationProcessIdentity")) {
                const identity = Adapter.publicationProcessIdentity() orelse return null;
                return .{ .pid = identity.pid, .process_nonce = identity.process_nonce };
            }
            if (!@import("builtin").is_test) return null;
            return .{ .pid = @intCast(std.c.getpid()), .process_nonce = 1 };
        }

        fn requireOwner(self: *Self) void {
            self.ensureOwner() catch @panic("session host pool owner proof loss");
        }

        fn nextAdapterGeneration(self: *const Self) !u64 {
            return std.math.add(u64, self.adapter_generation, 1) catch
                error.AdapterGenerationExhausted;
        }

        pub fn get(self: *Self, host_id: u128) ?*Adapter {
            self.ensureOwner() catch return null;
            const entry = self.entries.get(host_id) orelse return null;
            return entry.adapter;
        }

        pub fn adapterGeneration(self: *Self, host_id: u128) ?u64 {
            self.ensureOwner() catch return null;
            return (self.entries.get(host_id) orelse return null).adapter_generation;
        }

        pub fn adapterSnapshots(self: *Self, out: []AdapterSnapshot) usize {
            self.requireOwner();
            var count: usize = 0;
            var entries = self.entries.valueIterator();
            while (entries.next()) |entry| {
                if (count < out.len) out[count] = .{
                    .adapter = entry.adapter,
                    .adapter_generation = entry.adapter_generation,
                };
                count += 1;
            }
            return count;
        }

        pub fn setSpawnHost(self: *Self, host_id: u128) !void {
            try self.ensureOwner();
            if (!self.entries.contains(host_id)) return error.UnknownHost;
            self.spawn_host_id = host_id;
        }

        pub fn spawnHost(self: *Self) ?*Adapter {
            self.requireOwner();
            return self.get(self.spawn_host_id orelse return null);
        }

        pub fn spawnHostId(self: *Self) ?u128 {
            self.ensureOwner() catch return null;
            return self.spawn_host_id;
        }

        pub fn retain(self: *Self, host_id: u128) !*Adapter {
            try self.ensureOwner();
            const entry = self.entries.getPtr(host_id) orelse return error.UnknownHost;
            entry.runtime_refs = std.math.add(usize, entry.runtime_refs, 1) catch return error.TooManyReferences;
            return entry.adapter;
        }

        pub fn release(self: *Self, host_id: u128) void {
            self.requireOwner();
            const entry = self.entries.getPtr(host_id) orelse unreachable;
            if (entry.runtime_refs == 0)
                @panic("session host runtime lease released more than once");
            entry.runtime_refs -= 1;
        }

        pub fn remove(self: *Self, host_id: u128) !bool {
            try self.ensureOwner();
            if (self.active_publication.lifecycle != .inactive) return error.PublicationBusy;
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
