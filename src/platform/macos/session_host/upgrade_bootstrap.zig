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
const rollback_image = @import("rollback_image.zig");
const short_endpoint = @import("short_endpoint.zig");
const staged_image = @import("staged_image.zig");
const upgrade_attempt_record = @import("upgrade_attempt_record.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const upgrade_owner = @import("upgrade_owner.zig");
extern "c" fn getdtablesize() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const Error = error{
    InvalidFd,
    InvalidState,
    InvalidExecutable,
    InvalidExecutableIdentity,
    InvalidRollbackImage,
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

pub const RestoreValidated = struct {
    state: Validated,
    token: upgrade_owner.RestoreToken,
    inherited: BorrowedInheritedSet,

    /// Decoded heap state만 해제하며 `inherited`와 runtime `fd_slot`은 caller 소유로 남긴다.
    pub fn deinit(self: *RestoreValidated) void {
        self.state.deinit();
        self.* = undefined;
    }
};

/// Product preflight entrypoint. Exec가 CLOEXEC descriptor를 이미 제거한 뒤라 `handoff_fd` 외 fd 3+가 있으면
/// 즉시 거부한다. 같은 검증 함수를 실제 restore도 사용하되 restore는 전체 inherited allowlist를 먼저 따로 검사한다.
pub fn runPreflight(
    allocator: std.mem.Allocator,
    io: std.Io,
    handoff_fd: c.fd_t,
) Error!void {
    exec_fd_set.assertExactOpen(&.{handoff_fd}) catch return error.InvalidFd;
    var validated = try readValidated(allocator, handoff_fd);
    defer validated.deinit();
    try validateExecutable(validated.attempt, try inspectRunningExecutable(io));
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

/// Target/rollback restore가 destructive state를 만들기 전의 typed authority gate. Target은 primary/backup의
/// exact bytes를 요구하고, rollback은 손상될 수 있는 primary의 provenance만 확인한 뒤 독립 backup을 읽는다.
/// 두 role 모두 PTY/owner identity와 CLI path/ID를 검증하며, process executable handle의 exact object identity를
/// staged target 또는 attempt에 고정된 self-image에 결합한다. Product main은 validation-only로 호출하지만 실제
/// prepared graph/executor가 없으므로 test 전용 gate 외에는 성공 종료하지 않는다.
pub fn readRestoreInvocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: entrypoint.RestoreInvocation,
) Error!RestoreValidated {
    return readRestoreInvocationForExecutable(
        allocator,
        invocation,
        try inspectRunningExecutable(io),
    );
}

fn readRestoreInvocationForExecutable(
    allocator: std.mem.Allocator,
    invocation: entrypoint.RestoreInvocation,
    executable_identity: staged_image.Identity,
) Error!RestoreValidated {
    if (!invocation.layout.valid())
        return error.InvalidState;
    short_endpoint.validateCurrentSocketPath(invocation.socket_path, invocation.host_id) catch
        return error.InvalidState;
    const primary = invocation.primarySlot();
    const backup = invocation.backupSlot();
    const owner = invocation.ownerSlot();

    if (sameObject(primary, backup))
        return error.InvalidFd;
    const selected_bytes = switch (invocation.role) {
        .target => target: {
            const primary_bytes = try readBounded(allocator, primary);
            errdefer allocator.free(primary_bytes);
            const backup_bytes = try readBounded(allocator, backup);
            defer allocator.free(backup_bytes);
            if (!std.mem.eql(u8, primary_bytes, backup_bytes))
                return error.InvalidState;
            break :target primary_bytes;
        },
        .rollback => rollback: {
            // Rollback의 복구 권위는 backup이다. Primary는 exact inherited allowlist에 속한
            // owner-only unlinked regular fd라는 provenance만 확인하고, 손상·truncate된
            // 내용이나 크기를 읽지 않는다.
            try validateIgnoredHandoffFd(primary);
            break :rollback try readBounded(allocator, backup);
        },
    };
    defer allocator.free(selected_bytes);
    var state = try decodeValidated(allocator, selected_bytes);
    errdefer state.deinit();
    if (state.host.host_id != invocation.host_id or
        state.attempt.attempt_id != invocation.attempt_id)
        return error.InvalidState;
    if (!rollback_image.validateCanonicalRecord(
        state.attempt.rollbackImage(),
        invocation.session_dir,
        invocation.host_id,
    ))
        return error.InvalidRollbackImage;
    const copy: upgrade_owner.HandoffCopy = if (invocation.role == .target) .primary else .backup;
    const token = upgrade_owner.validateRestoreEntry(
        state.attempt,
        invocation.role,
        invocation.attempt_id,
        copy,
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
    switch (invocation.role) {
        .target => try validateExecutable(state.attempt, executable_identity),
        .rollback => try validateImageExecutable(state.attempt.rollbackImage(), executable_identity),
    }
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

fn validateImageExecutable(
    image: upgrade_attempt_record.ImageView,
    actual: staged_image.Identity,
) Error!void {
    if (!staged_image.identityEqual(.{
        .dev = image.dev,
        .ino = image.ino,
        .size = image.size,
        .sha256 = image.sha256,
    }, actual))
        return error.InvalidExecutableIdentity;
}

/// `executablePathAlloc` 문자열은 macOS에서 `/tmp`와 `/private/tmp`처럼 같은 vnode를 다른 철자로
/// 돌려줄 수 있어 raw pathname equality를 권위로 쓰지 않는다. 다만 Zig의 macOS `openExecutable`도
/// `_NSGetExecutablePath` 결과를 다시 여는 구현이므로 여기서 증명하는 것은 reopened pathname object
/// identity까지다. 실제 loaded image pin은 future executor가 verified fd를 상속해야 닫힌다.
fn inspectRunningExecutable(io: std.Io) Error!staged_image.Identity {
    const executable = std.process.openExecutable(io, .{}) catch
        return error.InvalidExecutable;
    defer executable.close(io);
    return staged_image.inspectFd(executable.handle) catch
        return error.InvalidExecutable;
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
    actual: staged_image.Identity,
) Error!void {
    const expected: staged_image.Identity = .{
        .dev = attempt.dev,
        .ino = attempt.ino,
        .size = attempt.size,
        .sha256 = attempt.sha256,
    };
    if (!staged_image.identityEqual(expected, actual))
        return error.InvalidExecutableIdentity;
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

/// Rollback이 의도적으로 읽지 않는 primary copy의 provenance만 검증한다. 내용·크기·checksum은
/// backup 복구 성공의 선행조건이 아니며, zero-truncate까지 독립 복구해야 한다.
fn validateIgnoredHandoffFd(fd: c.fd_t) Error!void {
    if (fd < 3 or !exec_fd_set.isOpen(fd)) return error.InvalidFd;
    const raw_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (raw_flags < 0) return error.InvalidFd;
    const open_flags: c.O = @bitCast(@as(u32, @intCast(raw_flags)));
    var stat: posix.Stat = undefined;
    if (open_flags.ACCMODE != .RDONLY or
        c.fstat(fd, &stat) != 0 or
        !posix.S.ISREG(stat.mode) or
        stat.uid != c.getuid() or
        (stat.mode & 0o777) != 0o600 or
        stat.nlink != 0)
        return error.InvalidFd;
}

fn mapDecodeError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidState,
    };
}

test "restore gate rejects foreign endpoint before fd access for both roles" {
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
        readRestoreInvocation(std.testing.allocator, std.testing.io, base),
    );
    var target = base;
    target.role = .target;
    try std.testing.expectError(
        error.InvalidState,
        readRestoreInvocation(std.testing.allocator, std.testing.io, target),
    );
}

test "target and rollback bootstrap validate exact zero-runtime inherited process graph" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const restore_raw = c.getenv("MARU_SESSION_HOST_RESTORE_TEST_EXE") orelse return error.SkipZigTest;
    const restore_raw_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        std.mem.span(restore_raw),
        std.testing.allocator,
    );
    defer std.testing.allocator.free(restore_raw_path);
    const restore_executable = try std.testing.allocator.dupeZ(u8, restore_raw_path);
    defer std.testing.allocator.free(restore_executable);
    const restore_identity = try staged_image.inspect(restore_executable);
    const digest_hex = std.fmt.bytesToHex(restore_identity.sha256, .lower);
    const build_id = try std.fmt.allocPrint(std.testing.allocator, "sha256:{s}", .{&digest_hex});
    defer std.testing.allocator.free(build_id);

    const host_id: u128 = 0xA11CE;
    const attempt_id: u128 = 0;
    var session_buf: [192]u8 = undefined;
    const session_dir = std.fmt.bufPrintZ(
        &session_buf,
        "/tmp/maru-restore-bootstrap-{d}-{d}",
        .{ c.getpid(), std.Io.Clock.awake.now(std.testing.io).nanoseconds },
    ) catch return error.SkipZigTest;
    if (c.mkdir(session_dir.ptr, 0o700) != 0) return error.TestUnexpectedResult;
    defer _ = c.rmdir(session_dir.ptr);
    try host_manifest.prepareHostDirectory(session_dir, host_id);
    defer host_manifest.removeEmptyHostDirectories(session_dir, host_id);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = try host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id);
    var owner_path_buf: [832]u8 = undefined;
    const owner_path = try host_manifest.ownerLockPathIn(&owner_path_buf, session_dir, host_id);
    var lease = try @import("owner_lease.zig").OwnerLease.acquire(owner_path);
    defer {
        _ = lease.unlinkOwnedWhileLocked(owner_path) catch {};
        lease.deinit();
    }
    var rollback_authority = try rollback_image.Authority.prepare(
        std.testing.allocator,
        restore_executable,
        restore_identity,
        host_dir,
    );
    defer rollback_authority.deinit();
    var target_image = try staged_image.stageExclusive(
        std.testing.allocator,
        restore_executable,
        host_dir,
        "attempt-target",
    );
    defer target_image.deinit();
    const target_identity = target_image.identity;
    const target_path = target_image.path;

    const record = try upgrade_attempt_record.encode(std.testing.allocator, .{
        .host_id = host_id,
        .attempt_id = attempt_id,
        .epoch_before = 4,
        .expected_epoch_after = 5,
        .rollback_budget = 1,
        .request_path = restore_executable,
        .staged_path = target_path,
        .build_id = build_id,
        .sha256 = target_identity.sha256,
        .dev = target_identity.dev,
        .ino = target_identity.ino,
        .size = target_identity.size,
        .rollback_image = rollback_authority.record(),
        .reader_min = handoff_codec.reader_min,
        .reader_max = handoff_codec.reader_max,
        .runtime_ids = &.{},
        .completed = &.{},
    });
    defer std.testing.allocator.free(record);
    const handoff = try handoff_codec.encodeHost(std.testing.allocator, .{
        .host_id = host_id,
        .upgrade_epoch = 4,
        .next_handle = 1,
        .runtimes = &.{},
        .attempt_record = record,
    });
    defer std.testing.allocator.free(handoff);
    var pair = try @import("handoff_store.zig").commit(
        std.testing.allocator,
        host_dir,
        .{
            .host_id = host_id,
            .attempt_id = attempt_id,
            .upgrade_epoch = 4,
            .next_handle = 1,
            .runtime_ids = &.{},
            .request_path = restore_executable,
            .staged_path = target_path,
            .build_id = build_id,
            .sha256 = target_identity.sha256,
            .dev = target_identity.dev,
            .ino = target_identity.ino,
            .size = target_identity.size,
            .rollback_image = rollback_authority.record(),
            .reader_min = handoff_codec.reader_min,
            .reader_max = handoff_codec.reader_max,
        },
        handoff,
        .{ .deadline = .testingNever() },
    );
    defer pair.deinit();
    const layout = @import("upgrade_product_coordinator.zig").findAvailableLayout(40) orelse
        return error.SkipZigTest;
    var inherited: exec_fd_set.PreparedSlots = .{};
    defer inherited.rollback();
    try inherited.prepare(pair.primary_fd, layout.primarySlot());
    try inherited.prepare(pair.backup_fd, layout.backupSlot());
    try inherited.prepare(lease.descriptor(), layout.ownerSlot());
    var socket_buf: [128]u8 = undefined;
    const socket_path = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);

    const target_invocation: entrypoint.RestoreInvocation = .{
        .role = .target,
        .session_dir = session_dir,
        .socket_path = socket_path,
        .host_id = host_id,
        .attempt_id = attempt_id,
        .layout = layout,
    };
    const rollback_invocation: entrypoint.RestoreInvocation = .{
        .role = .rollback,
        .session_dir = session_dir,
        .socket_path = socket_path,
        .host_id = host_id,
        .attempt_id = attempt_id,
        .layout = layout,
    };
    try runRestoreGateChild(target_invocation, target_path, true);
    try runRestoreGateChild(rollback_invocation, rollback_authority.image.path, true);
    try runRestoreGateChild(rollback_invocation, target_path, false);

    _ = c.close(layout.primarySlot());
    const corrupt_primary = try openTruncatedUnlinkedCopy(host_dir, handoff);
    defer _ = c.close(corrupt_primary);
    var corrupt_slot: exec_fd_set.PreparedSlots = .{};
    defer corrupt_slot.rollback();
    try corrupt_slot.prepare(corrupt_primary, layout.primarySlot());
    try runRestoreGateChild(target_invocation, target_path, false);
    try runRestoreGateChild(rollback_invocation, rollback_authority.image.path, true);

    // 제품 `maru`는 같은 identity-valid restore를 끝까지 검증해도 compile-time gate가
    // false라 반드시 non-zero여야 한다. Test artifact만 성공한다는 build isolation 회귀를
    // 실제 product process로 고정한다.
    corrupt_slot.rollback();
    _ = c.close(layout.backupSlot());
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    const product_raw_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        std.mem.span(product_raw),
        std.testing.allocator,
    );
    defer std.testing.allocator.free(product_raw_path);
    const product = try std.testing.allocator.dupeZ(u8, product_raw_path);
    defer std.testing.allocator.free(product);
    var product_target = try staged_image.stageExclusive(
        std.testing.allocator,
        product,
        host_dir,
        "product-target",
    );
    defer product_target.deinit();
    const product_record = try upgrade_attempt_record.encode(std.testing.allocator, .{
        .host_id = host_id,
        .attempt_id = 1,
        .epoch_before = 4,
        .expected_epoch_after = 5,
        .rollback_budget = 1,
        .request_path = product,
        .staged_path = product_target.path,
        .build_id = build_id,
        .sha256 = product_target.identity.sha256,
        .dev = product_target.identity.dev,
        .ino = product_target.identity.ino,
        .size = product_target.identity.size,
        .rollback_image = rollback_authority.record(),
        .reader_min = handoff_codec.reader_min,
        .reader_max = handoff_codec.reader_max,
        .runtime_ids = &.{},
        .completed = &.{},
    });
    defer std.testing.allocator.free(product_record);
    const product_handoff = try handoff_codec.encodeHost(std.testing.allocator, .{
        .host_id = host_id,
        .upgrade_epoch = 4,
        .next_handle = 1,
        .runtimes = &.{},
        .attempt_record = product_record,
    });
    defer std.testing.allocator.free(product_handoff);
    var product_pair = try @import("handoff_store.zig").commit(
        std.testing.allocator,
        host_dir,
        .{
            .host_id = host_id,
            .attempt_id = 1,
            .upgrade_epoch = 4,
            .next_handle = 1,
            .runtime_ids = &.{},
            .request_path = product,
            .staged_path = product_target.path,
            .build_id = build_id,
            .sha256 = product_target.identity.sha256,
            .dev = product_target.identity.dev,
            .ino = product_target.identity.ino,
            .size = product_target.identity.size,
            .rollback_image = rollback_authority.record(),
            .reader_min = handoff_codec.reader_min,
            .reader_max = handoff_codec.reader_max,
        },
        product_handoff,
        .{ .deadline = .testingNever() },
    );
    defer product_pair.deinit();
    var product_slots: exec_fd_set.PreparedSlots = .{};
    defer product_slots.rollback();
    try product_slots.prepare(product_pair.primary_fd, layout.primarySlot());
    try product_slots.prepare(product_pair.backup_fd, layout.backupSlot());
    var product_invocation = target_invocation;
    product_invocation.attempt_id = 1;
    try runRestoreGateChild(product_invocation, product_target.path, false);
}

fn openTruncatedUnlinkedCopy(owner_dir: [:0]const u8, bytes: []const u8) !c.fd_t {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}/truncated-primary-{d}",
        .{ owner_dir, c.getpid() },
    ) catch return error.TestUnexpectedResult;
    _ = c.unlink(path.ptr);
    const writer = c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (writer < 0) return error.TestUnexpectedResult;
    var writer_open = true;
    defer {
        if (writer_open) _ = c.close(writer);
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(writer, bytes.ptr + offset, bytes.len - offset);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (count == 0) return error.TestUnexpectedResult;
        offset += @intCast(count);
    }
    if (c.ftruncate(writer, 0) != 0 or c.fsync(writer) != 0)
        return error.TestUnexpectedResult;
    _ = c.close(writer);
    writer_open = false;
    const reader = c.open(
        path.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (reader < 0) return error.TestUnexpectedResult;
    errdefer _ = c.close(reader);
    if (c.unlink(path.ptr) != 0) return error.TestUnexpectedResult;
    return reader;
}

fn runRestoreGateChild(
    invocation: entrypoint.RestoreInvocation,
    executable_path: [:0]const u8,
    expect_success: bool,
) !void {
    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        var fd: c.fd_t = 3;
        while (fd < getdtablesize()) : (fd += 1) {
            if (fd != invocation.primarySlot() and fd != invocation.backupSlot() and
                fd != invocation.ownerSlot())
                _ = c.close(fd);
        }
        if (!expect_success) {
            const dev_null = c.open(
                "/dev/null",
                .{ .ACCMODE = .WRONLY, .CLOEXEC = true },
                @as(c.mode_t, 0),
            );
            if (dev_null < 0 or c.dup2(dev_null, 2) < 0) c._exit(2);
            if (dev_null != 2) _ = c.close(dev_null);
        }
        var buffers: entrypoint.RestoreArgBuffers = .{};
        const raw_args = entrypoint.formatRestoreArgs(invocation, &buffers) catch c._exit(2);
        var owned: [entrypoint.max_invocation_args][:0]u8 = undefined;
        for (raw_args, 0..) |arg, index|
            owned[index] = std.heap.page_allocator.dupeZ(u8, arg) catch c._exit(2);
        const argv = [_:null]?[*:0]const u8{
            executable_path.ptr,
            entrypoint.subcommand,
            owned[0].ptr,
            owned[1].ptr,
            owned[2].ptr,
            owned[3].ptr,
            owned[4].ptr,
            owned[5].ptr,
            owned[6].ptr,
        };
        _ = execv(executable_path.ptr, &argv);
        c._exit(2);
    }
    var status: c_int = undefined;
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid) break;
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
    if (expect_success)
        try std.testing.expectEqual(@as(c_int, 0), status)
    else
        try std.testing.expect(status != 0);
}
