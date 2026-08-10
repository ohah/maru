//! Process-private bounded authority for one-shot generation event cleanup.
//!
//! This leaf owns scalar metadata only. It deliberately does not know Client, EventOwner,
//! ConnectionLease, allocators, callbacks, sockets, or protocol modules. The caller supplies the
//! protocol limits as comptime scalars and remains the sole transaction orchestrator.

const std = @import("std");

pub fn Registry(
    comptime protocol_max_inventory_runtimes: usize,
    comptime protocol_max_control_json: usize,
) type {
    return struct {
        const Self = @This();

        pub const capacity = protocol_max_inventory_runtimes;
        pub const retained_byte_cap = capacity * protocol_max_control_json;

        pub const Error = error{
            Busy,
            CapacityExhausted,
            ByteCapacityExhausted,
            InvalidIdentity,
            InvalidState,
            ProcessDomainMismatch,
            ThreadDomainMismatch,
        };

        pub const Lifecycle = enum(u8) {
            empty,
            reserved_unbound,
            reserved,
            releasing,
            transferring,
            released,
            transferred_no_free,
        };

        pub const Identity = struct {
            node_incarnation: u64,
            event_generation: u64,
            owner_addr: usize,
        };

        pub const CleanupMirror = struct {
            payload_addr: usize,
            payload_len: usize,
            payload_digest: [32]u8,
            admission_projection_digest: [32]u8,
            wire_major: u16,
            expected_major: u16,
            admission_tag: u8,
            metadata_support_raw: u8,
            allocator_ptr: usize,
            allocator_vtable: usize,
            pin_owner_addr: usize,
            lease_addr: usize,
            slot_addr: usize,
            slot_incarnation: u64,
            node_addr: usize,
            node_incarnation: u64,
            host_id: u128,
            connection_generation: u64,
            stream_id: u64,
            process_nonce: u64,
            owner_thread_id: u64,
        };

        pub const Reservation = struct {
            slot_index: u16,
            reservation_generation: u64,
            node_incarnation: u64,
            owner_addr: usize,
        };

        pub const Snapshot = struct {
            occupied_slots: usize,
            transferred_slots: usize,
            retained_bytes: usize,
        };

        const Entry = struct {
            lifecycle: Lifecycle = .empty,
            reservation_generation: u64 = 0,
            node_incarnation: u64 = 0,
            event_generation: u64 = 0,
            owner_addr: usize = 0,
            mirror: CleanupMirror = undefined,
        };

        mutex: std.atomic.Mutex = .unlocked,
        pid: u32 = 0,
        owner_thread_id: u64 = 0,
        next_reservation_generation: u64 = 1,
        entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
        occupied_slots: usize = 0,
        transferred_slots: usize = 0,
        retained_bytes: usize = 0,

        pub fn initInPlace(out: *Self, pid: u32, owner_thread_id: u64) Error!void {
            if (pid == 0 or owner_thread_id == 0) return error.InvalidIdentity;
            out.* = .{ .pid = pid, .owner_thread_id = owner_thread_id };
        }

        pub fn reserveUnbound(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            node_incarnation: u64,
            owner_addr: usize,
            mirror: CleanupMirror,
        ) Error!Reservation {
            try self.preLockDomain(current_pid, current_thread_id);
            if (!mirrorValid(mirror, node_incarnation) or owner_addr == 0)
                return error.InvalidIdentity;
            self.lock();
            defer self.mutex.unlock();
            if (self.next_reservation_generation == 0 or
                self.next_reservation_generation == std.math.maxInt(u64))
                return error.CapacityExhausted;
            const next_slots = std.math.add(usize, self.occupied_slots, 1) catch
                return error.CapacityExhausted;
            if (next_slots > capacity) return error.CapacityExhausted;
            const next_bytes = std.math.add(usize, self.retained_bytes, mirror.payload_len) catch
                return error.ByteCapacityExhausted;
            if (next_bytes > retained_byte_cap) return error.ByteCapacityExhausted;
            var index: usize = 0;
            while (index < self.entries.len and self.entries[index].lifecycle != .empty) : (index += 1) {}
            if (index == self.entries.len) return error.CapacityExhausted;
            const generation = self.next_reservation_generation;
            self.next_reservation_generation = generation + 1;
            self.entries[index] = .{
                .lifecycle = .reserved_unbound,
                .reservation_generation = generation,
                .node_incarnation = node_incarnation,
                .owner_addr = owner_addr,
                .mirror = mirror,
            };
            self.occupied_slots = next_slots;
            self.retained_bytes = next_bytes;
            return .{
                .slot_index = @intCast(index),
                .reservation_generation = generation,
                .node_incarnation = node_incarnation,
                .owner_addr = owner_addr,
            };
        }

        pub fn bind(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            event_generation: u64,
        ) Error!Identity {
            try self.preLockDomain(current_pid, current_thread_id);
            if (event_generation == 0) return error.InvalidIdentity;
            self.lock();
            defer self.mutex.unlock();
            const entry = try self.exactEntry(reservation, .reserved_unbound);
            entry.event_generation = event_generation;
            entry.lifecycle = .reserved;
            return .{
                .node_incarnation = entry.node_incarnation,
                .event_generation = event_generation,
                .owner_addr = entry.owner_addr,
            };
        }

        pub fn rollback(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
        ) Error!void {
            try self.preLockDomain(current_pid, current_thread_id);
            self.lock();
            defer self.mutex.unlock();
            const entry = self.exactEntryAny(reservation) orelse return error.InvalidIdentity;
            if (entry.lifecycle != .reserved_unbound and entry.lifecycle != .reserved)
                return error.InvalidState;
            self.releaseAccounting(entry.mirror.payload_len);
            entry.* = .{};
        }

        pub fn beginRelease(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            identity: Identity,
        ) Error!CleanupMirror {
            return self.beginTransition(
                current_pid,
                current_thread_id,
                reservation,
                identity,
                .releasing,
            );
        }

        pub fn settleRelease(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            identity: Identity,
        ) Error!void {
            try self.preLockDomain(current_pid, current_thread_id);
            self.lock();
            defer self.mutex.unlock();
            const entry = try self.exactBoundEntry(reservation, identity, .releasing);
            entry.lifecycle = .released;
            self.releaseAccounting(entry.mirror.payload_len);
            entry.* = .{};
        }

        pub fn beginTransfer(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            identity: Identity,
        ) Error!CleanupMirror {
            return self.beginTransition(
                current_pid,
                current_thread_id,
                reservation,
                identity,
                .transferring,
            );
        }

        pub fn settleTransfer(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            identity: Identity,
        ) Error!void {
            try self.preLockDomain(current_pid, current_thread_id);
            self.lock();
            defer self.mutex.unlock();
            const entry = try self.exactBoundEntry(reservation, identity, .transferring);
            entry.lifecycle = .transferred_no_free;
            self.transferred_slots = std.math.add(usize, self.transferred_slots, 1) catch
                @panic("event quarantine transferred counter overflow");
        }

        pub fn snapshot(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
        ) Error!Snapshot {
            try self.preLockDomain(current_pid, current_thread_id);
            self.lock();
            defer self.mutex.unlock();
            return .{
                .occupied_slots = self.occupied_slots,
                .transferred_slots = self.transferred_slots,
                .retained_bytes = self.retained_bytes,
            };
        }

        pub fn trustedMirror(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            identity: Identity,
        ) Error!CleanupMirror {
            try self.preLockDomain(current_pid, current_thread_id);
            self.lock();
            defer self.mutex.unlock();
            const entry = try self.exactBoundEntry(reservation, identity, .reserved);
            return entry.mirror;
        }

        fn beginTransition(
            self: *Self,
            current_pid: u32,
            current_thread_id: u64,
            reservation: Reservation,
            identity: Identity,
            next: Lifecycle,
        ) Error!CleanupMirror {
            try self.preLockDomain(current_pid, current_thread_id);
            self.lock();
            defer self.mutex.unlock();
            const entry = try self.exactBoundEntry(reservation, identity, .reserved);
            entry.lifecycle = next;
            return entry.mirror;
        }

        fn exactEntry(
            self: *Self,
            reservation: Reservation,
            expected: Lifecycle,
        ) Error!*Entry {
            const entry = self.exactEntryAny(reservation) orelse return error.InvalidIdentity;
            if (!lifecycleRawValid(&entry.lifecycle) or entry.lifecycle != expected)
                return error.InvalidState;
            return entry;
        }

        fn exactBoundEntry(
            self: *Self,
            reservation: Reservation,
            identity: Identity,
            expected: Lifecycle,
        ) Error!*Entry {
            const entry = try self.exactEntry(reservation, expected);
            if (identity.node_incarnation != entry.node_incarnation or
                identity.event_generation != entry.event_generation or
                identity.owner_addr != entry.owner_addr)
                return error.InvalidIdentity;
            return entry;
        }

        fn exactEntryAny(self: *Self, reservation: Reservation) ?*Entry {
            const index: usize = reservation.slot_index;
            if (index >= self.entries.len or reservation.reservation_generation == 0 or
                reservation.node_incarnation == 0 or reservation.owner_addr == 0)
                return null;
            const entry = &self.entries[index];
            if (entry.reservation_generation != reservation.reservation_generation or
                entry.node_incarnation != reservation.node_incarnation or
                entry.owner_addr != reservation.owner_addr)
                return null;
            return entry;
        }

        fn preLockDomain(self: *const Self, current_pid: u32, current_thread_id: u64) Error!void {
            if (current_pid == 0 or self.pid != current_pid) return error.ProcessDomainMismatch;
            if (current_thread_id == 0 or self.owner_thread_id != current_thread_id)
                return error.ThreadDomainMismatch;
        }

        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn releaseAccounting(self: *Self, payload_len: usize) void {
            if (self.occupied_slots == 0 or self.retained_bytes < payload_len)
                @panic("event quarantine accounting underflow");
            self.occupied_slots -= 1;
            self.retained_bytes -= payload_len;
        }

        fn mirrorValid(mirror: CleanupMirror, node_incarnation: u64) bool {
            return mirror.payload_addr != 0 and mirror.payload_len != 0 and
                mirror.payload_len <= protocol_max_control_json and
                mirror.wire_major != 0 and mirror.expected_major != 0 and
                mirror.admission_tag <= 1 and mirror.metadata_support_raw <= 1 and
                mirror.allocator_ptr != 0 and mirror.allocator_vtable != 0 and
                mirror.pin_owner_addr != 0 and mirror.lease_addr != 0 and
                mirror.slot_addr != 0 and mirror.slot_incarnation != 0 and
                mirror.node_addr != 0 and mirror.node_incarnation == node_incarnation and
                mirror.host_id != 0 and mirror.connection_generation != 0 and
                mirror.stream_id != 0 and mirror.process_nonce != 0 and
                mirror.owner_thread_id != 0;
        }

        fn lifecycleRawValid(value: *const Lifecycle) bool {
            return @as(*const u8, @ptrCast(value)).* <=
                @intFromEnum(Lifecycle.transferred_no_free);
        }

        comptime {
            if (capacity == 0 or capacity > std.math.maxInt(u16))
                @compileError("generation event quarantine capacity is not representable");
            if (capacity != 4096)
                @compileError("generation event quarantine protocol capacity drifted");
            if (retained_byte_cap != 1024 * 1024 * 1024)
                @compileError("generation event quarantine retained byte cap drifted");
            if (@sizeOf(Entry) > 256)
                @compileError("generation event quarantine entry budget exceeded");
            if (@sizeOf([capacity]Entry) > 1024 * 1024)
                @compileError("generation event quarantine descriptor table budget exceeded");
        }
    };
}

test "CR3a-2c3d C2 quarantine enforces 4096 slots and logical byte cap then reuses released rows" {
    const TestRegistry = Registry(4096, 256 * 1024);
    const allocator = std.testing.allocator;
    const registry = try allocator.create(TestRegistry);
    defer allocator.destroy(registry);
    try TestRegistry.initInPlace(registry, 41, 42);
    const reservations = try allocator.alloc(TestRegistry.Reservation, TestRegistry.capacity);
    defer allocator.free(reservations);
    const identities = try allocator.alloc(TestRegistry.Identity, TestRegistry.capacity);
    defer allocator.free(identities);

    for (0..TestRegistry.capacity) |index| {
        const scalar = index + 1;
        const owner_addr = 0x100000 + scalar;
        reservations[index] = try registry.reserveUnbound(41, 42, 7, owner_addr, .{
            .payload_addr = 0x200000 + scalar,
            .payload_len = 256 * 1024,
            .payload_digest = [_]u8{0xA5} ** 32,
            .admission_projection_digest = [_]u8{0x5A} ** 32,
            .wire_major = 1,
            .expected_major = 1,
            .admission_tag = 1,
            .metadata_support_raw = 0,
            .allocator_ptr = 1,
            .allocator_vtable = 2,
            .pin_owner_addr = 3,
            .lease_addr = 4,
            .slot_addr = 5,
            .slot_incarnation = 6,
            .node_addr = 7,
            .node_incarnation = 7,
            .host_id = 8,
            .connection_generation = 1,
            .stream_id = 9,
            .process_nonce = 10,
            .owner_thread_id = 42,
        });
        identities[index] = try registry.bind(41, 42, reservations[index], scalar);
        if (index == TestRegistry.capacity - 2)
            try std.testing.expectEqual(
                @as(usize, 4095),
                (try registry.snapshot(41, 42)).occupied_slots,
            );
    }
    const full = try registry.snapshot(41, 42);
    try std.testing.expectEqual(TestRegistry.capacity, full.occupied_slots);
    try std.testing.expectEqual(TestRegistry.retained_byte_cap, full.retained_bytes);
    try std.testing.expectError(error.CapacityExhausted, registry.reserveUnbound(
        41,
        42,
        7,
        0x900000,
        .{
            .payload_addr = 0x900001,
            .payload_len = 1,
            .payload_digest = [_]u8{0} ** 32,
            .admission_projection_digest = [_]u8{0} ** 32,
            .wire_major = 1,
            .expected_major = 1,
            .admission_tag = 0,
            .metadata_support_raw = 0,
            .allocator_ptr = 1,
            .allocator_vtable = 2,
            .pin_owner_addr = 3,
            .lease_addr = 4,
            .slot_addr = 5,
            .slot_incarnation = 6,
            .node_addr = 7,
            .node_incarnation = 7,
            .host_id = 8,
            .connection_generation = 1,
            .stream_id = 9,
            .process_nonce = 10,
            .owner_thread_id = 42,
        },
    ));
    try std.testing.expectEqualDeep(full, try registry.snapshot(41, 42));

    for (reservations, identities) |reservation, identity| {
        _ = try registry.beginRelease(41, 42, reservation, identity);
        try registry.settleRelease(41, 42, reservation, identity);
    }
    try std.testing.expectEqual(
        TestRegistry.Snapshot{ .occupied_slots = 0, .transferred_slots = 0, .retained_bytes = 0 },
        try registry.snapshot(41, 42),
    );
    const reused = try registry.reserveUnbound(41, 42, 7, 0xA00000, .{
        .payload_addr = 0xA00001,
        .payload_len = 1,
        .payload_digest = [_]u8{0} ** 32,
        .admission_projection_digest = [_]u8{0} ** 32,
        .wire_major = 1,
        .expected_major = 1,
        .admission_tag = 0,
        .metadata_support_raw = 0,
        .allocator_ptr = 1,
        .allocator_vtable = 2,
        .pin_owner_addr = 3,
        .lease_addr = 4,
        .slot_addr = 5,
        .slot_incarnation = 6,
        .node_addr = 7,
        .node_incarnation = 7,
        .host_id = 8,
        .connection_generation = 1,
        .stream_id = 9,
        .process_nonce = 10,
        .owner_thread_id = 42,
    });
    try registry.rollback(41, 42, reused);

    const byte_registry = try allocator.create(TestRegistry);
    defer allocator.destroy(byte_registry);
    try TestRegistry.initInPlace(byte_registry, 41, 42);
    byte_registry.retained_bytes = TestRegistry.retained_byte_cap;
    const byte_before = try byte_registry.snapshot(41, 42);
    try std.testing.expectError(error.ByteCapacityExhausted, byte_registry.reserveUnbound(
        41,
        42,
        7,
        0xB00000,
        .{
            .payload_addr = 0xB00001,
            .payload_len = 1,
            .payload_digest = [_]u8{0} ** 32,
            .admission_projection_digest = [_]u8{0} ** 32,
            .wire_major = 1,
            .expected_major = 1,
            .admission_tag = 0,
            .metadata_support_raw = 0,
            .allocator_ptr = 1,
            .allocator_vtable = 2,
            .pin_owner_addr = 3,
            .lease_addr = 4,
            .slot_addr = 5,
            .slot_incarnation = 6,
            .node_addr = 7,
            .node_incarnation = 7,
            .host_id = 8,
            .connection_generation = 1,
            .stream_id = 9,
            .process_nonce = 10,
            .owner_thread_id = 42,
        },
    ));
    try std.testing.expectEqualDeep(byte_before, try byte_registry.snapshot(41, 42));

    const transfer_registry = try allocator.create(TestRegistry);
    defer allocator.destroy(transfer_registry);
    try TestRegistry.initInPlace(transfer_registry, 41, 42);
    const transferred_reservation = try transfer_registry.reserveUnbound(41, 42, 7, 0xC00000, .{
        .payload_addr = 0xC00001,
        .payload_len = 17,
        .payload_digest = [_]u8{0} ** 32,
        .admission_projection_digest = [_]u8{0} ** 32,
        .wire_major = 1,
        .expected_major = 1,
        .admission_tag = 0,
        .metadata_support_raw = 0,
        .allocator_ptr = 1,
        .allocator_vtable = 2,
        .pin_owner_addr = 3,
        .lease_addr = 4,
        .slot_addr = 5,
        .slot_incarnation = 6,
        .node_addr = 7,
        .node_incarnation = 7,
        .host_id = 8,
        .connection_generation = 1,
        .stream_id = 9,
        .process_nonce = 10,
        .owner_thread_id = 42,
    });
    const transferred_identity = try transfer_registry.bind(41, 42, transferred_reservation, 1);
    _ = try transfer_registry.beginTransfer(41, 42, transferred_reservation, transferred_identity);
    try transfer_registry.settleTransfer(41, 42, transferred_reservation, transferred_identity);
    const transferred = try transfer_registry.snapshot(41, 42);
    try std.testing.expectEqual(
        TestRegistry.Snapshot{ .occupied_slots = 1, .transferred_slots = 1, .retained_bytes = 17 },
        transferred,
    );
    try std.testing.expectError(
        error.InvalidState,
        transfer_registry.settleTransfer(41, 42, transferred_reservation, transferred_identity),
    );
    try std.testing.expectEqualDeep(transferred, try transfer_registry.snapshot(41, 42));
}
