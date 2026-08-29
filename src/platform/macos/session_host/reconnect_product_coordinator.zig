//! CR6e-c3b2 main-owner bridge between bounded logical jobs and the physical reconnect lane.
//!
//! This owner is final-address and main-thread-only. It never performs connect/hello or waits in
//! a frame turn: the worker runtime owns that suffix, while this coordinator preserves the exact
//! c1 receipts until a product caller settles the bound admission and CR5 publication.

const std = @import("std");
const issuer = @import("reconnect_worker_issuer.zig");
const owner_mod = @import("reconnect_worker_owner.zig");
const worker_mod = @import("reconnect_worker_runtime.zig");
const admission_mod = @import("reconnect_admission_owner.zig");
const budget_mod = @import("reconnect_resident_budget.zig");
const backend_mod = @import("remote_term_backend.zig");
const process_seal = @import("process_seal_service.zig");

pub const PollResult = enum(u8) { idle, connected_ready, logical_completion_ready };
pub const AdmissionResult = enum(u8) { idle, admitted, coalesced, retry_later, discarded_stale };

pub const Coordinator = struct {
    self_addr: usize = 0,
    owner_thread: ?std.Thread.Id = null,
    jobs: owner_mod.Owner = .{},
    worker: worker_mod.Runtime = .{},
    job_receipt: owner_mod.JobReceipt = .{},
    completion_receipt: owner_mod.CompletionReceipt = .{},
    ready: bool = false,

    pub fn initInPlace(
        self: *Coordinator,
        allocator: std.mem.Allocator,
        io: std.Io,
        cache_base: []const u8,
        process_nonce: u64,
    ) !void {
        // Runtime's pristine value intentionally contains undefined allocator/io/cache storage;
        // inspect only its initialized discriminants so ReleaseFast never reads undefined bytes.
        if (self.self_addr != 0 or self.owner_thread != null or self.ready or
            self.worker.self_addr != 0 or self.worker.state != .pristine or self.worker.thread != null or
            !std.meta.eql(self.jobs, owner_mod.Owner{}) or
            !std.meta.eql(self.job_receipt, owner_mod.JobReceipt{}) or
            !std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}))
            return error.InvalidCoordinator;
        self.self_addr = @intFromPtr(self);
        self.owner_thread = std.Thread.getCurrentId();
        errdefer self.* = .{};
        try self.jobs.initInPlace(process_nonce);
        errdefer self.jobs.deinit() catch unreachable;
        try self.worker.initInPlace(allocator, io, cache_base);
        self.ready = true;
    }

    pub fn admit(self: *Coordinator, snapshot: owner_mod.Snapshot) !owner_mod.AdmitResult {
        try self.validate();
        return self.jobs.admit(snapshot);
    }

    /// Claims at most one process admission. New jobs reserve c1 before resident leases; later
    /// same-host incidents validate the first bound identity and coalesce without a second lease.
    pub fn admitOne(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        admissions: *admission_mod.Owner,
        budget: *budget_mod.ReconnectAdmissionBudget,
        absolute_deadline_ns: u64,
    ) !AdmissionResult {
        try self.validate();
        try backend.validateReconnectCoordinatorTarget();
        if (absolute_deadline_ns == 0) return error.InvalidDeadline;
        var dispatch: admission_mod.PreparedReconnectDispatch = .{};
        admissions.prepareDispatch(&dispatch) catch |err| switch (err) {
            error.NotFound => return .idle,
            else => return err,
        };
        var dispatch_owned = true;
        defer if (dispatch_owned) admissions.settleDispatch(&dispatch, .retry_later) catch
            process_seal.fatalIntegrity(.incident_authority);
        const projection = try admissions.preparedProjection(&dispatch);
        const snapshot: owner_mod.Snapshot = .{
            .host_id = projection.host_id,
            .pool_membership_generation = projection.host_adapter_generation,
            .connection_generation = projection.connection_generation,
            .incident_app_instance_nonce = projection.incident_id.app_instance_nonce,
            .incident_sequence = projection.incident_id.sequence,
            .absolute_deadline_ns = absolute_deadline_ns,
        };
        if (try self.jobs.activeSnapshotForHost(snapshot)) |first| {
            try backend.validateBoundReconnectSnapshot(first);
            const result = try self.jobs.admit(snapshot);
            switch (result) {
                .coalesced => {},
                .admitted => return error.InvalidCoordinator,
            }
            try admissions.settleDispatch(&dispatch, .scheduled);
            dispatch_owned = false;
            try admissions.consumeScheduled(projection);
            return .coalesced;
        }
        const reservation = try self.jobs.admit(snapshot);
        const key = switch (reservation) {
            .admitted => |value| value,
            .coalesced => return error.InvalidCoordinator,
        };
        const result = backend.bindPreparedReconnectAdmission(&dispatch, admissions, budget) catch |err| {
            dispatch_owned = false; // backend's defer has already returned it to admitted.
            try self.jobs.withdrawQueued(key, snapshot);
            return err;
        };
        dispatch_owned = false;
        switch (result) {
            .started => {
                try admissions.consumeScheduled(projection);
                return .admitted;
            },
            .retry_later => {
                try self.jobs.withdrawQueued(key, snapshot);
                return .retry_later;
            },
            .discarded_stale => {
                try self.jobs.withdrawQueued(key, snapshot);
                return .discarded_stale;
            },
            .idle => return error.InvalidCoordinator,
        }
    }

    /// Dispatches at most one queued logical job and never waits for it. A submit failure returns
    /// the exact c1 receipt to queued, so the admission/job remains retryable.
    pub fn dispatchOne(self: *Coordinator) !bool {
        try self.validate();
        if (!std.meta.eql(self.job_receipt, owner_mod.JobReceipt{}) or
            !std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}))
            return false;
        if (try self.worker.stateSnapshot() != .idle) return false;
        self.jobs.claim(&self.job_receipt) catch |err| switch (err) {
            error.NotFound => return false,
            else => return err,
        };
        const order: issuer.WorkOrder = .{
            .key = self.job_receipt.key,
            .snapshot = self.job_receipt.snapshot,
        };
        self.worker.submit(order) catch |err| {
            try self.jobs.returnClaimedToQueued(&self.job_receipt);
            return err;
        };
        return true;
    }

    /// Claims at most one physical completion. Failed results become a retained c1 completion;
    /// connected results stay claimed so c3b2b can move the candidate directly into c3a.
    pub fn pollCompletion(self: *Coordinator) !PollResult {
        try self.validate();
        if (!std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}))
            return .logical_completion_ready;
        const completion = (try self.worker.claimCompletion()) orelse return .idle;
        if (!sameOrder(completion.order, self.job_receipt)) return error.StaleCompletion;
        const outcome = try completion.outcome();
        if (outcome == .connected) return .connected_ready;
        try completion.consumeFailure();
        try self.finishClaimedPhysical(outcome);
        return .logical_completion_ready;
    }

    /// c3b2b calls this only after it consumed/abandoned the connected candidate at the same
    /// final address. The logical outcome records whether c3a adopted it or rejected it stale.
    pub fn finishConnected(self: *Coordinator, outcome: owner_mod.Outcome) !void {
        try self.validate();
        if (outcome == .connected or outcome == .retry_later or outcome == .cancelled) {
            try self.finishClaimedPhysical(outcome);
            return;
        }
        return error.InvalidOutcome;
    }

    pub fn claimedPhysicalCompletion(self: *Coordinator) !*issuer.Completion {
        try self.validate();
        if (try self.worker.stateSnapshot() != .claimed) return error.NotFound;
        return &self.worker.completion;
    }

    pub fn logicalCompletion(self: *Coordinator) !*owner_mod.CompletionReceipt {
        try self.validate();
        if (std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}))
            return error.NotFound;
        return &self.completion_receipt;
    }

    pub fn consumeLogicalCompletion(self: *Coordinator) !void {
        try self.validate();
        try self.jobs.consumeCompletion(&self.completion_receipt);
        try self.jobs.resetConsumedCompletionReceipt(&self.completion_receipt);
    }

    /// Product Quit calls this before backend/pool teardown. It wakes and joins the worker first,
    /// abandons a retained candidate at its final address, then drains every cancelled c1 slot.
    pub fn shutdownAndDeinit(self: *Coordinator) !void {
        try self.validate();
        try self.jobs.requestCancelAll();
        // A connected result may have been claimed by the preceding frame but not yet adopted.
        // The worker has already returned in this state; abandon it before waking the thread so
        // requestShutdown cannot strand the lane in `.claimed`.
        if (try self.worker.stateSnapshot() == .claimed) {
            if (!sameOrder(self.worker.completion.order, self.job_receipt))
                return error.StaleCompletion;
            try self.worker.completion.abandon();
            try self.finishClaimedPhysical(.cancelled);
        }
        try self.worker.requestShutdown();
        try self.worker.join();
        if (try self.worker.claimCompletion()) |completion| {
            if (!sameOrder(completion.order, self.job_receipt)) return error.StaleCompletion;
            try completion.abandon();
            try self.finishClaimedPhysical(.cancelled);
        }
        if (!std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}))
            try self.consumeLogicalCompletion();
        while (true) {
            self.jobs.takeCompletion(&self.completion_receipt) catch |err| switch (err) {
                error.NotFound => break,
                else => return err,
            };
            try self.consumeLogicalCompletion();
        }
        try self.worker.deinit();
        try self.jobs.deinit();
        self.* = .{};
    }

    fn finishClaimedPhysical(self: *Coordinator, outcome: owner_mod.Outcome) !void {
        try self.worker.completion.validateConsumedAtFinalAddress();
        try self.jobs.settle(&self.job_receipt, outcome);
        try self.worker.finishClaim();
        try self.jobs.resetConsumedJobReceipt(&self.job_receipt);
        try self.jobs.takeCompletion(&self.completion_receipt);
    }

    fn validate(self: *const Coordinator) !void {
        if (!self.ready or self.self_addr != @intFromPtr(self) or self.owner_thread == null or
            self.owner_thread.? != std.Thread.getCurrentId())
            return error.InvalidCoordinator;
    }
};

fn sameOrder(order: issuer.WorkOrder, receipt: owner_mod.JobReceipt) bool {
    return std.meta.eql(order.key, receipt.key) and std.meta.eql(order.snapshot, receipt.snapshot);
}

fn expiredSnapshot(io: std.Io, sequence: u64) owner_mod.Snapshot {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    return .{
        .host_id = 3,
        .pool_membership_generation = 4,
        .connection_generation = 5,
        .incident_app_instance_nonce = (@as(u128, 1) << 96) | 6,
        .incident_sequence = sequence,
        .absolute_deadline_ns = @intCast(@max(1, now - 1)),
    };
}

test "CR6e-c3b2a coordinator cycles final-address worker and logical receipts" {
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(std.testing.allocator, std.testing.io, "/tmp", 9);
    _ = try coordinator.admit(expiredSnapshot(std.testing.io, 7));
    try std.testing.expect(try coordinator.dispatchOne());
    var result: PollResult = .idle;
    for (0..10_000) |_| {
        result = try coordinator.pollCompletion();
        if (result != .idle) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(PollResult.logical_completion_ready, result);
    try std.testing.expectEqual(owner_mod.Outcome.deadline_exceeded, (try coordinator.logicalCompletion()).outcome);
    try coordinator.consumeLogicalCompletion();
    try std.testing.expectEqual(@as(usize, 0), try coordinator.jobs.activeCount());
    try coordinator.shutdownAndDeinit();
}

test "CR6e-c3b2a retained completion backpressures the next physical dispatch" {
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(std.testing.allocator, std.testing.io, "/tmp", 9);
    _ = try coordinator.admit(expiredSnapshot(std.testing.io, 7));
    try std.testing.expect(try coordinator.dispatchOne());
    while (try coordinator.pollCompletion() == .idle) std.Thread.yield() catch {};
    var sibling = expiredSnapshot(std.testing.io, 8);
    sibling.host_id = 4;
    _ = try coordinator.admit(sibling);
    try std.testing.expect(!(try coordinator.dispatchOne()));
    try coordinator.consumeLogicalCompletion();
    try std.testing.expect(try coordinator.dispatchOne());
    try coordinator.shutdownAndDeinit();
}

test "CR6e-c3b2a idle shutdown joins before all final-address owners deinit" {
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(std.testing.allocator, std.testing.io, "/tmp", 9);
    try coordinator.shutdownAndDeinit();
    try std.testing.expectEqual(@as(usize, 0), coordinator.self_addr);
    try std.testing.expect(!coordinator.ready);
    try std.testing.expectEqual(worker_mod.State.pristine, coordinator.worker.state);
}

test "CR6e-c3b2a admission reservation binds once and coalesces on the first identity" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const host_adapter = @import("host_adapter.zig");
    const remote_runtime = @import("remote_runtime.zig");
    try host_adapter.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var fixture: remote_runtime.testing_api.SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    var backend: backend_mod.RemoteTermBackend = undefined;
    try backend_mod.RemoteTermBackend.testing_api.initReconnectCoordinatorBackend(
        &backend,
        std.testing.allocator,
    );
    defer backend.deinit();
    try backend_mod.RemoteTermBackend.testing_api.installReconnectRuntime(
        &backend,
        1,
        &fixture.runtime,
        1,
        3,
    );
    defer _ = backend_mod.RemoteTermBackend.testing_api.removeEventCursorRuntime(&backend, 1);
    var admissions: admission_mod.Owner = .{};
    try admissions.initInPlace(identity.process_nonce);
    var budget: budget_mod.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    defer budget.deinit() catch @panic("c3b2a budget leak");
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(
        std.testing.allocator,
        std.testing.io,
        "/tmp",
        identity.process_nonce,
    );
    defer coordinator.shutdownAndDeinit() catch @panic("c3b2a coordinator shutdown failed");
    const connection_generation = fixture.adapter.connectionGeneration();
    try admitFixture(&admissions, connection_generation, 1);
    try std.testing.expectEqual(
        AdmissionResult.admitted,
        try coordinator.admitOne(
            &backend,
            &admissions,
            &budget,
            std.math.maxInt(u64),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
    try admitFixture(&admissions, connection_generation, 2);
    try std.testing.expectEqual(
        AdmissionResult.coalesced,
        try coordinator.admitOne(
            &backend,
            &admissions,
            &budget,
            std.math.maxInt(u64),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
    try backend.validateBoundReconnectSnapshot(.{
        .host_id = 1,
        .pool_membership_generation = 3,
        .connection_generation = connection_generation,
        .incident_app_instance_nonce = (@as(u128, 1) << 96) | 1,
        .incident_sequence = 1,
        .absolute_deadline_ns = std.math.maxInt(u64),
    });
    try remote_runtime.testing_api.releaseBoundReconnectAdmission(&fixture.runtime, &budget);
}

fn admitFixture(admissions: *admission_mod.Owner, connection_generation: u64, sequence: u64) !void {
    const publication = @import("maru").observability.incident_publication_contract;
    const incident = @import("maru").observability.connection_incident;
    const input: publication.IncidentInput = .{
        .timestamp_ns = sequence,
        .host_id = 1,
        .host_adapter_generation = 3,
        .connection_generation = connection_generation,
        .wire_major = 1,
        .reason_raw = @intFromEnum(incident.ConnectionReason.connection_eof),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
    };
    try admissions.admit(.{
        .publication = .{
            .incident_id = .{
                .app_instance_nonce = (@as(u128, 1) << 96) | 1,
                .sequence = sequence,
            },
            .detail_present = true,
            .detail_slot = 0,
            .aggregate_slot = 0,
            .aggregate_generation = sequence,
        },
        .wake = .queued,
        .kind_raw = @intFromEnum(publication.PublicationKind.first),
    }, input);
}
