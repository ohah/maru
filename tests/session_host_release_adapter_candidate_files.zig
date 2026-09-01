//! Binds a created draft to the already-attested candidate owner without reopening raw authority.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const draft_mod = @import("release_adapter_github_draft_creation");
const attestation = @import("release_adapter_candidate_attestation");
const candidate = @import("release_adapter_candidate_files");

const dmg_name = "Maru-1.2.3-universal.dmg";
const frozen_name = "maru-session-host-1.2.3";
fn context() context_mod.Context {
    return .{ .repository = .{ .id = 55, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = "0123456789abcdef0123456789abcdef01234567", .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 7, .run_attempt = 1 }, .protected_tag = true };
}
fn draft() draft_mod.DraftAuthority {
    var value: draft_mod.DraftAuthority = .{ .status = .ready, .id = 8123, .tag_len = "v1.2.3".len };
    @memcpy(value.tag[0..value.tag_len], "v1.2.3");
    @memcpy(&value.source_commit, context().source_commit);
    return value;
}
const Deadline = struct {
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.cursor += 1;
        return 100 - @as(i128, @intCast(self.cursor));
    }
};
const Authority = struct {
    pub fn revalidate(_: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {}
};
const Executor = struct {};
const Observation = struct {
    verified: bool = true,
    run_id: u64 = 7,
    run_attempt: u64 = 1,
    subject_name: []const u8,
    subject_sha256: []const u8,
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};
const Verifier = struct {
    pub fn verifyWith(_: *@This(), _: *Executor, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, expected: anytype, _: []u8, _: i128) !Observation {
        return .{ .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256 };
    }
};
fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, output: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(output, "{s}/{s}", .{ root[0..len], leaf });
}
const Fixture = struct {
    tmp: std.testing.TmpDir,
    dmg_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = "signed dmg bytes" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = frozen_name, .data = "signed host bytes" });
        _ = try absolute(&self.tmp, dmg_name, &self.dmg_path);
        _ = try absolute(&self.tmp, frozen_name, &self.frozen_path);
        if (c.chmod(self.frozen().ptr, 0o755) != 0) return error.FixtureFailed;
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn dmg(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.dmg_path, 0);
    }
    fn frozen(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.frozen_path, 0);
    }
    fn paths(self: *@This()) candidate.Paths {
        return .{ .dmg = self.dmg(), .frozen_executable = self.frozen() };
    }
    fn attest(self: *@This(), result: *attestation.CandidateAttestation) !void {
        var authority = Authority{};
        var verifier = Verifier{};
        var executor = Executor{};
        var deadline = Deadline{};
        var output: [8192]u8 = undefined;
        try attestation.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), self.paths(), "/opt/trusted/gh", "token", &output, result);
    }
};

test "draft binds exact pre-draft attestation without owning its files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attested: attestation.CandidateAttestation = .{};
    try fixture.attest(&attested);
    defer attested.deinit() catch {};
    var draft_value = draft();
    draft_value.owner = &draft_value;
    var result: candidate.CandidateFiles = .{};
    try candidate.observe(context(), &draft_value, &attested, fixture.paths(), &result);
    const view = result.value().?;
    try std.testing.expectEqual(@as(u64, 8123), view.release_id);
    try std.testing.expectEqualStrings("v1.2.3", view.tag);
    try std.testing.expectEqualStrings(context().build.workflow_ref, view.build.workflow_ref);
    try std.testing.expectEqual(context().build.run_id, view.build.run_id);
    try std.testing.expectEqual(context().build.run_attempt, view.build.run_attempt);
    _ = try result.revalidate(fixture.paths());
    try result.deinit();
    try std.testing.expect(attested.value() != null);
}

test "context draft and stale attestation publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attested: attestation.CandidateAttestation = .{};
    try fixture.attest(&attested);
    defer attested.deinit() catch {};
    var draft_value = draft();
    draft_value.owner = &draft_value;
    var result: candidate.CandidateFiles = .{};
    var foreign = context();
    foreign.source_commit = "1123456789abcdef0123456789abcdef01234567";
    try std.testing.expectError(error.AuthorityMismatch, candidate.observe(foreign, &draft_value, &attested, fixture.paths(), &result));
    var copied = attested;
    try std.testing.expectError(error.InvalidAttestation, candidate.observe(context(), &draft_value, &copied, fixture.paths(), &result));
    draft_value.id = 0;
    try std.testing.expectError(error.AuthorityMismatch, candidate.observe(context(), &draft_value, &attested, fixture.paths(), &result));
}

test "pathname mutation invalidates the draft-bound view" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attested: attestation.CandidateAttestation = .{};
    try fixture.attest(&attested);
    defer attested.deinit() catch {};
    var draft_value = draft();
    draft_value.owner = &draft_value;
    var result: candidate.CandidateFiles = .{};
    try candidate.observe(context(), &draft_value, &attested, fixture.paths(), &result);
    defer result.deinit() catch {};
    const fd = c.open(fixture.dmg().ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const changed = [_]u8{'X'};
    if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.FixtureFailed;
    try std.testing.expectError(error.FileChanged, result.revalidate(fixture.paths()));
}

test "copied and pre-owned candidate owners fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attested: attestation.CandidateAttestation = .{};
    try fixture.attest(&attested);
    defer attested.deinit() catch {};
    var draft_value = draft();
    draft_value.owner = &draft_value;
    var result: candidate.CandidateFiles = .{};
    try candidate.observe(context(), &draft_value, &attested, fixture.paths(), &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try std.testing.expectError(error.InvalidOwner, candidate.observe(context(), &draft_value, &attested, fixture.paths(), &result));
    try result.deinit();
}

test "borrowed attestation lifetime and overlapping result fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attested: attestation.CandidateAttestation = .{};
    try fixture.attest(&attested);
    var draft_value = draft();
    draft_value.owner = &draft_value;
    const overlapping: *candidate.CandidateFiles = @ptrCast(&attested);
    try std.testing.expectError(error.InvalidOwner, candidate.observe(context(), &draft_value, &attested, fixture.paths(), overlapping));

    var result: candidate.CandidateFiles = .{};
    try candidate.observe(context(), &draft_value, &attested, fixture.paths(), &result);
    try attested.deinit();
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.InvalidOwner, result.revalidate(fixture.paths()));
    try result.deinit();
}
