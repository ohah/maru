//! Authenticated current manifest의 local DMG와 frozen executable을 한 제품 관측으로 결속한다.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const apple = @import("release_adapter_apple_product");
const current_input = @import("release_adapter_github_current_manifest_input");
const manifest_file = @import("release_adapter_github_manifest_file");
const product = @import("release_adapter_github_current_product");

const frozen_name = "maru-macos-app";
const dmg_name = "Maru.dmg";
const frozen_bytes = "current frozen executable bytes";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const requirement_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

fn digest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

fn manifestValue(assets: []const manifest.Asset) manifest.Manifest {
    return .{
        .schema = manifest.schema,
        .role = .b,
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
        .signing = .{
            .bundle_id = "dev.maru.apphost",
            .bundle_short_version = "1.2.3",
            .bundle_version = "1",
            .team_id = "TEAMID1234",
            .designated_requirement_sha256 = requirement_sha,
            .architectures = &.{ "arm64", "x86_64" },
            .notarization = "accepted",
            .stapled = true,
        },
        .assets = assets,
        .evidence = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
        .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" },
    };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    current: current_input.CurrentManifestInput = .{},
    frozen_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    dmg_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    dmg_work: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_work: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_sha: [64]u8 = @splat(0),
    assets: [3]manifest.Asset = undefined,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = frozen_name, .data = frozen_bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = "fixture dmg" });
        _ = try absolute(&self.tmp, frozen_name, &self.frozen_path);
        _ = try absolute(&self.tmp, dmg_name, &self.dmg_path);
        _ = try absolute(&self.tmp, "dmg-work", &self.dmg_work);
        const manifest_work_path = try absolute(&self.tmp, "manifest-work", &self.manifest_work);
        if (c.chmod(self.frozen_path[0..].ptr, 0o755) != 0) return error.FixtureFailed;

        self.frozen_sha = digest(frozen_bytes);
        self.assets = .{
            .{ .role = .universal_dmg, .name = dmg_name, .sha256 = dmg_sha, .size = 4096 },
            .{ .role = .frozen_product_executable, .name = frozen_name, .sha256 = &self.frozen_sha, .size = frozen_bytes.len },
            .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1024 },
        };
        const value = manifestValue(&self.assets);
        const bytes = try manifest.writeCanonical(allocator, value);
        errdefer allocator.free(bytes);
        var sha_raw: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &sha_raw, .{});
        const manifest_sha: [64]u8 = std.fmt.bytesToHex(sha_raw, .lower);
        try manifest_file.materialize(&self.current.file, manifest_work_path, .{
            .name = "Maru-1.2.3-session-host-release.json",
            .sha256 = &manifest_sha,
            .bytes = bytes,
        });
        self.current.input = .{
            .bytes = bytes,
            .size = bytes.len,
            .mode = 0o100400,
            .sha256 = manifest_sha,
            .identity = .{ .device = 1, .inode = 1 },
        };
        self.current.authenticated.parsed = try manifest.parseCanonical(allocator, bytes);
        self.current.authenticated.owner = &self.current.authenticated;
        self.current.owner = &self.current;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.current.deinit(allocator) catch {};
        self.tmp.cleanup();
    }

    fn paths(self: *Fixture) product.Paths {
        return .{
            .dmg = std.mem.sliceTo(&self.dmg_path, 0),
            .dmg_work = std.mem.sliceTo(&self.dmg_work, 0),
            .frozen_executable = std.mem.sliceTo(&self.frozen_path, 0),
        };
    }
};

const Observer = struct {
    calls: usize = 0,
    executable_sha256: [64]u8,
    team_id: []const u8 = "TEAMID1234",
    fail: bool = false,
    mutate: ?[:0]const u8 = null,

    pub fn observe(self: *Observer, allocator: std.mem.Allocator, _: std.Io, paths: product.Paths, expected: product.DmgExpected, version: []const u8, _: i128) !apple.Observed {
        self.calls += 1;
        try std.testing.expectEqualStrings(dmg_name, std.fs.path.basename(paths.dmg));
        try std.testing.expectEqual(@as(u64, 4096), expected.size);
        try std.testing.expectEqualStrings(dmg_sha, &expected.sha256);
        try std.testing.expectEqualStrings("1.2.3", version);
        if (self.mutate) |path| {
            const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
            if (fd < 0) return error.FixtureFailed;
            defer _ = c.close(fd);
            const changed = [_]u8{'X'};
            if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.FixtureFailed;
        }
        if (self.fail) return error.ObserverFailed;
        var result: apple.Observed = undefined;
        result.executable_sha256 = self.executable_sha256;
        result.requirement_sha256 = comptime blk: {
            var out: [64]u8 = undefined;
            @memcpy(&out, requirement_sha);
            break :blk out;
        };
        result.bundle_id = try allocator.dupe(u8, "dev.maru.apphost");
        errdefer allocator.free(result.bundle_id);
        result.bundle_short_version = try allocator.dupe(u8, "1.2.3");
        errdefer allocator.free(result.bundle_short_version);
        result.bundle_version = try allocator.dupe(u8, "1");
        errdefer allocator.free(result.bundle_version);
        result.team_id = try allocator.dupe(u8, self.team_id);
        return result;
    }
};

test "authenticated current manifest publishes one revalidated local product" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var observer = Observer{ .executable_sha256 = digest(frozen_bytes) };
    var result: product.CurrentProduct = .{};
    try product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1_000_000_000, &result);
    defer result.deinit(std.testing.allocator) catch {};
    const view = try result.revalidate(fixture.paths().frozen_executable);
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expectEqualStrings(&digest(frozen_bytes), &view.frozen.sha256);
    try std.testing.expectEqualStrings(&digest(frozen_bytes), view.apple.executableSha256());
}

test "unauthenticated copied and preowned owners reach no observer" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var observer = Observer{ .executable_sha256 = digest(frozen_bytes) };
    var result: product.CurrentProduct = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    result = .{};
    var copied = fixture.current;
    try std.testing.expectError(error.InvalidCurrent, product.observeWith(&observer, std.testing.allocator, std.testing.io, &copied, fixture.paths(), 1, &result));
    fixture.current.owner = null;
    try std.testing.expectError(error.InvalidCurrent, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    fixture.current.owner = &fixture.current;
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
}

test "relative wrong basename and aliased paths fail before pin or observer" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var observer = Observer{ .executable_sha256 = digest(frozen_bytes) };
    var result: product.CurrentProduct = .{};
    var paths = fixture.paths();
    paths.dmg = "Maru.dmg";
    try std.testing.expectError(error.InvalidPath, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, paths, 1, &result));
    paths = fixture.paths();
    paths.dmg = paths.frozen_executable;
    try std.testing.expectError(error.InvalidPath, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, paths, 1, &result));
    paths = fixture.paths();
    paths.dmg = paths.dmg_work;
    try std.testing.expectError(error.InvalidPath, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, paths, 1, &result));
    try fixture.tmp.dir.deleteFile(std.testing.io, dmg_name);
    try fixture.tmp.dir.hardLink(frozen_name, fixture.tmp.dir, dmg_name, std.testing.io, .{});
    paths = fixture.paths();
    try std.testing.expectError(error.InvalidPath, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, paths, 1, &result));
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
}

test "DMG executable digest and Apple signing mismatch publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var bad_digest = digest(frozen_bytes);
    bad_digest[0] = if (bad_digest[0] == '0') '1' else '0';
    var observer = Observer{ .executable_sha256 = bad_digest };
    var result: product.CurrentProduct = .{};
    const parsed_assets = @constCast(fixture.current.value().?.manifest.assets);
    const original_dmg_size = parsed_assets[0].size;
    parsed_assets[0].size = files.max_release_asset_bytes + 1;
    try std.testing.expectError(error.InvalidAsset, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    parsed_assets[0].size = original_dmg_size;
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    try std.testing.expectError(error.ProductMismatch, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    try std.testing.expect(result.value() == null);
    observer = .{ .executable_sha256 = digest(frozen_bytes), .team_id = "FOREIGN1234" };
    try std.testing.expectError(error.ProductMismatch, product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    try std.testing.expect(result.value() == null);
}

test "observer failure and concurrent frozen mutation leave no product owner" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: product.CurrentProduct = .{};
    var failing = Observer{ .executable_sha256 = digest(frozen_bytes), .fail = true };
    try std.testing.expectError(error.ObserverFailed, product.observeWith(&failing, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    try std.testing.expect(result.value() == null);
    for (0..4) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var allocating = Observer{ .executable_sha256 = digest(frozen_bytes) };
        try std.testing.expectError(error.OutOfMemory, product.observeWith(&allocating, failing_allocator.allocator(), std.testing.io, &fixture.current, fixture.paths(), 1, &result));
        try std.testing.expect(result.value() == null);
    }
    var mutating = Observer{ .executable_sha256 = digest(frozen_bytes), .mutate = fixture.paths().frozen_executable };
    try std.testing.expectError(error.FrozenChanged, product.observeWith(&mutating, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result));
    try std.testing.expect(result.value() == null);
}

test "current product result is final-address move-only and cleanup exact once" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var observer = Observer{ .executable_sha256 = digest(frozen_bytes) };
    var result: product.CurrentProduct = .{};
    try product.observeWith(&observer, std.testing.allocator, std.testing.io, &fixture.current, fixture.paths(), 1, &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit(std.testing.allocator));
    try result.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidOwner, result.deinit(std.testing.allocator));
}
