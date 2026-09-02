//! Authored aggregate provenance keeps both published inodes pinned while attesting in order.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const authored = @import("release_adapter_candidate_authored_attestation");

fn context() context_mod.Context {
    return .{ .repository = .{ .id = 55, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = "0123456789abcdef0123456789abcdef01234567", .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 7, .run_attempt = 1 }, .protected_tag = true };
}

const Deadline = struct {
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

const Semantic = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, evidence: *const files.PinnedReleaseFile, manifest: *const files.PinnedReleaseFile, paths: authored.Paths) !void {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.SemanticChanged;
        _ = try evidence.revalidate(paths.evidence);
        _ = try manifest.revalidate(paths.manifest);
    }
};

const CliAuthority = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.ExecutableChanged;
    }
};

const Observation = struct {
    verified: bool = true,
    run_id: u64 = 7,
    run_attempt: u64 = 1,
    subject_name: []const u8,
    subject_sha256: []const u8,
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};

const Verifier = struct {
    calls: usize = 0,
    names: [2][]const u8 = @splat(""),
    budgets: [2]i128 = @splat(0),
    fail_at: ?usize = null,
    mutate_on_second: ?[:0]const u8 = null,
    pub fn verifyWith(self: *@This(), _: *Executor, _: std.mem.Allocator, _: []const u8, _: []const u8, path: []const u8, expected: anytype, _: []u8, budget: i128) !Observation {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.AttestationFailed;
        const index = self.calls - 1;
        self.names[index] = expected.subject_name;
        self.budgets[index] = budget;
        if (!std.mem.eql(u8, std.fs.path.basename(path), expected.subject_name)) return error.BadSubject;
        if (self.calls == 2) if (self.mutate_on_second) |target| try mutate(target);
        return .{ .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256 };
    }
};
const Executor = struct {};

const AllocatingObservation = struct {
    verified: bool = true,
    run_id: u64 = 7,
    run_attempt: u64 = 1,
    subject_name: []const u8,
    subject_sha256: []const u8,
    allocation: []u8,
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
    }
};
const AllocatingVerifier = struct {
    pub fn verifyWith(_: *@This(), _: *Executor, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, expected: anytype, _: []u8, _: i128) !AllocatingObservation {
        return .{ .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256, .allocation = try allocator.alloc(u8, 1) };
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, output: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(output, "{s}/{s}", .{ root[0..len], leaf });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    evidence_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence: files.PinnedReleaseFile = .{},
    manifest: files.PinnedReleaseFile = .{},

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        _ = try absolute(&self.tmp, "Maru-1.2.3-session-host-evidence.json", &self.evidence_path);
        _ = try absolute(&self.tmp, "Maru-1.2.3-session-host-release.json", &self.manifest_path);
        try files.publishSummaryOwnedExclusive(&self.evidence, self.evidencePath(), "canonical evidence");
        try files.publishSummaryOwnedExclusive(&self.manifest, self.manifestPath(), "canonical manifest");
    }
    fn deinit(self: *@This()) void {
        if (self.manifest.value() != null) self.manifest.deinit() catch {};
        if (self.evidence.value() != null) self.evidence.deinit() catch {};
        self.tmp.cleanup();
    }
    fn evidencePath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.evidence_path, 0);
    }
    fn manifestPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.manifest_path, 0);
    }
    fn paths(self: *@This()) authored.Paths {
        return .{ .evidence = self.evidencePath(), .manifest = self.manifestPath() };
    }
};

test "authored evidence then manifest share one deadline and final authority" {
    _ = authored.composeUntil;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var semantic = Semantic{};
    var cli = CliAuthority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: authored.AuthoredAttestation = .{};
    try authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result);
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-evidence.json", verifier.names[0]);
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", verifier.names[1]);
    try std.testing.expectEqualSlices(i128, &.{ 90, 70 }, &verifier.budgets);
    try std.testing.expectEqual(@as(usize, 5), deadline.cursor);
    try std.testing.expectEqual(@as(usize, 6), semantic.calls);
    try std.testing.expectEqual(@as(usize, 4), cli.calls);
    _ = try result.revalidate(context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths());
    try std.testing.expectError(error.AuthorityMismatch, result.revalidate(context(), 457, &fixture.evidence, &fixture.manifest, fixture.paths()));
    var foreign_context = context();
    foreign_context.build.run_attempt = 2;
    try std.testing.expectError(error.AuthorityMismatch, result.revalidate(foreign_context, 456, &fixture.evidence, &fixture.manifest, fixture.paths()));
    try result.deinit();
}

test "second child failure and final semantic drift publish no receipt" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var semantic = Semantic{};
    var cli = CliAuthority{};
    var verifier = Verifier{ .fail_at = 2 };
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: authored.AuthoredAttestation = .{};
    try std.testing.expectError(error.AttestationFailed, authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);

    semantic = .{ .fail_at = 6 };
    cli = .{};
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try std.testing.expectError(error.SemanticChanged, authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);
}

test "pathname mutation CLI drift and copied result fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var semantic = Semantic{};
    var cli = CliAuthority{};
    var verifier = Verifier{ .mutate_on_second = fixture.evidencePath() };
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: authored.AuthoredAttestation = .{};
    try std.testing.expectError(error.InvalidOwner, authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", std.mem.asBytes(&result), &result));
    try std.testing.expectError(error.InvalidInput, authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", @constCast(std.mem.asBytes(&fixture.evidence)), &result));
    try std.testing.expectError(error.FileChanged, authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);

    fixture.deinit();
    try fixture.init();
    semantic = .{};
    cli = .{ .fail_at = 2 };
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try std.testing.expectError(error.ExecutableChanged, authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result));

    cli = .{};
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, std.testing.allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try result.deinit();
}

fn allocationCase(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var semantic = Semantic{};
    var cli = CliAuthority{};
    var verifier = AllocatingVerifier{};
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: authored.AuthoredAttestation = .{};
    try authored.composeUntilWith(&semantic, &cli, &verifier, &executor, &deadline, allocator, context(), 456, &fixture.evidence, &fixture.manifest, fixture.paths(), "/opt/trusted/gh", "token", &output, &result);
    try result.deinit();
}

test "all allocation failures unwind observations and publish no copied authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{&fixture});
}

test "manifest semantic snapshot has one production consumer" {
    const manifest_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_manifest.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(manifest_source);
    const authored_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_authored_attestation.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(authored_source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, manifest_source, "pub fn validateAuthoredSnapshot("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, authored_source, "candidate_manifest.validateAuthoredSnapshot("));
}

fn mutate(path: [:0]const u8) !void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const changed = [_]u8{'X'};
    if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.FixtureFailed;
}
