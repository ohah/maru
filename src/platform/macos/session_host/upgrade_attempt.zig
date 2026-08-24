//! U2 quiesce→host DTO encode coordinator. Exec/staging은 U3 모듈이 이 결과를 소비한다.

const std = @import("std");
const runtime_manager = @import("runtime_manager.zig");
const upgrade_coordinator = @import("upgrade_coordinator.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_limits = @import("upgrade_limits.zig");

extern "c" fn usleep(usec: c_uint) c_int;

pub const Error = runtime_manager.RuntimeManager.QuiesceError ||
    runtime_manager.RuntimeManager.ResumeError ||
    @import("handoff_codec.zig").Error ||
    error{ UpgradeBusy, DeadlineExceeded };

pub const Quiesced = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    resources: []runtime_manager.RuntimeManager.UpgradeResource,
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    active: bool = true,

    /// U2 test path 또는 U3 pre-exec 실패 rollback. Same graph의 reader와 admission을 다시 연다.
    pub fn rollbackToServing(self: *Quiesced) runtime_manager.RuntimeManager.ResumeError!void {
        if (!self.active) return;
        try self.manager.resumeUpgradeQuiesce();
        self.allocator.free(self.bytes);
        self.allocator.free(self.resources);
        self.gate.reopen();
        self.active = false;
    }

    /// U3가 bytes와 paused runtime ownership을 넘겨받는다. 이후 이 guard는 rollback하지 않는다.
    pub fn takePlan(self: *Quiesced) runtime_manager.RuntimeManager.EncodedUpgradePlan {
        std.debug.assert(self.active);
        self.active = false;
        return .{ .allocator = self.allocator, .bytes = self.bytes, .resources = self.resources };
    }
};

pub const Frozen = struct {
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    active: bool = true,
    captured: bool = false,

    pub fn rollbackToServing(self: *Frozen) runtime_manager.RuntimeManager.ResumeError!void {
        if (!self.active) return;
        try self.manager.resumeUpgradeQuiesce();
        self.gate.reopen();
        self.active = false;
    }

    pub fn prepareRollbackToServing(
        self: *Frozen,
    ) runtime_manager.RuntimeManager.ResumeError!runtime_manager.RuntimeManager.PreparedResume {
        if (!self.active) return error.ResumeFailed;
        return self.manager.prepareUpgradeResume();
    }

    pub fn commitPreparedRollback(
        self: *Frozen,
        prepared: *runtime_manager.RuntimeManager.PreparedResume,
    ) void {
        std.debug.assert(self.active);
        prepared.release();
        self.gate.reopen();
        self.active = false;
    }

    pub fn prepareCapture(
        self: *Frozen,
        allocator: std.mem.Allocator,
        host_id: u128,
        upgrade_epoch: u64,
        authority_generation: u64,
        first_fd_slot: u16,
    ) (runtime_manager.RuntimeManager.QuiesceError || @import("handoff_codec.zig").Error)!runtime_manager.RuntimeManager.QuiescedCapture {
        std.debug.assert(self.active);
        if (self.captured) return error.UnsafeFrontier;
        const capture = try self.manager.prepareQuiescedCapture(
            allocator,
            host_id,
            upgrade_epoch,
            authority_generation,
            first_fd_slot,
        );
        self.captured = true;
        return capture;
    }
};

pub fn begin(
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    host_id: u128,
    upgrade_epoch: u64,
    first_fd_slot: u16,
    deadline_ms: u64,
) Error!Quiesced {
    const deadline = upgrade_deadline.Deadline.after(
        io,
        @as(i128, deadline_ms) * std.time.ns_per_ms,
    ) catch return error.DeadlineExceeded;
    return beginWithRecord(
        allocator,
        manager,
        gate,
        host_id,
        upgrade_epoch,
        first_fd_slot,
        deadline,
        null,
    );
}

pub fn beginWithRecord(
    allocator: std.mem.Allocator,
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    host_id: u128,
    upgrade_epoch: u64,
    first_fd_slot: u16,
    deadline: upgrade_deadline.Deadline,
    attempt_record: ?[]const u8,
) Error!Quiesced {
    var frozen = try freeze(manager, gate, deadline);
    var capture = frozen.prepareCapture(allocator, host_id, upgrade_epoch, 1, first_fd_slot) catch |err| {
        frozen.rollbackToServing() catch return error.ResumeFailed;
        return err;
    };
    var plan = capture.intoPlan(attempt_record) catch |err| {
        capture.deinit();
        frozen.rollbackToServing() catch return error.ResumeFailed;
        return err;
    };
    if (deadline.expired()) {
        plan.deinit();
        frozen.rollbackToServing() catch return error.ResumeFailed;
        return error.DeadlineExceeded;
    }
    frozen.active = false;
    return .{
        .allocator = allocator,
        .bytes = plan.bytes,
        .resources = plan.resources,
        .manager = manager,
        .gate = gate,
    };
}

pub fn freeze(
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    deadline: upgrade_deadline.Deadline,
) Error!Frozen {
    return freezeGate(manager, gate, deadline, false);
}

/// Reactor accepted-reply path already closed the sole product admission gate before arm. Reusing
/// `freeze` would interpret that valid handoff as UpgradeBusy, so the typed marker must select this
/// entrypoint. It still waits for every pre-close lease before quiescing readers.
pub fn freezePreclosed(
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    deadline: upgrade_deadline.Deadline,
) Error!Frozen {
    return freezeGate(manager, gate, deadline, true);
}

fn freezeGate(
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    deadline: upgrade_deadline.Deadline,
    preclosed: bool,
) Error!Frozen {
    if (preclosed) {
        if (gate.snapshot().open) return error.UpgradeBusy;
    } else if (!gate.close()) return error.UpgradeBusy;
    var pause_requested = false;

    while (!gate.closedAndDrained()) {
        if (deadline.expired()) {
            try rollbackFreeze(manager, gate, pause_requested);
            return error.DeadlineExceeded;
        }
        _ = usleep(1000);
    }
    _ = manager.requestUpgradeQuiesce() catch |err| {
        try rollbackRequestFailure(gate, err);
        return err;
    };
    pause_requested = true;
    while (!manager.upgradeQuiesceReached()) {
        if (deadline.expired()) {
            try rollbackFreeze(manager, gate, pause_requested);
            return error.DeadlineExceeded;
        }
        _ = usleep(1000);
    }
    manager.joinAndValidateUpgradeQuiesce() catch |err| {
        try rollbackFreeze(manager, gate, pause_requested);
        return err;
    };
    if (deadline.expired()) {
        try rollbackFreeze(manager, gate, pause_requested);
        return error.DeadlineExceeded;
    }
    return .{
        .manager = manager,
        .gate = gate,
    };
}

/// `requestUpgradeQuiesce`는 요청 도중 실패하면 자신이 건드린 reader를 먼저 복구한다. 그 복구가 성공한
/// `PauseFailed` 등은 아직 reader 전체 pause가 성립하기 전이므로 admission만 다시 열면 된다. 반대로
/// `ResumeFailed`는 죽거나 재시작하지 못한 reader가 남았다는 뜻이라 serving 복귀를 증명할 수 없다.
/// 이때 gate를 열지 않고 상위 fail-stop 경로가 host 권위를 철회하게 한다.
fn rollbackRequestFailure(
    gate: *upgrade_coordinator.AdmissionGate,
    request_error: runtime_manager.RuntimeManager.QuiesceError,
) runtime_manager.RuntimeManager.ResumeError!void {
    if (request_error == error.ResumeFailed) return error.ResumeFailed;
    gate.cancelClose();
}

fn rollbackFreeze(
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    pause_requested: bool,
) runtime_manager.RuntimeManager.ResumeError!void {
    if (pause_requested) try manager.resumeUpgradeQuiesce();
    gate.cancelClose();
}

test "U2 request cleanup failure keeps admission closed for fail-stop" {
    var gate = upgrade_coordinator.AdmissionGate.init(std.testing.io);
    try std.testing.expect(gate.close());
    try std.testing.expectError(error.ResumeFailed, rollbackRequestFailure(&gate, error.ResumeFailed));
    try std.testing.expect(!gate.snapshot().open);

    gate.cancelClose();
    try std.testing.expect(gate.snapshot().open);
    try std.testing.expect(gate.close());
    try rollbackRequestFailure(&gate, error.PauseFailed);
    try std.testing.expect(gate.snapshot().open);
}

test "U2 coordinator deadline rollback reopens admission and keeps runtime usable" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const reg = @import("registry.zig");
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(std.testing.allocator, std.testing.io, &registry, null);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);
    var gate = upgrade_coordinator.AdmissionGate.init(std.testing.io);

    const ExpiredClock = struct {
        fn now(_: *anyopaque) i128 {
            return 1;
        }
    };
    try std.testing.expectError(
        error.DeadlineExceeded,
        freeze(
            &manager,
            &gate,
            .fromInjected(.{ .ctx = @ptrFromInt(1), .now_ns = ExpiredClock.now }, 1),
        ),
    );
    try std.testing.expect(gate.snapshot().open);
    try ops.write_input(ops.ctx, rid, "after-timeout\n");
    var retry = try begin(
        std.testing.allocator,
        std.testing.io,
        &manager,
        &gate,
        1,
        0,
        40,
        upgrade_limits.pause_budget_ms,
    );
    try retry.rollbackToServing();
    try std.testing.expect(gate.snapshot().open);
}

test "U2 coordinator returns a validated host artifact and explicit resume restores admission" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const reg = @import("registry.zig");
    const codec = @import("handoff_codec.zig");
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(std.testing.allocator, std.testing.io, &registry, null);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);
    var gate = upgrade_coordinator.AdmissionGate.init(std.testing.io);

    var quiesced = try begin(
        std.testing.allocator,
        std.testing.io,
        &manager,
        &gate,
        0xAA,
        7,
        40,
        upgrade_limits.pause_budget_ms,
    );
    var decoded = try codec.decodeHost(std.testing.allocator, quiesced.bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u128, 0xAA), decoded.host_id);
    try std.testing.expectEqual(@as(usize, 1), decoded.runtimes.len);
    try quiesced.rollbackToServing();
    try std.testing.expect(gate.snapshot().open);
    try ops.write_input(ops.ctx, rid, "after-resume\n");
}
