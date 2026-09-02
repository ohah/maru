const std = @import("std");
const c = std.c;
const draft_assets = @import("release_adapter_github_draft_asset_attachment");

const names = [_][]const u8{
    "Maru-1.2.3-universal.dmg",
    "maru-session-host-1.2.3",
    "Maru-1.2.3-session-host-evidence.json",
    "Maru-1.2.3-session-host-release.json",
};

fn expectedAssets() [4]draft_assets.ExpectedAsset {
    var result: [4]draft_assets.ExpectedAsset = undefined;
    for (&result, 0..) |*asset, index| asset.* = .{
        .name = names[index],
        .size = 100 + index,
        .sha256 = [_]u8{'a' + @as(u8, @intCast(index))} ** 64,
        .device = 7,
        .inode = 20 + index,
        .fd = 40 + @as(std.c.fd_t, @intCast(index)),
    };
    return result;
}

const Authority = struct {
    assets: [4]draft_assets.ExpectedAsset = expectedAssets(),
    release_id: u64 = 88,
    calls: usize = 0,
    drift_after: ?usize = null,

    pub fn snapshot(self: *@This()) !draft_assets.Snapshot {
        self.calls += 1;
        var assets = self.assets;
        if (self.drift_after) |call| {
            if (self.calls >= call) assets[2].size += 1;
        }
        return .{ .release_id = self.release_id, .cli_sha256 = [_]u8{'f'} ** 64, .assets = assets };
    }
};

const Uploader = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    foreign_at: ?usize = null,
    duplicate_at: ?usize = null,
    budgets: [4]i128 = @splat(0),
    fds: [4]std.c.fd_t = @splat(-1),

    pub fn upload(self: *@This(), release_id: u64, expected: draft_assets.ExpectedAsset, budget: i128) !draft_assets.ObservedAsset {
        const index = self.calls;
        self.calls += 1;
        try std.testing.expectEqual(@as(u64, 88), release_id);
        try std.testing.expectEqualStrings(names[index], expected.name);
        self.budgets[index] = budget;
        self.fds[index] = expected.fd;
        if (self.fail_at == index) return error.ChildFailed;
        return .{
            .id = if (self.duplicate_at == index) 1000 else 1000 + index,
            .name = if (self.foreign_at == index) "foreign" else expected.name,
            .size = expected.size,
            .state = .uploaded,
        };
    }
};

const Publisher = struct {
    fail: bool = false,
    calls: usize = 0,
    pub fn publish(self: *@This(), result: *draft_assets.DraftAssets) !void {
        self.calls += 1;
        if (self.fail) return error.PublishFailed;
        try draft_assets.testing_api.publish(result);
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

test "four held assets attach in canonical order and publish one owner" {
    var authority = Authority{};
    var uploader = Uploader{};
    var publisher = Publisher{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
    var result: draft_assets.DraftAssets = .{};
    try draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result);
    const view = result.value().?;
    try std.testing.expectEqual(@as(u64, 88), view.release_id);
    try std.testing.expectEqual(@as(usize, 4), view.assets.len);
    for (view.assets, 0..) |asset, index| {
        try std.testing.expectEqual(@as(u64, 1000 + index), asset.id);
        try std.testing.expectEqualStrings(names[index], asset.name);
        try std.testing.expectEqual(@as(std.c.fd_t, 40 + @as(std.c.fd_t, @intCast(index))), uploader.fds[index]);
    }
    try std.testing.expectEqual(draft_assets.State.ready, result.state());
    try result.deinit();
}

test "each child failure preserves terminal remote uncertainty and known prefix" {
    inline for (0..4) |fail_at| {
        var authority = Authority{};
        var uploader = Uploader{ .fail_at = fail_at };
        var publisher = Publisher{};
        var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
        var result: draft_assets.DraftAssets = .{};
        try std.testing.expectError(error.ChildFailed, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
        try std.testing.expectEqual(draft_assets.State.remote_state_unknown, result.state());
        try std.testing.expectEqual(@as(usize, fail_at), result.knownAssetIds().len);
        try std.testing.expect(result.value() == null);
    }
}

test "foreign and duplicate responses never become authority" {
    inline for (.{ true, false }) |foreign| {
        var authority = Authority{};
        var uploader = Uploader{};
        if (foreign) uploader.foreign_at = 2 else uploader.duplicate_at = 2;
        var publisher = Publisher{};
        var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
        var result: draft_assets.DraftAssets = .{};
        try std.testing.expectError(error.InvalidResponse, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
        try std.testing.expectEqual(draft_assets.State.remote_state_unknown, result.state());
        try std.testing.expectEqual(@as(usize, 2), result.knownAssetIds().len);
    }
}

test "final authority drift preserves four known remote assets for cleanup audit" {
    var authority = Authority{ .drift_after = 9 };
    var uploader = Uploader{};
    var publisher = Publisher{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
    var result: draft_assets.DraftAssets = .{};
    try std.testing.expectError(error.AuthorityChanged, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
    try std.testing.expectEqual(draft_assets.State.cleanup_required, result.state());
    try std.testing.expectEqual(@as(usize, 4), result.knownAssetIds().len);
}

test "publication failure does not erase attached asset ids" {
    var authority = Authority{};
    var uploader = Uploader{};
    var publisher = Publisher{ .fail = true };
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
    var result: draft_assets.DraftAssets = .{};
    try std.testing.expectError(error.PublishFailed, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
    try std.testing.expectEqual(draft_assets.State.cleanup_required, result.state());
    try std.testing.expectEqual(@as(usize, 4), result.knownAssetIds().len);
}

test "deadline before mutation stays empty while later expiry is terminal" {
    inline for (.{ true, false }) |before_first| {
        var authority = Authority{};
        var uploader = Uploader{};
        var publisher = Publisher{};
        var deadline = Deadline{ .values = if (before_first) &.{0} else &.{ 100, 90, 0 } };
        var result: draft_assets.DraftAssets = .{};
        try std.testing.expectError(error.TimedOut, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
        try std.testing.expectEqual(if (before_first) draft_assets.State.empty else draft_assets.State.cleanup_required, result.state());
        try std.testing.expectEqual(if (before_first) @as(usize, 0) else 1, result.knownAssetIds().len);
        if (before_first) try std.testing.expectEqual(@as(u64, 0), result.release_id);
    }
}

test "preowned result and aliased inode set fail before upload" {
    var authority = Authority{};
    authority.assets[3].inode = authority.assets[2].inode;
    var uploader = Uploader{};
    var publisher = Publisher{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
    var result: draft_assets.DraftAssets = .{};
    try std.testing.expectError(error.AssetAlias, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
    try std.testing.expectEqual(@as(usize, 0), uploader.calls);
    result.status = .cleanup_required;
    try std.testing.expectError(error.InvalidOwner, draft_assets.testing_api.attach(&authority, &uploader, &publisher, &deadline, &result));
}

test "production attachment boundary instantiates" {
    draft_assets.assertProductionBoundary();
}

test "upload response binds digest content type and canonical fields" {
    const expected = expectedAssets()[0];
    const valid = "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"application/octet-stream\"}";
    const observed = try draft_assets.testing_api.parse(std.testing.allocator, valid, expected);
    try std.testing.expectEqual(@as(u64, 1000), observed.id);
    for ([_][]const u8{
        "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"content_type\":\"application/octet-stream\"}",
        "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"new\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"application/octet-stream\"}",
        "{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"content_type\":\"text/plain\"}",
    }) |invalid| try std.testing.expectError(error.InvalidResponse, draft_assets.testing_api.parse(std.testing.allocator, invalid, expected));
}

test "upload endpoint name encoding cannot inject a query" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings("asset%20name%3Fx%3D1%26y%3D2", try draft_assets.testing_api.encode(&storage, "asset name?x=1&y=2"));
}

test "production uploader sends exact argv environment and held fd body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\set -eu
        \\test "$#" = 14
        \\test "$1|$2|$3|$4|$5" = 'api|--method|POST|--hostname|uploads.github.com'
        \\test "$6|$7" = '--header|Accept: application/vnd.github+json'
        \\test "$8|$9" = '--header|X-GitHub-Api-Version: 2022-11-28'
        \\test "${10}|${11}|${12}|${13}" = '--header|Content-Type: application/octet-stream|--input|-'
        \\test "${14}" = 'repos/ohah/maru/releases/88/assets?name=asset%20name%3Fx%3D1'
        \\test "$GH_TOKEN" = token
        \\test "${HOME-unset}" = unset
        \\test "$(/bin/cat)" = held-body
        \\printf '%s' '{"id":1000,"name":"asset name?x=1","size":9,"state":"uploaded","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","content_type":"application/octet-stream"}'
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-gh", .data = script });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "body", .data = "held-body" });
    var executable_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var body_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const executable = try temporaryPath(&tmp, "fake-gh", &executable_storage);
    const body = try temporaryPath(&tmp, "body", &body_storage);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(executable.ptr, 0o700));
    const fd = c.open(body.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    try std.testing.expect(fd >= 3);
    defer _ = c.close(fd);
    var expected = expectedAssets()[0];
    expected.name = "asset name?x=1";
    expected.size = 9;
    expected.fd = fd;
    var output: [1024]u8 = undefined;
    const observed = try draft_assets.testing_api.upload(std.testing.io, std.testing.allocator, executable, "token", &output, expected, 5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 1000), observed.id);
}

fn temporaryPath(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..root_len], leaf });
}
