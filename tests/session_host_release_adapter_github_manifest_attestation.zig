//! Predecessor manifest authentication composition publishes nothing before every binding holds.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const deadline_mod = @import("release_adapter_deadline");
const manifest_file = @import("release_adapter_github_manifest_file");
const composition = @import("release_adapter_github_manifest_attestation");

const commit = "0123456789abcdef0123456789abcdef01234567";
const digest_placeholder = "0000000000000000000000000000000000000000000000000000000000000000";
const valid_attestation =
    \\[{"attestation":{},"verificationResult":{"signature":{"certificate":{
    \\"subjectAlternativeName":"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
    \\"issuer":"https://token.actions.githubusercontent.com","githubWorkflowTrigger":"push","githubWorkflowSHA":"0123456789abcdef0123456789abcdef01234567","githubWorkflowRepository":"ohah/maru",
    \\"githubWorkflowRef":"refs/tags/v1.2.3","buildSignerURI":"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3","buildSignerDigest":"0123456789abcdef0123456789abcdef01234567","runnerEnvironment":"github-hosted",
    \\"sourceRepositoryURI":"https://github.com/ohah/maru","sourceRepositoryDigest":"0123456789abcdef0123456789abcdef01234567","sourceRepositoryRef":"refs/tags/v1.2.3","sourceRepositoryIdentifier":"12345",
    \\"sourceRepositoryOwnerURI":"https://github.com/ohah","buildConfigURI":"https://github.com/ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3","buildConfigDigest":"0123456789abcdef0123456789abcdef01234567","buildTrigger":"push",
    \\"runInvocationURI":"https://github.com/ohah/maru/actions/runs/333/attempts/2","sourceRepositoryVisibilityAtSigning":"public"}},
    \\"statement":{"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"Maru-1.2.3-session-host-release.json","digest":{"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}}],
    \\"predicateType":"https://slsa.dev/provenance/v1","predicate":{"buildDefinition":{"buildType":"https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1","externalParameters":{"workflow":{"path":".github/workflows/release.yml","ref":"refs/tags/v1.2.3","repository":"https://github.com/ohah/maru"}},
    \\"internalParameters":{"github":{"event_name":"push","repository_id":"12345"}},"resolvedDependencies":[{"uri":"git+https://github.com/ohah/maru@refs/tags/v1.2.3","digest":{"gitCommit":"0123456789abcdef0123456789abcdef01234567"}}]},
    \\"runDetails":{"builder":{"id":"https://github.com/actions/runner/github-hosted"},"metadata":{"invocationId":"https://github.com/ohah/maru/actions/runs/333/attempts/2"}}}},"verifiedTimestamps":[{"type":"TimestampAuthority","uri":"timestamp.githubapp.com","timestamp":"2026-08-31T00:00:00Z"}]}}]
;

fn candidate() manifest.Manifest {
    const assets = &[_]manifest.Asset{
        .{ .role = .universal_dmg, .name = "Maru-1.2.3.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 },
        .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 },
        .{ .role = .evidence_summary, .name = "summary.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 },
    };
    return .{
        .schema = manifest.schema,
        .role = .a,
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
        .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = assets,
        .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "summary.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
    };
}

fn trustedContext() composition.TrustedContext {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

const Never = struct {
    calls: usize = 0,
    pub fn capture(self: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
        self.calls += 1;
        return error.UnexpectedCall;
    }
};

const Authority = struct {
    calls: usize = 0,
    fail: bool = false,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.fail) return error.ExecutableChanged;
    }
};

const Attesting = struct {
    sha: []const u8,
    calls: usize = 0,
    fail: bool = false,
    mutate_after: bool = false,
    budget_ns: i128 = 0,
    pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        self.calls += 1;
        self.budget_ns = budget_ns;
        if (self.fail) return error.ChildFailed;
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("attestation", args[0]);
        try std.testing.expectEqualStrings("verify", args[1]);
        try std.testing.expectEqualStrings("GH_TOKEN=token", environment[0]);
        @memcpy(output[0..valid_attestation.len], valid_attestation);
        const offset = std.mem.indexOf(u8, output[0..valid_attestation.len], digest_placeholder) orelse return error.MissingDigest;
        @memcpy(output[offset .. offset + 64], self.sha);
        if (self.mutate_after) {
            var path: [std.fs.max_path_bytes:0]u8 = undefined;
            const path_z = try std.fmt.bufPrintZ(&path, "{s}", .{args[2]});
            if (c.chmod(path_z.ptr, 0o600) != 0) return error.MutationFailed;
        }
        return output[0..valid_attestation.len];
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

fn expectCandidateRejected(value: manifest.Manifest, file_name: []const u8) !void {
    const bytes = try manifest.writeCanonical(std.testing.allocator, value);
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = file_name, .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    var authority = Authority{};
    var executor = Never{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try std.testing.expectError(error.InvalidPredecessor, composition.authenticateWith(&authority, &executor, std.testing.allocator, trustedContext(), .{
        .release_id = value.release.id,
        .tag = value.release.tag,
        .commit = value.source.commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
}

fn authenticateAllocationCase(allocator: std.mem.Allocator, bytes: []const u8, sha: []const u8, file: *manifest_file.ManifestFile) !void {
    var authority = Authority{};
    var executor = Attesting{ .sha = sha };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try composition.authenticateWith(&authority, &executor, allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = sha,
    }, bytes, file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result);
    try result.deinit(allocator);
}

test "predecessor cross-binding rejects release drift before attestation" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    var fake = Never{};
    var authority = Authority{};
    var output: [1024]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try std.testing.expectError(error.InvalidPredecessor, composition.authenticateWith(&authority, &fake, std.testing.allocator, trustedContext(), .{
        .release_id = 78,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
}

test "manifest revalidation detects content drift before attestation" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    const observed = file.observation().?;
    var observed_path: [std.fs.max_path_bytes:0]u8 = undefined;
    const observed_z = try std.fmt.bufPrintZ(&observed_path, "{s}", .{observed.path});
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(observed_z.ptr, 0o600));
    var fake = Never{};
    var authority = Authority{};
    var output: [1024]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try std.testing.expectError(error.FileChanged, composition.authenticateWith(&authority, &fake, std.testing.allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(observed_z.ptr, 0o400));
    try tmp.dir.rename("work", tmp.dir, "owned-work", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "work", .default_dir);
    try std.testing.expectError(error.FileChanged, composition.authenticateWith(&authority, &fake, std.testing.allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try tmp.dir.deleteDir(std.testing.io, "work");
    try tmp.dir.rename("owned-work", tmp.dir, "work", std.testing.io);
    try file.cleanup();
}

test "exact authority and attestation publish one authenticated manifest" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    var authority = Authority{};
    var executor = Attesting{ .sha = &sha };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try composition.authenticateWith(&authority, &executor, std.testing.allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result);
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expectEqual(@as(u64, 77), result.value().?.release.id);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit(std.testing.allocator);
}

test "shared deadline brackets CLI attestation and final publication" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    const predecessor: manifest.Predecessor = .{ .release_id = 77, .tag = "v1.2.3", .commit = commit, .manifest_sha256 = &sha };
    var authority = Authority{};
    var executor = Attesting{ .sha = &sha };
    var deadline = SharedDeadline{ .values = &.{ 100, 70, 40 } };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result);
    try std.testing.expectEqual(@as(usize, 3), deadline.cursor);
    try std.testing.expectEqual(@as(i128, 70), executor.budget_ns);
    try result.deinit(std.testing.allocator);

    authority = .{};
    executor = .{ .sha = &sha };
    deadline = .{ .values = &.{ 100, 70, 0 } };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), executor.calls);
    try std.testing.expect(result.value() == null);

    authority = .{};
    executor = .{ .sha = &sha };
    deadline = .{ .values = &.{ 100, 0 } };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expect(result.value() == null);

    authority = .{};
    executor = .{ .sha = &sha };
    deadline = .{ .values = &.{0} };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&authority, &executor, &deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expect(result.value() == null);

    const result_deadline: *SharedDeadline = @ptrCast(@alignCast(&result));
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&authority, &executor, result_deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result));

    const file_deadline: *SharedDeadline = @ptrCast(@alignCast(&file));
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&authority, &executor, file_deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result));

    var output_deadline_storage: [@sizeOf(SharedDeadline)]u8 align(@alignOf(SharedDeadline)) = undefined;
    const output_deadline: *SharedDeadline = @ptrCast(&output_deadline_storage);
    output_deadline.* = .{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&authority, &executor, output_deadline, std.testing.allocator, trustedContext(), predecessor, bytes, &file, "/opt/trusted/gh", "token", &output_deadline_storage, &result));
    try std.testing.expectEqual(@as(usize, 0), output_deadline.cursor);

    var scalar_deadline = SharedDeadline{ .values = &.{100} };
    var aliased_predecessor = predecessor;
    aliased_predecessor.tag = std.mem.asBytes(&scalar_deadline);
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&authority, &executor, &scalar_deadline, std.testing.allocator, trustedContext(), aliased_predecessor, bytes, &file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), scalar_deadline.cursor);

    var real_deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(100, &real_deadline);
    defer real_deadline.deinit() catch unreachable;
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntil(std.testing.io, std.testing.allocator, trustedContext(), predecessor, bytes, &file, .{ .path = "/opt/trusted/gh", .pinned = @ptrCast(@alignCast(&result)) }, "token", &output, &real_deadline, &result));
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntil(std.testing.io, std.testing.allocator, trustedContext(), predecessor, bytes, &file, .{ .path = "/opt/trusted/gh", .pinned = undefined }, "token", &output, &real_deadline, &result));
}

test "post-attestation file drift publishes nothing and preserves cleanup authority" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    const observed = file.observation().?;
    var observed_path: [std.fs.max_path_bytes:0]u8 = undefined;
    const observed_z = try std.fmt.bufPrintZ(&observed_path, "{s}", .{observed.path});
    var authority = Authority{};
    var executor = Attesting{ .sha = &sha, .mutate_after = true };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try std.testing.expectError(error.FileChanged, composition.authenticateWith(&authority, &executor, std.testing.allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(observed_z.ptr, 0o400));
    try file.cleanup();
}

test "child and allocation failure publish nothing" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    var authority = Authority{};
    var executor = Attesting{ .sha = &sha, .fail = true };
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    try std.testing.expectError(error.ChildFailed, composition.authenticateWith(&authority, &executor, std.testing.allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expect(result.value() == null);
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    authority.calls = 0;
    try std.testing.expectError(error.OutOfMemory, composition.authenticateWith(&authority, &executor, fixed.allocator(), trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
}

test "CLI authority failure prevents attestation and product wrapper is compiled" {
    _ = composition.authenticate;
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    var authority = Authority{ .fail = true };
    var executor = Never{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedManifest = .{};
    var unprotected = trustedContext();
    unprotected.protected_tag = false;
    try std.testing.expectError(error.InvalidPredecessor, composition.authenticateWith(&authority, &executor, std.testing.allocator, unprotected, .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    authority.fail = true;
    try std.testing.expectError(error.ExecutableChanged, composition.authenticateWith(&authority, &executor, std.testing.allocator, trustedContext(), .{
        .release_id = 77,
        .tag = "v1.2.3",
        .commit = commit,
        .manifest_sha256 = &sha,
    }, bytes, &file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), executor.calls);
    try std.testing.expect(result.value() == null);
}

test "role B predecessor and foreign canonical filename never reach attestation" {
    try expectCandidateRejected(candidate(), "Maru-9.9.9-session-host-release.json");
    var role_b = candidate();
    role_b.role = .b;
    role_b.predecessor = .{
        .release_id = 1,
        .tag = "v1.0.0",
        .commit = "1111111111111111111111111111111111111111",
        .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    };
    try expectCandidateRejected(role_b, "Maru-1.2.3-session-host-release.json");
}

test "successful composition unwinds every allocation failure" {
    const bytes = try manifest.writeCanonical(std.testing.allocator, candidate());
    defer std.testing.allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var file: manifest_file.ManifestFile = .{};
    try manifest_file.materialize(&file, try absolute(&tmp, "work", &path), .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = &sha, .bytes = bytes });
    defer file.cleanup() catch {};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, authenticateAllocationCase, .{ bytes, &sha, &file });
}
