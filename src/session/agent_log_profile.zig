//! Process-pinned format and disjoint log namespaces; no OS or file-content inference.
const std = @import("std");
pub const Profile = @import("../agent_log_format.zig").Profile;
pub const Scope = enum { local, remote };
pub const local_env = @import("../agent_log_format.zig").local_env;
pub const remote_env = @import("../agent_log_format.zig").remote_env;
pub fn parse(value: ?[]const u8) ?Profile {
    const text = value orelse return .v1;
    if (std.mem.eql(u8, text, "1")) return .v1;
    if (std.mem.eql(u8, text, "2")) return .v2;
    return null;
}
pub fn localCacheSubdir(profile: Profile) []const u8 {
    return switch (profile) {
        .v1 => "agent-turn-events",
        .v2 => "agent-turn-events-v2",
    };
}
pub fn homeRelative(scope: Scope, profile: Profile) []const u8 {
    return switch (scope) {
        .local => switch (profile) {
            .v1 => ".cache/maru/agent-turn-events",
            .v2 => ".cache/maru/agent-turn-events-v2",
        },
        .remote => switch (profile) {
            .v1 => ".cache/maru/remote-agent-events",
            .v2 => ".cache/maru/remote-agent-events-v2",
        },
    };
}
pub fn dirAlloc(allocator: std.mem.Allocator, home: ?[]const u8, scope: Scope, profile: Profile) !?[]u8 {
    const value = home orelse return null;
    if (value.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, value, "/"), homeRelative(scope, profile) });
}
fn canonical(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/') return false;
    for (path) |byte| if (byte == 0 or byte == '\n' or byte == '\r') return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn contains(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}
/// Lexical isolation is necessary; native I/O still authenticates physical handles.
pub fn disjoint(roots: [4][]const u8) bool {
    for (roots, 0..) |root, i| {
        if (!canonical(root)) return false;
        for (roots[0..i]) |other| if (contains(root, other) or contains(other, root)) return false;
    }
    return true;
}
test "pinned format does not downgrade unknown or empty values" {
    try std.testing.expectEqual(Profile.v1, parse(null).?);
    try std.testing.expectEqual(Profile.v1, parse("1").?);
    try std.testing.expectEqual(Profile.v2, parse("2").?);
    for ([_][]const u8{ "", "02", "3", " 2", "2\n" }) |bad| try std.testing.expect(parse(bad) == null);
}
test "namespace isolation rejects aliases and overlapping roots" {
    const good: [4][]const u8 = .{ "/tmp/local", "/tmp/remote", "/tmp/local-v2", "/tmp/remote-v2" };
    try std.testing.expect(disjoint(good));
    for ([_][]const u8{ "/tmp/local", "/tmp/local/child", "/tmp", "/tmp/../else", "/tmp//else", "/tmp/./else", "/tmp/else/", "relative", "/" }) |bad| {
        var roots = good;
        roots[3] = bad;
        try std.testing.expect(!disjoint(roots));
    }
    const path = (try dirAlloc(std.testing.allocator, "/home/a/", .local, .v2)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/a/.cache/maru/agent-turn-events-v2", path);
    try std.testing.expectEqualStrings(".cache/maru/remote-agent-events", homeRelative(.remote, .v1));
}

/// A fresh GUI runtime may use native logs only when its producer and owner are
/// ready. An old persistent host keeps v1 instead of losing persistence through
/// a local fallback; explicit v2 requests still reach the strict capability gate.
pub fn forNewRuntime(requested: Profile, cli_ready: bool, directory_ready: bool, persistent_support: ?bool) Profile {
    if (requested == .v2) return .v2;
    if (!cli_ready or !directory_ready) return .v1;
    if (persistent_support) |supported| if (!supported) return .v1;
    return .v2;
}

test "native default selection preserves old hosts and explicit runtime intent" {
    const t = std.testing;
    try t.expectEqual(Profile.v2, forNewRuntime(.v1, true, true, null));
    try t.expectEqual(Profile.v2, forNewRuntime(.v1, true, true, true));
    try t.expectEqual(Profile.v1, forNewRuntime(.v1, true, true, false));
    try t.expectEqual(Profile.v1, forNewRuntime(.v1, false, true, null));
    try t.expectEqual(Profile.v1, forNewRuntime(.v1, true, false, null));
    try t.expectEqual(Profile.v2, forNewRuntime(.v2, false, false, false));
}
