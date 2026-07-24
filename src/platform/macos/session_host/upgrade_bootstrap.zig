//! Exec 뒤 새 image가 inherited handoff를 읽는 제품 bootstrap의 공통 검증 경계.
//!
//! preflight와 실제 target/rollback entry가 서로 다른 decoder나 authority 검사를 만들면, preflight를 통과한 bytes를
//! 실제 restore가 거부하거나 그 반대가 될 수 있다. 이 모듈이 bounded fd read, outer handoff, embedded attempt
//! record, host/runtime 집합, 실행 image identity를 한 번에 검증하는 SSOT다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const exec_fd_set = @import("exec_fd_set.zig");
const handoff_codec = @import("handoff_codec.zig");
const staged_image = @import("staged_image.zig");
const upgrade_attempt_record = @import("upgrade_attempt_record.zig");
const upgrade_limits = @import("upgrade_limits.zig");

pub const Error = error{
    InvalidFd,
    InvalidState,
    InvalidExecutable,
    ReadFailed,
    OutOfMemory,
};

pub const Validated = struct {
    host: handoff_codec.HostState,
    attempt: upgrade_attempt_record.State,

    pub fn deinit(self: *Validated) void {
        self.attempt.deinit();
        self.host.deinit();
        self.* = undefined;
    }
};

/// Product preflight entrypoint. Exec가 CLOEXEC descriptor를 이미 제거한 뒤라 `handoff_fd` 외 fd 3+가 있으면
/// 즉시 거부한다. 같은 검증 함수를 실제 restore도 사용하되 restore는 전체 inherited allowlist를 먼저 따로 검사한다.
pub fn runPreflight(
    allocator: std.mem.Allocator,
    handoff_fd: c.fd_t,
    executable_path: [:0]const u8,
) Error!void {
    exec_fd_set.assertExactOpen(&.{handoff_fd}) catch return error.InvalidFd;
    var validated = try readValidated(allocator, handoff_fd);
    defer validated.deinit();
    try validateExecutable(validated.attempt, executable_path);
}

pub fn readValidated(
    allocator: std.mem.Allocator,
    handoff_fd: c.fd_t,
) Error!Validated {
    const bytes = try readBounded(allocator, handoff_fd);
    defer allocator.free(bytes);
    var host = handoff_codec.decodeHost(allocator, bytes) catch |err| return mapDecodeError(err);
    errdefer host.deinit();
    const record_bytes = host.attempt_record orelse return error.InvalidState;
    var attempt = upgrade_attempt_record.decode(allocator, record_bytes) catch |err| return mapDecodeError(err);
    errdefer attempt.deinit();
    if (attempt.host_id != host.host_id or
        attempt.epoch_before != host.upgrade_epoch or
        attempt.runtime_ids.len != host.runtimes.len)
        return error.InvalidState;

    // Handoff runtime order is stable handle order이고 attempt record는 runtime_id 오름차순이다. 별도 allocation 없이
    // bounded stack copy를 정렬해 두 표현이 정확히 같은 live graph인지 확인한다.
    var ids: [upgrade_limits.max_runtime_count]u128 = undefined;
    if (host.runtimes.len > ids.len) return error.InvalidState;
    for (host.runtimes, 0..) |runtime, index| ids[index] = runtime.runtime_id;
    std.mem.sort(u128, ids[0..host.runtimes.len], {}, std.sort.asc(u128));
    if (!std.mem.eql(u128, ids[0..host.runtimes.len], attempt.runtime_ids))
        return error.InvalidState;
    return .{ .host = host, .attempt = attempt };
}

pub fn validateExecutable(
    attempt: upgrade_attempt_record.State,
    executable_path: [:0]const u8,
) Error!void {
    if (!std.mem.eql(u8, attempt.staged_path, executable_path))
        return error.InvalidExecutable;
    const actual = staged_image.inspect(executable_path) catch return error.InvalidExecutable;
    const expected: staged_image.Identity = .{
        .dev = attempt.dev,
        .ino = attempt.ino,
        .size = attempt.size,
        .sha256 = attempt.sha256,
    };
    if (!staged_image.identityEqual(expected, actual))
        return error.InvalidExecutable;
}

fn readBounded(allocator: std.mem.Allocator, fd: c.fd_t) Error![]u8 {
    if (fd < 3 or !exec_fd_set.isOpen(fd)) return error.InvalidFd;
    const raw_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (raw_flags < 0) return error.InvalidFd;
    const open_flags: c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    if (open_flags.ACCMODE != .RDONLY) return error.InvalidFd;
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        (stat.mode & 0o777) != 0o600 or stat.nlink != 0 or stat.size <= 0)
        return error.InvalidFd;
    const len = std.math.cast(usize, stat.size) orelse return error.InvalidState;
    if (len > handoff_codec.max_total_bytes or len > upgrade_limits.max_handoff_commit_bytes)
        return error.InvalidState;
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.ReadFailed;
    const bytes = allocator.alloc(u8, len) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (read_count < 0) {
            if (posix.errno(read_count) == .INTR) continue;
            return error.ReadFailed;
        }
        if (read_count == 0) return error.ReadFailed;
        offset += @intCast(read_count);
    }
    return bytes;
}

fn mapDecodeError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidState,
    };
}
