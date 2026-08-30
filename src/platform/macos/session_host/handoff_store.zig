//! Exec handoff bytes의 primary/backup disk commit 경계(U5-B).
//!
//! Caller가 이미 소유한 encoded bytes를 owner-only attempt directory에 두 번 독립적으로 O_EXCL write/fsync하고,
//! read-only fd로 다시 열어 전량 read-back과 semantic decode를 통과시킨다. 성공 시 pathname은 exec 전에 모두
//! unlink되고 열린 fd 두 개만 반환된다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const test_scratch = @import("test_scratch.zig");
const posix = std.posix;
const handoff = @import("handoff_codec.zig");
const attempt_record = @import("upgrade_attempt_record.zig");
const limits = @import("upgrade_limits.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
extern "c" fn renameatx_np(
    from_dir_fd: c_int,
    from: [*:0]const u8,
    to_dir_fd: c_int,
    to: [*:0]const u8,
    flags: c_uint,
) c_int;
const rename_excl: c_uint = 0x00000004;
const at_removedir: c_uint = 0x00000080;
const f_preallocate: c_int = 42;
const f_allocate_all: c_uint = 0x00000004;
const f_peof_posmode: c_int = 3;
const FStore = extern struct {
    flags: c_uint,
    posmode: c_int,
    offset: i64,
    length: i64,
    bytes_allocated: i64,
};

pub const Error = error{
    InvalidDirectory,
    AlreadyExists,
    LimitExceeded,
    OpenFailed,
    WriteFailed,
    SyncFailed,
    ReadFailed,
    StateMismatch,
    InvalidState,
    CleanupFailed,
    DeadlineExceeded,
    InsufficientSpace,
    OutOfMemory,
};

pub const Failpoint = enum {
    none,
    primary_before_sync,
    primary_after_rename,
    backup_before_sync,
    corrupt_backup_after_sync,
};

const ReserveFailpoint = enum { none, after_primary };

const ReservedCommitFailpoint = enum {
    none,
    primary_sync,
    backup_sync,
    attempt_pre_readback_sync,
    primary_unlink,
    backup_unlink,
    attempt_post_unlink_sync,
    attempt_rmdir,
    owner_sync,
};

pub const Pair = struct {
    primary_fd: c.fd_t,
    backup_fd: c.fd_t,

    pub fn deinit(self: *Pair) void {
        _ = c.close(self.primary_fd);
        _ = c.close(self.backup_fd);
        self.* = undefined;
    }
};

/// Pre-quiesce disk reservation. The private attempt directory is not a publication point; only
/// this owner can turn the two preallocated writable files into validated read-only handoff fds.
pub const Reservation = struct {
    owner_fd: c.fd_t,
    attempt_fd: c.fd_t,
    primary_fd: c.fd_t,
    backup_fd: c.fd_t,
    attempt_id: u128,
    reserved_len: usize,
    active: bool = true,
    owner_open: bool = true,
    attempt_open: bool = true,
    primary_open: bool = true,
    backup_open: bool = true,
    primary_present: bool = true,
    backup_present: bool = true,
    attempt_present: bool = true,

    pub fn deinit(self: *Reservation) void {
        self.cancel() catch @panic("upgrade handoff reservation cleanup failed");
    }

    /// Cancels the reservation exactly once and reports any cleanup failure. Product callers must
    /// turn that failure into fail-stop instead of claiming that the old graph resumed cleanly.
    pub fn cancel(self: *Reservation) Error!void {
        return self.cancelImpl(null);
    }

    fn cancelObserved(self: *Reservation, evidence: ?*KernelCleanupEvidence) Error!void {
        if (!builtin.is_test) @compileError("kernel cleanup observation is test-only");
        return self.cancelImpl(evidence);
    }

    fn cancelImpl(self: *Reservation, evidence: ?*KernelCleanupEvidence) Error!void {
        if (!self.active) return;
        var cleanup_failed = false;
        if (self.attempt_open and self.primary_open and self.primary_present) {
            removePinnedLeaf(
                self.attempt_fd,
                "primary",
                self.primary_fd,
                if (evidence) |value| &value.primary_remove else null,
            ) catch {
                cleanup_failed = true;
            };
        }
        if (self.attempt_open and self.backup_open and self.backup_present) {
            removePinnedLeaf(
                self.attempt_fd,
                "backup",
                self.backup_fd,
                if (evidence) |value| &value.backup_remove else null,
            ) catch {
                cleanup_failed = true;
            };
        }
        if (self.primary_open) _ = c.close(self.primary_fd);
        if (self.backup_open) _ = c.close(self.backup_fd);
        if (self.attempt_open) {
            if (c.fsync(self.attempt_fd) != 0) cleanup_failed = true;
            _ = c.close(self.attempt_fd);
        }
        var leaf_buf: [64]u8 = undefined;
        const leaf = std.fmt.bufPrintZ(&leaf_buf, "attempt-{x:0>32}", .{self.attempt_id}) catch {
            if (self.owner_open) _ = c.close(self.owner_fd);
            self.active = false;
            return error.CleanupFailed;
        };
        if (self.owner_open) {
            if (self.attempt_present and c.unlinkat(self.owner_fd, leaf.ptr, at_removedir) != 0) {
                if (comptime builtin.is_test) {
                    if (evidence) |value| value.attempt_remove = posix.errno(-1);
                }
                cleanup_failed = true;
            }
            if (c.fsync(self.owner_fd) != 0) cleanup_failed = true;
            _ = c.close(self.owner_fd);
        }
        self.active = false;
        if (cleanup_failed) return error.CleanupFailed;
    }
};

const KernelCleanupEvidence = struct {
    primary_remove: ?posix.E = null,
    backup_remove: ?posix.E = null,
    attempt_remove: ?posix.E = null,
};

pub const CommitBudget = struct {
    max_bytes: usize = limits.max_handoff_commit_bytes,
    deadline: upgrade_deadline.Deadline,

    pub fn testing() CommitBudget {
        if (!builtin.is_test) @compileError("unbounded handoff budget is test-only");
        return .{
            .deadline = .testingNever(),
        };
    }
};

pub const ExpectedAuthority = struct {
    host_id: u128,
    attempt_id: u128,
    upgrade_epoch: u64,
    next_handle: u64,
    /// RuntimeManager capture에서 stable sort한 exact live graph.
    runtime_ids: []const u128,
    request_path: []const u8,
    staged_path: []const u8,
    build_id: []const u8,
    sha256: [32]u8,
    dev: i64,
    ino: u64,
    size: u64,
    rollback_image: attempt_record.ImageView,
    reader_min: u16,
    reader_max: u16,
};

pub fn commit(
    allocator: std.mem.Allocator,
    owner_dir: [:0]const u8,
    expected: ExpectedAuthority,
    bytes: []const u8,
    budget: CommitBudget,
) Error!Pair {
    return commitWithFailpoint(allocator, owner_dir, expected, bytes, budget, .none);
}

/// Reserves both durable copies before readers are paused. `commitReserved` remains responsible
/// for semantic validation, final exact length, fsync, read-back, and unlink-before-exec.
pub fn reserve(
    owner_dir: [:0]const u8,
    attempt_id: u128,
    reserved_len: usize,
    deadline: upgrade_deadline.Deadline,
) Error!Reservation {
    return reserveWithFailpoint(owner_dir, attempt_id, reserved_len, deadline, .none);
}

fn reserveWithFailpoint(
    owner_dir: [:0]const u8,
    attempt_id: u128,
    reserved_len: usize,
    deadline: upgrade_deadline.Deadline,
    failpoint: ReserveFailpoint,
) Error!Reservation {
    try validateLength(reserved_len, .{ .deadline = deadline });
    try checkDeadline(.{ .deadline = deadline });
    const owner_fd = try openOwnerDir(owner_dir);
    var close_owner = true;
    defer {
        if (close_owner) _ = c.close(owner_fd);
    }
    var leaf_buf: [64]u8 = undefined;
    const leaf = std.fmt.bufPrintZ(&leaf_buf, "attempt-{x:0>32}", .{attempt_id}) catch
        return error.OpenFailed;
    if (c.mkdirat(owner_fd, leaf.ptr, 0o700) != 0) {
        if (posix.errno(-1) == .EXIST) return error.AlreadyExists;
        if (posix.errno(-1) == .NOSPC) return error.InsufficientSpace;
        return error.OpenFailed;
    }
    const attempt_fd = openOwnerDirAt(owner_fd, leaf) catch |err| {
        if (c.unlinkat(owner_fd, leaf.ptr, at_removedir) != 0 or c.fsync(owner_fd) != 0)
            return error.CleanupFailed;
        return err;
    };
    var reservation: Reservation = .{
        .owner_fd = owner_fd,
        .attempt_fd = attempt_fd,
        .primary_fd = -1,
        .backup_fd = -1,
        .attempt_id = attempt_id,
        .reserved_len = reserved_len,
        .primary_open = false,
        .backup_open = false,
        .primary_present = false,
        .backup_present = false,
    };
    reservation.primary_fd = createReservedFile(attempt_fd, "primary", reserved_len) catch |err| {
        cancelReserveFailure(&reservation, &close_owner) catch return error.CleanupFailed;
        return err;
    };
    reservation.primary_open = true;
    reservation.primary_present = true;
    if (failpoint == .after_primary) {
        cancelReserveFailure(&reservation, &close_owner) catch return error.CleanupFailed;
        return error.WriteFailed;
    }
    reservation.backup_fd = createReservedFile(attempt_fd, "backup", reserved_len) catch |err| {
        cancelReserveFailure(&reservation, &close_owner) catch return error.CleanupFailed;
        return err;
    };
    reservation.backup_open = true;
    reservation.backup_present = true;
    checkDeadline(.{ .deadline = deadline }) catch |err| {
        cancelReserveFailure(&reservation, &close_owner) catch return error.CleanupFailed;
        return err;
    };
    close_owner = false;
    return reservation;
}

fn cancelReserveFailure(reservation: *Reservation, close_owner: *bool) Error!void {
    // `Reservation.cancel` closes owner_fd. Disable the outer pre-transfer guard first so a
    // concurrently reused descriptor number can never be closed a second time on return.
    close_owner.* = false;
    try reservation.cancel();
}

pub fn commitReserved(
    allocator: std.mem.Allocator,
    reservation: *Reservation,
    expected: ExpectedAuthority,
    bytes: []const u8,
    budget: CommitBudget,
) Error!Pair {
    return commitReservedWithFailpoint(
        allocator,
        reservation,
        expected,
        bytes,
        budget,
        .none,
    );
}

fn commitReservedWithFailpoint(
    allocator: std.mem.Allocator,
    reservation: *Reservation,
    expected: ExpectedAuthority,
    bytes: []const u8,
    budget: CommitBudget,
    failpoint: ReservedCommitFailpoint,
) Error!Pair {
    if (!reservation.active or expected.attempt_id != reservation.attempt_id or
        bytes.len > reservation.reserved_len)
        return error.InvalidState;
    try validateLength(bytes.len, budget);
    try checkDeadline(budget);
    validateHandoff(allocator, expected, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidState,
    };
    try writeReservedFile(
        reservation.primary_fd,
        bytes,
        budget,
        failpoint == .primary_sync,
    );
    try writeReservedFile(
        reservation.backup_fd,
        bytes,
        budget,
        failpoint == .backup_sync,
    );
    if (failpoint == .attempt_pre_readback_sync) return error.SyncFailed;
    if (c.fsync(reservation.attempt_fd) != 0) return error.SyncFailed;
    try checkDeadline(budget);

    const primary_read = try openReadOnlyExact(reservation.attempt_fd, "primary", bytes.len);
    errdefer _ = c.close(primary_read);
    const backup_read = try openReadOnlyExact(reservation.attempt_fd, "backup", bytes.len);
    errdefer _ = c.close(backup_read);
    if (!sameFile(reservation.primary_fd, primary_read) or
        !sameFile(reservation.backup_fd, backup_read))
        return error.StateMismatch;
    try readbackEqual(primary_read, bytes, budget);
    try readbackEqual(backup_read, bytes, budget);
    if (failpoint == .primary_unlink) return error.CleanupFailed;
    try removePinnedLeaf(reservation.attempt_fd, "primary", reservation.primary_fd, null);
    reservation.primary_present = false;
    if (failpoint == .backup_unlink) return error.CleanupFailed;
    try removePinnedLeaf(reservation.attempt_fd, "backup", reservation.backup_fd, null);
    reservation.backup_present = false;
    _ = c.close(reservation.primary_fd);
    reservation.primary_open = false;
    _ = c.close(reservation.backup_fd);
    reservation.backup_open = false;
    if (failpoint == .attempt_post_unlink_sync) return error.SyncFailed;
    if (c.fsync(reservation.attempt_fd) != 0) return error.SyncFailed;
    _ = c.close(reservation.attempt_fd);
    reservation.attempt_open = false;
    var leaf_buf: [64]u8 = undefined;
    const leaf = std.fmt.bufPrintZ(
        &leaf_buf,
        "attempt-{x:0>32}",
        .{reservation.attempt_id},
    ) catch return error.CleanupFailed;
    if (failpoint == .attempt_rmdir) return error.CleanupFailed;
    if (c.unlinkat(reservation.owner_fd, leaf.ptr, at_removedir) != 0) return error.CleanupFailed;
    reservation.attempt_present = false;
    if (failpoint == .owner_sync) return error.SyncFailed;
    if (c.fsync(reservation.owner_fd) != 0) return error.SyncFailed;
    _ = c.close(reservation.owner_fd);
    reservation.owner_open = false;
    reservation.active = false;
    return .{ .primary_fd = primary_read, .backup_fd = backup_read };
}

/// Measures the same filesystem and one of the already preallocated files without publishing it.
/// The caller supplies incompressible bytes; the later authoritative commit overwrites this prefix.
pub fn probeReservation(
    reservation: *Reservation,
    sample: []const u8,
    deadline: upgrade_deadline.Deadline,
) Error!i128 {
    if (!reservation.active or sample.len == 0 or sample.len > reservation.reserved_len)
        return error.InvalidState;
    const started = deadline.nowNs();
    var offset: usize = 0;
    while (offset < sample.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const n = c.pwrite(
            reservation.primary_fd,
            sample.ptr + offset,
            sample.len - offset,
            @intCast(offset),
        );
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            if (posix.errno(n) == .NOSPC) return error.InsufficientSpace;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
    if (c.fsync(reservation.primary_fd) != 0)
        return if (posix.errno(-1) == .NOSPC) error.InsufficientSpace else error.SyncFailed;
    var checked: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (checked < sample.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const wanted = @min(buffer.len, sample.len - checked);
        const n = c.pread(
            reservation.primary_fd,
            &buffer,
            wanted,
            @intCast(checked),
        );
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.ReadFailed;
        const got: usize = @intCast(n);
        if (!std.mem.eql(u8, buffer[0..got], sample[checked .. checked + got]))
            return error.StateMismatch;
        checked += got;
    }
    const finished = deadline.nowNs();
    if (finished <= started) return error.InvalidState;
    return finished - started;
}

fn commitWithFailpoint(
    allocator: std.mem.Allocator,
    owner_dir: [:0]const u8,
    expected: ExpectedAuthority,
    bytes: []const u8,
    budget: CommitBudget,
    failpoint: Failpoint,
) Error!Pair {
    try validateLength(bytes.len, budget);
    try checkDeadline(budget);
    validateHandoff(allocator, expected, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidState,
    };
    try checkDeadline(budget);

    const owner_fd = try openOwnerDir(owner_dir);
    defer _ = c.close(owner_fd);
    var attempt_leaf_buf: [64]u8 = undefined;
    const attempt_leaf = std.fmt.bufPrintZ(
        &attempt_leaf_buf,
        "attempt-{x:0>32}",
        .{expected.attempt_id},
    ) catch return error.OpenFailed;
    if (c.mkdirat(owner_fd, attempt_leaf.ptr, 0o700) != 0) {
        if (posix.errno(-1) == .EXIST) return error.AlreadyExists;
        return error.OpenFailed;
    }
    var attempt_exists = true;
    defer {
        if (attempt_exists) _ = c.unlinkat(owner_fd, attempt_leaf.ptr, at_removedir);
    }

    const attempt_fd = openOwnerDirAt(owner_fd, attempt_leaf) catch return error.InvalidDirectory;
    var attempt_open = true;
    defer {
        if (attempt_open) _ = c.close(attempt_fd);
    }

    const primary_fd = try writeAtomicExclusive(
        attempt_fd,
        "primary",
        bytes,
        budget,
        failpoint == .primary_before_sync,
        failpoint == .primary_after_rename,
    );
    errdefer {
        removePinnedLeaf(attempt_fd, "primary", primary_fd, null) catch {};
        _ = c.close(primary_fd);
    }
    const backup_fd = try writeAtomicExclusive(
        attempt_fd,
        "backup",
        bytes,
        budget,
        failpoint == .backup_before_sync,
        false,
    );
    errdefer {
        removePinnedLeaf(attempt_fd, "backup", backup_fd, null) catch {};
        _ = c.close(backup_fd);
    }
    if (failpoint == .corrupt_backup_after_sync) {
        const fd = c.openat(
            attempt_fd,
            "backup",
            .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        const corrupt = [_]u8{bytes[0] ^ 0xFF};
        if (c.pwrite(fd, &corrupt, corrupt.len, 0) != 1) return error.WriteFailed;
        if (c.fsync(fd) != 0) return error.SyncFailed;
    }
    if (c.fsync(attempt_fd) != 0) return error.SyncFailed;
    try checkDeadline(budget);

    try validateReadOnlyExact(primary_fd, bytes.len);
    try validateReadOnlyExact(backup_fd, bytes.len);
    try readbackEqual(primary_fd, bytes, budget);
    try readbackEqual(backup_fd, bytes, budget);

    // read-back이 원본과 byte-identical이고 원본의 semantic decode가 위에서 성공했으므로 두 copy 모두 같은
    // logical handoff다. pathname은 inherited fd를 준비하기 전에 제거한다.
    try removePinnedLeaf(attempt_fd, "primary", primary_fd, null);
    try removePinnedLeaf(attempt_fd, "backup", backup_fd, null);
    if (c.fsync(attempt_fd) != 0) return error.SyncFailed;
    _ = c.close(attempt_fd);
    attempt_open = false;
    if (c.unlinkat(owner_fd, attempt_leaf.ptr, at_removedir) != 0) return error.CleanupFailed;
    attempt_exists = false;
    if (c.fsync(owner_fd) != 0) return error.SyncFailed;
    try checkDeadline(budget);
    return .{ .primary_fd = primary_fd, .backup_fd = backup_fd };
}

fn validateLength(len: usize, budget: CommitBudget) Error!void {
    if (len == 0 or len > handoff.max_total_bytes or len > limits.max_handoff_commit_bytes or
        len > budget.max_bytes)
        return error.LimitExceeded;
}

fn openOwnerDir(path: [:0]const u8) Error!c.fd_t {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidDirectory;
    errdefer _ = c.close(fd);
    try validateOwnerDir(fd);
    return fd;
}

fn openOwnerDirAt(parent_fd: c.fd_t, leaf: [:0]const u8) Error!c.fd_t {
    const fd = c.openat(
        parent_fd,
        leaf.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (fd < 0) return error.InvalidDirectory;
    errdefer _ = c.close(fd);
    try validateOwnerDir(fd);
    return fd;
}

fn validateOwnerDir(fd: c.fd_t) Error!void {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o077 != 0)
        return error.InvalidDirectory;
}

fn writeAtomicExclusive(
    dir_fd: c.fd_t,
    leaf: [:0]const u8,
    bytes: []const u8,
    budget: CommitBudget,
    fail_before_sync: bool,
    fail_after_rename: bool,
) Error!c.fd_t {
    var tmp_buf: [96]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, ".{s}.tmp-{d}", .{ leaf, c.getpid() }) catch
        return error.OpenFailed;
    const fd = c.openat(
        dir_fd,
        tmp.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var tmp_exists = true;
    defer {
        if (tmp_exists) removePinnedLeaf(dir_fd, tmp, fd, null) catch {};
    }
    try checkDeadline(budget);
    try reserveExact(fd, bytes.len);
    try checkDeadline(budget);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkDeadline(budget);
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
    if (fail_before_sync) return error.WriteFailed;
    try checkDeadline(budget);
    if (c.fsync(fd) != 0) return error.SyncFailed;
    try checkDeadline(budget);
    if (renameatx_np(dir_fd, tmp.ptr, dir_fd, leaf.ptr, rename_excl) != 0) return error.OpenFailed;
    tmp_exists = false;
    var final_exists = true;
    defer {
        if (final_exists) removePinnedLeaf(dir_fd, leaf, fd, null) catch {};
    }
    if (fail_after_rename) return error.OpenFailed;
    const read_fd = try openReadOnlyExact(dir_fd, leaf, bytes.len);
    errdefer _ = c.close(read_fd);
    if (!sameFile(fd, read_fd)) return error.StateMismatch;
    final_exists = false;
    return read_fd;
}

fn createReservedFile(dir_fd: c.fd_t, leaf: [:0]const u8, len: usize) Error!c.fd_t {
    const fd = c.openat(
        dir_fd,
        leaf.ptr,
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0)
        return if (posix.errno(-1) == .NOSPC) error.InsufficientSpace else error.OpenFailed;
    errdefer _ = c.close(fd);
    reserveExact(fd, len) catch |err| {
        removePinnedLeaf(dir_fd, leaf, fd, null) catch return error.CleanupFailed;
        return err;
    };
    return fd;
}

fn writeReservedFile(
    fd: c.fd_t,
    bytes: []const u8,
    budget: CommitBudget,
    fail_sync: bool,
) Error!void {
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.WriteFailed;
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkDeadline(budget);
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
    const exact = std.math.cast(i64, bytes.len) orelse return error.LimitExceeded;
    if (c.ftruncate(fd, exact) != 0) return error.WriteFailed;
    try checkDeadline(budget);
    if (fail_sync) return error.SyncFailed;
    if (c.fsync(fd) != 0) return error.SyncFailed;
    try checkDeadline(budget);
}

fn reserveExact(fd: c.fd_t, len: usize) Error!void {
    const exact = std.math.cast(i64, len) orelse return error.LimitExceeded;
    var store: FStore = .{
        .flags = f_allocate_all,
        .posmode = f_peof_posmode,
        .offset = 0,
        .length = exact,
        .bytes_allocated = 0,
    };
    if (c.fcntl(fd, f_preallocate, &store) < 0 or store.bytes_allocated < exact)
        return error.InsufficientSpace;
    if (c.ftruncate(fd, exact) != 0) return error.InsufficientSpace;
}

fn validateHandoff(allocator: std.mem.Allocator, expected: ExpectedAuthority, bytes: []const u8) !void {
    var decoded = try handoff.decodeHost(allocator, bytes);
    defer decoded.deinit();
    const nested_bytes = decoded.attempt_record orelse return error.InvalidState;
    var nested = try attempt_record.decode(allocator, nested_bytes);
    defer nested.deinit();
    if (decoded.host_id != expected.host_id or
        nested.host_id != expected.host_id or
        decoded.upgrade_epoch != expected.upgrade_epoch or
        decoded.next_handle != expected.next_handle or
        nested.attempt_id != expected.attempt_id or
        nested.epoch_before != expected.upgrade_epoch or
        nested.runtime_ids.len != decoded.runtimes.len)
        return error.InvalidState;
    if (!std.mem.eql(u8, nested.request_path, expected.request_path) or
        !std.mem.eql(u8, nested.staged_path, expected.staged_path) or
        !std.mem.eql(u8, nested.build_id, expected.build_id) or
        !std.mem.eql(u8, &nested.sha256, &expected.sha256) or
        nested.dev != expected.dev or nested.ino != expected.ino or nested.size != expected.size or
        !std.mem.eql(u8, nested.rollback_path, expected.rollback_image.path) or
        !std.mem.eql(u8, &nested.rollback_sha256, &expected.rollback_image.sha256) or
        nested.rollback_dev != expected.rollback_image.dev or
        nested.rollback_ino != expected.rollback_image.ino or
        nested.rollback_size != expected.rollback_image.size or
        nested.reader_min != expected.reader_min or nested.reader_max != expected.reader_max)
        return error.InvalidState;
    var runtime_ids: [attempt_record.max_runtime_count]u128 = undefined;
    for (decoded.runtimes, 0..) |runtime, index| {
        runtime_ids[index] = runtime.runtime_id;
    }
    std.mem.sort(u128, runtime_ids[0..decoded.runtimes.len], {}, std.sort.asc(u128));
    if (!std.mem.eql(u128, nested.runtime_ids, runtime_ids[0..decoded.runtimes.len]))
        return error.InvalidState;
    if (!std.mem.eql(u128, expected.runtime_ids, runtime_ids[0..decoded.runtimes.len]))
        return error.InvalidState;
}

fn openReadOnlyExact(dir_fd: c.fd_t, leaf: [:0]const u8, expected_len: usize) Error!c.fd_t {
    const fd = c.openat(
        dir_fd,
        leaf.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (fd < 0) return error.OpenFailed;
    errdefer _ = c.close(fd);
    try validateReadOnlyExact(fd, expected_len);
    return fd;
}

fn validateReadOnlyExact(fd: c.fd_t, expected_len: usize) Error!void {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o177 != 0 or stat.size < 0 or @as(u64, @intCast(stat.size)) != expected_len)
        return error.InvalidState;
}

fn sameFile(a: c.fd_t, b: c.fd_t) bool {
    var a_stat: posix.Stat = undefined;
    var b_stat: posix.Stat = undefined;
    return c.fstat(a, &a_stat) == 0 and c.fstat(b, &b_stat) == 0 and
        a_stat.dev == b_stat.dev and a_stat.ino == b_stat.ino;
}

fn removePinnedLeaf(
    dir_fd: c.fd_t,
    leaf: [:0]const u8,
    pinned_fd: c.fd_t,
    kernel_error: ?*?posix.E,
) Error!void {
    var tomb_buf: [128]u8 = undefined;
    const tomb = std.fmt.bufPrintZ(&tomb_buf, ".{s}.remove-{d}", .{ leaf, c.getpid() }) catch
        return error.CleanupFailed;
    if (renameatx_np(dir_fd, leaf.ptr, dir_fd, tomb.ptr, rename_excl) != 0) {
        if (comptime builtin.is_test) {
            if (kernel_error) |value| value.* = posix.errno(-1);
        }
        return error.CleanupFailed;
    }
    const tomb_fd = openReadOnlyExactFromPinned(dir_fd, tomb, pinned_fd) catch {
        _ = renameatx_np(dir_fd, tomb.ptr, dir_fd, leaf.ptr, rename_excl);
        return error.CleanupFailed;
    };
    defer _ = c.close(tomb_fd);
    if (c.unlinkat(dir_fd, tomb.ptr, 0) != 0) {
        if (comptime builtin.is_test) {
            if (kernel_error) |value| value.* = posix.errno(-1);
        }
        return error.CleanupFailed;
    }
}

fn openReadOnlyExactFromPinned(dir_fd: c.fd_t, leaf: [:0]const u8, pinned_fd: c.fd_t) Error!c.fd_t {
    const fd = c.openat(
        dir_fd,
        leaf.ptr,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0),
    );
    if (fd < 0) return error.OpenFailed;
    errdefer _ = c.close(fd);
    if (!sameFile(fd, pinned_fd)) return error.StateMismatch;
    return fd;
}

fn readbackEqual(fd: c.fd_t, expected: []const u8, budget: CommitBudget) Error!void {
    var offset: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (offset < expected.len) {
        try checkDeadline(budget);
        const want = @min(buffer.len, expected.len - offset);
        const n = c.pread(fd, &buffer, want, @intCast(offset));
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.StateMismatch;
        const count: usize = @intCast(n);
        if (!std.mem.eql(u8, buffer[0..count], expected[offset .. offset + count]))
            return error.StateMismatch;
        offset += count;
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const n = c.pread(fd, &extra, 1, @intCast(offset));
        if (n == 0) break;
        if (n < 0 and posix.errno(n) == .INTR) continue;
        if (n < 0) return error.ReadFailed;
        return error.StateMismatch;
    }
    try checkDeadline(budget);
}

fn checkDeadline(budget: CommitBudget) Error!void {
    if (budget.deadline.expired()) return error.DeadlineExceeded;
}

fn testAttemptRecord(allocator: std.mem.Allocator, host_id: u128, attempt_id: u128) ![]u8 {
    return attempt_record.encode(allocator, .{
        .host_id = host_id,
        .attempt_id = attempt_id,
        .epoch_before = 3,
        .expected_epoch_after = 4,
        .rollback_budget = 1,
        .deadline_expires_at_ns = std.math.maxInt(i128),
        .request_path = "/Applications/Maru",
        .staged_path = "/tmp/maru/target",
        .build_id = "sha256:0101010101010101010101010101010101010101010101010101010101010101",
        .sha256 = [_]u8{1} ** 32,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .rollback_image = .{
            .path = "/tmp/maru/rollback-current",
            .sha256 = [_]u8{2} ** 32,
            .dev = 4,
            .ino = 5,
            .size = 6,
        },
        .reader_min = 1,
        .reader_max = 1,
        .runtime_ids = &.{},
        .completed = &.{},
    });
}

fn testExpected(host_id: u128, attempt_id: u128, next_handle: u64) ExpectedAuthority {
    return .{
        .host_id = host_id,
        .attempt_id = attempt_id,
        .upgrade_epoch = 3,
        .next_handle = next_handle,
        .runtime_ids = &.{},
        .request_path = "/Applications/Maru",
        .staged_path = "/tmp/maru/target",
        .build_id = "sha256:0101010101010101010101010101010101010101010101010101010101010101",
        .sha256 = [_]u8{1} ** 32,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .rollback_image = .{
            .path = "/tmp/maru/rollback-current",
            .sha256 = [_]u8{2} ** 32,
            .dev = 4,
            .ino = 5,
            .size = 6,
        },
        .reader_min = 1,
        .reader_max = 1,
    };
}

fn testOpenFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| {
        count = std.math.add(u32, count, 1) catch return error.TooManyOpenFds;
    }
    return count;
}

test "handoff store commits identical primary backup and unlinks secret paths before exec" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-store");
    defer test_scratch.close(std.testing.io, dir);
    const record = try testAttemptRecord(std.testing.allocator, 0xAA, 0x11);
    defer std.testing.allocator.free(record);
    const bytes = try handoff.encodeHost(std.testing.allocator, .{
        .host_id = 0xAA,
        .upgrade_epoch = 3,
        .next_handle = 4,
        .runtimes = &.{},
        .attempt_record = record,
    });
    defer std.testing.allocator.free(bytes);
    var divergent = testExpected(0xAA, 0x11, 4);
    divergent.upgrade_epoch = 4;
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.request_path = "/other";
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.staged_path = "/other";
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.build_id = "sha256:0202020202020202020202020202020202020202020202020202020202020202";
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.sha256 = [_]u8{2} ** 32;
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.dev = 9;
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.ino = 9;
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.size = 9;
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    divergent = testExpected(0xAA, 0x11, 4);
    divergent.reader_max = 2;
    try std.testing.expectError(error.InvalidState, validateHandoff(std.testing.allocator, divergent, bytes));
    var tiny_budget = CommitBudget.testing();
    tiny_budget.max_bytes = bytes.len - 1;
    try std.testing.expectError(
        error.LimitExceeded,
        commit(
            std.testing.allocator,
            dir,
            testExpected(0xBB, 2, 4),
            bytes,
            tiny_budget,
        ),
    );
    var pair = try commit(
        std.testing.allocator,
        dir,
        testExpected(0xAA, 0x11, 4),
        bytes,
        CommitBudget.testing(),
    );
    try readbackEqual(pair.primary_fd, bytes, CommitBudget.testing());
    try readbackEqual(pair.backup_fd, bytes, CommitBudget.testing());
    try std.testing.expect(c.fcntl(pair.primary_fd, c.F.GETFD, @as(c_int, 0)) & c.FD_CLOEXEC != 0);
    try std.testing.expect(c.fcntl(pair.backup_fd, c.F.GETFD, @as(c_int, 0)) & c.FD_CLOEXEC != 0);
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(&attempt_buf, "{s}/attempt-{x:0>32}", .{ dir, @as(u128, 0x11) });
    try std.testing.expect(c.access(attempt_path.ptr, c.F_OK) != 0);
    const primary_fd = pair.primary_fd;
    const backup_fd = pair.backup_fd;
    pair.deinit();
    try std.testing.expect(c.fcntl(primary_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
    try std.testing.expect(c.fcntl(backup_fd, c.F.GETFD, @as(c_int, 0)) < 0);
    try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
}

test "reserved handoff commits into pre-quiesce files and cleans the private attempt" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-store-reserved");
    defer test_scratch.close(std.testing.io, dir);
    const record = try testAttemptRecord(std.testing.allocator, 0xAC, 0x13);
    defer std.testing.allocator.free(record);
    const bytes = try handoff.encodeHost(std.testing.allocator, .{
        .host_id = 0xAC,
        .upgrade_epoch = 3,
        .next_handle = 4,
        .runtimes = &.{},
        .attempt_record = record,
    });
    defer std.testing.allocator.free(bytes);
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    var reservation = try reserve(dir, 0x13, bytes.len + 128, deadline);
    defer reservation.deinit();
    var pair = try commitReserved(
        std.testing.allocator,
        &reservation,
        testExpected(0xAC, 0x13, 4),
        bytes,
        .{ .deadline = deadline },
    );
    defer pair.deinit();
    try readbackEqual(pair.primary_fd, bytes, .{ .deadline = deadline });
    try readbackEqual(pair.backup_fd, bytes, .{ .deadline = deadline });
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ dir, @as(u128, 0x13) },
    );
    try std.testing.expect(c.access(attempt_path.ptr, c.F_OK) != 0);
}

test "reserved handoff syscall failures publish no pair and leave no attempt residue" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-store-reserved-failures");
    defer test_scratch.close(std.testing.io, dir);
    const attempt_id: u128 = 0x1313;
    const record = try testAttemptRecord(std.testing.allocator, 0xAC, attempt_id);
    defer std.testing.allocator.free(record);
    const bytes = try handoff.encodeHost(std.testing.allocator, .{
        .host_id = 0xAC,
        .upgrade_epoch = 3,
        .next_handle = 4,
        .runtimes = &.{},
        .attempt_record = record,
    });
    defer std.testing.allocator.free(bytes);
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    const cases = [_]struct { failpoint: ReservedCommitFailpoint, expected: Error }{
        .{ .failpoint = .primary_sync, .expected = error.SyncFailed },
        .{ .failpoint = .backup_sync, .expected = error.SyncFailed },
        .{ .failpoint = .attempt_pre_readback_sync, .expected = error.SyncFailed },
        .{ .failpoint = .primary_unlink, .expected = error.CleanupFailed },
        .{ .failpoint = .backup_unlink, .expected = error.CleanupFailed },
        .{ .failpoint = .attempt_post_unlink_sync, .expected = error.SyncFailed },
        .{ .failpoint = .attempt_rmdir, .expected = error.CleanupFailed },
        .{ .failpoint = .owner_sync, .expected = error.SyncFailed },
    };
    for (cases) |case| {
        const fd_count_before = try testOpenFdCount();
        var reservation = try reserve(dir, attempt_id, bytes.len + 128, deadline);
        const primary_fd = reservation.primary_fd;
        const backup_fd = reservation.backup_fd;
        try std.testing.expectError(
            case.expected,
            commitReservedWithFailpoint(
                std.testing.allocator,
                &reservation,
                testExpected(0xAC, attempt_id, 4),
                bytes,
                .{ .deadline = deadline },
                case.failpoint,
            ),
        );
        try reservation.cancel();
        try std.testing.expect(!reservation.active);
        try std.testing.expect(c.fcntl(primary_fd, c.F.GETFD, @as(c_int, 0)) < 0);
        try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
        try std.testing.expect(c.fcntl(backup_fd, c.F.GETFD, @as(c_int, 0)) < 0);
        try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
        var attempt_buf: [256]u8 = undefined;
        const attempt_path = try std.fmt.bufPrintZ(
            &attempt_buf,
            "{s}/attempt-{x:0>32}",
            .{ dir, attempt_id },
        );
        try std.testing.expect(c.access(attempt_path.ptr, c.F_OK) != 0);
        try std.testing.expectEqual(fd_count_before, try testOpenFdCount());
    }
}

test "reservation cleanup identity failure closes descriptors and preserves replacement" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-reservation-cleanup-failure");
    defer test_scratch.close(std.testing.io, dir);
    const fd_count_before = try testOpenFdCount();
    const attempt_id: u128 = 0x1414;
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    var reservation = try reserve(dir, attempt_id, 4096, deadline);
    const primary_fd = reservation.primary_fd;
    const backup_fd = reservation.backup_fd;
    const attempt_fd = reservation.attempt_fd;
    const owner_fd = reservation.owner_fd;

    if (renameatx_np(attempt_fd, "primary", attempt_fd, "saved", rename_excl) != 0)
        return error.TestUnexpectedResult;
    const replacement_fd = c.openat(
        attempt_fd,
        "primary",
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (replacement_fd < 0) return error.TestUnexpectedResult;
    var replacement_open = true;
    defer {
        if (replacement_open) _ = c.close(replacement_fd);
    }
    try std.testing.expectEqual(@as(isize, 1), c.write(replacement_fd, "b", 1));

    try std.testing.expectError(error.CleanupFailed, reservation.cancel());
    try std.testing.expect(!reservation.active);
    try readbackEqual(replacement_fd, "b", CommitBudget.testing());
    for ([_]c.fd_t{ primary_fd, backup_fd, attempt_fd, owner_fd }) |fd| {
        try std.testing.expect(c.fcntl(fd, c.F.GETFD, @as(c_int, 0)) < 0);
        try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
    }
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ dir, attempt_id },
    );
    try std.testing.expect(c.access(attempt_path.ptr, c.F_OK) == 0);
    var primary_path_buf: [288]u8 = undefined;
    const primary_path = try std.fmt.bufPrintZ(&primary_path_buf, "{s}/primary", .{attempt_path});
    var saved_path_buf: [288]u8 = undefined;
    const saved_path = try std.fmt.bufPrintZ(&saved_path_buf, "{s}/saved", .{attempt_path});
    var backup_path_buf: [288]u8 = undefined;
    const backup_path = try std.fmt.bufPrintZ(&backup_path_buf, "{s}/backup", .{attempt_path});
    try std.testing.expect(c.access(primary_path.ptr, c.F_OK) == 0);
    try std.testing.expect(c.access(saved_path.ptr, c.F_OK) == 0);
    try std.testing.expect(c.access(backup_path.ptr, c.F_OK) != 0);
    _ = c.close(replacement_fd);
    replacement_open = false;
    try std.testing.expectEqual(fd_count_before, try testOpenFdCount());
}

test "reservation cleanup observes consecutive kernel permission and nonempty failures" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-kernel-cleanup-faults");
    defer test_scratch.close(std.testing.io, dir);
    const fd_count_before = try testOpenFdCount();
    const attempt_id: u128 = 0x1515;
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    var reservation = try reserve(dir, attempt_id, 4096, deadline);
    const primary_fd = reservation.primary_fd;
    const backup_fd = reservation.backup_fd;
    const attempt_fd = reservation.attempt_fd;
    const owner_fd = reservation.owner_fd;
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ dir, attempt_id },
    );
    if (c.fchmod(attempt_fd, 0o500) != 0) return error.TestUnexpectedResult;
    var permissions_restored = false;
    defer {
        if (!permissions_restored) _ = c.chmod(attempt_path.ptr, 0o700);
    }

    var evidence: KernelCleanupEvidence = .{};
    try std.testing.expectError(error.CleanupFailed, reservation.cancelObserved(&evidence));
    try std.testing.expectEqual(posix.E.ACCES, evidence.primary_remove.?);
    try std.testing.expectEqual(posix.E.ACCES, evidence.backup_remove.?);
    try std.testing.expectEqual(posix.E.NOTEMPTY, evidence.attempt_remove.?);
    try std.testing.expect(!reservation.active);
    for ([_]c.fd_t{ primary_fd, backup_fd, attempt_fd, owner_fd }) |fd| {
        try std.testing.expect(c.fcntl(fd, c.F.GETFD, @as(c_int, 0)) < 0);
        try std.testing.expectEqual(posix.E.BADF, posix.errno(-1));
    }
    try std.testing.expect(c.chmod(attempt_path.ptr, 0o700) == 0);
    permissions_restored = true;
    try std.testing.expectEqual(fd_count_before, try testOpenFdCount());
}

test "partial reservation failure removes the first copy and private attempt" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-store-partial-reserve");
    defer test_scratch.close(std.testing.io, dir);
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    try std.testing.expectError(
        error.WriteFailed,
        reserveWithFailpoint(dir, 0x14, 4096, deadline, .after_primary),
    );
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ dir, @as(u128, 0x14) },
    );
    try std.testing.expect(c.access(attempt_path.ptr, c.F_OK) != 0);
}

test "handoff store rejects malformed or divergent state and removes attempt residue" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-store-fail");
    defer test_scratch.close(std.testing.io, dir);
    var raised_budget = CommitBudget.testing();
    raised_budget.max_bytes = std.math.maxInt(usize);
    try std.testing.expectError(
        error.LimitExceeded,
        validateLength(limits.max_handoff_commit_bytes + 1, raised_budget),
    );
    try std.testing.expectError(
        error.InvalidState,
        commit(
            std.testing.allocator,
            dir,
            testExpected(0xBB, 1, 5),
            "not-handoff",
            CommitBudget.testing(),
        ),
    );

    const record = try testAttemptRecord(std.testing.allocator, 0xBB, 2);
    defer std.testing.allocator.free(record);
    const bytes = try handoff.encodeHost(std.testing.allocator, .{
        .host_id = 0xBB,
        .upgrade_epoch = 3,
        .next_handle = 5,
        .runtimes = &.{},
        .attempt_record = record,
    });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(
        error.InvalidState,
        commit(std.testing.allocator, dir, testExpected(0xBB, 3, 5), bytes, CommitBudget.testing()),
    );
    try std.testing.expectError(
        error.InvalidState,
        commit(std.testing.allocator, dir, testExpected(0xBC, 2, 5), bytes, CommitBudget.testing()),
    );
    try std.testing.expectError(
        error.InvalidState,
        commit(std.testing.allocator, dir, testExpected(0xBB, 2, 4), bytes, CommitBudget.testing()),
    );
    try std.testing.expectError(
        error.StateMismatch,
        commitWithFailpoint(
            std.testing.allocator,
            dir,
            testExpected(0xBB, 2, 5),
            bytes,
            CommitBudget.testing(),
            .corrupt_backup_after_sync,
        ),
    );
    for ([_]struct { failpoint: Failpoint, expected_error: Error }{
        .{ .failpoint = .primary_before_sync, .expected_error = error.WriteFailed },
        .{ .failpoint = .primary_after_rename, .expected_error = error.OpenFailed },
        .{ .failpoint = .backup_before_sync, .expected_error = error.WriteFailed },
    }) |case| {
        try std.testing.expectError(
            case.expected_error,
            commitWithFailpoint(
                std.testing.allocator,
                dir,
                testExpected(0xBB, 2, 5),
                bytes,
                CommitBudget.testing(),
                case.failpoint,
            ),
        );
        var failed_attempt_buf: [256]u8 = undefined;
        const failed_attempt = try std.fmt.bufPrintZ(
            &failed_attempt_buf,
            "{s}/attempt-{x:0>32}",
            .{ dir, @as(u128, 2) },
        );
        try std.testing.expect(c.access(failed_attempt.ptr, c.F_OK) != 0);
    }
    const Expirer = struct {
        remaining: usize,

        fn now(ctx: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.remaining == 0) return 1;
            self.remaining -= 1;
            return 0;
        }

        fn deadline(self: *@This()) upgrade_deadline.Deadline {
            return .fromInjected(.{ .ctx = self, .now_ns = now }, 1);
        }
    };
    var expirer: Expirer = .{ .remaining = 3 };
    try std.testing.expectError(
        error.DeadlineExceeded,
        commit(
            std.testing.allocator,
            dir,
            testExpected(0xBB, 2, 5),
            bytes,
            .{ .deadline = expirer.deadline() },
        ),
    );
    var final_expirer: Expirer = .{ .remaining = 17 };
    try std.testing.expectError(
        error.DeadlineExceeded,
        commit(
            std.testing.allocator,
            dir,
            testExpected(0xBB, 2, 5),
            bytes,
            .{ .deadline = final_expirer.deadline() },
        ),
    );
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(&attempt_buf, "{s}/attempt-{x:0>32}", .{ dir, @as(u128, 2) });
    try std.testing.expect(c.access(attempt_path.ptr, c.F_OK) != 0);
}

test "handoff store directory fd stays on the approved generation after path replacement" {
    var owner_buf: [192]u8 = undefined;
    const owner = try test_scratch.open(std.testing.io, &owner_buf, "handoff-dir-pin");
    var pinned_buf: [208]u8 = undefined;
    const pinned = try std.fmt.bufPrintZ(&pinned_buf, "{s}.pinned", .{owner});
    // `.pinned`는 이 테스트가 rename으로 만드는 **대상**이라 미리 만들지 않는다 — 잔여물만 걷는다.
    test_scratch.close(std.testing.io, pinned);
    const owner_fd = try openOwnerDir(owner);
    defer _ = c.close(owner_fd);
    if (c.rename(owner.ptr, pinned.ptr) != 0) return error.SkipZigTest;
    defer {
        var child_buf: [224]u8 = undefined;
        if (std.fmt.bufPrintZ(&child_buf, "{s}/child", .{pinned})) |child| {
            _ = c.rmdir(child.ptr);
        } else |_| {}
        _ = c.rmdir(pinned.ptr);
        _ = c.rmdir(owner.ptr);
    }
    if (c.mkdir(owner.ptr, 0o700) != 0) return error.SkipZigTest;
    if (c.mkdirat(owner_fd, "child", 0o700) != 0) return error.SkipZigTest;
    var pinned_child_buf: [224]u8 = undefined;
    const pinned_child = try std.fmt.bufPrintZ(&pinned_child_buf, "{s}/child", .{pinned});
    var replacement_child_buf: [224]u8 = undefined;
    const replacement_child = try std.fmt.bufPrintZ(&replacement_child_buf, "{s}/child", .{owner});
    try std.testing.expect(c.access(pinned_child.ptr, c.F_OK) == 0);
    try std.testing.expect(c.access(replacement_child.ptr, c.F_OK) != 0);
}

test "handoff store exact cleanup preserves a swapped replacement leaf" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "handoff-cleanup-pin");
    defer test_scratch.close(std.testing.io, dir);
    const dir_fd = try openOwnerDir(dir);
    defer _ = c.close(dir_fd);

    const original_fd = c.openat(
        dir_fd,
        "leaf",
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (original_fd < 0) return error.SkipZigTest;
    defer _ = c.close(original_fd);
    try std.testing.expectEqual(@as(isize, 1), c.write(original_fd, "a", 1));
    try validateReadOnlyExact(original_fd, 1);
    if (renameatx_np(dir_fd, "leaf", dir_fd, "saved", rename_excl) != 0) return error.SkipZigTest;
    defer removePinnedLeaf(dir_fd, "saved", original_fd, null) catch {};

    const replacement_fd = c.openat(
        dir_fd,
        "leaf",
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (replacement_fd < 0) return error.SkipZigTest;
    defer _ = c.close(replacement_fd);
    defer removePinnedLeaf(dir_fd, "leaf", replacement_fd, null) catch {};
    try std.testing.expectEqual(@as(isize, 1), c.write(replacement_fd, "b", 1));

    try std.testing.expectError(error.CleanupFailed, removePinnedLeaf(dir_fd, "leaf", original_fd, null));
    try readbackEqual(replacement_fd, "b", CommitBudget.testing());
}
