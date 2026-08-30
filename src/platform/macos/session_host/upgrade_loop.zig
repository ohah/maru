//! Normal launch와 restored launch가 공유하는 armed-upgrade outer-loop adapter.

const std = @import("std");
const owner_lease = @import("owner_lease.zig");
const rollback_image = @import("rollback_image.zig");
const runtime_manager = @import("runtime_manager.zig");
const upgrade_coordinator = @import("upgrade_coordinator.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const upgrade_product = @import("upgrade_product_coordinator.zig");
const connection_turn = @import("connection_turn.zig");

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

pub fn processPreclosed(
    marker: connection_turn.ArmedUpgrade,
    ctx: Context,
) Outcome {
    return processPreclosedMode(.product, marker, ctx);
}

/// 실제 daemon process fixture가 제품과 같은 context/layout을 쓰되 coordinator-private fault만 선택한다.
pub fn processPreclosedCleanupCollisionFixture(
    marker: connection_turn.ArmedUpgrade,
    ctx: Context,
) Outcome {
    if (!@import("builtin").is_test) @compileError("cleanup collision fixture is test-only");
    return processPreclosedMode(.cleanup_collision_fixture, marker, ctx);
}

pub fn processPreclosedKernelCleanupFaultFixture(
    marker: connection_turn.ArmedUpgrade,
    ctx: Context,
) Outcome {
    if (!@import("builtin").is_test) @compileError("kernel cleanup fault fixture is test-only");
    return processPreclosedMode(.kernel_cleanup_fault_fixture, marker, ctx);
}

const ProcessMode = enum { product, cleanup_collision_fixture, kernel_cleanup_fault_fixture };

fn processPreclosedMode(
    comptime mode: ProcessMode,
    marker: connection_turn.ArmedUpgrade,
    ctx: Context,
) Outcome {
    if (!marker.gate_preclosed) return .fail_stop;
    const layout = upgrade_product.findAvailableLayout(40) orelse
        return finishPreclosedWithoutLayout(marker, ctx);
    const product_context: upgrade_product.Context = .{
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
    };
    return classify(switch (mode) {
        .product => upgrade_product.processArmedPreclosed(product_context, marker.attempt_id),
        .cleanup_collision_fixture => upgrade_product.processArmedPreclosedCleanupCollisionFixture(
            product_context,
            marker.attempt_id,
        ),
        .kernel_cleanup_fault_fixture => upgrade_product.processArmedPreclosedKernelCleanupFaultFixture(
            product_context,
            marker.attempt_id,
        ),
    });
}

fn finishPreclosedWithoutLayout(marker: connection_turn.ArmedUpgrade, ctx: Context) Outcome {
    if (ctx.owner.beginExecution(marker.attempt_id) != null) {
        if (!ctx.owner.finish(marker.attempt_id, .{
            .status = .resumed,
            .reason = .handoff_failed,
        })) return .fail_stop;
    } else {
        const report = ctx.owner.status(marker.attempt_id) orelse return .fail_stop;
        if (report.status == .pending) return .fail_stop;
    }
    const report = ctx.owner.status(marker.attempt_id) orelse return .fail_stop;
    if (report.status != .resumed) return .fail_stop;
    ctx.gate.cancelClose();
    return .terminal;
}

fn classify(outcome: upgrade_product.Outcome) Outcome {
    return switch (outcome) {
        .invariant_violation => .fail_stop,
        // The typed preclosed marker must still name an armed attempt. Losing that owner state is
        // authority drift, not a retryable serving outcome.
        .not_armed => .fail_stop,
        .terminal => |report| if (report.status == .failed_nonretryable)
            .fail_stop
        else
            .terminal,
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
}
