//! Same-PID exec 뒤 target/rollback image가 prepared graph를 실제 daemon
//! authority로 전환하는 U5 제품 coordinator.
//!
//! Rollback은 `rollback_armed`부터 durable ready commit 직전까지만
//! 허용한다. ready commit 뒤 오류는 reader/admission을 열지 않는 fail-stop
//! 이며 이전 image로 다시 exec하지 않는다.

const builtin = @import("builtin");
const std = @import("std");
const c = std.c;
const entrypoint = @import("entrypoint.zig");
const code_signature = @import("code_signature.zig");
const host_authority = @import("host_authority.zig");
const host_manifest = @import("host_manifest.zig");
const agent_hook_logs = @import("agent_hook_logs.zig");
const owner_lease = @import("owner_lease.zig");
const protocol = @import("protocol.zig");
const reg = @import("registry.zig");
const rollback_image = @import("rollback_image.zig");
const runtime_manager = @import("runtime_manager.zig");
const notification_os_delivery = @import("notification_os_delivery.zig");
const screen_stream = @import("maru").session.screen_stream;
const short_endpoint = @import("short_endpoint.zig");
const socket_server = @import("socket_server.zig");
const upgrade = @import("upgrade_coordinator.zig");
const upgrade_bootstrap = @import("upgrade_bootstrap.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_executor = @import("upgrade_executor.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const upgrade_loop = @import("upgrade_loop.zig");
const poll_owner = @import("poll_owner.zig");
const process_seal_service = @import("process_seal_service.zig");
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
    return runImpl(allocator, io, invocation, null);
}

pub fn runWithNotificationAdapter(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: entrypoint.RestoreInvocation,
    adapter: notification_os_delivery.Adapter,
) !void {
    return runImpl(allocator, io, invocation, adapter);
}

fn runImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: entrypoint.RestoreInvocation,
    notification_adapter: ?notification_os_delivery.Adapter,
) !void {
    _ = try bootstrapProcessSeal();

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
        notification_adapter,
    ) catch |err| {
        if (rollback_allowed and err != error.AuthorityPoisoned) {
            if (rollback_exec) |*prepared|
                prepared.execute() catch return error.RollbackExecFailed;
        }
        return err;
    };
}

fn bootstrapProcessSeal() !process_seal_service.ReadyIdentity {
    // exec 뒤 process-global seal은 항상 pristine이다. 복원 graph나 inherited fd를
    // 읽기 전에 새 process-domain을 게시해 이후 owner turn과 Client bootstrap이
    // 동일한 ready identity만 사용하게 한다.
    const process_pid = process_seal_service.currentProcessId();
    const process_nonce = try process_seal_service.generateProcessNonce();
    process_seal_service.commitReady(try process_seal_service.prepare(process_pid, process_nonce));
    return process_seal_service.currentReadyIdentity();
}

/// 지금 실행 중인 이미지의 build_id. 실패하면 `null` — 호출자는 기존 값을 그대로 쓴다.
fn selfImageBuildId(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    const self_path = std.process.executablePathAlloc(io, allocator) catch return null;
    defer allocator.free(self_path);
    const self_path_z = allocator.dupeZ(u8, self_path) catch return null;
    defer allocator.free(self_path_z);
    return host_manifest.buildIdForExecutable(allocator, self_path_z) catch null;
}

/// manifest 가 광고하려던 값과 실제 이미지가 어긋났다. 정정 자체는 위에서 하고, 여기서는 **어긋났다는 사실**을
/// 남긴다 — 이 드리프트가 있었다는 것 자체가 attempt record 전달 경로의 회귀 신호다.
fn logManifestBuildIdDrift(attempt_build_id: []const u8, actual_build_id: []const u8) void {
    if (builtin.is_test) return;
    std.log.err(
        "session host manifest build_id drift: attempt={s} actual={s} (publishing actual)",
        .{ attempt_build_id, actual_build_id },
    );
}

fn activateValidated(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: entrypoint.RestoreInvocation,
    validated: *upgrade_bootstrap.RestoreValidated,
    rollback_allowed: *bool,
    notification_adapter: ?notification_os_delivery.Adapter,
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
    // **업그레이드 후계자도 훅 신원을 심는다.** 여기서 빠뜨리면 업그레이드 뒤 새로 뜨는 자식만
    // `MARU_HOOK_INSTANCE`/`MARU_HOOK_PANE` 없이 살아, 그 터미널의 훅이 영영 조용히 나간다(관측 모드로
    // 강등, 신호 없음). `invocation.host_id` 는 검증이 선임자와 같도록 강제한 값이라(§upgrade) 칸 이름이
    // exec 을 넘어 유지된다 — 그것이 pid 대신 host_id 를 쓰는 이유다(docs/agent-hooks.md §4).
    // 훅 로그 base 는 manager 보다 오래 살아야 한다 — 아래 `defer manager.deinit()` 보다 **먼저** 등록해
    // LIFO 로 나중에 풀리게 한다.
    const hook_log_base = agent_hook_logs.resolveCacheBase(allocator);
    defer if (hook_log_base) |base| allocator.free(base);
    manager.initWithHostId(allocator, io, &registry, invocation.host_id, if (hook_log_base) |base| .{
        .host_id = invocation.host_id,
        .log_base = base,
    } else null);
    defer manager.deinit();
    if (notification_adapter) |adapter| manager.installNotificationOsAdapter(adapter);
    manager.enableOutputWake() catch return error.RestoreFailed;
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
    server.owner_wake_fd = manager.outputWakeReadFd().?;
    server.owner_wake_ctx = &manager;
    server.owner_wake_drain = struct {
        fn drain(ctx: *anyopaque) bool {
            const owner: *runtime_manager.RuntimeManager =
                @ptrCast(@alignCast(ctx));
            return owner.drainOutputWake();
        }
    }.drain;

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
    // manifest 가 광고할 build_id 의 수명. 실제 이미지에서 구한 값을 쓸 때만 채워지고, `publish` 가 자기
    // 사본을 뜨므로 이 함수 밖으로 새어 나가지 않는다.
    var actual_build_id: ?[]u8 = null;
    defer if (actual_build_id) |b| allocator.free(b);
    if (invocation.role == .target) {
        ready.build_id = validated.state.attempt.build_id;
        ready.protocol_major = protocol.version_major;
        ready.screen_codec_version = screen_stream.codec_version;
        ready.upgrade_epoch = validated.state.attempt.expected_epoch_after;
        // **manifest 는 지금 돌고 있는 이미지를 광고해야 한다.**
        //
        // attempt record 의 build_id 는 전달 과정에서 실제와 어긋날 수 있고, 어긋나면 manifest 가 거짓이 된다.
        // 그러면 client 는 hello(진짜)와 manifest(거짓)의 불일치를 `stale_manifest` 로 읽고 **성공한 upgrade 를
        // 실패로 판정해** 새 host 를 띄운다. 2026-08-27 실측이 정확히 그랬다 — exec 는 성공해 host 가 새 이미지로
        // 갈아탔는데(`got=2680714d`) manifest 는 옛 값에 머물러(`want=b61d9ae1`), 앱을 켤 때마다 host 가 하나씩
        // 늘고 사용자 PTY 를 쥔 host 는 고아가 됐다.
        //
        // 진실의 단일 출처는 **실행 중인 바이너리**다. 이 대조는 양방향 모두 옳은 값으로 수렴한다 — exec 가
        // 됐는데 attempt 가 옛것이면 새 값을, exec 가 안 됐는데 attempt 가 새것이면 옛 값을 광고하게 되고,
        // 둘 다 client 의 hello 와 일치한다. 구하지 못하면 기존 동작 그대로 둔다(fail-open 이 아니라 무변경).
        if (selfImageBuildId(allocator, io)) |actual| {
            if (std.mem.eql(u8, actual, ready.build_id)) {
                allocator.free(actual);
            } else {
                logManifestBuildIdDrift(ready.build_id, actual);
                actual_build_id = actual;
                ready.build_id = actual;
            }
        }
    }
    var prepared_authority = try host_authority.HostAuthority.prepareInit(
        allocator,
        &server,
        ready,
    );
    defer prepared_authority.discard();
    const restored_authority_generation = std.math.add(
        u64,
        validated.state.host.authority_generation,
        2,
    ) catch return error.InvalidRestore;
    try prepared_authority.restoreAuthorityGeneration(restored_authority_generation);

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
    var owner = try poll_owner.Owner.init(upgrade_context.allocator, upgrade_context.io, server);
    defer owner.deinit();
    while (true) {
        owner.requireCurrentProcessOrFatal();
        server.tickOwner();
        switch (try owner.pollOnce(poll_timeout_ms)) {
            .upgrade_ready => {
                const marker = owner.takeArmedUpgrade() orelse return error.PostCommitFailStop;
                if (upgrade_loop.processPreclosed(marker, upgrade_context) == .fail_stop)
                    return error.PostCommitFailStop;
            },
            .idle => if (test_oneshot) {
                idle_ticks += 1;
                if (idle_ticks >= 25) return;
            },
            .progress => {},
            .listener_broken => return,
            .authority_lost => owner.requireCurrentProcessOrFatal(),
        }
        if (test_oneshot and owner.total_admitted != 0 and owner.activeCount() == 0) return;
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

test "CR4a restore exec bootstrap은 graph 접근 전에 fresh process seal을 게시한다" {
    const parent_marker = "maru-cr4a-restore-parent-v1";
    const child_marker = "maru-cr4a-restore-exec-v1";
    const marker = if (c.getenv("MARU_CR4A_RESTORE_EXEC_ROLE")) |raw_marker|
        std.mem.span(raw_marker)
    else
        null;
    if (marker != null and std.mem.eql(u8, marker.?, child_marker)) {
        const raw_expected_pid = c.getenv("MARU_CR4A_RESTORE_EXEC_PID") orelse
            return error.TestUnexpectedResult;
        const expected_pid = try std.fmt.parseInt(
            u32,
            std.mem.span(raw_expected_pid),
            10,
        );
        try std.testing.expectEqual(
            expected_pid,
            process_seal_service.currentProcessId(),
        );
        try std.testing.expectError(
            error.NotReady,
            process_seal_service.currentReadyIdentity(),
        );
        const published = try bootstrapProcessSeal();
        try std.testing.expectEqual(expected_pid, published.pid);
        try std.testing.expect(published.process_nonce != 0);
        try std.testing.expectEqualDeep(
            published,
            try process_seal_service.currentReadyIdentity(),
        );
        return;
    }
    if (marker == null) {
        if (process_seal_service.currentReadyIdentity()) |_| {
            return error.SkipZigTest;
        } else |err| switch (err) {
            error.NotReady => return error.TestUnexpectedResult,
            else => return err,
        }
    }
    if (!std.mem.eql(u8, marker.?, parent_marker))
        return error.TestUnexpectedResult;

    if (process_seal_service.currentReadyIdentity()) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.NotReady => {},
        else => return err,
    }

    const self_path = try std.process.executablePathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(self_path);
    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        // exec 직전에는 child PID에 결속된 ready seal이 실제로 존재해야 한다.
        // 같은 PID exec 뒤 위 child branch가 이를 NotReady로 관측해야 증거가 된다.
        _ = bootstrapProcessSeal() catch c._exit(125);
        var pid_env_buf: [96]u8 = undefined;
        const pid_env = std.fmt.bufPrintZ(
            &pid_env_buf,
            "MARU_CR4A_RESTORE_EXEC_PID={d}",
            .{process_seal_service.currentProcessId()},
        ) catch c._exit(125);
        const argv = [_:null]?[*:0]const u8{self_path.ptr};
        const child_env = [_:null]?[*:0]const u8{
            "MARU_CR4A_RESTORE_EXEC_ROLE=maru-cr4a-restore-exec-v1",
            pid_env.ptr,
        };
        _ = c.execve(self_path.ptr, &argv, &child_env);
        c._exit(127);
    }

    var status: c_int = 0;
    var reaped = false;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = c.waitpid(child, &status, std.posix.W.NOHANG);
        if (waited == child) {
            reaped = true;
            break;
        }
        if (waited < 0 and std.posix.errno(waited) != .INTR) break;
        _ = usleep(1000);
    }
    if (!reaped) {
        _ = c.kill(child, c.SIG.KILL);
        while (true) {
            const waited = c.waitpid(child, &status, 0);
            if (waited == child) break;
            if (waited >= 0 or std.posix.errno(waited) != .INTR) break;
        }
        return error.TestUnexpectedResult;
    }
    const unsigned_status: u32 = @bitCast(status);
    try std.testing.expect(c.W.IFEXITED(unsigned_status));
    try std.testing.expectEqual(@as(u32, 0), c.W.EXITSTATUS(unsigned_status));
}
