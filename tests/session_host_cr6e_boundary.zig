//! CR6e-a1 transport baseline artifact and product-boundary source policy.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "CR6e-a1 경계는 stalled peer raw artifact만 열고 자동 reconnect를 배선하지 않는다" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const harness = try read(allocator, "src/platform/macos/session_host/cr6e_baseline.zig");
    defer allocator.free(harness);
    const validator = try read(allocator, "tools/perf/session_host_cr6e_baseline_validator.zig");
    defer allocator.free(validator);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);

    try std.testing.expectEqual(@as(usize, 1), count(build, "test-session-host-cr6e-baseline-macos"));
    try std.testing.expectEqual(@as(usize, 2), count(build, "session-host-cr6e-baseline-macos.json"));
    try std.testing.expectEqual(@as(usize, 2), count(harness, "connectExistingHostUntilObserved"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "connectExistingHostUntilObserved",
        &.{
            "platform/macos/session_host/host_connect.zig",
            "platform/macos/session_host/cr6e_baseline.zig",
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "hello_reply_stall"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "transient_backoff"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "defer if (peer_owned) terminateAndReap(peer_pid);"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "defer if (artifact_fd_open) {"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "std.json.parseFromSlice"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "const backoff_attempt_limit: u32 = 10;"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "std.mem.eql(u8, backoff.failure_reason, \"host_gone\")"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "std.mem.eql(u8, backoff.failure_reason, \"deadline_exceeded\")"));

    // CR6e-a1 is evidence collection. Product auto-reconnect remains forbidden until CR6e-b.
    try std.testing.expectEqual(@as(usize, 0), count(app, "MARU_SESSION_HOST_CR6E_AUTO_RECONNECT"));
}

test "CR6e-a2 경계는 exact AppKit fixture root와 반복 raw artifact만 연다" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const harness = try read(allocator, "src/platform/macos/session_host/cr6c_appkit_smoke.zig");
    defer allocator.free(harness);
    const validator = try read(allocator, "tools/perf/session_host_cr6e_recovery_validator.zig");
    defer allocator.free(validator);
    const budget = try read(allocator, "tools/perf/session_host_cr6e_budget_validator.zig");
    defer allocator.free(budget);
    const soak = try read(allocator, "tools/perf/session-host-cr6e-soak.sh");
    defer allocator.free(soak);

    try std.testing.expectEqual(@as(usize, 1), count(build, "\"macos-session-host-cr6e-recovery-baseline\""));
    try std.testing.expectEqual(@as(usize, 1), count(build, "MARU_SESSION_HOST_CR6E_RECOVERY_BASELINE_ARTIFACT"));
    // Capture root validation and native-wake handshake root allowlist each name the exact root.
    try std.testing.expectEqual(@as(usize, 2), count(swift, "\"session-host-cr6e-home\""));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "private var isSessionHostRecoveryBaselineMode: Bool"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "MARU_SESSION_HOST_CR6E_RECOVERY_ITERATION"));
    try std.testing.expectEqual(@as(usize, 1), count(swift, "sessionHostRecoverySmokeCaptureLabel(label)"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "const recovery_baseline_iterations: usize = 5;"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, "for (0..iteration_count)"));
    try std.testing.expectEqual(@as(usize, 2), count(harness, "MARU_SESSION_HOST_CR6E_RECOVERY_ITERATION"));
    try std.testing.expectEqual(@as(usize, 1), count(harness, ".swift_iteration ="));
    try std.testing.expectEqual(@as(usize, 1), count(harness, ".fd_before ="));
    try std.testing.expectEqual(@as(usize, 1), count(harness, ".fd_after ="));
    try std.testing.expectEqual(@as(usize, 1), count(harness, ".child_processes_remaining ="));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "std.json.parseFromSlice"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "const iteration_count: usize = 5;"));
    try std.testing.expectEqual(@as(usize, 1), count(budget, "const expected_os_release = \"25.5.0\";"));
    try std.testing.expectEqual(@as(usize, 1), count(budget, "const expected_machine_model = \"Mac16,9\";"));
    try std.testing.expectEqual(@as(usize, 1), count(soak, "while [ \"$batch\" -lt 20 ]"));
    // The harness observes the normal product click path; it must not call the Zig activation
    // action or manufacture a remote projection directly.
    try std.testing.expectEqual(@as(usize, 0), count(harness, "activateRecoveredSessionAt"));
    try std.testing.expectEqual(@as(usize, 0), count(harness, "maru_macos_app_session_activate"));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, identifier)) |at| {
        const end = at + identifier.len;
        if ((at == 0 or !identifierByte(haystack[at - 1])) and
            (end == haystack.len or !identifierByte(haystack[end]))) total += 1;
        offset = end;
    }
    return total;
}

fn countProductIdentifiersExcept(allocator: std.mem.Allocator, identifier: []const u8, excluded: []const []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);
        total += countIdentifier(source, identifier);
    }
    return total;
}
