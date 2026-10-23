//! Real process regressions: every case executes the product search runner.
//! Korean literals below are argv/expected-output fixtures, never product UI.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("app_session/editor/search/process.zig");
const c = std.c;
const a = std.testing.allocator;
const Sink = struct {
    bytes: std.ArrayList(u8) = .empty,
    control: *process.Control,
    cancel: bool = false,
    reject: bool = false,
    fn accept(self: *@This(), value: []const u8) !void {
        if (self.reject) return error.CallbackRejected;
        try self.bytes.appendSlice(a, value);
        try self.bytes.append(a, '\n');
        if (self.cancel) self.control.cancelled.store(true, .release);
    }
};
fn fdCount() usize {
    var count: usize = 0;
    for (0..512) |fd| if (c.fcntl(@as(c_int, @intCast(fd)), c.F.GETFD) != -1) {
        count += 1;
    };
    return count;
}
fn scenario(comptime n: usize) !void {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try fixture.dir.createDir(io, "root", .default_dir);
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const parent = base[0..try fixture.dir.realPath(io, &base)];
    const path = try std.fs.path.join(a, &.{ parent, "root" });
    defer a.free(path);
    var root = try process.openRoot(a, io, path);
    defer root.deinit(a, io);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("PROBE", "isolated");
    var control: process.Control = .{};
    var sink: Sink = .{ .control = &control, .cancel = n == 14, .reject = n == 17 };
    defer sink.bytes.deinit(a);
    var stats: process.Stats = .{};
    var fds: [2]c.fd_t = undefined;
    try std.testing.expect(c.pipe(&fds) == 0);
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    var extra: c.fd_t = -1;
    defer if (extra >= 0) {
        _ = c.close(extra);
    };
    var target = fds[1];
    if (n == 2) {
        const limit = try std.posix.getrlimit(.NOFILE);
        const high: c_int = @intCast(@min(limit.cur - 1, 4095));
        extra = c.fcntl(target, c.F.DUPFD, high);
        try std.testing.expect(extra >= high);
        target = extra;
    }
    if (n == 3) {
        extra = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        try std.testing.expect(extra >= 0);
        target = extra;
    }
    if (n == 4) {
        target = root.directory.handle;
        try std.testing.expect(c.fcntl(target, c.F.SETFD, @as(c_int, 0)) == 0);
    }
    if (n == 5) try std.testing.expect(c.fcntl(target, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) == 0);
    var script_buf: [512]u8 = undefined;
    var script: []const u8 = try std.fmt.bufPrint(&script_buf, "if [ -e /dev/fd/{d} ]; then printf 'inherited\\n'; else printf 'closed\\n'; fi", .{target});
    switch (n) {
        6 => script = "printf '%s\\n' \"$1\"",
        7 => script = "printf '%s\\n' \"$PROBE\"",
        8 => script = "pwd -P",
        9 => script = "if read x; then exit 3; else printf 'eof\\n'; fi",
        10 => script = "/usr/bin/head -c 200000 /dev/zero >&2; printf 'ok\\n'",
        11 => script = "/usr/bin/head -c 65536 /dev/zero | /usr/bin/tr '\\0' x; printf '\\n'",
        12 => script = "printf 'a\\nb\\0'",
        14 => script = "printf 'tick\\n'; exec /bin/sleep 30",
        15 => script = "exec /bin/sleep 30",
        16 => script = "printf 'ok\\n'; exit 2",
        17 => script = "printf 'reject\\n'; exec /bin/sleep 30",
        18 => script = "printf 'xx\\n'",
        else => {},
    }
    if (n == 13) control.cancelled.store(true, .release);
    if (n == 19) {
        try fixture.dir.rename("root", fixture.dir, "old", io);
        try fixture.dir.createDir(io, "root", .default_dir);
    }
    const args: []const []const u8 = if (n == 6) &.{ "/bin/sh", "-c", script, "probe", "한 글😀" } else if (n == 20) &.{"/nonexistent-maru-fd-probe"} else &.{ "/bin/sh", "-c", script };
    const before = fdCount();
    const result = process.runDelimited(a, io, args, &env, &root, &control, .{ .execution_ms = if (n == 15) 50 else 5000, .reap_ms = 3000 }, if (n == 18) 1 else 128 * 1024, &sink, Sink.accept, &stats, if (n == 12) 0 else '\n');
    if (n == 17) try std.testing.expectError(error.CallbackRejected, result) else if (n == 18) try std.testing.expectError(error.EventTooLarge, result) else if (n == 19) try std.testing.expectError(error.RootChanged, result) else if (n == 20) {
        try std.testing.expectError(error.SpawnFailed, result);
        try std.testing.expectEqual(before, fdCount());
        try std.testing.expectError(error.InvalidArguments, process.run(a, io, &.{ "/bin/sh", "nul\x00arg" }, &env, &root, &control, .{ .execution_ms = 1000, .reap_ms = 1000 }, 1024, &sink, Sink.accept, &stats));
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, process.run(failing.allocator(), io, &.{ "/bin/sh", "-c", "printf x" }, &env, &root, &control, .{ .execution_ms = 1000, .reap_ms = 1000 }, 1024, &sink, Sink.accept, &stats));
    } else {
        try std.testing.expectEqual(if (n == 13 or n == 14) process.Outcome.cancelled else if (n == 15 or n == 16) process.Outcome.partial else process.Outcome.complete, try result);
        const want: ?[]const u8 = switch (n) {
            1...5 => "closed\n",
            6 => "한 글😀\n",
            7 => "isolated\n",
            9 => "eof\n",
            10, 16 => "ok\n",
            12 => "a\nb\n",
            14 => "tick\n",
            13, 15 => "",
            else => null,
        };
        if (want) |text| try std.testing.expectEqualStrings(text, sink.bytes.items);
        if (n == 8) {
            const expected = try std.fmt.allocPrint(a, "{s}\n", .{root.canonical});
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, sink.bytes.items);
        }
        if (n == 11) {
            try std.testing.expectEqual(@as(usize, 65537), sink.bytes.items.len);
            for (sink.bytes.items[0..65536]) |v| try std.testing.expectEqual(@as(u8, 'x'), v);
        }
        if (n == 16) try std.testing.expectEqual(@as(?u8, 2), stats.exit);
    }
    if (n <= 5) try std.testing.expect(c.fcntl(target, c.F.GETFD) != -1); // Child isolation must preserve the parent owner.
    if (n == 20) {
        var stream_oom = false;
        var healthy = false;
        for (0..8) |failure_index| {
            sink.bytes.clearRetainingCapacity();
            var injected = std.testing.FailingAllocator.init(a, .{ .fail_index = failure_index });
            var observed: process.Stats = .{};
            const attempt = process.run(injected.allocator(), io, &.{ "/bin/sh", "-c", "printf 'ok\\n'" }, &env, &root, &control, .{ .execution_ms = 1000, .reap_ms = 1000 }, 1024, &sink, Sink.accept, &observed);
            if (attempt) |outcome| {
                healthy = true;
                try std.testing.expectEqual(process.Outcome.complete, outcome);
                try std.testing.expectEqualStrings("ok\n", sink.bytes.items);
            } else |err| {
                try std.testing.expect(err == error.OutOfMemory);
                if (observed.children_started > 0) stream_oom = true;
            }
            std.debug.print("EDPSFD_OOM index={d} children={d} reaped={any}\n", .{ failure_index, observed.children_started, observed.reaped });
            try std.testing.expectEqual(before, fdCount());
            if (observed.children_started > 0) try std.testing.expect(observed.reaped);
        }
        try std.testing.expect(stream_oom and healthy);
    }
    const no_child = n == 13 or n == 19 or n == 20;
    try std.testing.expectEqual(@as(usize, if (no_child) 0 else 1), stats.children_started);
    if (!no_child) {
        try std.testing.expect(stats.reaped);
        var status: c_int = 0;
        try std.testing.expect(c.waitpid(stats.child_pid.?, &status, c.W.NOHANG) == -1);
        try std.testing.expect(std.posix.errno(@as(c_int, -1)) == .CHILD);
    }
    std.debug.print("EDPSFD case={d} passed=true children={d} reaped={any} bytes={d}\n", .{ n, stats.children_started, stats.reaped, sink.bytes.items.len });
}
test "EDPSFD01 unmarked pipe writer" {
    try scenario(1);
}
test "EDPSFD02 high descriptor" {
    try scenario(2);
}
test "EDPSFD03 unmarked open file" {
    try scenario(3);
}
test "EDPSFD04 root fd closes after fchdir" {
    try scenario(4);
}
test "EDPSFD05 protected control" {
    try scenario(5);
}
test "EDPSFD06 literal Unicode argv" {
    try scenario(6);
}
test "EDPSFD07 explicit environment" {
    try scenario(7);
}
test "EDPSFD08 pinned cwd" {
    try scenario(8);
}
test "EDPSFD09 stdin EOF" {
    try scenario(9);
}
test "EDPSFD10 ignored stderr backpressure" {
    try scenario(10);
}
test "EDPSFD11 pipe sized output" {
    try scenario(11);
}
test "EDPSFD12 NUL delimited newline name" {
    try scenario(12);
}
test "EDPSFD13 pre cancel has no child" {
    try scenario(13);
}
test "EDPSFD14 callback cancellation reaps" {
    try scenario(14);
}
test "EDPSFD15 execution deadline reaps" {
    try scenario(15);
}
test "EDPSFD16 nonzero status preserved" {
    try scenario(16);
}
test "EDPSFD17 callback failure reaps" {
    try scenario(17);
}
test "EDPSFD18 event overflow reaps" {
    try scenario(18);
}
test "EDPSFD19 replaced root rejected" {
    try scenario(19);
}
test "EDPSFD20 spawn argv and OOM failure cleanup" {
    try scenario(20);
}
