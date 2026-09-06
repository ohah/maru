//! P3-e4d-2a actual foreground and AppSession consumer boundary.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

test "P3-e4d-2a metadata consumers use actual product boundaries" {
    const allocator = std.testing.allocator;
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);
    const build = try read(allocator, "build.zig", 2 * 1024 * 1024);
    defer allocator.free(build);
    const matrix = try read(allocator, "docs/verification-matrix.md", 2 * 1024 * 1024);
    defer allocator.free(matrix);

    const marker = "test \"P3-e4d-2a actual foreground metadata reaches Git agent and SSH consumers\"";
    const start = std.mem.indexOf(u8, app, marker) orelse return error.MissingProductGate;
    const tail = app[start + marker.len ..];
    const end = std.mem.indexOf(u8, tail, "\ntest \"") orelse tail.len;
    const body = tail[0..end];

    try std.testing.expectEqual(@as(usize, 1), count(app, marker));
    try std.testing.expectEqual(@as(usize, 1), count(build, "test-session-host-metadata-consumers"));
    try std.testing.expectEqual(@as(usize, 1), count(matrix, "P3-e4d-2a current-host foreground·consumer parity"));
    try std.testing.expect(std.mem.indexOf(u8, body, "session_host.daemon.runSessionHost") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "RemoteTermBackend.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "term_ops.createTerm") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "agent_ops.pollAgentKinds") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "git_ops.termGitBranch") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "remoteUploadContext") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "handleDroppedFiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "testing_api") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "test_only") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "writeArtifact") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "observation.replace") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "term.agent_kind = .") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "term.git_branch = ") == null);
}
