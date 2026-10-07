//! CR6e-c3b2 main-owner bridge between bounded logical jobs and the physical reconnect lane.
//!
//! This owner is final-address and main-thread-only. It never performs connect/hello or waits in
//! a frame turn: the worker runtime owns that suffix, while this coordinator preserves the exact
//! c1 receipts until a product caller settles the bound admission and CR5 publication.

const std = @import("std");
const builtin = @import("builtin");
const issuer = @import("reconnect_worker_issuer.zig");
const owner_mod = @import("reconnect_worker_owner.zig");
const worker_mod = @import("reconnect_worker_runtime.zig");
const admission_mod = @import("reconnect_admission_owner.zig");
const budget_mod = @import("reconnect_resident_budget.zig");
const backend_mod = @import("remote_term_backend.zig");
const failure_log = @import("reconnect_failure_log.zig");
const retry_policy = @import("reconnect_retry_policy.zig");
const attach_phase_deadline = @import("attach_phase_deadline.zig");
const process_seal = @import("process_seal_service.zig");

pub const PollResult = enum(u8) { idle, connected_ready, logical_completion_ready };
pub const AdmissionResult = enum(u8) { idle, admitted, coalesced, retry_later, discarded_stale };
pub const ConnectedSettlement = enum(u8) { adopted, retry_later };
pub const ConnectedProgress = enum(u8) { advanced, retry_later, completed, retained_terminal };
pub const TurnResult = enum(u8) { idle, progressed };
pub const Snapshot = struct {
    ready: bool,
    worker_state_raw: u8,
    active_jobs: usize,
    job_receipt_present: bool,
    completion_receipt_present: bool,
};

pub const Coordinator = struct {
    self_addr: usize = 0,
    owner_thread: ?std.Thread.Id = null,
    jobs: owner_mod.Owner = .{},
    worker: worker_mod.Runtime = .{},
    job_receipt: owner_mod.JobReceipt = .{},
    completion_receipt: owner_mod.CompletionReceipt = .{},
    ready: bool = false,
    /// 진단 전용 — 동작을 바꾸지 않는다. 마지막 물리 시도가 왜 그렇게 끝났는지, host 마다 몇 번 돌았는지,
    /// 다시 넣기 줄의 간격 상한(`reconnect_failure_log.zig`).
    last_attempt: failure_log.Attempt = .{},
    streaks: failure_log.Streaks = .{},
    requeue_rate: failure_log.RateLimit = .{},
    /// **동작을 정한다** — 위 진단 필드와 다르다. 다시 넣을 때의 대기 순번(`reconnect_retry_policy.zig`).
    retry_streak: retry_policy.Streak = .{},

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

    pub fn ensureReady(
        self: *Coordinator,
        allocator: std.mem.Allocator,
        io: std.Io,
        cache_base: []const u8,
        process_nonce: u64,
    ) !void {
        if (!self.ready) return self.initInPlace(allocator, io, cache_base, process_nonce);
        try self.validate();
        if (self.jobs.process_nonce != process_nonce or
            self.worker.cache_base_len != cache_base.len or
            !std.mem.eql(u8, self.worker.cache_base[0..self.worker.cache_base_len], cache_base))
            return error.InvalidCoordinator;
    }

    pub fn diagnosticSnapshot(self: *Coordinator) !Snapshot {
        if (!self.ready) return .{
            .ready = false,
            .worker_state_raw = @intFromEnum(worker_mod.State.pristine),
            .active_jobs = 0,
            .job_receipt_present = false,
            .completion_receipt_present = false,
        };
        try self.validate();
        return .{
            .ready = true,
            .worker_state_raw = @intFromEnum(try self.worker.stateSnapshot()),
            .active_jobs = try self.jobs.activeCount(),
            .job_receipt_present = !std.meta.eql(self.job_receipt, owner_mod.JobReceipt{}),
            .completion_receipt_present = !std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}),
        };
    }

    /// One app-global frame turn. The caller invokes this once before iterating Window sessions;
    /// every leaf is bounded to one claim/state/admission/dispatch and no leaf waits for I/O.
    pub fn turnOne(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        admissions: *admission_mod.Owner,
        budget: *budget_mod.ReconnectAdmissionBudget,
        absolute_deadline_ns: u64,
    ) !TurnResult {
        try self.validate();
        var progressed = false;
        switch (try self.pollCompletion()) {
            .idle => {},
            .logical_completion_ready => {
                if ((try self.logicalCompletion()).outcome != .connected) {
                    _ = try self.settleLogicalCompletion(backend, budget);
                    progressed = true;
                }
            },
            .connected_ready => {
                _ = try self.settleConnectedCompletion(backend, budget);
                progressed = true;
            },
        }
        if (!std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}) and
            self.completion_receipt.outcome == .connected)
        {
            _ = try self.progressConnectedOne(backend, budget);
            progressed = true;
        }
        if (try self.admitOne(backend, admissions, budget, absolute_deadline_ns) != .idle)
            progressed = true;
        if (try self.dispatchOne()) progressed = true;
        if (!progressed) noteIdleTurn(admissions.count, try self.jobs.activeCount());
        return if (progressed) .progressed else .idle;
    }

    /// 한 바퀴가 **아무것도 진행하지 못했을 때** 그 자리의 재고를 남긴다. `turnOne` 은 매 frame 불리므로
    /// 값이 **바뀔 때만** 찍는다 — 정지 상태가 이어지는 동안은 조용하고, 전이 순간에만 한 줄이 남는다.
    ///
    /// **`admissions` 가 0 이 아닌데 `jobs` 가 0 이면 그 사이가 끊긴 것이다.** 2026-09-03 네 번째 정지
    /// 실측에서 incident 는 `disposition=reconnect`·`sequence=1` 로 admission 조건을 만족했고 소켓도 살아
    /// 있었는데 job 시작 진단이 한 줄도 남지 않았다. admission 이 애초에 안 만들어진 것인지, 만들어졌지만
    /// dispatch 가 집어가지 못한 것인지 가릴 수단이 없어 원인을 좁히지 못했다.
    ///
    /// **(0,0) 으로 돌아온 순간도 남긴다(`reconnect turn drained`).** 2026-10-04 23:43 사고에서 `jobs=1` 한 줄 뒤 50분이
    /// 조용했는데, job 이 아직 살아 있는지 이미 끝났는지를 로그로 가릴 수 없었다 — 끝나는 전이를 찍지 않았기 때문이다.
    fn noteIdleTurn(admission_count: u32, active_jobs: usize) void {
        if (builtin.is_test) return;
        const Last = struct {
            var tracker: failure_log.IdleTracker = .{};
        };
        const prev_admissions = Last.tracker.admissions orelse 0;
        const prev_jobs = Last.tracker.jobs orelse 0;
        switch (Last.tracker.note(admission_count, active_jobs)) {
            .none => {},
            .idle => std.log.warn("reconnect turn idle: admissions={d} jobs={d}", .{ admission_count, active_jobs }),
            .drained => logLine(.info, failure_log.writeDrained, .{ prev_admissions, prev_jobs }),
        }
    }

    fn nowNs(self: *const Coordinator) i128 {
        return std.Io.Clock.awake.now(self.worker.io).nanoseconds;
    }

    /// 재시도 없이 입장을 정산한 job 을 한 줄로 남긴다. 예전에는 이 갈래가 결속만 풀고 조용히 끝나, 재접속이
    /// 영영 멈춰도 로그에 아무것도 없었다(2026-10-04).
    fn noteEnded(self: *Coordinator, snapshot: owner_mod.Snapshot, outcome: []const u8) void {
        const now = self.nowNs();
        const summary = self.streaks.end(snapshot.host_id, snapshot.connection_generation, now);
        if (builtin.is_test) return;
        logLine(.warn, failure_log.writeEnded, .{failure_log.Ended{
            .host_id = snapshot.host_id,
            .outcome = outcome,
            .attempt = self.last_attempt,
            .summary = summary,
            .deadline_remaining_ms = failure_log.deadlineRemainingMs(snapshot.absolute_deadline_ns, now),
        }});
    }

    /// 같은 신원을 새 데드라인·대기로 다시 넣었다. 루프가 돌 수 있어 1초에 한 줄로 묶는다.
    fn noteRequeued(self: *Coordinator, snapshot: owner_mod.Snapshot, outcome: []const u8, backoff_ns: u64) void {
        const now = self.nowNs();
        const attempts = self.streaks.requeue(snapshot.host_id, snapshot.connection_generation);
        const suppressed = self.requeue_rate.admit(now) orelse return;
        if (builtin.is_test) return;
        logLine(.info, failure_log.writeRequeued, .{failure_log.Requeued{
            .host_id = snapshot.host_id,
            .outcome = outcome,
            .attempt = self.last_attempt,
            .attempts = attempts,
            .retry_in_ms = backoff_ns / std.time.ns_per_ms,
            .deadline_remaining_ms = failure_log.deadlineRemainingMs(snapshot.absolute_deadline_ns, now),
            .suppressed = suppressed,
        }});
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
                self.streaks.begin(snapshot.host_id, snapshot.connection_generation, self.nowNs());
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
        // 다시 넣은 job 은 대기가 끝나야 나간다(`deferQueued`). 대기 중인 job 만 남았으면 이번 turn 은 쉰다.
        self.jobs.claimReady(&self.job_receipt, self.nowNs()) catch |err| switch (err) {
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
        self.last_attempt = completion.attempt();
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

    /// Settles a retained non-connected result only after every bound resident admission can be
    /// released as one no-fail suffix. The logical receipt is the last owner consumed.
    pub fn settleLogicalCompletion(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        budget: *budget_mod.ReconnectAdmissionBudget,
    ) !owner_mod.Outcome {
        try self.validate();
        const completion = try self.logicalCompletion();
        if (completion.outcome == .connected) return error.InvalidOutcome;
        const outcome = completion.outcome;
        const snapshot = completion.snapshot;
        // 다시 넣는 갈래(2026-10-07). 잠자기·DarkWake 로 5 초 안에 연결을 못 마친 것(`deadline_exceeded`)을 영구 실패로
        // 굳히면, poison 은 연결마다 첫 번만 admission 을 만드므로 앱을 다시 띄울 때까지 안 붙는다. 그래서 시간 초과는
        // 끝없이, 그 밖의 실패(`retry_later` — manifest 없음 등)는 연속 상한까지만 다시 걸고, 상한을 넘거나 `host_gone`·
        // `cancelled` 면 아래 종결로 간다(`reconnect_retry_policy.zig`). 다시 넣을 때 데드라인을 **새로** 주지 않으면 처음
        // 받은 5 초를 끌고 가 연결도 안 해 보고 끝난다 — 신원은 그대로, 데드라인과 대기만 바꾼다. runtime 에 묶인 admission
        // 신원(`matchesBoundReconnectIdentity`)에는 데드라인이 없어 결속·resident lease 는 그대로 유효하다.
        const retry_kind: ?retry_policy.Failure = switch (outcome) {
            .deadline_exceeded => .timeout,
            .retry_later => .other,
            else => null,
        };
        const retries: ?u32 = if (retry_kind) |kind| self.retry_streak.fail(snapshot.host_id, kind) else null;
        if (retries) |retry_number| {
            try self.consumeLogicalCompletion();
            const retry = retry_policy.schedule(self.nowNs(), attach_phase_deadline.budget_ns, retry_number);
            var next = snapshot;
            next.absolute_deadline_ns = retry.absolute_deadline_ns;
            const key = switch (try self.jobs.admit(next)) {
                .admitted => |value| value,
                .coalesced => return error.InvalidCoordinator,
            };
            try self.jobs.deferQueued(key, next, retry.not_before_ns);
            self.noteRequeued(next, @tagName(outcome), retry.backoff_ns);
            return outcome;
        }
        self.retry_streak.reset(snapshot.host_id);
        try backend.settleBoundReconnectSnapshot(completion.snapshot, budget);
        try self.consumeLogicalCompletion();
        self.noteEnded(snapshot, @tagName(outcome));
        return outcome;
    }

    /// Moves a connected candidate into the existing CR5 final-address job. All admission rows
    /// are preflighted before `takeClient`; after a successful move the lease release and both
    /// physical/logical receipt consumptions are a forward-only suffix.
    pub fn settleConnectedCompletion(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        budget: *budget_mod.ReconnectAdmissionBudget,
    ) !ConnectedSettlement {
        try self.validate();
        if (!std.meta.eql(self.completion_receipt, owner_mod.CompletionReceipt{}))
            return error.InvalidCoordinator;
        const completion = try self.claimedPhysicalCompletion();
        if (!sameOrder(completion.order, self.job_receipt) or try completion.outcome() != .connected)
            return error.InvalidOutcome;
        const snapshot = self.job_receipt.snapshot;
        try backend.preflightBoundReconnectSnapshotSettlement(snapshot, budget);
        var candidate = try completion.takeClient();
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const adopted = backend.adoptReconnectCoordinatorCandidate(snapshot, &candidate);
        const logical_outcome: owner_mod.Outcome = switch (adopted) {
            .connected => blk: {
                candidate_owned = false;
                self.retry_streak.reset(snapshot.host_id);
                break :blk .connected;
            },
            .busy, .invalid_authority, .failed => blk: {
                // 연결은 됐는데 채택을 못 했다 — 다시 넣기 줄에 그 사유를 싣는다.
                self.last_attempt.detail = switch (adopted) {
                    .busy => .adopt_busy,
                    .invalid_authority => .adopt_invalid_authority,
                    else => .adopt_failed,
                };
                break :blk .retry_later;
            },
        };
        try self.finishConnected(logical_outcome);
        if (logical_outcome == .connected) return .adopted;
        _ = try self.settleLogicalCompletion(backend, budget);
        return .retry_later;
    }

    /// Drives one CR5 state per call. Only a terminal summary opens the all-runtime admission
    /// release; completed jobs are reclaimed, while CR5c retained-terminal jobs stay backend-owned.
    pub fn progressConnectedOne(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        budget: *budget_mod.ReconnectAdmissionBudget,
    ) !ConnectedProgress {
        try self.validate();
        const completion = try self.logicalCompletion();
        if (completion.outcome != .connected) return error.InvalidOutcome;
        return switch (try backend.progressHostReconnectOne()) {
            .advanced => .advanced,
            .retry_later => .retry_later,
            .completed_ready, .retained_terminal_ready => |progress| blk: {
                const terminal = try backend.preflightHostReconnectTerminal();
                if ((progress == .completed_ready) != (terminal == .completed))
                    return error.InvalidCoordinator;
                try backend.preflightBoundReconnectSnapshotSettlement(completion.snapshot, budget);
                const snapshot = completion.snapshot;
                backend.settleBoundReconnectSnapshotNoFail(completion.snapshot, budget);
                if (terminal == .completed) backend.finalizeCompletedHostReconnectNoFail();
                try self.consumeLogicalCompletion();
                // 성공은 `reconnect job connected` 가 이미 남긴다 — 칸만 비운다. retained_terminal 은 연결 뒤
                // 일부 runtime 이 남은 채 끝난 것이라 실패 줄로 남긴다.
                if (terminal == .completed)
                    _ = self.streaks.end(snapshot.host_id, snapshot.connection_generation, self.nowNs())
                else
                    self.noteEnded(snapshot, "retained_terminal");
                break :blk if (terminal == .completed) .completed else .retained_terminal;
            },
        };
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

    /// Product Quit variant. Every c1 slot admitted by `admitOne` has a bound backend lease, so
    /// cancellation must settle that authority before the generic owners can be destroyed.
    pub fn shutdownProductAndDeinit(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        budget: *budget_mod.ReconnectAdmissionBudget,
    ) !void {
        try self.validate();
        try backend.validateReconnectCoordinatorTarget();
        try self.jobs.requestCancelAll();
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
            try self.settleProductShutdownCompletion(backend, budget);
        while (true) {
            self.jobs.takeCompletion(&self.completion_receipt) catch |err| switch (err) {
                error.NotFound => break,
                else => return err,
            };
            try self.settleProductShutdownCompletion(backend, budget);
        }
        try self.worker.deinit();
        try self.jobs.deinit();
        self.* = .{};
    }

    fn settleProductShutdownCompletion(
        self: *Coordinator,
        backend: *backend_mod.RemoteTermBackend,
        budget: *budget_mod.ReconnectAdmissionBudget,
    ) !void {
        const completion = try self.logicalCompletion();
        try backend.preflightBoundReconnectSnapshotSettlement(completion.snapshot, budget);
        if (completion.outcome == .connected)
            backend.cancelHostReconnectForProcessShutdownNoFail();
        backend.settleBoundReconnectSnapshotNoFail(completion.snapshot, budget);
        try self.consumeLogicalCompletion();
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

/// 진단 한 줄을 스택 버퍼에 서식해 남긴다. 이벤트(정산·전이) 때만 불린다 — 매 frame 경로에는 없다.
fn logLine(comptime level: std.log.Level, comptime write: anytype, args: anytype) void {
    var buf: [384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    @call(.auto, write, .{&w} ++ args) catch {};
    const line = w.buffered();
    switch (level) {
        .err => std.log.err("{s}", .{line}),
        .warn => std.log.warn("{s}", .{line}),
        .info => std.log.info("{s}", .{line}),
        .debug => std.log.debug("{s}", .{line}),
    }
}

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
    try admitFixture(&admissions, 1, 3, connection_generation, 1);
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
    try admitFixture(&admissions, 1, 3, connection_generation, 2);
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

test "CR6e-c3b2b deadline failure requeues with a fresh deadline and a bounded run of other failures releases every bound admission" {
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
    defer budget.deinit() catch @panic("c3b2b budget leak");
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(std.testing.allocator, std.testing.io, "/tmp", identity.process_nonce);
    defer coordinator.shutdownAndDeinit() catch @panic("c3b2b coordinator shutdown failed");
    const connection_generation = fixture.adapter.connectionGeneration();
    try admitFixture(&admissions, 1, 3, connection_generation, 1);
    const now = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try std.testing.expectEqual(
        AdmissionResult.admitted,
        try coordinator.admitOne(&backend, &admissions, &budget, @intCast(@max(1, now - 1))),
    );
    try std.testing.expect(try coordinator.dispatchOne());
    while (try coordinator.pollCompletion() == .idle) std.Thread.yield() catch {};
    // 2026-10-07: 데드라인 초과는 영구 실패가 아니다 — 결속을 그대로 둔 채 **새 데드라인**과 대기로 다시 넣는다.
    try std.testing.expectEqual(
        owner_mod.Outcome.deadline_exceeded,
        try coordinator.settleLogicalCompletion(&backend, &budget),
    );
    try std.testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
    try std.testing.expect(remote_runtime.testing_api.hasChargedReconnectAdmission(&fixture.runtime));
    try std.testing.expectError(error.NotFound, coordinator.logicalCompletion());
    try std.testing.expectEqual(@as(usize, 1), try coordinator.jobs.activeCount());
    const requeued = for (coordinator.jobs.slots) |slot| {
        if (slot.state == .queued) break slot;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(requeued.not_before_ns > coordinator.nowNs());
    try std.testing.expect(@as(i128, requeued.snapshot.absolute_deadline_ns) >=
        requeued.not_before_ns + attach_phase_deadline.budget_ns);
    // 대기 중에는 worker 로 안 나간다.
    try std.testing.expect(!try coordinator.dispatchOne());

    // 대기를 끝낸 것으로 치고 다시 보낸다. 이 host 는 실재하지 않아 매번 manifest 가 없다 — 재접속 worker 의
    // 기존 host 연결 경로는 그것을 `host_gone` 이 아니라 `invalid_manifest`(→ `retry_later`)로 낸다. 시간 초과가
    // 아닌 실패라 연속 상한(`max_other_failures`)까지만 다시 넣고, 그다음은 모든 결속을 풀고 끝난다 — 상한이 없으면
    // 사라진 host 를 영원히 두드린다.
    var other_attempts: u32 = 0;
    while (try coordinator.jobs.activeCount() != 0) {
        if (other_attempts > retry_policy.max_other_failures) return error.TestUnexpectedResult;
        for (&coordinator.jobs.slots) |*slot| {
            if (slot.state == .queued) slot.not_before_ns = 0;
        }
        try std.testing.expect(try coordinator.dispatchOne());
        while (try coordinator.pollCompletion() == .idle) std.Thread.yield() catch {};
        try std.testing.expectEqual(
            owner_mod.Outcome.retry_later,
            try coordinator.settleLogicalCompletion(&backend, &budget),
        );
        other_attempts += 1;
        if (other_attempts <= retry_policy.max_other_failures) {
            // 상한 전에는 결속·lease 를 쥔 채 대기 중이다.
            try std.testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
            try std.testing.expect(!try coordinator.dispatchOne());
        }
    }
    try std.testing.expectEqual(retry_policy.max_other_failures + 1, other_attempts);
    try std.testing.expectEqual(@as(usize, 0), (try budget.snapshot()).live_entries);
    try std.testing.expect(!remote_runtime.testing_api.hasChargedReconnectAdmission(&fixture.runtime));
    try std.testing.expectError(error.NotFound, coordinator.logicalCompletion());
}

test "CR6e-c3b2b coordinator adopts an actual daemon candidate through terminal settlement" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try backend_mod.RemoteTermBackend.testing_api.runActualReconnectCoordinatorFixture(
        actualReconnectCoordinatorHook,
    );
}

fn actualReconnectCoordinatorHook(
    backend: *backend_mod.RemoteTermBackend,
    fixture: backend_mod.RemoteTermBackend.testing_api.ActualReconnectFixture,
) !void {
    const host_adapter = @import("host_adapter.zig");
    try host_adapter.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var admissions: admission_mod.Owner = .{};
    try admissions.initInPlace(identity.process_nonce);
    var budget: budget_mod.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    defer budget.deinit() catch @panic("c3b2b actual budget leak");
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(
        std.testing.allocator,
        std.testing.io,
        fixture.cache_base,
        identity.process_nonce,
    );
    defer coordinator.shutdownAndDeinit() catch @panic("c3b2b actual coordinator shutdown failed");
    try admitFixture(
        &admissions,
        fixture.host_id,
        fixture.host_adapter_generation,
        fixture.connection_generation,
        1,
    );
    try std.testing.expectEqual(
        AdmissionResult.admitted,
        try coordinator.admitOne(backend, &admissions, &budget, std.math.maxInt(u64)),
    );
    try std.testing.expect(try coordinator.dispatchOne());
    var poll: PollResult = .idle;
    for (0..100_000) |_| {
        poll = try coordinator.pollCompletion();
        if (poll != .idle) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(PollResult.connected_ready, poll);
    try std.testing.expectEqual(
        ConnectedSettlement.adopted,
        try coordinator.settleConnectedCompletion(backend, &budget),
    );
    // CR6e-c3b2c: host admission 하나 = resident charge 하나. fixture 는 한 host 에 runtime 셋(handle 1·2·3)을
    // spawn 하므로 anchor(handle 최솟값 1)만 charge 를 쥐고 2·3 은 identity-only 다(예전에는 3).
    const remote_runtime = @import("remote_runtime.zig");
    try std.testing.expectEqual(@as(usize, 1), (try budget.snapshot()).live_entries);
    try std.testing.expect(remote_runtime.testing_api.hasChargedReconnectAdmission(backend.runtimes.get(1).?.runtime));
    for ([_]u64{ 2, 3 }) |sibling| {
        const runtime = backend.runtimes.get(sibling).?.runtime;
        try std.testing.expect(!remote_runtime.testing_api.hasChargedReconnectAdmission(runtime));
        try std.testing.expect(remote_runtime.testing_api.hasIdentityOnlyReconnectAdmission(runtime));
    }
    var terminal: ?ConnectedProgress = null;
    for (0..100_000) |_| {
        const progress = try coordinator.progressConnectedOne(backend, &budget);
        switch (progress) {
            .advanced, .retry_later => std.Thread.yield() catch {},
            .completed, .retained_terminal => {
                terminal = progress;
                break;
            },
        }
    }
    try std.testing.expectEqual(ConnectedProgress.completed, terminal orelse
        return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 0), (try budget.snapshot()).live_entries);
    try std.testing.expectError(error.NotFound, coordinator.logicalCompletion());
}

test "CR6e-c3c app-global turn drives an actual daemon candidate to terminal settlement" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try backend_mod.RemoteTermBackend.testing_api.runActualReconnectCoordinatorFixture(
        actualProductTurnHook,
    );
}

fn actualProductTurnHook(
    backend: *backend_mod.RemoteTermBackend,
    fixture: backend_mod.RemoteTermBackend.testing_api.ActualReconnectFixture,
) !void {
    const host_adapter = @import("host_adapter.zig");
    try host_adapter.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var admissions: admission_mod.Owner = .{};
    try admissions.initInPlace(identity.process_nonce);
    var budget: budget_mod.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    defer budget.deinit() catch @panic("c3c actual turn budget leak");
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(
        std.testing.allocator,
        std.testing.io,
        fixture.cache_base,
        identity.process_nonce,
    );
    defer if (coordinator.ready)
        coordinator.shutdownProductAndDeinit(backend, &budget) catch
            @panic("c3c actual turn coordinator shutdown failed");
    try admitFixture(
        &admissions,
        fixture.host_id,
        fixture.host_adapter_generation,
        fixture.connection_generation,
        1,
    );
    var completed = false;
    for (0..100_000) |_| {
        _ = try coordinator.turnOne(
            backend,
            &admissions,
            &budget,
            std.math.maxInt(u64),
        );
        if ((try budget.snapshot()).live_entries == 0 and
            try coordinator.jobs.activeCount() == 0)
        {
            completed = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(usize, 0), (try budget.snapshot()).live_entries);
    try coordinator.shutdownProductAndDeinit(backend, &budget);
}

test "CR6e-c3c Quit cancels an actual mid-CR5 job before releasing its admission" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try backend_mod.RemoteTermBackend.testing_api.runActualReconnectCoordinatorFixture(
        actualProductQuitHook,
    );
}

fn actualProductQuitHook(
    backend: *backend_mod.RemoteTermBackend,
    fixture: backend_mod.RemoteTermBackend.testing_api.ActualReconnectFixture,
) !void {
    const host_adapter = @import("host_adapter.zig");
    try host_adapter.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var admissions: admission_mod.Owner = .{};
    try admissions.initInPlace(identity.process_nonce);
    var budget: budget_mod.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    defer budget.deinit() catch @panic("c3c actual Quit budget leak");
    var coordinator: Coordinator = .{};
    try coordinator.initInPlace(
        std.testing.allocator,
        std.testing.io,
        fixture.cache_base,
        identity.process_nonce,
    );
    try admitFixture(
        &admissions,
        fixture.host_id,
        fixture.host_adapter_generation,
        fixture.connection_generation,
        1,
    );
    try std.testing.expectEqual(
        AdmissionResult.admitted,
        try coordinator.admitOne(backend, &admissions, &budget, std.math.maxInt(u64)),
    );
    try std.testing.expect(try coordinator.dispatchOne());
    var poll: PollResult = .idle;
    for (0..100_000) |_| {
        poll = try coordinator.pollCompletion();
        if (poll != .idle) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(PollResult.connected_ready, poll);
    try std.testing.expectEqual(
        ConnectedSettlement.adopted,
        try coordinator.settleConnectedCompletion(backend, &budget),
    );
    try std.testing.expectEqual(
        ConnectedProgress.advanced,
        try coordinator.progressConnectedOne(backend, &budget),
    );
    try coordinator.shutdownProductAndDeinit(backend, &budget);
    try std.testing.expect(!coordinator.ready);
    try std.testing.expectEqual(@as(usize, 0), (try budget.snapshot()).live_entries);
}

fn admitFixture(
    admissions: *admission_mod.Owner,
    host_id: u128,
    host_adapter_generation: u64,
    connection_generation: u64,
    sequence: u64,
) !void {
    const publication = @import("maru").observability.incident_publication_contract;
    const incident = @import("maru").observability.connection_incident;
    const input: publication.IncidentInput = .{
        .timestamp_ns = sequence,
        .host_id = host_id,
        .host_adapter_generation = host_adapter_generation,
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
