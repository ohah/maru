//! A retained release aggregate is reopened and semantically bound by a fresh process owner.

const std = @import("std");
const c = std.c;
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const context_mod = @import("release_adapter_context");
const cli_authority = @import("release_adapter_github_cli_authority");
const handoff = @import("release_adapter_candidate_aggregate_handoff");
const reopen = @import("release_adapter_candidate_aggregate_reopen");
const manifest_mod = @import("release_manifest");
const post = @import("release_adapter_github_post_publish_attestation");
const retention = @import("release_adapter_candidate_aggregate_retention");

const source_names = [_][]const u8{
    "release-evidence.json",
    "dmg.bundle.json",
    "frozen.bundle.json",
    "evidence.bundle.json",
    "manifest.bundle.json",
};
const source_bytes = [_][]const u8{
    "{\"schema\":\"maru.session-host-release-evidence.v1\"}\n",
    "candidate dmg bundle\n",
    "candidate frozen bundle\n",
    "evidence bundle\n",
    "manifest bundle\n",
};
const artifact_names = [_][]const u8{
    "Maru-1.2.3-universal.dmg",
    "maru-session-host-1.2.3",
    "Maru-1.2.3-session-host-release.json",
};
const artifact_bytes = [_][]const u8{ "candidate dmg bytes\n", "frozen executable bytes\n", "manifest placeholder\n" };

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn canonicalManifest(dmg_name: []const u8) ![]u8 {
    const dmg_sha = sha256Hex(artifact_bytes[0]);
    const frozen_sha = sha256Hex(artifact_bytes[1]);
    const evidence_sha = sha256Hex(source_bytes[0]);
    const assets = [_]manifest_mod.Asset{
        .{ .role = .universal_dmg, .name = dmg_name, .sha256 = &dmg_sha, .size = artifact_bytes[0].len },
        .{ .role = .frozen_product_executable, .name = artifact_names[1], .sha256 = &frozen_sha, .size = artifact_bytes[1].len },
        .{ .role = .evidence_summary, .name = source_names[0], .sha256 = &evidence_sha, .size = source_bytes[0].len },
    };
    return manifest_mod.writeCanonical(std.testing.allocator, .{
        .schema = manifest_mod.schema,
        .role = .a,
        .repository = .{ .id = 55, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 88, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = "0123456789abcdef0123456789abcdef01234567", .tree = "1111111111111111111111111111111111111111" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 7, .run_attempt = 1 },
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
        .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = &assets,
        .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = source_names[0], .summary_sha256 = &evidence_sha, .result = "passed" },
    });
}

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 55, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{
            .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
            .run_id = 7,
            .run_attempt = 1,
        },
        .protected_tag = true,
    };
}

const Observation = struct {
    verified: bool = true,
    run_id: u64 = 7,
    run_attempt: u64 = 1,
    subject_name: []const u8,
    subject_sha256: []const u8,
    allocation: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.allocation) |bytes| allocator.free(bytes);
        self.allocation = null;
    }
};

const Executor = struct {};

const Verifier = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    foreign_at: ?usize = null,
    mutate_at: ?usize = null,
    mutate_path: ?[:0]const u8 = null,
    add_entry_at: ?usize = null,
    extra_path: ?[:0]const u8 = null,
    allocate: bool = false,
    artifact_paths: [4][]const u8 = @splat(""),
    bundle_paths: [4][]const u8 = @splat(""),
    names: [4][]const u8 = @splat(""),
    digests: [4][64]u8 = @splat(@splat(0)),

    pub fn verifyBundleWith(
        self: *@This(),
        _: *Executor,
        allocator: std.mem.Allocator,
        _: []const u8,
        artifact_path: []const u8,
        bundle_path: []const u8,
        expected: anytype,
        _: []u8,
        budget_ns: i128,
    ) !Observation {
        if (budget_ns <= 0 or self.calls >= 4) return error.BadCall;
        const index = self.calls;
        self.calls += 1;
        self.artifact_paths[index] = artifact_path;
        self.bundle_paths[index] = bundle_path;
        self.names[index] = expected.subject_name;
        @memcpy(&self.digests[index], expected.subject_sha256);
        if (self.add_entry_at == index) if (self.extra_path) |path| {
            const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
            if (fd < 0) return error.FixtureFailed;
            _ = c.write(fd, "x", 1);
            _ = c.close(fd);
        };
        if (self.mutate_at == index) if (self.mutate_path) |path| {
            const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
            if (fd < 0) return error.FixtureFailed;
            defer _ = c.close(fd);
            if (c.pwrite(fd, "X", 1, 0) != 1) return error.FixtureFailed;
        };
        if (self.fail_at == index) return error.VerifierFailed;
        const allocation = if (self.allocate) try allocator.alloc(u8, 1) else null;
        return .{
            .subject_name = if (self.foreign_at == index) "foreign" else expected.subject_name,
            .subject_sha256 = expected.subject_sha256,
            .allocation = allocation,
        };
    }
};

const Cli = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    close_fd_at: ?usize = null,
    close_fd: ?*c.fd_t = null,

    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable) !void {
        self.calls += 1;
        if (self.close_fd_at == self.calls) {
            const fd = self.close_fd orelse return error.BadCall;
            if (fd.* < 0 or c.close(fd.*) != 0) return error.BadCall;
        }
        if (self.fail_at == self.calls) return error.ExecutableChanged;
        try cli_authority.revalidate(allocator, path, pinned);
    }
};

const Deadline = struct {
    calls: usize = 0,
    fail_at: ?usize = null,

    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.TimedOut;
        return 1_000_000_000;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    source_roots: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    source_paths: [handoff.role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    source_owners: [handoff.role_count]files.PinnedReleaseFile = @splat(.{}),
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    artifact_paths: [3][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    cli_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    cli: cli_authority.PinnedExecutable = undefined,
    prepared: bool = false,

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        for ([_][]const u8{ "workspace", "bundles", "durable", "artifacts", "tools" }) |name|
            try self.tmp.dir.createDir(std.testing.io, name, .default_dir);
        for (source_names, source_bytes, 0..) |name, bytes, index| {
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&relative, "{s}/{s}", .{ if (index == 0) "workspace" else "bundles", name });
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
        }
        for (artifact_names, artifact_bytes) |name, bytes| {
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&relative, "artifacts/{s}", .{name});
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
        }
        const manifest_bytes = try canonicalManifest(artifact_names[0]);
        defer std.testing.allocator.free(manifest_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "artifacts/Maru-1.2.3-session-host-release.json", .data = manifest_bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tools/gh", .data = "#!/bin/sh\nexit 1\n" });
        _ = try absolute(&self.tmp, "workspace", &self.source_roots[0]);
        _ = try absolute(&self.tmp, "bundles", &self.source_roots[1]);
        _ = try absolute(&self.tmp, "durable/handoff", &self.destination);
        for (source_names, 0..) |name, index| {
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&relative, "{s}/{s}", .{ if (index == 0) "workspace" else "bundles", name });
            const absolute_path = try absolute(&self.tmp, path, &self.source_paths[index]);
            try files.pinReleaseFileObserved(&self.source_owners[index], absolute_path, false, if (index == 0) evidence.max_evidence_bytes else handoff.max_attestation_bundle_bytes);
        }
        for (artifact_names, 0..) |name, index| {
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&relative, "artifacts/{s}", .{name});
            _ = try absolute(&self.tmp, path, &self.artifact_paths[index]);
        }
        const frozen = std.mem.sliceTo(&self.artifact_paths[1], 0);
        if (c.chmod(frozen.ptr, 0o755) != 0) return error.FixtureFailed;
        const cli_path = try absolute(&self.tmp, "tools/gh", &self.cli_path);
        if (c.chmod(cli_path.ptr, 0o755) != 0) return error.FixtureFailed;
        var input = try files.readInputAlloc(std.testing.allocator, cli_path, cli_authority.max_executable_bytes);
        defer input.deinit(std.testing.allocator);
        self.cli = try cli_authority.pin(std.testing.allocator, cli_path, &input.sha256);
    }

    fn deinit(self: *@This()) void {
        for (&self.source_owners) |*owner| if (owner.value() != null) owner.deinit() catch {};
        self.tmp.cleanup();
    }

    fn prepare(self: *@This()) !void {
        var aggregate: handoff.DurableAggregate = .{};
        try handoff.promote(std.testing.allocator, self.sources(), self.destinationPath(), &aggregate);
        try aggregate.closeRetaining();
        for (&self.source_owners) |*owner| try owner.deinit();
        try self.tmp.dir.deleteTree(std.testing.io, "workspace");
        try self.tmp.dir.deleteTree(std.testing.io, "bundles");
        self.prepared = true;
    }

    fn replaceManifest(self: *@This(), dmg_name: []const u8) !void {
        const manifest_bytes = try canonicalManifest(dmg_name);
        defer std.testing.allocator.free(manifest_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "artifacts/Maru-1.2.3-session-host-release.json", .data = manifest_bytes });
    }

    fn sources(self: *@This()) handoff.Sources {
        return .{
            .evidence = self.source(0),
            .candidate_dmg_bundle = self.source(1),
            .candidate_frozen_bundle = self.source(2),
            .evidence_bundle = self.source(3),
            .manifest_bundle = self.source(4),
        };
    }

    fn source(self: *@This(), index: usize) handoff.Source {
        return .{ .file = &self.source_owners[index], .root = std.mem.sliceTo(&self.source_roots[if (index == 0) 0 else 1], 0), .path = std.mem.sliceTo(&self.source_paths[index], 0) };
    }

    fn paths(self: *@This()) reopen.Paths {
        return .{
            .directory = self.destinationPath(),
            .dmg = std.mem.sliceTo(&self.artifact_paths[0], 0),
            .frozen_executable = std.mem.sliceTo(&self.artifact_paths[1], 0),
            .manifest = std.mem.sliceTo(&self.artifact_paths[2], 0),
        };
    }

    fn cliInput(self: *@This()) reopen.Cli {
        return .{ .path = std.mem.sliceTo(&self.cli_path, 0), .pinned = &self.cli };
    }

    fn destinationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.destination, 0);
    }

    fn durablePath(self: *@This(), name: []const u8, storage: []u8) ![:0]const u8 {
        return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ self.destinationPath(), name });
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, output: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(output, "{s}/{s}", .{ root[0..len], suffix });
}

fn verify(fixture: *Fixture, allocator: std.mem.Allocator, verifier: *Verifier, cli: *Cli, deadline: *Deadline, result: *reopen.ReopenedAggregate) !void {
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    try reopen.openAndVerifyWith(cli, verifier, &executor, deadline, allocator, context(), fixture.paths(), fixture.cliInput(), &output, result);
}

const PostAuthority = struct {
    value: post.Snapshot,
    pub fn snapshot(self: *@This()) !post.Snapshot {
        return self.value;
    }
};

const PostDriver = struct {
    pub fn resolve(_: *@This(), expected: post.Snapshot, _: i128) !post.ResolvedTag {
        var result: post.ResolvedTag = undefined;
        @memcpy(&result.tag_ref_sha, "fedcba9876543210fedcba9876543210fedcba98");
        @memcpy(&result.source_commit, expected.source_commit);
        return result;
    }
    pub fn verify(_: *@This(), expected: post.Snapshot, tag: post.ResolvedTag, index: ?usize, _: i128) !post.Observation {
        return post.testing_api.observe(expected, tag, index);
    }
};

const PostDeadline = struct {
    pub fn remaining(_: *@This()) !i128 {
        return std.time.ns_per_s;
    }
};

fn publicationSnapshot(fixture: *Fixture, aggregate: reopen.View) !post.Snapshot {
    const snapshot_paths = [_][]const u8{
        std.mem.sliceTo(&fixture.artifact_paths[0], 0),
        std.mem.sliceTo(&fixture.artifact_paths[1], 0),
        std.mem.sliceTo(&fixture.source_paths[0], 0),
        std.mem.sliceTo(&fixture.artifact_paths[2], 0),
    };
    const snapshot_names = [_][]const u8{ artifact_names[0], artifact_names[1], source_names[0], artifact_names[2] };
    const observations = [_]files.ExecutableObservation{
        aggregate.artifacts[0],
        aggregate.artifacts[1],
        aggregate.entries[0],
        aggregate.artifacts[2],
    };
    var artifacts: [post.artifact_count]post.Artifact = undefined;
    for (&artifacts, 0..) |*artifact, index| artifact.* = .{
        .id = 1000 + index,
        .path = snapshot_paths[index],
        .name = snapshot_names[index],
        .size = observations[index].size,
        .sha256 = observations[index].sha256,
    };
    return .{
        .release_id = 88,
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .cli_sha256 = [_]u8{'f'} ** 64,
        .artifacts = artifacts,
    };
}

fn verifyPublicationReceipt(snapshot: post.Snapshot, verified: *post.VerifiedRelease) !void {
    var authority = PostAuthority{ .value = snapshot };
    var post_driver = PostDriver{};
    var post_deadline = PostDeadline{};
    try post.testing_api.verify(&authority, &post_driver, &post_deadline, verified);
}

fn deleteConcreteOnce() !u64 {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var aggregate: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &aggregate);
    errdefer aggregate.deinit() catch {};

    var verified: post.VerifiedRelease = .{};
    try verifyPublicationReceipt(try publicationSnapshot(&fixture, aggregate.value().?), &verified);
    defer verified.deinit() catch {};

    var deletion: retention.Deletion = .{};
    const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try std.testing.expectEqual(retention.Outcome.success, try retention.deleteVerifiedAggregate(
        std.testing.allocator,
        &aggregate,
        &verified,
        &deletion,
    ));
    const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - started;
    try std.testing.expect(deletion.isPristine());
    try std.testing.expect(aggregate.value() == null);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(std.testing.io, "durable/handoff", .{}));
    try fixture.tmp.dir.access(std.testing.io, "artifacts/Maru-1.2.3-universal.dmg", .{});
    return @intCast(elapsed);
}

test "production deletion removes the exact retained aggregate on a real filesystem" {
    _ = try deleteConcreteOnce();
}

test "production deletion reports local macOS deletion primitive timing samples" {
    var samples: [12]u64 = undefined;
    for (&samples) |*sample| sample.* = try deleteConcreteOnce();
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("\naggregate-retention delete ns median={d} p95={d} samples={d}\n", .{ samples[samples.len / 2], samples[samples.len - 1], samples.len });
}

test "production deletion preserves the aggregate when canonical manifest asset name is foreign" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.replaceManifest("foreign.dmg");
    try fixture.prepare();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var aggregate: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &aggregate);
    defer aggregate.deinit() catch {};
    var verified: post.VerifiedRelease = .{};
    try verifyPublicationReceipt(try publicationSnapshot(&fixture, aggregate.value().?), &verified);
    defer verified.deinit() catch {};
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.audit_required, try retention.deleteVerifiedAggregate(
        std.testing.allocator,
        &aggregate,
        &verified,
        &deletion,
    ));
    try std.testing.expect(deletion.isPristine());
    try fixture.tmp.dir.access(std.testing.io, "durable/handoff", .{});
}

test "production deletion preserves a newly hardlinked entry before rename" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var aggregate: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &aggregate);
    defer aggregate.deinit() catch {};
    var verified: post.VerifiedRelease = .{};
    try verifyPublicationReceipt(try publicationSnapshot(&fixture, aggregate.value().?), &verified);
    defer verified.deinit() catch {};
    try fixture.tmp.dir.hardLink("durable/handoff/release-evidence.json", fixture.tmp.dir, "durable/foreign-alias.json", std.testing.io, .{});
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.audit_required, try retention.deleteVerifiedAggregate(
        std.testing.allocator,
        &aggregate,
        &verified,
        &deletion,
    ));
    try std.testing.expect(deletion.isPristine());
    try fixture.tmp.dir.access(std.testing.io, "durable/handoff/release-evidence.json", .{});
    try fixture.tmp.dir.access(std.testing.io, "durable/foreign-alias.json", .{});
}

test "production deletion leaves a foreign directory replacement untouched" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var aggregate: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &aggregate);
    defer aggregate.deinit() catch {};
    var verified: post.VerifiedRelease = .{};
    try verifyPublicationReceipt(try publicationSnapshot(&fixture, aggregate.value().?), &verified);
    defer verified.deinit() catch {};
    try fixture.tmp.dir.rename("durable/handoff", fixture.tmp.dir, "durable/held-original", std.testing.io);
    try fixture.tmp.dir.createDir(std.testing.io, "durable/handoff", .default_dir);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/handoff/foreign", .data = "do not delete\n" });
    var deletion: retention.Deletion = .{};
    try std.testing.expectEqual(retention.Outcome.audit_required, try retention.deleteVerifiedAggregate(
        std.testing.allocator,
        &aggregate,
        &verified,
        &deletion,
    ));
    try std.testing.expect(deletion.isPristine());
    try fixture.tmp.dir.access(std.testing.io, "durable/handoff/foreign", .{});
    try fixture.tmp.dir.access(std.testing.io, "durable/held-original/release-evidence.json", .{});
}

test "production tomb fence rejects a foreign replacement before first unlink" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var aggregate: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &aggregate);
    defer aggregate.deinit() catch {};

    const tomb = ".maru-aggregate-cleanup-test";
    try fixture.tmp.dir.rename("durable/handoff", fixture.tmp.dir, "durable/" ++ tomb, std.testing.io);
    try fixture.tmp.dir.rename("durable/" ++ tomb, fixture.tmp.dir, "durable/held-original", std.testing.io);
    try fixture.tmp.dir.createDir(std.testing.io, "durable/" ++ tomb, .default_dir);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/" ++ tomb ++ "/foreign", .data = "do not delete\n" });

    var deletion: retention.Deletion = .{};
    deletion.tomb_len = tomb.len;
    @memcpy(deletion.tomb[0..tomb.len], tomb);
    try std.testing.expectError(error.AuthorityChanged, retention.testing_api.fenceConcreteTomb(&aggregate, &deletion));
    try fixture.tmp.dir.access(std.testing.io, "durable/" ++ tomb ++ "/foreign", .{});
    try fixture.tmp.dir.access(std.testing.io, "durable/held-original/release-evidence.json", .{});
}

test "retained aggregate reopens and binds four fixed artifact roles" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result);
    const value = result.value().?;
    try std.testing.expect(value.verified);
    try std.testing.expectEqual(@as(usize, 4), verifier.calls);
    try std.testing.expectEqualStrings(artifact_names[0], verifier.names[0]);
    try std.testing.expectEqualStrings(artifact_names[1], verifier.names[1]);
    try std.testing.expectEqualStrings(source_names[0], verifier.names[2]);
    try std.testing.expectEqualStrings(artifact_names[2], verifier.names[3]);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.close();
    try std.testing.expect(result.value() == null);
}

test "reopen rejects missing extra and renamed fixed inventory" {
    inline for (.{ "missing", "extra", "renamed" }) |mode| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try fixture.prepare();
        var path: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const bundle = try fixture.durablePath(handoff.destinationName(.candidate_dmg_bundle, source_names[0]), &path);
        if (comptime std.mem.eql(u8, mode, "missing")) {
            if (c.unlink(bundle.ptr) != 0) return error.FixtureFailed;
        } else if (comptime std.mem.eql(u8, mode, "extra")) {
            var extra_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
            const extra = try fixture.durablePath("extra", &extra_storage);
            const fd = c.open(extra.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
            if (fd < 0) return error.FixtureFailed;
            _ = c.write(fd, "x", 1);
            _ = c.close(fd);
        } else {
            var renamed_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
            const renamed = try fixture.durablePath("renamed.bundle", &renamed_storage);
            if (c.rename(bundle.ptr, renamed.ptr) != 0) return error.FixtureFailed;
        }
        var verifier = Verifier{};
        var cli = Cli{};
        var deadline = Deadline{};
        var result: reopen.ReopenedAggregate = .{};
        try std.testing.expectError(error.InvalidInventory, verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result));
        try std.testing.expect(result.value() == null);
        try std.testing.expectEqual(@as(usize, 0), verifier.calls);
    }
}

test "artifact names roles and aliases fail before verification" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var paths = fixture.paths();
    paths.dmg = paths.manifest;
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: reopen.ReopenedAggregate = .{};
    try std.testing.expectError(error.InvalidPath, reopen.openAndVerifyWith(&cli, &verifier, &executor, &deadline, std.testing.allocator, context(), paths, fixture.cliInput(), &output, &result));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
}

test "foreign semantic receipt cannot publish a verified aggregate" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{ .foreign_at = 2 };
    var cli = Cli{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    try std.testing.expectError(error.AttestationMismatch, verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result));
    try std.testing.expect(result.value() == null);
}

test "leaf and artifact drift during verifier call fail closed" {
    inline for (.{ "leaf", "artifact" }) |mode| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try fixture.prepare();
        var path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const path = if (comptime std.mem.eql(u8, mode, "leaf"))
            try fixture.durablePath(handoff.destinationName(.evidence_bundle, source_names[0]), &path_storage)
        else
            fixture.paths().dmg;
        var verifier = Verifier{ .mutate_at = 0, .mutate_path = path };
        var cli = Cli{};
        var deadline = Deadline{};
        var result: reopen.ReopenedAggregate = .{};
        try std.testing.expectError(error.AuthorityChanged, verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "extra entry added during verification is detected by the full fence" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var extra_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const extra = try fixture.durablePath("late-extra", &extra_storage);
    var verifier = Verifier{ .add_entry_at = 1, .extra_path = extra };
    var cli = Cli{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    try std.testing.expectError(error.AuthorityChanged, verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result));
    try std.testing.expect(result.value() == null);
}

test "CLI drift timeout and every child failure preserve durable aggregate" {
    inline for (0..6) |failure_index| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try fixture.prepare();
        var verifier = Verifier{ .fail_at = if (failure_index < 4) failure_index else null };
        var cli = Cli{ .fail_at = if (failure_index == 4) 2 else null };
        var deadline = Deadline{ .fail_at = if (failure_index == 5) 2 else null };
        var result: reopen.ReopenedAggregate = .{};
        try std.testing.expectError(if (failure_index < 4) error.VerifierFailed else if (failure_index == 4) error.AuthorityChanged else error.TimedOut, verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result));
        try std.testing.expect(result.value() == null);
        var evidence_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const evidence_path = try fixture.durablePath(source_names[0], &evidence_path_storage);
        var input = try files.readInputAlloc(std.testing.allocator, evidence_path, evidence.max_evidence_bytes);
        input.deinit(std.testing.allocator);
    }
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{ .allocate = true };
    var cli = Cli{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    verify(&fixture, allocator, &verifier, &cli, &deadline, &result) catch |err| switch (err) {
        error.OutOfMemory => {
            try std.testing.expect(result.value() == null);
            return error.OutOfMemory;
        },
        else => return err,
    };
    try result.close();
}

test "every allocation failure leaves no reusable partial owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}

test "successful and failed reopen close every descriptor without deleting durable bytes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    const before = try countFds();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result);
    try result.close();
    try std.testing.expectEqual(before, try countFds());
    var evidence_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const evidence_path = try fixture.durablePath(source_names[0], &evidence_path_storage);
    var input = try files.readInputAlloc(std.testing.allocator, evidence_path, evidence.max_evidence_bytes);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(source_bytes[0], input.bytes);
}

test "audit deinit closes descriptors after a verified artifact changes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    const before = try countFds();
    var verifier = Verifier{};
    var cli = Cli{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    try verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result);
    const dmg = fixture.paths().dmg;
    const fd = c.open(dmg.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    if (c.pwrite(fd, "X", 1, 0) != 1 or c.close(fd) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.AuthorityChanged, result.fence());
    try result.deinit();
    try std.testing.expectEqual(before, try countFds());
}

test "descriptor cleanup failure is observable and preserves durable bytes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var verifier = Verifier{};
    var deadline = Deadline{};
    var result: reopen.ReopenedAggregate = .{};
    var cli = Cli{ .fail_at = 2, .close_fd_at = 2, .close_fd = &result.directory_fd };
    try std.testing.expectError(error.CleanupFailed, verify(&fixture, std.testing.allocator, &verifier, &cli, &deadline, &result));
    try std.testing.expect(result.value() == null);
    var evidence_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const evidence_path = try fixture.durablePath(source_names[0], &evidence_path_storage);
    var input = try files.readInputAlloc(std.testing.allocator, evidence_path, evidence.max_evidence_bytes);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(source_bytes[0], input.bytes);
}

test "production entrypoint cannot select a fake verifier" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_candidate_aggregate_reopen.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn openAndVerify("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn openAndVerifyUntil("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn openAndVerifyWith("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "if (!builtin.is_test) @compileError(\"openAndVerifyWith is a test-only seam\")"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "return openAndVerifyUsing(&cli_impl, &verifier"));
}

fn countFds() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
