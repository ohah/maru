//! Node-local authority for one prepared generation RPC request.
//!
//! The opaque Client storage owns the encoded frame bytes. This value is the canonical scalar
//! transcript that must match that storage before anybody hashes, dereferences, or frees its
//! descriptor. It intentionally owns no pointer and performs no allocation or I/O.

const std = @import("std");
const contract = @import("generation_attachment_contract.zig");
const owner_seal = @import("external_owner_seal.zig");

pub const Lifecycle = enum(u8) {
    idle,
    prepared,
    executing,
    terminal,
};

pub const SettlementReadiness = enum(u8) {
    settled,
    busy,
    invalid,
};

pub const PreparedDescriptor = struct {
    storage_addr: usize,
    prepared_incarnation: u64,
    client_addr: usize,
    request_id: u64,
    request_digest: u64,
    frame_addr: usize,
    frame_len: usize,
    allocator_ptr: usize,
    allocator_vtable: usize,

    pub fn valid(self: @This()) bool {
        return self.storage_addr != 0 and self.prepared_incarnation != 0 and
            self.client_addr != 0 and self.request_id != 0 and self.request_digest != 0 and
            self.frame_addr != 0 and self.frame_len != 0 and self.allocator_ptr != 0 and
            self.allocator_vtable != 0 and rangeEndValid(self.frame_addr, self.frame_len);
    }

    pub fn matches(self: @This(), other: @This()) bool {
        return self.valid() and other.valid() and std.meta.eql(self, other);
    }
};

fn rangeEndValid(start: usize, len: usize) bool {
    _ = std.math.add(usize, start, len) catch return false;
    return true;
}

pub const Prepared = struct {
    transport_addr: usize,
    transport_incarnation: u64,
    binding: contract.BindingIdentity,
    tag: contract.RuntimeRequestTag,
    family: contract.RequestFamily,
    receipt: contract.PreparedCallReceipt,
    descriptor: PreparedDescriptor,

    pub fn valid(self: @This()) bool {
        return self.transport_addr != 0 and self.transport_incarnation != 0 and
            self.binding.valid() and contract.runtimeRequestTagRawValid(&self.tag) and
            contract.requestFamilyRawValid(&self.family) and
            contract.requestFamilyAllowed(self.tag, self.family) and self.receipt.valid() and
            self.receipt.transport_incarnation == self.transport_incarnation and
            self.receipt.request_id == self.descriptor.request_id and
            self.receipt.request_digest == self.descriptor.request_digest and
            self.descriptor.valid();
    }
};

pub const Authority = struct {
    lifecycle: Lifecycle = .idle,
    prepared_present: u8 = 0,
    prepared: Prepared = std.mem.zeroes(Prepared),
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub const Error = error{ InvalidState, InvalidPrepared };

    pub fn rawLifecycleValid(self: *const Authority) bool {
        const raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return raw <= @intFromEnum(Lifecycle.terminal);
    }

    fn rawPreparedPresenceValid(self: *const Authority) bool {
        return self.prepared_present <= 1;
    }

    fn preparedBytesZero(self: *const Authority) bool {
        // Never perform typed enum equality on an absent/untrusted transcript. Padding is not
        // canonical, so compare every semantic scalar and read enum storage only as raw bytes.
        const prepared = &self.prepared;
        const tag_raw = @as(*const u8, @ptrCast(&prepared.tag)).*;
        const family_raw = @as(*const u8, @ptrCast(&prepared.family)).*;
        const role_raw = @as(*const u8, @ptrCast(&prepared.binding.role)).*;
        return prepared.transport_addr == 0 and prepared.transport_incarnation == 0 and
            prepared.binding.slot_incarnation == 0 and prepared.binding.node_incarnation == 0 and
            prepared.binding.host_id == 0 and prepared.binding.connection_generation == 0 and
            prepared.binding.pid == 0 and prepared.binding.process_nonce == 0 and
            prepared.binding.binding_incarnation == 0 and
            prepared.binding.binding_storage_addr == 0 and
            prepared.binding.destination_addr == 0 and
            prepared.binding.binding_reservation_id == 0 and
            prepared.binding.runtime_id == 0 and role_raw == 0 and
            tag_raw == 0 and family_raw == 0 and
            prepared.receipt.transport_incarnation == 0 and prepared.receipt.request_id == 0 and
            prepared.receipt.request_digest == 0 and
            prepared.descriptor.storage_addr == 0 and
            prepared.descriptor.prepared_incarnation == 0 and
            prepared.descriptor.client_addr == 0 and prepared.descriptor.request_id == 0 and
            prepared.descriptor.request_digest == 0 and prepared.descriptor.frame_addr == 0 and
            prepared.descriptor.frame_len == 0 and prepared.descriptor.allocator_ptr == 0 and
            prepared.descriptor.allocator_vtable == 0;
    }

    pub fn settledExact(self: *const Authority) bool {
        if (!self.rawLifecycleValid() or !self.rawPreparedPresenceValid()) return false;
        return switch (self.lifecycle) {
            .idle => self.prepared_present == 0 and self.preparedBytesZero() and
                std.mem.allEqual(u8, &self.seal, 0),
            .terminal => self.prepared_present == 0 and self.preparedBytesZero() and
                std.mem.eql(u8, &self.seal, &sealFor(self)),
            .prepared, .executing => false,
        };
    }

    /// Teardown must distinguish a coherent live request from corrupt split
    /// authority. Both block destruction, but only the former is retryable.
    pub fn settlementReadiness(self: *const Authority) SettlementReadiness {
        if (!self.rawLifecycleValid() or !self.rawPreparedPresenceValid()) return .invalid;
        return switch (self.lifecycle) {
            .idle, .terminal => if (self.settledExact()) .settled else .invalid,
            .prepared, .executing => blk: {
                if (self.prepared_present != 1) break :blk .invalid;
                const prepared = self.prepared;
                if (!prepared.valid() or
                    !std.mem.eql(u8, &self.seal, &sealFor(self)))
                    break :blk .invalid;
                break :blk .busy;
            },
        };
    }

    pub fn publish(self: *Authority, prepared: Prepared) Error!void {
        if (!self.rawLifecycleValid() or !self.rawPreparedPresenceValid() or
            self.lifecycle != .idle or self.prepared_present != 0 or !self.preparedBytesZero() or
            !std.mem.allEqual(u8, &self.seal, 0))
            return error.InvalidState;
        if (!prepared.valid()) return error.InvalidPrepared;
        self.lifecycle = .prepared;
        self.prepared_present = 1;
        self.prepared = prepared;
        self.seal = sealFor(self);
    }

    pub fn matches(self: *const Authority, prepared: Prepared) bool {
        return self.rawLifecycleValid() and self.rawPreparedPresenceValid() and
            self.lifecycle == .prepared and self.prepared_present == 1 and
            self.prepared.valid() and prepared.valid() and
            std.meta.eql(self.prepared, prepared) and
            std.mem.eql(u8, &self.seal, &sealFor(self));
    }

    pub fn matchesExecuting(self: *const Authority, prepared: Prepared) bool {
        return self.rawLifecycleValid() and self.rawPreparedPresenceValid() and
            self.lifecycle == .executing and self.prepared_present == 1 and
            self.prepared.valid() and prepared.valid() and
            std.meta.eql(self.prepared, prepared) and
            std.mem.eql(u8, &self.seal, &sealFor(self));
    }

    pub fn terminalExact(self: *const Authority) bool {
        return self.rawLifecycleValid() and self.rawPreparedPresenceValid() and
            self.lifecycle == .terminal and self.prepared_present == 0 and
            self.preparedBytesZero() and std.mem.eql(u8, &self.seal, &sealFor(self));
    }

    pub fn beginExecute(self: *Authority, prepared: Prepared) Error!void {
        if (!self.matches(prepared)) return error.InvalidPrepared;
        self.lifecycle = .executing;
        self.seal = sealFor(self);
    }

    pub fn settleReusable(self: *Authority, prepared: Prepared) Error!void {
        if (!self.rawLifecycleValid() or !self.rawPreparedPresenceValid() or
            (self.lifecycle != .prepared and self.lifecycle != .executing) or
            self.prepared_present != 1 or !self.prepared.valid() or !prepared.valid() or
            !std.meta.eql(self.prepared, prepared) or
            !std.mem.eql(u8, &self.seal, &sealFor(self)))
            return error.InvalidPrepared;
        self.* = .{};
    }

    pub fn settleTerminal(self: *Authority, prepared: Prepared) Error!void {
        if (!self.rawLifecycleValid() or !self.rawPreparedPresenceValid() or
            (self.lifecycle != .prepared and self.lifecycle != .executing) or
            self.prepared_present != 1 or !self.prepared.valid() or !prepared.valid() or
            !std.meta.eql(self.prepared, prepared) or
            !std.mem.eql(u8, &self.seal, &sealFor(self)))
            return error.InvalidPrepared;
        self.lifecycle = .terminal;
        self.prepared_present = 0;
        self.prepared = std.mem.zeroes(Prepared);
        self.seal = sealFor(self);
    }

    pub fn commitExecutingTerminalNoFail(self: *Authority, prepared: Prepared) void {
        if (!self.matchesExecuting(prepared))
            @panic("prepared request recovery commit drifted");
        self.lifecycle = .terminal;
        self.prepared_present = 0;
        self.prepared = std.mem.zeroes(Prepared);
        self.seal = sealFor(self);
    }
};

fn sealFor(authority: *const Authority) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.prepared-request-authority.v1");
    writer.writeU8(@as(*const u8, @ptrCast(&authority.lifecycle)).*);
    writer.writeU8(authority.prepared_present);
    if (authority.prepared_present == 1) {
        const prepared = authority.prepared;
        writer.writeBool(true);
        writer.writeUsize(prepared.transport_addr);
        writer.writeU64(prepared.transport_incarnation);
        writeBinding(&writer, prepared.binding);
        writer.writeU8(@as(*const u8, @ptrCast(&prepared.tag)).*);
        writer.writeU8(@as(*const u8, @ptrCast(&prepared.family)).*);
        writer.writeU64(prepared.receipt.transport_incarnation);
        writer.writeU64(prepared.receipt.request_id);
        writer.writeU64(prepared.receipt.request_digest);
        writer.writeUsize(prepared.descriptor.storage_addr);
        writer.writeU64(prepared.descriptor.prepared_incarnation);
        writer.writeUsize(prepared.descriptor.client_addr);
        writer.writeU64(prepared.descriptor.request_id);
        writer.writeU64(prepared.descriptor.request_digest);
        writer.writeUsize(prepared.descriptor.frame_addr);
        writer.writeUsize(prepared.descriptor.frame_len);
        writer.writeUsize(prepared.descriptor.allocator_ptr);
        writer.writeUsize(prepared.descriptor.allocator_vtable);
    } else writer.writeBool(false);
    return writer.finish();
}

fn writeBinding(writer: *owner_seal.Writer, binding: contract.BindingIdentity) void {
    writer.writeU64(binding.binding_incarnation);
    writer.writeUsize(binding.binding_storage_addr);
    writer.writeUsize(binding.destination_addr);
    writer.writeU64(binding.binding_reservation_id);
    writer.writeU64(binding.slot_incarnation);
    writer.writeU64(binding.node_incarnation);
    writer.writeU128(binding.host_id);
    writer.writeU64(binding.connection_generation);
    writer.writeU128(binding.runtime_id);
    writer.writeU8(@as(*const u8, @ptrCast(&binding.role)).*);
    writer.writeU64(binding.pid);
    writer.writeU64(binding.process_nonce);
}

test "prepared request authority rejects splice and settles exact" {
    const binding = contract.BindingIdentity.init(.{
        .binding_incarnation = 1,
        .binding_storage_addr = 2,
        .destination_addr = 3,
        .binding_reservation_id = 4,
        .slot_incarnation = 5,
        .node_incarnation = 6,
        .host_id = 7,
        .connection_generation = 1,
        .runtime_id = 8,
        .role = .controller,
        .pid = 9,
        .process_nonce = 10,
    }).?;
    const descriptor: PreparedDescriptor = .{
        .storage_addr = 11,
        .prepared_incarnation = 12,
        .client_addr = 13,
        .request_id = 14,
        .request_digest = 15,
        .frame_addr = 16,
        .frame_len = 17,
        .allocator_ptr = 18,
        .allocator_vtable = 19,
    };
    const prepared: Prepared = .{
        .transport_addr = 20,
        .transport_incarnation = 21,
        .binding = binding,
        .tag = .detach,
        .family = .bound_terminal,
        .receipt = .{ .transport_incarnation = 21, .request_id = 14, .request_digest = 15 },
        .descriptor = descriptor,
    };
    var authority: Authority = .{};
    try authority.publish(prepared);
    var splice = prepared;
    splice.tag = .observation;
    try std.testing.expect(!authority.matches(splice));
    try authority.beginExecute(prepared);
    try authority.settleReusable(prepared);
    try std.testing.expect(authority.settledExact());
}

test "prepared request authority raw lifecycle sweep fails closed" {
    var raw: [@sizeOf(Authority)]u8 align(@alignOf(Authority)) = [_]u8{0} ** @sizeOf(Authority);
    const authority: *Authority = @ptrCast(&raw);
    for (0..256) |value| {
        raw[@offsetOf(Authority, "lifecycle")] = @intCast(value);
        const expected = value <= @intFromEnum(Lifecycle.terminal);
        try std.testing.expectEqual(expected, authority.rawLifecycleValid());
        if (!expected) try std.testing.expect(!authority.settledExact());
    }
    raw[@offsetOf(Authority, "lifecycle")] = @intFromEnum(Lifecycle.idle);
    for (2..256) |value| {
        raw[@offsetOf(Authority, "prepared_present")] = @intCast(value);
        try std.testing.expect(!authority.settledExact());
        try std.testing.expectEqual(SettlementReadiness.invalid, authority.settlementReadiness());
    }
}

test "prepared request authority settled state rejects every semantic residue" {
    const Field = enum {
        transport_addr,
        transport_incarnation,
        binding_incarnation,
        binding_storage_addr,
        destination_addr,
        binding_reservation_id,
        slot_incarnation,
        node_incarnation,
        host_id,
        connection_generation,
        runtime_id,
        role,
        pid,
        process_nonce,
        tag,
        family,
        receipt_transport_incarnation,
        receipt_request_id,
        receipt_request_digest,
        descriptor_storage_addr,
        descriptor_prepared_incarnation,
        descriptor_client_addr,
        descriptor_request_id,
        descriptor_request_digest,
        descriptor_frame_addr,
        descriptor_frame_len,
        descriptor_allocator_ptr,
        descriptor_allocator_vtable,
    };

    inline for (std.enums.values(Field)) |field| {
        var authority: Authority = .{};
        switch (field) {
            .transport_addr => authority.prepared.transport_addr = 1,
            .transport_incarnation => authority.prepared.transport_incarnation = 1,
            .binding_incarnation => authority.prepared.binding.binding_incarnation = 1,
            .binding_storage_addr => authority.prepared.binding.binding_storage_addr = 1,
            .destination_addr => authority.prepared.binding.destination_addr = 1,
            .binding_reservation_id => authority.prepared.binding.binding_reservation_id = 1,
            .slot_incarnation => authority.prepared.binding.slot_incarnation = 1,
            .node_incarnation => authority.prepared.binding.node_incarnation = 1,
            .host_id => authority.prepared.binding.host_id = 1,
            .connection_generation => authority.prepared.binding.connection_generation = 1,
            .runtime_id => authority.prepared.binding.runtime_id = 1,
            .role => authority.prepared.binding.role = .observer,
            .pid => authority.prepared.binding.pid = 1,
            .process_nonce => authority.prepared.binding.process_nonce = 1,
            .tag => authority.prepared.tag = .attach_controller,
            .family => authority.prepared.family = .attach_only,
            .receipt_transport_incarnation => authority.prepared.receipt.transport_incarnation = 1,
            .receipt_request_id => authority.prepared.receipt.request_id = 1,
            .receipt_request_digest => authority.prepared.receipt.request_digest = 1,
            .descriptor_storage_addr => authority.prepared.descriptor.storage_addr = 1,
            .descriptor_prepared_incarnation => authority.prepared.descriptor.prepared_incarnation = 1,
            .descriptor_client_addr => authority.prepared.descriptor.client_addr = 1,
            .descriptor_request_id => authority.prepared.descriptor.request_id = 1,
            .descriptor_request_digest => authority.prepared.descriptor.request_digest = 1,
            .descriptor_frame_addr => authority.prepared.descriptor.frame_addr = 1,
            .descriptor_frame_len => authority.prepared.descriptor.frame_len = 1,
            .descriptor_allocator_ptr => authority.prepared.descriptor.allocator_ptr = 1,
            .descriptor_allocator_vtable => authority.prepared.descriptor.allocator_vtable = 1,
        }
        try std.testing.expect(!authority.settledExact());
        try std.testing.expectEqual(SettlementReadiness.invalid, authority.settlementReadiness());
    }
}
