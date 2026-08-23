//! P5c3c-3a1 dedicated nonblocking TTY output transaction.
//!
//! The inherited stdout open-file-description belongs to the invoking shell. Changing its status
//! flags through `dup` or `F_SETFL` would therefore leak `O_NONBLOCK` back into that shell. This
//! leaf resolves the slave path, opens a distinct description, and revalidates identity and the
//! inherited flags before publishing the final-address owner.

const std = @import("std");
const c = std.c;
const posix = std.posix;

extern "c" fn ttyname_r(fd: c.fd_t, buffer: [*]u8, len: usize) c_int;
extern "c" fn openpty(
    amaster: *c.fd_t,
    aslave: *c.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;

pub const Error = error{
    DestinationNotEmpty,
    NotInitialized,
    Moved,
    PathUnavailable,
    FlagReadFailed,
    StatFailed,
    OpenFailed,
    OutputFlagMismatch,
    NotCharacterDevice,
    IdentityChanged,
};

const StatView = struct {
    device: c.dev_t,
    character: bool,
};

const Ops = struct {
    context: *anyopaque,
    tty_path: *const fn (context: *anyopaque, fd: c.fd_t, buffer: []u8) bool,
    flags: *const fn (context: *anyopaque, fd: c.fd_t) ?c_int,
    descriptor_flags: *const fn (context: *anyopaque, fd: c.fd_t) ?c_int,
    stat: *const fn (context: *anyopaque, fd: c.fd_t) ?StatView,
    open_output: *const fn (context: *anyopaque, path: [*:0]const u8) c.fd_t,
    close: *const fn (context: *anyopaque, fd: c.fd_t) void,
};

pub const DedicatedOutput = struct {
    saved_self_addr: usize = 0,
    fd: c.fd_t = -1,
    device: c.dev_t = 0,
    ops: Ops = undefined,

    pub fn initInPlace(self: *DedicatedOutput, stdout_fd: c.fd_t) Error!void {
        return self.initWithOps(stdout_fd, posix_ops);
    }

    pub fn pollFd(self: *const DedicatedOutput) Error!c.fd_t {
        try self.requireFinalAddress();
        if (self.fd < 0) return error.NotInitialized;
        return self.fd;
    }

    pub fn ttyDevice(self: *const DedicatedOutput) Error!c.dev_t {
        try self.requireFinalAddress();
        if (self.fd < 0) return error.NotInitialized;
        return self.device;
    }

    pub fn deinit(self: *DedicatedOutput) void {
        if (self.saved_self_addr == 0) return;
        std.debug.assert(self.saved_self_addr == @intFromPtr(self));
        if (self.fd >= 0) self.ops.close(self.ops.context, self.fd);
        self.* = .{};
    }

    fn initWithOps(self: *DedicatedOutput, stdout_fd: c.fd_t, ops: Ops) Error!void {
        if (self.saved_self_addr != 0 or self.fd != -1) return error.DestinationNotEmpty;
        self.saved_self_addr = @intFromPtr(self);
        self.ops = ops;
        errdefer self.* = .{};

        const inherited_flags = ops.flags(ops.context, stdout_fd) orelse
            return error.FlagReadFailed;
        var path_buffer: [posix.PATH_MAX]u8 = undefined;
        if (!ops.tty_path(ops.context, stdout_fd, &path_buffer))
            return error.PathUnavailable;
        const before = ops.stat(ops.context, stdout_fd) orelse return error.StatFailed;
        if (!before.character) return error.NotCharacterDevice;

        const output_fd = ops.open_output(ops.context, @ptrCast(&path_buffer));
        if (output_fd < 0) return error.OpenFailed;
        errdefer ops.close(ops.context, output_fd);

        const output = ops.stat(ops.context, output_fd) orelse return error.StatFailed;
        if (!output.character) return error.NotCharacterDevice;
        const output_flags = ops.flags(ops.context, output_fd) orelse
            return error.FlagReadFailed;
        const nonblocking: c_int = @bitCast(c.O{ .NONBLOCK = true });
        const access_mode: c_int = @bitCast(c.O{ .ACCMODE = .WRONLY });
        const read_write: c_int = @bitCast(c.O{ .ACCMODE = .RDWR });
        const access_mask = access_mode | read_write;
        if (output_flags & access_mask != access_mode or output_flags & nonblocking == 0)
            return error.OutputFlagMismatch;
        const output_descriptor_flags = ops.descriptor_flags(ops.context, output_fd) orelse
            return error.FlagReadFailed;
        if (output_descriptor_flags & c.FD_CLOEXEC == 0) return error.OutputFlagMismatch;
        const after = ops.stat(ops.context, stdout_fd) orelse return error.StatFailed;
        if (!after.character) return error.NotCharacterDevice;
        if (before.device != output.device or before.device != after.device)
            return error.IdentityChanged;
        const final_inherited_flags = ops.flags(ops.context, stdout_fd) orelse
            return error.FlagReadFailed;
        if (final_inherited_flags != inherited_flags) return error.IdentityChanged;

        self.fd = output_fd;
        self.device = before.device;
    }

    fn requireFinalAddress(self: *const DedicatedOutput) Error!void {
        if (self.saved_self_addr == 0) return error.NotInitialized;
        if (self.saved_self_addr != @intFromPtr(self)) return error.Moved;
    }
};

fn posixTtyPath(_: *anyopaque, fd: c.fd_t, buffer: []u8) bool {
    return ttyname_r(fd, buffer.ptr, buffer.len) == 0;
}

fn posixFlags(_: *anyopaque, fd: c.fd_t) ?c_int {
    const result = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    return if (result < 0) null else result;
}

fn posixDescriptorFlags(_: *anyopaque, fd: c.fd_t) ?c_int {
    const result = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    return if (result < 0) null else result;
}

fn posixStat(_: *anyopaque, fd: c.fd_t) ?StatView {
    var value: c.Stat = undefined;
    if (c.fstat(fd, &value) != 0) return null;
    return .{
        .device = value.rdev,
        .character = value.mode & posix.S.IFMT == posix.S.IFCHR,
    };
}

fn posixOpenOutput(_: *anyopaque, path: [*:0]const u8) c.fd_t {
    return c.open(path, .{
        .ACCMODE = .WRONLY,
        .NOCTTY = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0));
}

fn posixClose(_: *anyopaque, fd: c.fd_t) void {
    _ = c.close(fd);
}

var posix_context: u8 = 0;
const posix_ops: Ops = .{
    .context = &posix_context,
    .tty_path = posixTtyPath,
    .flags = posixFlags,
    .descriptor_flags = posixDescriptorFlags,
    .stat = posixStat,
    .open_output = posixOpenOutput,
    .close = posixClose,
};

const Failure = enum {
    none,
    first_flags,
    path,
    first_stat,
    open,
    output_stat,
    output_status_flags,
    output_descriptor_flags,
    output_blocking,
    output_read_only,
    output_no_cloexec,
    final_stat,
    final_flags,
    output_not_character,
    identity_drift,
    flag_drift,
};

const Fake = struct {
    failure: Failure,
    stat_calls: u8 = 0,
    flag_calls: u8 = 0,
    descriptor_flag_calls: u8 = 0,
    open_calls: u8 = 0,
    close_calls: u8 = 0,
    closed_fd: c.fd_t = -1,

    fn ops(self: *Fake) Ops {
        return .{
            .context = self,
            .tty_path = fakeTtyPath,
            .flags = fakeFlags,
            .descriptor_flags = fakeDescriptorFlags,
            .stat = fakeStat,
            .open_output = fakeOpen,
            .close = fakeClose,
        };
    }
};

fn asFake(context: *anyopaque) *Fake {
    return @ptrCast(@alignCast(context));
}

fn fakeTtyPath(context: *anyopaque, _: c.fd_t, buffer: []u8) bool {
    const fake = asFake(context);
    if (fake.failure == .path) return false;
    const path = "/dev/ttys001\x00";
    @memcpy(buffer[0..path.len], path);
    return true;
}

fn fakeFlags(context: *anyopaque, fd: c.fd_t) ?c_int {
    const fake = asFake(context);
    fake.flag_calls += 1;
    if ((fake.failure == .first_flags and fake.flag_calls == 1) or
        (fake.failure == .output_status_flags and fd == 99) or
        (fake.failure == .final_flags and fd != 99 and fake.flag_calls == 3)) return null;
    if (fd == 99) {
        if (fake.failure == .output_blocking)
            return @bitCast(c.O{ .ACCMODE = .WRONLY });
        if (fake.failure == .output_read_only)
            return @bitCast(c.O{ .ACCMODE = .RDONLY, .NONBLOCK = true });
        return @bitCast(c.O{ .ACCMODE = .WRONLY, .NONBLOCK = true });
    }
    return if (fake.failure == .flag_drift and fake.flag_calls == 3) 8 else 7;
}

fn fakeDescriptorFlags(context: *anyopaque, _: c.fd_t) ?c_int {
    const fake = asFake(context);
    fake.descriptor_flag_calls += 1;
    if (fake.failure == .output_descriptor_flags) return null;
    return if (fake.failure == .output_no_cloexec) 0 else c.FD_CLOEXEC;
}

fn fakeStat(context: *anyopaque, _: c.fd_t) ?StatView {
    const fake = asFake(context);
    fake.stat_calls += 1;
    if ((fake.failure == .first_stat and fake.stat_calls == 1) or
        (fake.failure == .output_stat and fake.stat_calls == 2) or
        (fake.failure == .final_stat and fake.stat_calls == 3)) return null;
    if (fake.failure == .output_not_character and fake.stat_calls == 2)
        return .{ .device = 42, .character = false };
    if (fake.failure == .identity_drift and fake.stat_calls == 3)
        return .{ .device = 43, .character = true };
    return .{ .device = 42, .character = true };
}

fn fakeOpen(context: *anyopaque, _: [*:0]const u8) c.fd_t {
    const fake = asFake(context);
    fake.open_calls += 1;
    return if (fake.failure == .open) -1 else 99;
}

fn fakeClose(context: *anyopaque, fd: c.fd_t) void {
    const fake = asFake(context);
    fake.close_calls += 1;
    fake.closed_fd = fd;
}

test "p5c3c-3a1 dedicated TTY output failure matrix leaves no published owner" {
    const cases = [_]struct { failure: Failure, expected: Error, closes: u8 }{
        .{ .failure = .first_flags, .expected = error.FlagReadFailed, .closes = 0 },
        .{ .failure = .path, .expected = error.PathUnavailable, .closes = 0 },
        .{ .failure = .first_stat, .expected = error.StatFailed, .closes = 0 },
        .{ .failure = .open, .expected = error.OpenFailed, .closes = 0 },
        .{ .failure = .output_stat, .expected = error.StatFailed, .closes = 1 },
        .{ .failure = .output_status_flags, .expected = error.FlagReadFailed, .closes = 1 },
        .{ .failure = .output_descriptor_flags, .expected = error.FlagReadFailed, .closes = 1 },
        .{ .failure = .output_blocking, .expected = error.OutputFlagMismatch, .closes = 1 },
        .{ .failure = .output_read_only, .expected = error.OutputFlagMismatch, .closes = 1 },
        .{ .failure = .output_no_cloexec, .expected = error.OutputFlagMismatch, .closes = 1 },
        .{ .failure = .final_stat, .expected = error.StatFailed, .closes = 1 },
        .{ .failure = .final_flags, .expected = error.FlagReadFailed, .closes = 1 },
        .{ .failure = .output_not_character, .expected = error.NotCharacterDevice, .closes = 1 },
        .{ .failure = .identity_drift, .expected = error.IdentityChanged, .closes = 1 },
        .{ .failure = .flag_drift, .expected = error.IdentityChanged, .closes = 1 },
    };
    for (cases) |case| {
        var fake = Fake{ .failure = case.failure };
        var output = DedicatedOutput{};
        try std.testing.expectError(case.expected, output.initWithOps(1, fake.ops()));
        try std.testing.expectEqual(@as(c.fd_t, -1), output.fd);
        try std.testing.expectEqual(case.closes, fake.close_calls);
        if (case.closes == 1) try std.testing.expectEqual(@as(c.fd_t, 99), fake.closed_fd);
    }
}

test "p5c3c-3a1 dedicated TTY output publishes only at its final address and closes exactly once" {
    var fake = Fake{ .failure = .none };
    var output = DedicatedOutput{};
    try output.initWithOps(1, fake.ops());
    try std.testing.expectEqual(@as(c.fd_t, 99), try output.pollFd());
    try std.testing.expectEqual(@as(c.dev_t, 42), try output.ttyDevice());
    var moved = output;
    try std.testing.expectError(error.Moved, moved.pollFd());
    output.deinit();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    output.deinit();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
}

test "p5c3c-3a1 real openpty uses a separate nonblocking close-on-exec output description" {
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const inherited_before = c.fcntl(slave, c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(inherited_before >= 0);

    var output = DedicatedOutput{};
    try output.initInPlace(slave);
    const output_fd = try output.pollFd();
    try std.testing.expect(output_fd != slave);
    const output_flags = c.fcntl(output_fd, c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(output_flags >= 0);
    try std.testing.expect(output_flags & @as(c_int, @bitCast(c.O{ .NONBLOCK = true })) != 0);
    const descriptor_flags = c.fcntl(output_fd, c.F.GETFD, @as(c_int, 0));
    try std.testing.expect(descriptor_flags >= 0);
    try std.testing.expect(descriptor_flags & c.FD_CLOEXEC != 0);
    try std.testing.expectEqual(inherited_before, c.fcntl(slave, c.F.GETFL, @as(c_int, 0)));

    output.deinit();
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(output_fd, c.F.GETFL, @as(c_int, 0)));
    try std.testing.expectEqual(inherited_before, c.fcntl(slave, c.F.GETFL, @as(c_int, 0)));
    try std.testing.expectEqual(@as(isize, 1), c.write(slave, "x", 1));
}
