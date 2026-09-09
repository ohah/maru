//! Contract tests for downloaded Release canonical semantic binding.

const std = @import("std");
const semantics = @import("release_adapter_remote_release_semantics");
const metadata = @import("release_adapter_remote_release_metadata");
const context_mod = @import("release_adapter_context");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const commit = "1111111111111111111111111111111111111111";
const tree = "2222222222222222222222222222222222222222";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const host_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const predecessor_manifest_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const predecessor_dmg_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const predecessor_host_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const requirement_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

test "baseline canonical bytes publish profile only after metadata manifest and evidence binding" {
    var fixture = try Fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: metadata.Owner = .{};
    try fixture.bindRemote(std.testing.allocator, context(), fixture.evidence_name, dmg_sha, &fixture.manifest_sha, 88, &remote);
    defer remote.deinit() catch {};
    var result: semantics.Owner = .{};
    defer if (result.owner != null) result.deinit(std.testing.allocator) catch {};
    try semantics.bind(std.testing.allocator, context(), &remote, fixture.manifest_bytes, fixture.evidence_bytes, &result);
    const value = result.value().?;
    try std.testing.expectEqual(evidence.Profile.baseline_a, value.profile);
    try std.testing.expectEqual(@as(u64, 88), value.release_id);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    result.release_id += 1;
    try std.testing.expect(result.value() == null);
    result.release_id -= 1;
    try result.deinit(std.testing.allocator);
}

test "upgrade profile and predecessor identity come from authenticated semantics" {
    var fixture = try Fixture.init(.upgrade_b);
    defer fixture.deinit();
    var remote: metadata.Owner = .{};
    try fixture.bindRemote(std.testing.allocator, context(), fixture.evidence_name, dmg_sha, &fixture.manifest_sha, 88, &remote);
    defer remote.deinit() catch {};
    var result: semantics.Owner = .{};
    try semantics.bind(std.testing.allocator, context(), &remote, fixture.manifest_bytes, fixture.evidence_bytes, &result);
    try std.testing.expectEqual(evidence.Profile.upgrade_b, result.value().?.profile);
    try result.deinit(std.testing.allocator);
}

test "role profile identity and digest exchanges fail before publication" {
    var fixture = try Fixture.init(.baseline_a);
    defer fixture.deinit();
    inline for ([_]Mutation{ .evidence_name, .dmg_digest, .manifest_digest, .release_id, .context_source }) |mutation| {
        var changed_context = context();
        if (mutation == .context_source) changed_context.source_commit = "2111111111111111111111111111111111111111";
        var remote: metadata.Owner = .{};
        const metadata_context = if (mutation == .context_source) changed_context else context();
        try fixture.bindRemote(std.testing.allocator, metadata_context, if (mutation == .evidence_name) "upgrade-evidence.json" else fixture.evidence_name, if (mutation == .dmg_digest) requirement_sha else dmg_sha, if (mutation == .manifest_digest) requirement_sha else &fixture.manifest_sha, if (mutation == .release_id) 89 else 88, &remote);
        defer remote.deinit() catch {};
        if (mutation == .context_source) changed_context = context();
        var result: semantics.Owner = .{};
        defer if (result.value() != null) result.deinit(std.testing.allocator) catch {};
        try std.testing.expectError(switch (mutation) {
            .manifest_digest => error.ContentMismatch,
            .context_source => error.MetadataMismatch,
            .release_id => error.BindingMismatch,
            else => error.BindingMismatch,
        }, semantics.bind(std.testing.allocator, changed_context, &remote, fixture.manifest_bytes, fixture.evidence_bytes, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "noncanonical bytes preowned alias and allocation failures publish no owner" {
    var fixture = try Fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: metadata.Owner = .{};
    try fixture.bindRemote(std.testing.allocator, context(), fixture.evidence_name, dmg_sha, &fixture.manifest_sha, 88, &remote);
    defer remote.deinit() catch {};
    var preowned: semantics.Owner = .{ .release_id = 1 };
    try std.testing.expectError(error.InvalidOwner, semantics.bind(std.testing.allocator, context(), &remote, fixture.manifest_bytes, fixture.evidence_bytes, &preowned));
    var aliased: semantics.Owner = .{};
    try std.testing.expectError(error.InvalidOwner, semantics.bind(std.testing.allocator, context(), &remote, std.mem.asBytes(&aliased), fixture.evidence_bytes, &aliased));
    const noncanonical = try std.fmt.allocPrint(std.testing.allocator, "{s} ", .{fixture.manifest_bytes});
    defer std.testing.allocator.free(noncanonical);
    var noncanonical_sha: [64]u8 = undefined;
    hash(noncanonical, &noncanonical_sha);
    var matching_remote: metadata.Owner = .{};
    var altered = fixture;
    altered.manifest_bytes = noncanonical;
    try altered.bindRemote(std.testing.allocator, context(), altered.evidence_name, dmg_sha, &noncanonical_sha, 88, &matching_remote);
    defer matching_remote.deinit() catch {};
    var rejected: semantics.Owner = .{};
    try std.testing.expectError(error.NonCanonical, semantics.bind(std.testing.allocator, context(), &matching_remote, noncanonical, fixture.evidence_bytes, &rejected));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}

test "copied metadata and post-publication byte mutation revoke value while cleanup remains possible" {
    var fixture = try Fixture.init(.baseline_a);
    defer fixture.deinit();
    var remote: metadata.Owner = .{};
    try fixture.bindRemote(std.testing.allocator, context(), fixture.evidence_name, dmg_sha, &fixture.manifest_sha, 88, &remote);
    var copied_remote = remote;
    var rejected: semantics.Owner = .{};
    try std.testing.expectError(error.InvalidMetadata, semantics.bind(std.testing.allocator, context(), &copied_remote, fixture.manifest_bytes, fixture.evidence_bytes, &rejected));
    var result: semantics.Owner = .{};
    defer if (result.owner != null) result.deinit(std.testing.allocator) catch {};
    try semantics.bind(std.testing.allocator, context(), &remote, fixture.manifest_bytes, fixture.evidence_bytes, &result);
    result.manifest_bytes.?[0] ^= 1;
    try std.testing.expect(result.value() == null);
    result.manifest_bytes.?[0] ^= 1;
    try remote.deinit();
    try fixture.bindRemote(std.testing.allocator, context(), fixture.evidence_name, dmg_sha, &fixture.manifest_sha, 89, &remote);
    try std.testing.expect(result.value() == null);
    try remote.deinit();
    try result.deinit(std.testing.allocator);
}

const Mutation = enum { evidence_name, dmg_digest, manifest_digest, release_id, context_source };

fn allocationPath(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.initWith(allocator, .baseline_a);
    defer fixture.deinitWith(allocator);
    var remote: metadata.Owner = .{};
    try fixture.bindRemote(allocator, context(), fixture.evidence_name, dmg_sha, &fixture.manifest_sha, 88, &remote);
    defer remote.deinit() catch {};
    var result: semantics.Owner = .{};
    try semantics.bind(allocator, context(), &remote, fixture.manifest_bytes, fixture.evidence_bytes, &result);
    try result.deinit(allocator);
}

const Fixture = struct {
    evidence_bytes: []u8,
    manifest_bytes: []u8,
    evidence_sha: [64]u8,
    manifest_sha: [64]u8,
    evidence_name: []const u8,

    fn init(profile: evidence.Profile) !@This() {
        return initWith(std.testing.allocator, profile);
    }
    fn initWith(allocator: std.mem.Allocator, profile: evidence.Profile) !@This() {
        const evidence_bytes = switch (profile) {
            .baseline_a => try evidence.assembleBaseline(allocator, common(), defaultLeaf(), quitLeaf()),
            .upgrade_b => try evidence.assembleUpgrade(allocator, common(), predecessor(), upgradeLeaf(1), upgradeLeaf(evidence.near_max_runtime_count)),
        };
        errdefer allocator.free(evidence_bytes);
        var evidence_sha: [64]u8 = undefined;
        hash(evidence_bytes, &evidence_sha);
        const evidence_name = if (profile == .baseline_a) "baseline-evidence.json" else "upgrade-evidence.json";
        const assets = [_]manifest.Asset{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 100 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host-1.2.3", .sha256 = host_sha, .size = 101 },
            .{ .role = .evidence_summary, .name = evidence_name, .sha256 = &evidence_sha, .size = evidence_bytes.len },
        };
        const predecessor_value: ?manifest.Predecessor = if (profile == .upgrade_b) .{ .release_id = 77, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha } else null;
        const manifest_bytes = try manifest.writeCanonical(allocator, .{
            .schema = manifest.schema,
            .role = if (profile == .baseline_a) .a else .b,
            .repository = context().repository,
            .release = .{ .id = 88, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = commit, .tree = tree },
            .build = context().build,
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = evidence_name, .summary_sha256 = &evidence_sha, .result = "passed" },
            .predecessor = predecessor_value,
        });
        var manifest_sha: [64]u8 = undefined;
        hash(manifest_bytes, &manifest_sha);
        return .{ .evidence_bytes = evidence_bytes, .manifest_bytes = manifest_bytes, .evidence_sha = evidence_sha, .manifest_sha = manifest_sha, .evidence_name = evidence_name };
    }
    fn deinit(self: *@This()) void {
        self.deinitWith(std.testing.allocator);
    }
    fn deinitWith(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_bytes);
        allocator.free(self.evidence_bytes);
    }
    fn bindRemote(self: *@This(), allocator: std.mem.Allocator, ctx: context_mod.Context, evidence_name: []const u8, remote_dmg_sha: []const u8, remote_manifest_sha: []const u8, release_id: u64, result: *metadata.Owner) !void {
        const json = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"tag_name\":\"{s}\",\"target_commitish\":\"{s}\",\"draft\":false,\"prerelease\":false,\"immutable\":true,\"assets\":[" ++
            "{{\"id\":1000,\"name\":\"Maru-1.2.3-universal.dmg\",\"size\":100,\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1000\"}}," ++
            "{{\"id\":1001,\"name\":\"maru-session-host-1.2.3\",\"size\":101,\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1001\"}}," ++
            "{{\"id\":1002,\"name\":\"{s}\",\"size\":{d},\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1002\"}}," ++
            "{{\"id\":1003,\"name\":\"Maru-1.2.3-session-host-release.json\",\"size\":{d},\"state\":\"uploaded\",\"digest\":\"sha256:{s}\",\"content_type\":\"application/octet-stream\",\"url\":\"https://api.github.com/repos/ohah/maru/releases/assets/1003\"}}]}}", .{ release_id, ctx.tag, ctx.source_commit, remote_dmg_sha, host_sha, evidence_name, self.evidence_bytes.len, &self.evidence_sha, self.manifest_bytes.len, remote_manifest_sha });
        defer allocator.free(json);
        try metadata.bind(allocator, json, ctx, result);
    }
};

fn context() context_mod.Context {
    return .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = commit, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };
}
fn common() evidence.Common {
    return .{ .test_uuid = uuid, .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .release = .{ .id = 88, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = commit, .tree = tree }, .build = .{ .workflow_ref = context().build.workflow_ref, .run_id = 333, .run_attempt = 2 }, .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = host_sha } };
}
fn predecessor() evidence.Predecessor {
    return .{ .release_id = 77, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha, .dmg_sha256 = predecessor_dmg_sha, .executable_sha256 = predecessor_host_sha };
}
fn defaultLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"123e4567-e89b-42d3-a456-426614174000\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ host_sha ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
}
fn quitLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"123e4567-e89b-42d3-a456-426614174000\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ host_sha ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
}
fn upgradeLeaf(comptime count: u64) []const u8 {
    return std.fmt.comptimePrint("{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, predecessor_host_sha, host_sha, requirement_sha, count, predecessor_manifest_sha });
}
fn hash(bytes: []const u8, output: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    output.* = std.fmt.bytesToHex(digest, .lower);
}
