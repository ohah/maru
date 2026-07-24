//! Frozen U3 old-image fixture. 이 파일은 old side wire/exec 동작이므로 schema 변경 때 current helper처럼 고치지 않는다.

const std = @import("std");
const maru = @import("maru");
const session_host = @import("session_host");
const c = std.c;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const pty_slot: c.fd_t = 40;
const primary_state_slot: c.fd_t = 41;
const backup_state_slot: c.fd_t = 42;
const owner_slot: c.fd_t = 43;
const host_id_sentinel: u128 = 0x102030405060708090A0B0C0D0E0F001;

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

fn readState(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.ReadFailed;
    var stat: std.posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.size < 0) return error.InvalidState;
    const bytes = try allocator.alloc(u8, std.math.cast(usize, stat.size) orelse return error.InvalidState);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc <= 0) return error.ReadFailed;
        offset += @intCast(rc);
    }
    return bytes;
}

fn writeResult(path: []const u8, text: []const u8, allocator: std.mem.Allocator) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeAll(fd, text);
}

fn finishRuntime(
    allocator: std.mem.Allocator,
    session: *maru.pty.PtySession,
    core: *maru.terminal.TerminalCore,
    input: []const u8,
    expected: []const u8,
) !void {
    try session.writeInput(input);
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
    if (std.mem.indexOf(u8, dump, expected) == null or core.parser != .ground)
        return error.ParserContinuationFailed;
}

fn rollbackTarget(allocator: std.mem.Allocator, result_path: []const u8, owner_dir: []const u8) !void {
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
    if (host.runtimes.len != 1 or host.host_id != host_id_sentinel) return error.IdentityMismatch;
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
    try finishRuntime(allocator, &session, &runtime.core, "rollback\n", "MIGRATED:rollback");
    const result = try std.fmt.allocPrint(
        allocator,
        "host_pid={d}\nchild_pid={d}\nhost_id={x}\nruntime_id={x}\nrollback=ok\nowner_lease=ok\nparser=ground\nexit=23\n",
        .{ c.getpid(), runtime.child_pid, host.host_id, runtime.runtime_id },
    );
    defer allocator.free(result);
    try writeResult(result_path, result, allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    const executable_path = args.next() orelse return error.MissingArgument;
    const new_path = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, new_path, "--rollback-target")) {
        const rollback_result = args.next() orelse return error.MissingArgument;
        const rollback_owner_dir = args.next() orelse return error.MissingArgument;
        return rollbackTarget(allocator, rollback_result, rollback_owner_dir);
    }
    const state_path = args.next() orelse return error.MissingArgument;
    const result_path = args.next() orelse return error.MissingArgument;
    const scenario = args.next() orelse "success";
    const owner_dir = args.next() orelse return error.MissingArgument;
    const owner_dir_z = try allocator.dupeZ(u8, owner_dir);
    defer allocator.free(owner_dir_z);
    var self_image = try session_host.staged_image.stage(allocator, executable_path, owner_dir_z, "self-current");
    defer self_image.deinit();
    var target_image = try session_host.staged_image.stage(allocator, new_path, owner_dir_z, "target-current");
    defer target_image.deinit();
    const owner_z = try std.fmt.allocPrintSentinel(allocator, "{s}/owner.lock", .{owner_dir}, 0);
    defer allocator.free(owner_z);
    var owner = try session_host.owner_lease.OwnerLease.acquire(owner_z);
    defer owner.deinit();

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "stty raw -echo; printf '\\033[31'; IFS= read -r line; printf 'mMIGRATED:%s\\r\\n' \"$line\"; exit 23" },
        .size = .{ .cols = 20, .rows = 4 },
    });
    defer session.deinit();
    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    while (core.parser != .csi) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);
        switch (event) {
            .output => |bytes| try core.write(bytes),
            .exited => return error.ChildExitedBeforeHandoff,
        }
    }

    const pty_identity = try session.masterIdentity();
    const runtime = [_]session_host.handoff_codec.RuntimeView{.{
        .runtime_id = 0xAABBCCDD,
        .surface_id = 7,
        .child_pid = session.childPid(),
        .cols = 20,
        .rows = 4,
        .resize_generation = 9,
        .fd_slot = pty_slot,
        .pty_dev = pty_identity.dev,
        .pty_ino = pty_identity.ino,
        .pty_rdev = pty_identity.rdev,
        .core = &core,
    }};
    const bytes = try session_host.handoff_codec.encodeHost(allocator, .{
        .host_id = host_id_sentinel,
        .upgrade_epoch = 1,
        .next_handle = 8,
        .runtimes = &runtime,
    });
    defer allocator.free(bytes);

    const state_z = try allocator.dupeZ(u8, state_path);
    defer allocator.free(state_z);
    const backup_z = try std.fmt.allocPrintSentinel(allocator, "{s}.backup", .{state_path}, 0);
    defer allocator.free(backup_z);
    const paths = [_][:0]const u8{ state_z, backup_z };
    for (paths) |path| {
        const write_fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (write_fd < 0) return error.OpenFailed;
        errdefer _ = c.close(write_fd);
        try writeAll(write_fd, bytes);
        if (c.fsync(write_fd) != 0) return error.SyncFailed;
        _ = c.close(write_fd);
    }
    if (std.mem.eql(u8, scenario, "target-decode-fail")) {
        const corrupt_fd = c.open(state_z.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
        if (corrupt_fd < 0) return error.OpenFailed;
        defer _ = c.close(corrupt_fd);
        const corrupt = [_]u8{0};
        if (c.write(corrupt_fd, &corrupt, 1) != 1) return error.WriteFailed;
        if (c.fsync(corrupt_fd) != 0) return error.SyncFailed;
    }
    const primary_read_fd = c.open(state_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (primary_read_fd < 0) return error.OpenFailed;
    defer _ = c.close(primary_read_fd);
    const backup_read_fd = c.open(backup_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (backup_read_fd < 0) return error.OpenFailed;
    defer _ = c.close(backup_read_fd);
    try setCloseOnExec(primary_read_fd);
    try setCloseOnExec(backup_read_fd);
    if (c.unlink(state_z.ptr) != 0 or c.unlink(backup_z.ptr) != 0) return error.UnlinkFailed;

    var slots: session_host.exec_fd_set.PreparedSlots = .{};
    defer slots.rollback();
    try slots.prepare(session.inheritedMasterFd().?, pty_slot);
    try slots.prepare(primary_read_fd, primary_state_slot);
    try slots.prepare(backup_read_fd, backup_state_slot);
    try slots.prepare(owner.descriptor(), owner_slot);
    try slots.assertExactNonCloexec(&.{});

    const result_z = try allocator.dupeZ(u8, result_path);
    defer allocator.free(result_z);
    const scenario_z = try allocator.dupeZ(u8, scenario);
    defer allocator.free(scenario_z);
    if (std.mem.eql(u8, scenario, "old-exec-fail")) {
        const missing: [*:0]const u8 = "/definitely/missing/maru-upgrade-target";
        const bad_argv = [_:null]?[*:0]const u8{missing};
        _ = execv(missing, &bad_argv);
        slots.rollback();
        if (session_host.owner_lease.OwnerLease.acquire(owner_z)) |replacement_value| {
            var replacement = replacement_value;
            replacement.deinit();
            return error.OwnerLeaseLost;
        } else |err| if (err != error.AlreadyOwned) return err;
        try finishRuntime(allocator, &session, &core, "old-resume\n", "MIGRATED:old-resume");
        return writeResult(result_path, "old_exec_failed_resumed=ok\nowner_lease=ok\nparser=ground\nexit=23\n", allocator);
    }
    const argv = [_:null]?[*:0]const u8{ target_image.path.ptr, self_image.path.ptr, result_z.ptr, scenario_z.ptr, owner_dir_z.ptr };
    _ = execv(target_image.path.ptr, &argv);
    return error.ExecFailed;
}
