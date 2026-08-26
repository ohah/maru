//! Fresh detached session-host의 exec 이후 startup 결과를 부모 GUI에 한 번 전달하는 typed channel.
//!
//! exec 성패는 launcher의 CLOEXEC pipe가 따로 소유한다. 이 모듈은 daemon이 owner lease, endpoint,
//! ready manifest, poll owner까지 구성했는지만 말하며 upgrade/restore handoff fd와 섞이지 않는다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn getpeereid(fd: c.fd_t, euid: *posix.uid_t, egid: *posix.gid_t) c_int;

pub const env_name: [:0]const u8 = "MARU_SESSION_HOST_STARTUP_FD";
pub const legacy_wait_ms: c_int = 3_000;

pub const Status = enum(u8) {
    ready = 0xA1,
    failed = 0xA2,
};

pub const ParentResult = enum {
    ready,
    failed,
    legacy_timeout,
};

pub const NotifierError = error{InvalidChannel};

/// 단위 테스트용 환경 설치 helper. 제품 launcher는 다중 스레드 fork 이후 setenv를 호출하지 않고
/// 부모에서 완성한 envp를 execve에 전달한다.
pub fn installEnvironment(fd: c.fd_t) bool {
    var value_buf: [24]u8 = undefined;
    const value = std.fmt.bufPrintZ(&value_buf, "{d}", .{fd}) catch return false;
    return setenv(env_name.ptr, value.ptr, 1) == 0;
}

/// Hidden daemon entrypoint가 environment에서 상속 channel을 정확히 한 번 가져온다. 외부에서 임의로
/// 주입한 숫자가 일반 파일/pipe를 닫거나 쓰지 못하도록 connected Unix socket과 descriptor flags를 검증한다.
pub const Notifier = struct {
    fd: ?c.fd_t,

    pub fn fromEnvironment() NotifierError!Notifier {
        const raw = c.getenv(env_name.ptr) orelse return .{ .fd = null };
        defer _ = unsetenv(env_name.ptr);
        const text = std.mem.span(raw);
        const parsed = std.fmt.parseInt(i64, text, 10) catch return error.InvalidChannel;
        if (parsed < 3 or parsed > std.math.maxInt(c_int)) return error.InvalidChannel;
        const fd: c.fd_t = @intCast(parsed);
        const flags = c.fcntl(fd, c.F.GETFD);
        if (flags < 0 or flags & c.FD_CLOEXEC != 0) return error.InvalidChannel;
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !posix.S.ISSOCK(stat.mode)) return error.InvalidChannel;
        var peer_uid: posix.uid_t = undefined;
        var peer_gid: posix.gid_t = undefined;
        if (getpeereid(fd, &peer_uid, &peer_gid) != 0 or peer_uid != c.geteuid())
            return error.InvalidChannel;
        return .{ .fd = fd };
    }

    pub fn ready(self: *Notifier) void {
        self.finish(.ready);
    }

    pub fn failed(self: *Notifier) void {
        self.finish(.failed);
    }

    pub fn deinit(self: *Notifier) void {
        if (self.fd) |fd| _ = c.close(fd);
        self.fd = null;
    }

    fn finish(self: *Notifier, status: Status) void {
        const fd = self.fd orelse return;
        self.fd = null;
        const byte = [_]u8{@intFromEnum(status)};
        _ = c.write(fd, &byte, byte.len);
        _ = c.close(fd);
    }
};

/// Launcher parent의 닫힌 decoder. timeout은 capability를 모르는 구 binary fallback이며 success 주장이 아니다.
pub fn awaitParent(fd: c.fd_t, timeout_ms: c_int) ParentResult {
    const started_ns = monotonicNs() orelse return .failed;
    const timeout_ns: u64 = @as(u64, @intCast(@max(timeout_ms, 0))) * std.time.ns_per_ms;
    const expires_ns = std.math.add(u64, started_ns, timeout_ns) catch std.math.maxInt(u64);
    var poll_fd = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN | c.POLL.HUP, .revents = 0 }};
    while (true) {
        const now_ns = monotonicNs() orelse return .failed;
        const remaining_ns = if (now_ns >= expires_ns) 0 else expires_ns - now_ns;
        const remaining_ms = @min(
            std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch return .failed,
            @as(u64, std.math.maxInt(c_int)),
        );
        const rc = c.poll(&poll_fd, 1, @intCast(remaining_ms));
        if (rc == 0) return .legacy_timeout;
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return .failed;
        }
        var byte: [1]u8 = undefined;
        const n = c.read(fd, &byte, byte.len);
        if (n != 1) return .failed;
        return switch (byte[0]) {
            @intFromEnum(Status.ready) => .ready,
            @intFromEnum(Status.failed) => .failed,
            else => .failed,
        };
    }
}

fn monotonicNs() ?u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return null;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return std.math.add(u64, std.math.mul(u64, sec, std.time.ns_per_s) catch return null, nsec) catch null;
}

test "startup readiness parent decoder distinguishes ready fail EOF unknown and timeout" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    inline for (.{ Status.ready, Status.failed }) |status| {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        const byte = [_]u8{@intFromEnum(status)};
        try std.testing.expectEqual(@as(isize, 1), c.write(fds[1], &byte, 1));
        _ = c.close(fds[1]);
        defer _ = c.close(fds[0]);
        try std.testing.expectEqual(
            if (status == .ready) ParentResult.ready else ParentResult.failed,
            awaitParent(fds[0], 10),
        );
    }
    var eof: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &eof));
    _ = c.close(eof[1]);
    defer _ = c.close(eof[0]);
    try std.testing.expectEqual(ParentResult.failed, awaitParent(eof[0], 10));

    var unknown: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &unknown));
    const bad = [_]u8{0xFF};
    _ = c.write(unknown[1], &bad, 1);
    defer _ = c.close(unknown[0]);
    defer _ = c.close(unknown[1]);
    try std.testing.expectEqual(ParentResult.failed, awaitParent(unknown[0], 10));

    var timeout: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &timeout));
    defer _ = c.close(timeout[0]);
    defer _ = c.close(timeout[1]);
    try std.testing.expectEqual(ParentResult.legacy_timeout, awaitParent(timeout[0], 0));
}

test "startup notifier consumes only a non-CLOEXEC socket descriptor" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[0]);
    try std.testing.expect(installEnvironment(fds[1]));
    var notifier = try Notifier.fromEnvironment();
    try std.testing.expect(notifier.fd != null);
    try std.testing.expect(c.getenv(env_name.ptr) == null);
    notifier.ready();
    try std.testing.expectEqual(ParentResult.ready, awaitParent(fds[0], 10));
}

test "startup notifier rejects a malformed injected channel instead of silently continuing" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(installRawEnvironment("not-a-fd"));
    try std.testing.expectError(error.InvalidChannel, Notifier.fromEnvironment());
    try std.testing.expect(c.getenv(env_name.ptr) == null);
}

test "startup notifier rejects pipe and CLOEXEC socket descriptors" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var pipe_fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&pipe_fds));
    defer _ = c.close(pipe_fds[0]);
    defer _ = c.close(pipe_fds[1]);
    try std.testing.expect(installEnvironment(pipe_fds[1]));
    try std.testing.expectError(error.InvalidChannel, Notifier.fromEnvironment());

    var socket_fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &socket_fds));
    defer _ = c.close(socket_fds[0]);
    defer _ = c.close(socket_fds[1]);
    try std.testing.expect(c.fcntl(socket_fds[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) == 0);
    try std.testing.expect(installEnvironment(socket_fds[1]));
    try std.testing.expectError(error.InvalidChannel, Notifier.fromEnvironment());
}

fn installRawEnvironment(value: [:0]const u8) bool {
    return setenv(env_name.ptr, value.ptr, 1) == 0;
}
