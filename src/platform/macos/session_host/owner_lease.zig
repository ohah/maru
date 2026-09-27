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
///
/// **`free`는 「파일이 없다」도 포함한다.** 락은 fd가 쥐는 것이지 pathname이 쥐는 것이 아니므로,
/// 살아 있는 host의 `owner.lock`이 unlink되면 그 host가 락을 계속 쥔 채로도 여기서는 `free`로 보인다
/// (2026-09-27 실측: pid 2954가 fd 3으로 락을 쥔 채 경로만 사라졌다). 그래서 host는 자기 이름을
/// 주기적으로 감사하고 사라졌으면 다시 세운다(`OwnerLease.healOwnedPath`) — 관측 쪽 의미를 넓히는
/// 대신 **불변식 자체를 복구한다**. 넓히는 쪽은 안 된다: 승계 후계자가 exec 때 fd를 경로와 대조하므로
/// (`validateInheritedExact`) 이름 없는 host를 후보로 넘기면 arm 단계에서 죽는다.
pub const Observation = enum {
    free,
    held,
    unknown,
};

/// 내 lock의 **이름**이 아직 내 fd의 inode를 가리키는가. 읽기 전용(2 syscall)이라 제품 동작을 바꾸지 않는다.
///
/// `absent`와 `replaced`를 가르는 것이 요점이다 — 전자는 누가 내 이름을 **지운** 것이고 후자는 **덮어쓴**
/// 것이라, 행위자 추론이 갈린다. `revalidatePath`는 둘을 같은 오류로 접으므로 진단에 못 쓴다.
pub const PathAudit = enum { intact, absent, replaced, unreadable };

/// 감사 주기와 래치. **순수**라 syscall 없이 판정자로 잠근다.
pub const PathWatch = struct {
    last_ms: ?u64 = null,
    last_state: PathAudit = .intact,

    /// 지금 감사할 차례인가. 「아직 한 번도 안 봄」을 `null`로 둔다 — 단조 시계는 부팅 후 경과라
    /// `0`을 sentinel로 쓰면 첫 감사가 한 주기 밀린다(`daemon.shouldTouchRuntimeArtifacts`와 같은 규율).
    pub fn due(self: *PathWatch, now_ms: u64, interval_ms: u64) bool {
        const last = self.last_ms orelse {
            self.last_ms = now_ms;
            return true;
        };
        if (now_ms -| last < interval_ms) return false;
        self.last_ms = now_ms;
        return true;
    }

    /// 이 관측을 남길 것인가. **상태가 바뀔 때만** 참이다 — 정상 host는 평생 0줄이고, 어긋난 host도
    /// 분당 한 줄로 불어나지 않는다. 복구(`.intact`로 돌아옴)도 한 줄 남는다: 「언제 풀렸나」가 없으면
    /// 사후에 창을 못 좁힌다.
    pub fn report(self: *PathWatch, state: PathAudit) bool {
        if (state == self.last_state) return false;
        self.last_state = state;
        return true;
    }
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

    /// 내 이름이 아직 내 것인가. `errno`를 직접 본다 — `identityForPath`는 NOENT와 권한 실패를 같은
    /// `OpenFailed`로 접는데, 여기서는 그 둘이 **다른 결론**(지워졌다 / 우리가 못 봤다)이다.
    pub fn auditOwnedPath(self: *const OwnerLease, path: [:0]const u8) PathAudit {
        const fd_identity = identityForFd(self.fd) catch return .unreadable;
        if (!sameIdentity(fd_identity, self.identity)) return .unreadable;
        var stat: posix.Stat = undefined;
        const rc = c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW);
        if (rc != 0) return if (posix.errno(rc) == .NOENT) .absent else .unreadable;
        // 우리 모양이 아닌 leaf가 그 이름에 앉아 있으면 그것은 **남의 것**이다. 고치거나 지우지 않는다.
        if (!metadataIsValid(stat, c.getuid())) return .replaced;
        return if (stat.dev == self.identity.dev and stat.ino == self.identity.ino)
            .intact
        else
            .replaced;
    }

    pub const HealOutcome = enum { not_needed, healed, contended, failed };

    /// 이름을 잃은 lock을 **같은 경로에 다시 세운다.**
    ///
    /// 락은 fd가 쥐므로 이름이 사라져도 배타성은 그대로다. 그런데도 이름이 필요한 이유는 **승계**다 —
    /// 후계자가 exec 때 물려받은 fd를 경로와 대조하는데(`validateInheritedExact`), 그 대조는
    /// `armRestoreInvocation` 안에서 일어나고 그 시점에는 **롤백이 아직 준비되지 않았다**. 즉 이름이
    /// 없으면 업그레이드가 세션째 프로세스를 끌고 죽는다. 그래서 관측 쪽 판정을 넓히는 대신 여기서
    /// 불변식을 되돌린다.
    ///
    /// **훔치지 않는다.** `.replaced`(남이 그 이름에 앉음)는 손대지 않고, `acquire`가 경합하면
    /// `.contended`로 물러난다. 그리고 **새 락을 잡은 뒤에** 옛 fd를 놓는다 — 순서가 뒤집히면 실패했을 때
    /// 쥐고 있던 락까지 잃는다.
    pub fn healOwnedPath(self: *OwnerLease, path: [:0]const u8) HealOutcome {
        if (self.auditOwnedPath(path) != .absent) return .not_needed;
        const replacement = acquire(path) catch |err| return switch (err) {
            error.AlreadyOwned => .contended,
            else => .failed,
        };
        const stale_fd = self.fd;
        self.fd = replacement.fd;
        self.identity = replacement.identity;
        if (stale_fd >= 0) _ = c.close(stale_fd);
        return .healed;
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

// ── owner.lock 이름 감사·치유 ────────────────────────────────────────────────
//
// 터미널에서 왜 중요한가: host는 사용자의 셸을 들고 산다. 그 host가 자기 `owner.lock` **이름**을 잃으면
// 락은 그대로 쥐고 있어도 바깥에서는 「주인 없음」으로 보여, 앱 업데이트 때 승계 대상에서 빠진다. 그러면
// 그 host는 옛 빌드에 영구히 고정되고(그 세션에는 새 고침이 안 먹는다) 설치마다 host가 하나씩 는다.

test "owner lock 감사: 이름이 사라진 것과 다른 inode 로 바뀐 것을 가른다" {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/maru-owner-audit-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var lease = try OwnerLease.acquire(path);
    defer lease.deinit();
    try std.testing.expectEqual(PathAudit.intact, lease.auditOwnedPath(path));

    // 지워졌다 — 락은 fd 가 그대로 쥐고 있다.
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(path.ptr));
    try std.testing.expectEqual(PathAudit.absent, lease.auditOwnedPath(path));

    // 같은 이름에 **다른 inode** 가 앉았다. 지워진 것과 같은 값으로 접으면 행위자 추론이 무너진다.
    var other = try OwnerLease.acquire(path);
    defer other.deinit();
    try std.testing.expectEqual(PathAudit.replaced, lease.auditOwnedPath(path));
}

test "owner lock 치유: 이름을 잃어도 같은 경로에 다시 서고, 그 뒤 observe 가 다시 held 라고 답한다" {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/maru-owner-heal-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var lease = try OwnerLease.acquire(path);
    defer lease.deinit();
    try std.testing.expectEqual(Observation.held, observe(path));

    // 2026-09-27 에 실제 기계에서 본 모양: 경로는 없는데 프로세스는 fd 로 락을 쥐고 있다.
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(path.ptr));
    try std.testing.expectEqual(Observation.free, observe(path));

    try std.testing.expectEqual(OwnerLease.HealOutcome.healed, lease.healOwnedPath(path));

    // **이것이 이 고침의 전부다** — 바깥에서 다시 「주인 있음」으로 보인다.
    try std.testing.expectEqual(Observation.held, observe(path));
    try std.testing.expectEqual(PathAudit.intact, lease.auditOwnedPath(path));
    // 그리고 후계자가 exec 때 하는 그 대조가 다시 통과한다 — 승계가 되살아났다는 뜻이다.
    try lease.revalidatePath(path);
    // 이름이 멀쩡하면 두 번째 호출은 아무것도 하지 않는다.
    try std.testing.expectEqual(OwnerLease.HealOutcome.not_needed, lease.healOwnedPath(path));
}

test "owner lock 치유: 남이 쥔 이름은 빼앗지 않는다" {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/maru-owner-steal-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var lease = try OwnerLease.acquire(path);
    defer lease.deinit();
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(path.ptr));

    // 그 사이 남이 같은 이름을 세워 쥐었다.
    var squatter = try OwnerLease.acquire(path);
    defer squatter.deinit();

    // 이름은 남의 것이다 — 감사는 `replaced` 이고, 치유는 손대지 않는다.
    try std.testing.expectEqual(PathAudit.replaced, lease.auditOwnedPath(path));
    try std.testing.expectEqual(OwnerLease.HealOutcome.not_needed, lease.healOwnedPath(path));
    // 남의 락이 살아 있어야 한다. 빼앗았다면 여기서 `held` 가 아니게 된다.
    try std.testing.expectEqual(Observation.held, observe(path));
    try squatter.revalidatePath(path);
}

test "owner lock 치유: 되세우기에 실패해도 쥐고 있던 락을 놓지 않는다" {
    var dir_buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-owner-keep-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.chmod(dir.ptr, 0o700);
    var stale_buf: [320]u8 = undefined;
    const stale = std.fmt.bufPrintZ(&stale_buf, "{s}/owner.lock", .{dir}) catch return error.SkipZigTest;
    _ = c.unlink(stale.ptr);
    _ = c.rmdir(dir.ptr);
    if (c.mkdir(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    defer {
        _ = c.chmod(dir.ptr, 0o700);
        _ = c.unlink(stale.ptr);
        _ = c.rmdir(dir.ptr);
    }

    var lease = try OwnerLease.acquire(stale);
    defer lease.deinit();
    const before = lease.identity;
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(stale.ptr));
    try std.testing.expectEqual(PathAudit.absent, lease.auditOwnedPath(stale));

    // 이름은 비었는데 **다시 세울 수가 없다**(디렉터리에 쓰기 권한이 없다). `.contended` 도 같은 갈래이지만
    // 그쪽은 감사와 획득 사이의 경주라 결정적으로 못 만든다 — 실패 갈래의 보장은 여기서 잰다.
    if (c.chmod(dir.ptr, 0o500) != 0) return error.SkipZigTest;
    try std.testing.expectEqual(OwnerLease.HealOutcome.failed, lease.healOwnedPath(stale));

    // **놓지 않았다.** 새 락을 잡은 뒤에 옛 fd 를 놓는 순서라야 이것이 참이다 — 순서가 뒤집히면
    // 실패한 그 시점에 이미 락을 잃어 이 단언이 깨진다.
    var stat: posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(lease.fd, &stat));
    try std.testing.expectEqual(before.dev, stat.dev);
    try std.testing.expectEqual(before.ino, stat.ino);

    // 권한이 돌아오면 그때는 되세운다 — 실패가 영구 포기가 아니라는 것.
    if (c.chmod(dir.ptr, 0o700) != 0) return error.SkipZigTest;
    try std.testing.expectEqual(OwnerLease.HealOutcome.healed, lease.healOwnedPath(stale));
    try std.testing.expectEqual(Observation.held, observe(stale));
}

test "owner.lock 감시: 벽시계 주기로만 깨어나고, 어긋남은 상태가 바뀔 때만 남긴다" {
    const interval: u64 = 60 * 1000;
    var watch: PathWatch = .{};

    // 첫 호출은 언제나 본다 — 「아직 안 봄」을 0 으로 두면 첫 감사가 한 주기 밀린다.
    try std.testing.expect(watch.due(5_000, interval));
    try std.testing.expect(!watch.due(5_000 + interval - 1, interval));
    try std.testing.expect(watch.due(5_000 + interval, interval));

    // 래치: 같은 사실을 되풀이해 남기지 않는다. 복구는 남긴다.
    try std.testing.expect(watch.report(.absent));
    try std.testing.expect(!watch.report(.absent));
    try std.testing.expect(watch.report(.intact));
    try std.testing.expect(watch.report(.absent));
}
