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
const host_adapter_mod = @import("host_adapter.zig");
const remote_attachment = @import("remote_attachment.zig");
const screen_assembler = @import("screen_assembler.zig");

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
    binding: contract.PreparedAttachmentBinding = .{},
    reservation: ?client_slot_mod.AttachmentBindingReservation = null,
    lease: connection_lease.ConnectionLease = .{},
    response: executed_response_mod.ExecutedResponse = .{},
    payload: ?remote_attachment.RemoteAttachment = null,

    pub fn initInPlace(
        out: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) generation_transport_mod.Error!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine or out.payload != null)
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
        legacy_batch_transport: remote_attachment.AttachmentTransport,
    ) anyerror!void {
        if (!self.valid() or self.lifecycle != .executing or self.payload != null)
            return error.InvalidState;
        try adapter.commitAttachmentBinding(
            &self.binding,
            self.reservation.?,
            accepted,
            state.stream_id,
            &self.lease,
        );
        self.payload = remote_attachment.RemoteAttachment.init(allocator, state);
        self.payload.?.bindTransport(legacy_batch_transport) catch unreachable;
        self.lifecycle = .attached;
    }

    pub fn tryDeinit(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) DeinitOutcome {
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
                const payload = &(self.payload orelse return .corrupt);
                adapter.beginAttachmentDrop(
                    &self.binding,
                    self.reservation orelse return .corrupt,
                    &self.lease,
                ) catch return .corrupt;
                self.lifecycle = .cleaning;
                // The legacy batch callbacks below still need their narrow cleanup transport, but
                // no callback may regain the live generation RPC authority while payload memory is
                // being released.
                self.terminalizeTransport();
                payload.deinitPayloadOnly();
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
        return self.payloadConst().allowsMutation();
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

    pub fn pumpScreen(
        self: *GenerationAttachment,
        io: std.Io,
    ) (@import("client.zig").ClientError || screen_assembler.ApplyError || remote_attachment.LeaseError)!remote_attachment.PumpScreenResult {
        return self.payloadMut().pumpScreen(io);
    }

    pub fn applyValidatedRevoked(self: *GenerationAttachment, generation: u64) anyerror!void {
        return self.payloadMut().applyValidatedRevoked(generation);
    }

    fn valid(self: *const GenerationAttachment) bool {
        return self.self_addr == @intFromPtr(self) and self.lifecycle != .pristine;
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
    try adapter.commitAttachmentBinding(
        &attachment.binding,
        attachment.reservation.?,
        accepted,
        0xEE,
        &attachment.lease,
    );
    attachment.payload = remote_attachment.RemoteAttachment.init(reentrant.allocator(), .{
        .runtime_id = 0xDD,
        .stream_id = 0xEE,
        .role = .controller,
        .controller_generation = 1,
    });
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
    attachment.lifecycle = .attached;
    try attachment.response.initWithoutPayloadInPlace(
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0xEF,
        .{ .typed_reject = accepted },
    );
    const response_owner = try adapter.responseOwnerSeal(attachment.reservation.?);
    try std.testing.expectEqual(executed_response_mod.DeinitOutcome.cleaned, attachment.response.deinit(response_owner));
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

test "CR3a-2a typed reject settles binding response and transport exactly once" {
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
