//! Contract tests for the credential-free current GitHub Release metadata owner.

const std = @import("std");
const metadata = @import("release_adapter_remote_release_metadata");
const context_mod = @import("release_adapter_context");

const sha = "0123456789abcdef0123456789abcdef01234567";

test "immutable published baseline Release becomes one role-ordered sealed owner" {
    var result: metadata.Owner = .{};
    try metadata.bind(std.testing.allocator, baseline(), context(), &result);
    const value = result.value().?;
    try std.testing.expectEqual(@as(u64, 88), value.release_id);
    try std.testing.expectEqualStrings("baseline-evidence.json", value.assets[@intFromEnum(metadata.Role.evidence_candidate)].name);
    try std.testing.expectEqual([_]u64{ 1000, 1001, 1002, 1003 }, ids(value.assets));
    var copied = result;
    try std.testing.expect(copied.value() == null);
    result.sizes[@intFromEnum(metadata.Role.dmg)] += 1;
    try std.testing.expect(result.value() == null);
    result.sizes[@intFromEnum(metadata.Role.dmg)] -= 1;
    try result.deinit();
    try std.testing.expect(result.value() == null);
}

test "asset array order is not authority and upgrade filename remains only a candidate" {
    var result: metadata.Owner = .{};
    try metadata.bind(std.testing.allocator, upgradeReordered(), context(), &result);
    const value = result.value().?;
    try std.testing.expectEqualStrings("Maru-1.2.3-universal.dmg", value.assets[@intFromEnum(metadata.Role.dmg)].name);
    try std.testing.expectEqualStrings("upgrade-evidence.json", value.assets[@intFromEnum(metadata.Role.evidence_candidate)].name);
    try std.testing.expect(!@hasField(metadata.View, "profile"));
    try result.deinit();
}

test "context and immutable release lifecycle drift fail before publication" {
    inline for (.{
        replace(baseline(), "\"immutable\":true", "\"immutable\":false"),
        replace(baseline(), "\"draft\":false", "\"draft\":true"),
        replace(baseline(), "\"prerelease\":false", "\"prerelease\":true"),
        replace(baseline(), "\"tag_name\":\"v1.2.3\"", "\"tag_name\":\"v1.2.4\""),
        replace(baseline(), sha, "1123456789abcdef0123456789abcdef01234567"),
    }) |invalid| {
        defer std.testing.allocator.free(invalid);
        var result: metadata.Owner = .{};
        try std.testing.expectError(error.InvalidResponse, metadata.bind(std.testing.allocator, invalid, context(), &result));
        try std.testing.expect(result.value() == null);
    }
}

test "asset exact set identity digest URL and scalar types fail closed" {
    inline for (.{
        replace(baseline(), "Maru-1.2.3-session-host-release.json", "upgrade-evidence.json"),
        replace(baseline(), "Maru-1.2.3-universal.dmg", "foreign.dmg"),
        replace(baseline(), "\"id\":1003", "\"id\":1002"),
        replace(baseline(), "sha256:cccc", "sha512:cccc"),
        replace(baseline(), "releases/assets/1002", "releases/assets/9999"),
        replace(baseline(), "\"size\":102", "\"size\":0"),
        replace(baseline(), "\"size\":102", "\"size\":2147483648"),
        replace(baseline(), "\"state\":\"uploaded\"", "\"state\":\"new\""),
        replace(baseline(), "application/octet-stream", "text/plain"),
        replace(baseline(), "\"id\":88", "\"id\":\"88\""),
    }) |invalid| {
        defer std.testing.allocator.free(invalid);
        var result: metadata.Owner = .{};
        try std.testing.expectError(error.InvalidResponse, metadata.bind(std.testing.allocator, invalid, context(), &result));
    }
}

test "complete bounded JSON allows extensions but rejects duplicate trailing and oversize input" {
    const extended = replace(baseline(), "\"id\":88", "\"future\":true,\"id\":88");
    defer std.testing.allocator.free(extended);
    var accepted: metadata.Owner = .{};
    try metadata.bind(std.testing.allocator, extended, context(), &accepted);
    try accepted.deinit();
    inline for (.{
        replace(baseline(), "\"id\":88", "\"id\":88,\"id\":88"),
        std.fmt.allocPrint(std.testing.allocator, "{s}x", .{baseline()}) catch unreachable,
    }) |invalid| {
        defer std.testing.allocator.free(invalid);
        var result: metadata.Owner = .{};
        try std.testing.expectError(error.InvalidResponse, metadata.bind(std.testing.allocator, invalid, context(), &result));
    }
    const huge = try std.testing.allocator.alloc(u8, 64 * 1024 + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    var result: metadata.Owner = .{};
    try std.testing.expectError(error.InvalidResponse, metadata.bind(std.testing.allocator, huge, context(), &result));
}

test "preowned aliased and every allocation failure publish no owner" {
    var preowned: metadata.Owner = .{ .release_id = 1 };
    try std.testing.expectError(error.InvalidOwner, metadata.bind(std.testing.allocator, baseline(), context(), &preowned));
    var aliased: metadata.Owner = .{};
    try std.testing.expectError(error.InvalidOwner, metadata.bind(std.testing.allocator, std.mem.asBytes(&aliased), context(), &aliased));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var result: metadata.Owner = .{};
    try metadata.bind(allocator, baseline(), context(), &result);
    try result.deinit();
}

fn ids(assets: [metadata.asset_count]metadata.Asset) [metadata.asset_count]u64 {
    var result: [metadata.asset_count]u64 = undefined;
    for (&result, assets) |*id, asset| id.* = asset.id;
    return result;
}

fn replace(source: []const u8, needle: []const u8, replacement: []const u8) []u8 {
    return std.mem.replaceOwned(u8, std.testing.allocator, source, needle, replacement) catch unreachable;
}

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = sha,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn baseline() []const u8 {
    return "{\"id\":88,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
        "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1000\"}," ++
        "{\"id\":1001,\"name\":\"maru-session-host-1.2.3\",\"size\":101,\"state\":\"uploaded\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1001\"}," ++
        "{\"id\":1002,\"name\":\"baseline-evidence.json\",\"size\":102,\"state\":\"uploaded\",\"digest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1002\"}," ++
        "{\"id\":1003,\"name\":\"Maru-1.2.3-session-host-release.json\",\"size\":103,\"state\":\"uploaded\",\"digest\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1003\"}]}";
}
fn upgradeReordered() []const u8 {
    return "{\"id\":88,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
        "{\"id\":1003,\"name\":\"Maru-1.2.3-session-host-release.json\",\"size\":103,\"state\":\"uploaded\",\"digest\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1003\"}," ++
        "{\"id\":1002,\"name\":\"upgrade-evidence.json\",\"size\":102,\"state\":\"uploaded\",\"digest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1002\"}," ++
        "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1000\"}," ++
        "{\"id\":1001,\"name\":\"maru-session-host-1.2.3\",\"size\":101,\"state\":\"uploaded\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1001\"}]}";
}
