const std = @import("std");
const c = std.c;
const publication = @import("release_adapter_github_draft_publication");

const names = [_][]const u8{ "Maru-1.2.3-universal.dmg", "maru-session-host-1.2.3", "evidence.json", "manifest.json" };

fn expectedSnapshot() publication.Snapshot {
    var assets: [4]publication.Asset = undefined;
    for (&assets, 0..) |*asset, index| asset.* = .{ .id = 1000 + index, .name = names[index], .size = 100 + index, .sha256 = [_]u8{'a' + @as(u8, @intCast(index))} ** 64 };
    return .{ .release_id = 88, .tag = "v1.2.3", .source_commit = "0123456789abcdef0123456789abcdef01234567", .cli_sha256 = [_]u8{'f'} ** 64, .assets = assets };
}

const Authority = struct {
    value: publication.Snapshot = expectedSnapshot(),
    calls: usize = 0,
    drift_after: ?usize = null,
    fail_at: ?usize = null,
    pub fn snapshot(self: *@This()) !publication.Snapshot {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.OutOfMemory;
        var result = self.value;
        if (self.drift_after) |call| {
            if (self.calls >= call) result.assets[1].size += 1;
        }
        return result;
    }
};

const Mutator = struct {
    calls: usize = 0,
    fail: bool = false,
    foreign: bool = false,
    budget: i128 = 0,
    pub fn publish(self: *@This(), expected: publication.Snapshot, budget: i128) !publication.ObservedRelease {
        self.calls += 1;
        self.budget = budget;
        if (self.fail) return error.ChildFailed;
        var result = publication.testing_api.observe(expected);
        if (self.foreign) result.assets[2].sha256[0] = '0';
        return result;
    }
};

const Deadline = struct {
    values: []const i128,
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.Exhausted;
        const value = self.values[self.cursor];
        self.cursor += 1;
        if (value <= 0) return error.TimedOut;
        return value;
    }
};

test "exact draft mutation publishes one final-address release authority" {
    var authority = Authority{};
    var mutator = Mutator{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80 } };
    var result: publication.PublishedRelease = .{};
    try publication.testing_api.publish(&authority, &mutator, &deadline, &result);
    const value = result.value().?;
    try std.testing.expectEqual(@as(u64, 88), value.release_id);
    try std.testing.expectEqualStrings("v1.2.3", value.tag);
    try std.testing.expectEqual([_]u64{ 1000, 1001, 1002, 1003 }, value.asset_ids);
    try std.testing.expectEqual(publication.State.ready, result.state());
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit();
}

test "child failure and foreign response preserve terminal remote uncertainty" {
    inline for (.{ true, false }) |child_failure| {
        var authority = Authority{};
        var mutator = Mutator{ .fail = child_failure, .foreign = !child_failure };
        var deadline = Deadline{ .values = &.{ 100, 90, 80 } };
        var result: publication.PublishedRelease = .{};
        const expected = if (child_failure) error.ChildFailed else error.InvalidResponse;
        try std.testing.expectError(expected, publication.testing_api.publish(&authority, &mutator, &deadline, &result));
        try std.testing.expectEqual(publication.State.remote_state_unknown, result.state());
        try std.testing.expect(result.value() == null);
    }
}

test "post-response authority drift retains known release for audit" {
    var authority = Authority{ .drift_after = 3 };
    var mutator = Mutator{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80 } };
    var result: publication.PublishedRelease = .{};
    try std.testing.expectError(error.AuthorityChanged, publication.testing_api.publish(&authority, &mutator, &deadline, &result));
    try std.testing.expectEqual(publication.State.cleanup_required, result.state());
    try std.testing.expectEqual(@as(?u64, 88), result.cleanupId());
}

test "deadline before mutation stays empty and later expiry is terminal" {
    inline for (.{ true, false }) |before| {
        var authority = Authority{};
        var mutator = Mutator{};
        var deadline = Deadline{ .values = if (before) &.{0} else &.{ 100, 90, 0 } };
        var result: publication.PublishedRelease = .{};
        try std.testing.expectError(error.TimedOut, publication.testing_api.publish(&authority, &mutator, &deadline, &result));
        try std.testing.expectEqual(if (before) publication.State.empty else publication.State.cleanup_required, result.state());
        try std.testing.expectEqual(if (before) @as(usize, 0) else 1, mutator.calls);
    }
}

test "every authority snapshot allocation failure preserves the correct mutation state" {
    inline for (1..4) |fail_at| {
        var authority = Authority{ .fail_at = fail_at };
        var mutator = Mutator{};
        var deadline = Deadline{ .values = &.{ 100, 90, 80 } };
        var result: publication.PublishedRelease = .{};
        try std.testing.expectError(error.OutOfMemory, publication.testing_api.publish(&authority, &mutator, &deadline, &result));
        const after_mutation = fail_at == 3;
        try std.testing.expectEqual(if (after_mutation) publication.State.cleanup_required else publication.State.empty, result.state());
        try std.testing.expectEqual(if (after_mutation) @as(usize, 1) else 0, mutator.calls);
        try std.testing.expectEqual(if (after_mutation) @as(?u64, 88) else null, result.cleanupId());
        try std.testing.expect(result.value() == null);
    }
}

test "duplicate assets and preowned result fail before mutation" {
    inline for (.{ true, false }) |duplicate| {
        var authority = Authority{};
        if (duplicate) authority.value.assets[3].id = authority.value.assets[2].id;
        var mutator = Mutator{};
        var deadline = Deadline{ .values = &.{ 100, 90, 80 } };
        var result: publication.PublishedRelease = .{};
        if (!duplicate) result.status = .cleanup_required;
        try std.testing.expectError(if (duplicate) error.AssetAlias else error.InvalidOwner, publication.testing_api.publish(&authority, &mutator, &deadline, &result));
        try std.testing.expectEqual(@as(usize, 0), mutator.calls);
    }
}

test "strict published response binds immutable lifecycle and exact assets" {
    const expected = expectedSnapshot();
    const valid = validResponse();
    const observed = try publication.testing_api.parse(std.testing.allocator, valid, expected);
    try std.testing.expectEqual(@as(u64, 88), observed.release_id);
    inline for (.{
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"immutable\":true", "\"immutable\":false") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"draft\":false", "\"draft\":true") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"prerelease\":false", "\"prerelease\":true") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"tag_name\":\"v1.2.3\"", "\"tag_name\":\"v9.9.9\"") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"state\":\"uploaded\"", "\"state\":\"new\"") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"content_type\":\"application/octet-stream\"", "\"content_type\":\"text/plain\"") catch unreachable,
        std.mem.replaceOwned(u8, std.testing.allocator, valid, "\"id\":1002", "\"id\":9999") catch unreachable,
    }) |invalid| {
        defer std.testing.allocator.free(invalid);
        try std.testing.expectError(error.InvalidResponse, publication.testing_api.parse(std.testing.allocator, invalid, expected));
    }
}

test "published response parser unwinds every successful allocation path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAllocationPath, .{});
}

fn parseAllocationPath(allocator: std.mem.Allocator) !void {
    _ = try publication.testing_api.parse(allocator, validResponse(), expectedSnapshot());
}

fn validResponse() []const u8 {
    return "{\"id\":88,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"0123456789abcdef0123456789abcdef01234567\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
        "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"application/octet-stream\"}," ++
        "{\"id\":1001,\"name\":\"maru-session-host-1.2.3\",\"size\":101,\"state\":\"uploaded\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"content_type\":\"application/octet-stream\"}," ++
        "{\"id\":1002,\"name\":\"evidence.json\",\"size\":102,\"state\":\"uploaded\",\"digest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"content_type\":\"application/octet-stream\"}," ++
        "{\"id\":1003,\"name\":\"manifest.json\",\"size\":103,\"state\":\"uploaded\",\"digest\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"content_type\":\"application/octet-stream\"}]}";
}

test "production mutation sends exact argv and clean token environment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\set -eu
        \\test "$#" = 14
        \\test "$1|$2|$3|$4|$5" = 'api|--method|PATCH|--hostname|github.com'
        \\test "$6|$7" = '--header|Accept: application/vnd.github+json'
        \\test "$8|$9" = '--header|X-GitHub-Api-Version: 2022-11-28'
        \\test "${10}" = 'repos/ohah/maru/releases/88'
        \\test "${11}|${12}|${13}|${14}" = '-F|draft=false|-F|prerelease=false'
        \\test "$GH_TOKEN" = token
        \\test "${HOME-unset}" = unset
        \\printf '{}'
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-gh", .data = script });
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try temporaryPath(&tmp, "fake-gh", &path_storage);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(path.ptr, 0o700));
    // The executor test owns argv/environment. Semantic response coverage is the parser test above.
    try publication.testing_api.checkCommand(std.testing.io, path, "token", 88, 5 * std.time.ns_per_s);
}

fn temporaryPath(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..root_len], leaf });
}
