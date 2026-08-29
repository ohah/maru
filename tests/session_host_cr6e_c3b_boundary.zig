const std = @import("std");

test "CR6e-c3b worker boundary keeps one final-address lane pointer-free" {
    const allocator = std.testing.allocator;
    const runtime = try read(allocator, "src/platform/macos/session_host/reconnect_worker_runtime.zig");
    defer allocator.free(runtime);
    const issuer = try read(allocator, "src/platform/macos/session_host/reconnect_worker_issuer.zig");
    defer allocator.free(issuer);
    const coordinator = try read(allocator, "src/platform/macos/session_host/reconnect_product_coordinator.zig");
    defer allocator.free(coordinator);
    const admissions = try read(allocator, "src/platform/macos/session_host/reconnect_admission_owner.zig");
    defer allocator.free(admissions);
    const backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const app_session = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const docs = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(docs);

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "std.Thread.spawn("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "completion: issuer.Completion"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "issuer.executeInto("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "*RemoteRuntime"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "*RemoteTermBackend"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "*HostAdapter"));
    try std.testing.expectEqual(@as(usize, 1), count(issuer, "pub fn resetConsumedAtFinalAddress("));
    try std.testing.expectEqual(@as(usize, 1), count(issuer, "pub fn validateConsumedAtFinalAddress("));
    try std.testing.expectEqual(@as(usize, 0), count(coordinator, "std.Thread.spawn("));
    try std.testing.expectEqual(@as(usize, 0), count(coordinator, "connectExistingHostUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn admitOne("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn dispatchOne("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn pollCompletion("));
    try std.testing.expectEqual(@as(usize, 1), count(admissions, "pub fn preparedProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn bindPreparedReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 0), count(app_session, "app_reconnect_product_coordinator"));
    try std.testing.expect(std.mem.indexOf(u8, docs, "CR6e-c3b app-global worker와 제품 정산 경계") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs, "flowchart TD") != null);
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024 * 1024));
}
