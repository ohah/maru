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
const framing = @import("framing.zig");
const initial_snapshot_owner_mod = @import("initial_snapshot_owner.zig");
const host_adapter_mod = @import("host_adapter.zig");
const process_seal = @import("process_seal_service.zig");
const remote_attachment = @import("remote_attachment.zig");
const screen_assembler = @import("screen_assembler.zig");
const screen_stream = @import("screen_stream.zig");
const settlement = @import("pending_event_settlement_contract.zig");
const runtime_lifetime = @import("runtime_lifetime_owner.zig");
const pending_event_owner_mod = @import("pending_event_owner.zig");
const pending_event_preparation = @import("pending_event_preparation.zig");
const runtime_pending_control = @import("runtime_pending_control.zig");
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
    already_terminal,
    busy,
    corrupt,
};

pub const GenerationAttachment = struct {
    pub fn pendingEventReleaseCallbackActive(self: *const GenerationAttachment) bool {
        return self.transport.pendingEventReleaseCallbackActive();
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

    pub fn initInPlace(
        out: *GenerationAttachment,
        adapter: *host_adapter_mod.HostAdapter,
    ) generation_transport_mod.Error!void {
        if (!rawLifecycleValid(&out.lifecycle) or out.self_addr != 0 or
            out.lifecycle != .pristine or out.payload != null or
            !@import("generation_event_contract.zig").pristineExact(&out.event_owner) or
            out.event_generation_mirror != 0)
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
        if (!self.valid() or self.lifecycle != .shell) return error.InvalidState;
        const reservation = try adapter.reserveAttachmentBinding(
            &self.binding,
            &self.lease,
            runtime_id,
            .controller,
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
        try generation_transport_mod.reserveEventOwnerInPlace(
            &self.transport,
            &self.event_owner,
        );
        const receipt = try self.transport.prepareRequest(
            contract.RuntimeRequest.attachController(),
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
        const projected = try generation_transport_mod.takeEventProjected(
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
        if (!rawLifecycleValid(&self.lifecycle)) return .corrupt;
        if (self.lifecycle == .terminal) return .corrupt;
        if (!self.valid()) return .corrupt;
        switch (self.lifecycle) {
            .shell => switch (generation_transport_mod.preflightTerminalizeOwned(
                &self.transport,
                @intFromPtr(self),
            )) {
                .ready => self.terminalizeTransport(),
                .busy => return .busy,
                .invalid => return .corrupt,
            },
            .binding_prepared => return .busy,
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
        if (outcome != .cleaned)
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
        self.transport.tombstonePendingEventOwnerNoFail(&self.event_owner, permit, begun);
        self.transport.beginPendingEventReleaseResourcesNoFail(effect_permit, permit, begun);
        self.transport.tombstonePendingEventCorrelationNoFail(begun);
        self.event_generation_mirror = 0;
        self.transport.markPendingEventMirrorTombstonedNoFail(self.event_generation_mirror, begun);
        self.transport.finishPendingEventReleaseNoFail(effect_permit, permit, begun, out);
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

    pub fn sendResyncNonBlocking(
        self: *GenerationAttachment,
    ) generation_transport_mod.InputError!bool {
        if (!self.valid() or self.lifecycle != .attached) return error.InvalidOwner;
        return generation_transport_mod.sendResyncNonBlockingOwned(
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
    ) catch |err| {
        attachment.transport.abortPreparedRequest(receipt) catch {};
        return err;
    };
}

fn rawLifecycleValid(value: *const Lifecycle) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(Lifecycle.terminal);
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
        const client = adapter.logicalClient();
        const Reason = @typeInfo(@TypeOf(client.first_poison_reason)).optional.child;
        client.first_poison_reason = std.enums.fromInt(Reason, raw) orelse return error.InvalidOwner;
    }

    pub fn seedSiblingOutbound(
        adapter: *host_adapter_mod.HostAdapter,
        bytes: []const u8,
        offset: usize,
        stream_id: u64,
    ) !void {
        const client = adapter.logicalClient();
        if (offset >= bytes.len or client.pending_outbound != null) return error.InvalidOwner;
        client.pending_outbound = .{
            .frame = try client.allocator.dupe(u8, bytes),
            .offset = offset,
            .stream_id = stream_id,
        };
    }

    pub fn effectStateSnapshot(adapter: *host_adapter_mod.HostAdapter) EffectStateSnapshot {
        const client = adapter.logicalClient();
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
                .pristine, .cleaning, .terminal => {},
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

    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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

test "CR3a-2c3d C3-1 event reserve failure rolls construction back to terminal" {
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
    try std.testing.expectError(
        error.InvalidOwner,
        attachment.transport.prepareRequest(contract.RuntimeRequest.detach()),
    );

    var request_exhausted: GenerationAttachment = .{};
    try GenerationAttachment.initInPlace(&request_exhausted, &adapter);
    adapter.logicalClient().next_request_id = std.math.maxInt(u64);
    try std.testing.expectError(
        error.ProtocolError,
        request_exhausted.prepareControllerAttach(&adapter, 0x2C3D73),
    );
    try std.testing.expectEqual(Lifecycle.terminal, request_exhausted.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.current.pin_owner.cleanup_pin_count);
    try std.testing.expectError(
        error.InvalidOwner,
        request_exhausted.transport.prepareRequest(contract.RuntimeRequest.detach()),
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try adapter.logicalClient().bufferGenerationEventForTest(
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
    try std.testing.expectEqual(@as(usize, 0), adapter.logicalClient().pending_events.items.len);
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
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3DC3, "{\"event\":\"future.event\"}");
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
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3DD4, "{\"event\":\"runtime.ended\"}");
    try std.testing.expectEqual(
        generation_transport_mod.PurgeEndedOutcome.not_ended,
        try attachment.purgeEndedStream(),
    );
    const sibling = (try adapter.logicalClient().takeEventForStream(0x2C3DD4)).?;
    try std.testing.expectEqualStrings("{\"event\":\"runtime.ended\"}", sibling.payload);
    adapter.logicalClient().releaseEvent(sibling);
    try std.testing.expectEqual(@as(usize, 0), adapter.logicalClient().pending_events.items.len);
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
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3DE4, sibling_one);
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3DE3, "{\"event\":\"runtime.ended\"}");
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3DE4, sibling_two);
    try std.testing.expectEqual(generation_transport_mod.PurgeEndedOutcome.purged, try attachment.purgeEndedStream());
    const first = (try adapter.logicalClient().takeEventForStream(0x2C3DE4)).?;
    try std.testing.expectEqualStrings(sibling_one, first.payload);
    adapter.logicalClient().releaseEvent(first);
    const second = (try adapter.logicalClient().takeEventForStream(0x2C3DE4)).?;
    try std.testing.expectEqualStrings(sibling_two, second.payload);
    adapter.logicalClient().releaseEvent(second);
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
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3DF3, "{\"event\":\"runtime.ended\"}");
    var copied = attachment;
    try std.testing.expectError(error.InvalidOwner, copied.purgeEndedStream());
    try std.testing.expectEqual(@as(usize, 1), adapter.logicalClient().pending_events.items.len);
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
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3E03, "{\"event\":\"runtime.ended\"}");
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
    try std.testing.expectEqual(@as(usize, 1), adapter.logicalClient().pending_events.items.len);
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
    try adapter.logicalClient().bufferGenerationEventForTest(0x2C3E13, "{\"event\":\"runtime.ended\"}");
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

test "CR3a-2c3b registry-cleared uncertain response rejects finish and attachment retry" {
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

test "CR3a-2c3b registry-cleared typed reject rejects finish and attachment retry" {
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
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.finishResponse(&adapter));
    try std.testing.expectEqual(DeinitOutcome.corrupt, attachment.tryDeinit(&adapter));
}
