//! Same-PID exec 뒤 target/rollback image가 prepared graph를 실제 daemon
//! authority로 전환하는 U5 제품 coordinator.
//!
//! Rollback은 `rollback_armed`부터 durable ready commit 직전까지만
//! 허용한다. ready commit 뒤 오류는 reader/admission을 열지 않는 fail-stop
//! 이며 이전 image로 다시 exec하지 않는다.

const std = @import("std");
const c = std.c;
const entrypoint = @import("entrypoint.zig");
const code_signature = @import("code_signature.zig");
const host_authority = @import("host_authority.zig");
const host_manifest = @import("host_manifest.zig");
const owner_lease = @import("owner_lease.zig");
const protocol = @import("protocol.zig");
const reg = @import("registry.zig");
const rollback_image = @import("rollback_image.zig");
const runtime_manager = @import("runtime_manager.zig");
const screen_stream = @import("screen_stream.zig");
const short_endpoint = @import("short_endpoint.zig");
const socket_server = @import("socket_server.zig");
const upgrade = @import("upgrade_coordinator.zig");
const upgrade_bootstrap = @import("upgrade_bootstrap.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_executor = @import("upgrade_executor.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const upgrade_loop = @import("upgrade_loop.zig");
const upgrade_owner = @import("upgrade_owner.zig");
const upgrade_target = @import("upgrade_target.zig");
const upgrade_wire = @import("upgrade_wire.zig");

const poll_timeout_ms: i32 = 200;
extern "c" fn usleep(usec: c_uint) c_int;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: entrypoint.RestoreInvocation,
) !void {
    var armed = try upgrade_bootstrap.armRestoreInvocation(
        allocator,
        invocation,
    );
    var armed_active = true;
    defer if (armed_active) armed.deinit();

    var rollback_exec: ?upgrade_bootstrap.PreparedRollbackExec =
        if (invocation.role == .target)
            try upgrade_bootstrap.PreparedRollbackExec.prepare(
                allocator,
                &armed,
                invocation,
            )
        else
            null;
    defer if (rollback_exec) |*prepared| prepared.deinit();

    var validated = upgrade_bootstrap.validateArmedCurrentExecutable(
        &armed,
        io,
        invocation,
    ) catch |err| {
        if (rollback_exec) |*prepared|
            prepared.execute() catch return error.RollbackExecFailed;
        return err;
    };
    armed_active = false;
    defer validated.deinit();

    var rollback_allowed = invocation.role == .target;
    activateValidated(
        allocator,
        io,
        invocation,
        &validated,
        &rollback_allowed,
    ) catch |err| {
        if (rollback_allowed and err != error.AuthorityPoisoned) {
            if (rollback_exec) |*prepared|
                prepared.execute() catch return error.RollbackExecFailed;
        }
        return err;
    };
}

fn activateValidated(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: entrypoint.RestoreInvocation,
    validated: *upgrade_bootstrap.RestoreValidated,
    rollback_allowed: *bool,
) !void {
    const deadline = try validated.deadline(io);
    try checkRoleDeadline(invocation.role, deadline);
    var inherited_close = try validated.prepareInheritedClose();
    const session_dir = try allocator.dupeZ(u8, invocation.session_dir);
    defer allocator.free(session_dir);

    var owner_path_buf: [832]u8 = undefined;
    const owner_path = try host_manifest.ownerLockPathIn(
        &owner_path_buf,
        session_dir,
        invocation.host_id,
    );
    var lifetime_owner = try owner_lease.OwnerLease.adoptInheritedExact(
        validated.inherited.owner,
        owner_path,
    );
    // Target precommit failure returns to `run`, which execs the canonical
    // rollback image with the original inherited owner fd. Until ready
    // publication commits, closing this working dup is safe but unlinking the
    // exact pathname would make rollback bootstrap reject that inherited fd.
    var preserve_owner_path_for_rollback = invocation.role == .target;
    defer {
        if (!preserve_owner_path_for_rollback)
            _ = lifetime_owner.unlinkOwnedWhileLocked(owner_path) catch {};
        lifetime_owner.deinit();
        if (!preserve_owner_path_for_rollback)
            host_manifest.removeEmptyHostDirectories(
                session_dir,
                invocation.host_id,
            );
    }

    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var manager: runtime_manager.RuntimeManager = undefined;
    manager.init(allocator, io, &registry);
    defer manager.deinit();
    var graph = try manager.prepareRestoredGraph(&validated.state.host);
    defer graph.discard();
    try checkRoleDeadline(invocation.role, deadline);
    const reader_deadline = try readerPreparationDeadline(
        io,
        invocation.role,
        deadline,
    );

    var gate = upgrade.AdmissionGate.initClosed(io);
    var socket_dir_buf: [112]u8 = undefined;
    const socket_dir = try short_endpoint.socketDirPathIn(
        &socket_dir_buf,
        c.getuid(),
    );
    const socket_path = try allocator.dupeZ(u8, invocation.socket_path);
    defer allocator.free(socket_path);
    var server = try socket_server.SocketServer.bind(
        allocator,
        socket_dir,
        socket_path,
        invocation.host_id,
        &registry,
    );
    defer server.deinit();
    server.admission_gate = &gate;
    server.runtime_ops = manager.runtimeOps();
    server.owner_tick_ctx = &manager;
    server.owner_tick = struct {
        fn tick(ctx: *anyopaque) void {
            const owner: *runtime_manager.RuntimeManager =
                @ptrCast(@alignCast(ctx));
            _ = owner.drainOwnedEvents();
        }
    }.tick;

    var adoption = try host_manifest.prepareAdoptRestoringPinned(
        allocator,
        session_dir,
        invocation.host_id,
        validated.state.attempt.epoch_before,
        invocation.socket_path,
    );
    defer adoption.deinit();
    const restoring = try adoption.get().descriptor();

    var rollback_authority = try rollback_image.Authority.adoptCanonical(
        allocator,
        session_dir,
        invocation.host_id,
        validated.state.attempt.rollbackImage(),
    );
    defer rollback_authority.deinit();

    var host_dir_buf: [768]u8 = undefined;
    var signature_authorizer = code_signature.Authorizer{
        .io = io,
        // Promotion rotates the canonical image in place. Unlike the staged
        // target pathname, this owner-only path remains a valid signer anchor
        // for the next consecutive upgrade.
        .current_executable = rollback_authority.image.path,
    };
    var stager = upgrade_target.Stager{
        .owner_dir = try host_manifest.hostDirPathIn(
            &host_dir_buf,
            session_dir,
            invocation.host_id,
        ),
        .authorizer = signature_authorizer.ops(),
    };
    var attempt_owner = upgrade_owner.UpgradeOwner.init(
        allocator,
        stager.ops(),
        .{
            .ctx = &registry,
            .is_busy = struct {
                fn busy(ctx: *anyopaque) bool {
                    const runtime_registry: *reg.TerminalRuntimeRegistry =
                        @ptrCast(@alignCast(ctx));
                    return runtime_registry.attachmentCount() != 0;
                }
            }.busy,
        },
    );
    defer attempt_owner.deinit();
    try attempt_owner.restoreRunningRecord(validated.state.attempt, .{
        .host_id = invocation.host_id,
        .host_epoch = validated.state.host.upgrade_epoch,
        .runtime_ids = validated.state.attempt.runtime_ids,
        .token = validated.token,
    });

    const target_execution = if (invocation.role == .target)
        attempt_owner.runningExecution(invocation.attempt_id) orelse
            return error.InvalidRestore
    else
        null;
    var finish = if (invocation.role == .target)
        attempt_owner.prepareTargetFinishLate(invocation.attempt_id) orelse
            return error.InvalidRestore
    else
        attempt_owner.prepareFinish(invocation.attempt_id, .{
            .status = .rolled_back,
            .reason = .restore_failed,
        }) orelse return error.InvalidRestore;

    var ready = restoring;
    ready.lifecycle = .ready;
    var next_upgrade_capable = invocation.role == .rollback;
    if (invocation.role == .target) {
        ready.build_id = validated.state.attempt.build_id;
        ready.protocol_major = protocol.version_major;
        ready.screen_codec_version = screen_stream.codec_version;
        ready.upgrade_epoch = validated.state.attempt.expected_epoch_after;
    }
    var prepared_authority = try host_authority.HostAuthority.prepareInit(
        allocator,
        &server,
        ready,
    );
    defer prepared_authority.discard();

    try checkRoleDeadline(invocation.role, deadline);
    try lifetime_owner.revalidatePath(owner_path);
    if (!server.revalidateBoundIdentity() or
        !rollback_authority.revalidate())
        return error.InvalidRestore;
    // Reader threads publish their start-gate asynchronously. Revalidation
    // before that publication would reject a healthy non-empty restore graph.
    // Target shares the original attempt deadline; rollback gets one bounded
    // recovery budget because that original deadline may be its trigger.
    while (!graph.allReadersPrepared()) {
        if (reader_deadline.expired()) return error.DeadlineExceeded;
        _ = usleep(1000);
    }
    var validated_graph = try graph.revalidateAll();
    try adoption.get().revalidate(session_dir);
    try checkRoleDeadline(invocation.role, deadline);

    var authority = prepared_authority.activateReady(&adoption) catch |err|
        return if (err == error.AuthorityPoisoned)
            error.AuthorityPoisoned
        else
            err;
    defer authority.deinit();
    rollback_allowed.* = false;
    preserve_owner_path_for_rollback = false;

    var committed_graph = validated_graph.commitOwnership();
    if (!rollback_authority.activateCleanup()) {
        authority.markDraining() catch {};
        return error.PostCommitFailStop;
    }
    inherited_close.closeAndVerify() catch {
        authority.markDraining() catch {};
        return error.PostCommitFailStop;
    };
    committed_graph.releaseReaders();

    if (invocation.role == .target) {
        const execution = target_execution.?;
        const promotion = rollback_authority.promoteTarget(
            stager.owner_dir,
            execution.target.artifact.path,
            .{
                .dev = execution.target.artifact.dev,
                .ino = execution.target.artifact.ino,
                .size = execution.target.artifact.size,
                .sha256 = execution.target.artifact.sha256,
            },
            .none,
        );
        const report: upgrade_wire.AttemptReport = switch (promotion) {
            .promoted => blk: {
                next_upgrade_capable = true;
                break :blk .{ .status = .committed };
            },
            else => .{
                .status = .committed,
                .reason = .promotion_failed,
            },
        };
        if (!finish.commitReport(report))
            return error.PostCommitFailStop;
    } else {
        finish.commit();
        if (attempt_owner.status(invocation.attempt_id) == null)
            return error.PostCommitFailStop;
    }

    if (next_upgrade_capable) {
        authority.installUpgradeController(attempt_owner.ops());
    } else {
        attempt_owner.disableNewAttempts();
        authority.installUpgradeStatusOnly(attempt_owner.ops());
    }
    gate.reopen();
    try writeTestActivationMarker(invocation.attempt_id);
    var product_executor: upgrade_executor.ProductExecutor = .{
        .allocator = allocator,
    };
    try serveLoop(&server, .{
        .allocator = allocator,
        .io = io,
        .owner = &attempt_owner,
        .manager = &manager,
        .gate = &gate,
        .lifetime_owner = &lifetime_owner,
        .rollback_authority = &rollback_authority,
        .authority = authority.upgradeAuthority(),
        .executor = product_executor.ops(),
        .owner_dir = stager.owner_dir,
        .session_dir = session_dir,
        .socket_path = socket_path,
    });
}

fn writeTestActivationMarker(attempt_id: u128) !void {
    const oneshot = c.getenv("MARU_SESSION_HOST_TEST_ONESHOT") orelse return;
    if (!std.mem.eql(
        u8,
        std.mem.span(oneshot),
        "maru-test-only-v1",
    )) return;
    const raw = c.getenv("MARU_SESSION_HOST_ACTIVATION_MARKER") orelse return;
    const path = std.mem.span(raw);
    if (!std.mem.startsWith(
        u8,
        path,
        "/tmp/maru-restore-activation-",
    ) or path.len > 256)
        return error.InvalidRestore;
    _ = c.unlink(raw);
    const fd = c.open(
        raw,
        .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return error.InvalidRestore;
    defer _ = c.close(fd);
    var buffer: [33]u8 = undefined;
    const bytes = std.fmt.bufPrint(
        &buffer,
        "{x:0>32}\n",
        .{attempt_id},
    ) catch return error.InvalidRestore;
    if (c.write(fd, bytes.ptr, bytes.len) !=
        @as(isize, @intCast(bytes.len)) or c.fsync(fd) != 0)
        return error.InvalidRestore;
}

fn checkDeadline(deadline: upgrade_deadline.Deadline) !void {
    if (deadline.expired()) return error.DeadlineExceeded;
}

fn checkRoleDeadline(
    role: entrypoint.RestoreRole,
    deadline: upgrade_deadline.Deadline,
) !void {
    // Target는 old-side absolute budget을 그대로 지킨다. Rollback image는
    // 그 budget을 넘긴 것이 곧 복구 사유일 수 있으므로, old coordinator의
    // "deadline 후에도 첫 authority rollback 시도"와 같이 한 번은
    // non-recursive recovery를 끝까지 시도한다.
    if (role == .target) try checkDeadline(deadline);
}

fn readerPreparationDeadline(
    io: std.Io,
    role: entrypoint.RestoreRole,
    attempt_deadline: upgrade_deadline.Deadline,
) !upgrade_deadline.Deadline {
    return if (role == .target)
        attempt_deadline
    else
        upgrade_deadline.Deadline.after(
            io,
            upgrade_limits.pause_budget_ns,
        );
}

fn serveLoop(
    server: *socket_server.SocketServer,
    upgrade_context: upgrade_loop.Context,
) !void {
    const test_oneshot = if (c.getenv("MARU_SESSION_HOST_TEST_ONESHOT")) |value|
        std.mem.eql(u8, std.mem.span(value), "maru-test-only-v1")
    else
        false;
    var idle_ticks: usize = 0;
    while (true) {
        server.tickOwner();
        switch (server.pollReady(poll_timeout_ms)) {
            .ready => {
                if (upgrade_loop.serveOne(server) == .fail_stop)
                    return error.PostCommitFailStop;
                if (upgrade_loop.processCompleted(
                    server,
                    upgrade_context,
                ) == .fail_stop)
                    return error.PostCommitFailStop;
                if (test_oneshot) return;
            },
            .timeout => if (test_oneshot) {
                idle_ticks += 1;
                if (idle_ticks >= 25) return;
            },
            .broken => return,
        }
    }
}

test "restore activation keeps the recorded absolute deadline" {
    const FakeClock = struct {
        now: i128,

        fn read(ctx: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.now;
        }
    };
    var fake: FakeClock = .{ .now = 100 };
    const deadline = upgrade_deadline.Deadline.fromInjected(
        .{ .ctx = &fake, .now_ns = FakeClock.read },
        101,
    );
    try checkDeadline(deadline);
    fake.now = 101;
    try std.testing.expectError(error.DeadlineExceeded, checkDeadline(deadline));
    try std.testing.expectError(
        error.DeadlineExceeded,
        checkRoleDeadline(.target, deadline),
    );
    try checkRoleDeadline(.rollback, deadline);
}

test "reader preparation keeps target deadline and bounds rollback recovery" {
    const expired = upgrade_deadline.Deadline.fromInjected(
        .{
            .ctx = @ptrFromInt(1),
            .now_ns = struct {
                fn now(_: *anyopaque) i128 {
                    return 10;
                }
            }.now,
        },
        5,
    );
    const target = try readerPreparationDeadline(
        std.testing.io,
        .target,
        expired,
    );
    try std.testing.expectEqual(
        expired.expiresAtNs(),
        target.expiresAtNs(),
    );
    const rollback = try readerPreparationDeadline(
        std.testing.io,
        .rollback,
        expired,
    );
    try std.testing.expect(rollback.remainingNs() > 0);
    try std.testing.expect(
        rollback.remainingNs() <= upgrade_limits.pause_budget_ns,
    );
}
