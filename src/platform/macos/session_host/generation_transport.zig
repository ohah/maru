//! CR3a-2a generation-1 live transport facade.
//!
//! HostAdapter mints this value in its final GUI attachment storage. Public methods expose only
//! the closed runtime request vocabulary; raw Client pointers and arbitrary method strings remain
//! private to this module.

const std = @import("std");
const client_mod = @import("client.zig");
const client_slot_mod = @import("client_slot.zig");
const contract = @import("generation_attachment_contract.zig");
const executed_response_mod = @import("executed_response.zig");
const initial_snapshot_owner_mod = @import("initial_snapshot_owner.zig");
const client_poison = @import("client_poison.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const socket_server = @import("socket_server.zig");
const builtin = @import("builtin");
const posix = std.posix;

const c = std.c;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn getdtablesize() c_int;

var response_alias_fail_stop_completed = false;

pub const Error = client_mod.PreparedBlockingRpcError || error{
    IdentityExhausted,
    InvalidTransport,
    InvalidReceipt,
    InvalidResponseDestination,
};

pub const InputError = error{
    Busy,
    InvalidOwner,
    Unauthorized,
    ResourceExhausted,
    ConnectionClosed,
    ProtocolError,
};

pub const CapabilityError = error{
    Busy,
    InvalidOwner,
};

pub const PrepareError = error{
    Busy,
    InvalidOwner,
    Unauthorized,
    IdentityExhausted,
    ResourceExhausted,
    ConnectionClosed,
    ProtocolError,
};

pub const AbortError = error{
    Busy,
    InvalidOwner,
    InvalidReceipt,
    ProtocolError,
};

fn errorSetMatches(comptime ErrorSet: type, comptime expected: []const []const u8) bool {
    const errors = @typeInfo(ErrorSet).error_set orelse return false;
    if (errors.len != expected.len) return false;
    inline for (expected) |name| {
        var found = false;
        inline for (errors) |entry| if (std.mem.eql(u8, entry.name, name)) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}

comptime {
    if (!errorSetMatches(PrepareError, &.{
        "Busy",
        "InvalidOwner",
        "Unauthorized",
        "IdentityExhausted",
        "ResourceExhausted",
        "ConnectionClosed",
        "ProtocolError",
    })) @compileError("PrepareError must match the documented closed facade set");
    if (!errorSetMatches(AbortError, &.{
        "Busy",
        "InvalidOwner",
        "InvalidReceipt",
        "ProtocolError",
    })) @compileError("AbortError must match the documented closed facade set");
}

pub const RevokeFence = enum {
    no_pending_stream_frame,
    cancelled_before_write,
    partial_frame_requires_close,
};

const Lifecycle = enum(u8) {
    pristine,
    live,
    terminal,
};

var transport_incarnation_issuer: std.atomic.Value(u64) = .init(1);

pub const GenerationTransport = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    owner_size: usize = 0,
    owner_seal_addr: usize = 0,
    slot_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    host_id: u128 = 0,
    connection_generation: u64 = 0,
    transport_incarnation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread_id: std.Thread.Id = 0,
    lifecycle: Lifecycle = .pristine,
    binding_reservation: client_slot_mod.AttachmentBindingReservation = undefined,
    bound_stream_id: u64 = 0,
    snapshot_authority: initial_snapshot_owner_mod.Authority = .{},
    prepared_storage: client_mod.PreparedBlockingRpcStorage = .{},

    pub fn capabilities(
        self: *const GenerationTransport,
    ) CapabilityError!contract.GenerationCapabilities {
        const identity = self.binding_reservation.identity;
        if (!rawLifecycleValid(&self.lifecycle) or self.self_addr != @intFromPtr(self) or
            self.lifecycle != .live or self.slot_addr == 0 or self.owner_seal_addr == 0 or
            self.transport_incarnation == 0 or self.connection_generation != 1 or
            self.pid != currentPid() or self.owner_thread_id != std.Thread.getCurrentId() or
            !bindingRoleRawValid(&identity.role) or
            self.slot_incarnation != identity.slot_incarnation or
            self.node_incarnation != identity.node_incarnation or
            self.host_id != identity.host_id or
            self.connection_generation != identity.connection_generation or
            self.pid != identity.pid or self.process_nonce != identity.process_nonce)
            return error.InvalidOwner;
        return client_slot_mod.projectGenerationCapabilities(.{
            .slot_addr = self.slot_addr,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .transport_incarnation = self.transport_incarnation,
            .owner_seal_addr = self.owner_seal_addr,
            .reservation = self.binding_reservation,
        }) catch |err| switch (err) {
            error.Busy => error.Busy,
            error.InvalidOwner => error.InvalidOwner,
        };
    }

    pub fn prepareRequest(
        self: *GenerationTransport,
        request: contract.RuntimeRequest,
    ) PrepareError!contract.PreparedCallReceipt {
        if (!self.requestIdentityValid()) return error.InvalidOwner;
        const prepared = client_slot_mod.prepareGenerationRequest(.{
            .slot_addr = self.slot_addr,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .transport_addr = @intFromPtr(self),
            .owner_addr = self.owner_addr,
            .owner_size = self.owner_size,
            .transport_incarnation = self.transport_incarnation,
            .owner_seal_addr = self.owner_seal_addr,
            .prepared_storage_addr = @intFromPtr(&self.prepared_storage),
            .bound_stream_id = self.bound_stream_id,
            .reservation = self.binding_reservation,
            .request = request,
        }) catch |err| return mapPrepareError(err);
        return prepared.receipt;
    }

    pub fn executePreparedRequest(
        self: *GenerationTransport,
        receipt: contract.PreparedCallReceipt,
        response_out: *executed_response_mod.ExecutedResponse,
    ) Error!contract.ExecuteResult {
        if (!self.requestIdentityValid()) return error.MovedOrCopied;
        return client_slot_mod.executeGenerationRequest(.{
            .request = self.requestOperation(receipt),
            .bound_stream_id = self.bound_stream_id,
            .response_out_addr = @intFromPtr(response_out),
            .owner_addr = self.owner_addr,
            .owner_size = self.owner_size,
        }) catch |err| return mapGenerationExecuteToLegacyError(err);
    }

    pub fn abortPreparedRequest(
        self: *GenerationTransport,
        receipt: contract.PreparedCallReceipt,
    ) AbortError!void {
        if (!self.requestIdentityValid()) return error.InvalidOwner;
        client_slot_mod.abortGenerationRequest(.{
            .slot_addr = self.slot_addr,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .transport_addr = @intFromPtr(self),
            .transport_incarnation = self.transport_incarnation,
            .owner_seal_addr = self.owner_seal_addr,
            .prepared_storage_addr = @intFromPtr(&self.prepared_storage),
            .reservation = self.binding_reservation,
            .receipt = receipt,
        }) catch |err| return mapAbortError(err);
    }

    pub fn sendInput(self: *GenerationTransport, bytes: []const u8) InputError!void {
        const client = try self.borrowInputClient();
        client.sendInput(self.bound_stream_id, bytes) catch |err| return mapInputError(err);
    }

    pub fn sendInputNonBlocking(
        self: *GenerationTransport,
        bytes: []const u8,
    ) InputError!usize {
        const client = try self.borrowInputClient();
        return client.sendInputNonBlocking(self.bound_stream_id, bytes) catch |err|
            return mapInputError(err);
    }

    pub fn pumpPendingOutput(self: *GenerationTransport) InputError!bool {
        const client = self.borrowClient() orelse return error.InvalidOwner;
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        if (!slot.streamOperationPermitIdle()) return error.Busy;
        // Output progress is connection-wide and observer-safe, but a buffered controller revoke
        // must win before any sibling flushes an already admitted mutation frame.
        if (client.hasBufferedControllerRevoke()) return false;
        return client.pumpPendingOutput() catch |err| return mapInputError(err);
    }

    pub fn fenceRevoke(self: *GenerationTransport) InputError!RevokeFence {
        const client = self.borrowClient() orelse return error.InvalidOwner;
        if (!self.controllerRevokePending()) return error.Unauthorized;
        const result = client.fenceRevokedStream(self.bound_stream_id) catch |err|
            return mapInputError(err);
        return switch (result) {
            .no_pending_stream_frame => .no_pending_stream_frame,
            .cancelled_before_write => .cancelled_before_write,
            .partial_frame_requires_close => .partial_frame_requires_close,
        };
    }

    pub fn readInitialSnapshot(
        self: *GenerationTransport,
        out: *initial_snapshot_owner_mod.InitialSnapshotOwner,
    ) (client_mod.ClientError || error{ InvalidSnapshotOwner, MovedOrCopied })!void {
        const client = self.borrowClient() orelse return error.MovedOrCopied;
        if (self.bound_stream_id == 0 or !out.canInitialize() or
            rangesOverlapTyped(out, self) or rangesOverlapTyped(out, &self.prepared_storage))
            return error.InvalidSnapshotOwner;
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        if (rangesOverlapTyped(out, slot) or rangesOverlapTyped(out, slot.current) or
            rangesOverlapTyped(out, client))
            return error.InvalidSnapshotOwner;
        const binding_identity = self.binding_reservation.identity;
        const canonical_permit = slot.prepareInitialSnapshotPermit(
            @intFromPtr(out),
            self.transport_incarnation,
            binding_identity,
        ) catch |err| switch (err) {
            error.AdminBusy => return error.AdminBusy,
            error.IdentityExhausted => {
                client.poison(.local_invariant_violation);
                return error.InvalidSnapshotOwner;
            },
            error.InvalidSnapshotPermit => return error.InvalidSnapshotOwner,
        };
        var canonical_permit_live = true;
        defer if (canonical_permit_live)
            slot.abortInitialSnapshotPermit(canonical_permit) catch
                @panic("initial snapshot canonical permit rollback drifted");
        const receipt = self.snapshot_authority.prepare(
            @intFromPtr(out),
            self.transport_incarnation,
        ) catch return error.InvalidSnapshotOwner;
        var receipt_live = true;
        defer if (receipt_live)
            self.snapshot_authority.abort(receipt) catch
                @panic("initial snapshot authority rollback drifted");
        const read = slot.readInitialSnapshotGuarded(
            self.bound_stream_id,
            self.owner_addr,
            self.owner_size,
            @intFromPtr(out),
            @sizeOf(initial_snapshot_owner_mod.InitialSnapshotOwner),
        ) catch |err| switch (err) {
            error.AliasedAllocation,
            error.InvalidDestination,
            error.CapacityExhausted,
            error.DestinationOccupied,
            error.IdentityExhausted,
            error.InvalidDescriptor,
            error.InvalidIdentity,
            error.InvalidReservation,
            error.InvalidState,
            error.InvalidStream,
            => {
                client.poison(.local_invariant_violation);
                return error.InvalidSnapshotOwner;
            },
            error.MovedOrCopied => return error.MovedOrCopied,
            else => |typed| return typed,
        };
        if (payloadOverlaps(read.bytes, .{
            out,
            self,
            &self.prepared_storage,
            slot,
            slot.current,
            client,
        }) or rangeOverlaps(
            @intFromPtr(read.bytes.ptr),
            read.bytes.len,
            self.owner_addr,
            self.owner_size,
        )) {
            client.poison(.local_invariant_violation);
            return error.InvalidSnapshotOwner;
        }
        initial_snapshot_owner_mod.InitialSnapshotOwner.initInPlace(out, read.allocator, read.bytes, .{
            .transport_incarnation = self.transport_incarnation,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .connection_generation = self.connection_generation,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .owner_thread_id = self.owner_thread_id,
            .stream_id = self.bound_stream_id,
            .binding_incarnation = binding_identity.binding_incarnation,
            .binding_storage_addr = binding_identity.binding_storage_addr,
            .binding_destination_addr = binding_identity.destination_addr,
            .binding_reservation_id = binding_identity.binding_reservation_id,
            .runtime_id = binding_identity.runtime_id,
            .role = binding_identity.role,
        }, &self.snapshot_authority, receipt, canonical_permit) catch {
            read.allocator.free(read.bytes);
            return error.InvalidSnapshotOwner;
        };
        receipt_live = false;
        canonical_permit_live = false;
    }

    pub fn poison(
        self: *GenerationTransport,
        reason: client_poison.ConnectionReason,
    ) Error!void {
        const client = self.borrowClient() orelse return error.MovedOrCopied;
        client.poison(reason);
    }

    fn borrowClient(self: *GenerationTransport) ?*client_mod.Client {
        if (!rawLifecycleValid(&self.lifecycle) or self.self_addr != @intFromPtr(self) or
            self.lifecycle != .live or
            self.slot_addr == 0 or self.owner_seal_addr == 0 or self.owner_size == 0 or
            self.transport_incarnation == 0 or
            self.connection_generation != 1 or self.pid != currentPid() or
            self.owner_thread_id != std.Thread.getCurrentId())
            return null;
        const owner_seal: *const contract.TransportOwnerSeal = @ptrFromInt(self.owner_seal_addr);
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        if (!bindingRoleRawValid(&self.binding_reservation.identity.role) or
            !slot.valid() or slot.incarnation.tagged != self.slot_incarnation or
            slot.current.incarnation.tagged != self.node_incarnation or
            slot.current.client.host_id != self.host_id or
            slot.process_nonce != self.process_nonce)
            return null;
        const canonical_seal = slot.transportOwnerSeal(self.binding_reservation) catch return null;
        if (canonical_seal != owner_seal or !canonical_seal.valid(self.transport_incarnation))
            return null;
        return slot.logicalClient();
    }

    fn borrowInputClient(self: *GenerationTransport) InputError!*client_mod.Client {
        const client = self.borrowClient() orelse return error.InvalidOwner;
        if (!self.controllerBindingValid()) return error.Unauthorized;
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        if (!slot.streamOperationPermitIdle() or client.hasBufferedControllerRevoke())
            return error.Busy;
        return client;
    }

    fn controllerBindingValid(self: *const GenerationTransport) bool {
        if (self.bound_stream_id == 0 or
            !bindingRoleRawValid(&self.binding_reservation.identity.role) or
            self.binding_reservation.identity.role != .controller or self.slot_addr == 0)
            return false;
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        return slot.controllerAuthorityLive(
            self.binding_reservation,
            self.bound_stream_id,
        ) catch false;
    }

    fn controllerRevokePending(self: *const GenerationTransport) bool {
        if (self.bound_stream_id == 0 or
            !bindingRoleRawValid(&self.binding_reservation.identity.role) or
            self.binding_reservation.identity.role != .controller or self.slot_addr == 0)
            return false;
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        return slot.controllerRevokePending(
            self.binding_reservation,
            self.bound_stream_id,
        ) catch false;
    }

    fn requestIdentityValid(self: *const GenerationTransport) bool {
        const identity = self.binding_reservation.identity;
        return rawLifecycleValid(&self.lifecycle) and self.self_addr == @intFromPtr(self) and
            self.lifecycle == .live and self.slot_addr != 0 and self.owner_seal_addr != 0 and
            self.owner_size != 0 and self.transport_incarnation != 0 and
            self.connection_generation == 1 and self.pid == currentPid() and
            self.owner_thread_id == std.Thread.getCurrentId() and
            bindingRoleRawValid(&identity.role) and
            self.slot_incarnation == identity.slot_incarnation and
            self.node_incarnation == identity.node_incarnation and self.host_id == identity.host_id and
            self.connection_generation == identity.connection_generation and
            self.pid == identity.pid and self.process_nonce == identity.process_nonce;
    }

    fn requestOperation(
        self: *GenerationTransport,
        receipt: contract.PreparedCallReceipt,
    ) client_slot_mod.GenerationRequestAbort {
        return .{
            .slot_addr = self.slot_addr,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .transport_addr = @intFromPtr(self),
            .transport_incarnation = self.transport_incarnation,
            .owner_seal_addr = self.owner_seal_addr,
            .prepared_storage_addr = @intFromPtr(&self.prepared_storage),
            .reservation = self.binding_reservation,
            .receipt = receipt,
        };
    }

    fn ownerQuery(self: *GenerationTransport) client_slot_mod.GenerationTransportOwnerQuery {
        return .{
            .slot_addr = self.slot_addr,
            .slot_incarnation = self.slot_incarnation,
            .node_incarnation = self.node_incarnation,
            .host_id = self.host_id,
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .transport_addr = @intFromPtr(self),
            .transport_incarnation = self.transport_incarnation,
            .owner_seal_addr = self.owner_seal_addr,
            .prepared_storage_addr = @intFromPtr(&self.prepared_storage),
            .reservation = self.binding_reservation,
        };
    }
};

fn mapPrepareError(err: client_slot_mod.GenerationRequestError) PrepareError {
    return switch (err) {
        error.Busy => error.Busy,
        error.InvalidOwner => error.InvalidOwner,
        error.Unauthorized => error.Unauthorized,
        error.IdentityExhausted => error.IdentityExhausted,
        error.ResourceExhausted => error.ResourceExhausted,
        error.ConnectionClosed => error.ConnectionClosed,
        error.InvalidReceipt, error.ProtocolError => error.ProtocolError,
    };
}

fn mapAbortError(err: client_slot_mod.GenerationRequestError) AbortError {
    return switch (err) {
        error.Busy => error.Busy,
        error.InvalidOwner => error.InvalidOwner,
        error.InvalidReceipt => error.InvalidReceipt,
        error.Unauthorized,
        error.IdentityExhausted,
        error.ResourceExhausted,
        error.ConnectionClosed,
        error.ProtocolError,
        => error.ProtocolError,
    };
}

fn mapGenerationRequestToLegacyError(err: client_slot_mod.GenerationRequestError) Error {
    return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner => error.MovedOrCopied,
        error.Unauthorized => error.ProtocolError,
        error.InvalidReceipt => error.InvalidReceipt,
        error.IdentityExhausted => error.IdentityExhausted,
        error.ResourceExhausted => error.OutOfMemory,
        error.ConnectionClosed => error.ConnectionClosed,
        error.ProtocolError => error.InvalidReceipt,
    };
}

fn mapGenerationExecuteToLegacyError(err: client_slot_mod.GenerationExecuteError) Error {
    return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner => error.MovedOrCopied,
        error.Unauthorized => error.ProtocolError,
        error.InvalidReceipt => error.InvalidReceipt,
        error.IdentityExhausted => error.IdentityExhausted,
        error.ResourceExhausted => error.OutOfMemory,
        error.InvalidResponseDestination => error.InvalidResponseDestination,
        else => |client_err| client_err,
    };
}

fn rawLifecycleValid(value: *const Lifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(Lifecycle.terminal);
}

fn bindingRoleRawValid(value: *const contract.AttachmentRole) bool {
    return contract.attachmentRoleRawValid(value);
}

fn mapInputError(err: client_mod.ClientError) InputError {
    return switch (err) {
        error.AdminBusy => error.Busy,
        error.Unauthorized => error.Unauthorized,
        error.OutOfMemory, error.EventQueueFull => error.ResourceExhausted,
        error.ConnectionClosed, error.WriteFailed => error.ConnectionClosed,
        error.EndpointAbsent,
        error.EndpointDenied,
        error.EndpointTransient,
        error.HandshakeFailed,
        error.IncompatibleVersion,
        error.ProtocolError,
        error.ExternalMode,
        => error.ProtocolError,
    };
}

pub fn mintInPlace(
    out: *GenerationTransport,
    slot: *client_slot_mod.ClientSlot,
    owner_addr: usize,
    owner_size: usize,
    binding_reservation: client_slot_mod.AttachmentBindingReservation,
) Error!void {
    if (owner_size == 0) return error.InvalidTransport;
    const owner_end = std.math.add(usize, owner_addr, owner_size) catch
        return error.InvalidTransport;
    const transport_start = @intFromPtr(out);
    const transport_end = std.math.add(usize, transport_start, @sizeOf(GenerationTransport)) catch
        return error.InvalidTransport;
    const storage_start = @intFromPtr(&out.prepared_storage);
    const storage_end = std.math.add(
        usize,
        storage_start,
        @sizeOf(client_mod.PreparedBlockingRpcStorage),
    ) catch return error.InvalidTransport;
    if (owner_addr > transport_start or transport_end > owner_end or
        owner_addr > storage_start or storage_end > owner_end)
        return error.InvalidTransport;
    const owner_seal = slot.transportOwnerSeal(binding_reservation) catch
        return error.InvalidTransport;
    if (rangeOverlapsTyped(owner_addr, owner_end, owner_seal) or
        rangeOverlapsTyped(owner_addr, owner_end, slot) or
        rangeOverlapsTyped(owner_addr, owner_end, slot.current) or
        rangeOverlapsTyped(owner_addr, owner_end, &slot.current.client) or
        rangesOverlapTyped(out, owner_seal) or rangesOverlapTyped(out, slot) or
        rangesOverlapTyped(out, slot.current) or
        rangesOverlapTyped(out, &slot.current.client))
        return error.InvalidTransport;
    if (!rawLifecycleValid(&out.lifecycle) or out.self_addr != 0 or out.lifecycle != .pristine or
        owner_seal.self_addr != 0 or owner_seal.lifecycle != .pristine)
        return error.DestinationOccupied;
    if (!slot.valid() or owner_addr == 0) return error.InvalidTransport;
    const incarnation = issueIncarnation(&transport_incarnation_issuer) catch
        return error.IdentityExhausted;
    contract.TransportOwnerSeal.initInPlace(
        owner_seal,
        incarnation,
        owner_addr,
        owner_size,
        @intFromPtr(out),
        @intFromPtr(&out.prepared_storage),
    ) catch
        return error.InvalidTransport;
    out.* = .{
        .self_addr = @intFromPtr(out),
        .owner_addr = owner_addr,
        .owner_size = owner_size,
        .owner_seal_addr = @intFromPtr(owner_seal),
        .slot_addr = @intFromPtr(slot),
        .slot_incarnation = slot.incarnation.tagged,
        .node_incarnation = slot.current.incarnation.tagged,
        .host_id = slot.current.client.host_id,
        .connection_generation = 1,
        .transport_incarnation = incarnation,
        .pid = slot.pid,
        .process_nonce = slot.process_nonce,
        .owner_thread_id = std.Thread.getCurrentId(),
        .lifecycle = .live,
        .binding_reservation = binding_reservation,
    };
    initial_snapshot_owner_mod.Authority.initInPlace(
        &out.snapshot_authority,
        incarnation,
    ) catch unreachable;
}

test "CR3a-2c3b transport mint rejects every non-containing declared owner range" {
    const Case = enum { disjoint, prefix_partial, suffix_partial, adjacent, overflow };
    inline for (std.enums.values(Case)) |case| {
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        const allocator = std.testing.allocator;
        var client: client_mod.Client = .{
            .allocator = allocator,
            .fd = -1,
            .host_id = 0xC3B0,
            .parser = framing.FrameParser.init(allocator),
        };
        var slot: client_slot_mod.ClientSlot = undefined;
        try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xC3B0);
        defer slot.deinit();
        var transport: GenerationTransport = .{};
        const start = @intFromPtr(&transport);
        const extent = @sizeOf(GenerationTransport);
        const owner_range: struct { addr: usize, size: usize } = switch (case) {
            .disjoint => .{ .addr = start + extent + 1, .size = extent },
            .prefix_partial => .{ .addr = start, .size = extent - 1 },
            .suffix_partial => .{ .addr = start + 1, .size = extent },
            .adjacent => .{ .addr = start + extent, .size = 1 },
            .overflow => .{ .addr = std.math.maxInt(usize) - 1, .size = 4 },
        };
        var binding: contract.PreparedAttachmentBinding = .{};
        var lease: @import("connection_lease.zig").ConnectionLease = .{};
        const reservation = try slot.reserveAttachmentBindingForTest(
            &binding,
            &lease,
            owner_range.addr,
        );
        try std.testing.expectError(
            error.InvalidTransport,
            mintInPlace(&transport, &slot, owner_range.addr, owner_range.size, reservation),
        );
        try std.testing.expect(std.meta.eql(GenerationTransport{}, transport));
        try std.testing.expect((try slot.transportOwnerSeal(reservation)).settledExact());
        try slot.abortAttachmentBinding(&binding, reservation);
    }
}

test "CR3a-2c3b transport mint rejects an overbroad owner range crossing canonical slot state" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B1,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xC3B1);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xC3B2);
    const transport_start = @intFromPtr(&transport);
    const transport_end = transport_start + @sizeOf(GenerationTransport);
    const slot_start = @intFromPtr(&slot);
    const slot_end = slot_start + @sizeOf(client_slot_mod.ClientSlot);
    const owner_start = @min(transport_start, slot_start);
    const owner_end = @max(transport_end, slot_end);
    try std.testing.expectError(
        error.InvalidTransport,
        mintInPlace(&transport, &slot, owner_start, owner_end - owner_start, reservation),
    );
    try std.testing.expect(std.meta.eql(GenerationTransport{}, transport));
    try std.testing.expect((try slot.transportOwnerSeal(reservation)).settledExact());
    try slot.abortAttachmentBinding(&binding, reservation);
}

/// Binding commit 직후 final attachment owner만 호출하는 allocation-free stream seal이다.
pub fn bindCommittedStreamOwned(
    transport: *GenerationTransport,
    owner_addr: usize,
    stream_id: u64,
) Error!void {
    if (!rawLifecycleValid(&transport.lifecycle) or stream_id == 0 or
        transport.self_addr != @intFromPtr(transport) or
        transport.lifecycle != .live or transport.owner_addr != owner_addr or
        transport.bound_stream_id != 0 or transport.borrowClient() == null)
        return error.InvalidTransport;
    transport.bound_stream_id = stream_id;
}

pub fn beginControllerRevokeOwned(
    transport: *GenerationTransport,
    owner_addr: usize,
) Error!client_slot_mod.StreamOperationPermit {
    if (transport.owner_addr != owner_addr or transport.borrowClient() == null or
        !transport.controllerBindingValid())
        return error.InvalidTransport;
    const slot: *client_slot_mod.ClientSlot = @ptrFromInt(transport.slot_addr);
    const permit = slot.prepareStreamOperationPermit(
        .controller_revoke,
        owner_addr,
        transport.transport_incarnation,
        transport.binding_reservation.identity,
    ) catch return error.InvalidTransport;
    errdefer slot.abortStreamOperationPermit(permit) catch
        @panic("controller revoke permit rollback failed");
    slot.beginControllerRevoke(
        transport.binding_reservation,
        transport.bound_stream_id,
    ) catch return error.InvalidTransport;
    return permit;
}

pub fn finishControllerRevokeOwned(
    transport: *GenerationTransport,
    owner_addr: usize,
    permit: client_slot_mod.StreamOperationPermit,
) Error!void {
    if (transport.owner_addr != owner_addr or transport.borrowClient() == null or
        !transport.controllerRevokePending())
        return error.InvalidTransport;
    const slot: *client_slot_mod.ClientSlot = @ptrFromInt(transport.slot_addr);
    if (!slot.streamOperationPermitLive(permit) or permit.kind != .controller_revoke)
        return error.InvalidTransport;
    slot.finishControllerRevoke(
        transport.binding_reservation,
        transport.bound_stream_id,
    ) catch return error.InvalidTransport;
    slot.consumeStreamOperationPermit(permit) catch return error.InvalidTransport;
}

/// GenerationAttachment's read-only UI admission query. It keeps the stream-local revoke lookup
/// behind the sealed transport without expanding the planned 2c4 exact facade or exposing Client.
pub fn mutationAllowedOwned(transport: *GenerationTransport, owner_addr: usize) bool {
    if (transport.owner_addr != owner_addr) return false;
    const client = transport.borrowClient() orelse return false;
    if (!transport.controllerBindingValid()) return false;
    const slot: *client_slot_mod.ClientSlot = @ptrFromInt(transport.slot_addr);
    return slot.streamOperationPermitIdle() and
        !client.hasBufferedControllerRevokeForStream(transport.bound_stream_id);
}

/// Connection-wide revoke ordering query for the final-address GenerationAttachment owner.
/// Invalid ownership is conservatively busy so no raw Client RPC can flush mutation wire.
pub fn bufferedControllerRevokeOwned(
    transport: *GenerationTransport,
    owner_addr: usize,
) bool {
    if (transport.owner_addr != owner_addr) return true;
    const client = transport.borrowClient() orelse return true;
    return client.hasBufferedControllerRevoke();
}

/// Owner-only no-I/O authority fence. It remains module-level so terminalization is not exposed as
/// a general facade operation; source boundaries pin its sole production caller to the attachment.
pub fn terminalizeOwned(transport: *GenerationTransport, owner_addr: usize) Error!void {
    if (preflightTerminalizeOwned(transport, owner_addr) != .ready)
        return error.InvalidTransport;
    transport.snapshot_authority.terminalize(transport.transport_incarnation) catch unreachable;
    client_slot_mod.terminalizeGenerationTransportOwner(transport.ownerQuery()) catch
        return error.InvalidTransport;
    transport.lifecycle = .terminal;
    transport.slot_addr = 0;
    transport.owner_addr = 0;
    transport.owner_size = 0;
    transport.owner_seal_addr = 0;
    transport.bound_stream_id = 0;
}

pub const TerminalizeReadiness = enum { ready, busy, invalid };

pub fn preflightTerminalizeOwned(
    transport: *GenerationTransport,
    owner_addr: usize,
) TerminalizeReadiness {
    if (!rawLifecycleValid(&transport.lifecycle) or
        transport.self_addr != @intFromPtr(transport) or transport.lifecycle != .live or
        transport.owner_addr == 0 or transport.owner_addr != owner_addr or transport.owner_seal_addr == 0 or
        !client_mod.Client.preparedBlockingRpcStorageSettled(&transport.prepared_storage))
        return .invalid;
    if (!transport.snapshot_authority.canTerminalize(transport.transport_incarnation))
        return .busy;
    client_slot_mod.preflightGenerationTransportTerminalize(transport.ownerQuery()) catch |err|
        return switch (err) {
            error.Busy => .busy,
            error.InvalidOwner => .invalid,
        };
    return .ready;
}

fn rangesOverlapTyped(a: anytype, b: anytype) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, @sizeOf(@TypeOf(a.*))) catch return true;
    const b_end = std.math.add(usize, b_start, @sizeOf(@TypeOf(b.*))) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn rangeOverlapsTyped(start: usize, end: usize, owner: anytype) bool {
    const owner_start = @intFromPtr(owner);
    const owner_end = std.math.add(usize, owner_start, @sizeOf(@TypeOf(owner.*))) catch
        return true;
    return start < owner_end and owner_start < end;
}

fn payloadOverlaps(payload: []const u8, owners: anytype) bool {
    const start = @intFromPtr(payload.ptr);
    const end = std.math.add(usize, start, payload.len) catch return true;
    inline for (owners) |owner| {
        const owner_start = @intFromPtr(owner);
        const owner_end = std.math.add(usize, owner_start, @sizeOf(@TypeOf(owner.*))) catch
            return true;
        if (start < owner_end and owner_start < end) return true;
    }
    return false;
}

fn rangeOverlaps(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

test "CR3a-2a response payload range rejects exact partial and overflow owner aliases" {
    var owner: GenerationTransport = .{};
    const bytes: [*]const u8 = @ptrCast(&owner);
    try std.testing.expect(payloadOverlaps(bytes[0..1], .{&owner}));
    try std.testing.expect(payloadOverlaps(bytes[@sizeOf(GenerationTransport) - 1 ..][0..1], .{&owner}));
    const overflow_addr = std.math.maxInt(usize) - 7;
    const overflow: [*]const u8 = @ptrFromInt(overflow_addr);
    try std.testing.expect(payloadOverlaps(overflow[0..16], .{&owner}));
    var separate: u8 = 0;
    try std.testing.expect(!payloadOverlaps((&separate)[0..1], .{&owner}));
}

fn currentPid() u32 {
    return if (builtin.os.tag == .macos) @intCast(c.getpid()) else 1;
}

fn issueIncarnation(issuer: *std.atomic.Value(u64)) error{IdentityExhausted}!u64 {
    var observed = issuer.load(.acquire);
    while (true) {
        if (observed == 0 or observed == std.math.maxInt(u64))
            return error.IdentityExhausted;
        if (issuer.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual| {
            observed = actual;
            continue;
        }
        return observed;
    }
}

fn isForbiddenFacadeType(comptime T: type) bool {
    if (T == client_mod.Client) return true;
    return switch (@typeInfo(T)) {
        .pointer => |info| isForbiddenFacadeType(info.child),
        .optional => |info| isForbiddenFacadeType(info.child),
        .array => |info| isForbiddenFacadeType(info.child),
        .error_union => |info| isForbiddenFacadeType(info.payload),
        .@"struct" => |info| blk: {
            for (info.fields) |field| if (isForbiddenFacadeType(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            for (info.fields) |field| if (isForbiddenFacadeType(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

comptime {
    if (CapabilityError != error{ Busy, InvalidOwner })
        @compileError("GenerationTransport CapabilityError changed without updating CR3a-2c3b SSOT");
    if (@TypeOf(GenerationTransport.capabilities) !=
        fn (*const GenerationTransport) CapabilityError!contract.GenerationCapabilities)
        @compileError("GenerationTransport capabilities signature drifted");
    if (InputError != error{
        Busy,
        InvalidOwner,
        Unauthorized,
        ResourceExhausted,
        ConnectionClosed,
        ProtocolError,
    }) @compileError("GenerationTransport InputError changed without updating CR3a-2c3a SSOT");
    if (@TypeOf(GenerationTransport.sendInput) !=
        fn (*GenerationTransport, []const u8) InputError!void or
        @TypeOf(GenerationTransport.sendInputNonBlocking) !=
            fn (*GenerationTransport, []const u8) InputError!usize or
        @TypeOf(GenerationTransport.pumpPendingOutput) !=
            fn (*GenerationTransport) InputError!bool or
        @TypeOf(GenerationTransport.fenceRevoke) !=
            fn (*GenerationTransport) InputError!RevokeFence)
        @compileError("GenerationTransport input facade signature drifted");
    const expected_revoke_fields = [_][]const u8{
        "no_pending_stream_frame",
        "cancelled_before_write",
        "partial_frame_requires_close",
    };
    const actual_revoke_fields = std.meta.fields(RevokeFence);
    if (actual_revoke_fields.len != expected_revoke_fields.len)
        @compileError("GenerationTransport RevokeFence changed without updating SSOT");
    for (actual_revoke_fields, expected_revoke_fields) |actual, expected|
        if (!std.mem.eql(u8, actual.name, expected))
            @compileError("GenerationTransport RevokeFence changed without updating SSOT");
    const methods = .{
        GenerationTransport.capabilities,
        GenerationTransport.prepareRequest,
        GenerationTransport.executePreparedRequest,
        GenerationTransport.abortPreparedRequest,
        GenerationTransport.sendInput,
        GenerationTransport.sendInputNonBlocking,
        GenerationTransport.pumpPendingOutput,
        GenerationTransport.fenceRevoke,
        GenerationTransport.poison,
    };
    for (methods) |method| {
        const info = @typeInfo(@TypeOf(method)).@"fn";
        for (info.params, 0..) |param, index| {
            if (index == 0) continue; // final-address self is the facade, not an escaped Client owner.
            if (param.type) |Param| if (isForbiddenFacadeType(Param))
                @compileError("GenerationTransport public facade exposes Client-owned backing");
        }
        if (info.return_type) |Return| if (isForbiddenFacadeType(Return))
            @compileError("GenerationTransport public facade returns Client-owned backing");
    }
}

test "CR3a-2a generation transport prepares and aborts a closed attach request" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xAA,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xAA);
    defer slot.deinit();

    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    try std.testing.expectEqual(@as(u64, 1), receipt.request_id);
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2c3b find family authority follows its typed scroll discriminator" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;

    var controller_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3BF1,
        .parser = framing.FrameParser.init(allocator),
    };
    var controller_slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(
        &controller_slot,
        allocator,
        &controller_client,
        0x2C3BF1,
    );
    defer controller_slot.deinit();
    var controller_transport: GenerationTransport = .{};
    var controller_binding: contract.PreparedAttachmentBinding = .{};
    var controller_lease: @import("connection_lease.zig").ConnectionLease = .{};
    const controller_reservation = try controller_slot.reserveAttachmentBindingForTest(
        &controller_binding,
        &controller_lease,
        @intFromPtr(&controller_transport),
    );
    try mintInPlace(
        &controller_transport,
        &controller_slot,
        @intFromPtr(&controller_transport),
        @sizeOf(GenerationTransport),
        controller_reservation,
    );
    try controller_slot.current.cleanup_registry.bindStream(
        controller_reservation.cleanup,
        controller_reservation.identity,
        41,
    );
    try bindCommittedStreamOwned(&controller_transport, @intFromPtr(&controller_transport), 41);
    const mutation = try controller_transport.prepareRequest(contract.RuntimeRequest.find(
        contract.FindRequest.init("needle", 0, true).?,
    ));
    try controller_transport.abortPreparedRequest(mutation);
    try controller_slot.current.cleanup_registry.beginBoundDrop(
        controller_reservation.cleanup,
        controller_reservation.identity,
        41,
    );
    try terminalizeOwned(&controller_transport, @intFromPtr(&controller_transport));
    try controller_slot.current.cleanup_registry.completeActiveDrop(
        controller_reservation.cleanup,
        controller_reservation.identity,
        41,
    );
    controller_slot.current.pin_owner.cleanup_pin_count -= 1;
    controller_binding.lifecycle = .terminal;

    var observer_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3BF4,
        .parser = framing.FrameParser.init(allocator),
    };
    var observer_slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(
        &observer_slot,
        allocator,
        &observer_client,
        0x2C3BF4,
    );
    defer observer_slot.deinit();
    var observer_transport: GenerationTransport = .{};
    var observer_binding: contract.PreparedAttachmentBinding = .{};
    var observer_lease: @import("connection_lease.zig").ConnectionLease = .{};
    const observer_reservation = try observer_slot.reserveAttachmentBinding(
        &observer_binding,
        &observer_lease,
        @intFromPtr(&observer_transport),
        .observer,
    );
    try mintInPlace(
        &observer_transport,
        &observer_slot,
        @intFromPtr(&observer_transport),
        @sizeOf(GenerationTransport),
        observer_reservation,
    );
    try observer_slot.current.cleanup_registry.bindStream(
        observer_reservation.cleanup,
        observer_reservation.identity,
        43,
    );
    try bindCommittedStreamOwned(&observer_transport, @intFromPtr(&observer_transport), 43);
    try std.testing.expectError(error.Unauthorized, observer_transport.prepareRequest(
        contract.RuntimeRequest.find(contract.FindRequest.init("needle", 0, true).?),
    ));
    const observation = try observer_transport.prepareRequest(contract.RuntimeRequest.find(
        contract.FindRequest.init("needle", 0, false).?,
    ));
    try observer_transport.abortPreparedRequest(observation);
    try observer_slot.current.cleanup_registry.beginBoundDrop(
        observer_reservation.cleanup,
        observer_reservation.identity,
        43,
    );
    try terminalizeOwned(&observer_transport, @intFromPtr(&observer_transport));
    try observer_slot.current.cleanup_registry.completeActiveDrop(
        observer_reservation.cleanup,
        observer_reservation.identity,
        43,
    );
    observer_slot.current.pin_owner.cleanup_pin_count -= 1;
    observer_binding.lifecycle = .terminal;
}

test "CR3a-2c3b terminalize consults node request authority despite storage restore" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3B71,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3B71);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    const saved = transport.prepared_storage.bytes;
    @memset(&transport.prepared_storage.bytes, 0);
    try std.testing.expectEqual(
        TerminalizeReadiness.busy,
        preflightTerminalizeOwned(&transport, @intFromPtr(&transport)),
    );
    try std.testing.expectError(error.InvalidTransport, terminalizeOwned(&transport, @intFromPtr(&transport)));
    transport.prepared_storage.bytes = saved;
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2c1 final snapshot owner rejects copy thread replay and restored transport authority" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xAB,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xAB);
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);

    var owner: initial_snapshot_owner_mod.InitialSnapshotOwner = .{};
    const canonical = try slot.prepareInitialSnapshotPermit(
        @intFromPtr(&owner),
        transport.transport_incarnation,
        reservation.identity,
    );
    const local = try transport.snapshot_authority.prepare(
        @intFromPtr(&owner),
        transport.transport_incarnation,
    );
    const bytes = try allocator.dupe(u8, "snapshot");
    try initial_snapshot_owner_mod.InitialSnapshotOwner.initInPlace(
        &owner,
        allocator,
        bytes,
        .{
            .transport_incarnation = transport.transport_incarnation,
            .slot_incarnation = reservation.identity.slot_incarnation,
            .node_incarnation = reservation.identity.node_incarnation,
            .host_id = reservation.identity.host_id,
            .connection_generation = reservation.identity.connection_generation,
            .pid = reservation.identity.pid,
            .process_nonce = reservation.identity.process_nonce,
            .owner_thread_id = std.Thread.getCurrentId(),
            .stream_id = 7,
            .binding_incarnation = reservation.identity.binding_incarnation,
            .binding_storage_addr = reservation.identity.binding_storage_addr,
            .binding_destination_addr = reservation.identity.destination_addr,
            .binding_reservation_id = reservation.identity.binding_reservation_id,
            .runtime_id = reservation.identity.runtime_id,
            .role = reservation.identity.role,
        },
        &transport.snapshot_authority,
        local,
        canonical,
    );
    var copied_owner = owner;
    const copied_transport = transport;
    try std.testing.expectError(error.MovedOrCopied, copied_owner.borrow());
    const ThreadProbe = struct {
        fn run(target: *initial_snapshot_owner_mod.InitialSnapshotOwner, rejected: *[2]bool) void {
            _ = target.borrow() catch {
                rejected[0] = true;
            };
            target.deinit() catch {
                rejected[1] = true;
            };
        }
    };
    var rejected = [_]bool{ false, false };
    var thread = try std.Thread.spawn(.{}, ThreadProbe.run, .{ &owner, &rejected });
    thread.join();
    try std.testing.expect(rejected[0] and rejected[1]);
    try owner.deinit();
    try std.testing.expectError(error.MovedOrCopied, owner.deinit());
    const consumed_transport = transport;
    owner = copied_owner;
    transport = copied_transport;
    try std.testing.expectError(error.MovedOrCopied, owner.deinit());
    transport = consumed_transport;
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.abortAttachmentBinding(&binding, reservation);
    slot.deinit();
    @memset(std.mem.asBytes(&slot), 0xA5);
    owner = copied_owner;
    try std.testing.expectError(error.MovedOrCopied, owner.borrow());
    try std.testing.expectError(error.MovedOrCopied, owner.deinit());
}

test "CR3a-2a copied generation transport cannot prepare or mutate Client" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xBB,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xBB);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    var copied = transport;
    try std.testing.expectError(
        error.InvalidOwner,
        copied.prepareRequest(contract.RuntimeRequest.attachController()),
    );
    try std.testing.expectEqual(Lifecycle.live, transport.lifecycle);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** @sizeOf(client_mod.PreparedBlockingRpcStorage)),
        &transport.prepared_storage.bytes,
    );
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    try std.testing.expectEqual(@as(u64, 1), receipt.request_id);
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2c3b capability projection is exact and rejects stale or busy ownership" {
    const test_protocol = @import("protocol.zig");
    const test_compatibility = @import("compatibility.zig");
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3BCA,
        .parser = framing.FrameParser.init(allocator),
    };
    client.wire_major = test_protocol.version_major;
    client.screen_codec_version = 2;
    client.compatibility_profile = test_compatibility.profileForMajor(test_protocol.version_major).?;
    client.metadata_support = .supported;
    client.attachment_capabilities.peer_attach_generation = true;
    client.screen_viewport_scrolled_v1 = false;
    client.async_scroll_to_bottom_v1 = true;
    client.notification_stream_auth_v1 = false;
    client.runtime_clipboard_v1 = true;
    client.runtime_core_command_v1 = false;
    client.runtime_link_at_v1 = true;
    client.runtime_selected_text_v1 = false;
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3BCA);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    const canonical_client = slot.logicalClient();

    const projected = try transport.capabilities();
    try std.testing.expectEqual(test_protocol.version_major, projected.wire_major);
    try std.testing.expectEqual(@as(u16, 2), projected.screen_codec_version);
    try std.testing.expectEqual(contract.AttachSchema.granted_roles, projected.attach_schema);
    try std.testing.expectEqual(contract.MetadataSupport.supported, projected.metadata_support);
    try std.testing.expect(projected.peer_attach_generation);
    try std.testing.expect(!projected.screen_viewport_scrolled);
    try std.testing.expect(projected.async_scroll_to_bottom);
    try std.testing.expect(!projected.notification_stream_auth);
    try std.testing.expect(projected.runtime_clipboard);
    try std.testing.expect(!projected.runtime_core_command);
    try std.testing.expect(projected.runtime_link_at);
    try std.testing.expect(!projected.runtime_selected_text);

    canonical_client.wire_major = 1;
    canonical_client.screen_codec_version = 1;
    canonical_client.compatibility_profile = test_compatibility.profileForMajor(1).?;
    canonical_client.metadata_support = .unsupported;
    canonical_client.attachment_capabilities.peer_attach_generation = false;
    canonical_client.screen_viewport_scrolled_v1 = true;
    canonical_client.async_scroll_to_bottom_v1 = false;
    canonical_client.notification_stream_auth_v1 = true;
    canonical_client.runtime_clipboard_v1 = false;
    canonical_client.runtime_core_command_v1 = true;
    canonical_client.runtime_link_at_v1 = false;
    canonical_client.runtime_selected_text_v1 = true;
    const previous = try transport.capabilities();
    try std.testing.expectEqual(@as(u16, 1), previous.wire_major);
    try std.testing.expectEqual(@as(u16, 1), previous.screen_codec_version);
    try std.testing.expectEqual(contract.AttachSchema.frozen_controller_only, previous.attach_schema);
    try std.testing.expectEqual(contract.MetadataSupport.unsupported, previous.metadata_support);
    try std.testing.expect(!previous.peer_attach_generation);
    try std.testing.expect(previous.screen_viewport_scrolled);
    try std.testing.expect(!previous.async_scroll_to_bottom);
    try std.testing.expect(previous.notification_stream_auth);
    try std.testing.expect(!previous.runtime_clipboard);
    try std.testing.expect(previous.runtime_core_command);
    try std.testing.expect(!previous.runtime_link_at);
    try std.testing.expect(previous.runtime_selected_text);

    var copied = transport;
    try std.testing.expectError(error.InvalidOwner, copied.capabilities());
    transport.slot_incarnation += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport.slot_incarnation -= 1;
    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        transport.owner_addr,
        transport.transport_incarnation,
        reservation.identity,
    );
    try std.testing.expectError(error.Busy, transport.capabilities());
    try slot.abortStreamOperationPermit(permit);

    slot.current.pin_owner.active_cleanup = 1;
    try std.testing.expectError(error.Busy, transport.capabilities());
    slot.current.pin_owner.active_cleanup = 0;

    slot.current.active_operation_kind = .ended_purge;
    try std.testing.expectError(error.Busy, transport.capabilities());
    slot.current.active_operation_kind = .none;
    slot.current.active_operation_owner_thread_incarnation = 1;
    try std.testing.expectError(error.Busy, transport.capabilities());
    slot.current.active_operation_owner_thread_incarnation = 0;
    slot.current.active_operation_owner_addr = 1;
    try std.testing.expectError(error.Busy, transport.capabilities());
    slot.current.active_operation_owner_addr = 0;
    slot.current.active_operation_transport_incarnation = 1;
    try std.testing.expectError(error.Busy, transport.capabilities());
    slot.current.active_operation_transport_incarnation = 0;
    const operation_kind_raw: *u8 = @ptrCast(&slot.current.active_operation_kind);
    var operation_kind_value: u16 =
        @as(u16, @intFromEnum(client_slot_mod.StreamOperationKind.ended_purge)) + 1;
    while (operation_kind_value <= std.math.maxInt(u8)) : (operation_kind_value += 1) {
        operation_kind_raw.* = @intCast(operation_kind_value);
        try std.testing.expectError(error.Busy, transport.capabilities());
    }
    slot.current.active_operation_kind = .none;

    transport.slot_addr = 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport.slot_addr = @intFromPtr(&slot);
    transport.host_id += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport.host_id -= 1;
    transport.process_nonce += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport.process_nonce -= 1;

    const canonical_owner_seal = try slot.transportOwnerSeal(reservation);
    const owner_lifecycle_raw: *u8 = @ptrCast(&canonical_owner_seal.lifecycle);
    var owner_lifecycle_value: u16 =
        @as(u16, @intFromEnum(contract.TransportOwnerLifecycle.terminal)) + 1;
    while (owner_lifecycle_value <= std.math.maxInt(u8)) : (owner_lifecycle_value += 1) {
        owner_lifecycle_raw.* = @intCast(owner_lifecycle_value);
        try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    }
    canonical_owner_seal.lifecycle = .live;

    if (canonical_client.compatibility_profile) |*profile| {
        const schema_raw: *u8 = @ptrCast(&profile.attach_schema);
        var raw: u16 = @as(u16, @intFromEnum(test_compatibility.AttachSchema.granted_roles)) + 1;
        while (raw <= std.math.maxInt(u8)) : (raw += 1) {
            schema_raw.* = @intCast(raw);
            try std.testing.expectError(error.InvalidOwner, transport.capabilities());
        }
        profile.attach_schema = .frozen_controller_only;
    }
    const metadata_raw: *u8 = @ptrCast(&canonical_client.metadata_support);
    var metadata_value: u16 = @as(u16, @intFromEnum(contract.MetadataSupport.supported)) + 1;
    while (metadata_value <= std.math.maxInt(u8)) : (metadata_value += 1) {
        metadata_raw.* = @intCast(metadata_value);
        try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    }
    canonical_client.metadata_support = .unsupported;

    if (builtin.os.tag == .macos) {
        const child = c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            const rejected = if (transport.capabilities()) |_| false else |err| err == error.InvalidOwner;
            std.c._exit(if (rejected) 0 else 1);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
    }

    transport.self_addr += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport.self_addr -= 1;
    transport.owner_seal_addr += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport.owner_seal_addr -= 1;

    const stale_transport = transport;
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    const terminal_transport = transport;
    transport = stale_transport;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    transport = terminal_transport;
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2c3a input facade rejects every invalid lifecycle and role byte before mutation" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3A,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3A);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 17);
    try bindCommittedStreamOwned(&transport, @intFromPtr(&transport), 17);

    const lifecycle_raw: *u8 = @ptrCast(&transport.lifecycle);
    var raw: u16 = 0;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        if (raw == @intFromEnum(Lifecycle.live)) continue;
        lifecycle_raw.* = @intCast(raw);
        try std.testing.expectError(error.InvalidOwner, transport.capabilities());
        try std.testing.expectError(error.InvalidOwner, transport.sendInput("x"));
        try std.testing.expectError(error.InvalidOwner, transport.sendInputNonBlocking("x"));
        try std.testing.expectError(error.InvalidOwner, transport.pumpPendingOutput());
        try std.testing.expectError(error.InvalidOwner, transport.fenceRevoke());
        try std.testing.expect(slot.logicalClient().pending_outbound == null);
    }
    lifecycle_raw.* = @intFromEnum(Lifecycle.live);

    const role_raw: *u8 = @ptrCast(&transport.binding_reservation.identity.role);
    raw = @intFromEnum(contract.AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        role_raw.* = @intCast(raw);
        try std.testing.expectError(error.InvalidOwner, transport.capabilities());
        try std.testing.expectError(error.InvalidOwner, transport.sendInputNonBlocking("x"));
        try std.testing.expectError(error.InvalidOwner, transport.pumpPendingOutput());
        try std.testing.expectError(error.InvalidOwner, transport.fenceRevoke());
        try std.testing.expect(slot.logicalClient().pending_outbound == null);
    }
    role_raw.* = @intFromEnum(contract.AttachmentRole.controller);

    var copied = transport;
    try std.testing.expectError(error.InvalidOwner, copied.capabilities());
    try std.testing.expectError(error.InvalidOwner, copied.sendInputNonBlocking("x"));
    try std.testing.expect(slot.logicalClient().pending_outbound == null);

    transport.slot_incarnation += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    try std.testing.expectError(error.InvalidOwner, transport.sendInputNonBlocking("stale-slot"));
    transport.slot_incarnation -= 1;
    transport.node_incarnation += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    try std.testing.expectError(error.InvalidOwner, transport.sendInputNonBlocking("stale-node"));
    transport.node_incarnation -= 1;
    transport.binding_reservation.identity.binding_reservation_id += 1;
    try std.testing.expectError(error.InvalidOwner, transport.capabilities());
    try std.testing.expectError(error.InvalidOwner, transport.sendInputNonBlocking("stale-binding"));
    transport.binding_reservation.identity.binding_reservation_id -= 1;
    try std.testing.expect(slot.logicalClient().pending_outbound == null);

    const ThreadProbe = struct {
        fn run(
            target: *GenerationTransport,
            rejected: *bool,
            capability_rejected: *bool,
            spoofed_thread_id_rejected: *bool,
        ) void {
            _ = target.capabilities() catch {
                capability_rejected.* = true;
            };
            _ = target.sendInputNonBlocking("x") catch {
                rejected.* = true;
            };
            const saved_thread_id = target.owner_thread_id;
            target.owner_thread_id = std.Thread.getCurrentId();
            target.poison(.local_invariant_violation) catch {
                spoofed_thread_id_rejected.* = true;
            };
            target.owner_thread_id = saved_thread_id;
        }
    };
    var cross_thread_rejected = false;
    var cross_thread_capability_rejected = false;
    var spoofed_thread_id_rejected = false;
    var thread = try std.Thread.spawn(.{}, ThreadProbe.run, .{
        &transport,
        &cross_thread_rejected,
        &cross_thread_capability_rejected,
        &spoofed_thread_id_rejected,
    });
    thread.join();
    try std.testing.expect(cross_thread_rejected);
    try std.testing.expect(cross_thread_capability_rejected);
    try std.testing.expect(spoofed_thread_id_rejected);
    try std.testing.expect(!slot.logicalClient().unusable);
    try std.testing.expect(slot.logicalClient().pending_outbound == null);

    const permit = try slot.prepareStreamOperationPermit(
        .ended_purge,
        transport.owner_addr,
        transport.transport_incarnation,
        reservation.identity,
    );
    try std.testing.expectError(error.Busy, transport.capabilities());
    try std.testing.expectError(error.Busy, transport.sendInputNonBlocking("x"));
    try std.testing.expect(slot.logicalClient().pending_outbound == null);
    try slot.abortStreamOperationPermit(permit);
    try slot.current.cleanup_registry.beginBoundDrop(reservation.cleanup, reservation.identity, 17);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.current.cleanup_registry.completeActiveDrop(reservation.cleanup, reservation.identity, 17);
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "CR3a-2c3a observer binding rejects input but permits shared output progress" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3C,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3C);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBinding(
        &binding,
        &lease,
        @intFromPtr(&transport),
        .observer,
    );
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 29);
    try bindCommittedStreamOwned(&transport, @intFromPtr(&transport), 29);
    try std.testing.expectError(error.Unauthorized, transport.sendInputNonBlocking("x"));
    try std.testing.expect(try transport.pumpPendingOutput());
    try std.testing.expectError(error.Unauthorized, transport.fenceRevoke());
    try std.testing.expect(slot.logicalClient().pending_outbound == null);
    try slot.current.cleanup_registry.beginBoundDrop(reservation.cleanup, reservation.identity, 29);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.current.cleanup_registry.completeActiveDrop(reservation.cleanup, reservation.identity, 29);
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "CR3a-2c3a input facade binds the sealed stream and preserves wire ownership" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    socket_server.setNoSigPipe(fds[0]);
    defer _ = c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0x2C3B,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3B);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 23);
    try bindCommittedStreamOwned(&transport, @intFromPtr(&transport), 23);

    const payload = "generation-input";
    try std.testing.expectEqual(payload.len, try transport.sendInputNonBlocking(payload));
    while (!(try transport.pumpPendingOutput())) {}
    const expected = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 23 },
        payload,
    );
    defer allocator.free(expected);
    const received = try allocator.alloc(u8, expected.len);
    defer allocator.free(received);
    var offset: usize = 0;
    while (offset < received.len) {
        const count = c.read(fds[1], received[offset..].ptr, received.len - offset);
        try std.testing.expect(count > 0);
        offset += @intCast(count);
    }
    try std.testing.expectEqualSlices(u8, expected, received);

    const partial = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 23 },
        "partial",
    );
    slot.logicalClient().pending_outbound = .{
        .frame = partial,
        .offset = 1,
        .stream_id = 23,
    };
    const revoke_permit = try beginControllerRevokeOwned(&transport, @intFromPtr(&transport));
    try std.testing.expectError(error.Unauthorized, transport.sendInputNonBlocking("late"));
    try std.testing.expectEqual(
        RevokeFence.partial_frame_requires_close,
        try transport.fenceRevoke(),
    );
    try finishControllerRevokeOwned(&transport, @intFromPtr(&transport), revoke_permit);
    try std.testing.expectError(error.Unauthorized, transport.sendInputNonBlocking("restored"));
    try std.testing.expect(slot.logicalClient().pending_outbound != null);

    try slot.current.cleanup_registry.beginBoundDrop(reservation.cleanup, reservation.identity, 23);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.current.cleanup_registry.completeActiveDrop(reservation.cleanup, reservation.identity, 23);
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "CR3a-2c3a input facade maps allocation and socket failure without authority drift" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var client: client_mod.Client = .{
        .allocator = failing.allocator(),
        .fd = -1,
        .host_id = 0x2C3D,
        .parser = framing.FrameParser.init(failing.allocator()),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3D);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 31);
    try bindCommittedStreamOwned(&transport, @intFromPtr(&transport), 31);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.ResourceExhausted,
        transport.sendInputNonBlocking("allocation-failure"),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(slot.logicalClient().pending_outbound == null);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(
        error.ConnectionClosed,
        transport.sendInputNonBlocking("closed-socket"),
    );
    try std.testing.expect(try slot.controllerAuthorityLive(reservation, 31));
    try std.testing.expect(slot.logicalClient().unusable);
    try slot.current.cleanup_registry.beginBoundDrop(reservation.cleanup, reservation.identity, 31);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.current.cleanup_registry.completeActiveDrop(reservation.cleanup, reservation.identity, 31);
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "B3-0.1 response destination rejection settles request reusable without poison" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var request_free = RequestBackingFreeProbe{ .parent = allocator };
    var client: client_mod.Client = .{
        .allocator = request_free.allocator(),
        .fd = -1,
        .host_id = 0xBC,
        .parser = framing.FrameParser.init(request_free.allocator()),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xBC);
    defer slot.deinit();
    const Shared = union {
        binding: contract.PreparedAttachmentBinding,
        response: executed_response_mod.ExecutedResponse,
    };
    const Owner = struct {
        transport: GenerationTransport = .{},
        shared: Shared = .{ .binding = .{} },
    };
    var owner: Owner = .{};
    const binding: *contract.PreparedAttachmentBinding = @ptrCast(&owner.shared);
    const response: *executed_response_mod.ExecutedResponse = @ptrCast(&owner.shared);
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(binding, &lease, @intFromPtr(&owner.transport));
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), reservation);
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    const canonical = (try slot.current.cleanup_registry.preparedRequestForReceipt(
        reservation.cleanup,
        reservation.identity,
        @intFromPtr(&owner.transport),
        owner.transport.transport_incarnation,
        receipt,
    )).?;
    request_free.arm(
        &slot,
        reservation,
        canonical,
    );
    try std.testing.expectError(
        error.InvalidResponseDestination,
        owner.transport.executePreparedRequest(receipt, response),
    );
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
        &owner.transport.prepared_storage,
    ));
    try std.testing.expectEqual(
        @import("prepared_request_authority.zig").SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            reservation.identity,
        ),
    );
    try slot.current.cleanup_registry.publishPreparedRequest(
        reservation.cleanup,
        reservation.identity,
        canonical,
    );
    try slot.current.cleanup_registry.settlePreparedRequest(
        reservation.cleanup,
        reservation.identity,
        canonical,
        false,
    );
    try std.testing.expect(slot.logicalClient().firstPoisonReason() == null);
    try request_free.expectExactOnceBeforeAuthoritySettlement();
    try std.testing.expectError(
        error.InvalidReceipt,
        owner.transport.abortPreparedRequest(receipt),
    );
    try std.testing.expect(binding.validAtFinalAddress());
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(binding, reservation);
}

test "B3-0.1 uncertain execute settles request terminal and preserves first poison" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var request_free = RequestBackingFreeProbe{ .parent = allocator };
    var client: client_mod.Client = .{
        .allocator = request_free.allocator(),
        .fd = -1,
        .host_id = 0xCC,
        .parser = framing.FrameParser.init(request_free.allocator()),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xCC);
    defer slot.deinit();
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&owner.transport));
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), reservation);
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    const canonical = (try slot.current.cleanup_registry.preparedRequestForReceipt(
        reservation.cleanup,
        reservation.identity,
        @intFromPtr(&owner.transport),
        owner.transport.transport_incarnation,
        receipt,
    )).?;
    request_free.arm(
        &slot,
        reservation,
        canonical,
    );
    const result = try owner.transport.executePreparedRequest(receipt, &owner.response);
    switch (result) {
        .uncertain_or_connection_failure => |executed| try std.testing.expect(
            executed.matchesPrepared(receipt),
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
        &owner.transport.prepared_storage,
    ));
    try std.testing.expectEqual(
        @import("prepared_request_authority.zig").SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            reservation.identity,
        ),
    );
    try std.testing.expectError(
        error.InvalidState,
        slot.current.cleanup_registry.publishPreparedRequest(
            reservation.cleanup,
            reservation.identity,
            canonical,
        ),
    );
    try std.testing.expectEqual(
        client_poison.ConnectionReason.outbound_write_ambiguous,
        slot.logicalClient().firstPoisonReason().?,
    );
    try request_free.expectExactOnceBeforeAuthoritySettlement();
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        owner.response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "B3-0.4 response publication failure poisons before exact payload free reentry" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var probe = PoisonOrderAllocator{ .parent = allocator };
    const response_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{}",
    );
    defer allocator.free(response_wire);
    const Peer = struct {
        fn run(fd: c.fd_t, wire: []const u8) void {
            defer _ = c.close(fd);
            var request: [4096]u8 = undefined;
            if (c.read(fd, &request, request.len) <= 0) return;
            socket_server.writeAll(fd, wire) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response_wire });
    defer peer.join();
    var client: client_mod.Client = .{
        .allocator = probe.allocator(),
        .fd = fds[0],
        .host_id = 0xDD,
        .parser = framing.FrameParser.init(probe.allocator()),
    };
    probe.client = &client;
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xDD);
    probe.client = slot.logicalClient();
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&owner.transport));
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), reservation);
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    probe.response = &owner.response;
    probe.armed = true;
    try std.testing.expectError(
        error.InvalidResponseDestination,
        owner.transport.executePreparedRequest(receipt, &owner.response),
    );
    probe.armed = false;
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expect(probe.saw_poison_before_free);
    try std.testing.expect(probe.reentry_rejected);
    try std.testing.expectEqual(@as(usize, 1), probe.payload_free_count);
    try std.testing.expect(slot.logicalClient().unusable);
    owner.response = .{};
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2c3b request allocation alias is rejected before canonical owner write" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xE1,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xE1);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    var transport: GenerationTransport = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&transport));
    try mintInPlace(&transport, &slot, @intFromPtr(&transport), @sizeOf(GenerationTransport), reservation);

    const binding_before = binding;
    var hostile = OperationAliasAllocator{
        .parent = allocator,
        .target = std.mem.asBytes(&binding),
        .armed = true,
    };
    slot.current.guarded_allocator.parent = hostile.allocator();
    try std.testing.expectError(
        error.ProtocolError,
        transport.prepareRequest(contract.RuntimeRequest.attachController()),
    );
    slot.current.guarded_allocator.parent = allocator;
    try std.testing.expect(hostile.alias_returned);
    try std.testing.expect(!hostile.alias_freed);
    try std.testing.expect(std.meta.eql(binding_before, binding));
    try std.testing.expect(slot.logicalClient().unusable);
    try terminalizeOwned(&transport, @intFromPtr(&transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "B3-0.4 request prepare sweeps every allocation failure before first success" {
    var reached_success = false;
    for (0..32) |fail_offset| {
        const identity_offset: u128 = fail_offset;
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        const allocator = std.testing.allocator;
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var client: client_mod.Client = .{
            .allocator = failing.allocator(),
            .fd = -1,
            .host_id = 0x2C3B40 + identity_offset,
            .parser = framing.FrameParser.init(failing.allocator()),
        };
        var slot: client_slot_mod.ClientSlot = undefined;
        try client_slot_mod.ClientSlot.initInPlace(
            &slot,
            allocator,
            &client,
            0x2C3B40 + identity_offset,
        );
        defer slot.deinit();
        var binding: contract.PreparedAttachmentBinding = .{};
        var lease: @import("connection_lease.zig").ConnectionLease = .{};
        var transport: GenerationTransport = .{};
        const reservation = try slot.reserveAttachmentBindingForTest(
            &binding,
            &lease,
            @intFromPtr(&transport),
        );
        try mintInPlace(
            &transport,
            &slot,
            @intFromPtr(&transport),
            @sizeOf(GenerationTransport),
            reservation,
        );
        const binding_before = binding;
        failing.fail_index = failing.alloc_index + fail_offset;
        if (transport.prepareRequest(contract.RuntimeRequest.attachController())) |receipt| {
            reached_success = true;
            try transport.abortPreparedRequest(receipt);
        } else |err| {
            try std.testing.expectEqual(error.ResourceExhausted, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expect(std.meta.eql(binding_before, binding));
            try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
                &transport.prepared_storage,
            ));
            try std.testing.expect(!slot.logicalClient().unusable);
        }
        try terminalizeOwned(&transport, @intFromPtr(&transport));
        try slot.abortAttachmentBinding(&binding, reservation);
        if (reached_success) break;
    }
    try std.testing.expect(reached_success);
}

test "CR3a-2c3b prepared request rejects a live cross-binding transport splice" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3B51,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3B51);
    defer slot.deinit();

    var binding_a: contract.PreparedAttachmentBinding = .{};
    var binding_b: contract.PreparedAttachmentBinding = .{};
    var lease_a: @import("connection_lease.zig").ConnectionLease = .{};
    var lease_b: @import("connection_lease.zig").ConnectionLease = .{};
    var transport_a: GenerationTransport = .{};
    const OwnerB = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner_b: OwnerB = .{};
    const reservation_a = try slot.reserveAttachmentBindingForTest(
        &binding_a,
        &lease_a,
        @intFromPtr(&transport_a),
    );
    const reservation_b = try slot.reserveAttachmentBindingForTest(
        &binding_b,
        &lease_b,
        @intFromPtr(&owner_b.transport),
    );
    try mintInPlace(
        &transport_a,
        &slot,
        @intFromPtr(&transport_a),
        @sizeOf(GenerationTransport),
        reservation_a,
    );
    try mintInPlace(
        &owner_b.transport,
        &slot,
        @intFromPtr(&owner_b),
        @sizeOf(OwnerB),
        reservation_b,
    );

    const receipt_a = try transport_a.prepareRequest(contract.RuntimeRequest.attachController());
    try std.testing.expectError(
        error.InvalidReceipt,
        owner_b.transport.executePreparedRequest(receipt_a, &owner_b.response),
    );
    try std.testing.expect(std.meta.eql(executed_response_mod.ExecutedResponse{}, owner_b.response));
    try std.testing.expect(!slot.logicalClient().unusable);
    try transport_a.abortPreparedRequest(receipt_a);

    try terminalizeOwned(&transport_a, @intFromPtr(&transport_a));
    try terminalizeOwned(&owner_b.transport, @intFromPtr(&owner_b.transport));
    try slot.abortAttachmentBinding(&binding_a, reservation_a);
    try slot.abortAttachmentBinding(&binding_b, reservation_b);
}

test "CR3a-2c3b stale prepared receipt fails after same-address transport reincarnation" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3B52,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3B52);
    defer slot.deinit();

    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const transport_addr = @intFromPtr(&owner.transport);
    const first = try slot.reserveAttachmentBindingForTest(&binding, &lease, transport_addr);
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), first);
    const stale_receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    try owner.transport.abortPreparedRequest(stale_receipt);
    const first_incarnation = owner.transport.transport_incarnation;
    try terminalizeOwned(&owner.transport, transport_addr);
    try slot.abortAttachmentBinding(&binding, first);

    binding = .{};
    lease = .{};
    owner = .{};
    const second = try slot.reserveAttachmentBindingForTest(&binding, &lease, transport_addr);
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), second);
    try std.testing.expect(owner.transport.transport_incarnation != first_incarnation);
    try std.testing.expectError(
        error.InvalidReceipt,
        owner.transport.executePreparedRequest(stale_receipt, &owner.response),
    );
    try std.testing.expectError(error.InvalidReceipt, owner.transport.abortPreparedRequest(stale_receipt));
    try std.testing.expect(std.meta.eql(executed_response_mod.ExecutedResponse{}, owner.response));
    try std.testing.expect(!slot.logicalClient().unusable);

    const fresh = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    try owner.transport.abortPreparedRequest(fresh);
    try terminalizeOwned(&owner.transport, transport_addr);
    try slot.abortAttachmentBinding(&binding, second);
}

test "CR3a-2c3b request allocation exact and partial transport-owner aliases are rejected before write" {
    const Harness = struct {
        fn run(partial_overlap: bool) !void {
            try client_slot_mod.ClientSlot.initializeProcessRuntime();
            const allocator = std.testing.allocator;
            var client: client_mod.Client = .{
                .allocator = allocator,
                .fd = -1,
                .host_id = 0xE3,
                .parser = framing.FrameParser.init(allocator),
            };
            var slot: client_slot_mod.ClientSlot = undefined;
            try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xE3);
            defer slot.deinit();
            var binding: contract.PreparedAttachmentBinding = .{};
            var lease: @import("connection_lease.zig").ConnectionLease = .{};
            const Owner = struct {
                prefix: [@alignOf(GenerationTransport)]u8 =
                    [_]u8{0} ** @alignOf(GenerationTransport),
                transport: GenerationTransport = .{},
            };
            var owner: Owner = .{};
            const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&owner.transport));
            const transport_addr = @intFromPtr(&owner.transport);
            try mintInPlace(
                &owner.transport,
                &slot,
                transport_addr,
                @sizeOf(GenerationTransport),
                reservation,
            );
            const transport_before = owner.transport;
            const target_addr = if (partial_overlap)
                transport_addr - 1
            else
                @intFromPtr(&owner.transport.owner_addr);
            const target: [*]u8 = @ptrFromInt(target_addr);
            var hostile = OperationAliasAllocator{
                .parent = allocator,
                .target = target[0..1],
                .armed = true,
            };
            slot.current.guarded_allocator.parent = hostile.allocator();
            try std.testing.expectError(
                error.ProtocolError,
                owner.transport.prepareRequest(contract.RuntimeRequest.attachController()),
            );
            slot.current.guarded_allocator.parent = allocator;
            try std.testing.expect(hostile.alias_returned);
            try std.testing.expect(!hostile.alias_freed);
            try std.testing.expect(std.meta.eql(transport_before, owner.transport));
            try std.testing.expect(slot.logicalClient().unusable);
            try terminalizeOwned(&owner.transport, transport_addr);
            try slot.abortAttachmentBinding(&binding, reservation);
        }
    };
    try Harness.run(false);
    try Harness.run(true);
}

test "CR3a-2c3b response allocation alias is rejected before destination write" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const child_marker = "MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC";
    const case_marker = "MARU_SESSION_HOST_RESPONSE_ALIAS_CASE";
    const marker_ptr = c.getenv(child_marker) orelse return;
    const marker = std.mem.span(marker_ptr);
    const strict_case = if (c.getenv(case_marker)) |raw| std.mem.span(raw) else "response_alias";
    if (std.mem.eql(u8, marker, "skip-in-aggregate-v1")) return;
    const child_mode = std.mem.eql(u8, marker, "execute-fixture-v1");
    if (!child_mode) {
        if (!std.mem.eql(u8, marker, "run-isolated-v1"))
            return error.InvalidResponseAliasSubprocessMode;
        const allocator = std.testing.allocator;
        const self_path_z = try std.process.executablePathAlloc(std.testing.io, allocator);
        defer allocator.free(self_path_z);
        var capability_pipe: [2]c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.pipe(&capability_pipe));
        var capability: u64 = undefined;
        std.testing.io.random(std.mem.asBytes(&capability));
        const capability_bytes = std.mem.asBytes(&capability);
        if (c.write(capability_pipe[1], capability_bytes.ptr, capability_bytes.len) != capability_bytes.len) {
            _ = c.close(capability_pipe[0]);
            _ = c.close(capability_pipe[1]);
            return error.TestUnexpectedResult;
        }
        var stderr_pipe: [2]c.fd_t = undefined;
        if (c.pipe(&stderr_pipe) != 0) {
            _ = c.close(capability_pipe[0]);
            _ = c.close(capability_pipe[1]);
            return error.TestUnexpectedResult;
        }
        defer _ = c.close(stderr_pipe[0]);
        const child = c.fork();
        if (child < 0) {
            _ = c.close(capability_pipe[0]);
            _ = c.close(capability_pipe[1]);
            _ = c.close(stderr_pipe[1]);
            return error.TestUnexpectedResult;
        }
        if (child == 0) {
            _ = c.close(capability_pipe[1]);
            _ = c.close(stderr_pipe[0]);
            if (c.dup2(stderr_pipe[1], 2) < 0) c._exit(126);
            _ = c.close(stderr_pipe[1]);
            var inherited_fd: c.fd_t = 3;
            while (inherited_fd < getdtablesize()) : (inherited_fd += 1) {
                if (inherited_fd != capability_pipe[0]) _ = c.close(inherited_fd);
            }
            var capability_fd_env_buf: [96]u8 = undefined;
            const capability_fd_env = std.fmt.bufPrintZ(
                &capability_fd_env_buf,
                "MARU_SESSION_HOST_RESPONSE_ALIAS_CAP_FD={d}",
                .{capability_pipe[0]},
            ) catch c._exit(126);
            var capability_env_buf: [96]u8 = undefined;
            const capability_env = std.fmt.bufPrintZ(
                &capability_env_buf,
                "MARU_SESSION_HOST_RESPONSE_ALIAS_CAP={x}",
                .{capability},
            ) catch c._exit(126);
            var case_env_buf: [128]u8 = undefined;
            const case_env = std.fmt.bufPrintZ(
                &case_env_buf,
                "MARU_SESSION_HOST_RESPONSE_ALIAS_CASE={s}",
                .{strict_case},
            ) catch c._exit(126);
            const argv = [_:null]?[*:0]const u8{self_path_z.ptr};
            const child_env = [_:null]?[*:0]const u8{
                "MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC=execute-fixture-v1",
                case_env.ptr,
                capability_fd_env.ptr,
                capability_env.ptr,
            };
            _ = c.execve(self_path_z.ptr, &argv, &child_env);
            c._exit(127);
        }
        _ = c.close(capability_pipe[0]);
        _ = c.close(capability_pipe[1]);
        _ = c.close(stderr_pipe[1]);
        const stderr_flags = c.fcntl(stderr_pipe[0], c.F.GETFL, @as(c_int, 0));
        if (stderr_flags < 0 or c.fcntl(
            stderr_pipe[0],
            c.F.SETFL,
            stderr_flags | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })),
        ) < 0) {
            _ = c.kill(child, c.SIG.KILL);
            _ = c.waitpid(child, null, 0);
            return error.TestUnexpectedResult;
        }
        var stderr_output: [64 * 1024]u8 = undefined;
        var stderr_total: usize = 0;
        var status: c_int = 0;
        var attempts: usize = 0;
        while (attempts < 2_000) : (attempts += 1) {
            if (stderr_total < stderr_output.len) {
                const read_len = c.read(
                    stderr_pipe[0],
                    stderr_output[stderr_total..].ptr,
                    stderr_output.len - stderr_total,
                );
                if (read_len > 0) stderr_total += @intCast(read_len);
            }
            const waited = c.waitpid(child, &status, c.W.NOHANG);
            if (waited == child) break;
            if (waited < 0 and posix.errno(waited) != .INTR) {
                _ = c.kill(child, c.SIG.KILL);
                _ = c.waitpid(child, null, 0);
                return error.TestUnexpectedResult;
            }
            var delay_fd = c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
            _ = c.poll(@ptrCast(&delay_fd), 0, 1);
        }
        if (attempts == 2_000) {
            _ = c.kill(child, c.SIG.KILL);
            _ = c.waitpid(child, &status, 0);
            return error.TestUnexpectedResult;
        }
        const wait_status: u32 = @bitCast(status);
        try std.testing.expect(!c.W.IFEXITED(wait_status) or c.W.EXITSTATUS(wait_status) != 0);
        if (stderr_total < stderr_output.len) {
            const read_len = c.read(
                stderr_pipe[0],
                stderr_output[stderr_total..].ptr,
                stderr_output.len - stderr_total,
            );
            if (read_len > 0) stderr_total += @intCast(read_len);
        }
        try std.testing.expect(stderr_total > 0);
        const expected_panic = if (std.mem.eql(u8, strict_case, "response_alias"))
            "response payload allocator returned a canonical owner alias"
        else
            "prepared execution transaction cleanup failed";
        try std.testing.expect(std.mem.indexOf(u8, stderr_output[0..stderr_total], expected_panic) != null);
        if (!std.mem.eql(u8, strict_case, "response_alias")) {
            const terminal_index = std.mem.indexOf(
                u8,
                stderr_output[0..stderr_total],
                "B3_CLEANUP_AUTHORITY_TERMINAL",
            ) orelse return error.TestUnexpectedResult;
            const panic_index = std.mem.indexOf(
                u8,
                stderr_output[0..stderr_total],
                expected_panic,
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expect(terminal_index < panic_index);
        }
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, stderr_output[0..stderr_total], "B3_REQUEST_BACKING_EXACT_FREE"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, stderr_output[0..stderr_total], "B3_STRICT_REQUEST_EXACT"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, stderr_output[0..stderr_total], "B3_NONCANONICAL_BACKING_FREED"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, stderr_output[0..stderr_total], "B3_RESPONSE_PAYLOAD_FREED"),
        );
        if (std.mem.eql(u8, strict_case, "response_alias")) try std.testing.expect(std.mem.indexOf(
            u8,
            stderr_output[0..stderr_total],
            "FORGED_RESPONSE_ALIAS_FREED",
        ) == null);
        if (std.mem.eql(u8, strict_case, "response_alias")) {
            const row = B3ExecutionHarness.expected(.accepted_alias_ambiguous);
            var transcript_buf: [512]u8 = undefined;
            const expected_transcript = try std.fmt.bufPrint(
                &transcript_buf,
                "B3_STRICT_ROW request={s} storage={s} authority={s} connection={s} outcome={s} error={s} poison={s} response={s} request_free={s} payload_free={s} final_zero={}\n",
                .{
                    @tagName(row.request),
                    if (row.storage_settled) "settled" else "unsettled",
                    @tagName(row.authority),
                    @tagName(row.connection),
                    @tagName(row.outcome),
                    @tagName(row.public_error),
                    @tagName(row.first_poison),
                    @tagName(row.response),
                    @tagName(row.request_free),
                    @tagName(row.payload_free),
                    row.final_zero,
                },
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                std.mem.count(u8, stderr_output[0..stderr_total], expected_transcript),
            );
        }
        response_alias_fail_stop_completed = true;
        return;
    }
    const capability_fd_ptr = c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_CAP_FD") orelse
        return error.MissingResponseAliasCapability;
    const capability_ptr = c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_CAP") orelse
        return error.MissingResponseAliasCapability;
    const capability_fd = std.fmt.parseInt(
        c.fd_t,
        std.mem.span(capability_fd_ptr),
        10,
    ) catch return error.InvalidResponseAliasCapability;
    const expected_capability = std.fmt.parseInt(
        u64,
        std.mem.span(capability_ptr),
        16,
    ) catch return error.InvalidResponseAliasCapability;
    var capability_bytes: [@sizeOf(u64)]u8 = undefined;
    const capability_len = c.read(capability_fd, &capability_bytes, capability_bytes.len);
    _ = c.close(capability_fd);
    if (capability_len != capability_bytes.len or
        std.mem.bytesToValue(u64, &capability_bytes) != expected_capability)
        return error.InvalidResponseAliasCapability;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const response_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{}",
    );
    defer allocator.free(response_wire);
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var request_free = RequestBackingFreeProbe{ .parent = allocator };
    var client: client_mod.Client = .{
        .allocator = request_free.allocator(),
        .fd = fds[0],
        .host_id = 0xE2,
        .parser = framing.FrameParser.init(request_free.allocator()),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xE2);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &binding,
        &lease,
        @intFromPtr(&owner.transport),
    );
    try mintInPlace(
        &owner.transport,
        &slot,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        reservation,
    );
    var hostile = OperationAliasAllocator{
        .parent = request_free.allocator(),
        .target = std.mem.asBytes(&owner.response),
    };
    if (std.mem.eql(u8, strict_case, "response_alias"))
        slot.current.guarded_allocator.parent = hostile.allocator();
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    const canonical = (try slot.current.cleanup_registry.preparedRequestForReceipt(
        reservation.cleanup,
        reservation.identity,
        @intFromPtr(&owner.transport),
        owner.transport.transport_incarnation,
        receipt,
    )).?;
    request_free.arm(&slot, reservation, canonical);
    const canonical_frame: [*]const u8 = @ptrFromInt(canonical.descriptor.frame_addr);
    var expected_request_buf: [4096]u8 = undefined;
    if (canonical.descriptor.frame_len > expected_request_buf.len)
        return error.TestUnexpectedResult;
    @memcpy(
        expected_request_buf[0..canonical.descriptor.frame_len],
        canonical_frame[0..canonical.descriptor.frame_len],
    );
    var peer_state = B3ActualSocketPeer{
        .fd = fds[1],
        .expected_request = expected_request_buf[0..canonical.descriptor.frame_len],
        .reply = response_wire,
        .deadline_ms = B3ActualSocketPeer.monotonicMs() + 2_000,
    };
    _ = try std.Thread.spawn(.{}, B3ActualSocketPeer.run, .{&peer_state});
    if (std.mem.eql(u8, strict_case, "response_alias")) {
        hostile.armed = true;
    } else {
        const drift_kind: u8 = if (std.mem.eql(u8, strict_case, "cleanup_descriptor"))
            1
        else if (std.mem.eql(u8, strict_case, "cleanup_stage"))
            2
        else if (std.mem.eql(u8, strict_case, "allocator_restore"))
            3
        else if (std.mem.eql(u8, strict_case, "guard_end"))
            4
        else if (std.mem.eql(u8, strict_case, "ledger_end"))
            5
        else
            return error.InvalidResponseAliasSubprocessMode;
        slot.current.guarded_allocator.request_free_test_observer.cleanup_drift_kind = drift_kind;
    }
    _ = owner.transport.executePreparedRequest(receipt, &owner.response) catch {};
    c._exit(0);
}

test "CR3a-2c3b response allocation alias gate sentinel proves destructive fixture ran" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const marker_ptr = c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC") orelse return;
    const marker = std.mem.span(marker_ptr);
    if (std.mem.eql(u8, marker, "skip-in-aggregate-v1")) return;
    if (!std.mem.eql(u8, marker, "run-isolated-v1"))
        return error.InvalidResponseAliasSentinelMode;
    try std.testing.expect(response_alias_fail_stop_completed);
}

test "CR3a-2a pending flush callback invalidates response before request wire" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var probe = PoisonOrderAllocator{ .parent = allocator };
    const fd = c.open("/dev/null", c.O{ .ACCMODE = .WRONLY });
    try std.testing.expect(fd >= 0);
    var client: client_mod.Client = .{
        .allocator = probe.allocator(),
        .fd = fd,
        .host_id = 0xDF,
        .parser = framing.FrameParser.init(probe.allocator()),
    };
    probe.client = &client;
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xDF);
    probe.client = slot.logicalClient();
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&owner.transport));
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), reservation);
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    slot.logicalClient().pending_outbound = .{
        .frame = try probe.allocator().dupe(u8, "older"),
        .stream_id = 9,
    };
    probe.response = &owner.response;
    probe.armed = true;
    try std.testing.expectError(
        error.InvalidResponseDestination,
        owner.transport.executePreparedRequest(receipt, &owner.response),
    );
    probe.armed = false;
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expectError(
        error.InvalidReceipt,
        owner.transport.abortPreparedRequest(receipt),
    );
    owner.response = .{};
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2c3b pending flush callback cannot redirect canonical execute owners" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var probe = PoisonOrderAllocator{ .parent = allocator };
    const fd = c.open("/dev/null", c.O{ .ACCMODE = .WRONLY });
    try std.testing.expect(fd >= 0);
    var client: client_mod.Client = .{
        .allocator = probe.allocator(),
        .fd = fd,
        .host_id = 0x2C3BC1,
        .parser = framing.FrameParser.init(probe.allocator()),
    };
    probe.client = &client;
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3BC1);
    probe.client = slot.logicalClient();
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&owner.transport));
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), reservation);
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    slot.logicalClient().pending_outbound = .{
        .frame = try probe.allocator().dupe(u8, "older"),
        .stream_id = 9,
    };
    const canonical_slot_addr = owner.transport.slot_addr;
    probe.transport = &owner.transport;
    probe.armed = true;
    const result = try owner.transport.executePreparedRequest(receipt, &owner.response);
    switch (result) {
        .uncertain_or_connection_failure => {},
        else => return error.TestUnexpectedResult,
    }
    probe.armed = false;
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expectEqual(@as(usize, 1), owner.transport.slot_addr);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
        &owner.transport.prepared_storage,
    ));
    owner.transport.slot_addr = canonical_slot_addr;
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        owner.response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "B3-0.1 accepted socket response settles request reusable and retains allocator" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var request_free = RequestBackingFreeProbe{ .parent = allocator };
    var probe = PoisonOrderAllocator{ .parent = request_free.allocator() };
    const response_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{}",
    );
    defer allocator.free(response_wire);
    const Peer = struct {
        fn run(fd: c.fd_t, wire: []const u8) void {
            defer _ = c.close(fd);
            var request: [4096]u8 = undefined;
            if (c.read(fd, &request, request.len) <= 0) return;
            socket_server.writeAll(fd, wire) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response_wire });
    defer peer.join();
    var client: client_mod.Client = .{
        .allocator = probe.allocator(),
        .fd = fds[0],
        .host_id = 0xDE,
        .parser = framing.FrameParser.init(probe.allocator()),
    };
    probe.client = &client;
    probe.replacement_allocator = allocator;
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xDE);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, @intFromPtr(&owner.transport));
    try mintInPlace(&owner.transport, &slot, @intFromPtr(&owner), @sizeOf(Owner), reservation);
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    const canonical = (try slot.current.cleanup_registry.preparedRequestForReceipt(
        reservation.cleanup,
        reservation.identity,
        @intFromPtr(&owner.transport),
        owner.transport.transport_incarnation,
        receipt,
    )).?;
    request_free.arm(
        &slot,
        reservation,
        canonical,
    );
    probe.armed = true;
    const result = try owner.transport.executePreparedRequest(receipt, &owner.response);
    try std.testing.expect(result == .accepted);
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
        &owner.transport.prepared_storage,
    ));
    try std.testing.expectEqual(
        @import("prepared_request_authority.zig").SettlementReadiness.settled,
        try slot.current.cleanup_registry.preparedRequestSettlementReadiness(
            reservation.cleanup,
            reservation.identity,
        ),
    );
    try slot.current.cleanup_registry.publishPreparedRequest(
        reservation.cleanup,
        reservation.identity,
        canonical,
    );
    try slot.current.cleanup_registry.settlePreparedRequest(
        reservation.cleanup,
        reservation.identity,
        canonical,
        false,
    );
    try std.testing.expect(slot.logicalClient().firstPoisonReason() == null);
    try std.testing.expectEqual(
        @intFromPtr(@as(*anyopaque, @ptrCast(&slot.current.guarded_allocator))),
        owner.response.allocator_ptr,
    );
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        owner.response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try std.testing.expect(probe.captured_payload_free_seen);
    try request_free.expectExactOnceBeforeAuthoritySettlement();
    probe.armed = false;
    client.allocator = probe.allocator();
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

const B3ActualSocketScenario = enum {
    eof_after_request,
    partial_header_eof,
    partial_payload_eof,
};

const B3ActualSocketPeerOutcome = enum {
    pending,
    exact,
    deadline,
    read_failure,
    mismatch,
    trailing_request,
};

const B3ActualSocketPeer = struct {
    fd: c.fd_t,
    expected_request: []const u8,
    reply: []const u8,
    deadline_ms: u64,
    outcome: B3ActualSocketPeerOutcome = .pending,
    request_exact: bool = false,
    reply_write_failed: bool = false,

    fn waitReadable(self: *const @This()) bool {
        var ready = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        while (true) {
            const now = monotonicMs();
            if (now >= self.deadline_ms) return false;
            const remaining: c_int = @intCast(@min(self.deadline_ms - now, @as(u64, std.math.maxInt(c_int))));
            const rc = c.poll(&ready, ready.len, remaining);
            if (rc > 0) return ready[0].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0;
            if (rc == 0) return false;
            if (posix.errno(rc) != .INTR) return false;
        }
    }

    fn requestQueueQuiet(self: *const @This()) bool {
        const quiet_deadline = @min(self.deadline_ms, monotonicMs() + 20);
        while (true) {
            var trailing: [1]u8 = undefined;
            const trailing_count = c.recv(
                self.fd,
                &trailing,
                trailing.len,
                posix.MSG.PEEK | posix.MSG.DONTWAIT,
            );
            if (trailing_count > 0) return false;
            if (trailing_count == 0) return true;
            if (posix.errno(trailing_count) != .AGAIN) return false;
            const now = monotonicMs();
            if (now >= quiet_deadline) return true;
            var ready = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
            const remaining: c_int = @intCast(quiet_deadline - now);
            const rc = c.poll(&ready, ready.len, remaining);
            if (rc == 0) return true;
            if (rc < 0 and posix.errno(rc) == .INTR) continue;
            if (rc < 0) return false;
        }
    }

    fn writeReply(self: *@This()) bool {
        socket_server.setNoSigPipe(self.fd);
        var offset: usize = 0;
        while (offset < self.reply.len) {
            const now = monotonicMs();
            if (now >= self.deadline_ms) {
                self.outcome = .deadline;
                return false;
            }
            const written = c.send(
                self.fd,
                self.reply[offset..].ptr,
                self.reply.len - offset,
                posix.MSG.DONTWAIT,
            );
            if (written > 0) {
                offset += @intCast(written);
                continue;
            }
            if (written == 0) {
                self.outcome = .read_failure;
                return false;
            }
            switch (posix.errno(written)) {
                .INTR => continue,
                .AGAIN => {
                    var ready = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.OUT, .revents = 0 }};
                    const remaining: c_int = @intCast(@min(
                        self.deadline_ms - now,
                        @as(u64, std.math.maxInt(c_int)),
                    ));
                    const rc = c.poll(&ready, ready.len, remaining);
                    if (rc > 0 and ready[0].revents & (c.POLL.OUT | c.POLL.ERR | c.POLL.HUP) != 0)
                        continue;
                    self.outcome = if (rc == 0) .deadline else .read_failure;
                    return false;
                },
                else => {
                    self.outcome = .read_failure;
                    return false;
                },
            }
        }
        return true;
    }

    fn run(self: *@This()) void {
        defer _ = c.close(self.fd);
        var received: [4096]u8 = undefined;
        if (self.expected_request.len > received.len) {
            self.outcome = .read_failure;
            return;
        }
        var offset: usize = 0;
        while (offset < self.expected_request.len) {
            if (!self.waitReadable()) {
                self.outcome = .deadline;
                return;
            }
            const count = c.read(
                self.fd,
                received[offset..].ptr,
                self.expected_request.len - offset,
            );
            if (count <= 0) {
                self.outcome = .read_failure;
                return;
            }
            offset += @intCast(count);
        }
        if (!std.mem.eql(u8, received[0..self.expected_request.len], self.expected_request)) {
            self.outcome = .mismatch;
            return;
        }

        // executePreparedRequest writes the complete canonical frame before it waits for a reply.
        // Therefore a byte readable at this point is necessarily an unowned trailing request byte.
        if (!self.requestQueueQuiet()) {
            self.outcome = .trailing_request;
            return;
        }
        self.request_exact = true;
        if (builtin.is_test and c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC") != null) {
            const marker = "B3_STRICT_REQUEST_EXACT\n";
            _ = c.write(2, marker.ptr, marker.len);
        }
        if (!self.writeReply()) {
            self.reply_write_failed = true;
            return;
        }
        self.outcome = .exact;
    }

    fn monotonicMs() u64 {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 +
            @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
    }
};

const B3AllocationFailureKind = enum { alloc, resize };

const B3OrdinalAllocator = struct {
    const FreeReceipt = struct { addr: usize = 0, len: usize = 0 };
    parent: std.mem.Allocator,
    kind: B3AllocationFailureKind,
    fail_index: usize = std.math.maxInt(usize),
    alloc_index: usize = 0,
    resize_index: usize = 0,
    induced_failure: bool = false,
    induced_failure_count: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    corrupt_response: ?*executed_response_mod.ExecutedResponse = null,
    corrupt_on_free_addr: usize = 0,
    corrupt_on_free_len: usize = 0,
    response_corrupted: bool = false,
    drift_request_on_free_addr: usize = 0,
    drift_request_addr: usize = 0,
    drift_request_len: usize = 0,
    request_drifted: bool = false,
    free_receipts: [256]FreeReceipt = [_]FreeReceipt{.{}} ** 256,
    free_receipt_count: usize = 0,
    free_receipt_overflow: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn armNext(self: *@This(), offset: usize) void {
        self.fail_index = switch (self.kind) {
            .alloc => self.alloc_index + offset,
            .resize => self.resize_index + offset,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ordinal = self.alloc_index;
        self.alloc_index += 1;
        if (self.kind == .alloc and ordinal == self.fail_index) {
            self.induced_failure = true;
            self.induced_failure_count += 1;
            return null;
        }
        const result = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse return null;
        self.allocated_bytes += len;
        return result;
    }

    fn shouldFailResize(self: *@This()) bool {
        const ordinal = self.resize_index;
        self.resize_index += 1;
        if (self.kind == .resize and ordinal == self.fail_index) {
            self.induced_failure = true;
            self.induced_failure_count += 1;
            return true;
        }
        return false;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.shouldFailResize()) return false;
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) self.allocated_bytes += new_len - memory.len else self.freed_bytes += memory.len - new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.shouldFailResize()) return null;
        const result = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) self.allocated_bytes += new_len - memory.len else self.freed_bytes += memory.len - new_len;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.free_receipt_count < self.free_receipts.len) {
            self.free_receipts[self.free_receipt_count] = .{
                .addr = @intFromPtr(memory.ptr),
                .len = memory.len,
            };
            self.free_receipt_count += 1;
        } else {
            self.free_receipt_overflow = true;
        }
        if (!self.response_corrupted and self.corrupt_response != null and
            @intFromPtr(memory.ptr) == self.corrupt_on_free_addr and
            memory.len == self.corrupt_on_free_len)
        {
            self.corrupt_response.?.self_addr = 1;
            self.response_corrupted = true;
        }
        if (!self.request_drifted and self.drift_request_on_free_addr != 0 and
            @intFromPtr(memory.ptr) == self.drift_request_on_free_addr)
        {
            if (self.drift_request_addr == 0 or self.drift_request_len == 0)
                @panic("B3 request drift descriptor missing");
            const request: [*]u8 = @ptrFromInt(self.drift_request_addr);
            request[self.drift_request_len - 1] ^= 1;
            self.request_drifted = true;
        }
        self.freed_bytes += memory.len;
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

const B3Scenario = enum {
    admission_rejected,
    local_preflight_rejected,
    pending_flush_ambiguous,
    pending_flush_backing_drift,
    issuer_exhausted_clean,
    issuer_exhausted_cleanup_drift,
    not_executed_reusable_connection_live,
    not_executed_reusable_connection_terminal,
    not_executed_terminal,
    uncertain,
    accepted_publication_failed_owned,
    accepted_alias_ambiguous,
    accepted_published,
};

const B3RequestClass = enum { none, prepared_only, exact_wire };
const B3AuthorityClass = enum { untouched, reusable, terminal, fail_stop };
const B3ConnectionClass = enum { keep, preserve_terminal, poison_local_invariant, fail_stop };
const B3OutcomeClass = enum { typed_error, uncertain, accepted, fail_stop };
const B3ErrorClass = enum { none, existing_typed, identity_exhausted, protocol_error, fail_stop };
const B3PoisonClass = enum { none, preserve_existing, local_invariant };
const B3ResponseClass = enum {
    pristine,
    uncertain_no_payload,
    accepted_owned,
    publication_failed_owned,
    terminal_no_free,
};
const B3FreeClass = enum { zero, exact_once, no_free, transferred, multiple };

const B3CallObservation = union(enum) {
    result: contract.ExecuteResult,
    failure: anyerror,

    fn outcome(self: @This()) B3OutcomeClass {
        return switch (self) {
            .failure => .typed_error,
            .result => |result| switch (result) {
                .accepted => .accepted,
                .uncertain_or_connection_failure => .uncertain,
                .typed_reject => .typed_error,
            },
        };
    }

    fn publicError(self: @This()) B3ErrorClass {
        return switch (self) {
            .result => .none,
            .failure => |err| if (err == error.IdentityExhausted)
                .identity_exhausted
            else if (err == error.ProtocolError)
                .protocol_error
            else
                .existing_typed,
        };
    }
};

const B3Expected = struct {
    scenario: B3Scenario,
    request: B3RequestClass,
    storage_settled: bool,
    authority: B3AuthorityClass,
    connection: B3ConnectionClass,
    outcome: B3OutcomeClass,
    public_error: B3ErrorClass,
    first_poison: B3PoisonClass,
    response: B3ResponseClass,
    request_free: B3FreeClass,
    payload_free: B3FreeClass,
    final_zero: bool,
};

const B3Observed = B3Expected;

const b3_expected_rows = [_]B3Expected{
    .{ .scenario = .admission_rejected, .request = .none, .storage_settled = false, .authority = .untouched, .connection = .keep, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .none, .response = .pristine, .request_free = .zero, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .local_preflight_rejected, .request = .prepared_only, .storage_settled = true, .authority = .reusable, .connection = .keep, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .none, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .pending_flush_ambiguous, .request = .prepared_only, .storage_settled = true, .authority = .reusable, .connection = .preserve_terminal, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .preserve_existing, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .pending_flush_backing_drift, .request = .prepared_only, .storage_settled = true, .authority = .terminal, .connection = .poison_local_invariant, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .local_invariant, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .issuer_exhausted_clean, .request = .prepared_only, .storage_settled = true, .authority = .terminal, .connection = .poison_local_invariant, .outcome = .typed_error, .public_error = .identity_exhausted, .first_poison = .local_invariant, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .issuer_exhausted_cleanup_drift, .request = .prepared_only, .storage_settled = true, .authority = .terminal, .connection = .poison_local_invariant, .outcome = .typed_error, .public_error = .protocol_error, .first_poison = .local_invariant, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .not_executed_reusable_connection_live, .request = .prepared_only, .storage_settled = true, .authority = .reusable, .connection = .keep, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .none, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .not_executed_reusable_connection_terminal, .request = .prepared_only, .storage_settled = true, .authority = .reusable, .connection = .preserve_terminal, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .preserve_existing, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .not_executed_terminal, .request = .prepared_only, .storage_settled = true, .authority = .terminal, .connection = .preserve_terminal, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .preserve_existing, .response = .pristine, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .uncertain, .request = .exact_wire, .storage_settled = true, .authority = .terminal, .connection = .preserve_terminal, .outcome = .uncertain, .public_error = .none, .first_poison = .preserve_existing, .response = .uncertain_no_payload, .request_free = .exact_once, .payload_free = .zero, .final_zero = true },
    .{ .scenario = .accepted_publication_failed_owned, .request = .exact_wire, .storage_settled = true, .authority = .terminal, .connection = .poison_local_invariant, .outcome = .typed_error, .public_error = .existing_typed, .first_poison = .local_invariant, .response = .publication_failed_owned, .request_free = .exact_once, .payload_free = .exact_once, .final_zero = true },
    .{ .scenario = .accepted_alias_ambiguous, .request = .exact_wire, .storage_settled = true, .authority = .terminal, .connection = .fail_stop, .outcome = .fail_stop, .public_error = .fail_stop, .first_poison = .local_invariant, .response = .terminal_no_free, .request_free = .exact_once, .payload_free = .no_free, .final_zero = false },
    .{ .scenario = .accepted_published, .request = .exact_wire, .storage_settled = true, .authority = .reusable, .connection = .keep, .outcome = .accepted, .public_error = .none, .first_poison = .none, .response = .accepted_owned, .request_free = .exact_once, .payload_free = .transferred, .final_zero = true },
};

const B3ExecutionHarness = struct {
    const Lease = @typeInfo(
        @typeInfo(@TypeOf(client_slot_mod.ClientSlot.reserveAttachmentBindingForTest)).@"fn".params[2].type.?,
    ).pointer.child;
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };

    self_addr: usize = 0,
    allocator: std.mem.Allocator,
    request_free: RequestBackingFreeProbe,
    ordinal: B3OrdinalAllocator,
    fds: [2]c.fd_t = .{ -1, -1 },
    client: client_mod.Client = undefined,
    slot: client_slot_mod.ClientSlot = undefined,
    slot_initialized: bool = false,
    binding: contract.PreparedAttachmentBinding = .{},
    lease: Lease = .{},
    owner: Owner = .{},
    reservation: ?client_slot_mod.AttachmentBindingReservation = null,
    transport_live: bool = false,
    receipt: contract.PreparedCallReceipt = undefined,
    canonical: ?@import("prepared_request_authority.zig").Prepared = null,
    expected_request: []u8 = &.{},
    peer_state: B3ActualSocketPeer = undefined,
    peer: ?std.Thread = null,
    peer_joined: bool = false,
    response_cleaned: bool = false,
    binding_cleaned: bool = false,
    observed: ?B3Observed = null,

    fn initInPlace(
        out: *@This(),
        allocator: std.mem.Allocator,
        host_id: u128,
        failure_kind: B3AllocationFailureKind,
    ) !void {
        out.* = .{
            .allocator = allocator,
            .request_free = .{ .parent = allocator },
            .ordinal = .{ .parent = undefined, .kind = failure_kind },
        };
        out.self_addr = @intFromPtr(out);
        errdefer out.deinit();
        out.ordinal.parent = out.request_free.allocator();
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &out.fds),
        );
        out.client = .{
            .allocator = out.ordinal.allocator(),
            .fd = out.fds[0],
            .host_id = host_id,
            .parser = framing.FrameParser.init(out.ordinal.allocator()),
        };
        try client_slot_mod.ClientSlot.initInPlace(&out.slot, allocator, &out.client, host_id);
        out.slot_initialized = true;
        out.fds[0] = -1;
        const reservation = try out.slot.reserveAttachmentBindingForTest(
            &out.binding,
            &out.lease,
            @intFromPtr(&out.owner.transport),
        );
        out.reservation = reservation;
        try mintInPlace(
            &out.owner.transport,
            &out.slot,
            @intFromPtr(&out.owner),
            @sizeOf(Owner),
            reservation,
        );
        out.transport_live = true;
        out.receipt = try out.owner.transport.prepareRequest(
            contract.RuntimeRequest.attachController(),
        );
        const canonical = (try out.slot.current.cleanup_registry.preparedRequestForReceipt(
            reservation.cleanup,
            reservation.identity,
            @intFromPtr(&out.owner.transport),
            out.owner.transport.transport_incarnation,
            out.receipt,
        )).?;
        out.canonical = canonical;
        out.request_free.arm(&out.slot, reservation, canonical);
        out.expected_request = try allocator.dupe(
            u8,
            @as([*]const u8, @ptrFromInt(canonical.descriptor.frame_addr))[0..canonical.descriptor.frame_len],
        );
    }

    fn startPeer(self: *@This(), reply: []const u8) !void {
        return self.startPeerExpected(self.expected_request, reply);
    }

    fn startPeerExpected(
        self: *@This(),
        expected_request: []const u8,
        reply: []const u8,
    ) !void {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        if (self.peer != null or self.fds[1] < 0) return error.InvalidState;
        self.peer_state = .{
            .fd = self.fds[1],
            .expected_request = expected_request,
            .reply = reply,
            .deadline_ms = B3ActualSocketPeer.monotonicMs() + 2_000,
        };
        self.peer = try std.Thread.spawn(.{}, B3ActualSocketPeer.run, .{&self.peer_state});
        self.fds[1] = -1;
    }

    fn armResponsePublicationDrift(self: *@This()) !void {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        const canonical = self.canonical.?;
        self.ordinal.corrupt_response = &self.owner.response;
        self.ordinal.corrupt_on_free_addr = canonical.descriptor.frame_addr;
        self.ordinal.corrupt_on_free_len = canonical.descriptor.frame_len;
    }

    fn armNotExecutedPendingInjection(
        self: *@This(),
        poison_before_execute: bool,
        drift_request_before_execute: bool,
    ) !void {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        const client = self.slot.logicalClient();
        const replacement = try client.allocator.dupe(u8, "replacement-pending");
        self.slot.current.guarded_allocator.request_free_test_observer.inject_pending_before_execute = true;
        self.slot.current.guarded_allocator.request_free_test_observer.pending_frame_addr =
            @intFromPtr(replacement.ptr);
        self.slot.current.guarded_allocator.request_free_test_observer.pending_frame_len = replacement.len;
        self.slot.current.guarded_allocator.request_free_test_observer.poison_before_execute =
            poison_before_execute;
        self.slot.current.guarded_allocator.request_free_test_observer.drift_request_before_execute =
            drift_request_before_execute;
        self.slot.current.guarded_allocator.request_free_test_observer.force_not_executed =
            poison_before_execute;
    }

    fn armPendingFlushBackingDrift(self: *@This()) ![]const u8 {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        const bytes = "older-before-request-drift";
        const client = self.slot.logicalClient();
        const frame = try client.allocator.dupe(u8, bytes);
        const canonical = self.canonical.?;
        self.ordinal.drift_request_on_free_addr = @intFromPtr(frame.ptr);
        self.ordinal.drift_request_addr = canonical.descriptor.frame_addr;
        self.ordinal.drift_request_len = canonical.descriptor.frame_len;
        client.pending_outbound = .{ .frame = frame, .stream_id = 9 };
        return bytes;
    }

    fn expected(scenario: B3Scenario) B3Expected {
        for (b3_expected_rows) |row| if (row.scenario == scenario) return row;
        unreachable;
    }

    fn joinPeer(self: *@This()) void {
        if (self.self_addr != @intFromPtr(self)) @panic("B3ExecutionHarness moved before peer join");
        if (self.peer) |thread| {
            if (!self.peer_joined) thread.join();
            self.peer_joined = true;
            self.peer = null;
        }
    }

    fn settleReusable(self: *@This()) !void {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        const reservation = self.reservation.?;
        const canonical = self.canonical.?;
        try self.slot.current.cleanup_registry.publishPreparedRequest(
            reservation.cleanup,
            reservation.identity,
            canonical,
        );
        try self.slot.current.cleanup_registry.settlePreparedRequest(
            reservation.cleanup,
            reservation.identity,
            canonical,
            false,
        );
    }

    fn settleAndClassifyAuthority(self: *@This()) !B3AuthorityClass {
        const reservation = self.reservation.?;
        const canonical = self.canonical.?;
        self.slot.current.cleanup_registry.publishPreparedRequest(
            reservation.cleanup,
            reservation.identity,
            canonical,
        ) catch |err| switch (err) {
            error.InvalidState => return .terminal,
            else => return err,
        };
        try self.slot.current.cleanup_registry.settlePreparedRequest(
            reservation.cleanup,
            reservation.identity,
            canonical,
            false,
        );
        return .reusable;
    }

    fn observedRequestClass(self: *const @This()) B3RequestClass {
        if (self.peer_joined and self.peer_state.request_exact and
            std.mem.eql(u8, self.peer_state.expected_request, self.expected_request))
            return .exact_wire;
        if (self.request_free.exact_free_count != 0 or
            client_mod.Client.preparedBlockingRpcStorageSettled(&self.owner.transport.prepared_storage))
            return .prepared_only;
        return .none;
    }

    fn observedConnectionClass(self: *@This()) B3ConnectionClass {
        const reason = self.slot.logicalClient().firstPoisonReason() orelse return .keep;
        return if (reason == .local_invariant_violation) .poison_local_invariant else .preserve_terminal;
    }

    fn observedPoisonClass(self: *@This()) B3PoisonClass {
        const reason = self.slot.logicalClient().firstPoisonReason() orelse return .none;
        return if (reason == .local_invariant_violation) .local_invariant else .preserve_existing;
    }

    fn observedResponseClass(self: *const @This()) B3ResponseClass {
        if (self.owner.response.pristine()) return .pristine;
        if (self.owner.response.lifecycle == .pristine) return .publication_failed_owned;
        return switch (self.owner.response.lifecycle) {
            .accepted => .accepted_owned,
            .uncertain_or_connection_failure => .uncertain_no_payload,
            .pristine => unreachable,
            .typed_reject, .terminal => .terminal_no_free,
        };
    }

    fn observedRequestFreeClass(self: *const @This()) B3FreeClass {
        return switch (self.request_free.exact_free_count) {
            0 => .zero,
            1 => .exact_once,
            else => .multiple,
        };
    }

    fn observedPayloadFreeClass(self: *const @This()) B3FreeClass {
        const observer = self.slot.current.guarded_allocator.request_free_test_observer;
        if (self.ordinal.free_receipt_overflow) return .multiple;
        var count: usize = 0;
        if (observer.response_payload_addr != 0) {
            for (self.ordinal.free_receipts[0..self.ordinal.free_receipt_count]) |receipt| {
                if (receipt.addr == observer.response_payload_addr and
                    receipt.len == observer.response_payload_len)
                    count += 1;
            }
        }
        if (count == 1) return .exact_once;
        if (count > 1) return .multiple;
        return if (self.observedResponseClass() == .accepted_owned) .transferred else .zero;
    }

    fn observeAuthority(self: *@This()) !B3AuthorityClass {
        if (!client_mod.Client.preparedBlockingRpcStorageSettled(
            &self.owner.transport.prepared_storage,
        )) return .untouched;
        return self.settleAndClassifyAuthority();
    }

    fn expectActualRow(
        self: *@This(),
        scenario: B3Scenario,
        call: B3CallObservation,
    ) !void {
        if (self.observed != null) return error.InvalidState;
        self.observed = B3Observed{
            .scenario = scenario,
            .request = self.observedRequestClass(),
            .storage_settled = client_mod.Client.preparedBlockingRpcStorageSettled(
                &self.owner.transport.prepared_storage,
            ),
            .authority = try self.observeAuthority(),
            .connection = self.observedConnectionClass(),
            .outcome = call.outcome(),
            .public_error = call.publicError(),
            .first_poison = self.observedPoisonClass(),
            .response = self.observedResponseClass(),
            .request_free = self.observedRequestFreeClass(),
            .payload_free = self.observedPayloadFreeClass(),
            .final_zero = false,
        };
    }

    fn expectExactOperationReceipt(observer: anytype) !void {
        try std.testing.expectEqual(@as(usize, 1), observer.registered_operation_begin_count);
        try std.testing.expectEqual(@as(usize, 1), observer.registered_operation_end_count);
        try std.testing.expectEqual(@as(u128, 0), observer.registered_operation_active_receipt);
        try std.testing.expect(!observer.registered_operation_receipt_drift);
        try std.testing.expect(observer.registered_operation_begin_receipts[0] != 0);
        try std.testing.expectEqual(
            observer.registered_operation_begin_receipts[0],
            observer.registered_operation_end_receipts[0],
        );
    }

    fn operationReceiptTranscriptExact(observer: anytype) bool {
        if (observer.registered_operation_begin_count != observer.registered_operation_end_count or
            observer.registered_operation_begin_count > observer.registered_operation_begin_receipts.len or
            observer.registered_operation_active_receipt != 0 or
            observer.registered_operation_receipt_drift)
            return false;
        for (0..observer.registered_operation_begin_count) |index| {
            if (observer.registered_operation_begin_receipts[index] == 0 or
                observer.registered_operation_begin_receipts[index] !=
                    observer.registered_operation_end_receipts[index])
                return false;
        }
        return true;
    }

    fn expectActualFinalZero(self: *const @This()) !void {
        const observer = self.slot.current.guarded_allocator.request_free_test_observer;
        try expectExactOperationReceipt(observer);
        if (observer.cleanup_count != 0) {
            try std.testing.expectEqual(@as(usize, 1), observer.cleanup_count);
            try std.testing.expect(observer.guard_inactive);
            try std.testing.expect(observer.allocator_scope_restored);
            try std.testing.expect(observer.client_scope_restored);
            try std.testing.expect(observer.ledger_ended);
            try std.testing.expect(observer.cleanup_settled);
        }
    }

    fn finishActualRow(self: *@This(), scenario: B3Scenario) !void {
        if (self.observed == null or self.observed.?.scenario != scenario)
            return error.InvalidState;
        try self.expectActualFinalZero();
        try self.cleanupBinding();
        self.deinit();
        self.observed.?.final_zero = true;
        try std.testing.expectEqualDeep(expected(scenario), self.observed.?);
    }

    fn expectOperationRegistryRestored(self: *const @This()) !void {
        try expectExactOperationReceipt(
            self.slot.current.guarded_allocator.request_free_test_observer,
        );
    }

    fn cleanupResponse(self: *@This()) !void {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        if (self.response_cleaned) return;
        if (self.owner.response.pristine()) {
            self.response_cleaned = true;
            return;
        }
        try std.testing.expectEqual(
            executed_response_mod.DeinitOutcome.cleaned,
            self.owner.response.deinit(try self.slot.responseOwnerSeal(self.reservation.?)),
        );
        self.response_cleaned = true;
    }

    fn cleanupBinding(self: *@This()) !void {
        if (self.self_addr != @intFromPtr(self)) return error.InvalidState;
        if (self.binding_cleaned or self.reservation == null) return;
        if (self.transport_live) {
            const operation_count_before = self.slot.current.guarded_allocator
                .request_free_test_observer.registered_operation_begin_count;
            terminalizeOwned(
                &self.owner.transport,
                @intFromPtr(&self.owner.transport),
            ) catch |err| {
                const operation = self.slot.current.guarded_allocator.request_free_test_observer;
                try std.testing.expect(
                    operation.registered_operation_begin_count > operation_count_before,
                );
                try std.testing.expect(operationReceiptTranscriptExact(operation));
                try self.slot.abortAttachmentBinding(&self.binding, self.reservation.?);
                self.transport_live = false;
                self.binding_cleaned = true;
                return err;
            };
            const operation = self.slot.current.guarded_allocator.request_free_test_observer;
            try std.testing.expect(
                operation.registered_operation_begin_count > operation_count_before,
            );
            try std.testing.expect(operationReceiptTranscriptExact(operation));
            self.transport_live = false;
        }
        try self.slot.abortAttachmentBinding(&self.binding, self.reservation.?);
        self.binding_cleaned = true;
    }

    fn deinit(self: *@This()) void {
        if (self.self_addr == 0) return;
        if (self.self_addr != @intFromPtr(self)) @panic("B3ExecutionHarness moved after init");
        if (self.peer != null and !self.peer_joined and self.slot_initialized) {
            _ = c.shutdown(self.slot.logicalClient().fd, c.SHUT.RDWR);
        }
        self.joinPeer();
        if (self.fds[1] >= 0) _ = c.close(self.fds[1]);
        if (self.fds[0] >= 0) _ = c.close(self.fds[0]);
        if (self.slot_initialized) {
            if (!self.response_cleaned and self.reservation != null)
                self.cleanupResponse() catch @panic("B3 harness response cleanup failed");
            if (!self.binding_cleaned and self.reservation != null)
                self.cleanupBinding() catch @panic("B3 harness binding cleanup failed");
            const operation = self.slot.current.guarded_allocator.request_free_test_observer;
            if (!operationReceiptTranscriptExact(operation))
                @panic("B3 harness operation registry did not return its exact receipt");
            self.slot.deinit();
            self.slot_initialized = false;
        }
        if (self.ordinal.allocated_bytes != self.ordinal.freed_bytes)
            @panic("B3 harness allocator outstanding bytes did not return to zero");
        if (self.expected_request.len != 0) {
            self.allocator.free(self.expected_request);
            self.expected_request = &.{};
        }
        self.self_addr = 0;
    }
};

test "B3-0.4 actual socket uncertain settlement follows full request then EOF boundaries" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    inline for (std.enums.values(B3ActualSocketScenario)) |scenario| {
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        const allocator = std.testing.allocator;
        const response_wire = try framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = 1 },
            "payload",
        );
        defer allocator.free(response_wire);
        var harness: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &harness,
            allocator,
            0xB30400 + @as(u128, @intFromEnum(scenario)),
            .alloc,
        );
        defer harness.deinit();
        const reply = switch (scenario) {
            .eof_after_request => response_wire[0..0],
            .partial_header_eof => response_wire[0..7],
            .partial_payload_eof => response_wire[0 .. protocol.header_size + 1],
        };
        try harness.startPeer(reply);
        const result = try harness.owner.transport.executePreparedRequest(
            harness.receipt,
            &harness.owner.response,
        );
        try harness.request_free.expectExecutionFinalZero();
        harness.joinPeer();
        try std.testing.expectEqual(B3ActualSocketPeerOutcome.exact, harness.peer_state.outcome);
        switch (result) {
            .uncertain_or_connection_failure => |executed| try std.testing.expect(
                executed.matchesPrepared(harness.receipt),
            ),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
            &harness.owner.transport.prepared_storage,
        ));
        const expected_poison: client_poison.ConnectionReason = switch (scenario) {
            .eof_after_request => .connection_eof,
            .partial_header_eof, .partial_payload_eof => .frame_malformed,
        };
        try std.testing.expectEqual(expected_poison, harness.slot.logicalClient().firstPoisonReason().?);
        try harness.expectActualRow(.uncertain, .{ .result = result });
        try harness.request_free.expectExactOnceBeforeAuthoritySettlement();
        try harness.cleanupResponse();
        try harness.finishActualRow(.uncertain);
    }
}

test "B3-0.4 execute allocation fail index settles every actual socket attempt" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    inline for (std.enums.values(B3AllocationFailureKind)) |failure_kind| {
        var reached_success = false;
        var failure_count: usize = 0;
        var saw_post_wire_failure = false;
        var saw_terminal_failure = false;
        var saw_recovered_resize_failure = false;
        for (0..32) |fail_offset| {
            try client_slot_mod.ClientSlot.initializeProcessRuntime();
            const allocator = std.testing.allocator;
            const response_payload = try allocator.alloc(u8, 64 * 1024);
            defer allocator.free(response_payload);
            @memset(response_payload, 0xA5);
            const response_wire = try framing.encodeFrame(
                allocator,
                .{ .kind = .response, .request_id = 1 },
                response_payload,
            );
            defer allocator.free(response_wire);
            const host_id = 0xB30440 + @as(u128, fail_offset);
            var harness: B3ExecutionHarness = undefined;
            try B3ExecutionHarness.initInPlace(&harness, allocator, host_id, failure_kind);
            defer harness.deinit();
            try harness.startPeer(response_wire);
            try std.testing.expectEqual(
                @intFromPtr(&harness.ordinal),
                @intFromPtr(harness.slot.current.guarded_allocator.parent.ptr),
            );
            harness.ordinal.armNext(fail_offset);
            const observed: union(enum) {
                result: contract.ExecuteResult,
                failure: Error,
            } = if (harness.owner.transport.executePreparedRequest(
                harness.receipt,
                &harness.owner.response,
            )) |result|
                .{ .result = result }
            else |err|
                .{ .failure = err };
            try harness.request_free.expectExecutionFinalZero();
            _ = c.shutdown(harness.slot.logicalClient().fd, c.SHUT.RDWR);
            harness.joinPeer();
            try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
                &harness.owner.transport.prepared_storage,
            ));
            try harness.request_free.expectExactOnceBeforeAuthoritySettlement();
            try std.testing.expect(!harness.slot.current.guarded_allocator.operation_guard_active);
            if (harness.ordinal.induced_failure) {
                try std.testing.expectEqual(@as(usize, 1), harness.ordinal.induced_failure_count);
                failure_count += 1;
                try std.testing.expectEqual(fail_offset + 1, failure_count);
                try std.testing.expect(harness.peer_state.request_exact);
                saw_post_wire_failure = true;
            }

            switch (observed) {
                .result => |result| switch (result) {
                    .accepted => {
                        try std.testing.expectEqual(B3ActualSocketPeerOutcome.exact, harness.peer_state.outcome);
                        if (harness.ordinal.induced_failure) {
                            try std.testing.expect(harness.slot.logicalClient().firstPoisonReason() == null);
                            if (failure_kind == .resize) saw_recovered_resize_failure = true;
                        } else {
                            reached_success = true;
                        }
                        const bytes = try harness.owner.response.borrowAccepted(
                            try harness.slot.responseOwnerSeal(harness.reservation.?),
                        );
                        try std.testing.expectEqualSlices(u8, response_payload, bytes);
                        if (!harness.ordinal.induced_failure) try harness.expectActualRow(
                            .accepted_published,
                            .{ .result = result },
                        );
                    },
                    .uncertain_or_connection_failure => {
                        try std.testing.expect(harness.peer_state.request_exact);
                        if (harness.ordinal.induced_failure) {
                            try std.testing.expectEqual(
                                client_poison.ConnectionReason.local_resource_exhausted,
                                harness.slot.logicalClient().firstPoisonReason().?,
                            );
                            saw_terminal_failure = true;
                        }
                        try std.testing.expectError(
                            error.InvalidState,
                            harness.slot.current.cleanup_registry.publishPreparedRequest(
                                harness.reservation.?.cleanup,
                                harness.reservation.?.identity,
                                harness.canonical.?,
                            ),
                        );
                    },
                    .typed_reject => return error.TestUnexpectedResult,
                },
                .failure => {
                    try std.testing.expect(harness.ordinal.induced_failure);
                    if (harness.slot.logicalClient().firstPoisonReason() == null) {
                        try harness.settleReusable();
                    } else {
                        try std.testing.expectEqual(
                            client_poison.ConnectionReason.local_resource_exhausted,
                            harness.slot.logicalClient().firstPoisonReason().?,
                        );
                        saw_terminal_failure = true;
                        try std.testing.expectError(
                            error.InvalidState,
                            harness.slot.current.cleanup_registry.publishPreparedRequest(
                                harness.reservation.?.cleanup,
                                harness.reservation.?.identity,
                                harness.canonical.?,
                            ),
                        );
                    }
                    try std.testing.expect(harness.owner.response.pristine());
                },
            }
            try harness.cleanupResponse();
            if (reached_success)
                try harness.finishActualRow(.accepted_published)
            else
                try harness.cleanupBinding();
            if (reached_success) break;
        }
        try std.testing.expect(reached_success);
        try std.testing.expect(failure_count > 0);
        try std.testing.expect(saw_post_wire_failure);
        switch (failure_kind) {
            .alloc => try std.testing.expect(saw_terminal_failure),
            .resize => try std.testing.expect(saw_recovered_resize_failure),
        }
    }
}

test "B3-0.4 closed thirteen-row execution table is exhaustive and internally consistent" {
    const b3_issuer_oracle = @import("b3_issuer_oracle.zig");
    try std.testing.expectEqual(std.meta.fields(B3Scenario).len, b3_expected_rows.len);
    var seen = [_]bool{false} ** std.meta.fields(B3Scenario).len;
    for (b3_expected_rows) |expected| {
        const index = @intFromEnum(expected.scenario);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        if (expected.outcome == .accepted) {
            try std.testing.expectEqual(B3AuthorityClass.reusable, expected.authority);
            try std.testing.expectEqual(B3ConnectionClass.keep, expected.connection);
            try std.testing.expect(expected.storage_settled);
        }
        if (expected.outcome == .uncertain) {
            try std.testing.expectEqual(B3RequestClass.exact_wire, expected.request);
            try std.testing.expectEqual(B3AuthorityClass.terminal, expected.authority);
            try std.testing.expect(expected.storage_settled);
        }
        if (expected.authority == .fail_stop) {
            try std.testing.expectEqual(B3OutcomeClass.fail_stop, expected.outcome);
        }
    }
    for (seen) |present| try std.testing.expect(present);
    inline for (std.enums.values(b3_issuer_oracle.Scenario)) |issuer_scenario| {
        const aggregate_scenario: B3Scenario = switch (issuer_scenario) {
            .clean => .issuer_exhausted_clean,
            .cleanup_drift => .issuer_exhausted_cleanup_drift,
        };
        const row = B3ExecutionHarness.expected(aggregate_scenario);
        const oracle = b3_issuer_oracle.expected(issuer_scenario);
        try std.testing.expectEqualDeep(oracle, b3_issuer_oracle.Observation{
            .scenario = issuer_scenario,
            .request_prepared_only = row.request == .prepared_only,
            .storage_settled = row.storage_settled,
            .authority_terminal = row.authority == .terminal,
            .connection_local_invariant = row.connection == .poison_local_invariant,
            .public_error = if (row.public_error == .identity_exhausted)
                .identity_exhausted
            else
                .protocol_error,
            .first_poison_local_invariant = row.first_poison == .local_invariant,
            .response_pristine = row.response == .pristine,
            .request_free_exact_once = row.request_free == .exact_once,
            .payload_never_observed = row.payload_free == .zero,
            .final_zero = row.final_zero,
        });
    }
    if (builtin.os.tag == .macos) {
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        var final_address_probe: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &final_address_probe,
            std.testing.allocator,
            0xB3047F,
            .alloc,
        );
        defer final_address_probe.deinit();
        var copied_probe = final_address_probe;
        try std.testing.expectError(
            error.InvalidState,
            copied_probe.armNotExecutedPendingInjection(false, false),
        );
        try std.testing.expect(
            !final_address_probe.slot.current.guarded_allocator.request_free_test_observer.inject_pending_before_execute,
        );
        try final_address_probe.owner.transport.abortPreparedRequest(final_address_probe.receipt);
        try final_address_probe.cleanupResponse();
        try final_address_probe.cleanupBinding();

        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        var admission: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &admission,
            std.testing.allocator,
            0xB30480,
            .alloc,
        );
        defer admission.deinit();
        var outside_response: executed_response_mod.ExecutedResponse = .{};
        const admission_call: B3CallObservation = if (client_slot_mod.executeGenerationRequest(.{
            .request = admission.owner.transport.requestOperation(admission.receipt),
            .response_out_addr = @intFromPtr(&outside_response),
            .owner_addr = @intFromPtr(&admission.owner),
            .owner_size = @sizeOf(B3ExecutionHarness.Owner),
        })) |result| .{ .result = result } else |err| .{ .failure = err };
        try std.testing.expect(admission_call == .failure);
        try std.testing.expect(admission_call.failure == error.InvalidResponseDestination);
        try std.testing.expect(!client_mod.Client.preparedBlockingRpcStorageSettled(
            &admission.owner.transport.prepared_storage,
        ));
        try std.testing.expect(admission.slot.logicalClient().firstPoisonReason() == null);
        try admission.expectActualRow(.admission_rejected, admission_call);
        try admission.owner.transport.abortPreparedRequest(admission.receipt);
        try admission.cleanupResponse();
        try admission.finishActualRow(.admission_rejected);

        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        var preflight: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &preflight,
            std.testing.allocator,
            0xB30481,
            .alloc,
        );
        defer preflight.deinit();
        preflight.owner.response.self_addr = 1;
        const preflight_call: B3CallObservation = if (preflight.owner.transport.executePreparedRequest(
            preflight.receipt,
            &preflight.owner.response,
        )) |result| .{ .result = result } else |err| .{ .failure = err };
        try std.testing.expect(preflight_call == .failure);
        try std.testing.expect(preflight_call.failure == error.InvalidResponseDestination);
        preflight.owner.response = .{};
        try preflight.request_free.expectExactOnceBeforeAuthoritySettlement();
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
            &preflight.owner.transport.prepared_storage,
        ));
        try std.testing.expect(preflight.slot.logicalClient().firstPoisonReason() == null);
        try preflight.expectActualRow(.local_preflight_rejected, preflight_call);
        try preflight.cleanupResponse();
        try preflight.finishActualRow(.local_preflight_rejected);

        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        var pending: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &pending,
            std.testing.allocator,
            0xB30482,
            .alloc,
        );
        defer pending.deinit();
        _ = c.close(pending.fds[1]);
        pending.fds[1] = -1;
        pending.slot.logicalClient().pending_outbound = .{
            .frame = try pending.slot.logicalClient().allocator.dupe(u8, "older-frame"),
            .stream_id = 9,
        };
        const pending_call: B3CallObservation = if (pending.owner.transport.executePreparedRequest(
            pending.receipt,
            &pending.owner.response,
        )) |result| .{ .result = result } else |err| .{ .failure = err };
        try std.testing.expect(pending_call == .failure);
        try std.testing.expect(pending_call.failure == error.WriteFailed);
        try pending.request_free.expectExactOnceBeforeAuthoritySettlement();
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
            &pending.owner.transport.prepared_storage,
        ));
        try std.testing.expect(pending.slot.logicalClient().firstPoisonReason() != null);
        try pending.expectActualRow(.pending_flush_ambiguous, pending_call);
        try pending.cleanupResponse();
        try pending.finishActualRow(.pending_flush_ambiguous);

        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        var pending_drift: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &pending_drift,
            std.testing.allocator,
            0xB30483,
            .alloc,
        );
        defer pending_drift.deinit();
        const older_bytes = try pending_drift.armPendingFlushBackingDrift();
        try pending_drift.startPeerExpected(older_bytes, &.{});
        const pending_drift_call: B3CallObservation = if (pending_drift.owner.transport.executePreparedRequest(
            pending_drift.receipt,
            &pending_drift.owner.response,
        )) |result| .{ .result = result } else |err| .{ .failure = err };
        try std.testing.expect(pending_drift_call == .failure);
        try std.testing.expect(pending_drift_call.failure == error.InvalidPreparedRpc);
        pending_drift.joinPeer();
        try std.testing.expectEqual(
            B3ActualSocketPeerOutcome.exact,
            pending_drift.peer_state.outcome,
        );
        try std.testing.expect(pending_drift.ordinal.request_drifted);
        try pending_drift.request_free.expectExecutionFinalZero();
        try pending_drift.request_free.expectExactOnceBeforeAuthoritySettlement();
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
            &pending_drift.owner.transport.prepared_storage,
        ));
        try std.testing.expect(
            pending_drift.slot.logicalClient().firstPoisonReason().? == .local_invariant_violation,
        );
        try pending_drift.expectActualRow(.pending_flush_backing_drift, pending_drift_call);
        try pending_drift.cleanupResponse();
        try pending_drift.finishActualRow(.pending_flush_backing_drift);

        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        var not_executed: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &not_executed,
            std.testing.allocator,
            0xB30484,
            .alloc,
        );
        defer not_executed.deinit();
        try not_executed.armNotExecutedPendingInjection(false, false);
        const not_executed_call: B3CallObservation = if (not_executed.owner.transport.executePreparedRequest(
            not_executed.receipt,
            &not_executed.owner.response,
        )) |result| .{ .result = result } else |err| .{ .failure = err };
        try std.testing.expect(not_executed_call == .failure);
        try std.testing.expect(not_executed_call.failure == error.InvalidPreparedRpc);
        try std.testing.expect(
            not_executed.slot.current.guarded_allocator.request_free_test_observer.pending_injected,
        );
        try not_executed.request_free.expectExecutionFinalZero();
        try not_executed.request_free.expectExactOnceBeforeAuthoritySettlement();
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
            &not_executed.owner.transport.prepared_storage,
        ));
        try std.testing.expect(not_executed.slot.logicalClient().firstPoisonReason() == null);
        try not_executed.expectActualRow(.not_executed_reusable_connection_live, not_executed_call);
        try not_executed.cleanupResponse();
        try not_executed.finishActualRow(.not_executed_reusable_connection_live);

        const TerminalNotExecutedCase = enum { reusable, terminal };
        inline for (std.enums.values(TerminalNotExecutedCase)) |case| {
            try client_slot_mod.ClientSlot.initializeProcessRuntime();
            var terminal_not_executed: B3ExecutionHarness = undefined;
            try B3ExecutionHarness.initInPlace(
                &terminal_not_executed,
                std.testing.allocator,
                0xB30485 + @as(u128, @intFromEnum(case)),
                .alloc,
            );
            defer terminal_not_executed.deinit();
            try terminal_not_executed.armNotExecutedPendingInjection(
                true,
                case == .terminal,
            );
            const terminal_call: B3CallObservation = if (terminal_not_executed.owner.transport.executePreparedRequest(
                terminal_not_executed.receipt,
                &terminal_not_executed.owner.response,
            )) |result| .{ .result = result } else |err| .{ .failure = err };
            try std.testing.expect(terminal_call == .failure);
            try std.testing.expect(terminal_call.failure == error.ConnectionClosed);
            try std.testing.expect(
                terminal_not_executed.slot.current.guarded_allocator.request_free_test_observer.pending_injected,
            );
            try terminal_not_executed.request_free.expectExecutionFinalZero();
            try terminal_not_executed.request_free.expectExactOnceBeforeAuthoritySettlement();
            try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
                &terminal_not_executed.owner.transport.prepared_storage,
            ));
            try std.testing.expectEqual(
                client_poison.ConnectionReason.transport_read_failure,
                terminal_not_executed.slot.logicalClient().firstPoisonReason().?,
            );
            const scenario: B3Scenario = switch (case) {
                .reusable => .not_executed_reusable_connection_terminal,
                .terminal => .not_executed_terminal,
            };
            try terminal_not_executed.expectActualRow(scenario, terminal_call);
            try terminal_not_executed.cleanupResponse();
            try terminal_not_executed.finishActualRow(scenario);
        }

        try client_slot_mod.ClientSlot.initializeProcessRuntime();
        const publication_wire = try framing.encodeFrame(
            std.testing.allocator,
            .{ .kind = .response, .request_id = 1 },
            "publication-owned-payload",
        );
        defer std.testing.allocator.free(publication_wire);
        var publication: B3ExecutionHarness = undefined;
        try B3ExecutionHarness.initInPlace(
            &publication,
            std.testing.allocator,
            0xB30483,
            .alloc,
        );
        defer publication.deinit();
        try publication.startPeer(publication_wire);
        try publication.armResponsePublicationDrift();
        const publication_call: B3CallObservation = if (publication.owner.transport.executePreparedRequest(
            publication.receipt,
            &publication.owner.response,
        )) |result| .{ .result = result } else |err| .{ .failure = err };
        try std.testing.expect(publication_call == .failure);
        try std.testing.expect(publication_call.failure == error.InvalidResponseDestination);
        publication.joinPeer();
        try std.testing.expect(publication.ordinal.response_corrupted);
        try publication.request_free.expectExecutionFinalZero();
        try publication.request_free.expectExactOnceBeforeAuthoritySettlement();
        try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
            &publication.owner.transport.prepared_storage,
        ));
        try std.testing.expectEqual(
            client_poison.ConnectionReason.local_invariant_violation,
            publication.slot.logicalClient().firstPoisonReason().?,
        );
        try publication.expectActualRow(.accepted_publication_failed_owned, publication_call);
        publication.owner.response = .{};
        try publication.cleanupResponse();
        try publication.finishActualRow(.accepted_publication_failed_owned);
    }
}

test "B3-0.4 strict cleanup category requires a successful isolated dependency" {
    const focused_marker = c.getenv("MARU_SESSION_HOST_B3_STRICT_GATE");
    const aggregate_marker = c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC");
    if (focused_marker == null and aggregate_marker == null) return;
    const focused_valid = if (focused_marker) |raw|
        std.mem.eql(u8, std.mem.span(raw), "passed-by-dependency-v1")
    else
        false;
    const aggregate_valid = if (aggregate_marker) |raw|
        std.mem.eql(u8, std.mem.span(raw), "skip-in-aggregate-v1")
    else
        false;
    try std.testing.expect(focused_valid or aggregate_valid);
}

test "B3-0.4 focused inventory sentinel is independent of test execution order" {
    try std.testing.expectEqual(@as(usize, 13), b3_expected_rows.len);
    const focused_marker = c.getenv("MARU_SESSION_HOST_B3_STRICT_GATE");
    const aggregate_marker = c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC");
    if (focused_marker == null and aggregate_marker == null) return;
    const focused_valid = if (focused_marker) |raw|
        std.mem.eql(u8, std.mem.span(raw), "passed-by-dependency-v1")
    else
        false;
    const aggregate_valid = if (aggregate_marker) |raw|
        std.mem.eql(u8, std.mem.span(raw), "skip-in-aggregate-v1")
    else
        false;
    try std.testing.expect(focused_valid or aggregate_valid);
}

test "CR3a-2c3b actual socket retires OOB observation before exact target publication" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const oob_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .delta_chunk, .stream_id = 99 },
        "oob-delta",
    );
    defer allocator.free(oob_wire);
    const response_wire = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{}",
    );
    defer allocator.free(response_wire);
    const combined_wire = try std.mem.concat(allocator, u8, &.{ oob_wire, response_wire });
    defer allocator.free(combined_wire);
    const Peer = struct {
        fn run(fd: c.fd_t, wire: []const u8) void {
            defer _ = c.close(fd);
            var request: [4096]u8 = undefined;
            if (c.read(fd, &request, request.len) <= 0) return;
            socket_server.writeAll(fd, wire) catch return;
        }
    };
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], combined_wire });
    defer peer.join();
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0x2C3B0B,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0x2C3B0B);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const Owner = struct {
        transport: GenerationTransport = .{},
        response: executed_response_mod.ExecutedResponse = .{},
    };
    var owner: Owner = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(
        &binding,
        &lease,
        @intFromPtr(&owner.transport),
    );
    try mintInPlace(
        &owner.transport,
        &slot,
        @intFromPtr(&owner),
        @sizeOf(Owner),
        reservation,
    );
    const receipt = try owner.transport.prepareRequest(contract.RuntimeRequest.attachController());
    const result = try owner.transport.executePreparedRequest(receipt, &owner.response);
    try std.testing.expect(result == .accepted);
    try std.testing.expectEqual(@as(usize, 1), slot.logicalClient().pending_stream.items.len);
    try std.testing.expectEqual(
        @as(u64, 0),
        slot.logicalClient().pending_stream.items[0].payload_observation_generation,
    );
    try std.testing.expectEqualStrings(
        "oob-delta",
        slot.logicalClient().pending_stream.items[0].payload,
    );
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        owner.response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try terminalizeOwned(&owner.transport, @intFromPtr(&owner.transport));
    try slot.abortAttachmentBinding(&binding, reservation);
}

const RequestBackingFreeProbe = struct {
    parent: std.mem.Allocator,
    slot: ?*client_slot_mod.ClientSlot = null,
    reservation: ?client_slot_mod.AttachmentBindingReservation = null,
    canonical: ?@import("prepared_request_authority.zig").Prepared = null,
    target_addr: usize = 0,
    target_len: usize = 0,
    exact_free_count: usize = 0,
    authority_was_executing: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn arm(
        self: *@This(),
        slot: *client_slot_mod.ClientSlot,
        reservation: client_slot_mod.AttachmentBindingReservation,
        canonical: @import("prepared_request_authority.zig").Prepared,
    ) void {
        self.slot = slot;
        self.reservation = reservation;
        self.canonical = canonical;
        self.target_addr = canonical.descriptor.frame_addr;
        self.target_len = canonical.descriptor.frame_len;
        slot.current.guarded_allocator.request_free_test_observer = .{
            .target_addr = canonical.descriptor.frame_addr,
            .target_len = canonical.descriptor.frame_len,
            .descriptor_allocator_ptr = canonical.descriptor.allocator_ptr,
            .descriptor_allocator_vtable = canonical.descriptor.allocator_vtable,
        };
    }

    fn expectExactOnceBeforeAuthoritySettlement(self: *const @This()) !void {
        try std.testing.expectEqual(@as(usize, 1), self.exact_free_count);
        try std.testing.expect(self.authority_was_executing);
        try std.testing.expectEqual(
            @as(usize, 1),
            self.slot.?.current.guarded_allocator.request_free_test_observer.entry_count,
        );
        try std.testing.expect(
            self.slot.?.current.guarded_allocator.request_free_test_observer.descriptor_exact,
        );
    }

    fn expectExecutionFinalZero(self: *const @This()) !void {
        const observer = self.slot.?.current.guarded_allocator.request_free_test_observer;
        try std.testing.expectEqual(@as(usize, 1), observer.cleanup_count);
        try std.testing.expect(observer.guard_inactive);
        try std.testing.expect(observer.allocator_scope_restored);
        try std.testing.expect(observer.client_scope_restored);
        try std.testing.expect(observer.ledger_ended);
        try std.testing.expect(observer.cleanup_settled);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const memory_addr = @intFromPtr(memory.ptr);
        const strict_child = builtin.is_test and
            c.getenv("MARU_SESSION_HOST_RESPONSE_ALIAS_EXEC") != null;
        if (self.slot) |slot| {
            const observer = slot.current.guarded_allocator.request_free_test_observer;
            if (strict_child and observer.response_payload_addr != 0 and
                memory_addr == observer.response_payload_addr and
                memory.len == observer.response_payload_len)
            {
                const marker = "B3_RESPONSE_PAYLOAD_FREED\n";
                _ = c.write(2, marker.ptr, marker.len);
            }
        }
        if (memory_addr == self.target_addr and memory.len == self.target_len) {
            self.exact_free_count += 1;
            const reservation = self.reservation.?;
            const canonical = self.canonical.?;
            self.authority_was_executing = self.slot.?.current.cleanup_registry.executingRequestMatches(
                reservation.cleanup,
                reservation.identity,
                canonical,
            ) catch false;
            const observer = self.slot.?.current.guarded_allocator.request_free_test_observer;
            if (strict_child and
                self.authority_was_executing and observer.entry_count == 1 and
                observer.descriptor_exact)
            {
                const marker = "B3_REQUEST_BACKING_EXACT_FREE\n";
                _ = c.write(2, marker.ptr, marker.len);
            }
        } else if (strict_child) {
            const memory_end = std.math.add(usize, memory_addr, memory.len) catch std.math.maxInt(usize);
            const target_end = std.math.add(usize, self.target_addr, self.target_len) catch
                std.math.maxInt(usize);
            if (memory_addr < target_end and self.target_addr < memory_end) {
                const marker = "B3_NONCANONICAL_BACKING_FREED\n";
                _ = c.write(2, marker.ptr, marker.len);
            }
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

const PoisonOrderAllocator = struct {
    parent: std.mem.Allocator,
    client: ?*client_mod.Client = null,
    response: ?*executed_response_mod.ExecutedResponse = null,
    transport: ?*GenerationTransport = null,
    replacement_allocator: ?std.mem.Allocator = null,
    armed: bool = false,
    mutated_after_preflight: bool = false,
    saw_poison_before_free: bool = false,
    reentry_rejected: bool = false,
    captured_payload_free_seen: bool = false,
    payload_free_count: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.armed and !self.mutated_after_preflight) {
            // The prepared frame settles after execute preflight and before response publication.
            // Simulate a hostile allocator changing the destination in that interval.
            self.mutated_after_preflight = true;
            if (self.response) |response| {
                response.self_addr = 1;
            } else if (self.transport) |transport| {
                transport.slot_addr = 1;
            } else if (self.replacement_allocator) |replacement| {
                self.client.?.allocator = replacement;
            }
        } else if (self.armed and self.replacement_allocator != null) {
            self.captured_payload_free_seen = true;
        } else if (self.armed and self.client.?.unusable and !self.saw_poison_before_free) {
            self.saw_poison_before_free = true;
            self.payload_free_count += 1;
            const unexpected = self.client.?.call("host.info", null) catch |err| blk: {
                self.reentry_rejected = err == error.ConnectionClosed or err == error.AdminBusy;
                break :blk null;
            };
            if (unexpected) |bytes| self.client.?.allocator.free(bytes);
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

const OperationAliasAllocator = struct {
    parent: std.mem.Allocator,
    target: []u8,
    armed: bool = false,
    alias_returned: bool = false,
    alias_freed: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.armed) {
            self.alias_returned = true;
            return self.target.ptr;
        }
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (@intFromPtr(memory.ptr) == @intFromPtr(self.target.ptr)) {
            self.alias_freed = true;
            _ = c.write(2, "FORGED_RESPONSE_ALIAS_FREED\n", "FORGED_RESPONSE_ALIAS_FREED\n".len);
            return;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};
