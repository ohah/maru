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
const socket_server = @import("socket_server.zig");
const builtin = @import("builtin");
const posix = std.posix;

const c = std.c;

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
    _ = std.math.add(usize, owner_addr, owner_size) catch return error.InvalidTransport;
    const owner_seal = slot.transportOwnerSeal(binding_reservation) catch
        return error.InvalidTransport;
    if (rangesOverlapTyped(out, owner_seal) or rangesOverlapTyped(out, slot) or
        rangesOverlapTyped(out, slot.current) or
        rangesOverlapTyped(out, &slot.current.client) or
        owner_addr == @intFromPtr(slot) or owner_addr == @intFromPtr(slot.current) or
        owner_addr == @intFromPtr(&slot.current.client) or owner_addr == @intFromPtr(owner_seal))
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xA1);
    try mintInPlace(&transport, &slot, 0x101, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    try std.testing.expectEqual(@as(u64, 1), receipt.request_id);
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, 0x101);
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
        0x2C3BF2,
    );
    try mintInPlace(
        &controller_transport,
        &controller_slot,
        0x2C3BF3,
        @sizeOf(GenerationTransport),
        controller_reservation,
    );
    try controller_slot.current.cleanup_registry.bindStream(
        controller_reservation.cleanup,
        controller_reservation.identity,
        41,
    );
    try bindCommittedStreamOwned(&controller_transport, 0x2C3BF3, 41);
    const mutation = try controller_transport.prepareRequest(contract.RuntimeRequest.find(
        contract.FindRequest.init("needle", 0, true).?,
    ));
    try controller_transport.abortPreparedRequest(mutation);
    try controller_slot.current.cleanup_registry.beginBoundDrop(
        controller_reservation.cleanup,
        controller_reservation.identity,
        41,
    );
    try terminalizeOwned(&controller_transport, 0x2C3BF3);
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
        0x2C3BF5,
        .observer,
    );
    try mintInPlace(
        &observer_transport,
        &observer_slot,
        0x2C3BF6,
        @sizeOf(GenerationTransport),
        observer_reservation,
    );
    try observer_slot.current.cleanup_registry.bindStream(
        observer_reservation.cleanup,
        observer_reservation.identity,
        43,
    );
    try bindCommittedStreamOwned(&observer_transport, 0x2C3BF6, 43);
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
    try terminalizeOwned(&observer_transport, 0x2C3BF6);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3B72);
    try mintInPlace(&transport, &slot, 0x2C3B73, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    const saved = transport.prepared_storage.bytes;
    @memset(&transport.prepared_storage.bytes, 0);
    try std.testing.expectEqual(
        TerminalizeReadiness.busy,
        preflightTerminalizeOwned(&transport, 0x2C3B73),
    );
    try std.testing.expectError(error.InvalidTransport, terminalizeOwned(&transport, 0x2C3B73));
    transport.prepared_storage.bytes = saved;
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, 0x2C3B73);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xA2);
    try mintInPlace(&transport, &slot, 0x102, @sizeOf(GenerationTransport), reservation);

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
    try terminalizeOwned(&transport, 0x102);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xB1);
    try mintInPlace(&transport, &slot, 0x103, @sizeOf(GenerationTransport), reservation);
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
    try terminalizeOwned(&transport, 0x103);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3BCB);
    try mintInPlace(&transport, &slot, 0x2C3BCC, @sizeOf(GenerationTransport), reservation);
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
    try terminalizeOwned(&transport, 0x2C3BCC);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3A1);
    try mintInPlace(&transport, &slot, 0x2C3A2, @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 17);
    try bindCommittedStreamOwned(&transport, 0x2C3A2, 17);

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
        fn run(target: *GenerationTransport, rejected: *bool, capability_rejected: *bool) void {
            _ = target.capabilities() catch {
                capability_rejected.* = true;
            };
            _ = target.sendInputNonBlocking("x") catch {
                rejected.* = true;
            };
        }
    };
    var cross_thread_rejected = false;
    var cross_thread_capability_rejected = false;
    var thread = try std.Thread.spawn(.{}, ThreadProbe.run, .{
        &transport,
        &cross_thread_rejected,
        &cross_thread_capability_rejected,
    });
    thread.join();
    try std.testing.expect(cross_thread_rejected);
    try std.testing.expect(cross_thread_capability_rejected);
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
    try terminalizeOwned(&transport, 0x2C3A2);
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
        0x2C3C1,
        .observer,
    );
    try mintInPlace(&transport, &slot, 0x2C3C2, @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 29);
    try bindCommittedStreamOwned(&transport, 0x2C3C2, 29);
    try std.testing.expectError(error.Unauthorized, transport.sendInputNonBlocking("x"));
    try std.testing.expect(try transport.pumpPendingOutput());
    try std.testing.expectError(error.Unauthorized, transport.fenceRevoke());
    try std.testing.expect(slot.logicalClient().pending_outbound == null);
    try slot.current.cleanup_registry.beginBoundDrop(reservation.cleanup, reservation.identity, 29);
    try terminalizeOwned(&transport, 0x2C3C2);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3B1);
    try mintInPlace(&transport, &slot, 0x2C3B2, @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 23);
    try bindCommittedStreamOwned(&transport, 0x2C3B2, 23);

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
    const revoke_permit = try beginControllerRevokeOwned(&transport, 0x2C3B2);
    try std.testing.expectError(error.Unauthorized, transport.sendInputNonBlocking("late"));
    try std.testing.expectEqual(
        RevokeFence.partial_frame_requires_close,
        try transport.fenceRevoke(),
    );
    try finishControllerRevokeOwned(&transport, 0x2C3B2, revoke_permit);
    try std.testing.expectError(error.Unauthorized, transport.sendInputNonBlocking("restored"));
    try std.testing.expect(slot.logicalClient().pending_outbound != null);

    try slot.current.cleanup_registry.beginBoundDrop(reservation.cleanup, reservation.identity, 23);
    try terminalizeOwned(&transport, 0x2C3B2);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3D1);
    try mintInPlace(&transport, &slot, 0x2C3D2, @sizeOf(GenerationTransport), reservation);
    try slot.current.cleanup_registry.bindStream(reservation.cleanup, reservation.identity, 31);
    try bindCommittedStreamOwned(&transport, 0x2C3D2, 31);

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
    try terminalizeOwned(&transport, 0x2C3D2);
    try slot.current.cleanup_registry.completeActiveDrop(reservation.cleanup, reservation.identity, 31);
    slot.current.pin_owner.cleanup_pin_count -= 1;
    binding.lifecycle = .terminal;
}

test "CR3a-2a response destination cannot splice binding storage before wire" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xBC,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xBC);
    defer slot.deinit();
    const Shared = union {
        binding: contract.PreparedAttachmentBinding,
        response: executed_response_mod.ExecutedResponse,
    };
    var shared: Shared = .{ .binding = .{} };
    const binding: *contract.PreparedAttachmentBinding = @ptrCast(&shared);
    const response: *executed_response_mod.ExecutedResponse = @ptrCast(&shared);
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(binding, &lease, 0xB2);
    var transport: GenerationTransport = .{};
    try mintInPlace(&transport, &slot, 0x104, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    try std.testing.expectError(
        error.InvalidResponseDestination,
        transport.executePreparedRequest(receipt, response),
    );
    try std.testing.expectError(
        error.InvalidReceipt,
        transport.abortPreparedRequest(receipt),
    );
    try std.testing.expect(binding.validAtFinalAddress());
    try terminalizeOwned(&transport, 0x104);
    try slot.abortAttachmentBinding(binding, reservation);
}

test "CR3a-2a execute failure settles prepared backing and publishes uncertain response" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xCC,
        .parser = framing.FrameParser.init(allocator),
    };
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xCC);
    defer slot.deinit();
    var transport: GenerationTransport = .{};
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xC1);
    try mintInPlace(&transport, &slot, 0x105, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    var response: executed_response_mod.ExecutedResponse = .{};
    const result = try transport.executePreparedRequest(receipt, &response);
    switch (result) {
        .uncertain_or_connection_failure => |executed| try std.testing.expect(
            executed.matchesPrepared(receipt),
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
        &transport.prepared_storage,
    ));
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try terminalizeOwned(&transport, 0x105);
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2a response publication failure poisons before payload free reentry" {
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
    var client: client_mod.Client = .{
        .allocator = probe.allocator(),
        .fd = fds[0],
        .host_id = 0xDD,
        .parser = framing.FrameParser.init(probe.allocator()),
    };
    probe.client = &client;
    var slot: client_slot_mod.ClientSlot = undefined;
    try client_slot_mod.ClientSlot.initInPlace(&slot, allocator, &client, 0xDD);
    defer slot.deinit();
    var binding: contract.PreparedAttachmentBinding = .{};
    var lease: @import("connection_lease.zig").ConnectionLease = .{};
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xD1);
    var transport: GenerationTransport = .{};
    try mintInPlace(&transport, &slot, 0x106, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    var response: executed_response_mod.ExecutedResponse = .{};
    probe.response = &response;
    probe.armed = true;
    try std.testing.expectError(
        error.InvalidResponseDestination,
        transport.executePreparedRequest(receipt, &response),
    );
    probe.armed = false;
    peer.join();
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expect(probe.saw_poison_before_free);
    try std.testing.expect(probe.reentry_rejected);
    try std.testing.expect(slot.logicalClient().unusable);
    response = .{};
    try terminalizeOwned(&transport, 0x106);
    try slot.abortAttachmentBinding(&binding, reservation);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xD3);
    var transport: GenerationTransport = .{};
    try mintInPlace(&transport, &slot, 0x108, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    slot.logicalClient().pending_outbound = .{
        .frame = try probe.allocator().dupe(u8, "older"),
        .stream_id = 9,
    };
    var response: executed_response_mod.ExecutedResponse = .{};
    probe.response = &response;
    probe.armed = true;
    try std.testing.expectError(
        error.InvalidResponseDestination,
        transport.executePreparedRequest(receipt, &response),
    );
    probe.armed = false;
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expectError(
        error.InvalidReceipt,
        transport.abortPreparedRequest(receipt),
    );
    response = .{};
    try terminalizeOwned(&transport, 0x108);
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0x2C3BC2);
    var transport: GenerationTransport = .{};
    try mintInPlace(&transport, &slot, 0x2C3BC3, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    slot.logicalClient().pending_outbound = .{
        .frame = try probe.allocator().dupe(u8, "older"),
        .stream_id = 9,
    };
    const canonical_slot_addr = transport.slot_addr;
    var response: executed_response_mod.ExecutedResponse = .{};
    probe.transport = &transport;
    probe.armed = true;
    const result = try transport.executePreparedRequest(receipt, &response);
    switch (result) {
        .uncertain_or_connection_failure => {},
        else => return error.TestUnexpectedResult,
    }
    probe.armed = false;
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expectEqual(@as(usize, 1), transport.slot_addr);
    try std.testing.expect(client_mod.Client.preparedBlockingRpcStorageSettled(
        &transport.prepared_storage,
    ));
    transport.slot_addr = canonical_slot_addr;
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try terminalizeOwned(&transport, 0x2C3BC3);
    try slot.abortAttachmentBinding(&binding, reservation);
}

test "CR3a-2a accepted response retains allocator captured before wire" {
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
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response_wire });
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
    const reservation = try slot.reserveAttachmentBindingForTest(&binding, &lease, 0xD2);
    var transport: GenerationTransport = .{};
    try mintInPlace(&transport, &slot, 0x107, @sizeOf(GenerationTransport), reservation);
    const receipt = try transport.prepareRequest(contract.RuntimeRequest.attachController());
    var response: executed_response_mod.ExecutedResponse = .{};
    probe.armed = true;
    const result = try transport.executePreparedRequest(receipt, &response);
    peer.join();
    try std.testing.expect(result == .accepted);
    try std.testing.expect(probe.mutated_after_preflight);
    try std.testing.expect(std.meta.eql(response.allocator.?, probe.allocator()));
    try std.testing.expectEqual(
        executed_response_mod.DeinitOutcome.cleaned,
        response.deinit(try slot.responseOwnerSeal(reservation)),
    );
    try std.testing.expect(probe.captured_payload_free_seen);
    probe.armed = false;
    client.allocator = probe.allocator();
    try terminalizeOwned(&transport, 0x107);
    try slot.abortAttachmentBinding(&binding, reservation);
}

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
            const unexpected = self.client.?.call("host.info", null) catch |err| blk: {
                self.reentry_rejected = err == error.ConnectionClosed;
                break :blk null;
            };
            if (unexpected) |bytes| self.client.?.allocator.free(bytes);
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};
