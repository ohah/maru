//! Contract tests for exact-ID current Release asset downloads.

const std = @import("std");
const c = std.c;
const assets = @import("release_adapter_remote_release_assets");
const fence_mod = @import("release_adapter_remote_release_fence");
const context_mod = @import("release_adapter_context");
const deadline_mod = @import("release_adapter_deadline");
const cli_authority = @import("release_adapter_github_cli_authority");

const source = "0123456789abcdef0123456789abcdef01234567";
const contents = [_][]const u8{ "dmg", "host", "evidence", "manifest" };

test "four exact-ID downloads publish immutable held assets in canonical role order" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    const view = fixture.result.value().?;
    try std.testing.expectEqual(@as(usize, 4), view.assets.len);
    try std.testing.expectEqual(@as(usize, 4), fixture.ops.downloads);
    try std.testing.expectEqual(@as(usize, 8), fixture.ops.revalidations);
    try std.testing.expect(fixture.ops.shape_ok);
    for (fixture.ops.budgets[1..], fixture.ops.budgets[0 .. fixture.ops.budgets.len - 1]) |later, earlier|
        try std.testing.expect(later < earlier);
    var copied = fixture.result;
    try std.testing.expect(copied.value() == null);
    copied.file_count = 99;
    try std.testing.expect(copied.value() == null);
    for (view.assets, 0..) |asset, index| {
        try std.testing.expectEqual(@as(u64, 1000 + index), asset.id);
        try std.testing.expectEqual(@as(u64, contents[index].len), asset.size);
        const fd = try fixture.result.openAssetDescriptor(@enumFromInt(index));
        defer _ = c.close(fd);
    }
}

test "short long digest and child failures publish nothing and remove workspace" {
    inline for (.{ Failure.short, .long, .digest, .child }) |failure| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.ops.failure = failure;
        try std.testing.expectError(if (failure == .child) error.ChildFailed else error.ContentMismatch, fixture.run());
        try std.testing.expect(fixture.result.value() == null);
        try std.testing.expect(!try pathExists(fixture.workspace()));
    }
}

test "CLI drift at every child fence is fail closed and residue free" {
    for (1..9) |failure| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.ops.fail_revalidate_at = failure;
        try std.testing.expectError(error.ExecutableChanged, fixture.run());
        try std.testing.expect(fixture.result.value() == null);
        try std.testing.expect(!try pathExists(fixture.workspace()));
    }
}

test "copied preowned and exchanged authority cannot download" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var copied = fixture.fence;
    try fixture.startDeadline();
    try std.testing.expectError(error.InvalidFence, assets.downloadUntilWith(&fixture.ops, std.testing.allocator, &copied, fixture.cli(), "token", fixture.workspace(), &fixture.deadline, &fixture.result));
    fixture.result.owner = &fixture.result;
    try std.testing.expectError(error.InvalidOwner, assets.downloadUntilWith(&fixture.ops, std.testing.allocator, &fixture.fence, fixture.cli(), "token", fixture.workspace(), &fixture.deadline, &fixture.result));
    try std.testing.expectEqual(@as(usize, 0), fixture.ops.downloads);

    var alias_storage: [@sizeOf(assets.Assets)]u8 align(@alignOf(deadline_mod.Deadline)) = @splat(0);
    const aliased_result: *assets.Assets = @ptrCast(&alias_storage);
    const aliased_deadline: *deadline_mod.Deadline = @ptrCast(&alias_storage);
    try std.testing.expectError(error.InvalidOwner, assets.downloadUntilWith(&fixture.ops, std.testing.allocator, &fixture.fence, fixture.cli(), "token", fixture.workspace(), aliased_deadline, aliased_result));
}

test "fence mutation before a child prevents all downloads" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.fence.before.release_id += 1;
    try std.testing.expectError(error.InvalidFence, fixture.run());
    try std.testing.expectEqual(@as(usize, 0), fixture.ops.downloads);
    fixture.fence.before.release_id -= 1;
}

test "production transport runs four exact clean-environment children into held files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const script =
        "#!/bin/sh\n" ++
        "test \"$GH_TOKEN\" = token || exit 71\n" ++
        "test \"$GH_PROMPT_DISABLED\" = 1 || exit 72\n" ++
        "test -z \"${HOME+x}\" || exit 73\n" ++
        "case \"$*\" in\n" ++
        "  *releases/assets/1000) /usr/bin/printf dmg ;;\n" ++
        "  *releases/assets/1001) /usr/bin/printf host ;;\n" ++
        "  *releases/assets/1002) /usr/bin/printf evidence ;;\n" ++
        "  *releases/assets/1003) /usr/bin/printf manifest ;;\n" ++
        "  *) exit 74 ;;\n" ++
        "esac\n";
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-gh", .data = script });
    var cli_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = try temporaryPath(&fixture.tmp, "fake-gh", &cli_path_storage);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(cli_path.ptr, 0o700));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    fixture.pinned = try cli_authority.pin(std.testing.allocator, cli_path, &hex);
    try assets.downloadUntil(std.testing.io, std.testing.allocator, &fixture.fence, .{ .path = cli_path, .pinned = &fixture.pinned }, "token", fixture.workspace(), &fixture.deadline, &fixture.result);
    try std.testing.expect(fixture.result.value() != null);
}

test "successful owner revalidation detects pathname replacement and cleanup preserves foreign file" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    const first = fixture.result.value().?.assets[0];
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(first.path.ptr));
    const replacement = c.open(first.path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    try std.testing.expect(replacement >= 0);
    _ = c.close(replacement);
    try std.testing.expectError(error.FileChanged, fixture.result.revalidate());
    try std.testing.expectError(error.CleanupFailed, fixture.result.deinit());
    try std.testing.expect(try pathExists(first.path));
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(first.path.ptr));
}

test "hardlink replacement cannot alias two asset roles or delete the foreign name" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.run();
    const view = fixture.result.value().?;
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(view.assets[0].path.ptr));
    try fixture.tmp.dir.hardLink("remote-assets/maru-session-host-1.2.3", fixture.tmp.dir, "remote-assets/Maru-1.2.3-universal.dmg", std.testing.io, .{});
    try std.testing.expectError(error.FileChanged, fixture.result.revalidate());
    try std.testing.expectError(error.CleanupFailed, fixture.result.deinit());
    try std.testing.expect(try pathExists(view.assets[0].path));
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(view.assets[0].path.ptr));
}

const Failure = enum { none, short, long, digest, child };

const DownloadOps = struct {
    downloads: usize = 0,
    revalidations: usize = 0,
    fail_revalidate_at: usize = 0,
    failure: Failure = .none,
    shape_ok: bool = true,
    budgets: [4]i128 = @splat(0),

    pub fn revalidateCli(self: *@This(), _: std.mem.Allocator, _: [:0]const u8, _: *const assets.PinnedExecutable) !void {
        self.revalidations += 1;
        if (self.revalidations == self.fail_revalidate_at) return error.ExecutableChanged;
    }

    pub fn download(self: *@This(), _: [:0]const u8, token: []const u8, args: []const []const u8, fd: c.fd_t, expected_size: u64, budget: i128) !@import("bounded_process").Digest {
        const index = self.downloads;
        self.downloads += 1;
        self.budgets[index] = budget;
        var endpoint: [96]u8 = undefined;
        const expected_endpoint = try std.fmt.bufPrint(&endpoint, "repos/ohah/maru/releases/assets/{d}", .{1000 + index});
        self.shape_ok = self.shape_ok and std.mem.eql(u8, token, "token") and args.len == 8 and
            std.mem.eql(u8, args[0], "api") and std.mem.eql(u8, args[1], "--method") and std.mem.eql(u8, args[2], "GET") and
            std.mem.eql(u8, args[3], "--hostname") and std.mem.eql(u8, args[4], "github.com") and
            std.mem.eql(u8, args[5], "--header") and std.mem.eql(u8, args[6], "Accept: application/octet-stream") and
            std.mem.eql(u8, args[7], expected_endpoint);
        if (self.failure == .child) return error.ChildFailed;
        const expected = contents[index];
        const bytes = if (self.failure == .short) expected[0 .. expected.len - 1] else expected;
        var used: usize = 0;
        while (used < bytes.len) {
            const count = c.write(fd, bytes[used..].ptr, bytes.len - used);
            if (count <= 0) return error.CaptureFailed;
            used += @intCast(count);
        }
        if (self.failure == .long) {
            const extra = "x";
            _ = c.write(fd, extra.ptr, extra.len);
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var result: @import("bounded_process").Digest = .{ .size = if (self.failure == .long) expected_size + 1 else bytes.len, .sha256 = std.fmt.bytesToHex(digest, .lower) };
        if (self.failure == .digest) result.sha256[0] ^= 1;
        return result;
    }
};

const FenceOps = struct {
    response: []const u8,
    pub fn revalidate(_: *@This(), _: std.mem.Allocator, _: [:0]const u8, _: *const fence_mod.PinnedExecutable) !void {}
    pub fn capture(self: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, output: []u8, _: i128) ![]const u8 {
        @memcpy(output[0..self.response.len], self.response);
        return output[0..self.response.len];
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    metadata: []u8,
    workspace_storage: [std.fs.max_path_bytes:0]u8,
    workspace_len: usize,
    fence: fence_mod.Fence = .{},
    deadline: deadline_mod.Deadline = .{},
    pinned: assets.PinnedExecutable = undefined,
    response: [64 * 1024]u8 = undefined,
    ops: DownloadOps = .{},
    result: assets.Assets = .{},

    fn init(self: *@This()) !void {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const metadata = try makeMetadata(std.testing.allocator);
        errdefer std.testing.allocator.free(metadata);
        var workspace_storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const workspace_path = try temporaryPath(&tmp, "remote-assets", &workspace_storage);
        self.* = .{ .tmp = tmp, .metadata = metadata, .workspace_storage = workspace_storage, .workspace_len = workspace_path.len };
        @memset(std.mem.asBytes(&self.pinned), 0);
        try deadline_mod.start(10 * std.time.ns_per_s, &self.deadline);
        var fence_ops = FenceOps{ .response = metadata };
        try fence_mod.beginUntilWith(&fence_ops, &fence_ops, &self.deadline, std.testing.allocator, context(), "/fake-gh", &self.pinned, "token", &self.response, &self.fence);
    }
    fn startDeadline(self: *@This()) !void {
        _ = try self.deadline.remaining();
    }
    fn cli(self: *@This()) assets.Cli {
        return .{ .path = "/fake-gh", .pinned = &self.pinned };
    }
    fn workspace(self: *@This()) [:0]const u8 {
        return self.workspace_storage[0..self.workspace_len :0];
    }
    fn run(self: *@This()) !void {
        try assets.downloadUntilWith(&self.ops, std.testing.allocator, &self.fence, self.cli(), "token", self.workspace(), &self.deadline, &self.result);
    }
    fn deinit(self: *@This()) void {
        if (self.result.value() != null) self.result.deinit() catch {};
        if (self.fence.candidate() != null or self.fence.value() != null) self.fence.deinit() catch {};
        if (self.deadline.owner == &self.deadline) self.deadline.deinit() catch {};
        std.testing.allocator.free(self.metadata);
        self.tmp.cleanup();
    }
};

fn context() context_mod.Context {
    return .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = source, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };
}

fn makeMetadata(allocator: std.mem.Allocator) ![]u8 {
    var sha: [contents.len][64]u8 = undefined;
    for (contents, 0..) |bytes, index| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        sha[index] = std.fmt.bytesToHex(digest, .lower);
    }
    return std.fmt.allocPrint(allocator, "{{\"id\":88,\"tag_name\":\"v1.2.3\",\"target_commitish\":\"{s}\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
        "{{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":{d},\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1000\"}}," ++
        "{{\"id\":1001,\"name\":\"maru-session-host-1.2.3\",\"size\":{d},\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1001\"}}," ++
        "{{\"id\":1002,\"name\":\"baseline-evidence.json\",\"size\":{d},\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1002\"}}," ++
        "{{\"id\":1003,\"name\":\"Maru-1.2.3-session-host-release.json\",\"size\":{d},\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1003\"}}]}}", .{ source, contents[0].len, &sha[0], contents[1].len, &sha[1], contents[2].len, &sha[2], contents[3].len, &sha[3] });
}

fn temporaryPath(tmp: *std.testing.TmpDir, name: []const u8, storage: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..root_len], name });
}

fn pathExists(path: [:0]const u8) !bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
