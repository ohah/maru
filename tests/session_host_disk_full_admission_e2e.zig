//! Actual HFS+ ENOSPC가 pre-quiesce admission에서 old daemon/runtime을 보존하는지 검증한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const sh = @import("session_host");

extern "c" fn getdtablesize() c_int;
extern "c" fn usleep(usec: c_uint) c_int;
const sol_local: c_int = 0;
const local_peerpid: c_int = 0x002;

test "actual disk full admission resumes before quiesce and keeps daemon live" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mount_raw = c.getenv("MARU_SESSION_HOST_DISK_FULL_MOUNT") orelse return error.SkipZigTest;
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    const product_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        std.mem.span(product_raw),
        allocator,
    );
    defer allocator.free(product_path);
    const product_z = try allocator.dupeZ(u8, product_path);
    defer allocator.free(product_z);
    const target_identity = try sh.staged_image.inspect(product_z);
    const target_build_id = try sh.host_manifest.buildIdForExecutable(allocator, product_z);
    defer allocator.free(target_build_id);

    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x4449534b46554c4c;
    const attempt_id: u128 = host_id ^ 0x41444d495353494f;
    var base_buf: [1024]u8 = undefined;
    const base = try std.fmt.bufPrintZ(
        &base_buf,
        "{s}/maru-disk-full-{d}",
        .{ std.mem.span(mount_raw), c.getpid() },
    );
    try std.Io.Dir.cwd().createDir(std.testing.io, base, .default_dir);
    var session_buf: [1152]u8 = undefined;
    const session_dir = try sh.discovery.sessionHostDirPath(&session_buf, base);
    try std.Io.Dir.cwd().createDir(std.testing.io, session_dir, .default_dir);
    try sh.short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket_path = try sh.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    var host_dir_buf: [1280]u8 = undefined;
    const host_dir = try sh.host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id);
    var attempt_buf: [1408]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ host_dir, attempt_id },
    );
    var filler_buf: [1408]u8 = undefined;
    const filler_path = try std.fmt.bufPrintZ(
        &filler_buf,
        "{s}/.disk-full-fixture-{x:0>32}",
        .{ host_dir, attempt_id },
    );

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    var child_reaped = false;
    defer {
        if (!child_reaped) {
            _ = c.kill(child, posix.SIG.KILL);
            _ = c.waitpid(child, null, 0);
        }
        _ = c.unlink(socket_path.ptr);
        std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    }
    if (child == 0) {
        var inherited_fd: c_int = 3;
        while (inherited_fd < getdtablesize()) : (inherited_fd += 1) _ = c.close(inherited_fd);
        sh.daemon.runSessionHostWithDiskFullAdmissionFixture(
            std.heap.page_allocator,
            std.testing.io,
            session_dir,
            socket_path,
            host_id,
        ) catch c._exit(75);
        c._exit(0);
    }

    var gui = try connectUntilReady(allocator, socket_path);
    const spawn_response = try gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/sh\",\"-c\",\"sleep 60\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(spawn_response);
    const runtime_hex = sh.client.extractRuntimeId(spawn_response) orelse return error.TestUnexpectedResult;
    const runtime_id = try std.fmt.parseInt(u128, &runtime_hex, 16);
    var sibling = try sh.client.Client.connect(allocator, socket_path, .cli_probe);
    defer sibling.deinit();

    const outcome = try gui.prepareUpgrade(.{
        .attempt_id = attempt_id,
        .target_path = product_path,
        .target_build_id = target_build_id,
        .target_sha256 = target_identity.sha256,
        .handoff_reader_min = sh.handoff_codec.reader_min,
        .handoff_reader_max = sh.handoff_codec.reader_max,
    });
    switch (outcome) {
        .accepted_reconnect_required => {},
        else => return error.TestUnexpectedResult,
    }
    gui.deinit();

    var after = try connectUntilReady(allocator, socket_path);
    defer after.deinit();
    const report = try waitForTerminal(&after, attempt_id);
    try std.testing.expectEqual(sh.upgrade_wire.AttemptStatus.resumed, report.status);
    try std.testing.expectEqual(sh.upgrade_wire.AttemptReason.state_too_large, report.reason);
    try std.testing.expectEqual(@as(c.pid_t, child), try peerPid(after.fd));
    try std.testing.expectError(error.WriteFailed, sibling.call("host.info", null));
    const info = try after.call("host.info", null);
    defer allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "host_id") != null);
    var inventory = try after.runtimeInventory();
    switch (inventory) {
        .complete => |*complete| {
            defer complete.deinit(allocator);
            try std.testing.expectEqualSlices(u128, &.{runtime_id}, complete.runtime_ids);
        },
        .unavailable => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(c_int, -1), c.access(attempt_path.ptr, c.F_OK));
    try std.testing.expectEqual(posix.E.NOENT, posix.errno(-1));
    try std.testing.expectEqual(@as(c_int, -1), c.access(filler_path.ptr, c.F_OK));
    try std.testing.expectEqual(posix.E.NOENT, posix.errno(-1));

    var terminate_buf: [80]u8 = undefined;
    const terminate_params = try std.fmt.bufPrint(
        &terminate_buf,
        "{{\"runtime_id\":\"{s}\"}}",
        .{runtime_hex},
    );
    const terminate = try after.call("runtime.terminate", terminate_params);
    defer allocator.free(terminate);
    try std.testing.expect(std.mem.indexOf(u8, terminate, "terminated") != null);

    _ = c.kill(child, posix.SIG.KILL);
    _ = c.waitpid(child, null, 0);
    child_reaped = true;
}

fn connectUntilReady(allocator: std.mem.Allocator, socket_path: [:0]const u8) !sh.client.Client {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (sh.client.Client.connect(allocator, socket_path, .gui)) |client| return client else |_| _ = usleep(20 * 1000);
    }
    return error.TestTimedOut;
}

fn waitForTerminal(client: *sh.client.Client, attempt_id: u128) !sh.upgrade_wire.AttemptReport {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (try client.upgradeStatus(attempt_id)) |report| {
            if (report.status != .pending) return report;
        }
        _ = usleep(20 * 1000);
    }
    return error.TestTimedOut;
}

fn peerPid(fd: c.fd_t) !c.pid_t {
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or
        len != @sizeOf(c.pid_t) or pid <= 0)
        return error.TestUnexpectedResult;
    return pid;
}
