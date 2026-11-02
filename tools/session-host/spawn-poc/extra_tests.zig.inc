
// PoC supplement; the existing 24 contract tests above retain their original expectations.
test "PoC every launched child already leads its own process group" {
    const probe: [:0]const u8 = POC_PROBE_LITERAL;
    const environment = [_:null]?[*:0]const u8{};
    const argv = [_:null]?[*:0]const u8{ probe.ptr, "group" };
    var elapsed: [30]u64 = undefined;
    for (&elapsed) |*sample| {
        var output: [64]u8 = undefined;
        const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        const bytes = try process.runCaptureEnvironmentStdout(std.testing.io, probe, &argv, &environment, &output, run_budget_ns);
        sample.* = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started);
        var values = std.mem.tokenizeAny(u8, bytes, " \n");
        const pid = try std.fmt.parseInt(i32, values.next() orelse return error.MissingPid, 10);
        const group = try std.fmt.parseInt(i32, values.next() orelse return error.MissingGroup, 10);
        try std.testing.expectEqual(pid, group);
        try std.testing.expect(values.next() == null);
    }
    std.mem.sort(u64, &elapsed, {}, std.sort.asc(u64));
    std.debug.print("poc_group_launch mode={s} samples={d} median_ns={d} p95_ns={d} max_ns={d}\n", .{
        @tagName(@import("builtin").mode), elapsed.len, elapsed[elapsed.len / 2], elapsed[(elapsed.len * 95 - 1) / 100], elapsed[elapsed.len - 1],
    });
}

test "PoC non-CLOEXEC descriptor above a lowered soft limit is not inherited" {
    const probe: [:0]const u8 = POC_PROBE_LITERAL;
    const original = c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try std.testing.expect(original >= 0);
    defer _ = c.close(original);
    const high = c.fcntl(original, c.F.DUPFD, @as(c_int, 512));
    try std.testing.expect(high >= 512);
    defer _ = c.close(high);
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(high, c.F.SETFD, @as(c_int, 0)));
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = 256, .max = saved.max });
    defer std.posix.setrlimit(.NOFILE, saved) catch {};
    var number_storage: [32]u8 = undefined;
    const number = try std.fmt.bufPrintSentinel(&number_storage, "{d}", .{high}, 0);
    const argv = [_:null]?[*:0]const u8{ probe.ptr, "fd", number.ptr };
    const environment = [_:null]?[*:0]const u8{};
    var output: [32]u8 = undefined;
    const bytes = try process.runCaptureEnvironmentStdout(std.testing.io, probe, &argv, &environment, &output, run_budget_ns);
    try std.testing.expectEqualStrings("closed\n", bytes);
}
