//! Binds the pre-manifest candidate files to Apple product semantics without mounting a real DMG.

const std = @import("std");
const c = std.c;
const context_mod = @import("release_adapter_context");
const draft_mod = @import("release_adapter_github_draft_creation");
const candidate_attestation = @import("release_adapter_candidate_attestation");
const candidate_files = @import("release_adapter_candidate_files");
const apple = @import("release_adapter_apple_product");
const product = @import("release_adapter_candidate_product");

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

const Fixture = struct {
    assets: std.testing.TmpDir,
    work: std.testing.TmpDir,
    files: candidate_files.CandidateFiles = .{},
    attested: candidate_attestation.CandidateAttestation = .{},
    dmg_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    frozen_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *@This()) !void {
        self.* = .{ .assets = std.testing.tmpDir(.{}), .work = std.testing.tmpDir(.{}) };
        try self.assets.dir.writeFile(std.testing.io, .{ .sub_path = dmg_name, .data = "signed dmg bytes" });
        try self.assets.dir.writeFile(std.testing.io, .{ .sub_path = frozen_name, .data = "signed host bytes" });
        _ = try absolute(&self.assets, dmg_name, &self.dmg_path);
        _ = try absolute(&self.assets, frozen_name, &self.frozen_path);
        _ = try absolute(&self.work, "dmg-work", &self.work_path);
        if (c.chmod(self.frozen().ptr, 0o755) != 0) return error.FixtureFailed;
        var draft_value = draft();
        draft_value.owner = &draft_value;
        var authority = AttestationAuthority{};
        var verifier = AttestationVerifier{};
        var executor = AttestationExecutor{};
        var deadline = AttestationDeadline{};
        var output: [8192]u8 = undefined;
        try candidate_attestation.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, context(), self.filePaths(), "/opt/trusted/gh", "token", &output, &self.attested);
        try candidate_files.observe(context(), &draft_value, &self.attested, self.filePaths(), &self.files);
    }
    fn deinit(self: *@This()) void {
        self.files.deinit() catch {};
        self.attested.deinit() catch {};
        self.assets.cleanup();
        self.work.cleanup();
    }
    fn dmg(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.dmg_path, 0);
    }
    fn frozen(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.frozen_path, 0);
    }
    fn dmgWork(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.work_path, 0);
    }
    fn filePaths(self: *@This()) candidate_files.Paths {
        return .{ .dmg = self.dmg(), .frozen_executable = self.frozen() };
    }
    fn paths(self: *@This()) product.Paths {
        return .{ .dmg = self.dmg(), .frozen_executable = self.frozen(), .dmg_work = self.dmgWork() };
    }
};

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

const Deadline = struct {
    values: []const i128 = &.{ 100, 70, 50, 30 },
    cursor: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.TimedOut;
        const value = self.values[self.cursor];
        self.cursor += 1;
        if (value <= 0) return error.TimedOut;
        return value;
    }
};

const Observer = struct {
    calls: usize = 0,
    wrong_executable: bool = false,
    mutate_path: ?[:0]const u8 = null,
    pub fn observeUntil(self: *@This(), allocator: std.mem.Allocator, _: std.Io, paths: product.Paths, expected: product.DmgExpected, version: []const u8, deadline: anytype) !apple.Observed {
        self.calls += 1;
        try std.testing.expectEqualStrings(dmg_name, std.fs.path.basename(paths.dmg));
        try std.testing.expectEqualStrings("1.2.3", version);
        try std.testing.expectEqual(@as(u64, "signed dmg bytes".len), expected.size);
        try std.testing.expectEqualStrings(&digest("signed dmg bytes"), &expected.sha256);
        try std.testing.expectEqual(@as(i128, 50), try deadline.remaining());
        if (self.mutate_path) |path| {
            const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
            if (fd < 0) return error.FixtureFailed;
            defer _ = c.close(fd);
            const byte = [_]u8{'X'};
            if (c.pwrite(fd, &byte, 1, 0) != 1) return error.FixtureFailed;
        }
        var observed: apple.Observed = undefined;
        observed.executable_sha256 = digest(if (self.wrong_executable) "foreign" else "signed host bytes");
        observed.requirement_sha256 = digest("requirement");
        observed.bundle_id = try allocator.dupe(u8, "dev.maru.apphost");
        errdefer allocator.free(observed.bundle_id);
        observed.bundle_short_version = try allocator.dupe(u8, "1.2.3");
        errdefer allocator.free(observed.bundle_short_version);
        observed.bundle_version = try allocator.dupe(u8, "1");
        errdefer allocator.free(observed.bundle_version);
        observed.team_id = try allocator.dupe(u8, "TEAMID1234");
        return observed;
    }
};

test "candidate files publish one Apple product with exact derived inputs" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var deadline = Deadline{};
    var observer = Observer{};
    var result: product.CandidateProduct = .{};
    try product.observeWith(&observer, &deadline, std.testing.allocator, std.testing.io, &fixture.files, fixture.paths(), &result);
    const view = try result.revalidate(&fixture.files, fixture.paths());
    try std.testing.expectEqual(@as(u64, 8123), view.release_id);
    try std.testing.expectEqual(context().build.run_id, view.build.run_id);
    try std.testing.expectEqual(context().build.run_attempt, view.build.run_attempt);
    try std.testing.expectEqualStrings(&digest("signed host bytes"), view.apple.executableSha256());
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try result.deinit(std.testing.allocator);
}

test "deadline and executable mismatch publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var result: product.CandidateProduct = .{};
    var expired = Deadline{ .values = &.{0} };
    var observer = Observer{};
    try std.testing.expectError(error.TimedOut, product.observeWith(&observer, &expired, std.testing.allocator, std.testing.io, &fixture.files, fixture.paths(), &result));
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    var expired_after = Deadline{ .values = &.{ 100, 70, 50, 0 } };
    try std.testing.expectError(error.TimedOut, product.observeWith(&observer, &expired_after, std.testing.allocator, std.testing.io, &fixture.files, fixture.paths(), &result));
    try std.testing.expect(result.value() == null);
    var deadline = Deadline{};
    observer = .{ .wrong_executable = true };
    try std.testing.expectError(error.ProductMismatch, product.observeWith(&observer, &deadline, std.testing.allocator, std.testing.io, &fixture.files, fixture.paths(), &result));
    try std.testing.expect(result.value() == null);
}

test "source mutation and copied owners fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var copied_files = fixture.files;
    var deadline = Deadline{};
    var observer = Observer{};
    var result: product.CandidateProduct = .{};
    try std.testing.expectError(error.InvalidCandidate, product.observeWith(&observer, &deadline, std.testing.allocator, std.testing.io, &copied_files, fixture.paths(), &result));
    deadline = .{};
    observer = .{ .mutate_path = fixture.frozen() };
    try std.testing.expectError(error.CandidateChanged, product.observeWith(&observer, &deadline, std.testing.allocator, std.testing.io, &fixture.files, fixture.paths(), &result));
    try std.testing.expect(result.value() == null);
}

test "allocation failure never publishes a partial product" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}

test "occupied work path is rejected and production surface compiles" {
    std.testing.refAllDecls(product);
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.work.dir.writeFile(std.testing.io, .{ .sub_path = "dmg-work", .data = "occupied" });
    var deadline = Deadline{};
    var observer = Observer{};
    var result: product.CandidateProduct = .{};
    try std.testing.expectError(error.InvalidPath, product.observeWith(&observer, &deadline, std.testing.allocator, std.testing.io, &fixture.files, fixture.paths(), &result));
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var deadline = Deadline{};
    var observer = Observer{};
    var result: product.CandidateProduct = .{};
    product.observeWith(&observer, &deadline, allocator, std.testing.io, &fixture.files, fixture.paths(), &result) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(result.value() == null);
        return error.OutOfMemory;
    };
    try result.deinit(allocator);
}
