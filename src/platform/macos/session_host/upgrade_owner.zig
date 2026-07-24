//! Daemon-owned live-upgrade attempt SSOT(U5-A).
//!
//! Socket handler는 borrowed request를 여기서 deep-copy해 pending으로 stage하고, accepted reply 전량 write 뒤 같은
//! attempt만 arm한다. Quiesce/exec는 connection admission lease 밖의 daemon loop가 `beginExecution`으로 시작한다.

const std = @import("std");
const wire = @import("upgrade_wire.zig");

pub const BusyProbe = struct {
    ctx: *anyopaque,
    is_busy: *const fn (ctx: *anyopaque) bool,
};

pub const StagedArtifact = struct {
    path: [:0]u8,
    /// Path replacement과 무관하게 staged executable inode를 pin한다. 제품 executor는 path 기반 exec가 아니라
    /// 이 fd 기반 실행 경계를 사용해야 한다.
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
    /// `finish` 전까지만 유효한 borrowed slice를 포함한다. Executor는 실제 exec 직전에
    /// `revalidateExecution`을 다시 통과해야 한다.
    target: VerifiedTarget,
};

const Phase = enum { staged, armed, running, terminal };

const Attempt = struct {
    id: u128,
    request_path: []u8,
    target: VerifiedTarget,
    phase: Phase = .staged,
    report: wire.AttemptReport = .{ .status = .pending },
};

pub const UpgradeOwner = struct {
    /// Host lifetime idempotency를 위해 완료 ID를 eviction하지 않는다. 상한에 닿으면 새 실행을 거부해 과거 ID가 다시
    /// 실행되는 것보다 fail-closed한다.
    const max_completed = 256;
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
                .running, .terminal => .conflict,
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
            .running, .terminal => return .conflict,
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
            .target = attempt.target,
        };
    }

    /// beginExecution 뒤 fd/argv 준비 중 path 교체가 없었는지 실제 exec syscall 직전에 재검증하는 마지막 gate다.
    pub fn revalidateExecution(self: *const UpgradeOwner, execution: Execution) bool {
        const attempt = if (self.attempt) |value| value else return false;
        if (attempt.id != execution.attempt_id or attempt.phase != .running) return false;
        return self.target_stager.verify(self.target_stager.ctx, attempt.target);
    }

    pub fn finish(
        self: *UpgradeOwner,
        attempt_id: u128,
        report: wire.AttemptReport,
    ) bool {
        const attempt = if (self.attempt) |*value| value else return false;
        if (attempt.id != attempt_id or attempt.phase != .running) return false;
        if (!wire.validReport(report) or report.status == .pending) return false;
        std.debug.assert(self.completed_count < max_completed);
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
        return true;
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

fn testRequest(id: u128, path: []const u8) wire.PrepareRequest {
    return .{
        .attempt_id = id,
        .target_path = path,
        .target_build_id = "sha256:build",
        .target_sha256 = [_]u8{0xAB} ** 32,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    };
}

const TestStager = struct {
    fn ops() TargetStager {
        return .{
            .ctx = @ptrFromInt(1),
            .stage = stage,
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
    try std.testing.expect(owner.finish(7, .{ .status = .rolled_back, .reason = .restore_failed }));
    const report = owner.status(7).?;
    try std.testing.expectEqual(wire.AttemptStatus.rolled_back, report.status);
    try std.testing.expectEqual(wire.AttemptReason.restore_failed, report.reason);
    const replay = owner.stagePending(testRequest(7, "/target"));
    try std.testing.expect(replay == .completed);
    try std.testing.expectEqual(wire.AttemptStatus.rolled_back, replay.completed.status);
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
    try std.testing.expect(owner.finish(12, .{ .status = .committed }));
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
