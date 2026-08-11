const std = @import("std");

test "C3-3b4 product semantic pump boundary는 sole caller와 raw source zero를 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/remote_runtime_pending_event.zig");
    defer allocator.free(adapter);
    const pending = try readSource(allocator, "src/platform/macos/session_host/pending_event_owner.zig");
    defer allocator.free(pending);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn settlePreparedEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "remote_runtime_pending_event_mod.settlePreparedEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn settleAndCommitPreparedEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn commitPreparedSemanticEvent("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "pending_generation_event_outcome"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "pending_generation_event_outcome"));

    inline for (.{
        "beginSemanticCommit",
        "moveCommittedObservationNoFail",
        "recordSemanticPostNoFail",
        "finishSemanticCommitNoFail",
    }) |name| try std.testing.expectEqual(
        @as(usize, 1),
        count(pending, "pub fn " ++ name ++ "("),
    );

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn advancePendingEventForClose("));
    // frame close sweep, detach-preserve graph-last, end-all target cursor만 prepared Pending을 제품 경로에서 소비한다.
    try std.testing.expectEqual(@as(usize, 3), count(backend, ".advancePendingEventForClose()"));
    try std.testing.expectEqual(@as(usize, 0), count(app, "advancePendingEventForClose("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn maintenanceEventTick("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "backend.maintenanceEventTick()"));

    try std.testing.expectEqual(@as(usize, 9), count(runtime, "test \"C3-3b4 실제 Runtime event"));
    try std.testing.expectEqual(@as(usize, 5), count(backend, "test \"C3-3b4 pump round-robin"));
    try std.testing.expectEqual(@as(usize, 3), count(runtime, "test \"C3-3b4 pump round-robin"));
    try std.testing.expectEqual(@as(usize, 2), count(backend, "test \"C3-3b4 async close parity"));
    try std.testing.expectEqual(@as(usize, 2), count(app, "test \"C3-3b4 async close parity"));
    try std.testing.expectEqual(@as(usize, 3), count(runtime, "test \"C3-3b4 proof-loss subprocess"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(backend, "test \"C3-3b4 remote backend는 실제 host runtime을 TermRuntimeBackend 계약으로 구동한다\""),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(backend, "std.c.getenv(\"MARU_SESSION_HOST_REMOTE_BACKEND_REAL_HOST\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        count(build, "\"MARU_SESSION_HOST_REMOTE_BACKEND_REAL_HOST\""),
    );
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"MARU_C3B4_PROOF_LOSS\""));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "std.c.getenv(\"MARU_C3B4_PROOF_LOSS\")"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fresh-artifact-v1"));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
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
