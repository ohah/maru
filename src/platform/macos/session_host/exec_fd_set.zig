//! same-PID exec handoff의 FD allowlist primitive(U3).
//!
//! 평상시 fd는 모두 CLOEXEC다. Upgrade 직전에만 각 PTY master를 예약 slot으로 `dup2`하고 그 slot의
//! CLOEXEC를 내린다. exec syscall 실패 시 slot만 닫으면 원 owner fd/reader를 그대로 재개할 수 있다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn getdtablesize() c_int;

pub const Error = error{
    InvalidSlot,
    SourceClosed,
    SourceNotCloexec,
    SlotOccupied,
    DuplicateSlot,
    FcntlFailed,
    DupFailed,
    UnexpectedInheritedFd,
    TooManyOpenFds,
};

pub const max_slots: usize = 256;

pub fn isOpen(fd: c.fd_t) bool {
    const rc = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    return rc >= 0 or posix.errno(rc) != .BADF;
}

pub fn closeOnExec(fd: c.fd_t) Error!bool {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    return flags & c.FD_CLOEXEC != 0;
}

fn setCloseOnExec(fd: c.fd_t, enabled: bool) Error!void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const next = if (enabled) flags | c.FD_CLOEXEC else flags & ~@as(c_int, c.FD_CLOEXEC);
    if (c.fcntl(fd, c.F.SETFD, next) < 0) return error.FcntlFailed;
}

pub const PreparedSlots = struct {
    slots: [max_slots]c.fd_t = undefined,
    len: usize = 0,

    pub fn prepare(self: *PreparedSlots, source: c.fd_t, slot: c.fd_t) Error!void {
        if (slot < 3 or source < 0 or source == slot) return error.InvalidSlot;
        if (self.len == self.slots.len) return error.TooManyOpenFds;
        for (self.slots[0..self.len]) |existing| if (existing == slot) return error.DuplicateSlot;
        if (!isOpen(source)) return error.SourceClosed;
        if (!try closeOnExec(source)) return error.SourceNotCloexec;
        if (isOpen(slot)) return error.SlotOccupied;
        if (c.dup2(source, slot) < 0) return error.DupFailed;
        errdefer _ = c.close(slot);
        try setCloseOnExec(slot, false);
        self.slots[self.len] = slot;
        self.len += 1;
    }

    pub fn rollback(self: *PreparedSlots) void {
        for (self.slots[0..self.len]) |slot| _ = c.close(slot);
        self.len = 0;
    }

    pub fn assertExactNonCloexec(self: *const PreparedSlots, baseline_allowed: []const c.fd_t) Error!void {
        const max_fd = getdtablesize();
        var fd: c.fd_t = 3;
        while (fd < max_fd) : (fd += 1) {
            const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
            if (flags < 0) continue;
            if (flags & c.FD_CLOEXEC != 0) continue;
            var allowed = false;
            for (baseline_allowed) |candidate| if (candidate == fd) {
                allowed = true;
                break;
            };
            if (!allowed) for (self.slots[0..self.len]) |candidate| if (candidate == fd) {
                allowed = true;
                break;
            };
            if (!allowed) return error.UnexpectedInheritedFd;
        }
    }
};

pub fn collectNonCloexec(out: []c.fd_t) Error!usize {
    var count: usize = 0;
    const max_fd = getdtablesize();
    var fd: c.fd_t = 3;
    while (fd < max_fd) : (fd += 1) {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or flags & c.FD_CLOEXEC != 0) continue;
        if (count == out.len) return error.TooManyOpenFds;
        out[count] = fd;
        count += 1;
    }
    return count;
}

fn freeSlot(start: c.fd_t) ?c.fd_t {
    var fd = start;
    while (fd < getdtablesize()) : (fd += 1) if (!isOpen(fd)) return fd;
    return null;
}

test "exec fd set exposes only reserved duplicate and rollback preserves CLOEXEC source" {
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
    }
    try setCloseOnExec(pipe_fds[0], true);
    try setCloseOnExec(pipe_fds[1], true);
    const slot = freeSlot(200) orelse return error.SkipZigTest;

    var baseline: [64]c.fd_t = undefined;
    const baseline_len = try collectNonCloexec(&baseline);
    var prepared: PreparedSlots = .{};
    defer prepared.rollback();
    try prepared.prepare(pipe_fds[0], slot);
    try std.testing.expect(try closeOnExec(pipe_fds[0]));
    try std.testing.expect(!try closeOnExec(slot));
    try prepared.assertExactNonCloexec(baseline[0..baseline_len]);

    prepared.rollback();
    try std.testing.expect(!isOpen(slot));
    try std.testing.expect(isOpen(pipe_fds[0]));
}

test "exec fd set rejects occupied and duplicate reserved slots without changing source" {
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
    }
    try setCloseOnExec(pipe_fds[0], true);
    try setCloseOnExec(pipe_fds[1], true);
    var prepared: PreparedSlots = .{};
    defer prepared.rollback();
    try std.testing.expectError(error.SlotOccupied, prepared.prepare(pipe_fds[0], pipe_fds[1]));
    const slot = freeSlot(200) orelse return error.SkipZigTest;
    try prepared.prepare(pipe_fds[0], slot);
    try std.testing.expectError(error.DuplicateSlot, prepared.prepare(pipe_fds[1], slot));
}
