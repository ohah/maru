//! Daemon-owned live-upgrade attempt SSOT(U5-A).
//!
//! Socket handler는 borrowed request를 여기서 deep-copy해 pending으로 stage하고, accepted reply 전량 write 뒤 같은
//! attempt만 arm한다. Quiesce/exec는 connection admission lease 밖의 daemon loop가 `beginExecution`으로 시작한다.

const std = @import("std");
const wire = @import("upgrade_wire.zig");
const attempt_record = @import("upgrade_attempt_record.zig");
const limits = @import("upgrade_limits.zig");

pub const BusyProbe = struct {
    ctx: *anyopaque,
    is_busy: *const fn (ctx: *anyopaque) bool,
};

pub const StagedArtifact = struct {
    path: [:0]u8,
    /// 검증과 exact cleanup 동안 staged executable inode를 pin한다. macOS 공개 API에는 fd-based exec가 없으므로
    /// 실제 실행 권위가 아니라 마지막 path 재검증과 cleanup generation 대조용이다.
    exec_fd: i32,
    sha256: [32]u8,
    dev: i64,
    ino: u64,
    size: u64,
};

pub const VerifiedTarget = struct {
    artifact: StagedArtifact,
    build_id: []u8,
    reader_min: u16,
    reader_max: u16,
};

pub const RecordedTarget = struct {
    staged_path: []const u8,
    build_id: []const u8,
    sha256: [32]u8,
    dev: i64,
    ino: u64,
    size: u64,
    reader_min: u16,
    reader_max: u16,
};

pub const StageDecision = union(enum) {
    verified: VerifiedTarget,
    invalid_target,
    unsupported,
    resource_exhausted,
};

pub const TargetStager = struct {
    ctx: *anyopaque,
    stage: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: wire.PrepareRequest,
    ) StageDecision,
    /// Exec 뒤 staged target path를 다시 열어 기록된 inode/hash에 결합한 새 CLOEXEC pin을 만든다.
    restore: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        recorded: RecordedTarget,
    ) StageDecision,
    release_artifact: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        artifact: *StagedArtifact,
    ) void,
    /// accepted 이후 exec 직전 staged leaf가 여전히 같은 inode/hash인지 재검증한다.
    verify: *const fn (ctx: *anyopaque, target: VerifiedTarget) bool,
};

pub const Execution = struct {
    attempt_id: u128,
    request_path: []const u8,
    /// `finish` 전까지만 유효한 borrowed slice와 borrowed `exec_fd`를 포함한다. Caller는 fd를 닫거나 flags/offset을
    /// 바꾸지 않으며, 실제 exec 직전에 `revalidateExecution`을 다시 통과해야 한다. `finish`가 exact-once로 회수한다.
    target: VerifiedTarget,
};

const Phase = enum { staged, armed, running, finishing };
pub const RestoreRole = @import("entrypoint.zig").RestoreRole;
pub const HandoffCopy = enum { primary, backup };
pub const RestoreToken = struct {
    host_id: u128,
    attempt_id: u128,
    copy: HandoffCopy,
    role: RestoreRole,
};

/// Exec bootstrap이 typed role, exact attempt ID, inherited handoff copy role을 함께 검증한 뒤에만 발급한다.
pub fn validateRestoreEntry(
    state: attempt_record.State,
    role: RestoreRole,
    attempt_id: u128,
    copy: HandoffCopy,
) ?RestoreToken {
    if (state.rollback_budget != 1 or attempt_id != state.attempt_id) return null;
    if (role == .target and copy == .primary)
        return .{
            .host_id = state.host_id,
            .attempt_id = state.attempt_id,
            .copy = copy,
            .role = .target,
        };
    if (role == .rollback and copy == .backup)
        return .{
            .host_id = state.host_id,
            .attempt_id = state.attempt_id,
            .copy = copy,
            .role = .rollback,
        };
    return null;
}

const Attempt = struct {
    id: u128,
    request_path: []u8,
    target: VerifiedTarget,
    phase: Phase = .staged,
    report: wire.AttemptReport = .{ .status = .pending },
    restored_role: ?RestoreRole = null,
};

pub const UpgradeOwner = struct {
    /// Host lifetime idempotency를 위해 완료 ID를 eviction하지 않는다. 상한에 닿으면 새 실행을 거부해 과거 ID가 다시
    /// 실행되는 것보다 fail-closed한다.
    const max_completed = limits.max_completed_history;
    const Completed = struct {
        id: u128,
        request_path: []u8,
        build_id: []u8,
        sha256: [32]u8,
        reader_min: u16,
        reader_max: u16,
        report: wire.AttemptReport,
    };

    allocator: std.mem.Allocator,
    target_stager: TargetStager,
    busy_probe: ?BusyProbe = null,
    attempt: ?Attempt = null,
    completed: [max_completed]Completed = undefined,
    completed_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        target_stager: TargetStager,
        busy_probe: ?BusyProbe,
    ) UpgradeOwner {
        // target_stager.ctx와 그 borrowed state는 이 owner의 deinit이 끝날 때까지 살아 있어야 한다.
        return .{
            .allocator = allocator,
            .target_stager = target_stager,
            .busy_probe = busy_probe,
        };
    }

    pub fn deinit(self: *UpgradeOwner) void {
        if (self.attempt) |*attempt| {
            self.allocator.free(attempt.request_path);
            self.allocator.free(attempt.target.build_id);
            self.target_stager.release_artifact(self.target_stager.ctx, self.allocator, &attempt.target.artifact);
        }
        for (self.completed[0..self.completed_count]) |*completed| {
            self.allocator.free(completed.request_path);
            self.allocator.free(completed.build_id);
        }
        self.* = undefined;
    }

    pub fn ops(self: *UpgradeOwner) wire.Ops {
        return .{
            .ctx = self,
            .stage_pending = stagePendingOpaque,
            .cancel_unaccepted = cancelUnacceptedOpaque,
            .arm_accepted = armAcceptedOpaque,
            .status = statusOpaque,
        };
    }

    /// 같은 ID와 동일 immutable target은 write-failure retry를 위해 idempotent하게 accepted한다. 다른 ID나 같은
    /// ID의 다른 target은 기존 attempt 실행 권위를 바꾸지 않고 conflict다.
    pub fn stagePending(self: *UpgradeOwner, candidate: wire.PrepareRequest) wire.PrepareDecision {
        if (self.attempt) |attempt| {
            if (!sameRequest(attempt, candidate)) return .conflict;
            return switch (attempt.phase) {
                .staged, .armed => .accepted,
                .running, .finishing => .conflict,
            };
        }
        for (self.completed[0..self.completed_count]) |completed| {
            if (completed.id != candidate.attempt_id) continue;
            return if (completedMatches(completed, candidate))
                .{ .completed = completed.report }
            else
                .conflict;
        }
        if (self.completed_count == max_completed) return .resource_exhausted;
        if (self.busy_probe) |probe| {
            if (probe.is_busy(probe.ctx)) return .busy;
        }
        var target = switch (self.target_stager.stage(self.target_stager.ctx, self.allocator, candidate)) {
            .verified => |verified| verified,
            .invalid_target => return .invalid_target,
            .unsupported => return .unsupported,
            .resource_exhausted => return .resource_exhausted,
        };
        const request_path = self.allocator.dupe(u8, candidate.target_path) catch {
            self.allocator.free(target.build_id);
            self.target_stager.release_artifact(self.target_stager.ctx, self.allocator, &target.artifact);
            return .resource_exhausted;
        };
        self.attempt = .{
            .id = candidate.attempt_id,
            .request_path = request_path,
            .target = target,
        };
        return .accepted;
    }

    pub fn cancelUnaccepted(self: *UpgradeOwner, attempt_id: u128) void {
        const attempt = if (self.attempt) |value| value else return;
        if (attempt.id != attempt_id or attempt.phase != .staged) return;
        self.allocator.free(attempt.request_path);
        var target = attempt.target;
        self.allocator.free(target.build_id);
        self.target_stager.release_artifact(self.target_stager.ctx, self.allocator, &target.artifact);
        self.attempt = null;
    }

    pub fn armAccepted(self: *UpgradeOwner, attempt_id: u128) wire.ArmDecision {
        const attempt = if (self.attempt) |*value| value else return .not_pending;
        if (attempt.id != attempt_id) return .conflict;
        switch (attempt.phase) {
            .staged => attempt.phase = .armed,
            .armed => {},
            .running, .finishing => return .conflict,
        }
        return .armed;
    }

    /// SocketServer가 connection cleanup 뒤 돌려준 exact marker와 owner의 armed state가 모두 맞을 때만 실행권을 한 번
    /// 발급한다. 반환 view는 `finish` 전까지만 유효하며 executor는 exec 전에 필요한 argv를 별도 소유해야 한다.
    pub fn beginExecution(self: *UpgradeOwner, attempt_id: u128) ?Execution {
        const attempt = if (self.attempt) |*value| value else return null;
        if (attempt.id != attempt_id or attempt.phase != .armed) return null;
        if (!self.target_stager.verify(self.target_stager.ctx, attempt.target)) {
            attempt.phase = .running;
            const recorded = self.finish(attempt_id, .{
                .status = .resumed,
                .reason = .target_invalid,
            });
            std.debug.assert(recorded);
            return null;
        }
        attempt.phase = .running;
        return .{
            .attempt_id = attempt.id,
            .request_path = attempt.request_path,
            .target = attempt.target,
        };
    }

    /// beginExecution 뒤 fd/argv 준비 중 path 교체가 없었는지 실제 exec syscall 직전에 재검증하는 마지막 gate다.
    pub fn revalidateExecution(self: *const UpgradeOwner, execution: Execution) bool {
        const attempt = if (self.attempt) |value| value else return false;
        if (attempt.id != execution.attempt_id or attempt.phase != .running) return false;
        return self.target_stager.verify(self.target_stager.ctx, attempt.target);
    }

    pub fn runningExecution(self: *const UpgradeOwner, attempt_id: u128) ?Execution {
        const attempt = self.attempt orelse return null;
        if (attempt.id != attempt_id or attempt.phase != .running) return null;
        return .{
            .attempt_id = attempt.id,
            .request_path = attempt.request_path,
            .target = attempt.target,
        };
    }

    /// Exec를 넘어 active authority와 host-lifetime completed idempotency ledger를 함께 보존한다. runtime_ids는
    /// caller가 stable sort한 exact graph set이어야 한다. rollback budget은 동일한 primary/backup record에 불변으로 남는다.
    pub fn encodeRunningRecord(
        self: *const UpgradeOwner,
        allocator: std.mem.Allocator,
        execution: Execution,
        host_id: u128,
        epoch_before: u64,
        rollback_image: attempt_record.ImageView,
        runtime_ids: []const u128,
    ) attempt_record.Error![]u8 {
        const active = if (self.attempt) |value| value else return error.InvalidValue;
        if (active.id != execution.attempt_id or active.phase != .running) return error.InvalidValue;
        var completed_views: [max_completed]attempt_record.CompletedView = undefined;
        for (self.completed[0..self.completed_count], 0..) |entry, index| {
            completed_views[index] = .{
                .attempt_id = entry.id,
                .request_path = entry.request_path,
                .build_id = entry.build_id,
                .sha256 = entry.sha256,
                .reader_min = entry.reader_min,
                .reader_max = entry.reader_max,
                .report = entry.report,
            };
        }
        const expected_epoch = std.math.add(u64, epoch_before, 1) catch return error.InvalidValue;
        return attempt_record.encode(allocator, .{
            .host_id = host_id,
            .attempt_id = active.id,
            .epoch_before = epoch_before,
            .expected_epoch_after = expected_epoch,
            .rollback_budget = 1,
            .request_path = active.request_path,
            .staged_path = active.target.artifact.path,
            .build_id = active.target.build_id,
            .sha256 = active.target.artifact.sha256,
            .dev = active.target.artifact.dev,
            .ino = active.target.artifact.ino,
            .size = active.target.artifact.size,
            .rollback_image = rollback_image,
            .reader_min = active.target.reader_min,
            .reader_max = active.target.reader_max,
            .runtime_ids = runtime_ids,
            .completed = completed_views[0..self.completed_count],
        });
    }

    pub const RestoreError = error{ NotEmpty, InvalidState, OutOfMemory };
    pub const RestoreContext = struct {
        host_id: u128,
        host_epoch: u64,
        runtime_ids: []const u128,
        token: RestoreToken,
    };

    /// Target/rollback entry가 handoff decode와 inherited target fd 검증을 마친 뒤 owner authority를 원자적으로
    /// 재구성한다. target pin은 상속하지 않고 기록된 staged path를 다시 열어 검증한다.
    pub fn restoreRunningRecord(
        self: *UpgradeOwner,
        state: attempt_record.State,
        expected: RestoreContext,
    ) RestoreError!void {
        if (self.attempt != null or self.completed_count != 0) return error.NotEmpty;
        attempt_record.validateDecoded(state) catch return error.InvalidState;
        if (state.host_id != expected.host_id or
            expected.token.host_id != state.host_id or
            expected.token.attempt_id != state.attempt_id or
            (expected.token.role == .target and expected.token.copy != .primary) or
            (expected.token.role == .rollback and expected.token.copy != .backup) or
            state.epoch_before != expected.host_epoch or
            !std.mem.eql(u128, state.runtime_ids, expected.runtime_ids) or
            state.rollback_budget != 1)
            return error.InvalidState;
        const restored_target = self.target_stager.restore(self.target_stager.ctx, self.allocator, .{
            .staged_path = state.staged_path,
            .build_id = state.build_id,
            .sha256 = state.sha256,
            .dev = state.dev,
            .ino = state.ino,
            .size = state.size,
            .reader_min = state.reader_min,
            .reader_max = state.reader_max,
        });
        const target = switch (restored_target) {
            .verified => |value| value,
            .resource_exhausted => return error.OutOfMemory,
            else => if (expected.token.role == .rollback)
                try detachedRecordedTarget(self.allocator, state)
            else
                return error.InvalidState,
        };
        var target_owned = true;
        errdefer if (target_owned) {
            self.allocator.free(target.build_id);
            var artifact = target.artifact;
            self.target_stager.release_artifact(self.target_stager.ctx, self.allocator, &artifact);
        };
        if (!targetMatchesRecord(target, state) or
            (expected.token.role == .target and
                !self.target_stager.verify(self.target_stager.ctx, target)))
            return error.InvalidState;
        const request_path = self.allocator.dupe(u8, state.request_path) catch return error.OutOfMemory;
        errdefer self.allocator.free(request_path);

        var restored: [max_completed]Completed = undefined;
        var restored_count: usize = 0;
        errdefer for (restored[0..restored_count]) |entry| {
            self.allocator.free(entry.request_path);
            self.allocator.free(entry.build_id);
        };
        for (state.completed) |entry| {
            const completed_path = self.allocator.dupe(u8, entry.request_path) catch return error.OutOfMemory;
            errdefer self.allocator.free(completed_path);
            const completed_build = self.allocator.dupe(u8, entry.build_id) catch return error.OutOfMemory;
            restored[restored_count] = .{
                .id = entry.attempt_id,
                .request_path = completed_path,
                .build_id = completed_build,
                .sha256 = entry.sha256,
                .reader_min = entry.reader_min,
                .reader_max = entry.reader_max,
                .report = entry.report,
            };
            restored_count += 1;
        }
        self.attempt = .{
            .id = state.attempt_id,
            .request_path = request_path,
            .target = target,
            .phase = .running,
            .restored_role = expected.token.role,
        };
        target_owned = false;
        @memcpy(self.completed[0..restored_count], restored[0..restored_count]);
        self.completed_count = restored_count;
    }

    /// Immutable handoff의 rollback budget은 target entry에서만 소비할 수 있다. rollback entry가 다시 실패하면
    /// 재귀 exec하지 않고 non-retryable로 끝낸다.
    pub fn rollbackAllowed(self: *const UpgradeOwner) bool {
        const attempt = self.attempt orelse return false;
        return attempt.restored_role != .rollback;
    }

    /// Manifest/rollback-image activation 전에 terminal transition이 이후
    /// 실패하지 않음을 증명하는 token. `commit`은 allocation이 없고 bool을
    /// 반환하지 않으므로 durable authority가 바뀐 뒤 ledger가 running에
    /// 남는 split-brain을 만들지 않는다.
    pub const PreparedFinish = struct {
        owner: *UpgradeOwner,
        attempt_id: u128,
        report: wire.AttemptReport,
        active: bool = true,

        pub fn commit(self: *PreparedFinish) void {
            if (!self.active) return;
            self.active = false;
            self.owner.commitFinishExact(self.attempt_id, self.report);
        }
    };

    pub fn prepareFinish(
        self: *UpgradeOwner,
        attempt_id: u128,
        report: wire.AttemptReport,
    ) ?PreparedFinish {
        const attempt = if (self.attempt) |*value| value else return null;
        if (!self.finishAllowed(attempt_id, report)) return null;
        attempt.phase = .finishing;
        return .{
            .owner = self,
            .attempt_id = attempt_id,
            .report = report,
        };
    }

    pub fn finish(
        self: *UpgradeOwner,
        attempt_id: u128,
        report: wire.AttemptReport,
    ) bool {
        var prepared = self.prepareFinish(attempt_id, report) orelse return false;
        prepared.commit();
        return true;
    }

    fn finishAllowed(
        self: *const UpgradeOwner,
        attempt_id: u128,
        report: wire.AttemptReport,
    ) bool {
        const attempt = self.attempt orelse return false;
        if (attempt.id != attempt_id or attempt.phase != .running) return false;
        if (!wire.validReport(report) or report.status == .pending) return false;
        if (attempt.restored_role == null and
            report.status != .resumed and
            !(report.status == .failed_nonretryable and
                (report.reason == .authority_poisoned or report.reason == .runtime_resume_failed)))
            return false;
        if (attempt.restored_role == .rollback and report.status != .rolled_back) return false;
        if (attempt.restored_role == .target and
            report.status != .committed and report.status != .failed_nonretryable)
            return false;
        return self.completed_count < max_completed;
    }

    fn commitFinishExact(
        self: *UpgradeOwner,
        attempt_id: u128,
        report: wire.AttemptReport,
    ) void {
        const attempt = if (self.attempt) |*value| value else return;
        if (attempt.id != attempt_id or attempt.phase != .finishing or
            !wire.validReport(report) or report.status == .pending or
            self.completed_count == max_completed)
            return;
        const build_id = attempt.target.build_id;
        const sha256 = attempt.target.artifact.sha256;
        const reader_min = attempt.target.reader_min;
        const reader_max = attempt.target.reader_max;
        var artifact = attempt.target.artifact;
        self.target_stager.release_artifact(self.target_stager.ctx, self.allocator, &artifact);
        self.completed[self.completed_count] = .{
            .id = attempt.id,
            .request_path = attempt.request_path,
            .build_id = build_id,
            .sha256 = sha256,
            .reader_min = reader_min,
            .reader_max = reader_max,
            .report = report,
        };
        self.completed_count += 1;
        self.attempt = null;
    }

    pub fn status(self: *const UpgradeOwner, attempt_id: u128) ?wire.AttemptReport {
        if (self.attempt) |attempt| {
            if (attempt.id == attempt_id) return attempt.report;
        }
        for (self.completed[0..self.completed_count]) |completed|
            if (completed.id == attempt_id) return completed.report;
        return null;
    }

    fn stagePendingOpaque(ctx: *anyopaque, candidate: wire.PrepareRequest) wire.PrepareDecision {
        const self: *UpgradeOwner = @ptrCast(@alignCast(ctx));
        return self.stagePending(candidate);
    }

    fn armAcceptedOpaque(ctx: *anyopaque, attempt_id: u128) wire.ArmDecision {
        const self: *UpgradeOwner = @ptrCast(@alignCast(ctx));
        return self.armAccepted(attempt_id);
    }

    fn cancelUnacceptedOpaque(ctx: *anyopaque, attempt_id: u128) void {
        const self: *UpgradeOwner = @ptrCast(@alignCast(ctx));
        self.cancelUnaccepted(attempt_id);
    }

    fn statusOpaque(ctx: *anyopaque, attempt_id: u128) ?wire.AttemptReport {
        const self: *UpgradeOwner = @ptrCast(@alignCast(ctx));
        return self.status(attempt_id);
    }
};

fn sameRequest(attempt: Attempt, candidate: wire.PrepareRequest) bool {
    return attempt.id == candidate.attempt_id and
        std.mem.eql(u8, attempt.request_path, candidate.target_path) and
        std.mem.eql(u8, attempt.target.build_id, candidate.target_build_id) and
        std.mem.eql(u8, &attempt.target.artifact.sha256, &candidate.target_sha256) and
        attempt.target.reader_min == candidate.handoff_reader_min and
        attempt.target.reader_max == candidate.handoff_reader_max;
}

fn completedMatches(completed: UpgradeOwner.Completed, candidate: wire.PrepareRequest) bool {
    return std.mem.eql(u8, completed.request_path, candidate.target_path) and
        std.mem.eql(u8, completed.build_id, candidate.target_build_id) and
        std.mem.eql(u8, &completed.sha256, &candidate.target_sha256) and
        completed.reader_min == candidate.handoff_reader_min and
        completed.reader_max == candidate.handoff_reader_max;
}

fn targetMatchesRecord(target: VerifiedTarget, state: attempt_record.State) bool {
    return std.mem.eql(u8, target.artifact.path, state.staged_path) and
        std.mem.eql(u8, target.build_id, state.build_id) and
        std.mem.eql(u8, &target.artifact.sha256, &state.sha256) and
        target.artifact.dev == state.dev and
        target.artifact.ino == state.ino and
        target.artifact.size == state.size and
        target.reader_min == state.reader_min and
        target.reader_max == state.reader_max;
}

/// Rollback entry는 backup handoff와 rollback executable만으로 old runtime을
/// 복구할 수 있어야 한다. 실패 원인인 target leaf가 사라졌거나 교체됐으면
/// exact cleanup metadata만 소유하고 실행 pin은 만들지 않는다.
fn detachedRecordedTarget(
    allocator: std.mem.Allocator,
    state: attempt_record.State,
) error{OutOfMemory}!VerifiedTarget {
    const path = allocator.dupeZ(u8, state.staged_path) catch return error.OutOfMemory;
    errdefer allocator.free(path);
    const build_id = allocator.dupe(u8, state.build_id) catch return error.OutOfMemory;
    return .{
        .artifact = .{
            .path = path,
            .exec_fd = -1,
            .sha256 = state.sha256,
            .dev = state.dev,
            .ino = state.ino,
            .size = state.size,
        },
        .build_id = build_id,
        .reader_min = state.reader_min,
        .reader_max = state.reader_max,
    };
}

fn testRequest(id: u128, path: []const u8) wire.PrepareRequest {
    return .{
        .attempt_id = id,
        .target_path = path,
        .target_build_id = "sha256:abababababababababababababababababababababababababababababababab",
        .target_sha256 = [_]u8{0xAB} ** 32,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    };
}

fn testRestoreToken(state: attempt_record.State, role: RestoreRole) RestoreToken {
    return validateRestoreEntry(state, role, state.attempt_id, if (role == .target) .primary else .backup) orelse
        unreachable;
}

fn testRollbackImage() attempt_record.ImageView {
    return .{
        .path = "/tmp/maru/rollback-current",
        .sha256 = [_]u8{0xCD} ** 32,
        .dev = 10,
        .ino = 11,
        .size = 12,
    };
}

const TestStager = struct {
    fn ops() TargetStager {
        return .{
            .ctx = @ptrFromInt(1),
            .stage = stage,
            .restore = restore,
            .release_artifact = releaseArtifact,
            .verify = verify,
        };
    }

    fn stage(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        request: wire.PrepareRequest,
    ) StageDecision {
        const path = std.fmt.allocPrintSentinel(
            allocator,
            "/staged/{x:0>32}",
            .{request.attempt_id},
            0,
        ) catch return .resource_exhausted;
        const build_id = allocator.dupe(u8, request.target_build_id) catch {
            allocator.free(path);
            return .resource_exhausted;
        };
        return .{ .verified = .{
            .artifact = .{
                .path = path,
                .exec_fd = -1,
                .sha256 = request.target_sha256,
                .dev = 7,
                .ino = @truncate(request.attempt_id),
                .size = 4096,
            },
            .build_id = build_id,
            .reader_min = request.handoff_reader_min,
            .reader_max = request.handoff_reader_max,
        } };
    }

    fn restore(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        recorded: RecordedTarget,
    ) StageDecision {
        const path = allocator.dupeZ(u8, recorded.staged_path) catch return .resource_exhausted;
        const build_id = allocator.dupe(u8, recorded.build_id) catch {
            allocator.free(path);
            return .resource_exhausted;
        };
        return .{ .verified = .{
            .artifact = .{
                .path = path,
                .exec_fd = -1,
                .sha256 = recorded.sha256,
                .dev = recorded.dev,
                .ino = recorded.ino,
                .size = recorded.size,
            },
            .build_id = build_id,
            .reader_min = recorded.reader_min,
            .reader_max = recorded.reader_max,
        } };
    }

    fn releaseArtifact(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        artifact: *StagedArtifact,
    ) void {
        allocator.free(artifact.path);
        artifact.* = undefined;
    }

    fn verify(_: *anyopaque, _: VerifiedTarget) bool {
        return true;
    }
};

const RejectingStager = struct {
    fn ops() TargetStager {
        var result = TestStager.ops();
        result.verify = verify;
        return result;
    }

    fn verify(_: *anyopaque, _: VerifiedTarget) bool {
        return false;
    }
};

const MissingRestoreStager = struct {
    fn ops() TargetStager {
        var result = TestStager.ops();
        result.restore = restore;
        return result;
    }

    fn restore(_: *anyopaque, _: std.mem.Allocator, _: RecordedTarget) StageDecision {
        return .invalid_target;
    }
};

test "upgrade owner stages atomically and enforces exact idempotency" {
    var owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(1, "/target-a")));
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(1, "/target-a")));
    try std.testing.expectEqual(wire.PrepareDecision.conflict, owner.stagePending(testRequest(1, "/target-b")));
    try std.testing.expectEqual(wire.PrepareDecision.conflict, owner.stagePending(testRequest(2, "/target-a")));
    try std.testing.expectEqual(wire.AttemptStatus.pending, owner.status(1).?.status);
}

test "upgrade owner requires reply arm before exactly one execution" {
    var owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(7, "/target")));
    try std.testing.expect(owner.beginExecution(7) == null);
    try std.testing.expectEqual(wire.ArmDecision.conflict, owner.armAccepted(8));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(7));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(7));
    const execution = owner.beginExecution(7).?;
    try std.testing.expectEqual(@as(u128, 7), execution.attempt_id);
    try std.testing.expect(owner.beginExecution(7) == null);
    try std.testing.expect(owner.finish(7, .{ .status = .resumed, .reason = .exec_failed }));
    const report = owner.status(7).?;
    try std.testing.expectEqual(wire.AttemptStatus.resumed, report.status);
    try std.testing.expectEqual(wire.AttemptReason.exec_failed, report.reason);
    const replay = owner.stagePending(testRequest(7, "/target"));
    try std.testing.expect(replay == .completed);
    try std.testing.expectEqual(wire.AttemptStatus.resumed, replay.completed.status);
    try std.testing.expectEqual(wire.PrepareDecision.conflict, owner.stagePending(testRequest(7, "/other")));
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(8, "/next")));
}

test "upgrade owner busy probe has no partial attempt side effect" {
    const Probe = struct {
        fn busy(_: *anyopaque) bool {
            return true;
        }
    };
    var marker: u8 = 0;
    var owner = UpgradeOwner.init(
        std.testing.allocator,
        TestStager.ops(),
        .{ .ctx = &marker, .is_busy = Probe.busy },
    );
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.busy, owner.stagePending(testRequest(9, "/target")));
    try std.testing.expect(owner.status(9) == null);
    try std.testing.expectEqual(wire.ArmDecision.not_pending, owner.armAccepted(9));
}

test "upgrade owner cancels undelivered staged attempt and rejects invalid status pairs" {
    var owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(11, "/first")));
    owner.cancelUnaccepted(11);
    try std.testing.expect(owner.status(11) == null);
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(12, "/second")));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(12));
    _ = owner.beginExecution(12).?;
    try std.testing.expect(!owner.finish(12, .{ .status = .committed, .reason = .restore_failed }));
    try std.testing.expect(!owner.finish(12, .{ .status = .committed }));
    try std.testing.expect(owner.finish(12, .{ .status = .resumed, .reason = .exec_failed }));
}

test "upgrade owner prepares a terminal transition before infallible commit" {
    var owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(13, "/target")));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(13));
    _ = owner.beginExecution(13).?;
    try std.testing.expect(owner.prepareFinish(13, .{ .status = .committed }) == null);
    var prepared = owner.prepareFinish(13, .{
        .status = .resumed,
        .reason = .exec_failed,
    }) orelse return error.TestUnexpectedNull;
    // Prepare is validation-only: the running attempt and pending status remain
    // authoritative until the caller durably commits its other resources.
    try std.testing.expectEqual(wire.AttemptStatus.pending, owner.status(13).?.status);
    prepared.commit();
    try std.testing.expectEqual(wire.AttemptStatus.resumed, owner.status(13).?.status);
}

test "upgrade owner prepared finish stale copy cannot terminate a later attempt" {
    var owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(14, "/first")));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(14));
    _ = owner.beginExecution(14).?;
    var prepared = owner.prepareFinish(14, .{
        .status = .resumed,
        .reason = .exec_failed,
    }) orelse return error.TestUnexpectedNull;
    var stale = prepared;
    prepared.commit();

    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(15, "/second")));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(15));
    _ = owner.beginExecution(15).?;
    stale.commit();
    try std.testing.expectEqual(wire.AttemptStatus.pending, owner.status(15).?.status);
    try std.testing.expect(owner.finish(15, .{ .status = .resumed, .reason = .exec_failed }));
}

test "upgrade owner revalidates the exact staged target before execution" {
    var owner = UpgradeOwner.init(std.testing.allocator, RejectingStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(21, "/target")));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(21));
    try std.testing.expect(owner.beginExecution(21) == null);
    const report = owner.status(21).?;
    try std.testing.expectEqual(wire.AttemptStatus.resumed, report.status);
    try std.testing.expectEqual(wire.AttemptReason.target_invalid, report.reason);
}

test "pre-exec owner accepts only explicit authority or runtime fail-stop terminals" {
    var owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, owner.stagePending(testRequest(22, "/target")));
    try std.testing.expectEqual(wire.ArmDecision.armed, owner.armAccepted(22));
    _ = owner.beginExecution(22).?;
    try std.testing.expect(!owner.finish(22, .{
        .status = .failed_nonretryable,
        .reason = .rollback_exec_failed,
    }));
    try std.testing.expect(owner.finish(22, .{
        .status = .failed_nonretryable,
        .reason = .authority_poisoned,
    }));

    var resume_owner = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer resume_owner.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, resume_owner.stagePending(testRequest(23, "/target")));
    try std.testing.expectEqual(wire.ArmDecision.armed, resume_owner.armAccepted(23));
    _ = resume_owner.beginExecution(23).?;
    try std.testing.expect(resume_owner.finish(23, .{
        .status = .failed_nonretryable,
        .reason = .runtime_resume_failed,
    }));
}

test "upgrade owner record survives exec and restores active plus completed idempotency authority" {
    var old = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer old.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(testRequest(30, "/old")));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(30));
    _ = old.beginExecution(30).?;
    try std.testing.expect(old.finish(30, .{ .status = .resumed, .reason = .exec_failed }));
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(testRequest(31, "/active")));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(31));
    const execution = old.beginExecution(31).?;
    const bytes = try old.encodeRunningRecord(
        std.testing.allocator,
        execution,
        0xAA,
        9,
        testRollbackImage(),
        &.{ 0xA, 0xB },
    );
    defer std.testing.allocator.free(bytes);
    var state = try attempt_record.decode(std.testing.allocator, bytes);
    defer state.deinit();

    var restored = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer restored.deinit();
    var rejected = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer rejected.deinit();
    try std.testing.expectError(error.InvalidState, rejected.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 8,
        .runtime_ids = &.{ 0xA, 0xB },
        .token = testRestoreToken(state, .target),
    }));
    try restored.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 9,
        .runtime_ids = &.{ 0xA, 0xB },
        .token = testRestoreToken(state, .target),
    });
    try std.testing.expect(restored.rollbackAllowed());
    try std.testing.expectEqual(wire.AttemptStatus.resumed, restored.status(30).?.status);
    try std.testing.expectEqual(wire.AttemptStatus.pending, restored.status(31).?.status);
    try std.testing.expectEqual(wire.PrepareDecision.conflict, restored.stagePending(testRequest(32, "/blocked")));
    try std.testing.expect(restored.finish(31, .{ .status = .committed }));
    const replay = restored.stagePending(testRequest(31, "/active"));
    try std.testing.expect(replay == .completed);
    try std.testing.expectEqual(wire.AttemptStatus.committed, replay.completed.status);
}

test "upgrade owner restore allocation failures publish nothing and release owned target" {
    var old = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer old.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(testRequest(40, "/old")));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(40));
    _ = old.beginExecution(40).?;
    try std.testing.expect(old.finish(40, .{ .status = .resumed, .reason = .exec_failed }));
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(testRequest(41, "/active")));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(41));
    const execution = old.beginExecution(41).?;
    const bytes = try old.encodeRunningRecord(
        std.testing.allocator,
        execution,
        0xAA,
        12,
        testRollbackImage(),
        &.{0xCC},
    );
    defer std.testing.allocator.free(bytes);
    var state = try attempt_record.decode(std.testing.allocator, bytes);
    defer state.deinit();

    for (0..5) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var restored = UpgradeOwner.init(failing.allocator(), TestStager.ops(), null);
        defer restored.deinit();
        try std.testing.expectError(error.OutOfMemory, restored.restoreRunningRecord(state, .{
            .host_id = 0xAA,
            .host_epoch = 12,
            .runtime_ids = &.{0xCC},
            .token = testRestoreToken(state, .target),
        }));
        try std.testing.expect(restored.attempt == null);
        try std.testing.expectEqual(@as(usize, 0), restored.completed_count);
    }
}

test "upgrade owner rollback restore does not require the failed target artifact" {
    var old = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer old.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(testRequest(45, "/gone-target")));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(45));
    const execution = old.beginExecution(45).?;
    const bytes = try old.encodeRunningRecord(
        std.testing.allocator,
        execution,
        0xAA,
        14,
        testRollbackImage(),
        &.{0xDD},
    );
    defer std.testing.allocator.free(bytes);
    var state = try attempt_record.decode(std.testing.allocator, bytes);
    defer state.deinit();

    var rejected_target = UpgradeOwner.init(std.testing.allocator, MissingRestoreStager.ops(), null);
    defer rejected_target.deinit();
    try std.testing.expectError(error.InvalidState, rejected_target.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 14,
        .runtime_ids = &.{0xDD},
        .token = testRestoreToken(state, .target),
    }));

    var rollback = UpgradeOwner.init(std.testing.allocator, MissingRestoreStager.ops(), null);
    defer rollback.deinit();
    try rollback.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 14,
        .runtime_ids = &.{0xDD},
        .token = testRestoreToken(state, .rollback),
    });
    try std.testing.expect(!rollback.rollbackAllowed());
    try std.testing.expect(rollback.finish(45, .{
        .status = .rolled_back,
        .reason = .restore_failed,
    }));
}

test "upgrade owner immutable handoff allows one target to rollback transition only" {
    var old = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer old.deinit();
    try std.testing.expectEqual(wire.PrepareDecision.accepted, old.stagePending(testRequest(50, "/active")));
    try std.testing.expectEqual(wire.ArmDecision.armed, old.armAccepted(50));
    const execution = old.beginExecution(50).?;
    const bytes = try old.encodeRunningRecord(
        std.testing.allocator,
        execution,
        0xAA,
        20,
        testRollbackImage(),
        &.{},
    );
    defer std.testing.allocator.free(bytes);
    var state = try attempt_record.decode(std.testing.allocator, bytes);
    defer state.deinit();

    var target = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer target.deinit();
    try std.testing.expect(validateRestoreEntry(
        state,
        .target,
        50,
        .backup,
    ) == null);
    try std.testing.expect(validateRestoreEntry(
        state,
        .rollback,
        50,
        .primary,
    ) == null);
    const replayed_token = testRestoreToken(state, .target);
    state.attempt_id = 51;
    var replay_rejected = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer replay_rejected.deinit();
    try std.testing.expectError(error.InvalidState, replay_rejected.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 20,
        .runtime_ids = &.{},
        .token = replayed_token,
    }));
    state.attempt_id = 50;
    try target.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 20,
        .runtime_ids = &.{},
        .token = testRestoreToken(state, .target),
    });
    try std.testing.expect(target.rollbackAllowed());
    try std.testing.expect(!target.finish(50, .{ .status = .rolled_back, .reason = .restore_failed }));

    var rollback = UpgradeOwner.init(std.testing.allocator, TestStager.ops(), null);
    defer rollback.deinit();
    try rollback.restoreRunningRecord(state, .{
        .host_id = 0xAA,
        .host_epoch = 20,
        .runtime_ids = &.{},
        .token = testRestoreToken(state, .rollback),
    });
    try std.testing.expect(!rollback.rollbackAllowed());
    try std.testing.expect(!rollback.finish(50, .{ .status = .committed }));
    try std.testing.expect(rollback.finish(50, .{ .status = .rolled_back, .reason = .restore_failed }));
    try std.testing.expectEqual(wire.PrepareDecision.accepted, rollback.stagePending(testRequest(51, "/next")));
    try std.testing.expectEqual(wire.ArmDecision.armed, rollback.armAccepted(51));
    _ = rollback.beginExecution(51).?;
    try std.testing.expect(rollback.rollbackAllowed());
}
