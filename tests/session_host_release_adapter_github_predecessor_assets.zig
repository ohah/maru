//! Authenticated predecessor manifest composition owns download, release proof and tag convergence.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const git = @import("release_adapter_github_git");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const composition = @import("release_adapter_github_predecessor_assets");

const commit = "0123456789abcdef0123456789abcdef01234567";
const tag_object = "89abcdef0123456789abcdef0123456789abcdef";
const a_sha = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb";
const b_sha = "3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d";
const c_sha = "2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6";
const assets = [_]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3.dmg", .sha256 = a_sha, .size = 1 },
    .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = b_sha, .size = 1 },
    .{ .role = .evidence_summary, .name = "summary.json", .sha256 = c_sha, .size = 1 },
};

fn candidate() manifest.Manifest {
    return .{ .schema = manifest.schema, .role = .a, .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" }, .release = .{ .id = 67890, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &assets, .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "summary.json", .summary_sha256 = c_sha, .result = "passed" } };
}

const valid_json =
    \\{"attestation":{},"verificationResult":{"signature":{"certificate":{"subjectAlternativeName":"https://dotcom.releases.github.com"}},
    \\"statement":{"_type":"https://in-toto.io/Statement/v1","subject":[{"uri":"pkg:github/ohah/maru@v1.2.3","digest":{"sha1":"0123456789abcdef0123456789abcdef01234567"}},
    \\{"name":"Maru-1.2.3.dmg","digest":{"sha256":"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"}},
    \\{"name":"maru-session-host","digest":{"sha256":"3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d"}},
    \\{"name":"summary.json","digest":{"sha256":"2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6"}}],
    \\"predicateType":"https://in-toto.io/attestation/release/v0.1","predicate":{"ownerId":"2468","purl":"pkg:github/ohah/maru@v1.2.3","releaseId":"67890","repository":"ohah/maru","repositoryId":"12345","tag":"v1.2.3"}},
    \\"verifiedTimestamps":[{"type":"TimestampAuthority","uri":"timestamp.githubapp.com","timestamp":"2026-09-01T00:00:00Z"}]}}
;

const Authority = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.ExecutableChanged;
    }
};
const Executor = struct {
    calls: usize = 0,
    response: []const u8 = valid_json,
    mutate_on_asset: bool = false,
    pub fn capture(self: *@This(), _: []const u8, args: []const []const u8, _: []const []const u8, output: []u8, _: i128) ![]const u8 {
        self.calls += 1;
        if (std.mem.eql(u8, args[1], "download")) {
            const pattern = args[6];
            output[0] = if (std.mem.indexOf(u8, pattern, "Maru-") != null) 'a' else if (std.mem.indexOf(u8, pattern, "session-host") != null) 'b' else 'c';
            return output[0..1];
        }
        @memcpy(output[0..self.response.len], self.response);
        if (self.mutate_on_asset and std.mem.eql(u8, args[1], "verify-asset")) {
            var storage: [std.fs.max_path_bytes:0]u8 = undefined;
            const z = try std.fmt.bufPrintZ(&storage, "{s}", .{args[3]});
            if (c.chmod(z.ptr, 0o600) != 0) return error.MutationFailed;
            self.mutate_on_asset = false;
        }
        return output[0..self.response.len];
    }
};

const FakeAuthenticated = struct {
    value_storage: manifest.Manifest,
    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return &self.value_storage;
    }
};
fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

test "lightweight tag publishes exact authenticated predecessor assets" {
    _ = composition.compose;
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    try composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result);
    try std.testing.expectEqual(@as(usize, 7), authority.calls);
    try std.testing.expectEqual(@as(usize, 7), executor.calls);
    try std.testing.expectEqualStrings(commit, result.value().?.source_commit);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.cleanup();
}

test "annotated tag ref digest remains distinct and converges through resolver" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    const tag_rows = [_]git.TagObservation{.{ .tag = "v1.2.3", .object_sha = tag_object, .target = .{ .kind = .commit, .sha = commit } }};
    const tagged_json = try std.mem.replaceOwned(u8, std.testing.allocator, valid_json, commit, tag_object);
    defer std.testing.allocator.free(tagged_json);
    executor.response = tagged_json;
    try composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .tag, .sha = tag_object } }, &tag_rows, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result);
    try std.testing.expectEqualStrings(commit, result.value().?.source_commit);
    try result.cleanup();
}

test "CLI failure publishes nothing and cleans downloads" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{ .fail_at = 4 };
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    const work = try absolute(&tmp, "assets", &path);
    try std.testing.expectError(error.ExecutableChanged, composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", work, &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "assets", .{}));
}

test "post verification file drift publishes nothing but preserves cleanup authority" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{ .mutate_on_asset = true };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    try std.testing.expectError(error.FileChanged, composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "assets", .{}));
}

test "release tag ref mismatch publishes nothing and cleans downloads" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    try std.testing.expectError(error.AttestationMismatch, composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = "ffffffffffffffffffffffffffffffffffffffff" } }, &.{}, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "assets", .{}));
}

test "extra tag observation cannot be ignored after convergence" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    const extra = [_]git.TagObservation{.{ .tag = "v1.2.3", .object_sha = tag_object, .target = .{ .kind = .commit, .sha = commit } }};
    try std.testing.expectError(error.InvalidState, composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &extra, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "assets", .{}));
}

test "annotated tag cycle is terminal and cleans downloads" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    const tagged_json = try std.mem.replaceOwned(u8, std.testing.allocator, valid_json, commit, tag_object);
    defer std.testing.allocator.free(tagged_json);
    executor.response = tagged_json;
    const cycle = [_]git.TagObservation{.{ .tag = "v1.2.3", .object_sha = tag_object, .target = .{ .kind = .tag, .sha = tag_object } }};
    try std.testing.expectError(error.Cycle, composition.composeWith(&authority, &executor, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .tag, .sha = tag_object } }, &cycle, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "assets", .{}));
}

test "allocation failure and unauthenticated product input publish nothing" {
    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, composition.composeWith(&authority, &executor, fixed.allocator(), &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", try absolute(&tmp, "assets", &path), &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "assets", .{}));

    var absent: authenticated_manifest.AuthenticatedManifest = .{};
    var pinned: @import("release_adapter_github_cli_authority").PinnedExecutable = undefined;
    try std.testing.expectError(error.InvalidManifest, composition.compose(std.testing.io, std.testing.allocator, &absent, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, .{ .path = "/opt/trusted/gh", .pinned = &pinned }, "token", "/tmp/not-created", &output, std.time.ns_per_s, &result));
}
