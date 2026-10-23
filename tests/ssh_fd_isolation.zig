// Exercise all seven SSH launch paths against real unmarked parent descriptors.
// A private fake SSH validates the descriptor list and consumes mapped stdin.
const std = @import("std");
const ssh = @import("ssh_upload");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
const script = "for fd in $MARU_SSH_TEST_FDS; do if [ -e /dev/fd/$fd ]; then printf inherited; exit 7; fi; done; if [ -e /dev/fd/0 ]; then /bin/cat >/dev/null; fi; printf closed";
fn bytes(out: []u8) !void {
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("closed", out);
}
fn stream(s: ssh.Stream) !void {
    defer _ = std.c.close(s.out_fd);
    const flags = std.c.fcntl(s.out_fd, std.c.F.GETFL);
    try std.testing.expect(std.c.fcntl(s.out_fd, std.c.F.SETFL, flags & ~@as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) >= 0);
    var buf: [32]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = std.c.read(s.out_fd, buf[used..].ptr, buf.len - used);
        if (n == 0) break;
        if (n < 0) return error.ReadFailed;
        used += @intCast(n);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(s.pid, std.c.waitpid(s.pid, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expectEqualStrings("closed", buf[0..used]);
}
fn allPaths() !void {
    const a = std.testing.allocator;
    try bytes(try ssh.uploadBytes(a, "/unused", "unused", "probe.txt", "payload"));
    var out: []u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), try ssh.runRemoteScript(a, "/unused", "unused", "ignored", &.{}, "payload", &out));
    try bytes(out);
    try std.testing.expectEqual(@as(c_int, 0), try ssh.runArgvCapped(a, &.{ "/bin/sh", "-c", script }, 1024, &out));
    try bytes(out);
    try std.testing.expectEqual(@as(c_int, 0), try ssh.runRemoteCapped(a, "/unused", "unused", "ignored", &.{}, 1024, &out));
    try bytes(out);
    try stream(try ssh.spawnRemoteCommand(a, "/unused", "unused", "ignored"));
    try stream(try ssh.spawnAgentEvents(a, "/unused", "unused", "/unused/maru", "logs", ""));
    try std.testing.expectEqual(@as(c_int, 0), setenv("MARU_SSH_TEST_WATCH", "1", 1));
    defer _ = unsetenv("MARU_SSH_TEST_WATCH");
    const watch = try ssh.spawnRemoteWatch(a, "/unused", "unused", "/repo");
    var old_pipe_action: std.posix.Sigaction = undefined;
    const ignore_pipe: std.posix.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &ignore_pipe, &old_pipe_action);
    defer std.posix.sigaction(.PIPE, &old_pipe_action, null);
    const written = std.c.write(watch.in_fd, "watch", 5);

    // Its stdin writer remains live in the parent; closing it must reach EOF.
    _ = std.c.close(watch.in_fd);
    try stream(.{ .pid = watch.pid, .out_fd = watch.out_fd });
    try std.testing.expectEqual(@as(isize, 5), written);
}
const Kind = enum { pipe, file, high_above_soft_limit, many, closed_stdin, cloexec };
fn probe(kind: Kind) !void {
    var owned: std.ArrayList(c_int) = .empty;
    defer {
        for (owned.items) |fd| _ = std.c.close(fd);
        owned.deinit(std.testing.allocator);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    for (fds) |fd| try owned.append(std.testing.allocator, fd);
    if (kind == .file) try owned.append(std.testing.allocator, std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }));
    if (kind == .high_above_soft_limit) try owned.append(std.testing.allocator, std.c.fcntl(fds[0], std.c.F.DUPFD, @as(c_int, 4096)));
    if (kind == .many) for (0..8) |_| {
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pair));
        for (pair) |fd| try owned.append(std.testing.allocator, fd);
    };
    if (kind == .cloexec) for (owned.items) |fd| {
        try std.testing.expect(std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) >= 0);
    };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    for (owned.items) |fd| {
        try std.testing.expect(fd >= 3);
        const token = try std.fmt.allocPrint(std.testing.allocator, "{d} ", .{fd});
        defer std.testing.allocator.free(token);
        try list.appendSlice(std.testing.allocator, token);
    }
    try list.append(std.testing.allocator, 0);
    try std.testing.expectEqual(@as(c_int, 0), setenv("MARU_SSH_TEST_FDS", @ptrCast(list.items.ptr), 1));
    defer _ = unsetenv("MARU_SSH_TEST_FDS");
    const limit = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, limit) catch {};
    if (kind == .high_above_soft_limit) {
        var low = limit;
        low.cur = 64;
        try std.posix.setrlimit(.NOFILE, low);
    }
    const saved = if (kind == .closed_stdin) std.c.dup(0) else -1;
    defer if (saved >= 0) {
        _ = std.c.dup2(saved, 0);
        _ = std.c.close(saved);
    };
    if (kind == .closed_stdin) _ = std.c.close(0);
    try allPaths();
    for (owned.items) |fd| try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) >= 0);
}
test "SSHF1 foreign pipe ends" {
    try probe(.pipe);
}
test "SSHF2 foreign regular descriptor" {
    try probe(.file);
}
test "SSHF3 foreign descriptor above lowered soft limit" {
    try probe(.high_above_soft_limit);
}
test "SSHF4 many foreign pipe ends" {
    try probe(.many);
}
test "SSHF5 closed host stdin preserves child mapping" {
    try probe(.closed_stdin);
}
test "SSHF6 protected descriptors and normal stdio control" {
    try probe(.cloexec);
}
