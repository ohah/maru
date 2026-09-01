//! Pre-draft candidate provenance uses only temporary files and injected GitHub observations.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const candidate = @import("release_adapter_candidate_attestation");

const dmg_name = "Maru-1.2.3-universal.dmg";
const frozen_name = "maru-session-host-1.2.3";

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

const Authority = struct {
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
    budgets: [2]i128 = @splat(0),
    names: [2][]const u8 = @splat(""),
    mutate_on_second: ?[:0]const u8 = null,
    foreign_subject: bool = false,
    pub fn verifyWith(self: *@This(), _: *Executor, _: std.mem.Allocator, _: []const u8, _: []const u8, path: []const u8, expected: anytype, _: []u8, budget: i128) !Observation {
        const index = self.calls;
        if (index >= 2 or !std.mem.eql(u8, std.fs.path.basename(path), expected.subject_name) or !std.mem.eql(u8, expected.context.tag, "v1.2.3")) return error.BadCall;
        self.calls += 1;
        self.budgets[index] = budget;
        self.names[index] = expected.subject_name;
        if (index == 1) if (self.mutate_on_second) |target| {
            const fd = c.open(target.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
            if (fd < 0) return error.FixtureFailed;
            defer _ = c.close(fd);
            const changed = [_]u8{'X'};
            if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.FixtureFailed;
        };
        return .{ .subject_name = if (self.foreign_subject) "foreign" else expected.subject_name, .subject_sha256 = expected.subject_sha256 };
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
};

test "pre-draft authority attests DMG then frozen with one deadline" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority = Authority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: candidate.CandidateAttestation = .{};
    try candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", &output, &result);
    const view = result.value().?;
    try std.testing.expectEqualStrings(dmg_name, verifier.names[0]);
    try std.testing.expectEqualStrings(frozen_name, verifier.names[1]);
    try std.testing.expectEqual(@as(usize, 4), authority.calls);
    try std.testing.expectEqual(@as(i128, 90), verifier.budgets[0]);
    try std.testing.expectEqual(@as(i128, 70), verifier.budgets[1]);
    try std.testing.expectEqual(@as(usize, 5), deadline.cursor);
    try std.testing.expect(view.dmg_attested and view.frozen_attested);
    _ = try result.revalidate(fixture.paths());
    try result.deinit();
}

test "final expiry and file mutation publish no candidate authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority = Authority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 0 } };
    var output: [8192]u8 = undefined;
    var result: candidate.CandidateAttestation = .{};
    try std.testing.expectError(error.TimedOut, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);

    authority = .{};
    verifier = .{ .mutate_on_second = fixture.dmg() };
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try std.testing.expectError(error.FileChanged, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);
}

test "invalid context basename and copied owner fail closed" {
    _ = candidate.composeUntil;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority = Authority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: candidate.CandidateAttestation = .{};
    var foreign = context();
    foreign.protected_tag = false;
    try std.testing.expectError(error.AuthorityMismatch, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, foreign, fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectError(error.InvalidInput, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", std.mem.asBytes(&result), &result));
    var aliased: [64]u8 = @splat('x');
    try std.testing.expectError(error.InvalidInput, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", aliased[0..8], &aliased, &result));

    authority = .{};
    verifier = .{ .foreign_subject = true };
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try std.testing.expectError(error.AttestationMismatch, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);

    authority = .{ .fail_at = 2 };
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try std.testing.expectError(error.ExecutableChanged, candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expect(result.value() == null);

    authority = .{};
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60 } };
    try candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), fixture.paths(), "/opt/trusted/gh", "token", &output, &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    const fd = c.open(fixture.dmg().ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const changed = [_]u8{'X'};
    if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.FixtureFailed;
    try std.testing.expectError(error.FileChanged, result.revalidate(fixture.paths()));
    try result.deinit();
}

fn allocationCase(allocator: std.mem.Allocator, paths: candidate.Paths) !void {
    var authority = Authority{};
    var verifier = AllocatingVerifier{};
    var executor = Executor{};
    var deadline = Deadline{ .values = &.{ 100, 90, 80, 70, 60 } };
    var output: [8192]u8 = undefined;
    var result: candidate.CandidateAttestation = .{};
    try candidate.composeUntilWith(&authority, &verifier, &executor, &deadline, allocator, context(), paths, "/opt/trusted/gh", "token", &output, &result);
    try result.deinit();
}

test "every successful allocation failure unwinds pinned files and observations" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{fixture.paths()});
}
