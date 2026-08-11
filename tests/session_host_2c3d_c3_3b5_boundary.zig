const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

test "C3-3b5 common close progress boundary는 RED inventory와 dormant caller를 고정한다" {
    const allocator = std.testing.allocator;
    const red_source = try readSource(allocator, "tests/session_host_2c3d_c3_3b5_red.zig");
    defer allocator.free(red_source);
    const runtime_source = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime_source);
    const backend_source = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend_source);
    const app_source = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_source);
    const workspace_source = try readSource(allocator, "src/platform/macos/app_session/workspace.zig");
    defer allocator.free(workspace_source);
    const term_source = try readSource(allocator, "src/platform/macos/app_session/term.zig");
    defer allocator.free(term_source);

    try std.testing.expectEqual(@as(usize, 6), count(red_source, "test \"C3-3b5 중립 계약"));
    try std.testing.expectEqual(@as(usize, 6), count(red_source, "test \"C3-3b5 close readiness"));
    try std.testing.expectEqual(@as(usize, 8), count(red_source, "test \"C3-3b5 close authority"));
    try std.testing.expectEqual(@as(usize, 8), count(red_source, "test \"C3-3b5 close sweep"));
    try std.testing.expectEqual(@as(usize, 7), count(backend_source, "test \"C3-3b5 remote backend"));
    try std.testing.expectEqual(@as(usize, 4), count(app_source, "test \"C3-3b5 AppSession"));
    try std.testing.expectEqual(@as(usize, 39), count(red_source, "test \"C3-3b5 ") + count(backend_source, "test \"C3-3b5 remote backend") + count(app_source, "test \"C3-3b5 AppSession"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime_source, "advancePendingEventForClose("));
    try std.testing.expectEqual(@as(usize, 0), count(backend_source, "advancePendingEventForClose("));
    try std.testing.expectEqual(@as(usize, 0), count(app_source, "advancePendingEventForClose("));
    try std.testing.expectEqual(@as(usize, 1), count(workspace_source, "backend.windowCloseReadiness(term.rt.handle)"));
    try std.testing.expectEqual(@as(usize, 2), count(app_source, "app_remote_backend.?.claimProductSingleton()"));
    try std.testing.expectEqual(@as(usize, 1), count(backend_source, "pub fn claimProductSingleton("));
    try std.testing.expectEqual(@as(usize, 1), count(app_source, "workspace_ops.advancePendingWindowClose(self);"));
    try std.testing.expectEqual(@as(usize, 1), count(term_source, "self.allocator.create(Term)"));
    const remote_spawn = std.mem.indexOf(u8, term_source, "rb.attachTermOnHost(") orelse return error.TestUnexpectedResult;
    const local_spawn = std.mem.indexOf(u8, term_source, "break :surface be.spawn(") orelse return error.TestUnexpectedResult;
    const term_allocation = std.mem.indexOf(u8, term_source, "self.allocator.create(Term)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(remote_spawn < term_allocation);
    try std.testing.expect(local_spawn < term_allocation);
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}
