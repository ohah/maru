//! Final-address, node-local authority for one blocking generation RPC response.
//!
//! This leaf owns only scalar identity and lifecycle evidence. It deliberately imports no Client,
//! socket, allocator, payload, decoder, GUI, or reconnect code. Product execute integration is a
//! later gate; the closed transitions live here so that exact ownership can be tested first.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("generation_attachment_contract.zig");
const owner_seal = @import("external_owner_seal.zig");

pub const Lifecycle = enum(u8) {
    idle,
    executing,
    published,
    borrowed,
    releasing,
    terminal,
};

pub const SettlementReadiness = enum(u8) {
    settled,
    busy,
    invalid,
};

pub const ReserveInput = struct {
    registry_incarnation: u64,
    binding: contract.BindingIdentity,
    transport_addr: usize,
    transport_incarnation: u64,
    family: contract.RequestFamily,
    tag: contract.RuntimeRequestTag,
    request_id: u64,
    request_digest: u64,
    destination_addr: usize,

    pub fn valid(self: @This()) bool {
        return self.registry_incarnation != 0 and self.binding.valid() and
            self.transport_addr != 0 and
            self.transport_incarnation != 0 and
            contract.requestFamilyRawValid(&self.family) and
            contract.runtimeRequestTagRawValid(&self.tag) and
            contract.requestFamilyAllowed(self.tag, self.family) and
            rpcFamily(self.family) and
            self.request_id != 0 and self.request_digest != 0 and
            self.destination_addr != 0;
    }
};

fn rpcFamily(family: contract.RequestFamily) bool {
    return switch (family) {
        .bound_observation, .bound_controller_mutation, .bound_terminal => true,
        .connection_only_denied, .attach_only => false,
    };
}

pub const Canonical = struct {
    authority_addr: usize,
    registry_incarnation: u64,
    binding: contract.BindingIdentity,
    transport_addr: usize,
    transport_incarnation: u64,
    family: contract.RequestFamily,
    tag: contract.RuntimeRequestTag,
    request_id: u64,
    request_digest: u64,
    response_epoch: u64,
    destination_addr: usize,

    pub fn valid(self: @This()) bool {
        return self.authority_addr != 0 and self.response_epoch != 0 and
            (ReserveInput{
                .binding = self.binding,
                .registry_incarnation = self.registry_incarnation,
                .transport_addr = self.transport_addr,
                .transport_incarnation = self.transport_incarnation,
                .family = self.family,
                .tag = self.tag,
                .request_id = self.request_id,
                .request_digest = self.request_digest,
                .destination_addr = self.destination_addr,
            }).valid();
    }
};

const Active = struct {
    transport_addr: usize,
    transport_incarnation: u64,
    family: contract.RequestFamily,
    tag: contract.RuntimeRequestTag,
    request_id: u64,
    request_digest: u64,
    response_epoch: u64,
    destination_addr: usize,

    fn valid(self: @This()) bool {
        return self.transport_addr != 0 and self.transport_incarnation != 0 and
            contract.requestFamilyRawValid(&self.family) and
            contract.runtimeRequestTagRawValid(&self.tag) and self.request_id != 0 and
            self.request_digest != 0 and self.response_epoch != 0 and
            self.destination_addr != 0;
    }
};

pub const Authority = struct {
    self_addr: usize = 0,
    registry_incarnation: u64 = 0,
    lifecycle: Lifecycle = .idle,
    binding_present: u8 = 0,
    canonical_present: u8 = 0,
    binding: contract.BindingIdentity = std.mem.zeroes(contract.BindingIdentity),
    next_epoch: u64 = 0,
    active: Active = std.mem.zeroes(Active),
    seal: owner_seal.Digest = [_]u8{0} ** 32,

    pub const Error = error{
        InvalidState,
        InvalidCanonical,
        IdentityExhausted,
        MovedOrCopied,
    };

    pub fn pristineExact(self: *const Authority) bool {
        return self.self_addr == 0 and self.registry_incarnation == 0 and
            rawLifecycle(self) == @intFromEnum(Lifecycle.idle) and
            self.binding_present == 0 and self.canonical_present == 0 and self.next_epoch == 0 and
            bindingZero(&self.binding) and activeZero(&self.active) and
            std.mem.allEqual(u8, &self.seal, 0);
    }

    pub fn initInPlace(
        out: *Authority,
        registry_incarnation: u64,
        binding: contract.BindingIdentity,
    ) Error!void {
        if (!out.pristineExact()) return error.InvalidState;
        if (registry_incarnation == 0 or !binding.valid()) return error.InvalidCanonical;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .registry_incarnation = registry_incarnation,
            .binding_present = 1,
            .binding = binding,
            .next_epoch = 1,
        };
        out.seal = sealFor(out);
    }

    pub fn rawLifecycleValid(self: *const Authority) bool {
        return rawLifecycle(self) <= @intFromEnum(Lifecycle.terminal);
    }

    pub fn settledExact(self: *const Authority) bool {
        if (!self.baseValid()) return false;
        return switch (self.lifecycle) {
            .idle, .terminal => self.canonical_present == 0 and activeZero(&self.active),
            .executing, .published, .borrowed, .releasing => false,
        };
    }

    pub fn settledExactFor(
        self: *const Authority,
        registry_incarnation: u64,
        binding: contract.BindingIdentity,
    ) bool {
        return registry_incarnation != 0 and
            self.registry_incarnation == registry_incarnation and
            binding.valid() and self.binding.matches(binding) and self.settledExact();
    }

    pub fn bindingExactForRegistry(
        self: *const Authority,
        registry_incarnation: u64,
    ) ?contract.BindingIdentity {
        return if (registry_incarnation != 0 and
            self.registry_incarnation == registry_incarnation and self.baseValid())
            self.binding
        else
            null;
    }

    pub fn settlementReadiness(self: *const Authority) SettlementReadiness {
        if (!self.baseValid()) return .invalid;
        return switch (self.lifecycle) {
            .idle, .terminal => if (self.canonical_present == 0 and
                activeZero(&self.active)) .settled else .invalid,
            .executing, .published, .borrowed, .releasing => if (self.activeExact()) .busy else .invalid,
        };
    }

    pub fn settlementReadinessFor(
        self: *const Authority,
        registry_incarnation: u64,
        binding: contract.BindingIdentity,
    ) SettlementReadiness {
        if (registry_incarnation == 0 or self.registry_incarnation != registry_incarnation or
            !binding.valid() or !self.binding.matches(binding)) return .invalid;
        return self.settlementReadiness();
    }

    pub fn terminalExactFor(
        self: *const Authority,
        registry_incarnation: u64,
        binding: contract.BindingIdentity,
    ) bool {
        return registry_incarnation != 0 and self.registry_incarnation == registry_incarnation and
            binding.valid() and self.binding.matches(binding) and self.lifecycle == .terminal and
            self.canonical_present == 0 and activeZero(&self.active) and
            std.mem.eql(u8, &self.seal, &sealFor(self));
    }

    pub fn reserveExecuting(self: *Authority, input: ReserveInput) Error!Canonical {
        try self.requireFinalAddress();
        if (self.lifecycle == .terminal) return error.InvalidState;
        if (self.lifecycle != .idle or self.canonical_present != 0 or
            !activeZero(&self.active)) return error.InvalidState;
        if (!input.valid() or input.registry_incarnation != self.registry_incarnation or
            !self.binding.matches(input.binding))
            return error.InvalidCanonical;
        if (self.next_epoch == 0 or self.next_epoch == std.math.maxInt(u64)) {
            self.lifecycle = .terminal;
            self.canonical_present = 0;
            self.active = std.mem.zeroes(Active);
            self.seal = sealFor(self);
            return error.IdentityExhausted;
        }
        const canonical: Canonical = .{
            .authority_addr = @intFromPtr(self),
            .registry_incarnation = self.registry_incarnation,
            .binding = input.binding,
            .transport_addr = input.transport_addr,
            .transport_incarnation = input.transport_incarnation,
            .family = input.family,
            .tag = input.tag,
            .request_id = input.request_id,
            .request_digest = input.request_digest,
            .response_epoch = self.next_epoch,
            .destination_addr = input.destination_addr,
        };
        self.next_epoch += 1;
        self.active = activeFromCanonical(canonical);
        self.canonical_present = 1;
        self.lifecycle = .executing;
        self.seal = sealFor(self);
        return canonical;
    }

    pub fn exhaustNextEpochForTest(self: *Authority) Error!void {
        if (!builtin.is_test) unreachable;
        try self.requireFinalAddress();
        if (self.lifecycle != .idle or self.canonical_present != 0 or
            !activeZero(&self.active)) return error.InvalidState;
        self.next_epoch = std.math.maxInt(u64);
        self.seal = sealFor(self);
    }

    pub fn matches(
        self: *const Authority,
        canonical: Canonical,
        expected: Lifecycle,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) bool {
        if (!self.baseValid() or !canonical.valid() or !self.activeExact()) return false;
        if (current_registry_incarnation == 0 or
            self.registry_incarnation != current_registry_incarnation or
            canonical.registry_incarnation != current_registry_incarnation or
            !current_binding.valid() or !self.binding.matches(current_binding) or
            expected == .idle or expected == .terminal or self.lifecycle != expected) return false;
        return canonical.authority_addr == @intFromPtr(self) and
            current_binding.matches(canonical.binding) and
            std.meta.eql(self.active, activeFromCanonical(canonical));
    }

    pub fn rollbackExecuting(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) Error!void {
        try self.transition(canonical, current_registry_incarnation, current_binding, .executing, .idle, true);
    }

    fn publish(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) Error!void {
        try self.transition(canonical, current_registry_incarnation, current_binding, .executing, .published, false);
    }

    fn borrow(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) Error!void {
        try self.transition(canonical, current_registry_incarnation, current_binding, .published, .borrowed, false);
    }

    fn beginRelease(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) Error!void {
        try self.transition(canonical, current_registry_incarnation, current_binding, .borrowed, .releasing, false);
    }

    fn finishReusable(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) Error!void {
        try self.transition(canonical, current_registry_incarnation, current_binding, .releasing, .idle, true);
    }

    pub fn settleExecutingTerminal(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
    ) Error!void {
        try self.requireFinalAddress();
        try self.transition(canonical, current_registry_incarnation, current_binding, .executing, .terminal, true);
    }

    fn transition(
        self: *Authority,
        canonical: Canonical,
        current_registry_incarnation: u64,
        current_binding: contract.BindingIdentity,
        from: Lifecycle,
        to: Lifecycle,
        clear: bool,
    ) Error!void {
        try self.requireFinalAddress();
        if (self.lifecycle == .terminal or self.lifecycle != from) return error.InvalidState;
        if (!self.matches(canonical, from, current_registry_incarnation, current_binding))
            return error.InvalidCanonical;
        self.lifecycle = to;
        if (clear) {
            self.canonical_present = 0;
            self.active = std.mem.zeroes(Active);
        }
        self.seal = sealFor(self);
    }

    fn requireFinalAddress(self: *const Authority) Error!void {
        if (self.self_addr != @intFromPtr(self)) return error.MovedOrCopied;
        if (!self.baseValid()) return error.InvalidState;
    }

    fn baseValid(self: *const Authority) bool {
        if (!self.rawLifecycleValid() or self.self_addr != @intFromPtr(self) or
            self.registry_incarnation == 0 or self.binding_present != 1 or
            self.canonical_present > 1 or
            !self.binding.valid() or self.next_epoch == 0 or
            !std.mem.eql(u8, &self.seal, &sealFor(self))) return false;
        return switch (self.lifecycle) {
            .idle, .terminal => self.canonical_present == 0,
            .executing, .published, .borrowed, .releasing => self.canonical_present == 1,
        };
    }

    fn activeExact(self: *const Authority) bool {
        return self.canonical_present == 1 and self.active.valid() and
            self.active.response_epoch < self.next_epoch;
    }
};

fn rawLifecycle(authority: *const Authority) u8 {
    return @as(*const u8, @ptrCast(&authority.lifecycle)).*;
}

fn sealFor(authority: *const Authority) owner_seal.Digest {
    var writer = owner_seal.Writer.init("maru.rpc-response-authority.v1");
    writer.writeUsize(authority.self_addr);
    writer.writeU64(authority.registry_incarnation);
    writer.writeU8(rawLifecycle(authority));
    writer.writeU8(authority.binding_present);
    writer.writeU8(authority.canonical_present);
    writeBinding(&writer, authority.binding);
    writer.writeU64(authority.next_epoch);
    if (authority.canonical_present == 1) {
        writer.writeBool(true);
        writeActive(&writer, authority.active);
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

fn writeActive(writer: *owner_seal.Writer, active: Active) void {
    writer.writeUsize(active.transport_addr);
    writer.writeU64(active.transport_incarnation);
    writer.writeU8(@as(*const u8, @ptrCast(&active.family)).*);
    writer.writeU8(@as(*const u8, @ptrCast(&active.tag)).*);
    writer.writeU64(active.request_id);
    writer.writeU64(active.request_digest);
    writer.writeU64(active.response_epoch);
    writer.writeUsize(active.destination_addr);
}

fn bindingZero(binding: *const contract.BindingIdentity) bool {
    const role_raw = @as(*const u8, @ptrCast(&binding.role)).*;
    return binding.binding_incarnation == 0 and binding.binding_storage_addr == 0 and
        binding.destination_addr == 0 and binding.binding_reservation_id == 0 and
        binding.slot_incarnation == 0 and binding.node_incarnation == 0 and
        binding.host_id == 0 and binding.connection_generation == 0 and
        binding.runtime_id == 0 and role_raw == 0 and binding.pid == 0 and
        binding.process_nonce == 0;
}

fn activeZero(active: *const Active) bool {
    const family_raw = @as(*const u8, @ptrCast(&active.family)).*;
    const tag_raw = @as(*const u8, @ptrCast(&active.tag)).*;
    return active.transport_addr == 0 and active.transport_incarnation == 0 and
        family_raw == 0 and tag_raw == 0 and active.request_id == 0 and
        active.request_digest == 0 and active.response_epoch == 0 and
        active.destination_addr == 0;
}

fn activeFromCanonical(canonical: Canonical) Active {
    return .{
        .transport_addr = canonical.transport_addr,
        .transport_incarnation = canonical.transport_incarnation,
        .family = canonical.family,
        .tag = canonical.tag,
        .request_id = canonical.request_id,
        .request_digest = canonical.request_digest,
        .response_epoch = canonical.response_epoch,
        .destination_addr = canonical.destination_addr,
    };
}

fn fixtureBinding(reservation_id: u64) contract.BindingIdentity {
    return contract.BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = 0x1000,
        .destination_addr = 0x2000,
        .binding_reservation_id = reservation_id,
        .slot_incarnation = 5,
        .node_incarnation = 7,
        .host_id = 11,
        .connection_generation = 1,
        .runtime_id = 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;
}

const fixture_registry_incarnation: u64 = 0xB300;

fn fixtureInput(binding: contract.BindingIdentity) ReserveInput {
    return .{
        .registry_incarnation = fixture_registry_incarnation,
        .binding = binding,
        .transport_addr = 0x3000,
        .transport_incarnation = 23,
        .family = .bound_observation,
        .tag = .observation,
        .request_id = 29,
        .request_digest = 31,
        .destination_addr = 0x4000,
    };
}

test "B3-1 RPC response authority closes lifecycle and reusable epochs" {
    var authority: Authority = .{};
    try authority.initInPlace(fixture_registry_incarnation, fixtureBinding(37));
    try std.testing.expectEqual(SettlementReadiness.settled, authority.settlementReadiness());

    const first = try authority.reserveExecuting(fixtureInput(fixtureBinding(37)));
    try std.testing.expectEqual(@as(u64, 1), first.response_epoch);
    try std.testing.expectEqual(SettlementReadiness.busy, authority.settlementReadiness());
    try authority.rollbackExecuting(first, fixture_registry_incarnation, fixtureBinding(37));
    const second = try authority.reserveExecuting(fixtureInput(fixtureBinding(37)));
    try std.testing.expectEqual(@as(u64, 2), second.response_epoch);
    try authority.publish(second, fixture_registry_incarnation, fixtureBinding(37));
    try authority.borrow(second, fixture_registry_incarnation, fixtureBinding(37));
    try authority.beginRelease(second, fixture_registry_incarnation, fixtureBinding(37));
    try authority.finishReusable(second, fixture_registry_incarnation, fixtureBinding(37));
    try std.testing.expectEqual(SettlementReadiness.settled, authority.settlementReadiness());

    const third = try authority.reserveExecuting(fixtureInput(fixtureBinding(37)));
    try authority.settleExecutingTerminal(third, fixture_registry_incarnation, fixtureBinding(37));
    try std.testing.expectEqual(SettlementReadiness.settled, authority.settlementReadiness());
    try std.testing.expectError(error.InvalidState, authority.reserveExecuting(fixtureInput(fixtureBinding(37))));
}

test "B3-1 RPC response authority rejects copy ABA and every canonical splice" {
    var authority: Authority = .{};
    try authority.initInPlace(fixture_registry_incarnation, fixtureBinding(41));
    const canonical = try authority.reserveExecuting(fixtureInput(fixtureBinding(41)));

    var copied = authority;
    try std.testing.expectError(error.MovedOrCopied, copied.publish(canonical, fixture_registry_incarnation, fixtureBinding(41)));
    try std.testing.expect(authority.matches(canonical, .executing, fixture_registry_incarnation, fixtureBinding(41)));

    inline for (@typeInfo(Canonical).@"struct".fields) |field| {
        var spliced = canonical;
        switch (@typeInfo(field.type)) {
            .int => @field(spliced, field.name) +%= 1,
            .@"enum" => {},
            .@"struct" => spliced.binding.binding_reservation_id += 1,
            else => @compileError("unhandled canonical field type"),
        }
        if (@typeInfo(field.type) == .@"enum") {
            if (comptime std.mem.eql(u8, field.name, "family")) spliced.family = .bound_terminal else spliced.tag = .detach;
        }
        try std.testing.expectError(error.InvalidCanonical, authority.publish(spliced, fixture_registry_incarnation, fixtureBinding(41)));
        try std.testing.expect(authority.matches(canonical, .executing, fixture_registry_incarnation, fixtureBinding(41)));
    }
    inline for (@typeInfo(contract.BindingIdentity).@"struct".fields) |field| {
        var spliced = canonical;
        switch (@typeInfo(field.type)) {
            .int => @field(spliced.binding, field.name) +%= 1,
            .@"enum" => spliced.binding.role = .observer,
            else => @compileError("unhandled binding field type"),
        }
        try std.testing.expectError(
            error.InvalidCanonical,
            authority.publish(spliced, fixture_registry_incarnation, fixtureBinding(41)),
        );
        try std.testing.expect(authority.matches(
            canonical,
            .executing,
            fixture_registry_incarnation,
            fixtureBinding(41),
        ));
    }

    try authority.rollbackExecuting(canonical, fixture_registry_incarnation, fixtureBinding(41));
    authority = .{};
    try authority.initInPlace(fixture_registry_incarnation, fixtureBinding(43));
    const current = try authority.reserveExecuting(fixtureInput(fixtureBinding(43)));
    try std.testing.expectError(error.InvalidCanonical, authority.publish(canonical, fixture_registry_incarnation, fixtureBinding(43)));
    try std.testing.expect(authority.matches(current, .executing, fixture_registry_incarnation, fixtureBinding(43)));

    const fresh_authority = authority;
    authority = copied;
    try std.testing.expectError(
        error.InvalidCanonical,
        authority.publish(canonical, fixture_registry_incarnation, fixtureBinding(43)),
    );
    try std.testing.expectEqual(
        SettlementReadiness.invalid,
        authority.settlementReadinessFor(fixture_registry_incarnation, fixtureBinding(43)),
    );
    authority = fresh_authority;
    try std.testing.expect(authority.matches(current, .executing, fixture_registry_incarnation, fixtureBinding(43)));
}

test "B3-1 RPC response authority rejects every invalid raw lifecycle and exhausts terminal" {
    var authority: Authority = .{};
    try authority.initInPlace(fixture_registry_incarnation, fixtureBinding(47));
    const canonical = try authority.reserveExecuting(fixtureInput(fixtureBinding(47)));
    const lifecycle_raw: *u8 = @ptrCast(&authority.lifecycle);
    var raw: u16 = @intFromEnum(Lifecycle.terminal) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        lifecycle_raw.* = @intCast(raw);
        try std.testing.expectEqual(SettlementReadiness.invalid, authority.settlementReadiness());
        try std.testing.expectError(error.InvalidState, authority.publish(canonical, fixture_registry_incarnation, fixtureBinding(47)));
    }

    lifecycle_raw.* = @intFromEnum(Lifecycle.executing);
    authority.seal = sealFor(&authority);
    try authority.rollbackExecuting(canonical, fixture_registry_incarnation, fixtureBinding(47));
    inline for (.{ Lifecycle.executing, .published, .borrowed, .releasing }) |active_lifecycle| {
        const active = try authority.reserveExecuting(fixtureInput(fixtureBinding(47)));
        authority.lifecycle = active_lifecycle;
        authority.seal = sealFor(&authority);
        try std.testing.expectEqual(SettlementReadiness.busy, authority.settlementReadiness());
        authority.lifecycle = .executing;
        authority.seal = sealFor(&authority);
        try authority.rollbackExecuting(active, fixture_registry_incarnation, fixtureBinding(47));
    }
    authority.next_epoch = 0;
    authority.seal = sealFor(&authority);
    try std.testing.expectEqual(SettlementReadiness.invalid, authority.settlementReadiness());
    try std.testing.expectError(
        error.InvalidState,
        authority.reserveExecuting(fixtureInput(fixtureBinding(47))),
    );
    try std.testing.expectEqual(@as(u64, 0), authority.next_epoch);
    authority.next_epoch = 9;
    authority.seal = sealFor(&authority);
    authority.seal[0] ^= 1;
    try std.testing.expectEqual(SettlementReadiness.invalid, authority.settlementReadiness());
    authority.seal = sealFor(&authority);
    authority.self_addr += 1;
    try std.testing.expectEqual(SettlementReadiness.invalid, authority.settlementReadiness());
    authority.self_addr = @intFromPtr(&authority);
    authority.seal = sealFor(&authority);
    authority.next_epoch = std.math.maxInt(u64);
    authority.seal = sealFor(&authority);
    try std.testing.expectError(error.IdentityExhausted, authority.reserveExecuting(fixtureInput(fixtureBinding(47))));
    try std.testing.expectEqual(Lifecycle.terminal, authority.lifecycle);
    try std.testing.expect(authority.settledExact());
}

test "B3-1 RPC response authority admits only structurally coherent bound RPC families" {
    inline for (std.meta.tags(contract.RuntimeRequestTag)) |tag| {
        inline for (std.meta.tags(contract.RequestFamily)) |family| {
            var authority: Authority = .{};
            const binding = fixtureBinding(53);
            try authority.initInPlace(fixture_registry_incarnation, binding);
            var input = fixtureInput(binding);
            input.tag = tag;
            input.family = family;
            const allowed = contract.requestFamilyAllowed(tag, family) and rpcFamily(family);
            if (allowed) {
                const canonical = try authority.reserveExecuting(input);
                try authority.rollbackExecuting(canonical, fixture_registry_incarnation, binding);
            } else {
                try std.testing.expectError(error.InvalidCanonical, authority.reserveExecuting(input));
                try std.testing.expectEqual(Lifecycle.idle, authority.lifecycle);
                try std.testing.expectEqual(@as(u64, 1), authority.next_epoch);
                try std.testing.expect(authority.settledExactFor(fixture_registry_incarnation, binding));
            }
        }
    }
}
