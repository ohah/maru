//! Current role-B manifest, release authority, file identity and attestation publish together.
const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const current_mod = @import("release_adapter_github_current_release_authority");
const attestation = @import("release_adapter_github_attestation");
const file_mod = @import("release_adapter_github_manifest_file");
const composition = @import("release_adapter_github_current_manifest_attestation");

const commit = "0123456789abcdef0123456789abcdef01234567";
const context: context_mod.Context = .{ .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = commit, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };

fn candidate() manifest.Manifest {
    return .{ .schema = manifest.schema, .role = .b, .repository = context.repository, .release = .{ .id = 77, .tag = context.tag, .version = "1.2.3" }, .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" }, .build = context.build, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &.{ .{ .role = .universal_dmg, .name = "Maru.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 }, .{ .role = .frozen_product_executable, .name = "maru-macos-app", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 }, .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 } }, .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" }, .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "2222222222222222222222222222222222222222", .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" } };
}

fn currentAuthority() current_mod.CurrentReleaseAuthority {
    var out: current_mod.CurrentReleaseAuthority = .{ .repository_id = 12345, .run_id = 333, .run_attempt = 2, .release_id = 77, .tag_len = context.tag.len, .protected_environment = true };
    @memcpy(&out.source_commit, commit);
    @memcpy(out.tag[0..out.tag_len], context.tag);
    return out;
}
fn absolute(tmp: *std.testing.TmpDir, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/work", .{root[0..len]});
}

const Authority = struct {
    calls: usize = 0,
    fail: bool = false,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.fail) return error.ExecutableChanged;
    }
};
const SharedDeadline = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.TimedOut;
        return 1_000 - @as(i128, @intCast(self.calls * 100));
    }
};
const Executor = struct {};
const Attestor = struct {
    calls: usize = 0,
    fail: bool = false,
    mutate: bool = false,
    sha: []const u8,
    last_budget: i128 = 0,
    pub fn verify(self: *@This(), _: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, path: []const u8, expected: attestation.Expected, _: []u8, budget: i128) !attestation.Observed {
        self.calls += 1;
        self.last_budget = budget;
        if (self.fail) return error.ChildFailed;
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("token", token);
        try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", expected.subject_name);
        try std.testing.expectEqualStrings(self.sha, expected.subject_sha256);
        try std.testing.expect(budget > 0);
        if (self.mutate) {
            var storage: [std.fs.max_path_bytes:0]u8 = undefined;
            const z = try std.fmt.bufPrintZ(&storage, "{s}", .{path});
            if (c.chmod(z.ptr, 0o600) != 0) return error.MutationFailed;
        }
        return .{ .parsed = try std.json.parseFromSlice(std.json.Value, allocator, "null", .{}), .verified = true, .run_id = 333, .run_attempt = 2, .subject_name = "manifest", .subject_sha256 = self.sha };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    bytes: []u8,
    sha: [64]u8,
    file: file_mod.ManifestFile,
    fn init(self: *Fixture) !void {
        return self.initWith(candidate(), "Maru-1.2.3-session-host-release.json");
    }
    fn initWith(self: *Fixture, value: manifest.Manifest, name: []const u8) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .bytes = undefined, .sha = undefined, .file = .{} };
        self.bytes = try manifest.writeCanonical(std.testing.allocator, value);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.bytes, &digest, .{});
        self.sha = std.fmt.bytesToHex(digest, .lower);
        var path: [std.fs.max_path_bytes:0]u8 = undefined;
        try file_mod.materialize(&self.file, try absolute(&self.tmp, &path), .{ .name = name, .sha256 = &self.sha, .bytes = self.bytes });
    }
    fn deinit(self: *Fixture) void {
        self.file.cleanup() catch {};
        std.testing.allocator.free(self.bytes);
        self.tmp.cleanup();
    }
};

fn runWith(allocator: std.mem.Allocator, expected_context: context_mod.Context, fixture: *Fixture, current: *const current_mod.CurrentReleaseAuthority, attestor: *Attestor, authority: *Authority, result: *composition.AuthenticatedCurrentManifest) !void {
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    try composition.authenticateWith(attestor, authority, &executor, allocator, expected_context, current, fixture.bytes, &fixture.file, "/opt/trusted/gh", "token", &output, std.time.ns_per_s, result);
}

fn run(allocator: std.mem.Allocator, fixture: *Fixture, current: *const current_mod.CurrentReleaseAuthority, attestor: *Attestor, result: *composition.AuthenticatedCurrentManifest) !void {
    var authority = Authority{};
    try runWith(allocator, context, fixture, current, attestor, &authority, result);
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
}

test "exact role-B manifest current authority file and attestation publish together" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{ .sha = &fixture.sha };
    var result: composition.AuthenticatedCurrentManifest = .{};
    try run(std.testing.allocator, &fixture, &current, &attestor, &result);
    defer result.deinit(std.testing.allocator) catch {};
    const value = result.value().?;
    try std.testing.expectEqual(@as(u64, 77), value.manifest.release.id);
    try std.testing.expectEqual(@as(u64, 77), value.authority.release_id);
    try std.testing.expectEqualStrings(commit, value.authority.source_commit);
    var copied = result;
    try std.testing.expect(copied.value() == null);
}

test "current identity and protection mismatch publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attestor = Attestor{ .sha = &fixture.sha };
    inline for (.{ "repository_id", "run_id", "run_attempt", "release_id" }) |field| {
        var current = currentAuthority();
        current.owner = &current;
        @field(current, field) += 1;
        var result: composition.AuthenticatedCurrentManifest = .{};
        try std.testing.expectError(error.InvalidCurrent, run(std.testing.allocator, &fixture, &current, &attestor, &result));
        try std.testing.expect(result.value() == null);
    }
    var current = currentAuthority();
    current.owner = &current;
    current.protected_environment = false;
    var result: composition.AuthenticatedCurrentManifest = .{};
    try std.testing.expectError(error.InvalidCurrent, run(std.testing.allocator, &fixture, &current, &attestor, &result));
}

test "current source commit and tag mismatch publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var attestor = Attestor{ .sha = &fixture.sha };
    var current = currentAuthority();
    current.owner = &current;
    current.source_commit[0] = 'f';
    var result: composition.AuthenticatedCurrentManifest = .{};
    try std.testing.expectError(error.InvalidCurrent, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    current = currentAuthority();
    current.owner = &current;
    current.tag[1] = '9';
    try std.testing.expectError(error.InvalidCurrent, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try std.testing.expect(result.value() == null);
}

test "role predecessor context and canonical filename mismatch publish nothing" {
    var current = currentAuthority();
    current.owner = &current;
    var result: composition.AuthenticatedCurrentManifest = .{};

    var role_a = candidate();
    role_a.role = .a;
    role_a.predecessor = null;
    var role_fixture: Fixture = undefined;
    try role_fixture.initWith(role_a, "Maru-1.2.3-session-host-release.json");
    defer role_fixture.deinit();
    var role_attestor = Attestor{ .sha = &role_fixture.sha };
    try std.testing.expectError(error.InvalidCurrent, run(std.testing.allocator, &role_fixture, &current, &role_attestor, &result));

    var context_fixture: Fixture = undefined;
    try context_fixture.init();
    defer context_fixture.deinit();
    var context_attestor = Attestor{ .sha = &context_fixture.sha };
    var wrong_context = context;
    wrong_context.repository.id += 1;
    var authority = Authority{};
    try std.testing.expectError(error.InvalidManifest, runWith(std.testing.allocator, wrong_context, &context_fixture, &current, &context_attestor, &authority, &result));

    var name_fixture: Fixture = undefined;
    try name_fixture.initWith(candidate(), "Maru-9.9.9-session-host-release.json");
    defer name_fixture.deinit();
    var name_attestor = Attestor{ .sha = &name_fixture.sha };
    try std.testing.expectError(error.InvalidManifest, run(std.testing.allocator, &name_fixture, &current, &name_attestor, &result));
    try std.testing.expect(result.value() == null);
}

test "pre-owned child and post-attestation file drift publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var result: composition.AuthenticatedCurrentManifest = .{};
    result.owner = &result;
    var attestor = Attestor{ .sha = &fixture.sha };
    try std.testing.expectError(error.InvalidOwner, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    result = .{};
    attestor.fail = true;
    try std.testing.expectError(error.ChildFailed, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    attestor = .{ .sha = &fixture.sha, .mutate = true };
    try std.testing.expectError(error.FileChanged, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try std.testing.expect(result.value() == null);
}

test "pre-attestation file and CLI authority drift publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{ .sha = &fixture.sha };
    var result: composition.AuthenticatedCurrentManifest = .{};
    var authority = Authority{ .fail = true };
    try std.testing.expectError(error.ExecutableChanged, runWith(std.testing.allocator, context, &fixture, &current, &attestor, &authority, &result));
    try std.testing.expectEqual(@as(usize, 0), attestor.calls);

    const observed = fixture.file.observation().?;
    var storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&storage, "{s}", .{observed.path});
    if (c.chmod(path.ptr, 0o600) != 0) return error.MutationFailed;
    authority = .{};
    try std.testing.expectError(error.FileChanged, runWith(std.testing.allocator, context, &fixture, &current, &attestor, &authority, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expect(result.value() == null);
}

fn allocationHarness(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{ .sha = &fixture.sha };
    var result: composition.AuthenticatedCurrentManifest = .{};
    try run(allocator, fixture, &current, &attestor, &result);
    try result.deinit(allocator);
}
test "every successful allocation failure unwinds" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{&fixture});
}
test "product wrapper is compiled" {
    _ = composition.authenticate;
    _ = composition.authenticateUntil;
}

test "shared deadline brackets CLI revalidation child budget and final publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{ .sha = &fixture.sha };
    var authority = Authority{};
    var executor = Executor{};
    var deadline = SharedDeadline{};
    var output: [8192]u8 = undefined;
    var result: composition.AuthenticatedCurrentManifest = .{};
    try composition.authenticateUntilWith(&attestor, &authority, &executor, &deadline, std.testing.allocator, context, &current, fixture.bytes, &fixture.file, "/opt/trusted/gh", "token", &output, &result);
    try std.testing.expectEqual(@as(usize, 3), deadline.calls);
    try std.testing.expectEqual(@as(i128, 800), attestor.last_budget);
    try result.deinit(std.testing.allocator);

    attestor = .{ .sha = &fixture.sha };
    authority = .{};
    deadline = .{ .fail_at = 3 };
    result = .{};
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&attestor, &authority, &executor, &deadline, std.testing.allocator, context, &current, fixture.bytes, &fixture.file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), attestor.calls);
    try std.testing.expect(result.value() == null);

    attestor = .{ .sha = &fixture.sha };
    authority = .{};
    deadline = .{ .fail_at = 2 };
    result = .{};
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&attestor, &authority, &executor, &deadline, std.testing.allocator, context, &current, fixture.bytes, &fixture.file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), attestor.calls);
    try std.testing.expect(result.value() == null);

    attestor = .{ .sha = &fixture.sha };
    authority = .{};
    deadline = .{ .fail_at = 1 };
    try std.testing.expectError(error.TimedOut, composition.authenticateUntilWith(&attestor, &authority, &executor, &deadline, std.testing.allocator, context, &current, fixture.bytes, &fixture.file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), attestor.calls);
    try std.testing.expect(result.value() == null);

    current.owner = null;
    deadline = .{};
    try std.testing.expectError(error.InvalidCurrent, composition.authenticateUntilWith(&attestor, &authority, &executor, &deadline, std.testing.allocator, context, &current, fixture.bytes, &fixture.file, "/opt/trusted/gh", "token", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), deadline.calls);
}
