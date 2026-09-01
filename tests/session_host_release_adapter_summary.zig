//! Canonical release validation summary encoding from already-authenticated owners.

const std = @import("std");
const manifest = @import("release_manifest");
const summary = @import("release_adapter_summary");
const current_observation = @import("release_adapter_github_current_observation");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

const assets = [_]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 101 },
    .{ .role = .frozen_product_executable, .name = "maru-macos-app", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 202 },
    .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 303 },
};

fn releaseManifest(role: manifest.Role) manifest.Manifest {
    return .{
        .schema = manifest.schema,
        .role = role,
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .release = .{ .id = if (role == .a) 76 else 77, .tag = if (role == .a) "v1.2.2" else "v1.2.3", .version = if (role == .a) "1.2.2" else "1.2.3" },
        .source = .{ .commit = if (role == .a) "2222222222222222222222222222222222222222" else "3333333333333333333333333333333333333333", .tree = "1111111111111111111111111111111111111111" },
        .build = .{ .workflow_ref = if (role == .a) "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.2" else "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = if (role == .a) 332 else 333, .run_attempt = 2 },
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 },
        .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = if (role == .a) "1.2.2" else "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = &assets,
        .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
        .predecessor = if (role == .b) .{ .release_id = 76, .tag = "v1.2.2", .commit = "2222222222222222222222222222222222222222", .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" } else null,
    };
}

const Current = struct {
    candidate: manifest.Manifest,
    valid: bool = true,

    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return if (self.valid) &self.candidate else null;
    }
};

const Attestation = struct { verified: bool = true };
const Predecessor = struct {
    candidate: manifest.Manifest,
    valid: bool = true,
    observed: ?Attestation = .{},

    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return if (self.valid) &self.candidate else null;
    }
};

const PredecessorAssets = struct {
    source_commit: []const u8 = "2222222222222222222222222222222222222222",
    valid: bool = true,
    calls: usize = 0,
    mutate_on_second: bool = false,

    pub fn revalidateSummary(self: *@This()) !summary.PredecessorAssetsView {
        self.calls += 1;
        if (!self.valid) return error.FileChanged;
        if (self.mutate_on_second and self.calls == 2)
            self.source_commit = "9999999999999999999999999999999999999999";
        return .{ .source_commit = self.source_commit };
    }
};

test "production summary owner graph compiles through both closed entrypoints" {
    var current: current_observation.CurrentObservation = .{};
    try std.testing.expectError(error.InvalidOwner, summary.encodePrePublish(std.testing.allocator, &current));
    var predecessor: authenticated_manifest.AuthenticatedManifest = .{};
    var assets_owner: predecessor_assets.AuthenticatedPredecessorAssets = .{};
    try std.testing.expectError(error.InvalidOwner, summary.encodePredecessor(
        std.testing.allocator,
        &predecessor,
        &assets_owner,
    ));
}

test "pre-publish B summary is one exact canonical audit document" {
    var current = Current{ .candidate = releaseManifest(.b) };
    const bytes = try summary.encodePrePublishWith(std.testing.allocator, &current);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"schema\":\"maru.session-host-release-validation.v1\",\"phase\":\"pre_publish\",\"result\":\"passed\",\"manifest_sha256\":\""));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\",\"manifest_size\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",\"manifest\":{\"schema\":\"maru.session-host-release.v1\",\"role\":\"b\"") != null);
    try std.testing.expect(bytes[bytes.len - 1] == '\n');
    const manifest_bytes = try manifest.writeCanonical(std.testing.allocator, current.candidate);
    defer std.testing.allocator.free(manifest_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"maru.session-host-release-validation.v1\",\"phase\":\"pre_publish\",\"result\":\"passed\",\"manifest_sha256\":\"{s}\",\"manifest_size\":{d},\"manifest\":{s}}}\n",
        .{ digest_hex, manifest_bytes.len, manifest_bytes[0 .. manifest_bytes.len - 1] },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);
    var parsed = try summary.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(summary.Phase.pre_publish, parsed.value().phase);
    try std.testing.expectEqual(manifest.Role.b, parsed.value().manifest.role);
}

test "verified predecessor A summary revalidates held assets before and after encoding" {
    var predecessor = Predecessor{ .candidate = releaseManifest(.a) };
    var held = PredecessorAssets{};
    const bytes = try summary.encodePredecessorWith(std.testing.allocator, &predecessor, &held);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), held.calls);
    var parsed = try summary.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(summary.Phase.verify_predecessor, parsed.value().phase);
    try std.testing.expectEqual(manifest.Role.a, parsed.value().manifest.role);
}

test "summary parser rejects noncanonical and semantically drifted documents" {
    var current = Current{ .candidate = releaseManifest(.b) };
    const bytes = try summary.encodePrePublishWith(std.testing.allocator, &current);
    defer std.testing.allocator.free(bytes);

    const no_lf = bytes[0 .. bytes.len - 1];
    try std.testing.expectError(error.NonCanonical, summary.parseCanonical(std.testing.allocator, no_lf));
    var reordered = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(reordered);
    const phase = std.mem.indexOf(u8, reordered, "pre_publish") orelse unreachable;
    @memcpy(reordered[phase .. phase + "pre_publish".len], "verify_prede"[0.."pre_publish".len]);
    try std.testing.expectError(error.InvalidJson, summary.parseCanonical(std.testing.allocator, reordered));
    var predecessor = Predecessor{ .candidate = releaseManifest(.a) };
    var held = PredecessorAssets{};
    const predecessor_bytes = try summary.encodePredecessorWith(std.testing.allocator, &predecessor, &held);
    defer std.testing.allocator.free(predecessor_bytes);
    const old = "verify_predecessor";
    const new = "pre_publish";
    const at = std.mem.indexOf(u8, predecessor_bytes, old) orelse unreachable;
    var wrong_phase = try std.testing.allocator.alloc(u8, predecessor_bytes.len - old.len + new.len);
    defer std.testing.allocator.free(wrong_phase);
    @memcpy(wrong_phase[0..at], predecessor_bytes[0..at]);
    @memcpy(wrong_phase[at .. at + new.len], new);
    @memcpy(wrong_phase[at + new.len ..], predecessor_bytes[at + old.len ..]);
    try std.testing.expectError(error.InvalidPhase, summary.parseCanonical(std.testing.allocator, wrong_phase));
    var trailing = try std.testing.allocator.alloc(u8, bytes.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = '\n';
    try std.testing.expectError(error.NonCanonical, summary.parseCanonical(std.testing.allocator, trailing));
    const unknown = try std.mem.concat(std.testing.allocator, u8, &.{ "{\"unknown\":0,", bytes[1..] });
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidJson, summary.parseCanonical(std.testing.allocator, unknown));
    const schema_field = "\"schema\":\"maru.session-host-release-validation.v1\",";
    const duplicate = try std.mem.concat(std.testing.allocator, u8, &.{ "{", schema_field, bytes[1..] });
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidJson, summary.parseCanonical(std.testing.allocator, duplicate));
    const result_field = "\"result\":\"passed\",";
    const result_at = std.mem.indexOf(u8, bytes, result_field) orelse unreachable;
    const missing = try std.mem.concat(std.testing.allocator, u8, &.{ bytes[0..result_at], bytes[result_at + result_field.len ..] });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidJson, summary.parseCanonical(std.testing.allocator, missing));
    const size_key = "\"manifest_size\":";
    const size_at = (std.mem.indexOf(u8, bytes, size_key) orelse unreachable) + size_key.len;
    const size_end = std.mem.indexOfScalarPos(u8, bytes, size_at, ',') orelse unreachable;
    const wrong_type = try std.mem.concat(std.testing.allocator, u8, &.{ bytes[0..size_at], "\"1\"", bytes[size_end..] });
    defer std.testing.allocator.free(wrong_type);
    try std.testing.expectError(error.InvalidSize, summary.parseCanonical(std.testing.allocator, wrong_type));
    const over_cap = try std.testing.allocator.alloc(u8, summary.max_summary_bytes + 1);
    defer std.testing.allocator.free(over_cap);
    @memset(over_cap, 'x');
    try std.testing.expectError(error.SummaryTooLarge, summary.parseCanonical(std.testing.allocator, over_cap));
}

test "copied stale and mismatched predecessor owners publish nothing" {
    var current = Current{ .candidate = releaseManifest(.b), .valid = false };
    try std.testing.expectError(error.InvalidOwner, summary.encodePrePublishWith(std.testing.allocator, &current));

    var predecessor = Predecessor{ .candidate = releaseManifest(.a), .observed = .{ .verified = false } };
    var held = PredecessorAssets{};
    try std.testing.expectError(error.InvalidOwner, summary.encodePredecessorWith(std.testing.allocator, &predecessor, &held));
    predecessor.observed = .{};
    held.source_commit = "9999999999999999999999999999999999999999";
    try std.testing.expectError(error.InvalidOwner, summary.encodePredecessorWith(std.testing.allocator, &predecessor, &held));
    held = .{ .mutate_on_second = true };
    try std.testing.expectError(error.InvalidOwner, summary.encodePredecessorWith(std.testing.allocator, &predecessor, &held));
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var current = Current{ .candidate = releaseManifest(.b) };
    const bytes = try summary.encodePrePublishWith(allocator, &current);
    defer allocator.free(bytes);
    var parsed = try summary.parseCanonical(allocator, bytes);
    parsed.deinit();
}

test "every allocation prefix either returns one canonical summary or unwinds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}
