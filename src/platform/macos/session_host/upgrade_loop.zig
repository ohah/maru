//! Normal launch와 restored launch가 공유하는 armed-upgrade outer-loop adapter.

const std = @import("std");
const owner_lease = @import("owner_lease.zig");
const rollback_image = @import("rollback_image.zig");
const runtime_manager = @import("runtime_manager.zig");
const socket_server = @import("socket_server.zig");
const upgrade_coordinator = @import("upgrade_coordinator.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const upgrade_product = @import("upgrade_product_coordinator.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *upgrade_owner.UpgradeOwner,
    manager: *runtime_manager.RuntimeManager,
    gate: *upgrade_coordinator.AdmissionGate,
    lifetime_owner: *owner_lease.OwnerLease,
    rollback_authority: *rollback_image.Authority,
    authority: upgrade_product.Authority,
    executor: upgrade_product.Executor,
    owner_dir: [:0]const u8,
    session_dir: []const u8,
    socket_path: []const u8,
};

pub const Outcome = enum { idle, terminal, fail_stop };

pub fn serveOne(server: *socket_server.SocketServer) Outcome {
    server.serveOnce() catch |err| return classifyServeError(err);
    return .terminal;
}

pub fn processCompleted(
    server: *socket_server.SocketServer,
    ctx: Context,
) Outcome {
    const attempt_id = server.takeCompletedUpgradeAttempt() orelse
        return .idle;
    const layout = upgrade_product.findAvailableLayout(40) orelse {
        // Marker를 받은 attempt는 armed다. Layout resource failure도
        // beginExecution을 한 번 소비해 terminal ledger로 끝낸다.
        if (ctx.owner.beginExecution(attempt_id) != null) {
            if (!ctx.owner.finish(attempt_id, .{
                .status = .resumed,
                .reason = .handoff_failed,
            })) return .fail_stop;
        } else {
            const report = ctx.owner.status(attempt_id) orelse
                return .fail_stop;
            if (report.status == .pending) return .fail_stop;
        }
        return .terminal;
    };
    return classify(upgrade_product.processArmed(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .owner = ctx.owner,
        .manager = ctx.manager,
        .gate = ctx.gate,
        .lifetime_owner = ctx.lifetime_owner,
        .rollback_image = ctx.rollback_authority,
        .authority = ctx.authority,
        .executor = ctx.executor,
        .owner_dir = ctx.owner_dir,
        .session_dir = ctx.session_dir,
        .socket_path = ctx.socket_path,
        .layout = layout,
    }, attempt_id));
}

fn classify(outcome: upgrade_product.Outcome) Outcome {
    return switch (outcome) {
        .invariant_violation => .fail_stop,
        // `processCompleted` only runs after SocketServer consumed an exact
        // accepted+armed marker. Losing that owner state is authority drift.
        .not_armed => .fail_stop,
        .terminal => |report| if (report.status == .failed_nonretryable)
            .fail_stop
        else
            .terminal,
    };
}

fn classifyServeError(err: socket_server.ServeError) Outcome {
    return switch (err) {
        error.WriteFailed, error.OutOfMemory => .terminal,
        error.UpgradeInvariantFailed => .fail_stop,
    };
}

test "outer loop fail-stops every nonretryable coordinator terminal" {
    try std.testing.expectEqual(
        Outcome.fail_stop,
        classify(.{ .terminal = .{
            .status = .failed_nonretryable,
            .reason = .authority_poisoned,
        } }),
    );
    try std.testing.expectEqual(
        Outcome.fail_stop,
        classify(.invariant_violation),
    );
    try std.testing.expectEqual(
        Outcome.terminal,
        classify(.{ .terminal = .{
            .status = .resumed,
            .reason = .exec_failed,
        } }),
    );
    try std.testing.expectEqual(
        Outcome.fail_stop,
        classify(.not_armed),
    );
    try std.testing.expectEqual(
        Outcome.fail_stop,
        classifyServeError(error.UpgradeInvariantFailed),
    );
    try std.testing.expectEqual(
        Outcome.terminal,
        classifyServeError(error.WriteFailed),
    );
}
