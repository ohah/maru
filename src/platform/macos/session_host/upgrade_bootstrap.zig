//! Exec 뒤 새 image가 inherited handoff를 읽는 제품 bootstrap의 공통 검증 경계.
//!
//! preflight와 실제 target/rollback entry가 서로 다른 decoder나 authority 검사를 만들면, preflight를 통과한 bytes를
//! 실제 restore가 거부하거나 그 반대가 될 수 있다. 이 모듈이 bounded fd read, outer handoff, embedded attempt
//! record, host/runtime 집합, 실행 image identity를 한 번에 검증하는 SSOT다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const entrypoint = @import("entrypoint.zig");
const exec_fd_set = @import("exec_fd_set.zig");
const handoff_codec = @import("handoff_codec.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");
const staged_image = @import("staged_image.zig");
const upgrade_attempt_record = @import("upgrade_attempt_record.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const upgrade_owner = @import("upgrade_owner.zig");

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

/// Exec에서 물려받은 descriptor의 borrowed view. `deinit`은 이 fd를 닫지 않는다. Prepared restore graph가 PTY와
/// owner lease를 CLOEXEC working descriptor로 전부 adopt한 뒤 authority commit 시 inherited set을 한 번만 닫는다.
pub const BorrowedInheritedSet = struct {
    primary: c.fd_t,
    backup: c.fd_t,
    owner: c.fd_t,
};

pub const TargetRestoreValidated = struct {
    state: Validated,
    token: upgrade_owner.RestoreToken,
    inherited: BorrowedInheritedSet,

    /// Decoded heap state만 해제하며 `inherited`와 runtime `fd_slot`은 caller 소유로 남긴다.
    pub fn deinit(self: *TargetRestoreValidated) void {
        self.state.deinit();
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
    return decodeValidated(allocator, bytes);
}

fn decodeValidated(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Validated {
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

/// Target restore가 destructive state를 만들기 전의 typed authority gate. Rollback image identity가 attempt
/// authority에 들어오기 전에는 rollback role을 성공시키지 않는다. Target도 rollback 가능성을 전제로 하므로
/// primary/backup exact bytes와 provenance, PTY/owner identity, CLI path/ID, executable을 모두 검증한다.
/// 이 함수 자체는 아직 product main에서 호출하지 않는다.
pub fn readTargetRestoreInvocation(
    allocator: std.mem.Allocator,
    invocation: entrypoint.RestoreInvocation,
    executable_path: [:0]const u8,
) Error!TargetRestoreValidated {
    if (invocation.role != .target or !invocation.layout.valid())
        return error.InvalidState;
    short_endpoint.validateCurrentSocketPath(invocation.socket_path, invocation.host_id) catch
        return error.InvalidState;
    const primary = invocation.primarySlot();
    const backup = invocation.backupSlot();
    const owner = invocation.ownerSlot();

    const primary_bytes = try readBounded(allocator, primary);
    defer allocator.free(primary_bytes);
    const backup_bytes = try readBounded(allocator, backup);
    defer allocator.free(backup_bytes);
    if (sameObject(primary, backup))
        return error.InvalidFd;
    if (!std.mem.eql(u8, primary_bytes, backup_bytes))
        return error.InvalidState;
    var state = try decodeValidated(allocator, primary_bytes);
    errdefer state.deinit();
    if (state.host.host_id != invocation.host_id or
        state.attempt.attempt_id != invocation.attempt_id)
        return error.InvalidState;
    const token = upgrade_owner.validateRestoreEntry(
        state.attempt,
        .target,
        invocation.attempt_id,
        .primary,
    ) orelse return error.InvalidState;

    var allowed: [upgrade_limits.max_runtime_count + 3]c.fd_t = undefined;
    for (state.host.runtimes, 0..) |runtime, index| {
        const expected = invocation.layout.runtimeSlot(index) orelse return error.InvalidState;
        if (runtime.fd_slot != expected) return error.InvalidState;
        try validateRuntimeFd(runtime);
        for (state.host.runtimes[0..index]) |prior|
            if (runtime.pty_dev == prior.pty_dev and runtime.pty_ino == prior.pty_ino and
                runtime.pty_rdev == prior.pty_rdev)
                return error.InvalidFd;
        allowed[index] = runtime.fd_slot;
    }
    try validateOwnerFd(invocation.session_dir, invocation.host_id, owner);
    const count = state.host.runtimes.len;
    allowed[count] = primary;
    allowed[count + 1] = backup;
    allowed[count + 2] = owner;
    exec_fd_set.assertExactOpen(allowed[0 .. count + 3]) catch return error.InvalidFd;
    try validateExecutable(state.attempt, executable_path);
    return .{
        .state = state,
        .token = token,
        .inherited = .{
            .primary = primary,
            .backup = backup,
            .owner = owner,
        },
    };
}

fn validateRuntimeFd(runtime: handoff_codec.RuntimeState) Error!void {
    @import("maru").pty.PtySession.PreparedAdoption.validateInheritedMaster(
        runtime.fd_slot,
        runtime.child_pid,
        .{ .cols = runtime.cols, .rows = runtime.rows },
        .{
            .dev = runtime.pty_dev,
            .ino = runtime.pty_ino,
            .rdev = runtime.pty_rdev,
        },
    ) catch return error.InvalidFd;
}

fn validateOwnerFd(session_dir: []const u8, host_id: u128, fd: c.fd_t) Error!void {
    var owner_path_buf: [832]u8 = undefined;
    const owner_path = host_manifest.ownerLockPathIn(&owner_path_buf, session_dir, host_id) catch
        return error.InvalidState;
    var path_stat: posix.Stat = undefined;
    var fd_stat: posix.Stat = undefined;
    const raw_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (raw_flags < 0 or
        c.fstatat(posix.AT.FDCWD, owner_path.ptr, &path_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        c.fstat(fd, &fd_stat) != 0)
        return error.InvalidFd;
    const open_flags: c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    if (open_flags.ACCMODE != .RDWR or !posix.S.ISREG(fd_stat.mode) or fd_stat.uid != c.getuid() or
        (fd_stat.mode & 0o777) != 0o600 or path_stat.dev != fd_stat.dev or path_stat.ino != fd_stat.ino)
        return error.InvalidFd;
    if (c.flock(fd, c.LOCK.EX | c.LOCK.NB) != 0)
        return error.InvalidFd;
}

fn sameObject(a: c.fd_t, b: c.fd_t) bool {
    var a_stat: posix.Stat = undefined;
    var b_stat: posix.Stat = undefined;
    return c.fstat(a, &a_stat) == 0 and c.fstat(b, &b_stat) == 0 and
        a_stat.dev == b_stat.dev and a_stat.ino == b_stat.ino;
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
    const bytes = allocator.alloc(u8, len) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = c.pread(fd, bytes.ptr + offset, bytes.len - offset, @intCast(offset));
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

test "target restore gate rejects rollback role and foreign endpoint before fd access" {
    const layout = try @import("upgrade_fd_layout.zig").Layout.init(40);
    const base: entrypoint.RestoreInvocation = .{
        .role = .rollback,
        .session_dir = "/tmp/maru-session",
        .socket_path = "/tmp/foreign.sock",
        .host_id = 0xAA,
        .attempt_id = 0,
        .layout = layout,
    };
    try std.testing.expectError(
        error.InvalidState,
        readTargetRestoreInvocation(std.testing.allocator, base, "/tmp/maru"),
    );
    var target = base;
    target.role = .target;
    try std.testing.expectError(
        error.InvalidState,
        readTargetRestoreInvocation(std.testing.allocator, target, "/tmp/maru"),
    );
}
