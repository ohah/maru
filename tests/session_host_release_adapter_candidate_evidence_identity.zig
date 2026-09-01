//! Candidate evidence identity is derived from owned product/tree authorities, never caller digests.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const draft_mod = @import("release_adapter_github_draft_creation");
const attestation = @import("release_adapter_candidate_attestation");
const candidate_files = @import("release_adapter_candidate_files");
const apple = @import("release_adapter_apple_product");
const candidate_product = @import("release_adapter_candidate_product");
const source_tree = @import("release_adapter_github_source_tree");
const identity = @import("release_adapter_candidate_evidence_identity");

const commit = "0123456789abcdef0123456789abcdef01234567";
const tree_sha = "89abcdef0123456789abcdef0123456789abcdef";
const dmg_name = "Maru-1.2.3-universal.dmg";
const frozen_name = "maru-session-host-1.2.3";

fn context() context_mod.Context {
    return .{ .repository = .{ .id = 55, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = commit, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 7, .run_attempt = 1 }, .protected_tag = true };
}
fn draft() draft_mod.DraftAuthority {
    var value: draft_mod.DraftAuthority = .{ .status = .ready, .id = 8123, .tag_len = "v1.2.3".len };
    @memcpy(value.tag[0..value.tag_len], "v1.2.3");
    @memcpy(&value.source_commit, commit);
    return value;
}
fn digest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}
fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, output: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(output, "{s}/{s}", .{ root[0..len], leaf });
}
const AttestationDeadline = struct {
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.cursor += 1;
        return 1000 - @as(i128, @intCast(self.cursor));
    }
};
const AttestationAuthority = struct {
    pub fn revalidate(_: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {}
};
const AttestationExecutor = struct {};
const AttestationObservation = struct {
    verified: bool = true,
    run_id: u64 = 7,
    run_attempt: u64 = 1,
    subject_name: []const u8,
    subject_sha256: []const u8,
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};
const AttestationVerifier = struct {
    pub fn verifyWith(_: *@This(), _: *AttestationExecutor, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, expected: anytype, _: []u8, _: i128) !AttestationObservation {
        return .{ .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256 };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    work: std.testing.TmpDir,
    attested: attestation.CandidateAttestation = .{},
    files: candidate_files.CandidateFiles = .{},
    product: candidate_product.CandidateProduct = .{},
    source: source_tree.SourceTreeAuthority = .{},
    dmg_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .work = std.testing.tmpDir(.{}) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = "signed dmg bytes" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = frozen_name, .data = "signed host bytes" });
        _ = try absolute(&self.tmp, dmg_name, &self.dmg_path);
        _ = try absolute(&self.tmp, frozen_name, &self.frozen_path);
        _ = try absolute(&self.work, "dmg-work", &self.work_path);
        if (c.chmod(self.frozen().ptr, 0o755) != 0) return error.FixtureFailed;
        var authority = AttestationAuthority{};
        var verifier = AttestationVerifier{};
        var executor = AttestationExecutor{};
        var deadline = AttestationDeadline{};
        var output: [8192]u8 = undefined;
        try attestation.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), self.filePaths(), "/opt/trusted/gh", "token", &output, &self.attested);
        var draft_value = draft();
        draft_value.owner = &draft_value;
        try candidate_files.observe(context(), &draft_value, &self.attested, self.filePaths(), &self.files);
        const files_view = self.files.value().?;
        self.product.release_id = files_view.release_id;
        self.product.tag_len = files_view.tag.len;
        @memcpy(self.product.tag[0..self.product.tag_len], files_view.tag);
        @memcpy(&self.product.source_commit, files_view.source_commit);
        self.product.workflow_ref_len = files_view.build.workflow_ref.len;
        @memcpy(self.product.workflow_ref[0..self.product.workflow_ref_len], files_view.build.workflow_ref);
        self.product.run_id = files_view.build.run_id;
        self.product.run_attempt = files_view.build.run_attempt;
        @memcpy(&self.product.dmg_sha256, &files_view.dmg.sha256);
        @memcpy(&self.product.frozen_sha256, &files_view.frozen.sha256);
        self.product.observed = apple.Observed{
            .executable_sha256 = files_view.frozen.sha256,
            .requirement_sha256 = digest("requirement"),
            .bundle_id = try std.testing.allocator.dupe(u8, "dev.maru.apphost"),
            .bundle_short_version = try std.testing.allocator.dupe(u8, "1.2.3"),
            .bundle_version = try std.testing.allocator.dupe(u8, "1"),
            .team_id = try std.testing.allocator.dupe(u8, "TEAMID1234"),
        };
        self.product.owner = &self.product;
        @memcpy(&self.source.commit, commit);
        @memcpy(&self.source.tree, tree_sha);
        self.source.owner = &self.source;
    }
    fn deinit(self: *@This()) void {
        self.source.deinit() catch {};
        self.product.deinit(std.testing.allocator) catch {};
        self.files.deinit() catch {};
        self.attested.deinit() catch {};
        self.tmp.cleanup();
        self.work.cleanup();
    }
    fn dmg(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.dmg_path, 0);
    }
    fn frozen(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.frozen_path, 0);
    }
    fn filePaths(self: *@This()) candidate_files.Paths {
        return .{ .dmg = self.dmg(), .frozen_executable = self.frozen() };
    }
    fn paths(self: *@This()) candidate_product.Paths {
        return .{ .dmg = self.dmg(), .frozen_executable = self.frozen(), .dmg_work = std.mem.sliceTo(&self.work_path, 0) };
    }
};

test "candidate product and source tree derive one exact evidence common identity" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var uuid = [_]u8{ '0', '1', '8', '9', '0', 'a', 'b', 'c', '-', 'd', 'e', 'f', '0', '-', '4', '1', '2', '3', '-', '8', '5', '6', '7', '-', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f', '0', '1', '2', '3' };
    var result: identity.CandidateEvidenceIdentity = .{};
    try identity.compose(context(), &uuid, &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result);
    uuid[0] = 'f';
    const view = try result.revalidate(context(), &fixture.files, &fixture.product, fixture.paths(), &fixture.source);
    try std.testing.expectEqualStrings("01890abc-def0-4123-8567-89abcdef0123", view.common.test_uuid);
    try std.testing.expectEqual(@as(u64, 8123), view.common.release.id);
    try std.testing.expectEqualStrings(tree_sha, view.common.source.tree);
    try std.testing.expectEqualStrings(&digest("signed dmg bytes"), view.common.candidate.dmg_sha256);
    try std.testing.expectEqualStrings(&digest("requirement"), view.designated_requirement_sha256);
    try result.deinit();
}

test "UUID context source and preowned drift publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var result: identity.CandidateEvidenceIdentity = .{};
    try std.testing.expectError(error.InvalidUuid, identity.compose(context(), "not-a-uuid", &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result));
    var foreign = context();
    foreign.build.run_attempt = 2;
    try std.testing.expectError(error.BindingMismatch, identity.compose(foreign, "01890abc-def0-4123-8567-89abcdef0123", &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result));
    fixture.source.commit[0] = '1';
    try std.testing.expectError(error.BindingMismatch, identity.compose(context(), "01890abc-def0-4123-8567-89abcdef0123", &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result));
    fixture.source.commit[0] = '0';
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, identity.compose(context(), "01890abc-def0-4123-8567-89abcdef0123", &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result));
    result = .{};
    result.tag[0] = 'x';
    try std.testing.expectError(error.InvalidOwner, identity.compose(context(), "01890abc-def0-4123-8567-89abcdef0123", &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result));
}

test "candidate mutation copied owners and revalidation drift fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var result: identity.CandidateEvidenceIdentity = .{};
    try identity.compose(context(), "01890abc-def0-4123-8567-89abcdef0123", &fixture.files, &fixture.product, fixture.paths(), &fixture.source, &result);
    var copied = result;
    try std.testing.expectError(error.InvalidOwner, copied.revalidate(context(), &fixture.files, &fixture.product, fixture.paths(), &fixture.source));
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    const fd = c.open(fixture.dmg().ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const changed = [_]u8{'X'};
    if (c.pwrite(fd, &changed, 1, 0) != 1) return error.FixtureFailed;
    try std.testing.expectError(error.CandidateChanged, result.revalidate(context(), &fixture.files, &fixture.product, fixture.paths(), &fixture.source));
    try result.deinit();
}

test "candidate evidence identity production surface compiles" {
    _ = identity.compose;
}
