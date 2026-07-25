//! Host lifetime owner lease(U3). Launch-time control lock과 달리 host 전체 수명 및 same-PID exec 동안 유지한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
extern "c" fn nanosleep(rqtp: *const c.timespec, rmtp: ?*c.timespec) c_int;

pub const Error = error{
    OpenFailed,
    InvalidOwnerFile,
    AlreadyOwned,
    LockFailed,
    FcntlFailed,
    CleanupFailed,
};

/// Read-only 생존 관측. `unknown`을 `free`로 접으면 GUI의 fd/권한 실패를 host 사망 증거로 오인한다.
pub const Observation = enum {
    free,
    held,
    unknown,
};

pub fn observe(path: [:0]const u8) Observation {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return if (posix.errno(fd) == .NOENT) .free else .unknown;
    defer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !metadataIsValid(stat, c.getuid())) return .unknown;
    var path_stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, path.ptr, &path_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !metadataIsValid(path_stat, c.getuid()) or path_stat.dev != stat.dev or path_stat.ino != stat.ino)
        return .unknown;
    const rc = c.flock(fd, c.LOCK.EX | c.LOCK.NB);
    const lock_contended = rc != 0 and posix.errno(rc) == .AGAIN;
    // lock 판정 직후 pathname을 다시 pin한다. open→flock 사이 replacement를 old inode의 held/free로 보고하지 않는다.
    if (c.fstatat(posix.AT.FDCWD, path.ptr, &path_stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !metadataIsValid(path_stat, c.getuid()) or path_stat.dev != stat.dev or path_stat.ino != stat.ino)
        return .unknown;
    if (rc == 0) return .free;
    return if (lock_contended) .held else .unknown;
}

pub const OwnerLease = struct {
    const Identity = struct {
        dev: posix.dev_t,
        ino: posix.ino_t,
    };

    pub const UnlinkOutcome = enum { removed, replaced, absent };

    fd: c.fd_t,
    identity: Identity,

    pub fn acquire(path: [:0]const u8) Error!OwnerLease {
        var created = false;
        var fd = c.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (fd < 0 and posix.errno(fd) == .NOENT) {
            fd = c.open(
                path.ptr,
                .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
                @as(c.mode_t, 0o600),
            );
            if (fd >= 0) {
                created = true;
            } else if (posix.errno(fd) == .EXIST) {
                fd = openExistingAfterCreateRace(path);
            }
        } else if (fd < 0 and posix.errno(fd) == .ACCES) {
            fd = openExistingAfterCreateRace(path);
        }
        if (fd < 0) return classifyOpenFailure(path);
        errdefer _ = c.close(fd);
        // open(2)의 mode는 umask 영향을 받는다. 우리가 O_EXCL로 새 inode를 만든 경우에만
        // exact 0600으로 고정한다. 기존 unsafe leaf는 절대 자동 repair하지 않는다.
        if (created and c.fchmod(fd, 0o600) != 0) return error.FcntlFailed;
        try validate(fd);
        const rc = c.flock(fd, c.LOCK.EX | c.LOCK.NB);
        // Darwin에서 EWOULDBLOCK은 EAGAIN과 같은 errno이며 Zig는 AGAIN으로 노출한다.
        if (rc != 0) return if (posix.errno(rc) == .AGAIN) error.AlreadyOwned else error.LockFailed;
        const identity = try identityForFd(fd);
        const path_identity = identityForPath(path) catch return error.InvalidOwnerFile;
        if (!sameIdentity(identity, path_identity)) return error.InvalidOwnerFile;
        return .{ .fd = fd, .identity = identity };
    }

    fn openExistingAfterCreateRace(path: [:0]const u8) c.fd_t {
        // O_EXCL winner가 restrictive umask로 mode 000 inode를 만든 직후 fchmod(0600)하기
        // 전에는 peer open이 EACCES일 수 있다. current-UID regular leaf인 동안만 bounded
        // retry하고, creator가 죽었거나 기존 unsafe leaf면 classifyOpenFailure가 unsafe로
        // 확정한다. 기존 inode를 chmod하거나 repair하지 않는다.
        var attempts: usize = 0;
        while (attempts < 250) : (attempts += 1) {
            const fd = c.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
            if (fd >= 0) return fd;
            if (posix.errno(fd) != .ACCES and posix.errno(fd) != .NOENT) return fd;
            var stat: posix.Stat = undefined;
            if (c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) == 0 and
                (!posix.S.ISREG(stat.mode) or stat.uid != c.getuid()))
                return fd;
            const delay = c.timespec{ .sec = 0, .nsec = 1_000_000 };
            _ = nanosleep(&delay, null);
        }
        return -1;
    }

    fn classifyOpenFailure(path: [:0]const u8) Error {
        // 성공 권위는 fd fstat뿐이다. 이 no-follow stat은 기존 unsafe leaf를
        // generic I/O 실패로 숨기지 않기 위한 error classification 전용이다.
        var stat: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) == 0 and
            !metadataIsValid(stat, c.getuid()))
            return error.InvalidOwnerFile;
        return error.OpenFailed;
    }

    /// Target image가 inherited non-CLOEXEC owner slot을 CLOEXEC working descriptor로 바꿔 lifetime lock을 이어받는다.
    pub fn adoptInherited(slot: c.fd_t) Error!OwnerLease {
        try validate(slot);
        const duped = c.fcntl(slot, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (duped < 0) return error.FcntlFailed;
        return .{ .fd = duped, .identity = try identityForFd(duped) };
    }

    pub fn validateInheritedExact(
        slot: c.fd_t,
        path: [:0]const u8,
    ) Error!void {
        try validate(slot);
        const raw_flags = c.fcntl(slot, c.F.GETFL, @as(c_int, 0));
        if (raw_flags < 0) return error.InvalidOwnerFile;
        const open_flags: c.O = @bitCast(@as(u32, @intCast(raw_flags)));
        if (open_flags.ACCMODE != .RDWR) return error.InvalidOwnerFile;
        const slot_identity = try identityForFd(slot);
        const path_identity = identityForPath(path) catch
            return error.InvalidOwnerFile;
        if (!sameIdentity(slot_identity, path_identity))
            return error.InvalidOwnerFile;
        if (c.flock(slot, c.LOCK.EX | c.LOCK.NB) != 0)
            return error.AlreadyOwned;
    }

    pub fn adoptInheritedExact(
        slot: c.fd_t,
        path: [:0]const u8,
    ) Error!OwnerLease {
        try validateInheritedExact(slot, path);
        const duped = c.fcntl(slot, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (duped < 0) return error.FcntlFailed;
        errdefer _ = c.close(duped);
        const result = OwnerLease{
            .fd = duped,
            .identity = try identityForFd(duped),
        };
        try result.revalidatePath(path);
        return result;
    }

    pub fn deinit(self: *OwnerLease) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    pub fn descriptor(self: *const OwnerLease) c.fd_t {
        return self.fd;
    }

    /// Durable manifest commit 직전 owner pathname이 inherited lock과 같은
    /// exact object인지 다시 확인한다. replacement/삭제는 rollback 가능한
    /// precommit 오류로 처리한다.
    pub fn revalidatePath(self: *const OwnerLease, path: [:0]const u8) Error!void {
        try validate(self.fd);
        const fd_identity = try identityForFd(self.fd);
        const path_identity = identityForPath(path) catch return error.InvalidOwnerFile;
        if (!sameIdentity(fd_identity, self.identity) or
            !sameIdentity(path_identity, self.identity))
            return error.InvalidOwnerFile;
    }

    /// Lifetime lock을 잡은 동안에만 호출한다. 경로가 다른 inode로 교체됐으면 replacement를 지우지 않는다.
    /// same-UID 악성 프로세스가 마지막 identity check와 unlink 사이를 바꾸는 공격은 제품 위협 경계 밖이다.
    pub fn unlinkOwnedWhileLocked(self: *const OwnerLease, path: [:0]const u8) Error!UnlinkOutcome {
        const current = identityForPath(path) catch |err| return switch (err) {
            error.OpenFailed => .absent,
            else => err,
        };
        if (!sameIdentity(current, self.identity)) return .replaced;
        const unlink_rc = c.unlink(path.ptr);
        if (unlink_rc != 0) {
            if (posix.errno(unlink_rc) == .NOENT) return .absent;
            return error.CleanupFailed;
        }
        const parent = std.fs.path.dirname(path) orelse return error.CleanupFailed;
        var parent_buf: [1024]u8 = undefined;
        const parent_z = std.fmt.bufPrintZ(&parent_buf, "{s}", .{parent}) catch return error.CleanupFailed;
        const dir_fd = c.open(parent_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (dir_fd < 0) return error.CleanupFailed;
        defer _ = c.close(dir_fd);
        if (c.fsync(dir_fd) != 0) return error.CleanupFailed;
        return .removed;
    }

    fn validate(fd: c.fd_t) Error!void {
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !metadataIsValid(stat, c.getuid()))
            return error.InvalidOwnerFile;
    }

    fn identityForFd(fd: c.fd_t) Error!Identity {
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !metadataIsValid(stat, c.getuid()))
            return error.InvalidOwnerFile;
        return .{ .dev = stat.dev, .ino = stat.ino };
    }

    fn identityForPath(path: [:0]const u8) Error!Identity {
        var stat: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
            return error.OpenFailed;
        if (!metadataIsValid(stat, c.getuid()))
            return error.InvalidOwnerFile;
        return .{ .dev = stat.dev, .ino = stat.ino };
    }

    fn sameIdentity(a: Identity, b: Identity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

pub fn metadataIsValid(stat: posix.Stat, expected_uid: posix.uid_t) bool {
    return posix.S.ISREG(stat.mode) and stat.uid == expected_uid and stat.mode & 0o777 == 0o600;
}

test "owner lease remains exclusive through inherited-slot adoption" {
    const exec_fd_set = @import("exec_fd_set.zig");
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/maru-owner-lease-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var original = try OwnerLease.acquire(path);
    try std.testing.expectError(error.AlreadyOwned, OwnerLease.acquire(path));
    var slots: exec_fd_set.PreparedSlots = .{};
    defer slots.rollback();
    var slot: c.fd_t = 220;
    while (slot < 1000 and exec_fd_set.isOpen(slot)) : (slot += 1) {}
    if (slot >= 1000) return error.SkipZigTest;
    try slots.prepare(original.descriptor(), slot);
    var adopted = try OwnerLease.adoptInherited(slot);
    _ = c.close(slot);
    slots.len = 0;
    original.deinit();
    try adopted.revalidatePath(path);
    try std.testing.expectError(error.AlreadyOwned, OwnerLease.acquire(path));
    adopted.deinit();
    var replacement = try OwnerLease.acquire(path);
    replacement.deinit();
}

test "owner lease cleanup preserves a replacement inode" {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-owner-replaced-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var old = try OwnerLease.acquire(path);
    defer old.deinit();
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(path.ptr));
    var replacement = try OwnerLease.acquire(path);
    defer replacement.deinit();

    try std.testing.expectEqual(OwnerLease.UnlinkOutcome.replaced, try old.unlinkOwnedWhileLocked(path));
    try std.testing.expectError(error.AlreadyOwned, OwnerLease.acquire(path));
    try std.testing.expectEqual(OwnerLease.UnlinkOutcome.removed, try replacement.unlinkOwnedWhileLocked(path));
}

test "owner lease metadata rejects a different uid without privileged chown" {
    var stat: posix.Stat = std.mem.zeroes(posix.Stat);
    stat.mode = posix.S.IFREG | 0o600;
    stat.uid = c.getuid();
    try std.testing.expect(metadataIsValid(stat, c.getuid()));
    try std.testing.expect(!metadataIsValid(stat, c.getuid() +% 1));
}
