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
    const close_graph_source = try readSource(allocator, "src/platform/macos/session_host/pending_term_close_graph.zig");
    defer allocator.free(close_graph_source);
    const app_source = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_source);
    const workspace_source = try readSource(allocator, "src/platform/macos/app_session/workspace.zig");
    defer allocator.free(workspace_source);
    const term_source = try readSource(allocator, "src/platform/macos/app_session/term.zig");
    defer allocator.free(term_source);
    const seal_source = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal_source);
    const cleanup_source = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(cleanup_source);
    const build_source = try readSource(allocator, "build.zig");
    defer allocator.free(build_source);

    try std.testing.expectEqual(@as(usize, 6), count(red_source, "test \"C3-3b5 중립 계약"));
    try std.testing.expectEqual(@as(usize, 6), count(red_source, "test \"C3-3b5 close readiness"));
    try std.testing.expectEqual(@as(usize, 8), count(red_source, "test \"C3-3b5 close authority"));
    try std.testing.expectEqual(@as(usize, 8), count(red_source, "test \"C3-3b5 close sweep"));
    try std.testing.expectEqual(@as(usize, 8), count(backend_source, "test \"C3-3b5 remote backend"));
    // 두 daemon과 process singleton을 쓰는 제품 검증은 b5 전용 exact-one artifact에서만 필수 실행한다.
    // broad filter는 exact marker로 그 한 행만 건너뛰고 나머지 일곱 synthetic 행을 같은 artifact에서 유지한다.
    try std.testing.expectEqual(@as(usize, 1), count(backend_source, "MARU_SESSION_HOST_WINDOW_CLOSE_MULTIHOST"));
    try std.testing.expectEqual(@as(usize, 3), count(build_source, "MARU_SESSION_HOST_WINDOW_CLOSE_MULTIHOST"));
    try std.testing.expectEqual(@as(usize, 3), count(build_source, "\"C3-3b5 remote backend"));
    try std.testing.expectEqual(@as(usize, 3), count(build_source, "event_c3_3b5_remote_backend_module"));
    try std.testing.expectEqual(@as(usize, 7), count(build_source, "previous_actual_host_run"));
    try std.testing.expectEqual(@as(usize, 2), count(close_graph_source, "test \"C3-3b5 close graph"));
    try std.testing.expectEqual(@as(usize, 4), count(app_source, "test \"C3-3b5 AppSession"));
    try std.testing.expectEqual(@as(usize, 42), count(red_source, "test \"C3-3b5 ") + count(backend_source, "test \"C3-3b5 remote backend") + count(close_graph_source, "test \"C3-3b5 close graph") + count(app_source, "test \"C3-3b5 AppSession"));
    // b4가 dormant seam의 유일한 semantic adapter를 활성화한다. backend sweep 밖 caller는 계속 금지한다.
    try std.testing.expectEqual(@as(usize, 1), count(runtime_source, "pub fn advancePendingEventForClose("));
    // b5 sweep, detach-preserve graph-last, b6 app-quit target만 제품 Pending을 전진시킨다.
    try std.testing.expectEqual(@as(usize, 3), count(backend_source, ".advancePendingEventForClose()"));
    try std.testing.expectEqual(@as(usize, 0), count(app_source, "advancePendingEventForClose("));
    try std.testing.expectEqual(@as(usize, 1), count(workspace_source, "backend.windowCloseReadiness(term.rt.handle)"));
    try std.testing.expectEqual(@as(usize, 1), count(workspace_source, "backend.reserveWindowCloseTickets("));
    try std.testing.expectEqual(@as(usize, 1), count(workspace_source, "backend.publishWindowCloseAuthoritiesNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(backend_source, "pub fn reserveWindowCloseTickets("));
    try std.testing.expectEqual(@as(usize, 1), count(backend_source, "pub fn publishWindowCloseAuthoritiesNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(backend_source, "self.surface_runtime.linkMatches(handle, &entry.runtime.surface, handle, entry.runtime)"));
    try std.testing.expectEqual(@as(usize, 1), count(cleanup_source, "pub const WindowCloseTicketReservationSealInput = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(seal_source, "maru.window-close-ticket-reservation.v1"));
    // current/restore 제품 설치 두 곳과 CR0b bootstrap 5의 실제 global-backend settlement fixture 한 곳이다.
    try std.testing.expectEqual(@as(usize, 2), count(app_source, "app_remote_backend.?.claimProductSingleton()"));
    try std.testing.expectEqual(@as(usize, 2), count(app_source, "if (!claimInstalledRemoteBackend("));
    try std.testing.expectEqual(@as(usize, 1), count(backend_source, "pub fn claimProductSingleton("));
    try std.testing.expectEqual(@as(usize, 1), count(close_graph_source, "@import(\"process_seal_service.zig\")"));
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
