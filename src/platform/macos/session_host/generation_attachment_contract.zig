//! CR3a-2a neutral value contracts shared by generation transport and GUI attachment owners.
//!
//! This leaf must remain independent from Client, sockets, allocators, and GUI types.  It carries
//! only opaque identities and closed state needed to pair a prepared RPC with one final-address
//! attachment binding without exporting either backing owner.

const std = @import("std");

/// Identity of one request whose frame and request slot are still owned by a
/// GenerationTransport. Zero is excluded from every component so pristine
/// storage cannot be mistaken for a live request after a partial init.
pub const PreparedCallReceipt = struct {
    transport_incarnation: u64,
    request_id: u64,
    /// Non-authoritative drift detector over the transport's canonical tagged
    /// request encoding. Authority is the exact transport/request pair; a
    /// digest collision cannot authorize a foreign request ID.
    request_digest: u64,

    pub fn init(fields: @This()) ?@This() {
        return if (fields.valid()) fields else null;
    }

    pub fn valid(self: @This()) bool {
        return self.transport_incarnation != 0 and
            self.request_id != 0 and
            self.request_digest != 0;
    }

    pub fn matches(self: @This(), other: @This()) bool {
        return self.valid() and other.valid() and std.meta.eql(self, other);
    }
};

/// Pointer-free proof that execute settled the corresponding prepared owner.
/// `response_request_id` is kept separately because correlation must be
/// checked before an accepted payload can bind a stream cleanup reservation.
pub const ExecutedCallReceipt = struct {
    prepared_call: PreparedCallReceipt,

    pub fn fromPrepared(prepared: PreparedCallReceipt) ?@This() {
        if (!prepared.valid()) return null;
        return .{ .prepared_call = prepared };
    }

    pub fn valid(self: @This()) bool {
        return self.prepared_call.valid();
    }

    pub fn matchesPrepared(self: @This(), prepared: PreparedCallReceipt) bool {
        return self.valid() and self.prepared_call.matches(prepared);
    }
};

pub const CorrelatedExecutedCall = struct {
    executed_call: ExecutedCallReceipt,
    response_request_id: u64,

    pub fn init(executed_call: ExecutedCallReceipt, response_request_id: u64) ?@This() {
        if (!executed_call.valid() or response_request_id == 0) return null;
        return .{
            .executed_call = executed_call,
            .response_request_id = response_request_id,
        };
    }

    pub fn responseMatchesPrepared(self: @This()) bool {
        return self.executed_call.valid() and
            self.response_request_id == self.executed_call.prepared_call.request_id;
    }
};

pub const AttachmentRole = enum(u8) {
    controller,
    observer,
};

pub fn attachmentRoleRawValid(value: *const AttachmentRole) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(AttachmentRole.observer);
}

/// Immutable, storage-neutral half of a prepared attachment binding. The
/// actual pin and cleanup entry remain private to ClientNode; this value only
/// lets the final-address owner reject foreign request or generation splices.
pub const BindingIdentity = struct {
    binding_incarnation: u64,
    binding_storage_addr: usize,
    destination_addr: usize,
    binding_reservation_id: u64,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    connection_generation: u64,
    runtime_id: u128,
    role: AttachmentRole,
    pid: u32,
    process_nonce: u64,

    pub fn init(fields: @This()) ?@This() {
        return if (fields.valid()) fields else null;
    }

    pub fn valid(self: @This()) bool {
        return attachmentRoleRawValid(&self.role) and
            self.binding_incarnation != 0 and
            self.binding_storage_addr != 0 and
            self.destination_addr != 0 and
            self.binding_reservation_id != 0 and
            self.slot_incarnation != 0 and
            self.node_incarnation != 0 and
            self.host_id != 0 and
            self.connection_generation == 1 and
            self.runtime_id != 0 and
            self.pid != 0 and
            self.process_nonce != 0;
    }

    pub fn matches(self: @This(), other: @This()) bool {
        return self.valid() and other.valid() and std.meta.eql(self, other);
    }
};

/// Closed state vocabulary; the stateful final-address owner lives outside
/// this leaf and is the only code allowed to perform transitions.
pub const BindingLifecycle = enum(u8) {
    pristine,
    reserved,
    request_paired,
    executing,
    committed,
    terminal,
};

/// Final-address neutral state paired with the private pin/drop reservation in
/// ClientNode. It never owns or dereferences that backing; callers must mutate
/// the backing first and publish the matching no-fail transition here second.
pub const PreparedAttachmentBinding = struct {
    self_addr: usize = 0,
    lifecycle: BindingLifecycle = .pristine,
    identity: ?BindingIdentity = null,
    prepared_call: ?PreparedCallReceipt = null,

    pub const TransitionError = error{
        InvalidIdentity,
        InvalidReceipt,
        InvalidState,
        MovedOrCopied,
    };

    pub fn initReservedInPlace(out: *PreparedAttachmentBinding, identity: BindingIdentity) TransitionError!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine or
            out.identity != null or out.prepared_call != null)
            return error.InvalidState;
        if (!identity.valid() or identity.binding_storage_addr != @intFromPtr(out))
            return error.InvalidIdentity;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .reserved,
            .identity = identity,
        };
    }

    pub fn validAtFinalAddress(self: *const PreparedAttachmentBinding) bool {
        return self.self_addr == @intFromPtr(self) and
            self.identity != null and self.identity.?.valid() and
            self.identity.?.binding_storage_addr == self.self_addr and
            self.identity.?.destination_addr != 0;
    }

    pub fn pairRequest(self: *PreparedAttachmentBinding, prepared: PreparedCallReceipt) TransitionError!void {
        if (!self.validAtFinalAddress()) return error.MovedOrCopied;
        if (self.lifecycle != .reserved or self.prepared_call != null)
            return error.InvalidState;
        if (!prepared.valid()) return error.InvalidReceipt;
        self.prepared_call = prepared;
        self.lifecycle = .request_paired;
    }

    pub fn beginExecute(self: *PreparedAttachmentBinding, prepared: PreparedCallReceipt) TransitionError!void {
        if (!self.validAtFinalAddress()) return error.MovedOrCopied;
        if (self.lifecycle != .request_paired) return error.InvalidState;
        const canonical = self.prepared_call orelse return error.InvalidState;
        if (!canonical.matches(prepared)) return error.InvalidReceipt;
        self.lifecycle = .executing;
    }

    // Commit/abort/cleanup transitions deliberately have no leaf-only public
    // method. ClientSlot must first validate and mutate its canonical pin/drop
    // reservation, then publish the matching state in the same owner API.
};

pub const ExecutedResponseLifecycle = enum(u8) {
    pristine,
    accepted,
    typed_reject,
    uncertain_or_connection_failure,
    terminal,
};

pub const ExecuteOutcome = enum(u8) {
    accepted,
    typed_reject,
    uncertain_or_connection_failure,
};

pub const ExecuteResult = union(ExecuteOutcome) {
    accepted: CorrelatedExecutedCall,
    typed_reject: CorrelatedExecutedCall,
    uncertain_or_connection_failure: ExecutedCallReceipt,
};

pub const TransportOwnerLifecycle = enum(u8) { pristine, live, terminal };

/// Neutral canonical fence stored beside, rather than inside, GenerationTransport. Restoring stale
/// transport bytes at the same address cannot revive this owner seal after attachment teardown.
pub const TransportOwnerSeal = struct {
    self_addr: usize = 0,
    incarnation: u64 = 0,
    lifecycle: TransportOwnerLifecycle = .pristine,

    fn lifecycleRawValid(self: *const TransportOwnerSeal) bool {
        const raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return raw <= @intFromEnum(TransportOwnerLifecycle.terminal);
    }

    pub fn initInPlace(out: *TransportOwnerSeal, incarnation: u64) error{ InvalidState, InvalidIncarnation }!void {
        if (!out.lifecycleRawValid() or out.self_addr != 0 or out.incarnation != 0 or
            out.lifecycle != .pristine)
            return error.InvalidState;
        if (incarnation == 0) return error.InvalidIncarnation;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .incarnation = incarnation,
            .lifecycle = .live,
        };
    }

    pub fn valid(self: *const TransportOwnerSeal, incarnation: u64) bool {
        return self.lifecycleRawValid() and self.self_addr == @intFromPtr(self) and
            self.incarnation == incarnation and
            incarnation != 0 and self.lifecycle == .live;
    }

    pub fn terminalize(self: *TransportOwnerSeal, incarnation: u64) error{InvalidState}!void {
        if (!self.valid(incarnation)) return error.InvalidState;
        self.lifecycle = .terminal;
    }

    pub fn settledExact(self: *const TransportOwnerSeal) bool {
        if (!self.lifecycleRawValid()) return false;
        return switch (self.lifecycle) {
            .pristine => self.self_addr == 0 and self.incarnation == 0,
            .terminal => self.self_addr == @intFromPtr(self) and self.incarnation != 0,
            .live => false,
        };
    }
};

pub const ExecutedResponseOwnerSeal = struct {
    self_addr: usize = 0,
    incarnation: u64 = 0,
    lifecycle: TransportOwnerLifecycle = .pristine,

    pub fn initInPlace(out: *@This(), incarnation: u64) error{ InvalidState, InvalidIncarnation }!void {
        if (out.self_addr != 0 or out.incarnation != 0 or out.lifecycle != .pristine)
            return error.InvalidState;
        if (incarnation == 0) return error.InvalidIncarnation;
        out.* = .{ .self_addr = @intFromPtr(out), .incarnation = incarnation, .lifecycle = .live };
    }

    pub fn valid(self: *const @This(), incarnation: u64) bool {
        return self.self_addr == @intFromPtr(self) and self.incarnation == incarnation and
            incarnation != 0 and self.lifecycle == .live;
    }

    pub fn terminalize(self: *@This(), incarnation: u64) error{InvalidState}!void {
        if (!self.valid(incarnation)) return error.InvalidState;
        self.lifecycle = .terminal;
    }

    pub fn settledExact(self: *const @This()) bool {
        return switch (self.lifecycle) {
            .pristine => self.self_addr == 0 and self.incarnation == 0,
            .terminal => self.self_addr == @intFromPtr(self) and self.incarnation != 0,
            .live => false,
        };
    }
};

/// Method strings remain inside GenerationTransport; callers select only one
/// of these audited request families and supply the existing encoded payload.
pub const RuntimeRequestTag = enum(u8) {
    spawn_full,
    attach_controller,
    resize,
    observation,
    selected_text,
    link_at,
    clipboard_write,
    find,
    select_op,
    core_command,
    report_mouse,
    notification,
    terminate,
    detach,
};

pub const EncodedRequestParams = struct {
    json: ?[]const u8,
};

pub const RuntimeRequest = union(RuntimeRequestTag) {
    spawn_full: EncodedRequestParams,
    attach_controller: EncodedRequestParams,
    resize: EncodedRequestParams,
    observation: EncodedRequestParams,
    selected_text: EncodedRequestParams,
    link_at: EncodedRequestParams,
    clipboard_write: EncodedRequestParams,
    find: EncodedRequestParams,
    select_op: EncodedRequestParams,
    core_command: EncodedRequestParams,
    report_mouse: EncodedRequestParams,
    notification: EncodedRequestParams,
    terminate: EncodedRequestParams,
    detach: EncodedRequestParams,

    pub fn params(self: @This()) ?[]const u8 {
        return switch (self) {
            inline else => |value| value.json,
        };
    }
};

/// Capability projection exposed by GenerationTransport. Optional feature
/// support is represented as booleans; no Client or wire storage escapes.
pub const GenerationCapabilities = struct {
    wire_major: u16,
    screen_codec_version: u16,
    attach_schema: AttachSchema,
    metadata_support: MetadataSupport,
    peer_attach_generation: bool,
    screen_viewport_scrolled: bool,
    async_scroll_to_bottom: bool,
    notification_stream_auth: bool,
    runtime_clipboard: bool,
    runtime_core_command: bool,
    runtime_link_at: bool,
    runtime_selected_text: bool,
};

comptime {
    const Expected = struct {
        wire_major: u16,
        screen_codec_version: u16,
        attach_schema: AttachSchema,
        metadata_support: MetadataSupport,
        peer_attach_generation: bool,
        screen_viewport_scrolled: bool,
        async_scroll_to_bottom: bool,
        notification_stream_auth: bool,
        runtime_clipboard: bool,
        runtime_core_command: bool,
        runtime_link_at: bool,
        runtime_selected_text: bool,
    };
    const actual = std.meta.fields(GenerationCapabilities);
    const expected = std.meta.fields(Expected);
    if (actual.len != expected.len)
        @compileError("GenerationCapabilities schema changed without updating CR3a SSOT");
    for (actual, expected) |a, e| {
        if (!std.mem.eql(u8, a.name, e.name) or a.type != e.type)
            @compileError("GenerationCapabilities schema changed without updating CR3a SSOT");
    }
}

pub const AttachSchema = enum(u8) {
    frozen_controller_only,
    granted_roles,
};

pub const MetadataSupport = enum(u8) {
    unsupported,
    supported,
};

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "CR3a-2a prepared and executed call receipts are pointer-free exact identities" {
    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 11,
        .request_id = 17,
        .request_digest = 23,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(prepared.matches(prepared));
    try std.testing.expect(!prepared.matches(.{
        .transport_incarnation = 11,
        .request_id = 18,
        .request_digest = 23,
    }));

    const executed = ExecutedCallReceipt.fromPrepared(prepared) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(executed.matchesPrepared(prepared));
    try std.testing.expect(!executed.matchesPrepared(.{
        .transport_incarnation = 12,
        .request_id = 17,
        .request_digest = 23,
    }));
}

test "CR3a-2a binding identity rejects zero and foreign request splices" {
    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 31,
        .request_id = 37,
        .request_digest = 41,
    }).?;
    const binding = BindingIdentity.init(.{
        .binding_incarnation = 43,
        .binding_storage_addr = 45,
        .destination_addr = 47,
        .binding_reservation_id = 49,
        .slot_incarnation = 53,
        .node_incarnation = 59,
        .host_id = 61,
        .connection_generation = 1,
        .runtime_id = 67,
        .role = .controller,
        .pid = 71,
        .process_nonce = 73,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(binding.valid());

    var foreign = prepared;
    foreign.request_id += 1;
    try std.testing.expect(!prepared.matches(foreign));
    try std.testing.expect(BindingIdentity.init(.{
        .binding_incarnation = 0,
        .binding_storage_addr = 45,
        .destination_addr = 47,
        .binding_reservation_id = 49,
        .slot_incarnation = 53,
        .node_incarnation = 59,
        .host_id = 61,
        .connection_generation = 1,
        .runtime_id = 67,
        .role = .controller,
        .pid = 71,
        .process_nonce = 73,
    }) == null);
}

test "CR3a-2c3a binding identity rejects every invalid raw attachment role" {
    var identity = BindingIdentity{
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
    };
    const role_raw: *u8 = @ptrCast(&identity.role);
    var raw: u16 = @intFromEnum(AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        role_raw.* = @intCast(raw);
        try std.testing.expect(!identity.valid());
        try std.testing.expect(!identity.matches(identity));
    }
}

test "CR3a-2a neutral lifecycle and request vocabularies are closed" {
    try std.testing.expectEqual(@as(usize, 6), std.enums.values(BindingLifecycle).len);
    try std.testing.expectEqual(@as(usize, 5), std.enums.values(ExecutedResponseLifecycle).len);
    // The SSOT list contains fourteen variants; an earlier RED inventory
    // accidentally omitted detach while the written list still included it.
    try std.testing.expectEqual(@as(usize, 14), std.meta.fields(RuntimeRequestTag).len);
    try std.testing.expectEqual(@as(usize, 3), std.enums.values(ExecuteOutcome).len);
}

test "CR3a-2a neutral identities and capabilities recursively contain no pointers" {
    try std.testing.expect(!containsPointer(PreparedCallReceipt));
    try std.testing.expect(!containsPointer(ExecutedCallReceipt));
    try std.testing.expect(!containsPointer(CorrelatedExecutedCall));
    try std.testing.expect(!containsPointer(ExecuteResult));
    try std.testing.expect(!containsPointer(BindingIdentity));
    try std.testing.expect(!containsPointer(GenerationCapabilities));
}

test "CR3a-2a zero receipt components never become authority" {
    inline for (0..3) |zero_index| {
        var fields = PreparedCallReceipt{
            .transport_incarnation = 11,
            .request_id = 17,
            .request_digest = 23,
        };
        switch (zero_index) {
            0 => fields.transport_incarnation = 0,
            1 => fields.request_id = 0,
            2 => fields.request_digest = 0,
            else => unreachable,
        }
        try std.testing.expect(PreparedCallReceipt.init(fields) == null);
    }

    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 11,
        .request_id = 17,
        .request_digest = 23,
    }).?;
    var invalid_prepared = prepared;
    invalid_prepared.request_id = 0;
    try std.testing.expect(ExecutedCallReceipt.fromPrepared(invalid_prepared) == null);
}

test "CR3a-2a prepared binding reserves before request and rejects copied execution" {
    var attachment_owner_marker: u64 = 0;
    var binding: PreparedAttachmentBinding = .{};
    const destination_addr = @intFromPtr(&attachment_owner_marker);
    const identity = BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = @intFromPtr(&binding),
        .destination_addr = destination_addr,
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;
    try std.testing.expect(destination_addr != @intFromPtr(&binding));
    try PreparedAttachmentBinding.initReservedInPlace(&binding, identity);
    try std.testing.expectEqual(BindingLifecycle.reserved, binding.lifecycle);

    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 23,
        .request_id = 29,
        .request_digest = 31,
    }).?;
    try binding.pairRequest(prepared);
    var copied = binding;
    try std.testing.expectError(error.MovedOrCopied, copied.beginExecute(prepared));
    try std.testing.expectEqual(BindingLifecycle.request_paired, binding.lifecycle);

    try binding.beginExecute(prepared);
    try std.testing.expectError(error.InvalidState, binding.beginExecute(prepared));
    try std.testing.expectEqual(BindingLifecycle.executing, binding.lifecycle);
}

test "CR3a-2a generation one and full-width host runtime identities are exact" {
    var binding: PreparedAttachmentBinding = .{};
    const canonical = BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = @intFromPtr(&binding),
        .destination_addr = @intFromPtr(&binding),
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;
    var foreign_host = canonical;
    foreign_host.host_id ^= @as(u128, 1) << 96;
    var foreign_runtime = canonical;
    foreign_runtime.runtime_id ^= @as(u128, 1) << 80;
    try std.testing.expect(!canonical.matches(foreign_host));
    try std.testing.expect(!canonical.matches(foreign_runtime));

    var future_generation = canonical;
    future_generation.connection_generation = 2;
    try std.testing.expect(!future_generation.valid());
}

test "CR3a-2a every scalar binding authority rejects zero and every foreign field mismatches" {
    var binding: PreparedAttachmentBinding = .{};
    const canonical = BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = @intFromPtr(&binding),
        .destination_addr = @intFromPtr(&binding),
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;

    inline for (0..11) |index| {
        var candidate = canonical;
        switch (index) {
            0 => candidate.binding_incarnation = 0,
            1 => candidate.binding_storage_addr = 0,
            2 => candidate.destination_addr = 0,
            3 => candidate.binding_reservation_id = 0,
            4 => candidate.slot_incarnation = 0,
            5 => candidate.node_incarnation = 0,
            6 => candidate.host_id = 0,
            7 => candidate.connection_generation = 0,
            8 => candidate.runtime_id = 0,
            9 => candidate.pid = 0,
            10 => candidate.process_nonce = 0,
            else => unreachable,
        }
        try std.testing.expect(!candidate.valid());
    }

    inline for (0..12) |index| {
        var foreign = canonical;
        switch (index) {
            0 => foreign.binding_incarnation += 1,
            1 => foreign.binding_storage_addr += 1,
            2 => foreign.destination_addr += 1,
            3 => foreign.binding_reservation_id += 1,
            4 => foreign.slot_incarnation += 1,
            5 => foreign.node_incarnation += 1,
            6 => foreign.host_id += 1,
            7 => foreign.connection_generation = 2,
            8 => foreign.runtime_id += 1,
            9 => foreign.role = .observer,
            10 => foreign.pid += 1,
            11 => foreign.process_nonce += 1,
            else => unreachable,
        }
        try std.testing.expect(!canonical.matches(foreign));
    }
}

test "CR3a-2a execute result preserves correlation only for response-bearing outcomes" {
    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 3,
        .request_id = 5,
        .request_digest = 7,
    }).?;
    const executed = ExecutedCallReceipt.fromPrepared(prepared).?;
    const correlated = CorrelatedExecutedCall.init(executed, prepared.request_id).?;
    try std.testing.expect(correlated.responseMatchesPrepared());

    const accepted: ExecuteResult = .{ .accepted = correlated };
    try std.testing.expect(accepted.accepted.responseMatchesPrepared());
    const uncertain: ExecuteResult = .{ .uncertain_or_connection_failure = executed };
    try std.testing.expect(uncertain.uncertain_or_connection_failure.matchesPrepared(prepared));

    const mismatched = CorrelatedExecutedCall.init(executed, prepared.request_id + 1).?;
    try std.testing.expect(!mismatched.responseMatchesPrepared());
    try std.testing.expect(CorrelatedExecutedCall.init(executed, 0) == null);
}
