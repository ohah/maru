//! U5 staged-target 제품 preflight.
//!
//! Old daemon은 quiesce 뒤 곧바로 destructive exec하지 않는다. 먼저 fork한 child가 staged target image 자체를
//! `__session-host --upgrade-preflight`로 실행해 primary handoff를 current reader로 검증한다. Parent는 attempt의
//! absolute deadline 안에서 child를 reap하며, timeout/cleanup 실패를 구분해 old graph rollback으로 돌려보낸다.
//! 실제 destructive executor는 target/rollback restore entrypoint와 같은 활성화 gate에서만 추가한다. 따라서 이
//! 모듈만 daemon에 잘못 연결해 restore consumer 없는 argv로 old image를 잃을 수 없다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const entrypoint = @import("entrypoint.zig");
const exec_fd_set = @import("exec_fd_set.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_product = @import("upgrade_product_coordinator.zig");

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getdtablesize() c_int;

pub const ProductPreflight = struct {
    pub fn run(
        _: *ProductPreflight,
        target: @import("upgrade_owner.zig").VerifiedTarget,
        primary_fd: c.fd_t,
        deadline: upgrade_deadline.Deadline,
    ) upgrade_product.PreflightError!void {
        const pid = c.fork();
        if (pid < 0) return error.ResourceExhausted;
        if (pid == 0) runPreflightChild(target.artifact.path, primary_fd);
        return waitPreflight(pid, deadline);
    }
};

fn runPreflightChild(target_path: [:0]const u8, source_fd: c.fd_t) noreturn {
    redirectStdioToDevNull() catch c._exit(125);
    var source = source_fd;
    if (source == entrypoint.preflight_fd) {
        source = c.fcntl(source_fd, c.F.DUPFD_CLOEXEC, entrypoint.preflight_fd + 1);
        if (source < 0) c._exit(125);
    }
    closeAllExcept(source);
    _ = c.close(entrypoint.preflight_fd);
    var prepared: exec_fd_set.PreparedSlots = .{};
    prepared.prepare(source, entrypoint.preflight_fd) catch c._exit(125);
    prepared.assertExactNonCloexec(&.{}) catch c._exit(125);
    const argv = [_:null]?[*:0]const u8{
        target_path.ptr,
        entrypoint.subcommand,
        entrypoint.upgrade_preflight_flag,
        entrypoint.preflight_fd_arg,
    };
    _ = execv(target_path.ptr, &argv);
    c._exit(125);
}

fn closeAllExcept(kept: c.fd_t) void {
    var fd: c.fd_t = 3;
    while (fd < getdtablesize()) : (fd += 1) {
        if (fd != kept) _ = c.close(fd);
    }
}

fn waitPreflight(
    pid: c.pid_t,
    deadline: upgrade_deadline.Deadline,
) upgrade_product.PreflightError!void {
    var status: c_int = undefined;
    while (!deadline.expired()) {
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid) return if (status == 0) {} else error.InvalidTarget;
        if (waited < 0 and posix.errno(waited) != .INTR) {
            if (!killAndReap(pid)) return error.Failed;
            return error.Failed;
        }
        _ = usleep(1000);
    }
    if (!killAndReap(pid)) return error.Failed;
    return error.DeadlineExceeded;
}

fn killAndReap(pid: c.pid_t) bool {
    _ = c.kill(pid, .KILL);
    var status: c_int = undefined;
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid) return true;
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return false;
    }
}

fn redirectStdioToDevNull() error{ OpenFailed, DupFailed }!void {
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (null_fd < 0) return error.OpenFailed;
    defer {
        if (null_fd > 2) _ = c.close(null_fd);
    }
    var fd: c.fd_t = 0;
    while (fd <= 2) : (fd += 1) {
        if (c.dup2(null_fd, fd) < 0) return error.DupFailed;
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC)) < 0)
            return error.DupFailed;
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (written < 0) {
            if (posix.errno(written) == .INTR) continue;
            return error.WriteFailed;
        }
        if (written == 0) return error.WriteFailed;
        offset += @intCast(written);
    }
}

test "product preflight execs the staged maru reader with only primary handoff fd" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    const product = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        std.mem.span(product_raw),
        std.testing.allocator,
    );
    defer std.testing.allocator.free(product);
    const identity = try @import("staged_image.zig").inspect(product);
    const digest_hex = std.fmt.bytesToHex(identity.sha256, .lower);
    const build_id = try std.fmt.allocPrint(std.testing.allocator, "sha256:{s}", .{&digest_hex});
    defer std.testing.allocator.free(build_id);
    const attempt_id: u128 = 0xABCDEF;
    const record = try @import("upgrade_attempt_record.zig").encode(std.testing.allocator, .{
        .host_id = 0xA11CE,
        .attempt_id = attempt_id,
        .epoch_before = 4,
        .expected_epoch_after = 5,
        .rollback_budget = 1,
        .deadline_expires_at_ns = std.math.maxInt(i128),
        .request_path = product,
        .staged_path = product,
        .build_id = build_id,
        .sha256 = identity.sha256,
        .dev = identity.dev,
        .ino = identity.ino,
        .size = identity.size,
        .rollback_image = .{
            .path = "/tmp/maru/preflight-rollback-current",
            .sha256 = identity.sha256,
            .dev = identity.dev,
            .ino = identity.ino + 1,
            .size = identity.size,
        },
        .reader_min = @import("handoff_codec.zig").reader_min,
        .reader_max = @import("handoff_codec.zig").reader_max,
        .runtime_ids = &.{},
        .completed = &.{},
    });
    defer std.testing.allocator.free(record);
    const handoff = try @import("handoff_codec.zig").encodeHost(std.testing.allocator, .{
        .host_id = 0xA11CE,
        .upgrade_epoch = 4,
        .next_handle = 1,
        .runtimes = &.{},
        .attempt_record = record,
    });
    defer std.testing.allocator.free(handoff);

    var path_buf: [192]u8 = undefined;
    const state_path = std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/maru-product-preflight-{d}",
        .{c.getpid()},
    ) catch return error.SkipZigTest;
    _ = c.unlink(state_path.ptr);
    defer _ = c.unlink(state_path.ptr);
    const write_fd = c.open(
        state_path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (write_fd < 0) return error.SkipZigTest;
    try writeAll(write_fd, handoff);
    try std.testing.expect(c.fsync(write_fd) == 0);
    _ = c.close(write_fd);
    const primary_fd = c.open(
        state_path.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (primary_fd < 0) return error.SkipZigTest;
    defer _ = c.close(primary_fd);
    const corrupt_fd = c.open(
        state_path.ptr,
        .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (corrupt_fd < 0) return error.TestUnexpectedResult;
    try std.testing.expect(c.unlink(state_path.ptr) == 0); // product store와 같은 unlink-before-exec provenance

    var preflight: ProductPreflight = .{};
    try preflight.run(
        .{
            .artifact = .{
                .path = product,
                .exec_fd = -1,
                .sha256 = identity.sha256,
                .dev = identity.dev,
                .ino = identity.ino,
                .size = identity.size,
            },
            .build_id = build_id,
            .reader_min = @import("handoff_codec.zig").reader_min,
            .reader_max = @import("handoff_codec.zig").reader_max,
        },
        primary_fd,
        try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s),
    );

    const corrupt_magic = [_]u8{'X'};
    try std.testing.expectEqual(
        @as(isize, 1),
        c.pwrite(corrupt_fd, &corrupt_magic, corrupt_magic.len, 0),
    );
    try std.testing.expect(c.fsync(corrupt_fd) == 0);
    _ = c.close(corrupt_fd);
    try std.testing.expectError(
        error.InvalidTarget,
        preflight.run(
            .{
                .artifact = .{
                    .path = product,
                    .exec_fd = -1,
                    .sha256 = identity.sha256,
                    .dev = identity.dev,
                    .ino = identity.ino,
                    .size = identity.size,
                },
                .build_id = build_id,
                .reader_min = @import("handoff_codec.zig").reader_min,
                .reader_max = @import("handoff_codec.zig").reader_max,
            },
            primary_fd,
            try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s),
        ),
    );
}
