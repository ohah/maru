//! Final current observation boundary must instantiate every production owner dependency.

const std = @import("std");
const manifest = @import("release_manifest");
const composition = @import("release_adapter_github_current_observation");
const current_input = @import("release_adapter_github_current_manifest_input");
const predecessor_mod = @import("release_adapter_github_manifest_attestation");
const predecessor_assets_mod = @import("release_adapter_github_predecessor_assets");
const product_mod = @import("release_adapter_github_current_product");
const evidence_mod = @import("release_adapter_github_current_evidence");
const files_mod = @import("release_adapter_github_current_asset_files");
const attestations_mod = @import("release_adapter_github_current_asset_attestation");
const compatibility_mod = @import("release_adapter_github_current_compatibility");

test "production final observation owner graph compiles as one closed composition" {
    var current: current_input.CurrentManifestInput = .{};
    var predecessor: predecessor_mod.AuthenticatedManifest = .{};
    var predecessor_owner: predecessor_assets_mod.AuthenticatedPredecessorAssets = .{};
    var product: product_mod.CurrentProduct = .{};
    var evidence: evidence_mod.CurrentEvidence = .{};
    var files: files_mod.CurrentAssetFiles = .{};
    var attestations: attestations_mod.CurrentAssetAttestations = .{};
    var compatibility: compatibility_mod.CurrentCompatibility = .{};
    var result: composition.CurrentObservation = .{};
    try std.testing.expectError(error.InvalidCurrent, composition.compose(
        std.testing.allocator,
        &current,
        &predecessor,
        &predecessor_owner,
        &product,
        &evidence,
        &files,
        &attestations,
        &compatibility,
        &result,
    ));
}

const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const evidence_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const requirement_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const source_sha = "1111111111111111111111111111111111111111";
const predecessor_source_sha = "3333333333333333333333333333333333333333";
const workflow = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3";
const predecessor_workflow = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.2";
const assets = [3]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3.dmg", .sha256 = dmg_sha, .size = 11 },
    .{ .role = .frozen_product_executable, .name = "maru-1.2.3", .sha256 = exe_sha, .size = 22 },
    .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = evidence_sha, .size = 33 },
};
const predecessor_asset_set = [3]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.2.dmg", .sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", .size = 10 },
    .{ .role = .frozen_product_executable, .name = "maru-1.2.2", .sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", .size = 20 },
    .{ .role = .evidence_summary, .name = "evidence-a.json", .sha256 = "9999999999999999999999999999999999999999999999999999999999999999", .size = 30 },
};

fn makeSigning(version: []const u8) manifest.Signing {
    return .{ .bundle_id = "dev.maru.apphost", .bundle_short_version = version, .bundle_version = "1", .team_id = "TEAMID1234", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true };
}

const Receipt = struct { verified: bool = true, run_id: u64, run_attempt: u64, subject_name: []const u8, subject_sha256: []const u8 };
const Input = struct { sha256: [64]u8 };

const Fixture = struct {
    predecessor_manifest: manifest.Manifest,
    current_manifest: manifest.Manifest,
    predecessor_bytes: []u8,
    current_bytes: []u8,
    predecessor_sha: [64]u8,
    current_sha: [64]u8,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const predecessor_manifest: manifest.Manifest = .{
            .schema = manifest.schema,
            .role = .a,
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 76, .tag = "v1.2.2", .version = "1.2.2" },
            .source = .{ .commit = predecessor_source_sha, .tree = "4444444444444444444444444444444444444444" },
            .build = .{ .workflow_ref = predecessor_workflow, .run_id = 222, .run_attempt = 1 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = makeSigning("1.2.2"),
            .assets = &predecessor_asset_set,
            .evidence = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .summary_name = "evidence-a.json", .summary_sha256 = predecessor_asset_set[2].sha256, .result = "passed" },
        };
        const predecessor_bytes = try manifest.writeCanonical(allocator, predecessor_manifest);
        const predecessor_sha = hash(predecessor_bytes);
        const current_manifest: manifest.Manifest = .{
            .schema = manifest.schema,
            .role = .b,
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = source_sha, .tree = "2222222222222222222222222222222222222222" },
            .build = .{ .workflow_ref = workflow, .run_id = 333, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = makeSigning("1.2.3"),
            .assets = &assets,
            .evidence = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = evidence_sha, .result = "passed" },
            .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = predecessor_source_sha, .manifest_sha256 = &predecessor_sha },
        };
        const current_bytes = try manifest.writeCanonical(allocator, current_manifest);
        return .{ .predecessor_manifest = predecessor_manifest, .current_manifest = current_manifest, .predecessor_bytes = predecessor_bytes, .current_bytes = current_bytes, .predecessor_sha = predecessor_sha, .current_sha = hash(current_bytes) };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.predecessor_bytes);
        allocator.free(self.current_bytes);
    }
};

fn hash(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

const Current = struct {
    fixture: *Fixture,
    input: ?Input,
    authenticated: struct { observed: ?Receipt },
    copied: bool = false,
    revalidate_calls: usize = 0,
    fail_revalidate_second: bool = false,
    const Authority = struct { repository_id: u64, release_id: u64, run_id: u64, run_attempt: u64, tag: []const u8, source_commit: []const u8, protected_environment: bool };
    const View = struct { manifest: *const manifest.Manifest, authority: Authority };
    pub fn value(self: *@This()) ?View {
        if (self.copied) return null;
        const candidate = &self.fixture.current_manifest;
        return .{ .manifest = candidate, .authority = .{ .repository_id = candidate.repository.id, .release_id = candidate.release.id, .run_id = candidate.build.run_id, .run_attempt = candidate.build.run_attempt, .tag = candidate.release.tag, .source_commit = candidate.source.commit, .protected_environment = true } };
    }
    pub fn bytes(self: *@This()) ?[]const u8 {
        return if (self.copied) null else self.fixture.current_bytes;
    }
    pub fn revalidate(self: *@This()) !void {
        self.revalidate_calls += 1;
        if (self.copied or (self.fail_revalidate_second and self.revalidate_calls == 2))
            return error.Drift;
    }
};

const Predecessor = struct {
    fixture: *Fixture,
    observed: ?Receipt,
    copied: bool = false,
    pub fn value(self: *@This()) ?*const manifest.Manifest {
        return if (self.copied) null else &self.fixture.predecessor_manifest;
    }
};

const Downloads = struct {
    fail: bool = false,
    calls: usize = 0,
    pub fn revalidate(self: *@This()) !void {
        self.calls += 1;
        if (self.fail) return error.Drift;
    }
};
const PredecessorAssets = struct {
    downloads: Downloads = .{},
    copied: bool = false,
    const View = struct { source_commit: []const u8 };
    pub fn value(self: *@This()) ?View {
        return if (self.copied) null else .{ .source_commit = predecessor_source_sha };
    }
};

const Apple = struct {
    pub fn signing(_: *const @This()) manifest.Signing {
        return makeSigning("1.2.3");
    }
    pub fn executableSha256(_: *const @This()) []const u8 {
        return exe_sha;
    }
};
const Product = struct {
    calls: usize = 0,
    drift: bool = false,
    apple: Apple = .{},
    const Frozen = struct { sha256: [64]u8 };
    const View = struct { frozen: Frozen, apple: *const Apple };
    pub fn revalidateHeld(self: *@This()) !View {
        self.calls += 1;
        var sha = exe_sha.*;
        if (self.drift and self.calls == 2) sha[0] = '0';
        return .{ .frozen = .{ .sha256 = sha }, .apple = &self.apple };
    }
};

const EvidenceRoot = struct { test_uuid: []const u8, result: enum { passed }, candidate: struct { executable_sha256: []const u8 } };
const EvidenceParsed = struct {
    root: EvidenceRoot,
    const Value = union(enum) { baseline_a: void, upgrade_b: *const EvidenceRoot };
    pub fn value(self: *const @This()) Value {
        return .{ .upgrade_b = &self.root };
    }
};
const Evidence = struct {
    parsed: EvidenceParsed = .{ .root = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .result = .passed, .candidate = .{ .executable_sha256 = exe_sha } } },
    copied: bool = false,
    const View = struct { evidence: *const EvidenceParsed, summary_sha256: []const u8 };
    pub fn value(self: *@This()) ?View {
        return if (self.copied) null else .{ .evidence = &self.parsed, .summary_sha256 = evidence_sha };
    }
};

const PrivateObservation = struct { role: manifest.AssetRole, name: []const u8, identity: struct { device: u64, inode: u64 }, size: u64, mode: u32 = 0o100400, link_count: u64 = 1, sha256: []const u8 };
const PrivateView = struct {
    pub fn asset(_: @This(), role: manifest.AssetRole) ?PrivateObservation {
        for (assets, 0..) |candidate, index| if (candidate.role == role) return .{ .role = role, .name = candidate.name, .identity = .{ .device = 1, .inode = index + 10 }, .size = candidate.size, .sha256 = candidate.sha256 };
        return null;
    }
};
const PrivateFiles = struct {
    calls: usize = 0,
    fail_second: bool = false,
    pub fn revalidate(self: *@This()) !PrivateView {
        self.calls += 1;
        if (self.fail_second and self.calls == 2) return error.Drift;
        return .{};
    }
};

const AttestationView = struct {
    owner: *Attestations,
    context: attestations_mod.ContextView,
    pub fn asset(self: @This(), role: manifest.AssetRole) ?*const Receipt {
        for (assets, 0..) |candidate, index| if (candidate.role == role) return &self.owner.receipts[index];
        return null;
    }
};
const Attestations = struct {
    receipts: [3]Receipt,
    copied: bool = false,
    pub fn value(self: *@This()) ?AttestationView {
        if (self.copied) return null;
        return .{ .owner = self, .context = .{ .repository_id = 12345, .release_id = 77, .run_id = 333, .run_attempt = 2, .tag = "v1.2.3", .source_commit = source_sha, .workflow_ref = workflow } };
    }
};
const Compatibility = struct {
    copied: bool = false,
    sha: [64]u8 = exe_sha.*,
    const View = struct { executable_sha256: [64]u8, compatibility: manifest.Compatibility };
    pub fn value(self: *@This()) ?View {
        return if (self.copied) null else .{ .executable_sha256 = self.sha, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 } };
    }
};

const Owners = struct {
    current: Current,
    predecessor: Predecessor,
    predecessor_assets: PredecessorAssets = .{},
    product: Product = .{},
    evidence: Evidence = .{},
    private: PrivateFiles = .{},
    attestations: Attestations,
    compatibility: Compatibility = .{},
    fn init(fixture: *Fixture) Owners {
        const current_name = "Maru-1.2.3-session-host-release.json";
        const predecessor_name = "Maru-1.2.2-session-host-release.json";
        var receipts: [3]Receipt = undefined;
        for (assets, 0..) |asset, index| receipts[index] = .{ .run_id = 333, .run_attempt = 2, .subject_name = asset.name, .subject_sha256 = asset.sha256 };
        return .{ .current = .{ .fixture = fixture, .input = .{ .sha256 = fixture.current_sha }, .authenticated = .{ .observed = .{ .run_id = 333, .run_attempt = 2, .subject_name = current_name, .subject_sha256 = &fixture.current_sha } } }, .predecessor = .{ .fixture = fixture, .observed = .{ .run_id = 222, .run_attempt = 1, .subject_name = predecessor_name, .subject_sha256 = &fixture.predecessor_sha } }, .attestations = .{ .receipts = receipts } };
    }
};

fn composeOwners(owners: *Owners, result: *composition.CurrentObservation) !void {
    return composeOwnersWithAllocator(std.testing.allocator, owners, result);
}

fn composeOwnersWithAllocator(allocator: std.mem.Allocator, owners: *Owners, result: *composition.CurrentObservation) !void {
    return composition.composeWith(allocator, &owners.current, &owners.predecessor, &owners.predecessor_assets, &owners.product, &owners.evidence, &owners.private, &owners.attestations, &owners.compatibility, result);
}

test "canonical owners publish one strict final observation" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.current_manifest.predecessor.?.manifest_sha256 = &fixture.predecessor_sha;
    var owners = Owners.init(&fixture);
    var result: composition.CurrentObservation = .{};
    try composeOwners(&owners, &result);
    defer result.deinit() catch {};
    const value = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(manifest.Role.b, value.role);
    try std.testing.expectEqual(@as(usize, 2), owners.product.calls);
    try std.testing.expectEqual(@as(usize, 2), owners.private.calls);
    try std.testing.expectEqual(@as(usize, 2), owners.predecessor_assets.downloads.calls);
}

test "final observation storage cannot overlap an input owner" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.current_manifest.predecessor.?.manifest_sha256 = &fixture.predecessor_sha;
    var owners = Owners.init(&fixture);

    const storage_size = @max(@sizeOf(PrivateFiles), @sizeOf(composition.CurrentObservation));
    const storage_alignment = @max(@alignOf(PrivateFiles), @alignOf(composition.CurrentObservation));
    var aliased_storage: [storage_size]u8 align(storage_alignment) = @splat(0);
    const private: *PrivateFiles = @ptrCast(&aliased_storage);
    private.* = .{};
    const result: *composition.CurrentObservation = @ptrCast(&aliased_storage);

    try std.testing.expectError(error.InvalidOwner, composition.composeWith(
        std.testing.allocator,
        &owners.current,
        &owners.predecessor,
        &owners.predecessor_assets,
        &owners.product,
        &owners.evidence,
        private,
        &owners.attestations,
        &owners.compatibility,
        result,
    ));
    try std.testing.expectEqual(@as(usize, 0), owners.current.revalidate_calls);
}

test "receipt owner and post-validation drift publish nothing" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.current_manifest.predecessor.?.manifest_sha256 = &fixture.predecessor_sha;
    var result: composition.CurrentObservation = .{};
    var owners = Owners.init(&fixture);
    owners.current.authenticated.observed = null;
    try std.testing.expectError(error.InvalidCurrent, composeOwners(&owners, &result));
    try std.testing.expect(result.value() == null);
    owners = Owners.init(&fixture);
    owners.predecessor.observed.?.verified = false;
    try std.testing.expectError(error.InvalidPredecessor, composeOwners(&owners, &result));
    owners = Owners.init(&fixture);
    owners.private.fail_second = true;
    try std.testing.expectError(error.InvalidAssets, composeOwners(&owners, &result));
    owners = Owners.init(&fixture);
    owners.product.drift = true;
    try std.testing.expectError(error.InvalidProduct, composeOwners(&owners, &result));
    owners = Owners.init(&fixture);
    owners.current.fail_revalidate_second = true;
    try std.testing.expectError(error.InvalidCurrent, composeOwners(&owners, &result));

    owners = Owners.init(&fixture);
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composeOwners(&owners, &result));
    result = .{};
    owners.current.copied = true;
    try std.testing.expectError(error.InvalidCurrent, composeOwners(&owners, &result));
    owners = Owners.init(&fixture);
    owners.attestations.copied = true;
    try std.testing.expectError(error.InvalidAssets, composeOwners(&owners, &result));
    owners = Owners.init(&fixture);
    owners.compatibility.copied = true;
    try std.testing.expectError(error.InvalidCompatibility, composeOwners(&owners, &result));
}

fn allocationHarness(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var owners = Owners.init(fixture);
    var result: composition.CurrentObservation = .{};
    try composeOwnersWithAllocator(allocator, &owners, &result);
    try result.deinit();
}

test "every successful allocation prefix either publishes one owner or unwinds" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.current_manifest.predecessor.?.manifest_sha256 = &fixture.predecessor_sha;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{&fixture});
}
