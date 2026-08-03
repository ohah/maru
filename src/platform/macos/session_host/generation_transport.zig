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

const Lifecycle = enum(u8) {
    pristine,
    live,
    terminal,
};

var transport_incarnation_issuer: std.atomic.Value(u64) = .init(1);
var response_incarnation_issuer: std.atomic.Value(u64) = .init(1);

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

    pub fn capabilities(self: *GenerationTransport) contract.GenerationCapabilities {
        const client = self.borrowClient() orelse @panic("invalid generation transport");
        const profile = client.compatibility_profile orelse
            @panic("generation transport lacks compatibility profile");
        return .{
            .wire_major = client.wire_major,
            .screen_codec_version = client.screen_codec_version,
            .attach_schema = switch (profile.attach_schema) {
                .frozen_controller_only => .frozen_controller_only,
                .granted_roles => .granted_roles,
            },
            .metadata_support = switch (client.metadata_support) {
                .unsupported => .unsupported,
                .supported => .supported,
            },
            .peer_attach_generation = client.attachment_capabilities.peer_attach_generation,
            .screen_viewport_scrolled = client.screen_viewport_scrolled_v1,
            .async_scroll_to_bottom = client.async_scroll_to_bottom_v1,
            .notification_stream_auth = client.notification_stream_auth_v1,
            .runtime_clipboard = client.runtime_clipboard_v1,
            .runtime_core_command = client.runtime_core_command_v1,
            .runtime_link_at = client.runtime_link_at_v1,
            .runtime_selected_text = client.runtime_selected_text_v1,
        };
    }

    pub fn prepareRequest(
        self: *GenerationTransport,
        request: contract.RuntimeRequest,
    ) Error!contract.PreparedCallReceipt {
        const client = self.borrowClient() orelse return error.MovedOrCopied;
        const identity = try client.prepareBlockingRpcStorage(
            &self.prepared_storage,
            methodFor(request),
            request.params(),
        );
        return contract.PreparedCallReceipt.init(.{
            .transport_incarnation = self.transport_incarnation,
            .request_id = identity.request_id,
            .request_digest = identity.frame_digest,
        }) orelse {
            client.abortPreparedBlockingRpcStorage(&self.prepared_storage) catch
                @panic("prepared request rollback failed");
            return error.InvalidReceipt;
        };
    }

    pub fn executePreparedRequest(
        self: *GenerationTransport,
        receipt: contract.PreparedCallReceipt,
        response_out: *executed_response_mod.ExecutedResponse,
    ) Error!contract.ExecuteResult {
        const client = self.borrowClient() orelse return error.MovedOrCopied;
        if (!self.matchesPrepared(receipt)) return error.InvalidReceipt;
        // Flush older outbound ownership and then capture the allocator before the first byte of
        // this request. Later parser/prepared-frame callbacks cannot redirect response cleanup.
        const response_allocator = client.preflightPreparedBlockingRpcStorageExecution(
            &self.prepared_storage,
        ) catch |err| {
            client.abortPreparedBlockingRpcStorage(&self.prepared_storage) catch
                @panic("preflighted request rollback failed");
            return err;
        };
        // The flush above may invoke allocator callbacks. Re-resolve the canonical owner and
        // repeat every destination check only after those callbacks and immediately before wire.
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        const response_owner = slot.responseOwnerSeal(self.binding_reservation) catch
            return error.InvalidResponseDestination;
        const binding: *contract.PreparedAttachmentBinding =
            @ptrFromInt(self.binding_reservation.identity.binding_storage_addr);
        if (!response_out.canInitializeWithOwner(response_owner) or
            rangesOverlapTyped(response_out, binding) or
            rangesOverlapTyped(response_out, self) or
            rangesOverlapTyped(response_out, &self.prepared_storage) or
            rangesOverlapTyped(response_out, slot) or
            rangesOverlapTyped(response_out, slot.current) or
            rangesOverlapTyped(response_out, client) or
            rangesOverlapTyped(response_owner, self) or
            rangesOverlapTyped(response_owner, &self.prepared_storage) or
            rangesOverlapTyped(response_owner, binding))
            return error.InvalidResponseDestination;
        const response_incarnation = issueIncarnation(&response_incarnation_issuer) catch
            return error.IdentityExhausted;
        const executed = contract.ExecutedCallReceipt.fromPrepared(receipt) orelse
            return error.InvalidReceipt;
        const response = switch (client.executePreparedBlockingRpcStorageWithAllocator(
            &self.prepared_storage,
            response_allocator,
        )) {
            .not_executed => |err| {
                client.abortPreparedBlockingRpcStorage(&self.prepared_storage) catch
                    @panic("not-executed prepared request rollback failed");
                return err;
            },
            .uncertain => {
                client.poison(.transport_read_failure);
                const result: contract.ExecuteResult = .{
                    .uncertain_or_connection_failure = executed,
                };
                response_out.initWithoutPayloadInPlace(response_owner, response_incarnation, result) catch {
                    client.poison(.local_invariant_violation);
                    return error.InvalidResponseDestination;
                };
                return result;
            },
            .accepted => |value| value,
        };
        if (!std.meta.eql(response.payload_allocator, response_allocator)) {
            // The parser records the allocator value used for the actual payload allocation.
            // Any drift after preflight makes the owner ambiguous to this request; do not free it.
            client.poison(.local_invariant_violation);
            return error.InvalidResponseDestination;
        }
        if (payloadOverlaps(response.payload, .{
            response_out,
            response_owner,
            binding,
            self,
            &self.prepared_storage,
            slot,
            slot.current,
            client,
        }) or rangeOverlaps(
            @intFromPtr(response.payload.ptr),
            response.payload.len,
            self.owner_addr,
            self.owner_size,
        )) {
            // A hostile allocator may return authoritative storage as an owned payload. Freeing
            // that forged slice would corrupt the owner graph, so fail-stop the connection and
            // quarantine the bounded slice instead of invoking an untrusted free authority.
            client.poison(.local_invariant_violation);
            return error.InvalidResponseDestination;
        }
        const correlated = contract.CorrelatedExecutedCall.init(
            executed,
            response.response_request_id,
        ) orelse {
            client.poison(.local_invariant_violation);
            response_allocator.free(response.payload);
            return error.InvalidReceipt;
        };
        if (!correlated.responseMatchesPrepared()) {
            client.poison(.response_correlation_lost);
            response_allocator.free(response.payload);
            return error.InvalidReceipt;
        }
        const result: contract.ExecuteResult = .{ .accepted = correlated };
        response_out.initAcceptedInPlace(
            response_allocator,
            response_owner,
            response_incarnation,
            correlated,
            response.payload,
        ) catch {
            client.poison(.local_invariant_violation);
            response_allocator.free(response.payload);
            return error.InvalidResponseDestination;
        };
        return result;
    }

    pub fn abortPreparedRequest(
        self: *GenerationTransport,
        receipt: contract.PreparedCallReceipt,
    ) Error!void {
        const client = self.borrowClient() orelse return error.MovedOrCopied;
        if (!self.matchesPrepared(receipt)) return error.InvalidReceipt;
        try client.abortPreparedBlockingRpcStorage(&self.prepared_storage);
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
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != .live or
            self.slot_addr == 0 or self.owner_seal_addr == 0 or self.owner_size == 0 or
            self.transport_incarnation == 0 or
            self.connection_generation != 1 or self.pid != currentPid() or
            self.owner_thread_id != std.Thread.getCurrentId())
            return null;
        const owner_seal: *const contract.TransportOwnerSeal = @ptrFromInt(self.owner_seal_addr);
        const slot: *client_slot_mod.ClientSlot = @ptrFromInt(self.slot_addr);
        if (!slot.valid() or slot.incarnation.tagged != self.slot_incarnation or
            slot.current.incarnation.tagged != self.node_incarnation or
            slot.current.client.host_id != self.host_id or
            slot.process_nonce != self.process_nonce)
            return null;
        const canonical_seal = slot.transportOwnerSeal(self.binding_reservation) catch return null;
        if (canonical_seal != owner_seal or !canonical_seal.valid(self.transport_incarnation))
            return null;
        return slot.logicalClient();
    }

    fn matchesPrepared(
        self: *GenerationTransport,
        receipt: contract.PreparedCallReceipt,
    ) bool {
        return receipt.valid() and
            receipt.transport_incarnation == self.transport_incarnation and
            (self.borrowClient() orelse return false).preparedBlockingRpcStorageMatches(
                &self.prepared_storage,
                .{ .request_id = receipt.request_id, .frame_digest = receipt.request_digest },
            );
    }
};

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
    if (out.self_addr != 0 or out.lifecycle != .pristine or
        owner_seal.self_addr != 0 or owner_seal.lifecycle != .pristine)
        return error.DestinationOccupied;
    if (!slot.valid() or owner_addr == 0) return error.InvalidTransport;
    const incarnation = issueIncarnation(&transport_incarnation_issuer) catch
        return error.IdentityExhausted;
    contract.TransportOwnerSeal.initInPlace(owner_seal, incarnation) catch
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
    if (stream_id == 0 or transport.self_addr != @intFromPtr(transport) or
        transport.lifecycle != .live or transport.owner_addr != owner_addr or
        transport.bound_stream_id != 0 or transport.borrowClient() == null)
        return error.InvalidTransport;
    transport.bound_stream_id = stream_id;
}

/// Owner-only no-I/O authority fence. It is module-level so the public transport facade remains
/// exactly five methods; source boundaries pin its sole production caller to GenerationAttachment.
pub fn terminalizeOwned(transport: *GenerationTransport, owner_addr: usize) Error!void {
    if (preflightTerminalizeOwned(transport, owner_addr) != .ready)
        return error.InvalidTransport;
    const slot: *client_slot_mod.ClientSlot = @ptrFromInt(transport.slot_addr);
    const owner_seal = slot.transportOwnerSeal(transport.binding_reservation) catch
        return error.InvalidTransport;
    transport.snapshot_authority.terminalize(transport.transport_incarnation) catch unreachable;
    owner_seal.terminalize(transport.transport_incarnation) catch return error.InvalidTransport;
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
    if (transport.self_addr != @intFromPtr(transport) or transport.lifecycle != .live or
        transport.owner_addr == 0 or transport.owner_addr != owner_addr or transport.owner_seal_addr == 0 or
        !client_mod.Client.preparedBlockingRpcStorageSettled(&transport.prepared_storage))
        return .invalid;
    if (!transport.snapshot_authority.canTerminalize(transport.transport_incarnation))
        return .busy;
    const slot: *client_slot_mod.ClientSlot = @ptrFromInt(transport.slot_addr);
    if (!slot.initialSnapshotPermitIdle()) return .busy;
    const owner_seal = slot.transportOwnerSeal(transport.binding_reservation) catch
        return .invalid;
    if (@intFromPtr(owner_seal) != transport.owner_seal_addr) return .invalid;
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

fn methodFor(request: contract.RuntimeRequest) []const u8 {
    return switch (request) {
        .spawn_full => "runtime.spawn_full",
        .attach_controller => "runtime.attach",
        .resize => "runtime.resize",
        .observation => "runtime.observation",
        .selected_text => "runtime.selected_text",
        .link_at => "runtime.link_at",
        .clipboard_write => "runtime.clipboard_write",
        .find => "runtime.find",
        .select_op => "runtime.select",
        .core_command => "runtime.core_command",
        .report_mouse => "runtime.report_mouse",
        .notification => "runtime.notification",
        .terminate => "runtime.terminate",
        .detach => "runtime.detach",
    };
}

fn isForbiddenFacadeType(comptime T: type) bool {
    if (T == client_mod.Client) return true;
    return switch (@typeInfo(T)) {
        .pointer => |info| isForbiddenFacadeType(info.child),
        .optional => |info| isForbiddenFacadeType(info.child),
        .array => |info| isForbiddenFacadeType(info.child),
        .error_union => |info| isForbiddenFacadeType(info.payload),
        else => false,
    };
}

comptime {
    const methods = .{
        GenerationTransport.capabilities,
        GenerationTransport.prepareRequest,
        GenerationTransport.executePreparedRequest,
        GenerationTransport.abortPreparedRequest,
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
    const receipt = try transport.prepareRequest(
        .{ .attach_controller = .{ .json = "{\"runtime_id\":\"01\"}" } },
    );
    try std.testing.expectEqual(@as(u64, 1), receipt.request_id);
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, 0x101);
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
        error.MovedOrCopied,
        copied.prepareRequest(.{ .detach = .{ .json = null } }),
    );
    const receipt = try transport.prepareRequest(.{ .detach = .{ .json = null } });
    try std.testing.expectEqual(@as(u64, 1), receipt.request_id);
    try transport.abortPreparedRequest(receipt);
    try terminalizeOwned(&transport, 0x103);
    try slot.abortAttachmentBinding(&binding, reservation);
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
    const receipt = try transport.prepareRequest(.{ .detach = .{ .json = null } });
    try std.testing.expectError(
        error.InvalidResponseDestination,
        transport.executePreparedRequest(receipt, response),
    );
    try transport.abortPreparedRequest(receipt);
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
    const receipt = try transport.prepareRequest(.{
        .attach_controller = .{ .json = "{\"runtime_id\":\"01\"}" },
    });
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
    const receipt = try transport.prepareRequest(.{
        .attach_controller = .{ .json = "{\"runtime_id\":\"01\"}" },
    });
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
    const receipt = try transport.prepareRequest(.{ .detach = .{ .json = null } });
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
    try transport.abortPreparedRequest(receipt);
    response = .{};
    try terminalizeOwned(&transport, 0x108);
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
    const receipt = try transport.prepareRequest(.{ .detach = .{ .json = null } });
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
