//! GitHub release attestation이 tag-ref와 exact release asset set에 결속되는지 검증한다.

const std = @import("std");
const release_manifest = @import("release_manifest");
const attestation = @import("release_adapter_github_release_attestation");

const tag_ref_sha = "0123456789abcdef0123456789abcdef01234567";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const manifest_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const executable_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const release_manifest_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const assets = [_]release_manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 123 },
    .{ .role = .frozen_product_executable, .name = "maru-session-host-1.2.3", .sha256 = executable_sha, .size = 321 },
    .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = manifest_sha, .size = 456 },
};

fn expected() attestation.Expected {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .release_id = 67890,
        .tag = "v1.2.3",
        .tag_ref_sha = tag_ref_sha,
        .assets = &assets,
        .manifest = .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = release_manifest_sha },
    };
}

const valid_json =
    \\{"attestation":{},"verificationResult":{"signature":{"certificate":{
    \\"subjectAlternativeName":"https://dotcom.releases.github.com"}},
    \\"statement":{"_type":"https://in-toto.io/Statement/v1","subject":[
    \\{"uri":"pkg:github/ohah/maru@v1.2.3","digest":{"sha1":"0123456789abcdef0123456789abcdef01234567"}},
    \\{"name":"Maru-1.2.3-universal.dmg","digest":{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
    \\{"name":"maru-session-host-1.2.3","digest":{"sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},
    \\{"name":"evidence.json","digest":{"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},
    \\{"name":"Maru-1.2.3-session-host-release.json","digest":{"sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}],
    \\"predicateType":"https://in-toto.io/attestation/release/v0.1","predicate":{
    \\"ownerId":"2468","purl":"pkg:github/ohah/maru@v1.2.3","releaseId":"67890",
    \\"repository":"ohah/maru","repositoryId":"12345","tag":"v1.2.3"}},
    \\"verifiedTimestamps":[{"type":"TimestampAuthority","uri":"timestamp.githubapp.com","timestamp":"2026-09-01T00:00:00Z"}]}}
;

test "release attestation command plans are exact and closed" {
    var storage: attestation.ArgsStorage = undefined;
    const release = try attestation.plan(&storage, .release, expected());
    const release_want = [_][]const u8{ "release", "verify", "v1.2.3", "--repo", "ohah/maru", "--format", "json" };
    try expectArgs(&release_want, release.args);

    const asset = try attestation.plan(&storage, .{ .asset = .{ .path = "/tmp/Maru-1.2.3-universal.dmg", .expected = assets[0] } }, expected());
    const asset_want = [_][]const u8{ "release", "verify-asset", "v1.2.3", "/tmp/Maru-1.2.3-universal.dmg", "--repo", "ohah/maru", "--format", "json" };
    try expectArgs(&asset_want, asset.args);
    const manifest_asset = try attestation.plan(&storage, .{ .manifest_asset = .{ .path = "/tmp/Maru-1.2.3-session-host-release.json" } }, expected());
    const manifest_want = [_][]const u8{ "release", "verify-asset", "v1.2.3", "/tmp/Maru-1.2.3-session-host-release.json", "--repo", "ohah/maru", "--format", "json" };
    try expectArgs(&manifest_want, manifest_asset.args);
    try std.testing.expectError(error.InvalidPath, attestation.plan(&storage, .{ .manifest_asset = .{ .path = "relative.json" } }, expected()));
    try std.testing.expectError(error.InvalidPath, attestation.plan(&storage, .{ .asset = .{ .path = "relative.dmg", .expected = assets[0] } }, expected()));
    var wrong = assets[0];
    wrong.name = "other.dmg";
    try std.testing.expectError(error.AssetMismatch, attestation.plan(&storage, .{ .asset = .{ .path = "/tmp/Maru-1.2.3-universal.dmg", .expected = wrong } }, expected()));
}

test "release attestation binds release identity tag ref and exact assets" {
    var observed = try attestation.parseAndBind(std.testing.allocator, valid_json, expected());
    defer observed.deinit();
    try std.testing.expect(observed.verified);
    try std.testing.expectEqual(@as(u64, 67890), observed.release_id);
    try std.testing.expectEqualStrings("v1.2.3", observed.tag);
    try std.testing.expectEqualStrings(tag_ref_sha, observed.tag_ref_sha);
    try std.testing.expectEqual(@as(usize, 4), observed.asset_count);
}

fn expectMutation(old: []const u8, replacement: []const u8) !void {
    const mutated = try std.mem.replaceOwned(u8, std.testing.allocator, valid_json, old, replacement);
    defer std.testing.allocator.free(mutated);
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, mutated, expected()));
}

test "release attestation rejects release and certificate authority drift" {
    try expectMutation("dotcom.releases.github.com", "example.releases.github.com");
    try expectMutation("releaseId\":\"67890", "releaseId\":\"67891");
    try expectMutation("repositoryId\":\"12345", "repositoryId\":\"54321");
    try expectMutation("repository\":\"ohah/maru", "repository\":\"fork/maru");
    try expectMutation("@v1.2.3", "@v9.9.9");
    try expectMutation(tag_ref_sha, "ffffffffffffffffffffffffffffffffffffffff");
}

test "release attestation rejects asset substitution addition and duplication" {
    try expectMutation(dmg_sha, "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");
    try expectMutation("Maru-1.2.3-universal.dmg", "Maru-9.9.9-universal.dmg");
    try expectMutation(release_manifest_sha, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    const missing_manifest = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_json,
        ",\n{\"name\":\"Maru-1.2.3-session-host-release.json\",\"digest\":{\"sha256\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}}",
        "",
    );
    defer std.testing.allocator.free(missing_manifest);
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, missing_manifest, expected()));
    var aliased = expected();
    aliased.manifest.name = assets[2].name;
    try std.testing.expectError(error.InvalidExpected, attestation.parseAndBind(std.testing.allocator, valid_json, aliased));
    const extra = try std.mem.replaceOwned(u8, std.testing.allocator, valid_json, "}],\n\"predicateType", "},{\"name\":\"extra\",\"digest\":{\"sha256\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}}],\n\"predicateType");
    defer std.testing.allocator.free(extra);
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, extra, expected()));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, valid_json, "}],\n\"predicateType", "},{\"name\":\"Maru-1.2.3-universal.dmg\",\"digest\":{\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}],\n\"predicateType");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, duplicate, expected()));
}

test "release attestation rejects malformed roots timestamps and caps" {
    try std.testing.expectError(error.AttestationMismatch, attestation.parseAndBind(std.testing.allocator, "[]", expected()));
    try std.testing.expectError(error.InvalidJson, attestation.parseAndBind(std.testing.allocator, "{}{}", expected()));
    try expectMutation("verifiedTimestamps\":[{", "verifiedTimestamps\":[] ,\"ignored\":[{");
    var oversized: [attestation.max_response_bytes + 1]u8 = @splat(' ');
    try std.testing.expectError(error.ResponseTooLarge, attestation.parseAndBind(std.testing.allocator, &oversized, expected()));
}

test "release attestation execution uses clean token environment and supplied capture" {
    const Fake = struct {
        pub fn capture(_: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
            try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
            try std.testing.expectEqualStrings("release", args[0]);
            try std.testing.expect(budget_ns > 0);
            try std.testing.expectEqual(@as(usize, 2), environment.len);
            try std.testing.expectEqualStrings("GH_TOKEN=secret-token", environment[0]);
            try std.testing.expectEqualStrings("GH_PROMPT_DISABLED=1", environment[1]);
            @memcpy(output[0..valid_json.len], valid_json);
            return output[0..valid_json.len];
        }
    };
    var fake = Fake{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    var observed = try attestation.verifyWith(&fake, std.testing.allocator, "/opt/trusted/gh", "secret-token", .release, expected(), &output, std.time.ns_per_s);
    defer observed.deinit();
    var asset_observed = try attestation.verifyWith(&fake, std.testing.allocator, "/opt/trusted/gh", "secret-token", .{ .asset = .{ .path = "/tmp/Maru-1.2.3-universal.dmg", .expected = assets[0] } }, expected(), &output, std.time.ns_per_s);
    defer asset_observed.deinit();
}

test "release attestation rejects foreign capture token and budget" {
    const Foreign = struct {
        pub fn capture(_: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
            return valid_json;
        }
    };
    var foreign = Foreign{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidCapture, attestation.verifyWith(&foreign, std.testing.allocator, "/opt/trusted/gh", "secret-token", .release, expected(), &output, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidToken, attestation.verifyWith(&foreign, std.testing.allocator, "/opt/trusted/gh", "bad\ntoken", .release, expected(), &output, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidBudget, attestation.verifyWith(&foreign, std.testing.allocator, "/opt/trusted/gh", "secret-token", .release, expected(), &output, 0));
}

test "release attestation product execution fails closed on child failure" {
    var output: [attestation.max_response_bytes]u8 = undefined;
    try std.testing.expectError(error.ChildFailed, attestation.verify(std.testing.io, std.testing.allocator, "/usr/bin/false", "secret-token", .release, expected(), &output, std.time.ns_per_s));
}

test "release attestation parse unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseForAllocationTest, .{});
}

fn parseForAllocationTest(allocator: std.mem.Allocator) !void {
    var observed = try attestation.parseAndBind(allocator, valid_json, expected());
    observed.deinit();
}

fn expectArgs(expected_args: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected_args.len, actual.len);
    for (expected_args, actual) |left, right| try std.testing.expectEqualStrings(left, right);
}
