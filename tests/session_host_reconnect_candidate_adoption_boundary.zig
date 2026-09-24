//! CR6e-c3a main-owner adoption boundary. This gate deliberately does not claim worker threads,
//! AppSession frame wiring, CR5 transaction driving, or the actual disconnect recovery E2E.

const std = @import("std");

test "CR6e-c3a boundary keeps candidate adoption nonblocking exact-identity and product dormant" {
    const allocator = std.testing.allocator;
    const backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try read(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const docs = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(docs);

    const adoption = between(
        backend,
        "pub fn beginHostReconnectCandidate(",
        "pub fn abortHostReconnectConnect(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), count(adoption, "connectExistingHostUntil"));
    try std.testing.expectEqual(@as(usize, 0), count(adoption, "std.Thread.spawn"));
    try std.testing.expectEqual(@as(usize, 1), count(adoption, "matchesBoundReconnectIdentity("));
    inline for (.{
        "snapshot.pool_membership_generation",
        "snapshot.connection_generation",
        "snapshot.incident_app_instance_nonce",
        "snapshot.incident_sequence",
        "snapshot.absolute_deadline_ns",
    }) |needle| try std.testing.expect(count(adoption, needle) > 0);
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn matchesBoundReconnectIdentity("));
    try std.testing.expectEqual(@as(usize, 0), count(app, "beginHostReconnectCandidate("));
    try std.testing.expect(std.mem.indexOf(u8, docs, "CR6e-c3a main-owner candidate adoption 경계") != null);
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
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
