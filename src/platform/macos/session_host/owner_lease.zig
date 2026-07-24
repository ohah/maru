//! Host lifetime owner lease(U3). Launch-time control lock과 달리 host 전체 수명 및 same-PID exec 동안 유지한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const Error = error{
    OpenFailed,
    InvalidOwnerFile,
    AlreadyOwned,
    LockFailed,
    FcntlFailed,
};

pub const OwnerLease = struct {
    fd: c.fd_t,

    pub fn acquire(path: [:0]const u8) Error!OwnerLease {
        const fd = c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        errdefer _ = c.close(fd);
        try validate(fd);
        const rc = c.flock(fd, c.LOCK.EX | c.LOCK.NB);
        // Darwin에서 EWOULDBLOCK은 EAGAIN과 같은 errno이며 Zig는 AGAIN으로 노출한다.
        if (rc != 0) return if (posix.errno(rc) == .AGAIN) error.AlreadyOwned else error.LockFailed;
        return .{ .fd = fd };
    }

    /// Target image가 inherited non-CLOEXEC owner slot을 CLOEXEC working descriptor로 바꿔 lifetime lock을 이어받는다.
    pub fn adoptInherited(slot: c.fd_t) Error!OwnerLease {
        try validate(slot);
        const duped = c.fcntl(slot, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (duped < 0) return error.FcntlFailed;
        return .{ .fd = duped };
    }

    pub fn deinit(self: *OwnerLease) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    pub fn descriptor(self: *const OwnerLease) c.fd_t {
        return self.fd;
    }

    fn validate(fd: c.fd_t) Error!void {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0) return error.InvalidOwnerFile;
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
            stat.mode & 0o077 != 0) return error.InvalidOwnerFile;
    }
};

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
    try std.testing.expectError(error.AlreadyOwned, OwnerLease.acquire(path));
    adopted.deinit();
    var replacement = try OwnerLease.acquire(path);
    replacement.deinit();
}
