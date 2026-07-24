//! U3 new-image fixture. Frozen old fixture가 만든 inherited PTY와 handoff를 target-side prepared adoption으로 복구한다.

const std = @import("std");
const maru = @import("maru");
const session_host = @import("session_host");
const c = std.c;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

const pty_slot: c.fd_t = 40;
const primary_state_slot: c.fd_t = 41;
const backup_state_slot: c.fd_t = 42;
const owner_slot: c.fd_t = 43;
const host_id_sentinel: u128 = 0x102030405060708090A0B0C0D0E0F001;

fn readState(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.ReadFailed;
    var stat: std.posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.size < 0) return error.InvalidState;
    const len = std.math.cast(usize, stat.size) orelse return error.InvalidState;
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < len) {
        const rc = c.read(fd, bytes.ptr + offset, len - offset);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) return error.Truncated;
        offset += @intCast(rc);
    }
    return bytes;
}

fn preflight(allocator: std.mem.Allocator, scenario: []const u8) !void {
    try session_host.exec_fd_set.assertExactOpen(&.{primary_state_slot});
    const bytes = try readState(allocator, primary_state_slot);
    defer allocator.free(bytes);
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.host_id != host_id_sentinel or host.runtimes.len != 1 or
        host.runtimes[0].runtime_id != 0xAABBCCDD or host.runtimes[0].surface_id != 7 or
        host.runtimes[0].fd_slot != pty_slot)
        return error.IdentityMismatch;
    if (std.mem.eql(u8, scenario, "target-preflight-fail"))
        return error.InjectedPreflightFailure;
    if (std.mem.eql(u8, scenario, "target-preflight-hang")) {
        while (true) _ = usleep(1000);
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}

fn setCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0) return error.FcntlFailed;
}

fn writeStateFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0) return error.SyncFailed;
}

fn validateSecondState(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.host_id != host_id_sentinel or host.upgrade_epoch != 2 or host.runtimes.len != 1 or
        host.runtimes[0].runtime_id != 0xAABBCCDD or host.runtimes[0].fd_slot != pty_slot)
        return error.IdentityMismatch;
}

fn redirectStdioToDevNull() !void {
    const null_path: [*:0]const u8 = "/dev/null";
    const null_fd = c.open(null_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (null_fd < 0) return error.OpenFailed;
    defer {
        if (null_fd > 2) _ = c.close(null_fd);
    }
    var stdio_fd: c.fd_t = 0;
    while (stdio_fd <= 2) : (stdio_fd += 1) {
        if (c.dup2(null_fd, stdio_fd) < 0) return error.DupFailed;
    }
}

const PreflightOutcome = enum { passed, rejected, cleanup_failed };
const TargetLaunch = struct {
    rollback_path: [:0]const u8,
    result_path: [:0]const u8,
    scenario: [:0]const u8,
    owner_dir: [:0]const u8,
    target_dev: [:0]const u8,
    target_ino: [:0]const u8,
    target_size: [:0]const u8,
    target_sha: [:0]const u8,
    rollback_dev: [:0]const u8,
    rollback_ino: [:0]const u8,
    rollback_size: [:0]const u8,
    rollback_sha: [:0]const u8,
};

fn killAndReap(pid: c.pid_t) bool {
    _ = c.kill(pid, .KILL);
    var status: c_int = undefined;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid) return true;
        if (waited < 0 and std.posix.errno(waited) != .INTR) return false;
        _ = usleep(1000);
    }
    return false;
}

fn runTargetPreflight(
    io: std.Io,
    target_path: [:0]const u8,
    primary_fd: c.fd_t,
    launch: TargetLaunch,
) PreflightOutcome {
    const pid = c.fork();
    if (pid < 0) return .cleanup_failed;
    if (pid == 0) {
        redirectStdioToDevNull() catch c._exit(135);
        var slots: session_host.exec_fd_set.PreparedSlots = .{};
        slots.prepare(primary_fd, primary_state_slot) catch c._exit(135);
        slots.assertExactNonCloexec(&.{primary_state_slot}) catch c._exit(135);
        const preflight_arg: [*:0]const u8 = "--upgrade-preflight";
        const argv = [_:null]?[*:0]const u8{
            target_path.ptr,
            preflight_arg,
            launch.rollback_path.ptr,
            launch.result_path.ptr,
            launch.scenario.ptr,
            launch.owner_dir.ptr,
            launch.target_dev.ptr,
            launch.target_ino.ptr,
            launch.target_size.ptr,
            launch.target_sha.ptr,
            launch.rollback_dev.ptr,
            launch.rollback_ino.ptr,
            launch.rollback_size.ptr,
            launch.rollback_sha.ptr,
        };
        _ = execv(target_path.ptr, &argv);
        c._exit(135);
    }
    var status: c_int = undefined;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid) return if (status == 0) .passed else .rejected;
        if (waited < 0 and std.posix.errno(waited) != .INTR)
            return if (killAndReap(pid)) .cleanup_failed else .cleanup_failed;
        _ = usleep(1000);
    }
    return if (killAndReap(pid)) .rejected else .cleanup_failed;
}

fn writeResult(path: []const u8, text: []const u8, allocator: std.mem.Allocator) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < text.len) {
        const rc = c.write(fd, text.ptr + offset, text.len - offset);
        if (rc <= 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}

fn finishRuntime(
    allocator: std.mem.Allocator,
    session: *maru.pty.PtySession,
    core: *maru.terminal.TerminalCore,
) !void {
    try session.writeInput("v2\n");
    while (true) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);
        switch (event) {
            .output => |output| try core.write(output),
            .exited => |status| {
                switch (status) {
                    .exited => |code| if (code != 23) return error.WrongExit,
                    else => return error.WrongExit,
                }
                break;
            },
        }
    }
    if (try session.reapIfExited() != null) return error.DoubleReap;
    const dump = try core.dumpUtf8(allocator);
    defer allocator.free(dump);
    if (std.mem.indexOf(u8, dump, "MIGRATED:v2") == null or core.parser != .ground)
        return error.ParserContinuationFailed;
}

fn isSecondAttemptScenario(scenario: []const u8) bool {
    return std.mem.eql(u8, scenario, "two-upgrade") or
        std.mem.eql(u8, scenario, "second-preflight-fail") or
        std.mem.eql(u8, scenario, "second-exec-fail");
}

fn resumeAfterSecondAttemptFailure(
    ctx: Context,
    session: *maru.pty.PtySession,
    runtime: *session_host.handoff_codec.RuntimeState,
    host: *session_host.handoff_codec.HostState,
) !void {
    try finishRuntime(ctx.allocator, session, &runtime.core);
    const result = try std.fmt.allocPrint(
        ctx.allocator,
        "host_pid={d}\nchild_pid={d}\nhost_id={x}\nruntime_id={x}\nfirst_upgrade=committed\nsecond_upgrade=resumed\nsecond_precommit_failed_resumed=ok\nowner_lease=ok\nparser=ground\nexit=23\n",
        .{ c.getpid(), runtime.child_pid, host.host_id, runtime.runtime_id },
    );
    defer ctx.allocator.free(result);
    try writeResult(ctx.result_path, result, ctx.allocator);
}

fn rollbackTargetV2(allocator: std.mem.Allocator, result_path: []const u8, owner_dir: []const u8) !void {
    try session_host.exec_fd_set.assertExactOpen(&.{ pty_slot, primary_state_slot, backup_state_slot, owner_slot });
    var owner = try session_host.owner_lease.OwnerLease.adoptInherited(owner_slot);
    defer owner.deinit();
    const owner_z = try std.fmt.allocPrintSentinel(allocator, "{s}/owner.lock", .{owner_dir}, 0);
    defer allocator.free(owner_z);
    try std.testing.expectError(error.AlreadyOwned, session_host.owner_lease.OwnerLease.acquire(owner_z));
    const bytes = try readState(allocator, backup_state_slot);
    defer allocator.free(bytes);
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.host_id != host_id_sentinel or host.upgrade_epoch != 2 or host.runtimes.len != 1)
        return error.IdentityMismatch;
    const runtime = &host.runtimes[0];
    var prepared = try maru.pty.PtySession.PreparedAdoption.prepareExact(
        pty_slot,
        runtime.child_pid,
        .{ .cols = runtime.cols, .rows = runtime.rows },
        .{ .dev = runtime.pty_dev, .ino = runtime.pty_ino, .rdev = runtime.pty_rdev },
    );
    defer prepared.discard();
    var session = prepared.commit();
    defer session.deinit();
    _ = c.close(pty_slot);
    _ = c.close(primary_state_slot);
    _ = c.close(backup_state_slot);
    _ = c.close(owner_slot);
    try finishRuntime(allocator, &session, &runtime.core);
    const result = try std.fmt.allocPrint(
        allocator,
        "host_pid={d}\nchild_pid={d}\nhost_id={x}\nruntime_id={x}\nfirst_upgrade=committed\nsecond_upgrade=rolled_back\nrollback_image=v2\nowner_lease=ok\nparser=ground\nexit=23\n",
        .{ c.getpid(), runtime.child_pid, host.host_id, runtime.runtime_id },
    );
    defer allocator.free(result);
    try writeResult(result_path, result, allocator);
}

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    old_path: []const u8,
    result_path: []const u8,
    scenario: []const u8,
    owner_dir: []const u8,
    target_identity: session_host.staged_image.Identity,
    rollback_identity: session_host.staged_image.Identity,
    next_path: []const u8,
};

fn rollback(ctx: Context) noreturn {
    // Target-created state는 전혀 commit하지 않았으므로 backup offset만 되감아 frozen old image로 돌아간다.
    if (c.lseek(backup_state_slot, 0, c.SEEK.SET) < 0) c._exit(121);
    const old_z = ctx.allocator.dupeZ(u8, ctx.old_path) catch c._exit(122);
    const result_z = ctx.allocator.dupeZ(u8, ctx.result_path) catch c._exit(122);
    const owner_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{ctx.owner_dir}, 0) catch c._exit(122);
    const actual_rollback = session_host.staged_image.inspect(old_z) catch c._exit(121);
    if (!session_host.staged_image.identityEqual(ctx.rollback_identity, actual_rollback)) c._exit(121);
    const rollback_dev_z = std.fmt.allocPrintSentinel(ctx.allocator, "{d}", .{ctx.rollback_identity.dev}, 0) catch c._exit(122);
    const rollback_ino_z = std.fmt.allocPrintSentinel(ctx.allocator, "{d}", .{ctx.rollback_identity.ino}, 0) catch c._exit(122);
    const rollback_size_z = std.fmt.allocPrintSentinel(ctx.allocator, "{d}", .{ctx.rollback_identity.size}, 0) catch c._exit(122);
    const rollback_sha_hex = std.fmt.bytesToHex(ctx.rollback_identity.sha256, .lower);
    const rollback_sha_z = ctx.allocator.dupeZ(u8, &rollback_sha_hex) catch c._exit(122);
    const rollback_arg: [*:0]const u8 = "--rollback-target";
    const argv = [_:null]?[*:0]const u8{
        old_z.ptr,
        rollback_arg,
        result_z.ptr,
        owner_z.ptr,
        rollback_dev_z.ptr,
        rollback_ino_z.ptr,
        rollback_size_z.ptr,
        rollback_sha_z.ptr,
    };
    _ = execv(old_z.ptr, &argv);
    // rollback exec 실패는 재귀 재시도하지 않는 fail-stop이다.
    c._exit(123);
}

fn restore(ctx: Context) !void {
    const allocator = ctx.allocator;
    try session_host.exec_fd_set.assertExactOpen(&.{ pty_slot, primary_state_slot, backup_state_slot, owner_slot });
    const bytes = try readState(allocator, primary_state_slot);
    defer allocator.free(bytes);
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.runtimes.len != 1 or host.host_id != host_id_sentinel or
        host.runtimes[0].runtime_id != 0xAABBCCDD or host.runtimes[0].surface_id != 7 or
        host.runtimes[0].fd_slot != pty_slot) return error.IdentityMismatch;

    const runtime = &host.runtimes[0];
    const staged_target_path = try std.fmt.allocPrintSentinel(allocator, "{s}/target-current", .{ctx.owner_dir}, 0);
    defer allocator.free(staged_target_path);
    const staged_target_identity = try session_host.staged_image.inspect(staged_target_path);
    if (!session_host.staged_image.identityEqual(ctx.target_identity, staged_target_identity))
        return error.StagedIdentityChanged;
    if (std.mem.eql(u8, ctx.scenario, "target-adopt-fail")) return error.InjectedAdoptionFailure;
    var prepared = try maru.pty.PtySession.PreparedAdoption.prepareExact(
        pty_slot,
        runtime.child_pid,
        .{ .cols = runtime.cols, .rows = runtime.rows },
        .{ .dev = runtime.pty_dev, .ino = runtime.pty_ino, .rdev = runtime.pty_rdev },
    );
    defer prepared.discard();
    if (std.mem.eql(u8, ctx.scenario, "target-rollback")) return error.InjectedPreCommitFailure;
    var owner = try session_host.owner_lease.OwnerLease.adoptInherited(owner_slot);
    defer owner.deinit();
    const owner_z = try std.fmt.allocPrintSentinel(allocator, "{s}/owner.lock", .{ctx.owner_dir}, 0);
    defer allocator.free(owner_z);
    try std.testing.expectError(error.AlreadyOwned, session_host.owner_lease.OwnerLease.acquire(owner_z));
    var session = prepared.commit();
    defer session.deinit();
    _ = c.close(pty_slot);
    _ = c.close(primary_state_slot);
    _ = c.close(backup_state_slot);
    _ = c.close(owner_slot);
    if (!session.upgradeEligible()) c._exit(124);
    if (isSecondAttemptScenario(ctx.scenario)) {
        upgradeAgain(ctx, &session, &owner, runtime, &host, staged_target_identity) catch {
            resumeAfterSecondAttemptFailure(ctx, &session, runtime, &host) catch c._exit(124);
            c._exit(0);
        };
    } else {
        serveCommitted(ctx, &session, runtime, &host, staged_target_identity) catch c._exit(124);
    }
    c._exit(0);
}

fn upgradeAgain(
    ctx: Context,
    session: *maru.pty.PtySession,
    owner: *session_host.owner_lease.OwnerLease,
    runtime: *session_host.handoff_codec.RuntimeState,
    host: *session_host.handoff_codec.HostState,
    staged_target_identity: session_host.staged_image.Identity,
) !void {
    const allocator = ctx.allocator;
    const owner_dir_z = try allocator.dupeZ(u8, ctx.owner_dir);
    defer allocator.free(owner_dir_z);
    const self_path = try std.fmt.allocPrintSentinel(allocator, "{s}/self-current", .{ctx.owner_dir}, 0);
    defer allocator.free(self_path);
    const first_target_path = try std.fmt.allocPrintSentinel(allocator, "{s}/target-current", .{ctx.owner_dir}, 0);
    defer allocator.free(first_target_path);
    const previous_path = try std.fmt.allocPrintSentinel(allocator, "{s}/self-previous", .{ctx.owner_dir}, 0);
    defer allocator.free(previous_path);
    try session_host.staged_image.promote(
        owner_dir_z,
        first_target_path,
        staged_target_identity,
        self_path,
        previous_path,
        .none,
    );

    const next_path_z = try allocator.dupeZ(u8, ctx.next_path);
    defer allocator.free(next_path_z);
    var next_image = try session_host.staged_image.stage(allocator, next_path_z, owner_dir_z, "target-current");
    defer next_image.deinit();

    const pty_identity = try session.masterIdentity();
    const runtimes = [_]session_host.handoff_codec.RuntimeView{.{
        .runtime_id = runtime.runtime_id,
        .surface_id = runtime.surface_id,
        .child_pid = runtime.child_pid,
        .cols = runtime.cols,
        .rows = runtime.rows,
        .resize_generation = runtime.resize_generation,
        .fd_slot = pty_slot,
        .pty_dev = pty_identity.dev,
        .pty_ino = pty_identity.ino,
        .pty_rdev = pty_identity.rdev,
        .core = &runtime.core,
    }};
    const bytes = try session_host.handoff_codec.encodeHost(allocator, .{
        .host_id = host.host_id,
        .upgrade_epoch = 2,
        .next_handle = host.next_handle,
        .runtimes = &runtimes,
    });
    defer allocator.free(bytes);
    const primary_path = try std.fmt.allocPrintSentinel(allocator, "{s}/second-primary", .{ctx.owner_dir}, 0);
    defer allocator.free(primary_path);
    const backup_path = try std.fmt.allocPrintSentinel(allocator, "{s}/second-backup", .{ctx.owner_dir}, 0);
    defer allocator.free(backup_path);
    try writeStateFile(primary_path, bytes);
    try writeStateFile(backup_path, bytes);
    const primary_fd = c.open(primary_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (primary_fd < 0) return error.OpenFailed;
    defer _ = c.close(primary_fd);
    const backup_fd = c.open(backup_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (backup_fd < 0) return error.OpenFailed;
    defer _ = c.close(backup_fd);
    try setCloseOnExec(primary_fd);
    try setCloseOnExec(backup_fd);
    const primary_readback = try readState(allocator, primary_fd);
    defer allocator.free(primary_readback);
    const backup_readback = try readState(allocator, backup_fd);
    defer allocator.free(backup_readback);
    if (!std.mem.eql(u8, primary_readback, backup_readback)) return error.StateMismatch;
    try validateSecondState(allocator, primary_readback);
    const scenario_z = try allocator.dupeZ(u8, ctx.scenario);
    defer allocator.free(scenario_z);
    const result_z = try allocator.dupeZ(u8, ctx.result_path);
    defer allocator.free(result_z);
    const target_dev_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{next_image.identity.dev}, 0);
    defer allocator.free(target_dev_z);
    const target_ino_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{next_image.identity.ino}, 0);
    defer allocator.free(target_ino_z);
    const target_size_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{next_image.identity.size}, 0);
    defer allocator.free(target_size_z);
    const target_sha_hex = std.fmt.bytesToHex(next_image.identity.sha256, .lower);
    const target_sha_z = try allocator.dupeZ(u8, &target_sha_hex);
    defer allocator.free(target_sha_z);
    const rollback_dev_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{staged_target_identity.dev}, 0);
    defer allocator.free(rollback_dev_z);
    const rollback_ino_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{staged_target_identity.ino}, 0);
    defer allocator.free(rollback_ino_z);
    const rollback_size_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{staged_target_identity.size}, 0);
    defer allocator.free(rollback_size_z);
    const rollback_sha_hex = std.fmt.bytesToHex(staged_target_identity.sha256, .lower);
    const rollback_sha_z = try allocator.dupeZ(u8, &rollback_sha_hex);
    defer allocator.free(rollback_sha_z);
    const target_launch: TargetLaunch = .{
        .rollback_path = self_path,
        .result_path = result_z,
        .scenario = scenario_z,
        .owner_dir = owner_dir_z,
        .target_dev = target_dev_z,
        .target_ino = target_ino_z,
        .target_size = target_size_z,
        .target_sha = target_sha_z,
        .rollback_dev = rollback_dev_z,
        .rollback_ino = rollback_ino_z,
        .rollback_size = rollback_size_z,
        .rollback_sha = rollback_sha_z,
    };
    if (runTargetPreflight(ctx.io, next_image.path, primary_fd, target_launch) != .passed) return error.TargetPreflightFailed;
    if (c.unlink(primary_path.ptr) != 0 or c.unlink(backup_path.ptr) != 0) return error.UnlinkFailed;

    var slots: session_host.exec_fd_set.PreparedSlots = .{};
    defer slots.rollback();
    try slots.prepare(session.inheritedMasterFd().?, pty_slot);
    try slots.prepare(primary_fd, primary_state_slot);
    try slots.prepare(backup_fd, backup_state_slot);
    try slots.prepare(owner.descriptor(), owner_slot);
    try slots.assertExactNonCloexec(&.{});

    const argv = [_:null]?[*:0]const u8{
        next_image.path.ptr,
        self_path.ptr,
        result_z.ptr,
        scenario_z.ptr,
        owner_dir_z.ptr,
        target_dev_z.ptr,
        target_ino_z.ptr,
        target_size_z.ptr,
        target_sha_z.ptr,
        rollback_dev_z.ptr,
        rollback_ino_z.ptr,
        rollback_size_z.ptr,
        rollback_sha_z.ptr,
    };
    if (std.mem.eql(u8, ctx.scenario, "second-exec-fail")) {
        const missing: [*:0]const u8 = "/definitely/missing/maru-upgrade-next";
        _ = execv(missing, &argv);
    } else {
        _ = execv(next_image.path.ptr, &argv);
    }
    return error.ExecFailed;
}

/// Irreversible PTY ownership commit 뒤의 오류는 old-image rollback으로 돌아가지 않는다.
fn serveCommitted(
    ctx: Context,
    session: *maru.pty.PtySession,
    runtime: *session_host.handoff_codec.RuntimeState,
    host: *session_host.handoff_codec.HostState,
    staged_target_identity: session_host.staged_image.Identity,
) !void {
    const allocator = ctx.allocator;
    const self_path = try std.fmt.allocPrintSentinel(allocator, "{s}/self-current", .{ctx.owner_dir}, 0);
    defer allocator.free(self_path);
    const target_path = try std.fmt.allocPrintSentinel(allocator, "{s}/target-current", .{ctx.owner_dir}, 0);
    defer allocator.free(target_path);
    const previous_path = try std.fmt.allocPrintSentinel(allocator, "{s}/self-previous", .{ctx.owner_dir}, 0);
    defer allocator.free(previous_path);
    const owner_dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{ctx.owner_dir}, 0);
    defer allocator.free(owner_dir_z);
    const inject_promotion = std.mem.eql(u8, ctx.scenario, "target-promotion-fail");
    const promotion = session_host.staged_image.promote(
        owner_dir_z,
        target_path,
        staged_target_identity,
        self_path,
        previous_path,
        if (inject_promotion) .before_swap else .none,
    );
    // promotion은 commit 이후 bookkeeping이다. 실패하면 runtime을 rollback/종료하지 않고 다음 upgrade capability만 철회한다.
    var capability: []const u8 = "enabled";
    if (promotion) |_| {} else |_| {
        capability = "withdrawn";
    }

    try session.writeInput("hello\n");
    var exit_ok = false;
    while (!exit_ok) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);
        switch (event) {
            .output => |output| try runtime.core.write(output),
            .exited => |status| switch (status) {
                .exited => |code| {
                    if (code != 23) return error.WrongExit;
                    exit_ok = true;
                },
                else => return error.WrongExit,
            },
        }
    }
    if (try session.reapIfExited() != null) return error.DoubleReap;
    const dump = try runtime.core.dumpUtf8(allocator);
    defer allocator.free(dump);
    if (std.mem.indexOf(u8, dump, "MIGRATED:hello") == null or runtime.core.parser != .ground)
        return error.ParserContinuationFailed;

    const result = try std.fmt.allocPrint(
        allocator,
        "host_pid={d}\nchild_pid={d}\nhost_id={x}\nruntime_id={x}\nowner_lease=ok\nparser=ground\nexit=23\ninput_output=ok\nupgrade_capability={s}\n",
        .{ c.getpid(), runtime.child_pid, host.host_id, runtime.runtime_id, capability },
    );
    defer allocator.free(result);
    try writeResult(ctx.result_path, result, allocator);
}

fn parseIdentity(args: anytype) !session_host.staged_image.Identity {
    const dev = try std.fmt.parseInt(i64, args.next() orelse return error.MissingArgument, 10);
    const ino = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const size = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const sha_hex = args.next() orelse return error.MissingArgument;
    if (sha_hex.len != 64) return error.InvalidIdentity;
    var sha256: [32]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&sha256, sha_hex);
    if (decoded.len != sha256.len) return error.InvalidIdentity;
    return .{ .dev = dev, .ino = ino, .size = size, .sha256 = sha256 };
}

fn parseContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    old_path: []const u8,
    args: anytype,
) !Context {
    const result_path = args.next() orelse return error.MissingArgument;
    const scenario = args.next() orelse return error.MissingArgument;
    const owner_dir = args.next() orelse return error.MissingArgument;
    const target_identity = try parseIdentity(args);
    const rollback_identity = try parseIdentity(args);
    const next_path = args.next() orelse return error.MissingArgument;
    if (args.next() != null) return error.UnexpectedArgument;
    return .{
        .allocator = allocator,
        .io = io,
        .old_path = old_path,
        .result_path = result_path,
        .scenario = scenario,
        .owner_dir = owner_dir,
        .target_identity = target_identity,
        .rollback_identity = rollback_identity,
        .next_path = next_path,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    const executable_path = args.next() orelse return error.MissingArgument;
    const mode_or_old_path = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, mode_or_old_path, "--upgrade-preflight")) {
        const preflight_old_path = args.next() orelse return error.MissingArgument;
        const preflight_ctx = try parseContext(allocator, init.io, preflight_old_path, &args);
        return preflight(allocator, preflight_ctx.scenario);
    }
    if (std.mem.eql(u8, mode_or_old_path, "--rollback-target-v2")) {
        const result_path = args.next() orelse return error.MissingArgument;
        const owner_dir = args.next() orelse return error.MissingArgument;
        const rollback_dev = try std.fmt.parseInt(i64, args.next() orelse return error.MissingArgument, 10);
        const rollback_ino = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
        const rollback_size = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
        const rollback_sha_hex = args.next() orelse return error.MissingArgument;
        if (rollback_sha_hex.len != 64 or args.next() != null) return error.InvalidIdentity;
        var rollback_sha256: [32]u8 = undefined;
        const rollback_decoded = try std.fmt.hexToBytes(&rollback_sha256, rollback_sha_hex);
        if (rollback_decoded.len != rollback_sha256.len) return error.InvalidIdentity;
        if (!session_host.staged_image.identityEqual(
            .{ .dev = rollback_dev, .ino = rollback_ino, .size = rollback_size, .sha256 = rollback_sha256 },
            try session_host.staged_image.inspect(executable_path),
        )) return error.StagedIdentityChanged;
        return rollbackTargetV2(allocator, result_path, owner_dir);
    }
    const ctx = try parseContext(allocator, init.io, mode_or_old_path, &args);
    restore(ctx) catch rollback(ctx);
}
