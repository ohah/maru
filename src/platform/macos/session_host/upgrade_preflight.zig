//! U5 staged-target 제품 preflight.
//!
//! Old daemon은 quiesce 뒤 곧바로 destructive exec하지 않는다. 먼저 fork한 child가 staged target image 자체를
//! `__session-host --upgrade-preflight`로 실행해 primary handoff를 current reader로 검증한다. Parent는 attempt의
//! absolute deadline 안에서 child를 reap하며, timeout/cleanup 실패를 구분해 old graph rollback으로 돌려보낸다.
//! 실제 destructive executor는 target/rollback restore entrypoint와 같은 활성화 gate에서만 추가한다. 따라서 이
//! 모듈만 daemon에 잘못 연결해 restore consumer 없는 argv로 old image를 잃을 수 없다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const entrypoint = @import("entrypoint.zig");
const exec_fd_set = @import("exec_fd_set.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_product = @import("upgrade_product_coordinator.zig");
const host_log = @import("host_log.zig");

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

/// 준비 단계마다 **다른 종료 코드**를 쓴다. 부모가 볼 수 있는 것은 종료 상태뿐이라, 전부 125 로
/// 끝내면 다섯 갈래가 한 숫자로 뭉친다 — 2026-09-10 에 업그레이드가 `reason=target_invalid` 로 접혔을
/// 때 그 다섯 중 무엇인지 알 길이 없었다.
const exit_redirect_failed: u8 = 121;
const exit_dup_failed: u8 = 122;
const exit_prepare_failed: u8 = 123;
const exit_fd_set_invalid: u8 = 124;
const exit_exec_failed: u8 = 125;

/// **자식이 스스로 남긴다 — 물려받은 fd 가 아니라 자기가 연 파일에.**
///
/// exec 뒤의 실패(`InvalidFd`·handoff 읽기·`validateExecutable`)는 stderr 로 나가는데, 그 fd 를 정하는
/// 것은 **부모**다. 그리고 원인을 알아야 하는 순간의 부모는 **항상 옛 빌드**다 — 새 빌드를 깔아야
/// 업그레이드가 일어나고, 그때 fork 하는 쪽은 아직 옛 이미지이기 때문이다. 2026-09-10 에 그 옛 부모가
/// stderr 를 `/dev/null` 로 보내고 있어서, `reason=target_invalid` 의 실제 이유가 **아무 데도** 남지
/// 않았다. 부모에 넣은 진단(`waitPreflight`)이 그 상황에서 영영 안 찍히는 것도 같은 이유다.
///
/// **자식은 새 빌드다.** 그래서 이 한 줄만은 부모가 무엇이든 남는다.
///
/// **성공도 적는다.** 「preflight 는 통과했는데 업그레이드는 `target_invalid`」이면 범인은 preflight 가
/// 아니라 `beginExecution` 의 `verify` 다(`upgrade_target.verifyOpaque`). 실패만 적으면 그 둘이 「로그
/// 없음」으로 똑같아 보인다 — 정확히 그래서 한 번 헛짚었다.
pub fn noteChildOutcome(ok: bool, detail: []const u8) void {
    if (builtin.is_test) return;
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/maru-{d}/session-host/preflight.log",
        .{c.getuid()},
    ) catch return;
    const fd = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return;
    defer _ = c.close(fd);
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    var line_buf: [320]u8 = undefined;
    const text = std.fmt.bufPrint(
        &line_buf,
        "preflight child: pid={d} at_unix={d} result={s} detail={s}\n",
        .{ c.getpid(), ts.sec, if (ok) "ok" else "failed", detail },
    ) catch return;
    _ = c.write(fd, text.ptr, text.len);
}

fn runPreflightChild(target_path: [:0]const u8, source_fd: c.fd_t) noreturn {
    // **stderr 는 남긴다.** 예전에는 셋 다 `/dev/null` 로 보내, exec 뒤의 실패
    // (`InvalidFd`·handoff 읽기·`validateExecutable`)가 찍는 «maru session host preflight failed: …»
    // 가 **아무 데도 안 남았다**. host 의 fd 2 는 `host-<id>.log` 라, 물려받으면 그대로 기록된다.
    // stdin·stdout 은 계속 막는다 — 자식이 채널을 읽거나 거기에 쓰면 안 된다.
    redirectStdinStdoutToDevNull() catch c._exit(exit_redirect_failed);
    var source = source_fd;
    if (source == entrypoint.preflight_fd) {
        source = c.fcntl(source_fd, c.F.DUPFD_CLOEXEC, entrypoint.preflight_fd + 1);
        if (source < 0) c._exit(exit_dup_failed);
    }
    closeAllExcept(source);
    _ = c.close(entrypoint.preflight_fd);
    var prepared: exec_fd_set.PreparedSlots = .{};
    prepared.prepare(source, entrypoint.preflight_fd) catch c._exit(exit_prepare_failed);
    prepared.assertExactNonCloexec(&.{}) catch c._exit(exit_fd_set_invalid);
    const argv = [_:null]?[*:0]const u8{
        target_path.ptr,
        entrypoint.subcommand,
        entrypoint.upgrade_preflight_flag,
        entrypoint.preflight_fd_arg,
    };
    _ = execv(target_path.ptr, &argv);
    c._exit(exit_exec_failed);
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
        if (waited == pid) {
            if (status == 0) return;
            // **부모가 이미 들고 있던 값을 버리지 않는다.** 이것 하나가 여덟 갈래를
            // `reason=target_invalid` 로 뭉갰다 — 자식의 준비 단계 다섯(121~125)과 exec 뒤의 실패
            // 셋(`InvalidFd`·handoff 읽기·`validateExecutable`)이 부모에게는 똑같이 「0 이 아님」이다.
            //
            // 121~125 면 exec **이전**(자식 준비)이고, 그 밖의 값이면 exec **이후**다 — 그때는 자식이
            // stderr 에 남긴 «maru session host preflight failed: …» 가 host 로그 같은 자리에 있다.
            const us: u32 = @bitCast(status);
            if (std.c.W.IFEXITED(us))
                host_log.line("upgrade preflight rejected target: exit={d}", .{std.c.W.EXITSTATUS(us)})
            else if (std.c.W.IFSIGNALED(us))
                host_log.line(
                    "upgrade preflight rejected target: signal={d}",
                    .{@intFromEnum(std.c.W.TERMSIG(us))},
                )
            else
                host_log.line("upgrade preflight rejected target: raw_status=0x{x}", .{us});
            return error.InvalidTarget;
        }
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

fn redirectStdinStdoutToDevNull() error{ OpenFailed, DupFailed }!void {
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (null_fd < 0) return error.OpenFailed;
    defer {
        if (null_fd > 2) _ = c.close(null_fd);
    }
    // **fd 2 는 건드리지 않는다** — host 로그로 가야 진단이 남는다.
    var fd: c.fd_t = 0;
    while (fd <= 1) : (fd += 1) {
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
