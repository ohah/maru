//! U2 quiesce→host DTO encode coordinator. Exec/staging은 U3 모듈이 이 결과를 소비한다.

const std = @import("std");
const runtime_manager = @import("runtime_manager.zig");
const upgrade_coordinator = @import("upgrade_coordinator.zig");

extern "c" fn usleep(usec: c_uint) c_int;

pub const hard_deadline_ms: u64 = 5_000;

pub const Error = runtime_manager.RuntimeManager.QuiesceError ||
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
    pub fn rollbackToServing(self: *Quiesced) void {
        if (!self.active) return;
        self.allocator.free(self.bytes);
        self.allocator.free(self.resources);
        self.manager.resumeUpgradeQuiesce();
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
    if (!gate.close()) return error.UpgradeBusy;
    var gate_closed = true;
    var pause_requested = false;
    errdefer {
        if (pause_requested) manager.resumeUpgradeQuiesce();
        if (gate_closed) gate.reopen();
    }

    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const budget_ns: i128 = @as(i128, deadline_ms) * std.time.ns_per_ms;
    while (!gate.closedAndDrained()) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start >= budget_ns) return error.DeadlineExceeded;
        _ = usleep(1000);
    }
    _ = try manager.requestUpgradeQuiesce();
    pause_requested = true;
    while (!manager.upgradeQuiesceReached()) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start >= budget_ns) return error.DeadlineExceeded;
        _ = usleep(1000);
    }
    try manager.joinAndValidateUpgradeQuiesce();
    if (std.Io.Clock.awake.now(io).nanoseconds - start >= budget_ns) return error.DeadlineExceeded;
    var plan = try manager.encodeQuiescedPlan(allocator, host_id, upgrade_epoch, first_fd_slot);
    if (std.Io.Clock.awake.now(io).nanoseconds - start >= budget_ns) {
        plan.deinit();
        return error.DeadlineExceeded;
    }

    pause_requested = false;
    gate_closed = false;
    return .{
        .allocator = allocator,
        .bytes = plan.bytes,
        .resources = plan.resources,
        .manager = manager,
        .gate = gate,
    };
}

test "U2 coordinator deadline rollback reopens admission and keeps runtime usable" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const reg = @import("registry.zig");
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(std.testing.allocator, std.testing.io, &registry);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);
    var gate = upgrade_coordinator.AdmissionGate.init(std.testing.io);

    try std.testing.expectError(
        error.DeadlineExceeded,
        begin(std.testing.allocator, std.testing.io, &manager, &gate, 1, 0, 40, 0),
    );
    try std.testing.expect(gate.snapshot().open);
    try ops.write_input(ops.ctx, rid, "after-timeout\n");
}

test "U2 coordinator returns a validated host artifact and explicit resume restores admission" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const reg = @import("registry.zig");
    const codec = @import("handoff_codec.zig");
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(std.testing.allocator, std.testing.io, &registry);
    defer manager.deinit();
    const ops = manager.runtimeOps();
    const rid = try ops.spawn(ops.ctx, .{ .argv = &.{"/bin/cat"}, .cwd = null, .cols = 20, .rows = 4 });
    defer ops.terminate(ops.ctx, rid);
    var gate = upgrade_coordinator.AdmissionGate.init(std.testing.io);

    var quiesced = try begin(std.testing.allocator, std.testing.io, &manager, &gate, 0xAA, 7, 40, hard_deadline_ms);
    var decoded = try codec.decodeHost(std.testing.allocator, quiesced.bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u128, 0xAA), decoded.host_id);
    try std.testing.expectEqual(@as(usize, 1), decoded.runtimes.len);
    quiesced.rollbackToServing();
    try std.testing.expect(gate.snapshot().open);
    try ops.write_input(ops.ctx, rid, "after-resume\n");
}
