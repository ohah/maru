
// PoC supplement; the existing 24 contract tests above retain their original expectations.
test "PoC every launched child already leads its own process group" {
    std.debug.print("poc_test_mode mode={s}\n", .{@tagName(@import("builtin").mode)});
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

fn pocSaveStdio(fd: c.fd_t) !c.fd_t {
    // Keep fd 3 free so closing stdin forces the inherited source to alias fd 3 itself.
    const saved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 64));
    try std.testing.expect(saved >= 64);
    try std.testing.expectEqual(@as(c_int, 0), c.close(fd));
    return saved;
}

fn pocRestoreStdio(saved: c.fd_t, fd: c.fd_t) void {
    _ = c.dup2(saved, fd);
    _ = c.close(saved);
}

fn pocClosedCapture(fd: c.fd_t) !void {
    const saved = try pocSaveStdio(fd);
    defer pocRestoreStdio(saved, fd);
    const probe: [:0]const u8 = POC_PROBE_LITERAL;
    const argv = [_:null]?[*:0]const u8{ probe.ptr, "echo", "ok" };
    const environment = [_:null]?[*:0]const u8{};
    var output: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ok\n", try process.runCaptureEnvironmentStdout(std.testing.io, probe, &argv, &environment, &output, run_budget_ns));
}

test "PoC closed stdin does not corrupt capture mappings" { try pocClosedCapture(0); }
test "PoC closed stdout does not corrupt capture mappings" { try pocClosedCapture(1); }
test "PoC closed stderr does not corrupt capture mappings" { try pocClosedCapture(2); }

test "PoC inherited receipt source aliases fd 3 when stdin is closed" {
    const saved = try pocSaveStdio(0);
    defer pocRestoreStdio(saved, 0);
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(3, c.F.GETFD));
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf ok >&3" };
    const environment = [_:null]?[*:0]const u8{};
    var child: process.InheritedPipeChild = .{};
    try process.spawnEnvironmentInheritedPipe(shell, &argv, &environment, &child);
    defer child.terminate() catch {};
    try std.testing.expectEqual(@as(c.fd_t, 0), child.read_fd);
    var output: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ok", try child.readReceipt(std.testing.io, &output, run_budget_ns));
}

test "PoC inherited socket source aliases fd 3 when stdin is closed" {
    const saved = try pocSaveStdio(0);
    defer pocRestoreStdio(saved, 0);
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(3, c.F.GETFD));
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf '\\000\\000\\000\\002ok' >&3" };
    const environment = [_:null]?[*:0]const u8{};
    var child: process.InheritedSocketChild = .{};
    try process.spawnEnvironmentInheritedSocket(shell, &argv, &environment, &child);
    defer child.terminate() catch {};
    try std.testing.expectEqual(@as(c.fd_t, 0), child.fd);
    var output: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ok", try child.readFrame(std.testing.io, &output, run_budget_ns));
}

test "PoC real program exit 126 remains an observed child exit" {
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "exit 126" };
    const environment = [_:null]?[*:0]const u8{};
    var stdout: [16]u8 = undefined;
    var stderr: [16]u8 = undefined;
    const observed = try process.runObserveEnvironment(std.testing.io, shell, &argv, &environment, &stdout, &stderr, run_budget_ns);
    try std.testing.expectEqual(process.Termination{ .exited = 126 }, observed.termination);
}

test "PoC insufficient gate descriptors preserves FD ownership" {
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = 128, .max = saved.max });
    defer std.posix.setrlimit(.NOFILE, saved) catch {};
    var held: [128]c.fd_t = undefined;
    var count: usize = 0;
    defer for (held[0..count]) |fd| { _ = c.close(fd); };
    while (count < held.len) {
        const fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
        if (fd < 0) break;
        held[count] = fd;
        count += 1;
    }
    try std.testing.expect(count > 3);
    for (0..3) |_| { count -= 1; _ = c.close(held[count]); }
    const before = pocCountFds();
    const probe: [:0]const u8 = POC_PROBE_LITERAL;
    const argv = [_:null]?[*:0]const u8{ probe.ptr, "echo", "ok" };
    const environment = [_:null]?[*:0]const u8{};
    var output: [16]u8 = undefined;
    if (process.runCaptureEnvironmentStdout(std.testing.io, probe, &argv, &environment, &output, run_budget_ns)) |bytes| {
        try std.testing.expectEqualStrings("ok\n", bytes);
    } else |err| {
        try std.testing.expect(err == error.PipeFailed or err == error.SpawnSetupFailed or err == error.SpawnFailed or err == error.ChildFailed);
    }
    try std.testing.expectEqual(before, pocCountFds());
}

fn pocCountFds() usize {
    var count: usize = 0;
    for (0..128) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) >= 0) { count += 1; };
    return count;
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
