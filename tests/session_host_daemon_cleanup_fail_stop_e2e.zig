//! U5 coordinator cleanup identity failure의 실제 daemon-process 종료 증거.
//!
//! 분류 helper만 호출하면 제품 accept loop의 unwind, listener close, pathname/lease 정리를 증명할 수 없다.
//! 이 fixture는 실제 MRSH prepare 요청을 보내고 fork child의 exact nonzero exit와 endpoint 소멸을 함께 단언한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const sh = @import("session_host");

extern "c" fn getdtablesize() c_int;
extern "c" fn usleep(usec: c_uint) c_int;

const manifest_fail_exit: u8 = 73;
const unexpected_success_exit: u8 = 74;
const unexpected_error_exit: u8 = 75;

test "daemon cleanup identity failure exits nonzero and removes listener authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
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

    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0x4641494c53544f50;
    const attempt_id: u128 = host_id ^ 0x434c45414e555046;
    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-daemon-fail-stop-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var session_buf: [256]u8 = undefined;
    const session_dir = sh.discovery.sessionHostDirPath(&session_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(session_dir.ptr, 0o700);
    try sh.short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket_path = try sh.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    var owner_buf: [832]u8 = undefined;
    const owner_path = try sh.host_manifest.ownerLockPathIn(&owner_buf, session_dir, host_id);

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
        sh.daemon.runSessionHostWithIdentityCleanupCollisionFixture(
            std.heap.page_allocator,
            std.testing.io,
            session_dir,
            socket_path,
            host_id,
        ) catch |err| c._exit(if (err == error.ManifestFailed) manifest_fail_exit else unexpected_error_exit);
        c._exit(unexpected_success_exit);
    }

    var gui: sh.client.Client = connectUntilReady(allocator, socket_path) catch |err| {
        _ = c.kill(child, posix.SIG.KILL);
        return err;
    };
    const outcome = try gui.prepareUpgrade(.{
        .attempt_id = attempt_id,
        .target_path = product_path,
        .target_build_id = target_build_id,
        .target_sha256 = target_identity.sha256,
        .handoff_reader_min = 1,
        .handoff_reader_max = 1,
    });
    switch (outcome) {
        .accepted_reconnect_required => {},
        else => return error.TestUnexpectedResult,
    }
    gui.deinit();

    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 750) : (attempts += 1) {
        const waited = c.waitpid(child, &status, c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0 and posix.errno(waited) != .INTR) return error.TestUnexpectedResult;
        _ = usleep(20 * 1000);
    } else return error.TestTimedOut;
    child_reaped = true;
    const wait_status: u32 = @bitCast(status);
    try std.testing.expect(c.W.IFEXITED(wait_status));
    try std.testing.expectEqual(manifest_fail_exit, c.W.EXITSTATUS(wait_status));
    try std.testing.expectEqual(@as(c_int, -1), c.access(socket_path.ptr, c.F_OK));
    try std.testing.expectEqual(posix.E.NOENT, posix.errno(-1));
    try std.testing.expectError(error.ConnectFailed, sh.client.Client.connect(allocator, socket_path, .gui));
    try std.testing.expectEqual(@as(c_int, -1), c.access(owner_path.ptr, c.F_OK));
    try std.testing.expectEqual(posix.E.NOENT, posix.errno(-1));
}

fn connectUntilReady(allocator: std.mem.Allocator, socket_path: [:0]const u8) !sh.client.Client {
    var attempts: usize = 0;
    while (attempts < 250) : (attempts += 1) {
        if (sh.client.Client.connect(allocator, socket_path, .gui)) |client| return client else |_| _ = usleep(20 * 1000);
    }
    return error.TestTimedOut;
}
