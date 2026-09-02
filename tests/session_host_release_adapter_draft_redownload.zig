const std = @import("std");
const c = std.c;
const redownload = @import("release_adapter_github_draft_asset_redownload");

const names = [_][]const u8{ "Maru-1.2.3-universal.dmg", "maru-session-host-1.2.3", "evidence.json", "manifest.json" };

fn assets() [4]redownload.ExpectedAsset {
    var result: [4]redownload.ExpectedAsset = undefined;
    for (&result, 0..) |*asset, index| asset.* = .{
        .id = 1000 + index,
        .name = names[index],
        .size = 100 + index,
        .sha256 = [_]u8{'a' + @as(u8, @intCast(index))} ** 64,
        .device = 7,
        .inode = 20 + index,
        .fd = 40 + @as(c.fd_t, @intCast(index)),
    };
    return result;
}

const Authority = struct {
    expected: [4]redownload.ExpectedAsset = assets(),
    calls: usize = 0,
    drift_after: ?usize = null,
    fail_at: ?usize = null,
    pub fn snapshot(self: *@This()) !redownload.Snapshot {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.OutOfMemory;
        var value = self.expected;
        if (self.drift_after) |call| {
            if (self.calls >= call) value[2].size += 1;
        }
        return .{ .release_id = 88, .cli_sha256 = [_]u8{'f'} ** 64, .assets = value };
    }
};

const Downloader = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    mismatch_at: ?usize = null,
    ids: [4]u64 = @splat(0),
    budgets: [4]i128 = @splat(0),
    pub fn download(self: *@This(), expected: redownload.ExpectedAsset, budget: i128) !redownload.ObservedAsset {
        const index = self.calls;
        self.calls += 1;
        self.ids[index] = expected.id;
        self.budgets[index] = budget;
        try std.testing.expectEqualStrings(names[index], expected.name);
        if (self.fail_at == index) return error.ChildFailed;
        var digest = expected.sha256;
        if (self.mismatch_at == index) digest[0] = '0';
        return .{ .id = expected.id, .size = expected.size, .sha256 = digest };
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

test "four exact asset ids redownload in canonical order and publish one owner" {
    var authority = Authority{};
    var downloader = Downloader{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
    var result: redownload.RedownloadValidation = .{};
    try redownload.testing_api.validate(&authority, &downloader, &deadline, &result);
    const view = result.value().?;
    try std.testing.expectEqual(@as(u64, 88), view.release_id);
    try std.testing.expectEqual([4]u64{ 1000, 1001, 1002, 1003 }, view.asset_ids);
    try std.testing.expectEqual([4]u64{ 1000, 1001, 1002, 1003 }, downloader.ids);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try result.deinit();
}

test "every child failure and foreign body publishes nothing" {
    inline for (0..4) |index| inline for (.{ true, false }) |child_failure| {
        var authority = Authority{};
        var downloader = Downloader{};
        if (child_failure) downloader.fail_at = index else downloader.mismatch_at = index;
        var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
        var result: redownload.RedownloadValidation = .{};
        const expected_error = if (child_failure) error.ChildFailed else error.ContentMismatch;
        try std.testing.expectError(expected_error, redownload.testing_api.validate(&authority, &downloader, &deadline, &result));
        try std.testing.expect(result.value() == null);
    };
}

test "authority drift and deadline publish nothing" {
    inline for (.{ 0, 1 }) |mode| {
        var authority = Authority{ .drift_after = if (mode == 0) 4 else null };
        var downloader = Downloader{};
        var deadline = Deadline{ .values = if (mode == 1) &.{ 100, 90, 0 } else &.{ 100, 90, 80, 70, 60, 50 } };
        var result: redownload.RedownloadValidation = .{};
        const expected_error = if (mode == 0) error.AuthorityChanged else error.TimedOut;
        try std.testing.expectError(expected_error, redownload.testing_api.validate(&authority, &downloader, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "every authority snapshot allocation failure publishes nothing" {
    inline for (1..11) |fail_at| {
        var authority = Authority{ .fail_at = fail_at };
        var downloader = Downloader{};
        var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
        var result: redownload.RedownloadValidation = .{};
        try std.testing.expectError(error.OutOfMemory, redownload.testing_api.validate(&authority, &downloader, &deadline, &result));
        try std.testing.expect(result.value() == null);
        try std.testing.expectEqual(redownload.State.empty, result.state());
    }
}

test "duplicate ids aliased inode and preowned result fail before download" {
    inline for (.{ 0, 1, 2 }) |mode| {
        var authority = Authority{};
        if (mode == 0) authority.expected[3].id = authority.expected[2].id;
        if (mode == 1) authority.expected[3].inode = authority.expected[2].inode;
        var downloader = Downloader{};
        var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60, 50 } };
        var result: redownload.RedownloadValidation = .{};
        if (mode == 2) result.status = .ready;
        try std.testing.expectError(if (mode == 2) error.InvalidOwner else error.AssetAlias, redownload.testing_api.validate(&authority, &downloader, &deadline, &result));
        try std.testing.expectEqual(@as(usize, 0), downloader.calls);
    }
}

test "production boundary instantiates" {
    redownload.assertProductionBoundary();
}

test "production downloader sends exact argv clean environment and hashes body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\set -eu
        \\test "$#" = 8
        \\test "$1|$2|$3|$4|$5" = 'api|--method|GET|--hostname|github.com'
        \\test "$6|$7" = '--header|Accept: application/octet-stream'
        \\test "$8" = 'repos/ohah/maru/releases/assets/1000'
        \\test "$GH_TOKEN" = token
        \\test "${HOME-unset}" = unset
        \\printf 'held-body'
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-gh", .data = script });
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try temporaryPath(&tmp, "fake-gh", &path_storage);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(path.ptr, 0o700));
    const expected = redownload.ExpectedAsset{ .id = 1000, .name = names[0], .size = 9, .sha256 = "f8428e9c98882ce1dddc7d92f54d011d06c60f44e7ac169aa39c76951abb9763".*, .device = 7, .inode = 20, .fd = 40 };
    const observed = try redownload.testing_api.download(std.testing.io, path, "token", expected, 5 * std.time.ns_per_s);
    try std.testing.expectEqual(expected.id, observed.id);
    try std.testing.expectEqual(expected.size, observed.size);
    try std.testing.expectEqual(expected.sha256, observed.sha256);
}

test "production downloader rejects short and oversized bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "short", .data = "#!/bin/sh\nprintf short" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long", .data = "#!/bin/sh\nprintf held-bodyX" });
    const expected = redownload.ExpectedAsset{ .id = 1000, .name = names[0], .size = 9, .sha256 = "f8428e9c98882ce1dddc7d92f54d011d06c60f44e7ac169aa39c76951abb9763".*, .device = 7, .inode = 20, .fd = 40 };
    inline for (.{ "short", "long" }) |leaf| {
        var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try temporaryPath(&tmp, leaf, &path_storage);
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(path.ptr, 0o700));
        const expected_error = if (std.mem.eql(u8, leaf, "short")) error.ContentMismatch else error.OutputTooLarge;
        try std.testing.expectError(expected_error, redownload.testing_api.download(std.testing.io, path, "token", expected, 5 * std.time.ns_per_s));
    }
}

fn temporaryPath(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..root_len], leaf });
}
