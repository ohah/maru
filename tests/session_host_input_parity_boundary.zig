//! P4 input parity micro-gate source and focused-build boundary.

const std = @import("std");

test "P4 input parity 경계는 AppSession 관측에서 actual host reader PTY까지 한 gate로 묶는다" {
    const allocator = std.testing.allocator;
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const manager = try readSource(allocator, "src/platform/macos/session_host/runtime_manager.zig");
    defer allocator.free(manager);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const persistent = try readSource(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try readSource(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);
    const verification = try readSource(allocator, "docs/verification-matrix.md");
    defer allocator.free(verification);
    const commands = try readSource(allocator, "docs/development-commands.md");
    defer allocator.free(commands);

    try std.testing.expectEqual(@as(usize, 1), count(app, "test \"host-backed motion 리포팅:"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "if (tracking != .any)"));
    try std.testing.expectEqual(@as(usize, 1), count(app, ".button = 3"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "test \"P4 input parity: host reader writes DECSET 1003 motion to the real PTY\""));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "test \"runtime manager: host selection scroll-and-extend is fenced before authoritative copy\""));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "return self.backend_impl.backend().enqueueCoreCommand(handle, .{ .report_mouse"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, ".scroll_and_extend => |step|"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "if (!rr.supportsSelectionState()) return;"));

    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-input-parity\""));
    try std.testing.expectEqual(@as(usize, 1), count(build, "session_host_input_parity_step.dependOn(session_host_e2c_step);"));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "고빈도 1003 hover와 selection autoscroll은") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "P4 parity micro-gate (완료)") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification, "P4 input parity micro-gate: 구현.") != null);
    try std.testing.expectEqual(@as(usize, 1), count(commands, "`zig build test-session-host-input-parity`"));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
}
