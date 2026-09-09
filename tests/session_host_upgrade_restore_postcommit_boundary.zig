const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn enumBody(source: []const u8) ![]const u8 {
    const start_marker = "pub const PostcommitFault = enum {";
    const start = std.mem.indexOf(u8, source, start_marker) orelse
        return error.TestUnexpectedResult;
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, source, body_start, "\n};") orelse
        return error.TestUnexpectedResult;
    return source[body_start..end];
}

test "U5 restore postcommit fault vocabulary is closed and absent from the product entrypoint" {
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
        "tools/session_host_restore_postcommit_test_runner.zig",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(runner);
    const build = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(build);

    try std.testing.expectEqual(
        @as(usize, 1),
        count(activation, "pub const PostcommitFault = enum {"),
    );
    var fields = std.mem.splitScalar(u8, try enumBody(activation), '\n');
    var fault_count: usize = 0;
    while (fields.next()) |line| {
        const name = std.mem.trim(u8, line, " \t,");
        if (name.len == 0 or std.mem.eql(u8, name, "none")) continue;
        try std.testing.expect(std.ascii.isAlphabetic(name[0]));
        for (name) |byte|
            try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '_');
        try std.testing.expect(count(main, name) == 0);
        fault_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), fault_count);
    try std.testing.expect(count(activation, "runWithPostcommitFaultForTest") == 1);
    try std.testing.expect(count(activation, "if (!fault.consumed) return error.PostcommitFaultNotConsumed") == 2);
    try std.testing.expect(count(e2e, "std.enums.values(sh.restore_activation.PostcommitFault)") == 1);
    try std.testing.expect(count(e2e, "if (fault == .none or fault == .rollback_promotion) continue;") == 1);
    try std.testing.expect(count(e2e, "runRestoreFaultCase(null, .rollback_promotion, 3, .postcommit_status_only)") == 1);
    try std.testing.expect(count(e2e, "expectPostcommitVocabularyAbsentFromProduct") == 2);
    try std.testing.expect(count(e2e, "const rollback_source = if (postcommit_fault != null) self else product;") == 1);
    try std.testing.expect(count(e2e, "restore postcommit fail-stop rows never execute rollback") == 1);
    try std.testing.expect(count(e2e, "restore postcommit promotion failure keeps the real PTY status-only") == 1);
    try std.testing.expect(count(runner, "--restore-activation-postcommit-fault") == 1);
    try std.testing.expect(count(runner, "std.mem.eql(u8, first, \"__session-host\")") == 1);
    try std.testing.expect(count(runner, "std.process.exit(94)") == 1);
    try std.testing.expect(count(build, "test-session-host-upgrade-restore-postcommit-failure-matrix") == 1);
    try std.testing.expect(count(build, "run_session_host_restore_postcommit_tests.addArg(\"--maru-expect-tests=2\")") == 1);
    try std.testing.expect(count(build, "session_host_restore_postcommit_step.dependOn(&run_session_host_restore_postcommit_tests.step)") == 1);
}
