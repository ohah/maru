//! GUI-only final-address attachment owner for CR3a-2a.
//!
//! The movable RemoteAttachment remains the screen/batch payload used by external attach. This
//! wrapper is only embedded in RemoteRuntime and owns the generation transport, prepared binding,
//! pre-reserved connection lease and the single teardown path around that payload.

const std = @import("std");
const client_slot_mod = @import("client_slot.zig");
const connection_lease = @import("connection_lease.zig");
const contract = @import("generation_attachment_contract.zig");
const executed_response_mod = @import("executed_response.zig");
const generation_transport_mod = @import("generation_transport.zig");
const generation_batch_adapter_mod = @import("generation_batch_adapter.zig");
const framing = @import("framing.zig");
const initial_snapshot_owner_mod = @import("initial_snapshot_owner.zig");
const host_adapter_mod = @import("host_adapter.zig");
const remote_attachment = @import("remote_attachment.zig");
const screen_assembler = @import("screen_assembler.zig");
const screen_stream = @import("screen_stream.zig");

pub const Lifecycle = enum(u8) {
    pristine,
    shell,
    binding_prepared,
    executing,
    attached,
    cleaning,
    terminal,
};

pub const DeinitOutcome = enum {
    cleaned,
    already_terminal,
    busy,
    corrupt,
};

pub const GenerationAttachment = struct {
    self_addr: usize = 0,
    lifecycle: Lifecycle = .pristine,
    transport: generation_transport_mod.GenerationTransport = .{},
    batch_adapter: generation_batch_adapter_mod.GenerationBatchAdapter = .{},
    binding: contract.PreparedAttachmentBinding = .{},
    reservation: ?client_slot_mod.AttachmentBindingReservation = null,
    lease: connection_lease.ConnectionLease = .{},
    response: executed_response_mod.ExecutedResponse = .{},
    payload: ?remote_attachment.RemoteAttachment = null,

    pub fn initInPlace(
        out: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) generation_transport_mod.Error!void {
        if (!rawLifecycleValid(&out.lifecycle) or out.self_addr != 0 or
            out.lifecycle != .pristine or out.payload != null)
            return error.DestinationOccupied;
        _ = adapter;
        out.self_addr = @intFromPtr(out);
        out.lifecycle = .shell;
    }

    pub fn prepareControllerAttach(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        runtime_id: u128,
        params_json: []const u8,
    ) anyerror!contract.PreparedCallReceipt {
        if (!self.valid() or self.lifecycle != .shell) return error.InvalidState;
        const reservation = try adapter.reserveAttachmentBinding(
            &self.binding,
            &self.lease,
            runtime_id,
            .controller,
        );
        errdefer adapter.abortAttachmentBinding(&self.binding, reservation) catch
            @panic("generation attachment binding rollback failed");
        try adapter.mintGenerationTransport(
            &self.transport,
            @intFromPtr(self),
            @sizeOf(GenerationAttachment),
            reservation,
        );
        errdefer self.terminalizeTransport();
        const receipt = try self.transport.prepareRequest(
            .{ .attach_controller = .{ .json = params_json } },
        );
        errdefer self.transport.abortPreparedRequest(receipt) catch
            @panic("generation attachment request rollback failed");
        try self.binding.pairRequest(receipt);
        self.reservation = reservation;
        self.lifecycle = .binding_prepared;
        return receipt;
    }

    pub fn executePreparedAttach(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        receipt: contract.PreparedCallReceipt,
    ) anyerror!contract.ExecuteResult {
        if (!self.valid() or self.lifecycle != .binding_prepared)
            return error.InvalidState;
        self.binding.beginExecute(receipt) catch |err| {
            self.transport.abortPreparedRequest(receipt) catch {};
            self.terminalizeTransport();
            try adapter.abortAttachmentBinding(&self.binding, self.reservation.?);
            self.lifecycle = .terminal;
            return err;
        };
        self.lifecycle = .executing;
        const result = self.transport.executePreparedRequest(
            receipt,
            &self.response,
        ) catch |err| {
            self.transport.abortPreparedRequest(receipt) catch {};
            self.terminalizeTransport();
            try adapter.abortExecutedAttachmentBinding(
                &self.binding,
                self.reservation.?,
                contract.ExecutedCallReceipt.fromPrepared(receipt).?,
            );
            self.lifecycle = .terminal;
            return err;
        };
        self.settleExecutedOutcome(adapter, result);
        return result;
    }

    fn settleExecutedOutcome(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        result: contract.ExecuteResult,
    ) void {
        switch (result) {
            .uncertain_or_connection_failure => |executed| {
                if (self.finishResponse(adapter) != .cleaned)
                    @panic("uncertain response settlement failed");
                self.terminalizeTransport();
                adapter.abortExecutedAttachmentBinding(
                    &self.binding,
                    self.reservation.?,
                    executed,
                ) catch @panic("uncertain binding settlement failed");
                self.lifecycle = .terminal;
            },
            .typed_reject => |correlated| {
                if (self.finishResponse(adapter) != .cleaned)
                    @panic("typed reject response settlement failed");
                self.terminalizeTransport();
                adapter.abortExecutedAttachmentBinding(
                    &self.binding,
                    self.reservation.?,
                    correlated.executed_call,
                ) catch @panic("typed reject binding settlement failed");
                self.lifecycle = .terminal;
            },
            .accepted => {},
        }
    }

    pub fn responseBytes(
        self: *const GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) anyerror![]const u8 {
        if (!self.valid() or self.lifecycle != .executing) return error.InvalidState;
        const owner = try adapter.responseOwnerSeal(self.reservation orelse return error.InvalidState);
        return self.response.borrowAccepted(owner);
    }

    pub fn finishResponse(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) DeinitOutcome {
        if (self.response.lifecycle == .terminal)
            return if (self.response.self_addr == @intFromPtr(&self.response))
                .already_terminal
            else
                .corrupt;
        const owner = adapter.responseOwnerSeal(self.reservation orelse return .corrupt) catch
            return .corrupt;
        return switch (self.response.deinit(owner)) {
            .cleaned => .cleaned,
            .already_terminal => .already_terminal,
            .corrupt => .corrupt,
        };
    }

    pub fn abortExecutedAttach(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        executed: contract.ExecutedCallReceipt,
    ) anyerror!void {
        if (!self.valid() or self.lifecycle != .executing) return error.InvalidState;
        self.terminalizeTransport();
        try adapter.abortExecutedAttachmentBinding(
            &self.binding,
            self.reservation.?,
            executed,
        );
        self.lifecycle = .terminal;
    }

    pub fn commitAccepted(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        accepted: contract.CorrelatedExecutedCall,
        state: remote_attachment.State,
        allocator: std.mem.Allocator,
    ) anyerror!void {
        if (!self.valid() or self.lifecycle != .executing or self.payload != null)
            return error.InvalidState;
        try adapter.mintGenerationBatchAdapter(
            &self.batch_adapter,
            @intFromPtr(self),
            @sizeOf(GenerationAttachment),
            state.stream_id,
        );
        errdefer self.batch_adapter.abortPrepared();
        try adapter.commitAttachmentBinding(
            &self.binding,
            self.reservation.?,
            accepted,
            state.stream_id,
            &self.lease,
        );
        generation_transport_mod.bindCommittedStreamOwned(
            &self.transport,
            @intFromPtr(self),
            state.stream_id,
        ) catch @panic("generation transport stream seal failed after binding commit");
        self.batch_adapter.activateCommitted() catch
            @panic("generation batch adapter activation failed after binding commit");
        self.payload = remote_attachment.RemoteAttachment.init(allocator, state);
        self.payload.?.bindTransport(self.batch_adapter.interface()) catch unreachable;
        self.lifecycle = .attached;
    }

    pub fn readInitialSnapshot(
        self: *GenerationAttachment,
        out: *initial_snapshot_owner_mod.InitialSnapshotOwner,
    ) anyerror!void {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidState;
        return self.transport.readInitialSnapshot(out);
    }

    /// Initial snapshot bytes are already generation-owned, so semantic apply failures must
    /// terminalize the same sealed connection instead of escaping through RemoteRuntime's legacy
    /// raw Client field.
    pub fn poisonInitialSnapshotApply(
        self: *GenerationAttachment,
        out_of_memory: bool,
    ) anyerror!void {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidState;
        return self.transport.poison(if (out_of_memory)
            .local_resource_exhausted
        else
            .peer_contract_violation);
    }

    pub fn tryDeinit(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) DeinitOutcome {
        if (!rawLifecycleValid(&self.lifecycle)) return .corrupt;
        if (self.lifecycle == .terminal)
            return if (self.self_addr == @intFromPtr(self)) .already_terminal else .corrupt;
        if (!self.valid()) return .corrupt;
        switch (self.lifecycle) {
            .shell => self.terminalizeTransport(),
            .binding_prepared => return .busy,
            .executing => return .busy,
            .cleaning => return .busy,
            .attached => {
                if (self.response.lifecycle != .terminal) return .busy;
                switch (generation_transport_mod.preflightTerminalizeOwned(
                    &self.transport,
                    @intFromPtr(self),
                )) {
                    .ready => {},
                    .busy => return .busy,
                    .invalid => return .corrupt,
                }
                const payload = &(self.payload orelse return .corrupt);
                self.batch_adapter.preflightDraining() catch return .corrupt;
                adapter.beginAttachmentDrop(
                    &self.binding,
                    self.reservation orelse return .corrupt,
                    &self.lease,
                ) catch return .corrupt;
                self.lifecycle = .cleaning;
                // 새 read와 RPC 권위는 먼저 닫되, pending generation token 전량을 정리할 때까지
                // batch adapter의 release-only draining 권위는 유지한다.
                self.batch_adapter.commitDraining();
                self.terminalizeTransport();
                payload.deinitPayloadOnly();
                self.batch_adapter.finishDraining();
                self.payload = null;
                adapter.finishActiveAttachmentDrop(
                    &self.binding,
                    self.reservation.?,
                    &self.lease,
                );
            },
            .pristine, .terminal => return .corrupt,
        }
        self.lifecycle = .terminal;
        return .cleaned;
    }

    pub fn deinit(self: *GenerationAttachment, adapter: *host_adapter_mod.HostAdapter) void {
        const outcome = self.tryDeinit(adapter);
        if (outcome != .cleaned and outcome != .already_terminal)
            @panic("generation attachment teardown invariant violated");
    }

    pub fn streamId(self: *const GenerationAttachment) u64 {
        return self.payloadConst().streamId();
    }

    pub fn allowsMutation(self: *const GenerationAttachment) bool {
        if (!self.payloadConst().allowsMutation()) return false;
        return generation_transport_mod.mutationAllowedOwned(
            @constCast(&self.transport),
            @intFromPtr(self),
        );
    }

    pub fn hasBufferedControllerRevoke(self: *const GenerationAttachment) bool {
        return generation_transport_mod.bufferedControllerRevokeOwned(
            @constCast(&self.transport),
            @intFromPtr(self),
        );
    }

    pub fn statePtr(self: *GenerationAttachment) *remote_attachment.State {
        return &self.payloadMut().state;
    }

    pub fn screenPtr(self: *GenerationAttachment) ?*@import("remote_screen.zig").RemoteScreen {
        const payload = if (self.payload) |*value| value else return null;
        return if (payload.screen) |*screen| screen else null;
    }

    pub fn initScreen(self: *GenerationAttachment, codec: u16) anyerror!void {
        return self.payloadMut().initScreen(codec);
    }

    pub fn sendInput(
        self: *GenerationAttachment,
        bytes: []const u8,
    ) generation_transport_mod.InputError!void {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return self.transport.sendInput(bytes);
    }

    pub fn sendInputNonBlocking(
        self: *GenerationAttachment,
        bytes: []const u8,
    ) generation_transport_mod.InputError!usize {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return self.transport.sendInputNonBlocking(bytes);
    }

    pub fn pumpPendingOutput(
        self: *GenerationAttachment,
    ) generation_transport_mod.InputError!bool {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return self.transport.pumpPendingOutput();
    }

    pub fn fenceRevoke(
        self: *GenerationAttachment,
    ) generation_transport_mod.InputError!generation_transport_mod.RevokeFence {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return self.transport.fenceRevoke();
    }

    pub fn pumpScreen(
        self: *GenerationAttachment,
        io: std.Io,
    ) (@import("client.zig").ClientError || screen_assembler.ApplyError || remote_attachment.LeaseError)!remote_attachment.PumpScreenResult {
        return self.payloadMut().pumpScreen(io);
    }

    pub fn applyValidatedRevokedAndFence(
        self: *GenerationAttachment,
        generation: u64,
    ) anyerror!generation_transport_mod.RevokeFence {
        const permit = try generation_transport_mod.beginControllerRevokeOwned(
            &self.transport,
            @intFromPtr(self),
        );
        // revoke_pending already rejects every input admission while retaining only the one-shot
        // pending-wire cleanup authority. Every exit consumes it into absorbing revoked state.
        defer generation_transport_mod.finishControllerRevokeOwned(
            &self.transport,
            @intFromPtr(self),
            permit,
        ) catch @panic("generation revoke authority close failed");
        try self.payloadMut().applyValidatedRevoked(generation);
        return self.transport.fenceRevoke();
    }

    fn valid(self: *const GenerationAttachment) bool {
        return rawLifecycleValid(&self.lifecycle) and
            self.self_addr == @intFromPtr(self) and self.lifecycle != .pristine;
    }

    fn terminalizeTransport(self: *GenerationAttachment) void {
        generation_transport_mod.terminalizeOwned(
            &self.transport,
            @intFromPtr(self),
        ) catch @panic("generation transport terminalization failed");
    }

    fn payloadMut(self: *GenerationAttachment) *remote_attachment.RemoteAttachment {
        if (!self.valid() or self.lifecycle != .attached) @panic("generation attachment is not live");
        return if (self.payload) |*payload| payload else @panic("generation attachment payload missing");
    }

    fn payloadConst(self: *const GenerationAttachment) *const remote_attachment.RemoteAttachment {
        if (!self.valid() or self.lifecycle != .attached) @panic("generation attachment is not live");
        return if (self.payload) |*payload| payload else @panic("generation attachment payload missing");
    }
};

fn rawLifecycleValid(value: *const Lifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(Lifecycle.terminal);
}

test "CR3a-2c3a attachment facade raw lifecycle sweep is fail closed in ReleaseFast" {
    var attachment: GenerationAttachment = .{};
    const lifecycle_raw: *u8 = @ptrCast(&attachment.lifecycle);
    var raw: u16 = 0;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        lifecycle_raw.* = @intCast(raw);
        try std.testing.expectError(error.InvalidOwner, attachment.sendInput("x"));
        try std.testing.expectError(error.InvalidOwner, attachment.sendInputNonBlocking("x"));
        try std.testing.expectError(error.InvalidOwner, attachment.pumpPendingOutput());
        try std.testing.expectError(error.InvalidOwner, attachment.fenceRevoke());
    }
    attachment = .{};
}

const AttachmentReentrantFreeAllocator = struct {
    parent: std.mem.Allocator,
    target: ?*GenerationAttachment = null,
    adapter: ?*host_adapter_mod.HostAdapter = null,
    armed: bool = false,
    reentered: bool = false,
    nested_outcome: ?DeinitOutcome = null,
    transport_rejected: bool = false,

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
        if (self.armed and !self.reentered) {
            self.reentered = true;
            self.nested_outcome = self.target.?.tryDeinit(self.adapter.?);
            self.transport_rejected = if (self.target.?.transport.prepareRequest(
                .{ .detach = .{ .json = null } },
            )) |_| false else |_| true;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "CR3a-2a generation attachment uncertain execute permits exact adapter teardown" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xAA,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0xBB,
        "{\"runtime_id\":\"000000000000000000000000000000bb\",\"mode\":\"controller\"}",
    );
    const result = try attachment.executePreparedAttach(&adapter, receipt);
    switch (result) {
        .uncertain_or_connection_failure => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(DeinitOutcome.already_terminal, attachment.finishResponse(&adapter));
    try std.testing.expectEqual(DeinitOutcome.already_terminal, attachment.tryDeinit(&adapter));
}

test "CR3a-2a attached teardown fences transport before adapter release" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var reentrant = AttachmentReentrantFreeAllocator{ .parent = allocator };
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xCC,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0xDD,
        "{\"runtime_id\":\"000000000000000000000000000000dd\",\"mode\":\"controller\"}",
    );
    try attachment.binding.beginExecute(receipt);
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0xEF,
        accepted,
        response_bytes,
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    attachment.lifecycle = .executing;
    try attachment.commitAccepted(&adapter, accepted, .{
        .runtime_id = 0xDD,
        .stream_id = 0xEE,
        .role = .controller,
        .controller_generation = 1,
    }, reentrant.allocator());
    const pending_bytes = try reentrant.allocator().dupe(u8, "pending");
    try attachment.payload.?.pending_batches.append(
        reentrant.allocator(),
        .{ .untracked = .{
            .is_snapshot = false,
            .stream_id = 0xEE,
            .bytes = pending_bytes,
            .allocator = reentrant.allocator(),
        } },
    );
    const stale_transport = attachment.transport;
    const stale_parent = attachment;
    reentrant.target = &attachment;
    reentrant.adapter = &adapter;
    reentrant.armed = true;
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    reentrant.armed = false;
    try std.testing.expect(reentrant.reentered);
    try std.testing.expectEqual(DeinitOutcome.busy, reentrant.nested_outcome.?);
    try std.testing.expect(reentrant.transport_rejected);
    attachment.transport = stale_transport;
    try std.testing.expectError(
        error.MovedOrCopied,
        attachment.transport.prepareRequest(.{ .detach = .{ .json = null } }),
    );
    attachment = stale_parent;
    try std.testing.expectError(
        error.MovedOrCopied,
        attachment.transport.prepareRequest(.{ .detach = .{ .json = null } }),
    );
}

test "CR3a-2a whole-parent restore cannot revive accepted response or transport authority" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xDA,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0xDB,
        "{\"runtime_id\":\"000000000000000000000000000000db\",\"mode\":\"controller\"}",
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0xDC,
        correlated,
        bytes,
    );
    const stale_parent = attachment;
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.abortExecutedAttach(&adapter, executed);
    adapter.deinit();

    attachment = stale_parent;
    try std.testing.expectError(
        error.MovedOrCopied,
        attachment.transport.prepareRequest(.{ .detach = .{ .json = null } }),
    );
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.finishResponse(&adapter));
}

test "CR3a-2b2 CR3a-2c3a generation GUI pump transfers and revoke closes direct input authority" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2B2,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0x2B3,
        "{\"runtime_id\":\"000000000000000000000000000002b3\",\"mode\":\"controller\"}",
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2B4,
        accepted,
        response_bytes,
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.commitAccepted(&adapter, accepted, .{
        .runtime_id = 0x2B3,
        .stream_id = 0x2B5,
        .role = .controller,
        .controller_generation = 1,
    }, allocator);
    try attachment.initScreen(screen_stream.codec_version);
    try std.testing.expectEqual(
        remote_attachment.PumpScreenResult.idle,
        try attachment.pumpScreen(std.testing.io),
    );

    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    defer snapshot.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&snapshot, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&snapshot, allocator, row);

    const first_batch_bytes = try allocator.dupe(u8, snapshot.items);
    const second_batch_bytes = try allocator.dupe(u8, snapshot.items);
    const logical_client = adapter.logicalClient();
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 0x2B5,
        .bytes = first_batch_bytes,
        .allocator = allocator,
    });
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 0x2B5,
        .bytes = second_batch_bytes,
        .allocator = allocator,
    });
    logical_client.pending_batch_bytes = first_batch_bytes.len + second_batch_bytes.len;

    for (0..2) |_| {
        try std.testing.expectEqual(
            remote_attachment.PumpScreenResult.applied,
            try attachment.pumpScreen(std.testing.io),
        );
    }
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(
        @import("generation_batch_registry.zig").DeinitOutcome.cleaned,
        adapter.slot.current.accounting_ledger.preflightDeinit(),
    );

    // A validated revoke closes both the ordinary attachment wrapper and the independently
    // reachable embedded transport. The original sealed controller role cannot revive input.
    const revoke_pending = try framing.encodeFrame(
        allocator,
        .{ .kind = .input_bytes, .stream_id = 0x2B5 },
        "pending-before-revoke",
    );
    const pre_revoke_transport = attachment.transport;
    logical_client.pending_outbound = .{ .frame = revoke_pending, .stream_id = 0x2B5 };
    try std.testing.expectEqual(
        generation_transport_mod.RevokeFence.cancelled_before_write,
        try attachment.applyValidatedRevokedAndFence(2),
    );
    try std.testing.expect(logical_client.pending_outbound == null);
    try std.testing.expectError(error.Unauthorized, attachment.sendInput("after-revoke"));
    try std.testing.expectError(
        error.Unauthorized,
        attachment.transport.sendInputNonBlocking("direct-after-revoke"),
    );
    try std.testing.expect(logical_client.pending_outbound == null);
    attachment.transport = pre_revoke_transport;
    try std.testing.expectError(
        error.Unauthorized,
        attachment.transport.sendInputNonBlocking("restored-pre-revoke-bytes"),
    );

    // RemoteAttachment queue append OOM도 generation token을 즉시 exact-once release한다.
    // Revoke fencing is deliberately tested first because this OOM fail-closes the connection.
    attachment.payload.?.pending_batches.deinit(allocator);
    attachment.payload.?.pending_batches = .empty;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    attachment.payload.?.allocator = failing.allocator();
    const oom_bytes = try allocator.dupe(u8, snapshot.items);
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 0x2B5,
        .bytes = oom_bytes,
        .allocator = allocator,
    });
    logical_client.pending_batch_bytes = oom_bytes.len;
    try std.testing.expectError(error.OutOfMemory, attachment.pumpScreen(std.testing.io));
    attachment.payload.?.allocator = allocator;
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());

    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(
        @import("generation_batch_registry.zig").DeinitOutcome.cleaned,
        adapter.slot.current.accounting_ledger.preflightDeinit(),
    );
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, attachment.binding.lifecycle);
}

test "CR3a-2b2 generation GUI pump releases a malformed node-owned batch" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2D2,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0x2D3,
        "{\"runtime_id\":\"000000000000000000000000000002d3\",\"mode\":\"controller\"}",
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2D4,
        accepted,
        response_bytes,
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.commitAccepted(&adapter, accepted, .{
        .runtime_id = 0x2D3,
        .stream_id = 0x2D5,
        .role = .controller,
        .controller_generation = 1,
    }, allocator);
    try attachment.initScreen(screen_stream.codec_version);

    const malformed_bytes = try allocator.dupe(u8, "malformed-screen-record");
    const logical_client = adapter.logicalClient();
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 0x2D5,
        .bytes = malformed_bytes,
        .allocator = allocator,
    });
    logical_client.pending_batch_bytes = malformed_bytes.len;
    try std.testing.expectError(error.Truncated, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(
        @import("generation_batch_registry.zig").DeinitOutcome.cleaned,
        adapter.slot.current.accounting_ledger.preflightDeinit(),
    );
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, attachment.binding.lifecycle);
}

test "CR3a-2b2 generation GUI pump transfers a direct parser frame through the node adapter" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const protocol = @import("protocol.zig");
    const socket_server = @import("socket_server.zig");
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = std.c.close(fds[1]);
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0x2C1,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0x2C2,
        "{\"runtime_id\":\"000000000000000000000000000002c2\",\"mode\":\"controller\"}",
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2C3,
        accepted,
        response_bytes,
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.commitAccepted(&adapter, accepted, .{
        .runtime_id = 0x2C2,
        .stream_id = 0x2C4,
        .role = .controller,
        .controller_generation = 1,
    }, allocator);
    try attachment.initScreen(screen_stream.codec_version);

    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    defer snapshot.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&snapshot, allocator, meta);
    const wire = try framing.encodeFrame(
        allocator,
        .{
            .kind = .snapshot_chunk,
            .stream_id = 0x2C4,
            .flags = protocol.Flags.end_stream,
        },
        snapshot.items,
    );
    defer allocator.free(wire);
    try socket_server.writeAll(fds[1], wire);

    try std.testing.expectEqual(
        remote_attachment.PumpScreenResult.applied,
        try attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());

    // 다음 batch는 payload queue가 이미 소유한 상태에서 teardown해 release-only draining과
    // canonical drop의 exact 순서를 고정한다.
    const pending_bytes = try allocator.dupe(u8, "pending-generation-batch");
    const logical_client = adapter.logicalClient();
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 0x2C4,
        .bytes = pending_bytes,
        .allocator = allocator,
    });
    logical_client.pending_batch_bytes = pending_bytes.len;
    const generation_transport = attachment.payload.?.transport.?;
    const pending_lease = (try generation_transport.read_batch(
        generation_transport.context,
        0x2C4,
    )).?;
    try attachment.payload.?.pending_batches.append(allocator, pending_lease);
    try std.testing.expectEqual(@as(usize, 1), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
}

test "CR3a-2a typed reject settles binding response and transport exactly once" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xFA,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(
        &adapter,
        0xFB,
        "{\"runtime_id\":\"000000000000000000000000000000fb\",\"mode\":\"controller\"}",
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const result: contract.ExecuteResult = .{ .typed_reject = correlated };
    try attachment.response.initWithoutPayloadInPlace(
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0xFC,
        result,
    );
    attachment.settleExecutedOutcome(&adapter, result);
    try std.testing.expectEqual(Lifecycle.terminal, attachment.lifecycle);
    try std.testing.expectEqual(contract.BindingLifecycle.terminal, attachment.binding.lifecycle);
    try std.testing.expectEqual(DeinitOutcome.already_terminal, attachment.finishResponse(&adapter));
    try std.testing.expectEqual(DeinitOutcome.already_terminal, attachment.tryDeinit(&adapter));
}
