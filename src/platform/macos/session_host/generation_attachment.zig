//! GUI-only final-address attachment owner for CR3a-2a.
//!
//! The movable RemoteAttachment remains the screen/batch payload used by external attach. This
//! wrapper is only embedded in RemoteRuntime and owns the generation transport, prepared binding,
//! pre-reserved connection lease and the single teardown path around that payload.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const client_slot_mod = @import("client_slot.zig");
const connection_lease = @import("connection_lease.zig");
const contract = @import("generation_attachment_contract.zig");
const executed_response_mod = @import("executed_response.zig");
const generation_transport_mod = @import("generation_transport.zig");
const generation_event = @import("generation_event_contract.zig");
const generation_batch_adapter_mod = @import("generation_batch_adapter.zig");
const generation_batch_registry = @import("generation_batch_registry.zig");
const framing = @import("framing.zig");
const initial_snapshot_owner_mod = @import("initial_snapshot_owner.zig");
const host_adapter_mod = @import("host_adapter.zig");
const process_seal = @import("process_seal_service.zig");
const remote_attachment = @import("remote_attachment.zig");
const screen_assembler = @import("maru").session.screen_assembler;
const screen_stream = @import("maru").session.screen_stream;
const settlement = @import("pending_event_settlement_contract.zig");
const runtime_lifetime = @import("runtime_lifetime_owner.zig");
const pending_event_owner_mod = @import("pending_event_owner.zig");
const pending_event_preparation = @import("pending_event_preparation.zig");
const runtime_pending_control = @import("runtime_pending_control.zig");
const catchup_barrier_contract = @import("catchup_barrier_contract.zig");
const catchup_stage_contract = @import("catchup_stage_contract.zig");
const client_deadline = @import("client_deadline.zig");
const control_response_wire = @import("control_response_wire.zig");
const SettlementDeathCheckpoint = struct { attachment_addr: usize, marker_fd: std.c.fd_t, stage_raw: u8 };
threadlocal var settlement_death_checkpoint: if (builtin.is_test) ?SettlementDeathCheckpoint else void =
    if (builtin.is_test) null else {};

fn writeDeathMarker(fd: std.c.fd_t, byte: u8) void {
    const marker: [1]u8 = .{byte};
    while (true) {
        const written = std.c.write(fd, &marker, marker.len);
        if (written == 1) return;
        if (written < 0 and std.posix.errno(written) == .INTR) continue;
        std.c._exit(126);
    }
}

fn payloadExtentExcludesProtected(payload_addr: usize, payload_len: usize, protected: anytype) bool {
    if (payload_addr == 0 or payload_len == 0) return false;
    const payload_end = std.math.add(usize, payload_addr, payload_len) catch return false;
    if (payload_end == 0) return false;
    inline for (protected) |pointer| {
        const Pointer = @TypeOf(pointer);
        const start = @intFromPtr(pointer);
        const extent = @sizeOf(@typeInfo(Pointer).pointer.child);
        const end = std.math.add(usize, start, extent) catch return false;
        if (payload_addr < end and start < payload_end) return false;
    }
    return true;
}

pub const Lifecycle = enum(u8) {
    pristine,
    shell,
    binding_prepared,
    executing,
    attached,
    cleaning,
    terminal,
    retirement_prepared,
};

fn testAllocationProvenance(generation: u64) executed_response_mod.AllocationProvenance {
    return .{
        .guard_addr = 0x201,
        .node_addr = 0x202,
        .operation_incarnation = 0x203,
        .generation = generation,
    };
}

pub const DeinitOutcome = enum {
    cleaned,
    terminal_handoff,
    already_terminal,
    busy,
    corrupt,
};

fn catchupStageLifecycleRawValid(value: *const catchup_stage_contract.Lifecycle) bool {
    return switch (@as(*const u8, @ptrCast(value)).*) {
        @intFromEnum(catchup_stage_contract.Lifecycle.pristine),
        @intFromEnum(catchup_stage_contract.Lifecycle.staged),
        @intFromEnum(catchup_stage_contract.Lifecycle.consumed),
        @intFromEnum(catchup_stage_contract.Lifecycle.aborted),
        => true,
        else => false,
    };
}

pub const GenerationAttachment = struct {
    pub fn pendingEventReleaseCallbackActive(self: *const GenerationAttachment) bool {
        return self.transport.pendingEventReleaseCallbackActive();
    }
    pub fn capabilities(self: *const GenerationAttachment) !contract.GenerationCapabilities {
        return self.transport.capabilities();
    }
    self_addr: usize = 0,
    lifecycle: Lifecycle = .pristine,
    transport: generation_transport_mod.GenerationTransport = .{},
    batch_adapter: generation_batch_adapter_mod.GenerationBatchAdapter = .{},
    binding: contract.PreparedAttachmentBinding = .{},
    reservation: ?client_slot_mod.AttachmentBindingReservation = null,
    lease: connection_lease.ConnectionLease = .{},
    response: executed_response_mod.ExecutedResponse = .{},
    payload: ?remote_attachment.RemoteAttachment = null,
    event_owner: generation_transport_mod.EventOwner = .{},
    event_generation_mirror: u64 = 0,
    catchup_stage_owner: CatchupStageOwner = .{},
    retirement_transaction_addr: usize = 0,
    retirement_transaction_generation: u64 = 0,
    retirement_adapter_addr: usize = 0,

    const CatchupStageOwner = struct {
        const State = enum(u8) {
            idle,
            building,
            staged,
            controller_committing,
            controller_evidenced,
            controller_promoted,
        };

        state: State = .idle,
        next_generation: u64 = 1,
        active_generation: u64 = 0,
        controller_generation: u64 = 0,
        seal: u64 = 0,
        canonical: catchup_stage_contract.PreparedStage = .{},

        fn stateRawValid(self: *const CatchupStageOwner) bool {
            const raw = @as(*const u8, @ptrCast(&self.state)).*;
            return switch (raw) {
                @intFromEnum(State.idle),
                @intFromEnum(State.building),
                @intFromEnum(State.staged),
                @intFromEnum(State.controller_committing),
                @intFromEnum(State.controller_evidenced),
                @intFromEnum(State.controller_promoted),
                => true,
                else => false,
            };
        }

        fn pristine(self: *const CatchupStageOwner) bool {
            return self.stateRawValid() and self.state == .idle and
                self.next_generation == 1 and self.active_generation == 0 and
                self.controller_generation == 0 and
                self.seal == 0 and self.canonical.pristine();
        }

        fn resetActive(self: *CatchupStageOwner) void {
            self.state = .idle;
            self.active_generation = 0;
            self.controller_generation = 0;
            self.seal = 0;
            self.canonical = .{};
        }

        fn stageSeal(stage: *const catchup_stage_contract.PreparedStage) u64 {
            var seal: u64 = 0x4352344153544147;
            inline for (.{
                stage.self_addr,
                stage.attachment_addr,
                stage.client_slot_addr,
                stage.slot_incarnation,
                stage.node_incarnation,
                stage.connection_generation,
                stage.transport_incarnation,
                stage.pid,
                stage.process_nonce,
                stage.owner_thread_id,
                stage.stream_id,
                stage.owner_generation,
                stage.identity.subscription.value,
                stage.identity.runtime_id,
                stage.identity.connection.monotonic_id,
                stage.identity.connection.slot_generation,
                stage.identity.host_id,
                stage.identity.request_nonce,
                stage.snapshot.generation,
                stage.snapshot.sequence,
                stage.target.generation,
                stage.target.sequence,
                stage.accounting.batches,
                stage.accounting.encoded_bytes,
                stage.accounting.decoded_cells,
                stage.deadline_expires_at_ns,
                @intFromEnum(stage.lifecycle),
            }) |value| seal = std.hash.Wyhash.hash(seal, std.mem.asBytes(&value));
            return seal;
        }
    };

    pub fn initInPlace(
        out: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) generation_transport_mod.Error!void {
        if (!rawLifecycleValid(&out.lifecycle) or out.self_addr != 0 or
            out.lifecycle != .pristine or out.payload != null or
            !@import("generation_event_contract.zig").pristineExact(&out.event_owner) or
            out.event_generation_mirror != 0 or !out.catchup_stage_owner.pristine())
            return error.DestinationOccupied;
        _ = adapter;
        out.self_addr = @intFromPtr(out);
        out.lifecycle = .shell;
    }

    pub fn prepareControllerAttach(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        runtime_id: u128,
    ) anyerror!contract.PreparedCallReceipt {
        return self.prepareAttach(adapter, runtime_id, .controller);
    }

    /// Reconnect candidate는 기존 controller가 살아 있는 동안 화면을 catch-up해야 하므로
    /// final-address binding을 observer로만 준비한다. takeover 권위는 CR4b 전까지 열지 않는다.
    pub fn prepareObserverAttach(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        runtime_id: u128,
    ) anyerror!contract.PreparedCallReceipt {
        return self.prepareAttach(adapter, runtime_id, .observer);
    }

    fn prepareAttach(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        runtime_id: u128,
        role: contract.AttachmentRole,
    ) anyerror!contract.PreparedCallReceipt {
        if (!self.valid() or self.lifecycle != .shell) return error.InvalidState;
        const reservation = try adapter.reserveAttachmentBinding(
            &self.binding,
            &self.lease,
            runtime_id,
            role,
        );
        errdefer {
            self.lifecycle = .terminal;
            adapter.abortAttachmentBinding(&self.binding, reservation) catch
                @panic("generation attachment binding rollback failed");
        }
        try adapter.mintGenerationTransport(
            &self.transport,
            @intFromPtr(self),
            @sizeOf(GenerationAttachment),
            reservation,
        );
        errdefer self.terminalizeTransport();
        try adapter.reserveGenerationBatchAdapter(
            &self.batch_adapter,
            @intFromPtr(self),
            @sizeOf(GenerationAttachment),
        );
        errdefer self.batch_adapter.abortPrepared();
        try generation_transport_mod.reserveEventOwnerInPlace(
            &self.transport,
            &self.event_owner,
        );
        const receipt = try self.transport.prepareRequest(
            switch (role) {
                .controller => contract.RuntimeRequest.attachController(),
                .observer => contract.RuntimeRequest.attachObserver(),
            },
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
        return self.executePreparedAttachInternal(adapter, receipt, null);
    }

    pub fn executePreparedAttachUntil(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        receipt: contract.PreparedCallReceipt,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!contract.ExecuteResult {
        return self.executePreparedAttachInternal(adapter, receipt, deadline);
    }

    fn executePreparedAttachInternal(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        receipt: contract.PreparedCallReceipt,
        deadline: ?client_deadline.AbsoluteDeadline,
    ) anyerror!contract.ExecuteResult {
        if (!self.valid() or self.lifecycle != .binding_prepared)
            return error.InvalidState;
        self.binding.beginExecute(receipt) catch |err| {
            self.transport.abortPreparedRequest(receipt) catch {};
            self.batch_adapter.abortPrepared();
            self.terminalizeTransport();
            try adapter.abortAttachmentBinding(&self.binding, self.reservation.?);
            self.lifecycle = .terminal;
            return err;
        };
        self.lifecycle = .executing;
        const result = (if (deadline) |absolute|
            generation_transport_mod.executePreparedRequestUntil(&self.transport, receipt, &self.response, absolute)
        else
            self.transport.executePreparedRequest(receipt, &self.response)) catch |err| {
            self.transport.abortPreparedRequest(receipt) catch {};
            self.batch_adapter.abortPrepared();
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
                self.batch_adapter.abortPrepared();
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
                self.batch_adapter.abortPrepared();
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
        self.batch_adapter.abortPrepared();
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
        try self.batch_adapter.preflightPreparedStream(state.stream_id);
        try adapter.commitAttachmentBinding(
            &self.binding,
            self.reservation.?,
            accepted,
            state.stream_id,
            &self.lease,
        );
        self.batch_adapter.bindPreparedStreamNoFail(state.stream_id);
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

    pub fn readInitialSnapshotUntil(
        self: *GenerationAttachment,
        out: *initial_snapshot_owner_mod.InitialSnapshotOwner,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!void {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidState;
        return generation_transport_mod.readInitialSnapshotUntil(&self.transport, out, deadline);
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

    pub fn poison(
        self: *GenerationAttachment,
        reason: @import("client_poison.zig").ConnectionReason,
    ) generation_transport_mod.Error!void {
        if (!self.valid() or (self.lifecycle != .executing and self.lifecycle != .attached))
            return error.MovedOrCopied;
        return self.transport.poison(reason);
    }

    pub fn sendControlNonBlocking(
        self: *GenerationAttachment,
        control: contract.RuntimeControl,
    ) generation_transport_mod.ControlError!bool {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return self.transport.sendControlNonBlocking(control);
    }

    pub fn sendControl(
        self: *GenerationAttachment,
        control: contract.RuntimeControl,
    ) generation_transport_mod.ControlError!void {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return self.transport.sendControl(control);
    }

    pub fn callOrdered(
        self: *GenerationAttachment,
        method: []const u8,
        params_json: ?[]const u8,
    ) @import("client.zig").ClientError![]u8 {
        if (!self.valid() or self.lifecycle != .attached) return error.ProtocolError;
        return generation_transport_mod.callOwned(
            &self.transport,
            @intFromPtr(self),
            method,
            params_json,
        );
    }

    pub fn takeEvent(
        self: *GenerationAttachment,
    ) generation_transport_mod.EventError!generation_transport_mod.EventTakeOutcome {
        return self.takeEventInternal(null);
    }

    pub fn takeEventWithPoisonCapture(
        self: *GenerationAttachment,
        poison_capture: @import("client_slot.zig").RegisteredOperationPoisonCaptureRequest,
    ) generation_transport_mod.EventError!generation_transport_mod.EventTakeOutcome {
        return self.takeEventInternal(poison_capture);
    }

    fn takeEventInternal(
        self: *GenerationAttachment,
        poison_capture: ?@import("client_slot.zig").RegisteredOperationPoisonCaptureRequest,
    ) generation_transport_mod.EventError!generation_transport_mod.EventTakeOutcome {
        if (!self.valid() or self.lifecycle != .attached)
            return error.InvalidOwner;
        const readiness = generation_transport_mod.eventReadinessOwned(
            &self.transport,
            @intFromPtr(self),
            &self.event_owner,
            self.event_generation_mirror,
        );
        if (self.event_generation_mirror != 0) {
            return switch (readiness) {
                .busy => error.Busy,
                .ready, .invalid => error.Corrupt,
            };
        }
        if (readiness == .invalid) return error.Corrupt;
        const projected = if (poison_capture) |capture|
            try generation_transport_mod.takeEventProjectedWithPoisonCapture(
                &self.transport,
                &self.event_owner,
                capture,
            )
        else
            try generation_transport_mod.takeEventProjected(
                &self.transport,
                &self.event_owner,
            );
        if (projected.outcome == .taken) {
            if (projected.generation == 0) @panic("canonical event generation was empty");
            self.event_generation_mirror = projected.generation;
        } else if (projected.generation != 0) {
            @panic("idle event take carried a generation");
        }
        return projected.outcome;
    }

    pub fn viewEvent(
        self: *const GenerationAttachment,
    ) generation_transport_mod.EventViewError!generation_transport_mod.EventView {
        if (!self.valid() or self.lifecycle != .attached or
            !@import("generation_event_contract.zig").liveGenerationMatches(
                &self.event_owner,
                self.event_generation_mirror,
            ))
            return error.InvalidOwner;
        return self.event_owner.view();
    }

    pub fn releaseEvent(self: *GenerationAttachment) generation_transport_mod.EventError!void {
        if (!self.valid() or self.lifecycle != .attached)
            return error.InvalidOwner;
        self.transport.releaseEvent(&self.event_owner) catch |err| switch (err) {
            error.Corrupt => {
                self.event_generation_mirror = 0;
                return err;
            },
            error.Busy, error.InvalidOwner, error.Terminal => return err,
        };
        self.event_generation_mirror = 0;
    }

    /// Settles only a registry-proven live inline event. A pristine owner is a no-op; an unrelated
    /// stream-operation blocker remains Busy, so callers never guess by issuing an empty release.
    pub fn releasePendingEvent(self: *GenerationAttachment) generation_transport_mod.EventError!bool {
        if (!self.valid() or self.lifecycle != .attached)
            return error.InvalidOwner;
        const readiness = generation_transport_mod.eventReadinessOwned(
            &self.transport,
            @intFromPtr(self),
            &self.event_owner,
            self.event_generation_mirror,
        );
        if (self.event_generation_mirror == 0) return switch (readiness) {
            .ready => false,
            .busy => error.Busy,
            .invalid => error.Corrupt,
        };
        if (readiness != .busy) return error.Corrupt;
        try self.releaseEvent();
        return true;
    }

    pub const PreparedSettlement = struct {
        correlation: generation_transport_mod.EventCorrelation,
        event_generation: u64,
    };

    pub const PendingSettlementPreparationContext = struct {
        allocator: std.mem.Allocator,
        lifetime_owner: *runtime_lifetime.RuntimeLifetimeOwner,
        pending_owner: *pending_event_owner_mod.PendingEventOwner,
        runtime_addr: usize,
        runtime_extent: usize,
        observation: *maru.app.RuntimeObservation,
        direct_input: *std.ArrayListUnmanaged(u8),
        direct_input_offset: *usize,
        pending_controls: *std.ArrayListUnmanaged(runtime_pending_control.RawQueuedRuntimeControl),
        blocking_flush_active: *bool,
        resize_generation: *u64,
        resize_baseline_present: *bool,
    };

    /// canonical take owner를 attachment 안에서만 빌려 immutable Pending owner publication까지 끝낸다.
    /// EventOwner pointer나 preparation view는 caller로 반환하지 않아 제품 pump가 source authority를 복제할 수 없다.
    pub fn preparePendingSettlement(
        self: *GenerationAttachment,
        input: PendingSettlementPreparationContext,
    ) pending_event_preparation.PrepareError!PreparedSettlement {
        if (!self.valid() or self.lifecycle != .attached or self.event_generation_mirror == 0)
            return error.InvalidOwner;
        const view = generation_transport_mod.preparationEventViewOwned(
            &self.transport,
            &self.event_owner,
        ) catch return error.InvalidOwner;
        const context: pending_event_preparation.RuntimePreparationContext = .{
            .runtime_addr = input.runtime_addr,
            .allocator = input.allocator,
            .lifetime_owner = input.lifetime_owner,
            .pending_owner = input.pending_owner,
            .observation = input.observation,
            .direct_input = input.direct_input,
            .direct_input_offset = input.direct_input_offset,
            .pending_controls = input.pending_controls,
            .blocking_flush_active = input.blocking_flush_active,
            .resize_generation = input.resize_generation,
            .resize_baseline_present = input.resize_baseline_present,
            .source_owner = &self.event_owner,
            .source_view = view,
            .correlation = self.transport.event_correlation,
        };
        const operation_preflight = input.lifetime_owner.preflightPreparation() catch |err| return switch (err) {
            error.Busy => error.Busy,
            error.InvalidOwner => error.InvalidOwner,
        };
        const source_identity = pending_event_preparation.sourceIdentityFromView(view) catch
            return error.InvalidOwner;
        const source_receipt = pending_event_preparation.preflightSource(
            context,
            view,
            operation_preflight,
        ) catch return error.InvalidOwner;
        const snapshot = pending_event_preparation.snapshotRuntimeContext(
            context,
            operation_preflight.owner_incarnation,
            std.mem.zeroes(@FieldType(pending_event_preparation.RuntimeSemanticSnapshot, "operation_identity")),
            source_identity,
        ) catch return error.InvalidOwner;
        const recipe = pending_event_preparation.recipeFromSourceView(view) catch
            return error.InvalidOwner;
        var frame: pending_event_preparation.PreparationFrame = undefined;
        pending_event_preparation.initFrameInPlace(&frame, .{
            .context = context,
            .operation_preflight = operation_preflight,
            .source_receipt = source_receipt,
            .snapshot = snapshot,
            .recipe = recipe,
        }, input.runtime_extent);
        try pending_event_preparation.prepare(&frame);
        return .{
            .correlation = self.transport.event_correlation,
            .event_generation = view.trusted.event_generation,
        };
    }

    /// Busy 재시도는 preparation을 다시 실행하지 않고 live source의 같은 identity만 재사용한다.
    pub fn preparedSettlementIdentity(
        self: *GenerationAttachment,
    ) pending_event_preparation.PrepareError!PreparedSettlement {
        if (!self.valid() or self.lifecycle != .attached or self.event_generation_mirror == 0)
            return error.InvalidOwner;
        const view = generation_transport_mod.preparationEventViewOwned(
            &self.transport,
            &self.event_owner,
        ) catch return error.InvalidOwner;
        return .{
            .correlation = self.transport.event_correlation,
            .event_generation = view.trusted.event_generation,
        };
    }

    pub fn purgeEndedStream(
        self: *GenerationAttachment,
    ) generation_transport_mod.PurgeEndedError!generation_transport_mod.PurgeEndedOutcome {
        if (!self.valid() or self.lifecycle != .attached)
            return error.InvalidOwner;
        return self.transport.purgeEndedStream();
    }

    pub fn tryDeinit(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) DeinitOutcome {
        if (!rawLifecycleValid(&self.lifecycle) or
            !self.catchup_stage_owner.stateRawValid()) return .corrupt;
        if (self.catchup_stage_owner.state != .idle) return .busy;
        if (self.lifecycle == .terminal) return .corrupt;
        if (!self.valid()) return .corrupt;
        switch (self.lifecycle) {
            .shell => {
                // `.shell`은 두 자리를 함께 가리킨다. `initInPlace`만 끝나 아무 권위도 안 잡은 자리와,
                // transport까지 mint된 자리다. 앞쪽에는 terminalize할 대상이 없으므로 lifecycle만 닫는다.
                //
                // 이 구분이 없으면 `RemoteRuntime.spawnWithConnection`의 롤백이 성공할 수 없다. 그 경로는
                // generation owner를 세운 직후 `runtime.spawn_full`을 보내는데, 그 RPC가 실패하면 attachment는
                // 아직 attach를 준비조차 하지 않은 `.shell`이다. 그 자리를 `.corrupt`로 읽으면 `deinit`이
                // `@panic`하고, **회복 가능한 spawn 실패가 앱 전체의 abort로 승격된다**.
                if (self.reservation == null and
                    generation_transport_mod.neverMinted(&self.transport))
                {
                    // 잡은 것이 없으니 되돌릴 것도 없다.
                } else switch (generation_transport_mod.preflightTerminalizeOwned(
                    &self.transport,
                    @intFromPtr(self),
                )) {
                    .ready => self.terminalizeTransport(),
                    .busy => return .busy,
                    .invalid => return .corrupt,
                }
            },
            .binding_prepared, .retirement_prepared => return .busy,
            .executing => return .busy,
            .cleaning => return .busy,
            .attached => {
                if (!self.response.lifecycleRawValid()) return .corrupt;
                if (self.response.lifecycle != .terminal) return .busy;
                switch (generation_transport_mod.eventReadinessOwned(
                    &self.transport,
                    @intFromPtr(self),
                    &self.event_owner,
                    self.event_generation_mirror,
                )) {
                    .ready => {},
                    .busy => return .busy,
                    .invalid => return .corrupt,
                }
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
                switch (payload.deinitPayloadOnly()) {
                    .cleaned => {},
                    .terminal_handoff => {
                        const view = payload.terminalCleanupView() catch return .corrupt;
                        var handoff: generation_batch_registry.TerminalCleanupHandoff = .{};
                        self.batch_adapter.preflightTerminalCleanup(view, &handoff) catch
                            return .corrupt;
                        self.batch_adapter.commitTerminalCleanupNoFail(view, &handoff);
                        payload.consumeTerminalCleanupSourcesNoFail(view.token_count);
                        if (payload.deinitPayloadOnly() != .cleaned)
                            @panic("published terminal cleanup source was not tombstoned");
                        self.payload = null;
                        adapter.finishActiveAttachmentDrop(
                            &self.binding,
                            self.reservation.?,
                            &self.lease,
                        );
                        self.batch_adapter.poisonTerminalCleanupNoFail();
                        self.batch_adapter.finishDraining();
                        self.lifecycle = .terminal;
                        return .terminal_handoff;
                    },
                    .corrupt => return .corrupt,
                }
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

    /// Freezes one attachment for the CR5 host-wide destructive prefix. Every fallible readiness
    /// check runs before the lifecycle changes; once prepared, ordinary attachment operations are
    /// rejected by their existing `.attached` guards until abort or no-fail commit.
    pub fn prepareHostRetirement(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) error{ Busy, InvalidOwner }!void {
        if (transaction_addr == 0 or transaction_generation == 0 or
            self.retirement_transaction_addr != 0 or self.retirement_transaction_generation != 0 or
            self.retirement_adapter_addr != 0) return error.InvalidOwner;
        if (!rawLifecycleValid(&self.lifecycle) or !self.catchup_stage_owner.stateRawValid() or
            !self.valid()) return error.InvalidOwner;
        if (self.lifecycle != .attached or self.catchup_stage_owner.state != .idle)
            return error.Busy;
        if (!self.response.lifecycleRawValid()) return error.InvalidOwner;
        if (self.response.lifecycle != .terminal) return error.Busy;
        switch (generation_transport_mod.eventReadinessOwned(
            &self.transport,
            @intFromPtr(self),
            &self.event_owner,
            self.event_generation_mirror,
        )) {
            .ready => {},
            .busy => return error.Busy,
            .invalid => return error.InvalidOwner,
        }
        switch (generation_transport_mod.preflightTerminalizeOwned(
            &self.transport,
            @intFromPtr(self),
        )) {
            .ready => {},
            .busy => return error.Busy,
            .invalid => return error.InvalidOwner,
        }
        const payload = &(self.payload orelse return error.InvalidOwner);
        switch (payload.preflightPayloadOnlyDeinit()) {
            .ready => {},
            .busy => return error.Busy,
            .corrupt => return error.InvalidOwner,
        }
        self.batch_adapter.preflightDraining() catch return error.InvalidOwner;
        adapter.preflightAttachmentDrop(
            &self.binding,
            self.reservation orelse return error.InvalidOwner,
            &self.lease,
        ) catch |err| return switch (err) {
            error.AdminBusy => error.Busy,
            else => error.InvalidOwner,
        };
        self.retirement_transaction_addr = transaction_addr;
        self.retirement_transaction_generation = transaction_generation;
        self.retirement_adapter_addr = @intFromPtr(adapter);
        self.lifecycle = .retirement_prepared;
    }

    pub fn hostRetirementPreparedExact(
        self: *const GenerationAttachment,
        adapter: *const host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) bool {
        return rawLifecycleValid(&self.lifecycle) and self.valid() and
            self.lifecycle == .retirement_prepared and self.catchup_stage_owner.stateRawValid() and
            self.catchup_stage_owner.state == .idle and
            self.retirement_transaction_addr == transaction_addr and
            self.retirement_transaction_generation == transaction_generation and
            self.retirement_adapter_addr == @intFromPtr(adapter);
    }

    pub fn abortHostRetirement(
        self: *GenerationAttachment,
        adapter: *const host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) error{InvalidOwner}!void {
        if (!self.hostRetirementPreparedExact(
            adapter,
            transaction_addr,
            transaction_generation,
        )) return error.InvalidOwner;
        self.retirement_transaction_addr = 0;
        self.retirement_transaction_generation = 0;
        self.retirement_adapter_addr = 0;
        self.lifecycle = .attached;
    }

    pub fn commitHostRetirementNoFail(
        self: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        transaction_addr: usize,
        transaction_generation: u64,
    ) void {
        if (!self.hostRetirementPreparedExact(
            adapter,
            transaction_addr,
            transaction_generation,
        )) process_seal.fatalIntegrity(.proof_loss);
        const payload = &(self.payload orelse process_seal.fatalIntegrity(.proof_loss));
        adapter.beginAttachmentDrop(
            &self.binding,
            self.reservation orelse process_seal.fatalIntegrity(.proof_loss),
            &self.lease,
        ) catch process_seal.fatalIntegrity(.proof_loss);
        self.lifecycle = .cleaning;
        self.retirement_transaction_addr = 0;
        self.retirement_transaction_generation = 0;
        self.retirement_adapter_addr = 0;
        self.batch_adapter.commitDraining();
        self.terminalizeTransport();
        switch (payload.deinitPayloadOnly()) {
            .cleaned => {},
            .terminal_handoff => {
                const view = payload.terminalCleanupView() catch
                    process_seal.fatalIntegrity(.proof_loss);
                var handoff: generation_batch_registry.TerminalCleanupHandoff = .{};
                self.batch_adapter.preflightTerminalCleanup(view, &handoff) catch
                    process_seal.fatalIntegrity(.proof_loss);
                self.batch_adapter.commitTerminalCleanupNoFail(view, &handoff);
                payload.consumeTerminalCleanupSourcesNoFail(view.token_count);
                if (payload.deinitPayloadOnly() != .cleaned)
                    process_seal.fatalIntegrity(.proof_loss);
                self.payload = null;
                adapter.finishActiveAttachmentDrop(
                    &self.binding,
                    self.reservation.?,
                    &self.lease,
                );
                self.batch_adapter.poisonTerminalCleanupNoFail();
                self.batch_adapter.finishDraining();
                self.lifecycle = .terminal;
                return;
            },
            .corrupt => process_seal.fatalIntegrity(.proof_loss),
        }
        self.batch_adapter.finishDraining();
        self.payload = null;
        adapter.finishActiveAttachmentDrop(
            &self.binding,
            self.reservation.?,
            &self.lease,
        );
        self.lifecycle = .terminal;
    }

    pub fn hostRetirementCommittedExact(
        self: *const GenerationAttachment,
        adapter: *const host_adapter_mod.HostAdapter,
    ) bool {
        return rawLifecycleValid(&self.lifecycle) and self.valid() and self.lifecycle == .terminal and
            self.payload == null and self.retirement_transaction_addr == 0 and
            self.retirement_transaction_generation == 0 and self.retirement_adapter_addr == 0 and
            self.binding.lifecycle == .terminal and self.reservation != null and
            adapter.hostId() != 0 and adapter.connectionGeneration() != 0;
    }

    pub fn deinit(self: *GenerationAttachment, adapter: *host_adapter_mod.HostAdapter) void {
        const outcome = self.tryDeinit(adapter);
        if (outcome != .cleaned and outcome != .terminal_handoff)
            @panic("generation attachment teardown invariant violated");
    }

    pub fn streamId(self: *const GenerationAttachment) u64 {
        return self.payloadConst().streamId();
    }

    pub fn preflightPendingSettlementTransport(
        self: *GenerationAttachment,
        correlation: generation_transport_mod.EventCorrelation,
        projection: settlement.PendingEffectProjection,
        lifetime_owner: *const runtime_lifetime.RuntimeLifetimeOwner,
        lease: *const runtime_lifetime.RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
        effect_out: *settlement.EffectCommitEvidence,
        release_out: *settlement.EventReleaseCompletion,
        effect_permit: *settlement.PreparedEffectPermit,
        release_permit: *settlement.PreparedEventReleasePermit,
        pending_permit: *settlement.PreparedPendingSettlementPermit,
        begun: *generation_transport_mod.PendingEventReleaseBegun,
        pending_owner: anytype,
    ) error{ Busy, InvalidOwner }!void {
        if (!self.valid() or self.lifecycle != .attached or
            !lifetime_owner.validatePreparedSettlementBinding(lease, binding) or
            projection.pending_owner_addr == 0 or projection.owner_incarnation == 0 or
            projection.attempt == 0 or projection.event_generation == 0 or
            projection.release.pending_owner_addr != projection.pending_owner_addr or
            projection.release.pending_owner_incarnation != projection.owner_incarnation or
            projection.release.attempt != projection.attempt)
            return error.InvalidOwner;
        const correlation_digest = self.transport.settlementCorrelationDigest(&correlation) catch
            return error.InvalidOwner;
        self.transport.preflightPendingEffect(.{
            .pending_owner_addr = projection.pending_owner_addr,
            .owner_incarnation = projection.owner_incarnation,
            .attempt = projection.attempt,
            .event_generation = projection.event_generation,
            .correlation_digest = correlation_digest,
            .prepared_effect_digest = projection.prepared_effect_digest,
            .effect_request = projection.effect_request,
            .target_stream_id = self.streamId(),
            .effect_out_addr = @intFromPtr(effect_out),
            .effect_out_extent = @sizeOf(settlement.EffectCommitEvidence),
            .effect_out_alignment = @alignOf(settlement.EffectCommitEvidence),
            .effect_out_pristine_digest = settlement.pristineEffectCommitEvidenceDigest(),
            .lease = binding,
        }, effect_out, effect_permit) catch |err| return err;
        errdefer self.transport.abortPendingEffectPreAdmissionNoFail(effect_permit);
        const event_projection = generation_event.releaseProjection(&self.event_owner) catch
            return error.InvalidOwner;
        if (@intFromPtr(pending_owner) != projection.pending_owner_addr or
            !payloadExtentExcludesProtected(event_projection.payload_addr, event_projection.payload_len, .{
                lease,          effect_out, release_out,    effect_permit, release_permit,
                pending_permit, begun,      lifetime_owner, pending_owner, self,
            })) return error.InvalidOwner;
        self.transport.preflightPendingEventReleaseUnderEffect(
            effect_permit,
            projection.release,
            event_projection,
            binding,
            release_out,
            release_permit,
            begun,
        ) catch return error.InvalidOwner;
    }

    pub fn abortPendingSettlementTransportPreAdmissionNoFail(
        self: *GenerationAttachment,
        effect_permit: *settlement.PreparedEffectPermit,
        release_permit: *settlement.PreparedEventReleasePermit,
    ) void {
        if (release_permit.lifecycle_raw == @intFromEnum(settlement.AuthorityLifecycle.prepared))
            release_permit.* = .{};
        self.transport.abortPendingEffectPreAdmissionNoFail(effect_permit);
    }

    pub fn commitPendingEffectNoFail(
        self: *GenerationAttachment,
        lifetime_owner: *const runtime_lifetime.RuntimeLifetimeOwner,
        lease: *const runtime_lifetime.RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
        permit: *settlement.PreparedEffectPermit,
        out: *settlement.EffectCommitEvidence,
    ) void {
        if (builtin.is_test) if (settlement_death_checkpoint) |checkpoint| {
            if (checkpoint.attachment_addr != @intFromPtr(self)) std.c._exit(126);
            writeDeathMarker(checkpoint.marker_fd, 0x42);
            if (checkpoint.stage_raw == 1) {
                permit.seal[0] ^= 1;
                writeDeathMarker(checkpoint.marker_fd, 0x47);
            }
        };
        if (!lifetime_owner.validateAdmittedSettlementBinding(lease, binding))
            process_seal.fatalIntegrity(.proof_loss);
        self.transport.commitPendingEffectNoFail(permit, binding, out);
    }

    pub fn commitPendingReleaseNoFail(
        self: *GenerationAttachment,
        lifetime_owner: *const runtime_lifetime.RuntimeLifetimeOwner,
        lease: *const runtime_lifetime.RuntimeSettlementLease,
        binding: settlement.RuntimeSettlementLeaseBinding,
        effect_permit: *settlement.PreparedEffectPermit,
        effect_out: *const settlement.EffectCommitEvidence,
        permit: *settlement.PreparedEventReleasePermit,
        begun: *generation_transport_mod.PendingEventReleaseBegun,
        out: *settlement.EventReleaseCompletion,
    ) void {
        if (!lifetime_owner.validateAdmittedSettlementBinding(lease, binding))
            process_seal.fatalIntegrity(.proof_loss);
        if (!self.transport.validatePendingEventReleaseFinal(
            &self.event_owner,
            effect_permit,
            effect_out,
            permit,
            binding,
            out,
        )) process_seal.fatalIntegrity(.proof_loss);
        self.transport.preparePendingEventReleaseBegunNoFail(effect_permit, permit, begun);
        const cleanup = self.transport.tombstonePendingEventOwnerNoFail(
            &self.event_owner,
            permit,
            begun,
        );
        self.transport.beginPendingEventReleaseResourcesNoFail(effect_permit, permit, begun);
        self.transport.tombstonePendingEventCorrelationNoFail(begun);
        self.event_generation_mirror = 0;
        self.transport.markPendingEventMirrorTombstonedNoFail(self.event_generation_mirror, begun);
        self.transport.finishPendingEventReleaseNoFail(
            effect_permit,
            permit,
            begun,
            out,
            cleanup,
        );
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

    pub const ControllerTransferOutcome = union(enum) {
        new_controller_evidenced: u64,
        authority_conflict,
        takeover_sent_unknown,
        pre_takeover_failed,
    };

    /// CR4b controller promotion은 caught-up observer의 same connection/stream에서만 수행한다.
    /// status와 generation-CAS takeover는 같은 absolute deadline을 공유하며 takeover call이
    /// 시작된 뒤의 불확실성은 재시도하지 않고 closed outcome으로 남긴다.
    pub fn executeControllerTakeoverUntil(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!ControllerTransferOutcome {
        if (deadline.expires_at_ns != stage.deadline_expires_at_ns or
            !self.catchupStageAuthorityMatches(stage))
            return error.InvalidAuthority;
        // Reserve the one-shot transfer before the first allocator or transport callback. A
        // callback that reenters this API must not issue a second status/takeover transaction.
        self.catchup_stage_owner.state = .controller_committing;
        defer {
            if (self.catchup_stage_owner.stateRawValid() and
                self.catchup_stage_owner.state == .controller_committing)
                self.catchup_stage_owner.state = .staged;
        }
        if (deadline.remainingNs() <= 0) {
            self.poison(.read_timeout) catch {};
            return .pre_takeover_failed;
        }
        const generation_capabilities = self.transport.capabilities() catch return error.InvalidAuthority;
        if (!generation_capabilities.controller_transfer or self.payloadConst().state.role != .observer) {
            self.poison(.local_invariant_violation) catch {};
            return .pre_takeover_failed;
        }
        const allocator = self.payloadConst().allocator;
        const stream_id = self.payloadConst().state.stream_id;
        const status_params = remote_attachment.statusParams(allocator, stream_id) catch {
            self.poison(.local_resource_exhausted) catch {};
            return .pre_takeover_failed;
        };
        defer allocator.free(status_params);
        const status_response = self.batch_adapter.callControllerUntil(
            "controller.status",
            status_params,
            deadline,
        ) catch |err| {
            self.poison(switch (err) {
                error.OutOfMemory => .local_resource_exhausted,
                error.DeadlineExceeded => .read_timeout,
                else => .transport_read_failure,
            }) catch {};
            return .pre_takeover_failed;
        };
        defer allocator.free(status_response);
        const status_wire_error = remote_attachment.decodeWireError(allocator, status_response) catch |err| {
            self.poison(if (err == error.OutOfMemory)
                .local_resource_exhausted
            else
                .peer_contract_violation) catch {};
            return .pre_takeover_failed;
        };
        if (status_wire_error) |wire_error| return switch (wire_error) {
            .invalid_generation, .unauthorized, .runtime_not_found => blk: {
                if (self.hasBufferedControllerRevoke()) {
                    self.poison(.response_correlation_lost) catch {};
                    break :blk .pre_takeover_failed;
                }
                break :blk .authority_conflict;
            },
            .resource_exhausted, .invalid_request, .internal => blk: {
                self.poison(.local_invariant_violation) catch {};
                break :blk .pre_takeover_failed;
            },
            else => unreachable,
        };
        var scratch = self.payloadConst().state;
        const status = remote_attachment.decodeStatusForTransfer(
            allocator,
            status_response,
            &scratch,
        ) catch |err| {
            self.poison(if (err == error.OutOfMemory)
                .local_resource_exhausted
            else
                .peer_contract_violation) catch {};
            return .pre_takeover_failed;
        };
        if (self.hasBufferedControllerRevoke()) {
            self.poison(.response_correlation_lost) catch {};
            return .pre_takeover_failed;
        }
        if (status.controller) return .authority_conflict;
        if (deadline.remainingNs() <= 0) {
            self.poison(.read_timeout) catch {};
            return .pre_takeover_failed;
        }
        const takeover_params = remote_attachment.takeoverParams(
            allocator,
            scratch.stream_id,
            scratch.controller_generation,
        ) catch {
            self.poison(.local_resource_exhausted) catch {};
            return .pre_takeover_failed;
        };
        defer allocator.free(takeover_params);
        const expected_generation = scratch.controller_generation;
        const takeover_response = self.batch_adapter.callControllerUntil(
            "controller.takeover",
            takeover_params,
            deadline,
        ) catch {
            self.poison(.response_correlation_lost) catch {};
            return .takeover_sent_unknown;
        };
        defer allocator.free(takeover_response);
        const takeover_wire_error = remote_attachment.decodeWireError(allocator, takeover_response) catch |err| {
            self.poison(if (err == error.OutOfMemory)
                .local_resource_exhausted
            else
                .peer_contract_violation) catch {};
            return .takeover_sent_unknown;
        };
        // A correlated CAS rejection is already a complete authoritative response. A follow-up
        // nonblocking read would misclassify an idle, still-usable connection as an unknown send.
        if (takeover_wire_error) |wire_error| return switch (wire_error) {
            .invalid_generation, .unauthorized, .runtime_not_found => blk: {
                if (self.hasBufferedControllerRevoke()) {
                    self.poison(.response_correlation_lost) catch {};
                    break :blk .takeover_sent_unknown;
                }
                break :blk .authority_conflict;
            },
            .resource_exhausted, .invalid_request, .internal => blk: {
                self.poison(.local_invariant_violation) catch {};
                break :blk .pre_takeover_failed;
            },
            else => unreachable,
        };
        remote_attachment.decodeTakeover(
            allocator,
            takeover_response,
            &scratch,
            expected_generation,
        ) catch |err| {
            self.poison(if (err == error.OutOfMemory)
                .local_resource_exhausted
            else
                .peer_contract_violation) catch {};
            return .takeover_sent_unknown;
        };
        if (deadline.remainingNs() <= 0) {
            self.poison(.read_timeout) catch {};
            return .takeover_sent_unknown;
        }
        self.batch_adapter.refreshControllerEvidence() catch {
            self.poison(.response_correlation_lost) catch {};
            return .takeover_sent_unknown;
        };
        if (self.hasBufferedControllerRevoke()) {
            self.poison(.response_correlation_lost) catch {};
            return .takeover_sent_unknown;
        }
        if (deadline.remainingNs() <= 0) {
            self.poison(.read_timeout) catch {};
            return .takeover_sent_unknown;
        }
        // Wire authority is evidenced now, but the unpublished candidate stays locally quarantined
        // as observer until CR4c can promote cleanup binding, attachment role and RemoteGeneration
        // publication in one suffix. Keeping the live role observer also keeps mutation authority 0.
        self.catchup_stage_owner.controller_generation = scratch.controller_generation;
        self.catchup_stage_owner.canonical.lifecycle = .consumed;
        self.catchup_stage_owner.seal = CatchupStageOwner.stageSeal(
            &self.catchup_stage_owner.canonical,
        );
        self.catchup_stage_owner.state = .controller_evidenced;
        return .{ .new_controller_evidenced = scratch.controller_generation };
    }

    pub fn validateControllerEvidence(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) bool {
        if (!self.catchup_stage_owner.stateRawValid() or
            !self.valid() or self.lifecycle != .attached or
            self.catchup_stage_owner.state != .controller_evidenced or
            stage != &self.catchup_stage_owner.canonical or
            self.catchup_stage_owner.active_generation != stage.owner_generation or
            self.catchup_stage_owner.controller_generation != controller_generation or
            !catchupStageLifecycleRawValid(&stage.lifecycle) or
            stage.lifecycle != .consumed or
            self.catchup_stage_owner.seal != CatchupStageOwner.stageSeal(stage) or
            stage.self_addr != @intFromPtr(stage) or stage.attachment_addr != @intFromPtr(self) or
            controller_generation == 0)
            return false;
        const projection = generation_transport_mod.catchupProjection(&self.transport) catch return false;
        if (stage.client_slot_addr != projection.slot_addr or
            stage.slot_incarnation != projection.slot_incarnation or
            stage.node_incarnation != projection.node_incarnation or
            stage.connection_generation != projection.connection_generation or
            stage.transport_incarnation != projection.transport_incarnation or
            stage.pid != projection.pid or stage.process_nonce != projection.process_nonce or
            stage.owner_thread_id != projection.owner_thread_id or
            stage.stream_id != projection.bound_stream_id or
            stage.identity.host_id != projection.host_id or
            stage.identity.runtime_id != projection.runtime_id or projection.role != .observer)
            return false;
        const state = self.payloadConst().state;
        const screen = self.screenPtr() orelse return false;
        return state.role == .observer and
            state.controller_generation < controller_generation and
            std.meta.eql(screen.catchupFrontier(), stage.target);
    }

    pub fn releaseControllerEvidence(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) catchup_stage_contract.Error!void {
        if (!self.validateControllerEvidence(stage, controller_generation))
            return error.InvalidAuthority;
        self.catchup_stage_owner.resetActive();
    }

    pub fn promoteControllerEvidence(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) catchup_stage_contract.Error!void {
        if (!self.validateControllerEvidence(stage, controller_generation))
            return error.InvalidAuthority;
        var reservation = self.reservation orelse return error.InvalidAuthority;
        _ = generation_transport_mod.preflightControllerPromotionOwned(
            &self.transport,
            @intFromPtr(self),
            &self.binding,
            reservation,
        ) catch return error.InvalidAuthority;

        generation_transport_mod.promoteControllerNoFailOwned(
            &self.transport,
            @intFromPtr(self),
            &self.binding,
            &reservation,
        );
        self.reservation = reservation;
        self.payloadMut().state.role = .controller;
        self.payloadMut().state.controller_generation = controller_generation;
        self.catchup_stage_owner.state = .controller_promoted;
    }

    pub fn validatePromotedController(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) bool {
        if (!self.catchup_stage_owner.stateRawValid() or
            !self.valid() or self.lifecycle != .attached or
            self.catchup_stage_owner.state != .controller_promoted or
            stage != &self.catchup_stage_owner.canonical or
            self.catchup_stage_owner.active_generation != stage.owner_generation or
            self.catchup_stage_owner.controller_generation != controller_generation or
            !catchupStageLifecycleRawValid(&stage.lifecycle) or
            stage.lifecycle != .consumed or
            self.catchup_stage_owner.seal != CatchupStageOwner.stageSeal(stage) or
            stage.self_addr != @intFromPtr(stage) or stage.attachment_addr != @intFromPtr(self) or
            controller_generation == 0)
            return false;
        const projection = generation_transport_mod.catchupProjection(&self.transport) catch return false;
        if (stage.client_slot_addr != projection.slot_addr or
            stage.slot_incarnation != projection.slot_incarnation or
            stage.node_incarnation != projection.node_incarnation or
            stage.connection_generation != projection.connection_generation or
            stage.transport_incarnation != projection.transport_incarnation or
            stage.pid != projection.pid or stage.process_nonce != projection.process_nonce or
            stage.owner_thread_id != projection.owner_thread_id or
            stage.stream_id != projection.bound_stream_id or
            stage.identity.host_id != projection.host_id or
            stage.identity.runtime_id != projection.runtime_id or projection.role != .controller)
            return false;
        const state = self.payloadConst().state;
        const screen = self.screenPtr() orelse return false;
        return state.role == .controller and
            state.controller_generation == controller_generation and
            self.allowsMutation() and
            std.meta.eql(screen.catchupFrontier(), stage.target);
    }

    pub fn releasePromotedController(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) catchup_stage_contract.Error!void {
        try self.preflightReleasePromotedController(stage, controller_generation);
        self.releasePromotedControllerNoFail(stage, controller_generation);
    }

    pub fn preflightReleasePromotedController(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) catchup_stage_contract.Error!void {
        if (!self.validatePromotedController(stage, controller_generation))
            return error.InvalidAuthority;
    }

    pub fn releasePromotedControllerNoFail(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) void {
        self.preflightReleasePromotedController(stage, controller_generation) catch
            @panic("CR4c promoted controller evidence drifted after preflight");
        self.catchup_stage_owner.resetActive();
    }

    pub fn releasePromotedControllerAfterTerminalTransport(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
    ) catchup_stage_contract.Error!void {
        if (!self.catchup_stage_owner.stateRawValid() or !self.valid() or
            self.lifecycle != .attached or
            self.catchup_stage_owner.state != .controller_promoted or
            stage != &self.catchup_stage_owner.canonical or
            self.catchup_stage_owner.active_generation != stage.owner_generation or
            self.catchup_stage_owner.controller_generation != controller_generation or
            !catchupStageLifecycleRawValid(&stage.lifecycle) or stage.lifecycle != .consumed or
            self.catchup_stage_owner.seal != CatchupStageOwner.stageSeal(stage) or
            stage.self_addr != @intFromPtr(stage) or stage.attachment_addr != @intFromPtr(self) or
            self.batch_adapter.terminalConnectionReason() == null)
            return error.InvalidAuthority;
        self.catchup_stage_owner.resetActive();
    }

    pub const ForcedResizeResult = struct {
        resize_generation: u64,
        changed: bool,
    };

    /// CR4c candidate-only resize. The candidate is still unpublished, so this leaf uses the
    /// promoted attachment's bound controller stream directly and shares the host job deadline.
    pub fn forcePromotedControllerResizeUntil(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        controller_generation: u64,
        cols: u16,
        rows: u16,
        client_sequence: u64,
        deadline: client_deadline.AbsoluteDeadline,
    ) anyerror!ForcedResizeResult {
        if (deadline.expires_at_ns != stage.deadline_expires_at_ns or
            !self.validatePromotedController(stage, controller_generation) or
            cols < 2 or rows == 0 or client_sequence == 0)
            return error.InvalidAuthority;
        if (deadline.remainingNs() <= 0) {
            self.poison(.read_timeout) catch {};
            return error.DeadlineExceeded;
        }
        var buffer: [96]u8 = undefined;
        const encoded = control_response_wire.encodeParams(&buffer, .{ .resize = .{
            .stream_id = stage.stream_id,
            .cols = cols,
            .rows = rows,
            .client_sequence = client_sequence,
        } }) catch |err| {
            self.poison(if (err == error.BufferTooSmall)
                .local_resource_exhausted
            else
                .local_invariant_violation) catch {};
            return err;
        };
        const allocator = self.payloadConst().allocator;
        const response = self.batch_adapter.callControllerUntil(
            encoded.method,
            encoded.params,
            deadline,
        ) catch |err| {
            self.poison(switch (err) {
                error.OutOfMemory => .local_resource_exhausted,
                error.DeadlineExceeded => .read_timeout,
                else => .transport_read_failure,
            }) catch {};
            return err;
        };
        defer allocator.free(response);
        const reply = control_response_wire.decodeResizeResponse(
            allocator,
            response,
            .{ .resize = .{ .client_sequence = client_sequence } },
        ) catch |err| {
            self.poison(if (err == error.OutOfMemory)
                .local_resource_exhausted
            else
                .peer_contract_violation) catch {};
            return err;
        };
        return switch (reply) {
            .stale => blk: {
                self.poison(.peer_contract_violation) catch {};
                break :blk error.StaleResize;
            },
            .applied => |applied| blk: {
                if (applied.cols != cols or applied.rows != rows) {
                    self.poison(.peer_contract_violation) catch {};
                    break :blk error.InvalidResizeResponse;
                }
                if (!self.validatePromotedController(stage, controller_generation))
                    break :blk error.InvalidAuthority;
                break :blk .{
                    .resize_generation = applied.resize_generation,
                    .changed = applied.changed,
                };
            },
        };
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

    pub fn sendResyncNonBlocking(
        self: *GenerationAttachment,
    ) generation_transport_mod.InputError!bool {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return generation_transport_mod.sendResyncNonBlockingOwned(
            &self.transport,
            @intFromPtr(self),
        );
    }

    pub fn screenRecoveryState(
        self: *GenerationAttachment,
    ) generation_transport_mod.InputError!@import("client.zig").ScreenRecoveryState {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return generation_transport_mod.screenRecoveryStateOwned(
            &self.transport,
            @intFromPtr(self),
        );
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

    pub fn discardPendingScreen(
        self: *GenerationAttachment,
    ) remote_attachment.LeaseError!void {
        return self.payloadMut().discardPendingScreen();
    }

    /// Host barrier보다 앞선 exact same-stream batch만 적용하고 실제 assembler frontier가
    /// target과 같을 때 final-address staged receipt를 게시한다. barrier 이후 batch는 읽지 않는다.
    pub fn prepareCatchupStage(
        self: *GenerationAttachment,
        runtime_id: u128,
        request_nonce: u128,
        deadline: client_deadline.AbsoluteDeadline,
        io: std.Io,
    ) (@import("client.zig").DeadlineClientError ||
        screen_assembler.ApplyError ||
        remote_attachment.LeaseError ||
        catchup_stage_contract.Error)!*const catchup_stage_contract.PreparedStage {
        if (!self.catchup_stage_owner.stateRawValid() or
            !self.valid() or self.lifecycle != .attached)
            return error.InvalidAuthority;
        if (self.catchup_stage_owner.state != .idle) return error.Busy;
        const owner_generation = self.catchup_stage_owner.next_generation;
        if (owner_generation == 0 or owner_generation == std.math.maxInt(u64))
            return error.InvalidAuthority;
        self.catchup_stage_owner.state = .building;
        self.catchup_stage_owner.active_generation = owner_generation;
        var owner_reserved = true;
        defer if (owner_reserved) self.catchup_stage_owner.resetActive();
        const projection = generation_transport_mod.catchupProjection(&self.transport) catch
            return error.InvalidAuthority;
        if (runtime_id == 0 or request_nonce == 0 or projection.bound_stream_id == 0 or
            runtime_id != projection.runtime_id or projection.role != .observer)
            return error.InvalidAuthority;
        const screen = self.screenPtr() orelse return error.InvalidAuthority;
        const snapshot = screen.catchupFrontier();
        const expected = try self.batch_adapter.requestCatchupUntil(
            runtime_id,
            request_nonce,
            deadline,
        );
        if (expected.host_id != projection.host_id or expected.runtime_id != runtime_id or
            expected.request_nonce != request_nonce)
            return error.InvalidAuthority;
        const plan = try self.batch_adapter.readCatchupBarrierPlanUntil(expected, deadline);
        if (plan.preceding_screen_batches > catchup_stage_contract.max_batches) {
            self.poison(.event_queue_overflow) catch return error.InvalidAuthority;
            return error.BatchLimitExceeded;
        }

        var accounting: catchup_stage_contract.Accounting = .{};
        var remaining = plan.preceding_screen_batches;
        while (remaining != 0) : (remaining -= 1) {
            if (deadline.remainingNs() <= 0) {
                self.poison(.read_timeout) catch return error.InvalidAuthority;
                return error.DeadlineExceeded;
            }
            switch (try self.payloadMut().pumpCatchupScreen(io, &accounting)) {
                .applied, .recovery_commit_pending => {},
                .idle => {
                    self.poison(.local_invariant_violation) catch return error.InvalidAuthority;
                    return error.InvalidAuthority;
                },
                .terminal => return error.ConnectionClosed,
            }
        }
        if (deadline.remainingNs() <= 0) {
            self.poison(.read_timeout) catch return error.InvalidAuthority;
            return error.DeadlineExceeded;
        }
        const target = screen.catchupFrontier();
        if (!std.meta.eql(target, plan.barrier.target)) {
            self.poison(.peer_contract_violation) catch return error.InvalidAuthority;
            return error.InvalidAuthority;
        }
        const canonical = &self.catchup_stage_owner.canonical;
        canonical.* = .{
            .self_addr = @intFromPtr(canonical),
            .attachment_addr = @intFromPtr(self),
            .client_slot_addr = projection.slot_addr,
            .slot_incarnation = projection.slot_incarnation,
            .node_incarnation = projection.node_incarnation,
            .connection_generation = projection.connection_generation,
            .transport_incarnation = projection.transport_incarnation,
            .pid = projection.pid,
            .process_nonce = projection.process_nonce,
            .owner_thread_id = projection.owner_thread_id,
            .stream_id = projection.bound_stream_id,
            .owner_generation = owner_generation,
            .identity = expected,
            .snapshot = snapshot,
            .target = target,
            .accounting = accounting,
            .deadline_expires_at_ns = deadline.expires_at_ns,
            .lifecycle = .staged,
        };
        self.catchup_stage_owner.seal = CatchupStageOwner.stageSeal(canonical);
        self.catchup_stage_owner.state = .staged;
        self.catchup_stage_owner.next_generation = owner_generation + 1;
        owner_reserved = false;
        return canonical;
    }

    pub fn validateCatchupStage(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
        deadline: client_deadline.AbsoluteDeadline,
    ) bool {
        return deadline.expires_at_ns == stage.deadline_expires_at_ns and
            deadline.remainingNs() > 0 and self.validateCatchupStageAuthority(stage);
    }

    /// Cleanup owners must still be able to authenticate and abort an exact staged receipt after
    /// its product deadline expires. Expiry prevents consumption, not canonical owner teardown.
    pub fn catchupStageAuthorityMatches(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
    ) bool {
        return self.validateCatchupStageAuthority(stage);
    }

    fn validateCatchupStageAuthority(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
    ) bool {
        if (!self.catchup_stage_owner.stateRawValid() or
            !self.valid() or self.lifecycle != .attached or
            self.catchup_stage_owner.state != .staged or
            stage != &self.catchup_stage_owner.canonical or
            self.catchup_stage_owner.active_generation != stage.owner_generation or
            !catchupStageLifecycleRawValid(&stage.lifecycle) or
            self.catchup_stage_owner.seal != CatchupStageOwner.stageSeal(stage) or
            stage.lifecycle != .staged or stage.self_addr != @intFromPtr(stage) or
            stage.attachment_addr != @intFromPtr(self) or !stage.identity.valid() or
            stage.deadline_expires_at_ns <= 0)
            return false;
        const projection = generation_transport_mod.catchupProjection(&self.transport) catch return false;
        if (stage.client_slot_addr != projection.slot_addr or
            stage.slot_incarnation != projection.slot_incarnation or
            stage.node_incarnation != projection.node_incarnation or
            stage.connection_generation != projection.connection_generation or
            stage.transport_incarnation != projection.transport_incarnation or
            stage.pid != projection.pid or stage.process_nonce != projection.process_nonce or
            stage.owner_thread_id != projection.owner_thread_id or
            stage.stream_id != projection.bound_stream_id or
            stage.identity.host_id != projection.host_id or
            stage.identity.runtime_id != projection.runtime_id or projection.role != .observer or
            stage.accounting.batches > catchup_stage_contract.max_batches or
            stage.accounting.encoded_bytes > catchup_stage_contract.max_encoded_bytes or
            stage.accounting.decoded_cells > catchup_stage_contract.max_decoded_cells)
            return false;
        const screen = self.screenPtr() orelse return false;
        const zero_accounting = stage.accounting.batches == 0 and
            stage.accounting.encoded_bytes == 0 and stage.accounting.decoded_cells == 0;
        const active_accounting = stage.accounting.batches != 0 and
            stage.accounting.encoded_bytes != 0;
        if ((!zero_accounting and !active_accounting) or
            (zero_accounting != std.meta.eql(stage.snapshot, stage.target)))
            return false;
        return std.meta.eql(screen.catchupFrontier(), stage.target);
    }

    fn catchupStageStaticAuthorityMatches(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
    ) bool {
        return self.catchup_stage_owner.stateRawValid() and self.valid() and
            self.lifecycle == .attached and self.catchup_stage_owner.state == .staged and
            stage == &self.catchup_stage_owner.canonical and
            self.catchup_stage_owner.active_generation == stage.owner_generation and
            catchupStageLifecycleRawValid(&stage.lifecycle) and stage.lifecycle == .staged and
            self.catchup_stage_owner.seal == CatchupStageOwner.stageSeal(stage) and
            stage.self_addr == @intFromPtr(stage) and stage.attachment_addr == @intFromPtr(self) and
            stage.identity.valid() and stage.deadline_expires_at_ns > 0;
    }

    pub fn abortCatchupStage(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
    ) catchup_stage_contract.Error!void {
        if (!self.validateCatchupStageAuthority(stage)) return error.InvalidAuthority;
        self.catchup_stage_owner.state = .idle;
        self.catchup_stage_owner.active_generation = 0;
        self.catchup_stage_owner.seal = 0;
        self.catchup_stage_owner.canonical.lifecycle = .aborted;
    }

    pub fn abortCatchupStageAfterTerminalTransport(
        self: *GenerationAttachment,
        stage: *const catchup_stage_contract.PreparedStage,
    ) catchup_stage_contract.Error!void {
        if (!self.catchupStageStaticAuthorityMatches(stage) or
            self.batch_adapter.terminalConnectionReason() == null)
            return error.InvalidAuthority;
        self.catchup_stage_owner.state = .idle;
        self.catchup_stage_owner.active_generation = 0;
        self.catchup_stage_owner.seal = 0;
        self.catchup_stage_owner.canonical.lifecycle = .aborted;
    }

    pub fn armReadPumpPoisonCapture(
        self: *GenerationAttachment,
        capture: *maru.observability.incident_publication_contract.ReadPumpPoisonCapture,
        timestamp_ns: i128,
        controller_generation: u64,
    ) @import("generation_batch_adapter.zig").Error!void {
        if (!self.valid() or self.lifecycle != .attached) return error.MovedOrCopied;
        try self.batch_adapter.armReadPumpPoisonCapture(
            capture,
            timestamp_ns,
            controller_generation,
        );
    }

    pub fn disarmReadPumpPoisonCapture(
        self: *GenerationAttachment,
        capture: *maru.observability.incident_publication_contract.ReadPumpPoisonCapture,
    ) void {
        if (!self.valid() or self.lifecycle != .attached)
            @panic("read pump poison attachment authority drifted");
        self.batch_adapter.disarmReadPumpPoisonCapture(capture);
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

    /// b3가 Client revoke fence를 이미 확정한 뒤 attachment 의미 상태만 같은 generation으로 닫는다.
    /// fence를 다시 호출하면 sibling outbound까지 두 번 처리할 수 있으므로 이 suffix에는 callback이 없다.
    pub fn applyPreparedRevokedNoFail(
        self: *GenerationAttachment,
        generation: u64,
    ) void {
        const permit = generation_transport_mod.beginControllerRevokeOwned(
            &self.transport,
            @intFromPtr(self),
        ) catch process_seal.fatalIntegrity(.proof_loss);
        self.payloadMut().applyValidatedRevoked(generation) catch
            process_seal.fatalIntegrity(.proof_loss);
        generation_transport_mod.finishControllerRevokeOwned(
            &self.transport,
            @intFromPtr(self),
            permit,
        ) catch process_seal.fatalIntegrity(.proof_loss);
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

/// C2 제품 경로는 attachment가 request 준비와 decoder 실행을 한 owner stack에서 끝내게 한다.
/// 준비 뒤 실패한 request만 여기서 회수하며, accepted callback 뒤 proof-loss는 복구를 추측하지 않는다.
pub fn executeRequestWithDecoderOwned(
    attachment: *GenerationAttachment,
    request: contract.RuntimeRequest,
    context: *anyopaque,
    decoder: contract.RpcDecoder,
    pre_decode_context: *anyopaque,
    pre_decode: contract.RpcPreDecode,
    poison_capture: ?@import("client_slot.zig").PreparedExecutionPoisonCaptureRequest,
) generation_transport_mod.Error!contract.RpcDecodeDisposition {
    if (!attachment.valid() or attachment.lifecycle != .attached)
        return error.InvalidTransport;
    const receipt = attachment.transport.prepareRequest(request) catch |err| return switch (err) {
        error.Busy => error.AdminBusy,
        error.InvalidOwner => error.MovedOrCopied,
        error.Unauthorized, error.ProtocolError => error.InvalidReceipt,
        error.ResourceExhausted => error.OutOfMemory,
        error.IdentityExhausted => error.IdentityExhausted,
        error.ConnectionClosed => error.ConnectionClosed,
    };
    return generation_transport_mod.executePreparedRequestWithDecoderOwned(
        &attachment.transport,
        @intFromPtr(attachment),
        receipt,
        context,
        decoder,
        pre_decode_context,
        pre_decode,
        poison_capture,
    ) catch |err| {
        attachment.transport.abortPreparedRequest(receipt) catch {};
        return err;
    };
}

fn rawLifecycleValid(value: *const Lifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(Lifecycle.retirement_prepared);
}

fn recursivelyContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => true,
        .array => |info| recursivelyContainsPointer(info.child),
        .optional => |info| recursivelyContainsPointer(info.child),
        .error_union => |info| recursivelyContainsPointer(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (recursivelyContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (recursivelyContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

pub const testing_api = if (builtin.is_test) struct {
    pub const EventReleasePostSnapshot = client_slot_mod.EventReleasePostSnapshot;
    pub const EventReleaseSourceSnapshot = client_slot_mod.testing.EventReleaseSourceSnapshot;
    pub const ForkRejectedClientProjection = client_slot_mod.testing.ForkRejectedClientProjection;

    pub fn initializeProcessRuntime() !void {
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
    }

    pub fn eventReleaseSourceSnapshot(
        adapter: *host_adapter_mod.HostAdapter,
    ) !EventReleaseSourceSnapshot {
        return client_slot_mod.testing.eventReleaseSourceSnapshot(&adapter.slot);
    }

    pub fn forkRejectedClientProjection(
        adapter: *const host_adapter_mod.HostAdapter,
    ) ForkRejectedClientProjection {
        return client_slot_mod.testing.forkRejectedClientProjection(&adapter.slot);
    }

    pub fn pendingEventPayloadCallbackCount() usize {
        return client_slot_mod.testing.pendingEventPayloadCallbackCount();
    }

    pub const DeinitReadiness = struct {
        stage_idle: bool,
        response_terminal: bool,
        event_ready: bool,
        transport_ready: bool,
        batch_ready: bool,
        operation_idle: bool,
        rpc_free: bool,
        prepared_settled: bool,
        response_settled: bool,
        bound_drop_ready: bool,
    };

    pub fn deinitReadiness(
        attachment: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) DeinitReadiness {
        const canonical = attachment.binding.identity;
        const reservation = attachment.reservation;
        return .{
            .stage_idle = attachment.catchup_stage_owner.stateRawValid() and
                attachment.catchup_stage_owner.state == .idle,
            .response_terminal = attachment.response.lifecycleRawValid() and
                attachment.response.lifecycle == .terminal,
            .event_ready = generation_transport_mod.eventReadinessOwned(
                &attachment.transport,
                @intFromPtr(attachment),
                &attachment.event_owner,
                attachment.event_generation_mirror,
            ) == .ready,
            .transport_ready = generation_transport_mod.preflightTerminalizeOwned(
                &attachment.transport,
                @intFromPtr(attachment),
            ) == .ready,
            .batch_ready = if (attachment.batch_adapter.preflightDraining()) |_| true else |_| false,
            .operation_idle = adapter.slot.current.active_operation_generation == 0,
            .rpc_free = adapter.slot.current.rpc_free_evidence.emptyExact(),
            .prepared_settled = if (canonical != null and reservation != null)
                (adapter.slot.current.cleanup_registry.preparedRequestSettlementReadiness(
                    reservation.?.cleanup,
                    canonical.?,
                ) catch .invalid) == .settled
            else
                false,
            .response_settled = if (canonical != null and reservation != null)
                (adapter.slot.current.cleanup_registry.rpcResponseSettlementReadiness(
                    reservation.?.cleanup,
                    canonical.?,
                ) catch .invalid) == .settled
            else
                false,
            .bound_drop_ready = if (canonical != null and reservation != null)
                if (adapter.slot.current.cleanup_registry.preflightBoundDrop(
                    reservation.?.cleanup,
                    canonical.?,
                    attachment.lease.stream_id,
                )) |_| true else |_| false
            else
                false,
        };
    }

    pub fn armSettlementProofLossMarker(fd: std.c.fd_t, stage_raw: u8) void {
        client_slot_mod.testing.armEventReleaseProofLossMarker(fd, stage_raw);
    }

    pub fn armSettlementDeathCheckpoint(
        attachment: *GenerationAttachment,
        fd: std.c.fd_t,
        stage_raw: u8,
    ) void {
        if (settlement_death_checkpoint != null or stage_raw < 1 or stage_raw > 3)
            @panic("settlement death checkpoint replayed");
        settlement_death_checkpoint = .{
            .attachment_addr = @intFromPtr(attachment),
            .marker_fd = fd,
            .stage_raw = stage_raw,
        };
    }

    pub fn takeEventReleasePostSnapshot() ?EventReleasePostSnapshot {
        return client_slot_mod.testing.takeEventReleasePostSnapshot();
    }

    pub const EventPayloadRange = struct { address: usize, len: usize };
    pub const EffectStateSnapshot = struct {
        first_reason_present: bool,
        first_reason_raw: u8,
        unusable: bool,
        outbound_addr: usize,
        outbound_len: usize,
        outbound_offset: usize,
        outbound_stream_id: u64,
        outbound_byte_len: u8,
        outbound_bytes: [64]u8,
        outbound_digest: [32]u8,
    };

    pub fn eventPayloadRange(attachment: *GenerationAttachment) !EventPayloadRange {
        const projection = try generation_event.releaseProjection(&attachment.event_owner);
        return .{ .address = projection.payload_addr, .len = projection.payload_len };
    }

    pub fn seedFirstReason(adapter: *host_adapter_mod.HostAdapter, raw: u8) !void {
        const client = host_adapter_mod.HostAdapter.testing.rawClient(adapter);
        const Reason = @typeInfo(@TypeOf(client.first_poison_reason)).optional.child;
        client.first_poison_reason = std.enums.fromInt(Reason, raw) orelse return error.InvalidOwner;
    }

    pub fn seedSiblingOutbound(
        adapter: *host_adapter_mod.HostAdapter,
        bytes: []const u8,
        offset: usize,
        stream_id: u64,
    ) !void {
        const client = host_adapter_mod.HostAdapter.testing.rawClient(adapter);
        if (offset >= bytes.len or client.pending_outbound != null) return error.InvalidOwner;
        client.pending_outbound = .{
            .frame = try client.allocator.dupe(u8, bytes),
            .offset = offset,
            .stream_id = stream_id,
        };
    }

    pub fn effectStateSnapshot(adapter: *host_adapter_mod.HostAdapter) EffectStateSnapshot {
        const client = host_adapter_mod.HostAdapter.testing.rawClient(adapter);
        var result: EffectStateSnapshot = .{
            .first_reason_present = client.first_poison_reason != null,
            .first_reason_raw = if (client.first_poison_reason) |reason| @intCast(@intFromEnum(reason)) else 0,
            .unusable = client.unusable,
            .outbound_addr = 0,
            .outbound_len = 0,
            .outbound_offset = 0,
            .outbound_stream_id = 0,
            .outbound_byte_len = 0,
            .outbound_bytes = [_]u8{0} ** 64,
            .outbound_digest = [_]u8{0} ** 32,
        };
        if (client.pending_outbound) |pending| {
            result.outbound_addr = @intFromPtr(pending.frame.ptr);
            result.outbound_len = pending.frame.len;
            result.outbound_offset = pending.offset;
            result.outbound_stream_id = pending.stream_id;
            result.outbound_byte_len = @intCast(@min(pending.frame.len, result.outbound_bytes.len));
            @memcpy(result.outbound_bytes[0..result.outbound_byte_len], pending.frame[0..result.outbound_byte_len]);
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update(pending.frame);
            hasher.final(&result.outbound_digest);
        }
        return result;
    }

    pub fn payloadExcludesProtected(
        payload_addr: usize,
        payload_len: usize,
        protected: anytype,
    ) bool {
        return payloadExtentExcludesProtected(payload_addr, payload_len, protected);
    }

    pub fn replaceEventPayload(
        attachment: *GenerationAttachment,
        address: usize,
        len: usize,
    ) []u8 {
        return generation_event.testing.replacePayload(&attachment.event_owner, address, len);
    }

    pub fn restoreEventPayload(attachment: *GenerationAttachment, payload: []u8) void {
        generation_event.testing.restorePayload(&attachment.event_owner, payload);
    }

    pub const PreparedSettlement = GenerationAttachment.PreparedSettlement;

    pub fn preparePendingSettlement(
        attachment: *GenerationAttachment,
        allocator: std.mem.Allocator,
        lifetime_owner: anytype,
        pending_owner: anytype,
        runtime_addr: usize,
        runtime_extent: usize,
        observation: anytype,
        direct_input: anytype,
        direct_input_offset: *usize,
        pending_controls: anytype,
        blocking_flush_active: *bool,
        resize_generation: *u64,
        resize_baseline_present: *bool,
    ) !PreparedSettlement {
        return attachment.preparePendingSettlement(.{
            .allocator = allocator,
            .lifetime_owner = lifetime_owner,
            .pending_owner = pending_owner,
            .runtime_addr = runtime_addr,
            .runtime_extent = runtime_extent,
            .observation = observation,
            .direct_input = direct_input,
            .direct_input_offset = direct_input_offset,
            .pending_controls = pending_controls,
            .blocking_flush_active = blocking_flush_active,
            .resize_generation = resize_generation,
            .resize_baseline_present = resize_baseline_present,
        });
    }

    pub const SettlementSourceSnapshot = struct {
        owner_pristine: bool,
        correlation_pristine: bool,
        event_generation_mirror: u64,
    };

    pub fn settlementSourceSnapshot(attachment: *const GenerationAttachment) SettlementSourceSnapshot {
        return .{
            .owner_pristine = generation_event.pristineExact(&attachment.event_owner),
            .correlation_pristine = std.meta.eql(
                attachment.transport.event_correlation,
                generation_transport_mod.EventCorrelation{},
            ),
            .event_generation_mirror = attachment.event_generation_mirror,
        };
    }

    pub fn initAttached(
        attachment: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
        allocator: std.mem.Allocator,
        runtime_id: u128,
        stream_id: u64,
    ) !void {
        try GenerationAttachment.initInPlace(attachment, adapter);
        const receipt = try attachment.prepareControllerAttach(adapter, runtime_id);
        const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
        var response_bytes: ?[]u8 = null;
        errdefer {
            if (response_bytes) |bytes| allocator.free(bytes);
            switch (attachment.lifecycle) {
                .binding_prepared => {
                    attachment.transport.abortPreparedRequest(receipt) catch {};
                    attachment.batch_adapter.abortPrepared();
                    attachment.terminalizeTransport();
                    adapter.abortAttachmentBinding(
                        &attachment.binding,
                        attachment.reservation.?,
                    ) catch @panic("test attachment prepared rollback failed");
                    attachment.lifecycle = .terminal;
                },
                .executing => {
                    _ = attachment.finishResponse(adapter);
                    attachment.transport.abortPreparedRequest(receipt) catch {};
                    attachment.batch_adapter.abortPrepared();
                    attachment.terminalizeTransport();
                    adapter.abortExecutedAttachmentBinding(
                        &attachment.binding,
                        attachment.reservation.?,
                        executed,
                    ) catch @panic("test attachment executed rollback failed");
                    attachment.lifecycle = .terminal;
                },
                .attached => attachment.deinit(adapter),
                .shell => attachment.lifecycle = .terminal,
                .pristine, .retirement_prepared, .cleaning, .terminal => {},
            }
        }
        try attachment.binding.beginExecute(receipt);
        attachment.lifecycle = .executing;
        try attachment.transport.abortPreparedRequest(receipt);
        const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
        response_bytes = try allocator.dupe(u8, "accepted");
        try attachment.response.initAcceptedFromPromotedInPlace(
            allocator,
            try adapter.responseOwnerSeal(attachment.reservation.?),
            stream_id + 1,
            accepted,
            response_bytes.?,
            testAllocationProvenance(stream_id + 1),
        );
        response_bytes = null;
        if (attachment.finishResponse(adapter) != .cleaned)
            return error.TestUnexpectedResult;
        try attachment.commitAccepted(adapter, accepted, .{
            .runtime_id = runtime_id,
            .stream_id = stream_id,
            .role = .controller,
            .controller_generation = 1,
        }, allocator);
    }
} else struct {};

test "C3-3b3 preparation facade 결과는 재귀적으로 pointer-free다" {
    try std.testing.expect(!recursivelyContainsPointer(testing_api.PreparedSettlement));
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
    const owner_state_raw: *u8 = @ptrCast(&attachment.catchup_stage_owner.state);
    const OwnerState = @TypeOf(attachment.catchup_stage_owner.state);
    const deadline = try client_deadline.AbsoluteDeadline.after(std.testing.io, std.time.ns_per_s);
    for ([_]OwnerState{
        .building,
        .staged,
        .controller_committing,
        .controller_evidenced,
        .controller_promoted,
    }) |active_state| {
        attachment = .{};
        attachment.catchup_stage_owner.state = active_state;
        try std.testing.expectError(
            error.InvalidAuthority,
            attachment.prepareCatchupStage(1, 1, deadline, std.testing.io),
        );
        var stage: catchup_stage_contract.PreparedStage = .{};
        try std.testing.expect(!attachment.validateCatchupStage(&stage, deadline));
        var adapter: host_adapter_mod.HostAdapter = undefined;
        try std.testing.expectEqual(DeinitOutcome.busy, attachment.tryDeinit(&adapter));
    }
    attachment = .{};
    var owner_raw: u16 = @intFromEnum(OwnerState.controller_promoted) + 1;
    while (owner_raw <= std.math.maxInt(u8)) : (owner_raw += 1) {
        owner_state_raw.* = @intCast(owner_raw);
        try std.testing.expectError(
            error.InvalidAuthority,
            attachment.prepareCatchupStage(1, 1, deadline, std.testing.io),
        );
        var stage: catchup_stage_contract.PreparedStage = .{};
        try std.testing.expect(!attachment.validateCatchupStage(&stage, deadline));
        var adapter: host_adapter_mod.HostAdapter = undefined;
        try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.tryDeinit(&adapter));
    }
    attachment = .{};
}

test "CR3a-2c3d C3-1 shell attachment without a minted transport tears down cleanly" {
    // 이 테스트가 증명하는 것: `initInPlace`만 끝난 `.shell` attachment는 teardown을 거부하지 않는다.
    //
    // 왜 터미널에서 중요한가: `RemoteRuntime.spawnWithConnection`은 generation owner를 세운 직후
    // `errdefer deinitGenerationOwnerAndScreenSource()`를 걸고 host에 `runtime.spawn_full`을 보낸다.
    // 그 RPC가 실패하면 attachment는 아직 attach를 준비조차 하지 않은 `.shell`이고, 이 상태의 teardown이
    // `.corrupt`로 거부되면 `deinit`이 곧바로 `@panic`한다. 사용자 입장에서는 "새 터미널이 안 열린다"가
    // 아니라 **앱 전체가 죽는다**. 실제로 2026-08-26에 이 경로로 앱이 시작 0.5~1.1초 만에 연속으로
    // abort했다. spawn 실패는 회복 가능한 오류여야 하므로 롤백이 성공해야 한다.
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x5E11_0001,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    try std.testing.expectEqual(Lifecycle.shell, attachment.lifecycle);
    // transport는 `prepareAttach`에서만 mint된다. 여기서는 아직 pristine이라 terminalize할 권위가 없다.
    try std.testing.expect(attachment.reservation == null);

    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(Lifecycle.terminal, attachment.lifecycle);
    // teardown은 replay를 거부한다 — 두 번째 호출은 여전히 fail-closed여야 한다.
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-1 inline event owner blocks teardown until explicit release" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D31,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var attachment: GenerationAttachment = .{};
    try testing_api.initAttached(&attachment, &adapter, allocator, 0x2C3D32, 0x2C3D34);

    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D34,
        "{\"event\":\"future.event\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try attachment.takeEvent(),
    );
    try std.testing.expect(attachment.event_generation_mirror != 0);
    try std.testing.expectError(error.Busy, attachment.takeEvent());
    _ = try attachment.viewEvent();
    try std.testing.expectEqual(DeinitOutcome.busy, attachment.tryDeinit(&adapter));
    try attachment.releaseEvent();
    try std.testing.expectEqual(@as(u64, 0), attachment.event_generation_mirror);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-1 mirror drift and copied attachment cannot settle canonical event" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D41,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try testing_api.initAttached(&attachment, &adapter, allocator, 0x2C3D42, 0x2C3D43);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D43,
        "{\"event\":\"future.event\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try attachment.takeEvent(),
    );
    const canonical_generation = attachment.event_generation_mirror;
    const canonical_pin_count = adapter.slot.current.pin_owner.cleanup_pin_count;
    const canonical_owner = attachment.event_owner;

    const ThreadProbe = struct {
        attachment: *GenerationAttachment,
        rejected: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.attachment.releaseEvent() catch |err| {
                self.rejected.store(err == error.InvalidOwner, .release);
            };
        }
    };
    var thread_probe = ThreadProbe{ .attachment = &attachment };
    const thread = try std.Thread.spawn(.{}, ThreadProbe.run, .{&thread_probe});
    thread.join();
    try std.testing.expect(thread_probe.rejected.load(.acquire));
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&canonical_owner),
        std.mem.asBytes(&attachment.event_owner),
    );
    try std.testing.expectEqual(canonical_generation, attachment.event_generation_mirror);
    try std.testing.expectEqual(canonical_pin_count, adapter.slot.current.pin_owner.cleanup_pin_count);

    if (@import("builtin").os.tag == .macos) {
        const child = std.c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            const take_rejected = if (attachment.takeEvent()) |_| false else |_| true;
            const view_rejected = if (attachment.viewEvent()) |_| false else |_| true;
            const release_rejected = if (attachment.releaseEvent()) |_| false else |err| err == error.InvalidOwner;
            const deinit_rejected = attachment.tryDeinit(&adapter) == .corrupt;
            std.c._exit(if (take_rejected and view_rejected and release_rejected and deinit_rejected) 0 else 1);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
        try std.testing.expectEqual(canonical_pin_count, adapter.slot.current.pin_owner.cleanup_pin_count);
    }

    attachment.event_generation_mirror +%= 1;
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(canonical_pin_count, adapter.slot.current.pin_owner.cleanup_pin_count);

    var copied = attachment;
    try std.testing.expectEqual(DeinitOutcome.corrupt, copied.tryDeinit(&adapter));
    try std.testing.expectError(error.InvalidOwner, copied.releaseEvent());
    try std.testing.expectEqual(canonical_pin_count, adapter.slot.current.pin_owner.cleanup_pin_count);
    try attachment.releaseEvent();
    try std.testing.expectEqual(@as(u64, 0), attachment.event_generation_mirror);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-1 construction seals the exact inline owner and stays in budget" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D51,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(&adapter, 0x2C3D52);
    try std.testing.expectEqual(@intFromPtr(&attachment.event_owner), attachment.transport.event_owner_addr);
    try std.testing.expect(@intFromPtr(&attachment.event_owner) >= @intFromPtr(&attachment));
    try std.testing.expect(
        @intFromPtr(&attachment.event_owner) + @sizeOf(generation_transport_mod.EventOwner) <=
            @intFromPtr(&attachment) + @sizeOf(GenerationAttachment),
    );
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(generation_transport_mod.EventOwner));
    try std.testing.expect(@sizeOf(GenerationAttachment) <= 8 * 1024);
    try std.testing.expectEqual(
        @as(usize, 2 * 1024 * 1024),
        @sizeOf(generation_transport_mod.EventOwner) * @import("protocol.zig").max_inventory_runtimes,
    );
    try attachment.transport.abortPreparedRequest(receipt);
    attachment.terminalizeTransport();
    try adapter.abortAttachmentBinding(&attachment.binding, attachment.reservation.?);
    attachment.lifecycle = .terminal;
}

test "CR3a-2c3d C3-1 release callback preserves mirror and teardown stays busy" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var reentrant = EventReleaseReentrantAllocator{ .parent = std.testing.allocator };
    const allocator = reentrant.allocator();
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D61,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try testing_api.initAttached(&attachment, &adapter, allocator, 0x2C3D62, 0x2C3D63);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D63,
        "{\"event\":\"future.event\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try attachment.takeEvent(),
    );
    const generation = attachment.event_generation_mirror;
    reentrant.target = &attachment;
    reentrant.adapter = &adapter;
    reentrant.armed = true;
    try attachment.releaseEvent();
    reentrant.armed = false;
    try std.testing.expect(reentrant.reentered);
    try std.testing.expect(reentrant.nested_release_terminal);
    try std.testing.expectEqual(DeinitOutcome.busy, reentrant.nested_deinit.?);
    try std.testing.expectEqual(generation, reentrant.mirror_during_callback);
    try std.testing.expectEqual(@as(u64, 0), attachment.event_generation_mirror);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-1 event 예약 실패와 모든 준비 할당 실패는 terminal로 원복한다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D71,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    attachment.event_owner.storage[0] = 1;
    try std.testing.expectError(
        error.InvalidTransport,
        attachment.prepareControllerAttach(&adapter, 0x2C3D72),
    );
    try std.testing.expectEqual(Lifecycle.terminal, attachment.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), attachment.batch_adapter.slot_addr);
    try std.testing.expectError(
        error.InvalidOwner,
        attachment.transport.prepareRequest(contract.RuntimeRequest.detach()),
    );

    var request_exhausted: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&request_exhausted, &adapter);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).next_request_id = std.math.maxInt(u64);
    try std.testing.expectError(
        error.ProtocolError,
        request_exhausted.prepareControllerAttach(&adapter, 0x2C3D73),
    );
    try std.testing.expectEqual(Lifecycle.terminal, request_exhausted.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), request_exhausted.batch_adapter.slot_addr);
    try std.testing.expectError(
        error.InvalidOwner,
        request_exhausted.transport.prepareRequest(contract.RuntimeRequest.detach()),
    );

    const AllocationFailure = struct {
        fn run(failing_allocator: std.mem.Allocator) !void {
            var source: @import("client.zig").Client = .{
                .allocator = failing_allocator,
                .fd = -1,
                .host_id = 0x2C3D74,
                .parser = framing.FrameParser.init(failing_allocator),
            };
            var host: host_adapter_mod.HostAdapter = undefined;
            try host_adapter_mod.HostAdapter.initInPlace(
                &host,
                std.testing.allocator,
                &source,
            );
            defer host.deinit();

            var candidate: GenerationAttachment = .{};
            try GenerationAttachment.initInPlace(&candidate, &host);
            const prepared = candidate.prepareControllerAttach(&host, 0x2C3D75) catch |err| {
                if (err != error.OutOfMemory and err != error.ResourceExhausted) return err;
                try std.testing.expectEqual(Lifecycle.terminal, candidate.lifecycle);
                try std.testing.expectEqual(
                    @as(usize, 0),
                    host.slot.current.pin_owner.cleanup_pin_count,
                );
                try std.testing.expectEqual(
                    @as(usize, 0),
                    try host.slot.current.cleanup_registry.count(),
                );
                try std.testing.expectEqual(@as(usize, 0), candidate.batch_adapter.slot_addr);
                return error.OutOfMemory;
            };
            const result = try candidate.executePreparedAttach(&host, prepared);
            switch (result) {
                .uncertain_or_connection_failure => {},
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqual(Lifecycle.terminal, candidate.lifecycle);
            try std.testing.expectEqual(
                @as(usize, 0),
                host.slot.current.pin_owner.cleanup_pin_count,
            );
            try std.testing.expectEqual(
                @as(usize, 0),
                try host.slot.current.cleanup_registry.count(),
            );
            try std.testing.expectEqual(@as(usize, 0), candidate.batch_adapter.slot_addr);
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        AllocationFailure.run,
        .{},
    );
}

test "CR3a-2c3d C3-1 same-address stale owner hands current event off without free" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var no_free_allocator: AttachmentEventNoFreeAllocator = .{ .parent = arena.allocator() };
    const allocator = no_free_allocator.allocator();
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D81,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try testing_api.initAttached(&attachment, &adapter, allocator, 0x2C3D82, 0x2C3D83);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D83,
        "{\"event\":\"future.event.one\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try attachment.takeEvent(),
    );
    const stale_owner = attachment.event_owner;
    const stale_generation = attachment.event_generation_mirror;
    try attachment.releaseEvent();
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D83,
        "{\"event\":\"future.event.two\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try attachment.takeEvent(),
    );
    try std.testing.expect(attachment.event_generation_mirror > stale_generation);
    const current_view = try attachment.viewEvent();
    no_free_allocator.target_addr = @intFromPtr(current_view.payload.ptr);
    no_free_allocator.target_len = current_view.payload.len;
    no_free_allocator.armed = true;
    attachment.event_owner = stale_owner;
    attachment.event_generation_mirror = stale_generation;
    try std.testing.expectError(error.Corrupt, attachment.releaseEvent());
    try std.testing.expectEqual(@as(usize, 0), no_free_allocator.armed_free_count);
    try std.testing.expectEqual(@as(usize, 0), no_free_allocator.target_free_count);
    no_free_allocator.armed = false;
    try std.testing.expectEqual(@as(u64, 0), attachment.event_generation_mirror);
    try std.testing.expectEqual(@as(usize, 1), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
}

test "CR3a-2c3d C3-1 mirror drift and permit exhaustion converge through canonical cleanup" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var no_free_allocator: AttachmentEventNoFreeAllocator = .{ .parent = arena.allocator() };
    const allocator = no_free_allocator.allocator();
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2C3D91,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    // A zeroed non-authoritative mirror must not prevent the canonical C2 owner from releasing.
    var zero_drift: GenerationAttachment = .{};
    try testing_api.initAttached(&zero_drift, &adapter, allocator, 0x2C3D92, 0x2C3D93);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D93,
        "{\"event\":\"future.event.zero-drift\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try zero_drift.takeEvent(),
    );
    zero_drift.event_generation_mirror = 0;
    try std.testing.expectError(error.Corrupt, zero_drift.takeEvent());
    try zero_drift.releaseEvent();
    try std.testing.expectEqual(@as(usize, 1), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(DeinitOutcome.cleaned, zero_drift.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);

    // Once operation identities are exhausted, release cannot retry. It must perform a trusted
    // no-free transfer under the registered-node operation and leave teardown convergent.
    var exhausted: GenerationAttachment = .{};
    try testing_api.initAttached(&exhausted, &adapter, allocator, 0x2C3D94, 0x2C3D95);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3D95,
        "{\"event\":\"future.event.exhausted\"}",
    );
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.taken,
        try exhausted.takeEvent(),
    );
    const exhausted_view = try exhausted.viewEvent();
    no_free_allocator.target_addr = @intFromPtr(exhausted_view.payload.ptr);
    no_free_allocator.target_len = exhausted_view.payload.len;
    no_free_allocator.armed = true;
    adapter.slot.current.next_operation_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.Corrupt, exhausted.releaseEvent());
    try std.testing.expectEqual(@as(usize, 0), no_free_allocator.armed_free_count);
    try std.testing.expectEqual(@as(usize, 0), no_free_allocator.target_free_count);
    no_free_allocator.armed = false;
    try std.testing.expectEqual(@as(u64, 0), exhausted.event_generation_mirror);
    try std.testing.expectEqual(@as(u64, 0), adapter.slot.current.active_operation_generation);
    try std.testing.expectEqual(@as(usize, 1), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(DeinitOutcome.cleaned, exhausted.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
}

test "CR3a-2c3d C3-2 ended event purges before ordinary event ownership" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = std.c.close(fds[1]);
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0x2C3DA1,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try testing_api.initAttached(&attachment, &adapter, allocator, 0x2C3DA2, 0x2C3DA3);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0x2C3DA3,
        "{\"event\":\"runtime.ended\"}",
    );

    try std.testing.expectEqual(
        generation_transport_mod.PurgeEndedOutcome.purged,
        try attachment.purgeEndedStream(),
    );
    try std.testing.expectEqual(@as(u64, 0), attachment.event_generation_mirror);
    try std.testing.expectEqual(
        generation_transport_mod.EventTakeOutcome.idle,
        try attachment.takeEvent(),
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

fn initPurgeTest(
    client: *@import("client.zig").Client,
    adapter: *host_adapter_mod.HostAdapter,
    attachment: *GenerationAttachment,
    host_id: u128,
    runtime_id: u128,
    stream_id: u64,
) !std.c.fd_t {
    const allocator = std.testing.allocator;
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    client.* = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = host_id,
        .parser = framing.FrameParser.init(allocator),
    };
    try host_adapter_mod.HostAdapter.initInPlace(adapter, allocator, client);
    try testing_api.initAttached(attachment, adapter, allocator, runtime_id, stream_id);
    return fds[1];
}

test "CR3a-2c3d C3-2 empty target is a mutation-free not-ended result" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3DB1, 0x2C3DB2, 0x2C3DB3);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    try std.testing.expectEqual(
        generation_transport_mod.PurgeEndedOutcome.not_ended,
        try attachment.purgeEndedStream(),
    );
    try std.testing.expectEqual(@as(usize, 0), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_events.items.len);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-2 ordinary owner blocks purge until exact release" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3DC1, 0x2C3DC2, 0x2C3DC3);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3DC3, "{\"event\":\"future.event\"}");
    try std.testing.expectEqual(generation_transport_mod.EventTakeOutcome.taken, try attachment.takeEvent());
    try std.testing.expectError(error.Busy, attachment.purgeEndedStream());
    try attachment.releaseEvent();
    try std.testing.expectEqual(
        generation_transport_mod.PurgeEndedOutcome.not_ended,
        try attachment.purgeEndedStream(),
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-2 sibling ended cannot purge the bound stream" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3DD1, 0x2C3DD2, 0x2C3DD3);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3DD4, "{\"event\":\"runtime.ended\"}");
    try std.testing.expectEqual(
        generation_transport_mod.PurgeEndedOutcome.not_ended,
        try attachment.purgeEndedStream(),
    );
    const sibling = (try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).takeEventForStream(0x2C3DD4)).?;
    try std.testing.expectEqualStrings("{\"event\":\"runtime.ended\"}", sibling.payload);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).releaseEvent(sibling);
    try std.testing.expectEqual(@as(usize, 0), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_events.items.len);
    _ = allocator;
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-2 target purge preserves sibling byte order" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3DE1, 0x2C3DE2, 0x2C3DE3);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    const sibling_one = "{\"event\":\"runtime.ended\"}";
    const sibling_two = "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":\"000000000000000000000000000000bb\",\"cols\":140,\"rows\":50,\"resize_generation\":10,\"reason\":\"controller\"}}";
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3DE4, sibling_one);
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3DE3, "{\"event\":\"runtime.ended\"}");
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3DE4, sibling_two);
    try std.testing.expectEqual(generation_transport_mod.PurgeEndedOutcome.purged, try attachment.purgeEndedStream());
    const first = (try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).takeEventForStream(0x2C3DE4)).?;
    try std.testing.expectEqualStrings(sibling_one, first.payload);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).releaseEvent(first);
    const second = (try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).takeEventForStream(0x2C3DE4)).?;
    try std.testing.expectEqualStrings(sibling_two, second.payload);
    host_adapter_mod.HostAdapter.testing.rawClient(&adapter).releaseEvent(second);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-2 copied attachment cannot purge canonical queue" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3DF1, 0x2C3DF2, 0x2C3DF3);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3DF3, "{\"event\":\"runtime.ended\"}");
    var copied = attachment;
    try std.testing.expectError(error.InvalidOwner, copied.purgeEndedStream());
    try std.testing.expectEqual(@as(usize, 1), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_events.items.len);
    try std.testing.expectEqual(generation_transport_mod.PurgeEndedOutcome.purged, try attachment.purgeEndedStream());
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-2 foreign thread purge is rejected before mutation" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3E01, 0x2C3E02, 0x2C3E03);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3E03, "{\"event\":\"runtime.ended\"}");
    const Probe = struct {
        attachment: *GenerationAttachment,
        rejected: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            _ = self.attachment.purgeEndedStream() catch |err| {
                self.rejected.store(err == error.InvalidOwner, .release);
                return;
            };
        }
    };
    var probe = Probe{ .attachment = &attachment };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    try std.testing.expect(probe.rejected.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), host_adapter_mod.HostAdapter.testing.rawClient(&adapter).pending_events.items.len);
    try std.testing.expectEqual(generation_transport_mod.PurgeEndedOutcome.purged, try attachment.purgeEndedStream());
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "CR3a-2c3d C3-2 repeated purge is one-shot then not-ended" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    var client: @import("client.zig").Client = undefined;
    var adapter: host_adapter_mod.HostAdapter = undefined;
    var attachment: GenerationAttachment = .{};
    const peer = try initPurgeTest(&client, &adapter, &attachment, 0x2C3E11, 0x2C3E12, 0x2C3E13);
    defer _ = std.c.close(peer);
    defer adapter.deinit();
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(0x2C3E13, "{\"event\":\"runtime.ended\"}");
    try std.testing.expectEqual(generation_transport_mod.PurgeEndedOutcome.purged, try attachment.purgeEndedStream());
    try std.testing.expectEqual(generation_transport_mod.PurgeEndedOutcome.not_ended, try attachment.purgeEndedStream());
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

const AttachmentEventNoFreeAllocator = struct {
    parent: std.mem.Allocator,
    target_addr: usize = 0,
    target_len: usize = 0,
    armed: bool = false,
    armed_free_count: usize = 0,
    target_free_count: usize = 0,

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
        if (self.armed) self.armed_free_count += 1;
        if (self.armed and @intFromPtr(memory.ptr) == self.target_addr and memory.len == self.target_len)
            self.target_free_count += 1;
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

const EventReleaseReentrantAllocator = struct {
    parent: std.mem.Allocator,
    target: ?*GenerationAttachment = null,
    adapter: ?*host_adapter_mod.HostAdapter = null,
    armed: bool = false,
    in_callback: bool = false,
    reentered: bool = false,
    nested_release_terminal: bool = false,
    nested_deinit: ?DeinitOutcome = null,
    mirror_during_callback: u64 = 0,

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
        if (self.armed and !self.in_callback) {
            self.in_callback = true;
            self.reentered = true;
            const target = self.target.?;
            _ = target.releaseEvent() catch |err| {
                self.nested_release_terminal = err == error.Terminal;
            };
            self.mirror_during_callback = target.event_generation_mirror;
            self.nested_deinit = target.tryDeinit(self.adapter.?);
            self.in_callback = false;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
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
                contract.RuntimeRequest.detach(),
            )) |_| false else |_| true;
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "CR3a-2e 원복은 응답 불확정 뒤 row와 pin과 batch를 terminal로 정리한다" {
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
    );
    const result = try attachment.executePreparedAttach(&adapter, receipt);
    switch (result) {
        .uncertain_or_connection_failure => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), attachment.batch_adapter.slot_addr);
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.finishResponse(&adapter));
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.tryDeinit(&adapter));
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
    );
    try attachment.binding.beginExecute(receipt);
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0xEF,
        accepted,
        response_bytes,
        testAllocationProvenance(0xEF),
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
        error.InvalidOwner,
        attachment.transport.prepareRequest(contract.RuntimeRequest.detach()),
    );
    attachment = stale_parent;
    try std.testing.expectError(
        error.InvalidOwner,
        attachment.transport.prepareRequest(contract.RuntimeRequest.detach()),
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
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const correlated = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0xDC,
        correlated,
        bytes,
        testAllocationProvenance(0xDC),
    );
    const stale_parent = attachment;
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.abortExecutedAttach(&adapter, executed);
    adapter.deinit();

    attachment = stale_parent;
    try std.testing.expectError(
        error.InvalidOwner,
        attachment.transport.prepareRequest(contract.RuntimeRequest.detach()),
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
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2B4,
        accepted,
        response_bytes,
        testAllocationProvenance(0x2B4),
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
    const logical_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
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

test "CR3a-2d1 generation attachment는 첫 retryable token을 teardown fresh permit으로 정리한다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var release_probe = AttachmentEventNoFreeAllocator{ .parent = allocator };
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2D21,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();

    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(&adapter, 0x2D22);
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2D23,
        accepted,
        response_bytes,
        testAllocationProvenance(0x2D23),
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.commitAccepted(&adapter, accepted, .{
        .runtime_id = 0x2D22,
        .stream_id = 0x2D24,
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
    var runs = [_]screen_stream.Run{.{ .grapheme = "r", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&snapshot, allocator, row);
    const bytes = try release_probe.allocator().dupe(u8, snapshot.items);
    release_probe.target_addr = @intFromPtr(bytes.ptr);
    release_probe.target_len = bytes.len;
    const logical_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = true,
        .stream_id = 0x2D24,
        .bytes = bytes,
        .allocator = release_probe.allocator(),
    });
    logical_client.pending_batch_bytes = bytes.len;

    const batch_registry_mod = @import("generation_batch_registry.zig");
    const pending_lease = (try attachment.batch_adapter.interface().read_batch(
        &attachment.batch_adapter,
        0x2D24,
    )) orelse return error.TestUnexpectedResult;
    const pending_token = switch (pending_lease) {
        .generation => |token| token,
        else => return error.TestUnexpectedResult,
    };
    try attachment.payload.?.pending_batches.append(allocator, pending_lease);
    batch_registry_mod.testing.armNextRetryable(&adapter.slot.current.batch_registry, pending_token);
    release_probe.armed = true;
    try std.testing.expectError(error.LedgerInvariant, attachment.pumpScreen(std.testing.io));
    try std.testing.expect(attachment.payload.?.failed_release != null);
    try std.testing.expectEqual(@as(usize, 0), release_probe.target_free_count);
    try std.testing.expectEqual(@as(usize, 1), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 1), adapter.slot.current.accounting_ledger.item_count);

    const sibling_bytes = try allocator.dupe(u8, "sibling-after-retryable");
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 0x2D24,
        .bytes = sibling_bytes,
        .allocator = allocator,
    });
    logical_client.pending_batch_bytes += sibling_bytes.len;
    const sibling_count = logical_client.pending_batches.items.len;
    const sibling_bytes_count = logical_client.pending_batch_bytes;
    try std.testing.expectError(error.LedgerInvariant, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(sibling_count, logical_client.pending_batches.items.len);
    try std.testing.expectEqual(sibling_bytes_count, logical_client.pending_batch_bytes);
    try std.testing.expectEqual(@as(usize, 0), release_probe.target_free_count);

    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    release_probe.armed = false;
    try std.testing.expectEqual(@as(usize, 1), release_probe.target_free_count);
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.batch_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.accounting_ledger.item_count);
}

test "CR3a-2d2 GenerationAttachment는 두 번째 retryable을 node terminal handoff로 이전하고 CR3a-2d3 component 실제 attachment terminal drain은 source와 node를 final-zero로 만든다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var release_probe = AttachmentEventNoFreeAllocator{ .parent = allocator };
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2D31,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);

    var attachment: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&attachment, &adapter);
    const receipt = try attachment.prepareControllerAttach(&adapter, 0x2D32);
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2D33,
        accepted,
        response_bytes,
        testAllocationProvenance(0x2D33),
    );
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.finishResponse(&adapter));
    try attachment.commitAccepted(&adapter, accepted, .{
        .runtime_id = 0x2D32,
        .stream_id = 0x2D34,
        .role = .controller,
        .controller_generation = 1,
    }, allocator);

    const bytes = try release_probe.allocator().dupe(u8, "terminal-generation-batch");
    release_probe.target_addr = @intFromPtr(bytes.ptr);
    release_probe.target_len = bytes.len;
    const logical_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
    try logical_client.pending_batches.append(allocator, .{
        .is_snapshot = false,
        .stream_id = 0x2D34,
        .bytes = bytes,
        .allocator = release_probe.allocator(),
    });
    logical_client.pending_batch_bytes = bytes.len;
    const pending_lease = (try attachment.batch_adapter.interface().read_batch(
        &attachment.batch_adapter,
        0x2D34,
    )) orelse return error.TestUnexpectedResult;
    const pending_token = switch (pending_lease) {
        .generation => |token| token,
        else => return error.TestUnexpectedResult,
    };
    try attachment.payload.?.pending_batches.append(allocator, pending_lease);
    generation_batch_registry.testing.armNextRetryable(
        &adapter.slot.current.batch_registry,
        pending_token,
    );
    try std.testing.expectError(error.LedgerInvariant, attachment.pumpScreen(std.testing.io));
    try std.testing.expect(attachment.payload.?.failed_release != null);
    generation_batch_registry.testing.armNextRetryable(
        &adapter.slot.current.batch_registry,
        pending_token,
    );
    release_probe.armed = true;
    try std.testing.expectEqual(DeinitOutcome.terminal_handoff, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(Lifecycle.terminal, attachment.lifecycle);
    try std.testing.expect(attachment.payload == null);
    try std.testing.expectEqual(@as(usize, 0), release_probe.target_free_count);
    try std.testing.expectEqual(client_slot_mod.DeinitOutcome.terminal_handoff, adapter.slot.tryDeinit());
    adapter.deinit();
    try std.testing.expectEqual(client_slot_mod.Lifecycle.dead, adapter.slot.lifecycle);
    release_probe.armed = false;
    try std.testing.expectEqual(@as(usize, 1), release_probe.target_free_count);
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
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2D4,
        accepted,
        response_bytes,
        testAllocationProvenance(0x2D4),
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
    const logical_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
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
    );
    try attachment.binding.beginExecute(receipt);
    attachment.lifecycle = .executing;
    try attachment.transport.abortPreparedRequest(receipt);
    const executed = contract.ExecutedCallReceipt.fromPrepared(receipt).?;
    const accepted = contract.CorrelatedExecutedCall.init(executed, receipt.request_id).?;
    const response_bytes = try allocator.dupe(u8, "accepted");
    try attachment.response.initAcceptedFromPromotedInPlace(
        allocator,
        try adapter.responseOwnerSeal(attachment.reservation.?),
        0x2C3,
        accepted,
        response_bytes,
        testAllocationProvenance(0x2C3),
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
    const logical_client = host_adapter_mod.HostAdapter.testing.rawClient(&adapter);
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

test "CR3a-2e 원복은 typed reject 뒤 row와 pin과 batch를 terminal로 정리한다" {
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
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), attachment.batch_adapter.slot_addr);
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.finishResponse(&adapter));
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.tryDeinit(&adapter));
}

test "CR3a-2e 원복은 committed snapshot 실패를 같은 stream cleanup으로 수렴시킨다" {
    try client_slot_mod.ClientSlot.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var client: @import("client.zig").Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0x2E40,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: GenerationAttachment = .{};
    try testing_api.initAttached(&attachment, &adapter, allocator, 0x2E41, 0x2E42);
    try attachment.poisonInitialSnapshotApply(false);
    try std.testing.expectEqual(DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
    try std.testing.expectEqual(@as(usize, 0), try adapter.slot.current.cleanup_registry.count());
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectEqual(@as(usize, 0), attachment.batch_adapter.slot_addr);
}
