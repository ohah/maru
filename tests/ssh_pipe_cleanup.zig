// Exhaust real process descriptors to prove failed uploads do not consume the
// terminal host descriptor budget. No SSH server or network is required.
const std = @import("std");
const ssh = @import("ssh_upload");
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn unsetenv([*:0]const u8) c_int;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
fn opened(fd: c_int) bool {
    return std.c.fcntl(fd, std.c.F.GETFD) != -1;
}
fn check(slots: usize, attempts: usize) !void {
    const old_path = if (getenv("PATH")) |value| try std.testing.allocator.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer if (old_path) |value| {
        _ = setenv("PATH", value.ptr, 1);
        std.testing.allocator.free(value);
    } else {
        _ = unsetenv("PATH");
    };
    _ = setenv("PATH", "/nonexistent", 1); // No network even if the resource precondition fails.
    const limit = try std.posix.getrlimit(.NOFILE);
    var low = limit;
    low.cur = 64;
    try std.posix.setrlimit(.NOFILE, low);
    defer std.posix.setrlimit(.NOFILE, limit) catch {};
    var held: [64]c_int = undefined;
    var used: usize = 0;
    while (used < held.len) {
        const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (fd < 0) break;
        held[used] = fd;
        used += 1;
    }
    try std.testing.expect(used >= 3);
    for (0..slots) |_| {
        used -= 1;
        _ = std.c.close(held[used]);
    }
    defer for (held[0..used]) |fd| {
        _ = std.c.close(fd);
    };
    for (0..attempts) |_| {
        var baseline: [64]bool = @splat(false);
        for (&baseline, 0..) |*v, i| v.* = opened(@intCast(i));
        const outcome = ssh.uploadBytes(std.testing.allocator, "/unused-control", "unused-host", "probe.txt", "x");
        var leaked: usize = 0;
        for (baseline, 0..) |v, i| if (!v and opened(@intCast(i))) {
            leaked += 1;
            _ = std.c.close(@intCast(i));
        };
        if (outcome) |bytes| {
            std.testing.allocator.free(bytes);
            return error.UnexpectedSuccess;
        } else |err| {
            try std.testing.expect(err == error.PipeFailed);
        }
        std.debug.print("SSH_PIPE_FAILURE leaked_fds={d}\n", .{leaked});
        try std.testing.expectEqual(@as(usize, 0), leaked);
    }
}

test "SSHP1 no free descriptors" {
    try check(0, 1);
}
test "SSHP2 one free descriptor" {
    try check(1, 1);
}
test "SSHP3 second pipe has no free descriptors" {
    try check(2, 1);
}
test "SSHP4 second pipe has only one free descriptor" {
    try check(3, 1);
}
test "SSHP5 repeated failure preserves available descriptors" {
    try check(3, 16);
}
test "SSHP6 healthy local command output" {
    var out: []u8 = undefined;
    const rc = try ssh.runArgvCapped(std.testing.allocator, &.{ "/bin/sh", "-c", "printf healthy" }, 64, &out);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqualStrings("healthy", out);
}
