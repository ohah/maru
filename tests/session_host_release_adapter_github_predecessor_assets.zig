//! Authenticated predecessor manifest composition owns download, release proof and tag convergence.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const git = @import("release_adapter_github_git");
const deadline_mod = @import("release_adapter_deadline");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const composition = @import("release_adapter_github_predecessor_assets");

const commit = "0123456789abcdef0123456789abcdef01234567";
const tag_object = "89abcdef0123456789abcdef0123456789abcdef";
const a_sha = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb";
const b_sha = "3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d";
const c_sha = "2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6";
const manifest_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
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
    \\{"name":"summary.json","digest":{"sha256":"2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6"}},
    \\{"name":"Maru-1.2.3-session-host-release.json","digest":{"sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}],
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
    budgets: [7]i128 = @splat(0),
    response: []const u8 = valid_json,
    mutate_on_asset: bool = false,
    pub fn capture(self: *@This(), _: []const u8, args: []const []const u8, _: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        self.budgets[self.calls] = budget_ns;
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

const SharedDeadline = struct {
    values: []const i128,
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.DeadlineExhausted;
        const value = self.values[self.cursor];
        self.cursor += 1;
        if (value <= 0) return error.TimedOut;
        return value;
    }
};

const FakeAuthenticated = struct {
    value_storage: manifest.Manifest,
    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return &self.value_storage;
    }
    pub fn evidenceView(self: *const @This()) ?authenticated_manifest.AuthenticatedManifest.EvidenceView {
        return .{ .value = &self.value_storage, .subject_name = "Maru-1.2.3-session-host-release.json", .subject_sha256 = manifest_sha, .run_id = self.value_storage.build.run_id, .run_attempt = self.value_storage.build.run_attempt };
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

test "shared deadline spans seven commands and final publication while expiry removes downloads" {
    var manifest_storage = candidate();
    var architecture_storage = [_][]const u8{ "arm64", "x86_64" };
    var asset_storage = [_]manifest.Asset{manifest_storage.assets[0]};
    var predecessor_storage: manifest.Predecessor = .{ .release_id = 1, .tag = "v1.2.2", .commit = commit, .manifest_sha256 = a_sha };
    manifest_storage.signing.architectures = &architecture_storage;
    manifest_storage.assets = &asset_storage;
    manifest_storage.predecessor = predecessor_storage;
    try std.testing.expect(manifest.aliasesStorage(&manifest_storage, std.mem.asBytes(&manifest_storage)));
    try std.testing.expect(manifest.aliasesStorage(&manifest_storage, std.mem.asBytes(&architecture_storage)));
    try std.testing.expect(manifest.aliasesStorage(&manifest_storage, std.mem.asBytes(&asset_storage)));
    try std.testing.expect(manifest.aliasesStorage(&manifest_storage, std.mem.asBytes(&predecessor_storage)) == false);
    try std.testing.expect(manifest.aliasesStorage(&manifest_storage, predecessor_storage.tag));

    var auth = FakeAuthenticated{ .value_storage = candidate() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var deadline = SharedDeadline{ .values = &.{ 100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87, 86 } };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedPredecessorAssets = .{};
    const work = try absolute(&tmp, "assets", &path);
    try composition.composeUntilWith(&authority, &executor, &deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", work, &output, &result);
    try std.testing.expectEqual(@as(usize, 15), deadline.cursor);
    try std.testing.expectEqualSlices(i128, &.{ 99, 97, 95, 93, 91, 89, 87 }, &executor.budgets);
    try result.cleanup();

    authority = .{};
    executor = .{};
    deadline = .{ .values = &.{ 100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87, 0 } };
    const final_expired_work = try absolute(&tmp, "final-expired-assets", &path);
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &executor, &deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", final_expired_work, &output, &result));
    try std.testing.expectEqual(@as(usize, 7), authority.calls);
    try std.testing.expectEqual(@as(usize, 7), executor.calls);
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "final-expired-assets", .{}));

    authority = .{};
    executor = .{};
    deadline = .{ .values = &.{ 100, 99, 98, 97, 96, 95, 94, 0 } };
    const expired_work = try absolute(&tmp, "expired-assets", &path);
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &executor, &deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", expired_work, &output, &result));
    try std.testing.expectEqual(@as(usize, 4), authority.calls);
    try std.testing.expectEqual(@as(usize, 3), executor.calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "expired-assets", .{}));

    authority = .{};
    executor = .{};
    deadline = .{ .values = &.{0} };
    const unopened_work = try absolute(&tmp, "unopened-assets", &path);
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &executor, &deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", unopened_work, &output, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "unopened-assets", .{}));

    var real_deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(100, &real_deadline);
    defer real_deadline.deinit() catch unreachable;
    var absent: authenticated_manifest.AuthenticatedManifest = .{};
    var pinned_storage: [256]u8 align(16) = undefined;
    try std.testing.expectError(error.InvalidManifest, composition.composeUntil(std.testing.io, std.testing.allocator, &absent, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, .{ .path = "/opt/trusted/gh", .pinned = @ptrCast(&pinned_storage) }, "token", "/tmp/not-created", &output, &real_deadline, &result));

    var untouched_deadline = SharedDeadline{ .values = &.{100} };
    const result_alias = std.mem.asBytes(&result);
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &untouched_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", result_alias, &result));
    var token_storage: [5]u8 = "token".*;
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &untouched_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", &token_storage, "/tmp/not-created", &token_storage, &result));
    var work_storage: [16:0]u8 = "/tmp/not-created".*;
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &untouched_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", &work_storage, work_storage[0..], &result));
    try std.testing.expectEqual(@as(usize, 0), untouched_deadline.cursor);

    const result_deadline: *SharedDeadline = @ptrCast(@alignCast(&result));
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, result_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", &output, &result));

    const authenticated_deadline: *SharedDeadline = @ptrCast(@alignCast(&auth));
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, authenticated_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", &output, &result));

    var deadline_token_storage: [@sizeOf(SharedDeadline)]u8 align(@alignOf(SharedDeadline)) = undefined;
    const token_deadline: *SharedDeadline = @ptrCast(&deadline_token_storage);
    token_deadline.* = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, token_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", &deadline_token_storage, "/tmp/not-created", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), token_deadline.cursor);

    var deadline_work_storage: [@sizeOf(SharedDeadline) + 1:0]u8 align(@alignOf(SharedDeadline)) = @splat(0);
    const work_deadline: *SharedDeadline = @ptrCast(&deadline_work_storage);
    work_deadline.* = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, work_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", deadline_work_storage[0..@sizeOf(SharedDeadline) :0], &output, &result));
    try std.testing.expectEqual(@as(usize, 0), work_deadline.cursor);

    var deadline_output_storage: [@sizeOf(SharedDeadline)]u8 align(@alignOf(SharedDeadline)) = undefined;
    const output_deadline: *SharedDeadline = @ptrCast(&deadline_output_storage);
    output_deadline.* = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, output_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", &deadline_output_storage, &result));
    try std.testing.expectEqual(@as(usize, 0), output_deadline.cursor);

    var manifest_output_alias = FakeAuthenticated{ .value_storage = candidate() };
    manifest_output_alias.value_storage.release.tag = output[0..1];
    var manifest_alias_deadline = SharedDeadline{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &manifest_alias_deadline, std.testing.allocator, &manifest_output_alias, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), manifest_alias_deadline.cursor);

    var owned_manifest_deadline = SharedDeadline{ .values = &.{100} };
    var manifest_deadline_alias = FakeAuthenticated{ .value_storage = candidate() };
    manifest_deadline_alias.value_storage.signing.team_id = std.mem.asBytes(&owned_manifest_deadline);
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &owned_manifest_deadline, std.testing.allocator, &manifest_deadline_alias, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), owned_manifest_deadline.cursor);

    var token_result: composition.AuthenticatedPredecessorAssets = .{};
    var independent_deadline = SharedDeadline{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &independent_deadline, std.testing.allocator, &auth, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", std.mem.asBytes(&token_result), "/tmp/not-created", &output, &token_result));
    try std.testing.expectEqual(@as(usize, 0), independent_deadline.cursor);

    var manifest_result: composition.AuthenticatedPredecessorAssets = .{};
    var manifest_result_alias = FakeAuthenticated{ .value_storage = candidate() };
    manifest_result_alias.value_storage.evidence.test_uuid = std.mem.asBytes(&manifest_result);
    independent_deadline = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &executor, &independent_deadline, std.testing.allocator, &manifest_result_alias, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, "/opt/trusted/gh", "token", "/tmp/not-created", &output, &manifest_result));
    try std.testing.expectEqual(@as(usize, 0), independent_deadline.cursor);

    try std.testing.expectError(error.InvalidOwner, composition.composeUntil(std.testing.io, std.testing.allocator, &absent, .{ .tag = "v1.2.3", .target = .{ .kind = .commit, .sha = commit } }, &.{}, .{ .path = "/opt/trusted/gh", .pinned = @ptrCast(@alignCast(&real_deadline)) }, "token", "/tmp/not-created", &output, &real_deadline, &result));
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
