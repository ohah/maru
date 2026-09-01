//! Current release의 세 asset을 attestation child가 읽을 immutable private leaves로 고정하는지 검증한다.
//!
//! 실제 사용자 release/session 경로 대신 test-owned temporary directory와 real fd를 사용한다.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const evidence_mod = @import("release_evidence");
const files = @import("release_adapter_files");
const apple = @import("release_adapter_apple_product");
const current_input = @import("release_adapter_github_current_manifest_input");
const current_product = @import("release_adapter_github_current_product");
const current_evidence = @import("release_adapter_github_current_evidence");
const composition = @import("release_adapter_github_current_asset_files");

const dmg_name = "Maru-1.2.3.dmg";
const frozen_name = "maru-1.2.3";
const summary_name = "evidence.json";
const dmg_bytes = "current dmg bytes";
const frozen_bytes = "current frozen executable bytes";
const uuid = "123e4567-e89b-42d3-a456-426614174000";
const predecessor_exe_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const requirement_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const predecessor_manifest_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

fn sha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn upgradeLeaf(allocator: std.mem.Allocator, count: u64, frozen_sha: []const u8) ![]u8 {
    const set_sha = if (count == 1)
        "1111111111111111111111111111111111111111111111111111111111111111"
    else
        "2222222222222222222222222222222222222222222222222222222222222222";
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n",
        .{ uuid, predecessor_exe_sha, frozen_sha, requirement_sha, count, set_sha },
    );
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], leaf });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    current: current_input.CurrentManifestInput = .{},
    product: current_product.CurrentProduct = .{},
    evidence: current_evidence.CurrentEvidence = .{},
    assets: [3]manifest.Asset = undefined,
    dmg_sha: [64]u8 = undefined,
    frozen_sha: [64]u8 = undefined,
    summary_sha: [64]u8 = undefined,
    dmg_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        self.dmg_sha = sha256(dmg_bytes);
        self.frozen_sha = sha256(frozen_bytes);
        const common: evidence_mod.Common = .{
            .test_uuid = uuid,
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
            .candidate = .{ .dmg_sha256 = &self.dmg_sha, .executable_sha256 = &self.frozen_sha },
        };
        const predecessor: evidence_mod.Predecessor = .{
            .release_id = 76,
            .tag = "v1.2.2",
            .commit = "3333333333333333333333333333333333333333",
            .manifest_sha256 = predecessor_manifest_sha,
            .dmg_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .executable_sha256 = predecessor_exe_sha,
        };
        const one = try upgradeLeaf(allocator, 1, &self.frozen_sha);
        defer allocator.free(one);
        const many = try upgradeLeaf(allocator, evidence_mod.near_max_runtime_count, &self.frozen_sha);
        defer allocator.free(many);
        const summary_bytes = try evidence_mod.assembleUpgrade(allocator, common, predecessor, one, many);
        defer allocator.free(summary_bytes);
        self.summary_sha = sha256(summary_bytes);

        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = dmg_bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = frozen_name, .data = frozen_bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = summary_name, .data = summary_bytes });
        const dmg_path = try absolute(&self.tmp, dmg_name, &self.dmg_path);
        const frozen_path = try absolute(&self.tmp, frozen_name, &self.frozen_path);
        _ = try absolute(&self.tmp, "private-assets", &self.work_path);
        if (c.chmod(frozen_path.ptr, 0o755) != 0) return error.FixtureFailed;

        self.assets = .{
            .{ .role = .universal_dmg, .name = dmg_name, .sha256 = &self.dmg_sha, .size = dmg_bytes.len },
            .{ .role = .frozen_product_executable, .name = frozen_name, .sha256 = &self.frozen_sha, .size = frozen_bytes.len },
            .{ .role = .evidence_summary, .name = summary_name, .sha256 = &self.summary_sha, .size = summary_bytes.len },
        };
        const value: manifest.Manifest = .{
            .schema = manifest.schema,
            .role = .b,
            .repository = .{ .id = common.repository.id, .owner = common.repository.owner, .name = common.repository.name },
            .release = .{ .id = common.release.id, .tag = common.release.tag, .version = common.release.version },
            .source = .{ .commit = common.source.commit, .tree = common.source.tree },
            .build = .{ .workflow_ref = common.build.workflow_ref, .run_id = common.build.run_id, .run_attempt = common.build.run_attempt },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "dev.maru.apphost", .bundle_short_version = "1.2.3", .bundle_version = "1", .team_id = "TEAMID1234", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &self.assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = summary_name, .summary_sha256 = &self.summary_sha, .result = "passed" },
            .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha },
        };
        const manifest_bytes = try manifest.writeCanonical(allocator, value);
        self.current.input = .{ .bytes = manifest_bytes, .size = manifest_bytes.len, .mode = 0o100400, .sha256 = sha256(manifest_bytes), .identity = .{ .device = 900, .inode = 901 } };
        self.current.authenticated.parsed = try manifest.parseCanonical(allocator, manifest_bytes);
        self.current.authenticated.owner = &self.current.authenticated;
        self.current.owner = &self.current;

        try files.pinExecutable(&self.product.frozen, frozen_path, .{ .size = frozen_bytes.len, .sha256 = self.frozen_sha }, files.max_release_asset_bytes);
        self.product.apple_observed = try fakeApple(allocator, self.frozen_sha);
        self.product.owner = &self.product;

        self.evidence.input = try files.readInputAlloc(allocator, try absolute(&self.tmp, summary_name, &self.work_path), evidence_mod.max_evidence_bytes);
        self.evidence.parsed = try evidence_mod.parseCanonical(allocator, self.evidence.input.?.bytes);
        self.evidence.owner = &self.evidence;
        _ = dmg_path;
        _ = try absolute(&self.tmp, "private-assets", &self.work_path);
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.evidence.deinit(allocator) catch {};
        self.product.deinit(allocator) catch {};
        self.current.deinit(allocator) catch {};
        self.tmp.cleanup();
    }

    fn paths(self: *Fixture) composition.Paths {
        return .{
            .dmg = std.mem.sliceTo(&self.dmg_path, 0),
            .frozen_executable = std.mem.sliceTo(&self.frozen_path, 0),
            .workdir = std.mem.sliceTo(&self.work_path, 0),
        };
    }
};

fn fakeApple(allocator: std.mem.Allocator, frozen_sha: [64]u8) !apple.Observed {
    const bundle_id = try allocator.dupe(u8, "dev.maru.apphost");
    errdefer allocator.free(bundle_id);
    const short_version = try allocator.dupe(u8, "1.2.3");
    errdefer allocator.free(short_version);
    const bundle_version = try allocator.dupe(u8, "1");
    errdefer allocator.free(bundle_version);
    const team_id = try allocator.dupe(u8, "TEAMID1234");
    var requirement: [64]u8 = undefined;
    @memcpy(&requirement, requirement_sha);
    return .{ .executable_sha256 = frozen_sha, .bundle_id = bundle_id, .bundle_short_version = short_version, .bundle_version = bundle_version, .team_id = team_id, .requirement_sha256 = requirement };
}

test "three authenticated assets publish exact immutable private leaves" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentAssetFiles = .{};
    try composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result);
    const view = result.value() orelse return error.TestUnexpectedResult;
    for ([_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary }) |role| {
        const observed = view.asset(role) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 0o100400), observed.mode & 0o170777);
        try std.testing.expectEqualStrings(assetFor(&fixture.assets, role).?.name, std.fs.path.basename(observed.path));
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, observed.path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(assetFor(&fixture.assets, role).?.sha256, &sha256(bytes));
    }
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, fixture.paths().workdir, .{}));
}

test "copied unauthenticated and preowned owners publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentAssetFiles = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    result = .{};
    var copied_current = fixture.current;
    try std.testing.expectError(error.InvalidCurrent, composition.compose(&copied_current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    var copied_product = fixture.product;
    try std.testing.expectError(error.InvalidProduct, composition.compose(&fixture.current, &copied_product, &fixture.evidence, fixture.paths(), &result));
    var copied_evidence = fixture.evidence;
    try std.testing.expectError(error.InvalidEvidence, composition.compose(&fixture.current, &fixture.product, &copied_evidence, fixture.paths(), &result));
    try std.testing.expect(result.value() == null);
}

test "path role size digest and source alias drift publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentAssetFiles = .{};
    var paths = fixture.paths();
    paths.dmg = "relative.dmg";
    try std.testing.expectError(error.InvalidPath, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, paths, &result));
    paths = fixture.paths();
    paths.frozen_executable = "relative-frozen";
    try std.testing.expectError(error.InvalidPath, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, paths, &result));
    paths = fixture.paths();
    paths.workdir = "relative-workdir";
    try std.testing.expectError(error.InvalidPath, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, paths, &result));
    const parsed_assets = @constCast(fixture.current.value().?.manifest.assets);
    parsed_assets[0].size += 1;
    try std.testing.expectError(error.InvalidAsset, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    parsed_assets[0].size -= 1;
    parsed_assets[0].sha256 = requirement_sha;
    try std.testing.expectError(error.InvalidAsset, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    parsed_assets[0].sha256 = &fixture.dmg_sha;
    parsed_assets[0].role = .evidence_summary;
    try std.testing.expectError(error.InvalidAsset, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    try std.testing.expect(result.value() == null);
}

test "source mutation and occupied or symlink work destinations publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentAssetFiles = .{};
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = "changed" });
    try std.testing.expectError(error.InvalidAsset, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = dmg_bytes });
    try fixture.tmp.dir.createDir(std.testing.io, "private-assets", .default_dir);
    try std.testing.expectError(error.DestinationExists, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    try fixture.tmp.dir.deleteDir(std.testing.io, "private-assets");
    try fixture.tmp.dir.symLink(std.testing.io, "missing", "private-assets", .{});
    try std.testing.expectError(error.DestinationExists, composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result));
    try std.testing.expect(result.value() == null);
}

test "cleanup failure preserves exact retry authority" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentAssetFiles = .{};
    try composition.compose(&fixture.current, &fixture.product, &fixture.evidence, fixture.paths(), &result);
    const dmg = result.value().?.asset(.universal_dmg).?;
    var moved_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const moved = try std.fmt.bufPrintZ(&moved_storage, "{s}.moved", .{dmg.path});
    try std.Io.Dir.renameAbsolute(dmg.path, moved, std.testing.io);
    try std.testing.expectError(error.CleanupFailed, result.deinit());
    try std.testing.expect(result.value() != null);
    try std.Io.Dir.renameAbsolute(moved, dmg.path, std.testing.io);
    try result.deinit();
}

fn assetFor(assets: []const manifest.Asset, role: manifest.AssetRole) ?manifest.Asset {
    for (assets) |asset| if (asset.role == role) return asset;
    return null;
}
