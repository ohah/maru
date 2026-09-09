const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn enumBody(source: []const u8) ![]const u8 {
    const start_marker = "pub const PrecommitFault = enum {";
    const start = std.mem.indexOf(u8, source, start_marker) orelse
        return error.TestUnexpectedResult;
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, source, body_start, "\n};") orelse
        return error.TestUnexpectedResult;
    return source[body_start..end];
}

test "U5 restore precommit fault vocabulary is closed and absent from the product entrypoint" {
    const activation = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/restore_activation.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(activation);
    const main = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(main);
    const e2e = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/session_host_nonempty_rollback_e2e.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(e2e);
    const runner = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tools/session_host_restore_precommit_test_runner.zig",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(runner);
    const entrypoint = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/entrypoint.zig",
        std.testing.allocator,
        .limited(32 * 1024),
    );
    defer std.testing.allocator.free(entrypoint);
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(build);

    try std.testing.expectEqual(
        @as(usize, 1),
        count(activation, "pub const PrecommitFault = enum {"),
    );
    var fields = std.mem.splitScalar(u8, try enumBody(activation), '\n');
    var fault_count: usize = 0;
    while (fields.next()) |line| {
        const name = std.mem.trim(u8, line, " \t,");
        if (name.len == 0 or std.mem.eql(u8, name, "none")) continue;
        try std.testing.expect(std.ascii.isAlphabetic(name[0]));
        for (name) |byte|
            try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '_');
        try std.testing.expect(count(activation, name) >= 1);
        try std.testing.expect(count(main, name) == 0);
        fault_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 11), fault_count);
    try std.testing.expect(count(activation, "runWithPrecommitFaultForTest") == 1);
    try std.testing.expect(count(activation, "if (!builtin.is_test) @compileError") >= 1);
    try std.testing.expect(count(activation, "if (!fault.consumed) return error.PrecommitFaultNotConsumed") == 1);
    try std.testing.expect(count(main, "--restore-activation-fault") == 0);
    try std.testing.expect(count(e2e, "std.enums.values(sh.restore_activation.PrecommitFault)") == 1);
    try std.testing.expect(count(e2e, "if (fault == .none or fault == .manifest_ready_poisoned) continue;") == 1);
    try std.testing.expect(count(e2e, "runPrecommitCase(.manifest_ready_poisoned, 10, true)") == 1);
    try std.testing.expect(count(e2e, "restore precommit rollback-safe matrix preserves one real PTY and same host PID") == 1);
    try std.testing.expect(count(e2e, "restore precommit manifest poison fails closed without recursive rollback") == 1);
    try std.testing.expect(count(runner, "std.mem.eql(u8, first, \"--restore-activation-fault\")") == 1);
    try std.testing.expect(count(runner, "std.mem.eql(u8, first, \"__session-host\")") == 1);
    try std.testing.expect(count(entrypoint, "pub const subcommand = \"__session-host\";") == 1);
    try std.testing.expect(count(build, "test-session-host-upgrade-restore-precommit-failure-matrix") == 1);
    try std.testing.expect(count(build, "run_session_host_restore_precommit_tests.addArg(\"--maru-expect-tests=2\")") == 1);
    try std.testing.expect(count(build, "session_host_restore_precommit_step.dependOn(&run_session_host_restore_precommit_tests.step)") == 1);
}
