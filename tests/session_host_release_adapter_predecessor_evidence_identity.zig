const std = @import("std");
const manifest = @import("release_manifest");
const identity = @import("release_adapter_predecessor_evidence_identity");

const commit = "0123456789abcdef0123456789abcdef01234567";
const manifest_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const dmg_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const exe_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const summary_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const assets = [_]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3.dmg", .sha256 = dmg_sha, .size = 11 },
    .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = exe_sha, .size = 12 },
    .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = summary_sha, .size = 13 },
};

fn candidate() manifest.Manifest {
    return .{ .schema = manifest.schema, .role = .a, .repository = .{ .id = 1, .owner = "ohah", .name = "maru" }, .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 9, .run_attempt = 2 }, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = summary_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &assets, .evidence = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = summary_sha, .result = "passed" } };
}
const ManifestOwner = struct {
    value_storage: manifest.Manifest = candidate(),
    subject_sha256: []const u8 = manifest_sha,
    valid: bool = true,
    pub fn evidenceView(self: *const @This()) ?identity.ManifestView {
        return if (self.valid) .{ .value = &self.value_storage, .subject_name = "Maru-1.2.3-session-host-release.json", .subject_sha256 = self.subject_sha256, .run_id = 9, .run_attempt = 2 } else null;
    }
};
const FileOwner = struct {
    sha256: []const u8 = manifest_sha,
    valid: bool = true,
    pub fn revalidate(self: *const @This()) !identity.FileObservation {
        if (!self.valid) return error.FileChanged;
        return .{ .path = "/held/Maru-1.2.3-session-host-release.json", .device = 1, .inode = 2, .size = 100, .sha256 = self.sha256 };
    }
};
const AssetsOwner = struct {
    source_commit: []const u8 = commit,
    valid: bool = true,
    swapped: bool = false,
    pub fn revalidateEvidence(self: *const @This()) !identity.AssetsView {
        if (!self.valid) return error.FileChanged;
        return .{ .source_commit = self.source_commit, .assets = .{
            .{ .role = .universal_dmg, .path = if (self.swapped) "/held/maru-session-host" else "/held/Maru-1.2.3.dmg", .device = 3, .inode = 4, .size = 11, .sha256 = if (self.swapped) exe_sha else dmg_sha },
            .{ .role = .frozen_product_executable, .path = if (self.swapped) "/held/Maru-1.2.3.dmg" else "/held/maru-session-host", .device = 5, .inode = 6, .size = 12, .sha256 = if (self.swapped) dmg_sha else exe_sha },
            .{ .role = .evidence_summary, .path = "/held/evidence.json", .device = 7, .inode = 8, .size = 13, .sha256 = summary_sha },
        } };
    }
};

test "authenticated owners derive exact predecessor evidence" {
    var auth = ManifestOwner{};
    var file = FileOwner{};
    var held = AssetsOwner{};
    var result: identity.PredecessorEvidenceIdentity = .{};
    try identity.composeWith(&auth, &file, &held, &result);
    const view = try result.revalidateWith(&auth, &file, &held);
    try std.testing.expectEqual(@as(u64, 77), view.release_id);
    try std.testing.expectEqualStrings("v1.2.3", view.tag);
    try std.testing.expectEqualStrings(dmg_sha, view.dmg_sha256);
    try result.deinit();
}
test "attestation manifest and source mismatches publish nothing" {
    var auth = ManifestOwner{ .subject_sha256 = exe_sha };
    var file = FileOwner{};
    var held = AssetsOwner{};
    var result: identity.PredecessorEvidenceIdentity = .{};
    try std.testing.expectError(error.BindingMismatch, identity.composeWith(&auth, &file, &held, &result));
    auth.subject_sha256 = manifest_sha;
    held.source_commit = "9999999999999999999999999999999999999999";
    try std.testing.expectError(error.BindingMismatch, identity.composeWith(&auth, &file, &held, &result));
}
test "role swaps and asset drift publish nothing" {
    var auth = ManifestOwner{};
    var file = FileOwner{};
    var held = AssetsOwner{ .swapped = true };
    var result: identity.PredecessorEvidenceIdentity = .{};
    try std.testing.expectError(error.BindingMismatch, identity.composeWith(&auth, &file, &held, &result));
    held.swapped = false;
    held.valid = false;
    try std.testing.expectError(error.FileChanged, identity.composeWith(&auth, &file, &held, &result));
}
test "copied preowned and revalidation drift fail closed" {
    var auth = ManifestOwner{};
    var file = FileOwner{};
    var held = AssetsOwner{};
    var result: identity.PredecessorEvidenceIdentity = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, identity.composeWith(&auth, &file, &held, &result));
    result = .{};
    try identity.composeWith(&auth, &file, &held, &result);
    var copied = result;
    try std.testing.expectError(error.InvalidOwner, copied.revalidateWith(&auth, &file, &held));
    file.valid = false;
    try std.testing.expectError(error.FileChanged, result.revalidateWith(&auth, &file, &held));
    try result.deinit();
}
test "result cannot alias nested authenticated evidence storage" {
    var result: identity.PredecessorEvidenceIdentity = .{};
    var auth = ManifestOwner{ .subject_sha256 = std.mem.asBytes(&result)[0..64] };
    var file = FileOwner{};
    var held = AssetsOwner{};
    try std.testing.expectError(error.InvalidOwner, identity.composeWith(&auth, &file, &held, &result));
    try std.testing.expectEqual(@as(?*identity.PredecessorEvidenceIdentity, null), result.owner);
}
test "production predecessor evidence surface compiles" {
    _ = identity.compose;
}
