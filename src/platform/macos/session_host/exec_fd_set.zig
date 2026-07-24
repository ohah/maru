//! same-PID exec handoff의 FD allowlist primitive(U3).
//!
//! 평상시 fd는 모두 CLOEXEC다. Upgrade 직전에만 각 PTY master를 예약 slot으로 `dup2`하고 그 slot의
//! CLOEXEC를 내린다. exec syscall 실패 시 slot만 닫으면 원 owner fd/reader를 그대로 재개할 수 있다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const limits = @import("upgrade_limits.zig");

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

/// 256 PTY masters + primary/backup handoff + lifetime owner lease.
pub const max_slots: usize = limits.max_runtime_count + 3;

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
        for (self.slots[0..self.len], 0..) |slot, index| {
            if (!isOpen(slot)) return error.SourceClosed;
            if (try closeOnExec(slot)) return error.SourceNotCloexec;
            for (self.slots[0..index]) |prior| if (prior == slot) return error.DuplicateSlot;
        }
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

/// Handoff capture 전에 전체 inherited slot을 CLOEXEC placeholder로 점유해, 이후 store/preflight가 여는 fd와
/// logical slot이 충돌하지 않게 한다. replace는 예약된 exact slot만 실제 resource로 바꾸며 rollback은 placeholder와
/// 교체된 slot 모두를 닫는다.
pub const SlotReservation = struct {
    slots: [max_slots]c.fd_t = undefined,
    replaced: [max_slots]bool = .{false} ** max_slots,
    len: usize = 0,
    sentinel_fd: c.fd_t = -1,

    pub fn reserve(self: *SlotReservation, requested: []const c.fd_t) Error!void {
        if (self.len != 0 or self.sentinel_fd >= 0) return error.SlotOccupied;
        if (requested.len > max_slots) return error.TooManyOpenFds;
        var highest_slot: c.fd_t = 3;
        for (requested, 0..) |slot, index| {
            if (slot < 3) return error.InvalidSlot;
            for (requested[0..index]) |prior| if (prior == slot) return error.DuplicateSlot;
            if (isOpen(slot)) return error.SlotOccupied;
            highest_slot = @max(highest_slot, slot);
        }
        var pipe_fds: [2]c.fd_t = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.DupFailed;
        self.sentinel_fd = c.fcntl(pipe_fds[0], c.F.DUPFD_CLOEXEC, highest_slot + 1);
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        if (self.sentinel_fd < 0) return error.DupFailed;
        errdefer self.rollback();
        for (requested) |slot| {
            if (c.dup2(self.sentinel_fd, slot) < 0) return error.DupFailed;
            self.slots[self.len] = slot;
            self.len += 1;
            try setCloseOnExec(slot, true);
        }
    }

    pub fn replace(self: *SlotReservation, source: c.fd_t, slot: c.fd_t) Error!void {
        const index = self.indexOf(slot) orelse return error.InvalidSlot;
        if (source == slot) return error.InvalidSlot;
        if (self.replaced[index]) return error.DuplicateSlot;
        if (!isOpen(source)) return error.SourceClosed;
        if (!try closeOnExec(source)) return error.SourceNotCloexec;
        if (!sameFile(self.sentinel_fd, slot) or !try closeOnExec(slot)) return error.SlotOccupied;
        if (c.dup2(source, slot) < 0) return error.DupFailed;
        errdefer _ = c.close(slot);
        try setCloseOnExec(slot, false);
        self.replaced[index] = true;
    }

    pub fn allReplaced(self: *const SlotReservation) bool {
        for (self.replaced[0..self.len]) |replaced| if (!replaced) return false;
        return true;
    }

    pub fn assertExactNonCloexec(
        self: *const SlotReservation,
        baseline_allowed: []const c.fd_t,
    ) Error!void {
        var prepared: PreparedSlots = .{};
        for (self.slots[0..self.len], self.replaced[0..self.len]) |slot, replaced| {
            if (!replaced) continue;
            prepared.slots[prepared.len] = slot;
            prepared.len += 1;
        }
        return prepared.assertExactNonCloexec(baseline_allowed);
    }

    pub fn rollback(self: *SlotReservation) void {
        for (self.slots[0..self.len]) |slot| _ = c.close(slot);
        if (self.sentinel_fd >= 0) _ = c.close(self.sentinel_fd);
        self.* = .{};
    }

    fn indexOf(self: *const SlotReservation, slot: c.fd_t) ?usize {
        for (self.slots[0..self.len], 0..) |candidate, index|
            if (candidate == slot) return index;
        return null;
    }
};

fn sameFile(a: c.fd_t, b: c.fd_t) bool {
    var a_stat: posix.Stat = undefined;
    var b_stat: posix.Stat = undefined;
    return c.fstat(a, &a_stat) == 0 and c.fstat(b, &b_stat) == 0 and
        a_stat.dev == b_stat.dev and a_stat.ino == b_stat.ino;
}

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

/// Target entrypoint 직후에는 CLOEXEC fd가 이미 kernel에서 닫혔으므로 열린 fd 3+ 전체가 inherited allowlist와
/// 정확히 같아야 한다.
pub fn assertExactOpen(allowed: []const c.fd_t) Error!void {
    const max_fd = getdtablesize();
    var seen: [max_slots]bool = .{false} ** max_slots;
    if (allowed.len > seen.len) return error.TooManyOpenFds;
    var fd: c.fd_t = 3;
    while (fd < max_fd) : (fd += 1) {
        if (!isOpen(fd)) continue;
        var match: ?usize = null;
        for (allowed, 0..) |candidate, index| if (candidate == fd) {
            match = index;
            break;
        };
        const index = match orelse return error.UnexpectedInheritedFd;
        if (seen[index]) return error.DuplicateSlot;
        seen[index] = true;
    }
    for (seen[0..allowed.len]) |present| if (!present) return error.SourceClosed;
}

fn freeSlot(start: c.fd_t) ?c.fd_t {
    var fd = start;
    while (fd < getdtablesize()) : (fd += 1) if (!isOpen(fd)) return fd;
    return null;
}

fn freeRange(start: c.fd_t, count: usize) ?c.fd_t {
    const max_fd = getdtablesize();
    var first = start;
    while (@as(i64, first) + @as(i64, @intCast(count)) <= max_fd) : (first += 1) {
        var offset: usize = 0;
        while (offset < count and !isOpen(first + @as(c.fd_t, @intCast(offset)))) : (offset += 1) {}
        if (offset == count) return first;
        first += @intCast(offset);
    }
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

test "exec fd set capacity includes maximum runtime graph and fixed upgrade roles" {
    try std.testing.expectEqual(limits.max_runtime_count + 3, max_slots);
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
    }
    try setCloseOnExec(pipe_fds[0], true);
    var prepared: PreparedSlots = .{};
    @memset(&prepared.slots, -1);
    prepared.len = max_slots - 1;
    const slot = freeSlot(300) orelse return error.SkipZigTest;
    try prepared.prepare(pipe_fds[0], slot);
    try std.testing.expectEqual(max_slots, prepared.len);
    try std.testing.expectError(error.TooManyOpenFds, prepared.prepare(pipe_fds[0], slot + 1));
    _ = c.close(slot);
    prepared.len = 0;
}

test "slot reservation pins the full namespace before exact replacement and rolls back all slots" {
    var sources: [2][2]c.fd_t = undefined;
    for (&sources) |*pair| {
        if (c.pipe(pair) != 0) return error.SkipZigTest;
        try setCloseOnExec(pair[0], true);
        try setCloseOnExec(pair[1], true);
    }
    defer for (&sources) |*pair| {
        _ = c.close(pair[0]);
        _ = c.close(pair[1]);
    };
    const first = freeSlot(300) orelse return error.SkipZigTest;
    const second = freeSlot(first + 1) orelse return error.SkipZigTest;
    const requested = [_]c.fd_t{ first, second };
    var reservation: SlotReservation = .{};
    defer reservation.rollback();
    try reservation.reserve(&requested);
    try std.testing.expect(try closeOnExec(first));
    try std.testing.expect(try closeOnExec(second));
    try std.testing.expectError(error.SlotOccupied, reservation.reserve(&requested));
    try reservation.replace(sources[0][0], first);
    try std.testing.expect(!try closeOnExec(first));
    try std.testing.expect(try closeOnExec(second));
    try std.testing.expectError(error.DuplicateSlot, reservation.replace(sources[1][0], first));
    try reservation.replace(sources[1][0], second);
    try std.testing.expect(reservation.allReplaced());
    _ = c.close(second);
    try std.testing.expectError(error.SourceClosed, reservation.assertExactNonCloexec(&.{}));

    reservation.rollback();
    try std.testing.expect(!isOpen(first));
    try std.testing.expect(!isOpen(second));
    try std.testing.expect(isOpen(sources[0][0]));
    try std.testing.expect(isOpen(sources[1][0]));
}

test "slot reservation handles the product maximum of 256 PTYs plus state and owner roles" {
    var source_pipe: [2]c.fd_t = undefined;
    if (c.pipe(&source_pipe) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(source_pipe[0]);
        _ = c.close(source_pipe[1]);
    }
    try setCloseOnExec(source_pipe[0], true);
    try setCloseOnExec(source_pipe[1], true);
    const first = freeRange(300, max_slots) orelse return error.SkipZigTest;
    var requested: [max_slots]c.fd_t = undefined;
    for (&requested, 0..) |*slot, index| slot.* = first + @as(c.fd_t, @intCast(index));
    var baseline: [64]c.fd_t = undefined;
    const baseline_len = try collectNonCloexec(&baseline);
    var reservation: SlotReservation = .{};
    defer reservation.rollback();
    try reservation.reserve(&requested);
    for (requested) |slot| try reservation.replace(source_pipe[0], slot);
    try std.testing.expectEqual(max_slots, reservation.len);
    try std.testing.expect(reservation.allReplaced());
    try reservation.assertExactNonCloexec(baseline[0..baseline_len]);
}
