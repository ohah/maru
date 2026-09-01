//! Authenticated current/predecessor manifest가 release evidence identity를 직접 소유하는지 검증한다.

const std = @import("std");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const current_input = @import("release_adapter_github_current_manifest_input");
const predecessor_mod = @import("release_adapter_github_manifest_attestation");
const composition = @import("release_adapter_github_current_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const current_dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const current_exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const predecessor_dmg_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const predecessor_exe_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const requirement_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const set_one_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
const set_many_sha = "9999999999999999999999999999999999999999999999999999999999999999";

fn sha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn common() evidence.Common {
    return .{
        .test_uuid = uuid,
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .candidate = .{ .dmg_sha256 = current_dmg_sha, .executable_sha256 = current_exe_sha },
    };
}

fn upgradeLeaf(allocator: std.mem.Allocator, count: u64) ![]u8 {
    const set_sha = if (count == 1) set_one_sha else set_many_sha;
    return std.fmt.allocPrint(allocator, "{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, predecessor_exe_sha, current_exe_sha, requirement_sha, count, set_sha });
}

fn assetFor(role: manifest.AssetRole, name: []const u8, digest: []const u8, size: u64) manifest.Asset {
    return .{ .role = role, .name = name, .sha256 = digest, .size = size };
}

fn signing(version: []const u8) manifest.Signing {
    return .{ .bundle_id = "dev.maru.apphost", .bundle_short_version = version, .bundle_version = "1", .team_id = "TEAMID1234", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    current: current_input.CurrentManifestInput = .{},
    predecessor: predecessor_mod.AuthenticatedManifest = .{},
    summary_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    summary_bytes: []u8,
    predecessor_bytes: []u8,
    summary_sha: [64]u8,
    predecessor_manifest_sha: [64]u8,
    current_assets: [3]manifest.Asset,
    predecessor_assets: [3]manifest.Asset,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = undefined;
        self.tmp = std.testing.tmpDir(.{});
        self.current = .{};
        self.predecessor = .{};

        const predecessor_expected: evidence.Predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = undefined, .dmg_sha256 = predecessor_dmg_sha, .executable_sha256 = predecessor_exe_sha };
        const one = try upgradeLeaf(allocator, 1);
        defer allocator.free(one);
        const many = try upgradeLeaf(allocator, evidence.near_max_runtime_count);
        defer allocator.free(many);

        self.predecessor_assets = .{
            assetFor(.universal_dmg, "Maru-1.2.2.dmg", predecessor_dmg_sha, 10),
            assetFor(.frozen_product_executable, "maru-1.2.2", predecessor_exe_sha, 20),
            assetFor(.evidence_summary, "evidence-a.json", set_one_sha, 30),
        };
        const predecessor_manifest: manifest.Manifest = .{
            .schema = manifest.schema,
            .role = .a,
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 76, .tag = "v1.2.2", .version = "1.2.2" },
            .source = .{ .commit = "3333333333333333333333333333333333333333", .tree = "4444444444444444444444444444444444444444" },
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.2", .run_id = 222, .run_attempt = 1 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = signing("1.2.2"),
            .assets = &self.predecessor_assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = "evidence-a.json", .summary_sha256 = set_one_sha, .result = "passed" },
        };
        self.predecessor_bytes = try manifest.writeCanonical(allocator, predecessor_manifest);
        self.predecessor_manifest_sha = sha256(self.predecessor_bytes);
        self.predecessor.parsed = try manifest.parseCanonical(allocator, self.predecessor_bytes);
        self.predecessor.owner = &self.predecessor;

        var expected = predecessor_expected;
        expected.manifest_sha256 = &self.predecessor_manifest_sha;
        self.summary_bytes = try evidence.assembleUpgrade(allocator, common(), expected, one, many);
        self.summary_sha = sha256(self.summary_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = self.summary_bytes });
        _ = try absolute(&self.tmp, "evidence.json", &self.summary_path);

        self.current_assets = .{
            assetFor(.universal_dmg, "Maru-1.2.3.dmg", current_dmg_sha, 11),
            assetFor(.frozen_product_executable, "maru-1.2.3", current_exe_sha, 21),
            assetFor(.evidence_summary, "evidence.json", &self.summary_sha, self.summary_bytes.len),
        };
        const current_manifest: manifest.Manifest = .{
            .schema = manifest.schema,
            .role = .b,
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = signing("1.2.3"),
            .assets = &self.current_assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = "evidence.json", .summary_sha256 = &self.summary_sha, .result = "passed" },
            .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = &self.predecessor_manifest_sha },
        };
        const current_bytes = try manifest.writeCanonical(allocator, current_manifest);
        self.current.input = .{ .bytes = current_bytes, .size = current_bytes.len, .mode = 0o100400, .sha256 = sha256(current_bytes), .identity = .{ .device = 1, .inode = 1 } };
        self.current.authenticated.parsed = try manifest.parseCanonical(allocator, current_bytes);
        self.current.authenticated.repository_id = 12345;
        self.current.authenticated.run_id = 333;
        self.current.authenticated.run_attempt = 2;
        @memcpy(&self.current.authenticated.source_commit, "1111111111111111111111111111111111111111");
        self.current.authenticated.release_id = 77;
        @memcpy(self.current.authenticated.tag[0..6], "v1.2.3");
        self.current.authenticated.tag_len = 6;
        self.current.authenticated.protected_environment = true;
        self.current.authenticated.owner = &self.current.authenticated;
        self.current.owner = &self.current;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.current.deinit(allocator) catch {};
        self.predecessor.deinit(allocator) catch {};
        allocator.free(self.predecessor_bytes);
        allocator.free(self.summary_bytes);
        self.tmp.cleanup();
    }

    fn path(self: *Fixture) [:0]const u8 {
        return std.mem.sliceTo(&self.summary_path, 0);
    }
};

test "authenticated manifests derive and publish current upgrade evidence" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentEvidence = .{};
    try composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result);
    defer result.deinit(std.testing.allocator) catch {};
    const view = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(evidence.Profile.upgrade_b, view.evidence.profile());
    try std.testing.expectEqualStrings(&fixture.summary_sha, view.summary_sha256);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = "changed" });
    try std.testing.expect(result.value() != null);
}

test "copied preowned and manifest-summary aliases publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentEvidence = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    result = .{};
    var copied = fixture.current;
    try std.testing.expectError(error.InvalidCurrent, composition.compose(std.testing.allocator, &copied, &fixture.predecessor, fixture.path(), &result));
    var input = try files.readInputAlloc(std.testing.allocator, fixture.path(), evidence.max_evidence_bytes);
    defer input.deinit(std.testing.allocator);
    fixture.current.input.?.identity = input.identity;
    try std.testing.expectError(error.PathAlias, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    try std.testing.expect(result.value() == null);
}

test "summary pathname size and digest drift publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentEvidence = .{};
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const wrong = try absolute(&fixture.tmp, "wrong.json", &path_storage);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wrong.json", .data = fixture.summary_bytes });
    try std.testing.expectError(error.InvalidSummary, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, wrong, &result));
    const summary_asset = @constCast(&fixture.current.value().?.manifest.assets[2]);
    summary_asset.size += 1;
    try std.testing.expectError(error.InvalidSummary, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    summary_asset.size -= 1;
    summary_asset.sha256 = set_many_sha;
    try std.testing.expectError(error.InvalidSummary, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    summary_asset.sha256 = &fixture.summary_sha;
    const current_manifest = @constCast(fixture.current.value().?.manifest);
    current_manifest.evidence.result = "failed";
    try std.testing.expectError(error.InvalidSummary, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    try std.testing.expect(result.value() == null);
}

test "predecessor candidate signer and UUID drift publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentEvidence = .{};
    const current_manifest = @constCast(fixture.current.value().?.manifest);
    current_manifest.signing.designated_requirement_sha256 = set_many_sha;
    try std.testing.expectError(error.EvidenceMismatch, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    current_manifest.signing.designated_requirement_sha256 = requirement_sha;
    current_manifest.evidence.test_uuid = "223e4567-e89b-42d3-a456-426614174000";
    try std.testing.expectError(error.EvidenceMismatch, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    current_manifest.evidence.test_uuid = uuid;
    current_manifest.repository.id = 54321;
    try std.testing.expectError(error.InvalidCurrent, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    current_manifest.repository.id = 12345;
    current_manifest.predecessor.?.commit = "5555555555555555555555555555555555555555";
    try std.testing.expectError(error.InvalidPredecessor, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    try std.testing.expect(result.value() == null);
}

test "malformed input and every successful allocation prefix publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var result: composition.CurrentEvidence = .{};
    const malformed = "{}\n";
    const malformed_sha = sha256(malformed);
    const current_manifest = @constCast(fixture.current.value().?.manifest);
    const summary_asset = @constCast(&current_manifest.assets[2]);
    summary_asset.size = malformed.len;
    summary_asset.sha256 = &malformed_sha;
    current_manifest.evidence.summary_sha256 = &malformed_sha;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = malformed });
    try std.testing.expectError(error.InvalidJson, composition.compose(std.testing.allocator, &fixture.current, &fixture.predecessor, fixture.path(), &result));
    summary_asset.size = fixture.summary_bytes.len;
    summary_asset.sha256 = &fixture.summary_sha;
    current_manifest.evidence.summary_sha256 = &fixture.summary_sha;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = fixture.summary_bytes });
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        composition.compose(failing.allocator(), &fixture.current, &fixture.predecessor, fixture.path(), &result) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(result.value() == null);
            continue;
        };
        try result.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index > 0);
}
