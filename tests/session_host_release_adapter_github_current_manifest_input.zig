//! Current manifest pathname이 한 번만 읽힌 owned bytes와 private attestation leaf로 수렴하는지 검증한다.
//!
//! 원본 pathname을 다시 열면 release job의 같은 UID process가 검증 대상을 바꿀 수 있으므로, 실제 filesystem에서
//! symlink·basename·크기·destination·cleanup과 read 뒤 원본 mutation 격리를 함께 고정한다.

const std = @import("std");
const c = std.c;
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const current_mod = @import("release_adapter_github_current_release_authority");
const attestation = @import("release_adapter_github_attestation");
const candidate_mod = @import("release_adapter_github_current_manifest_candidate");
const composition = @import("release_adapter_github_current_manifest_input");

const file_name = "Maru-1.2.3-session-host-release.json";
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

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

const Authority = struct {
    calls: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
    }
};
const Executor = struct {};
const Attestor = struct {
    calls: usize = 0,
    fail: bool = false,
    block_cleanup: bool = false,
    original: ?[:0]const u8 = null,
    seen_private: bool = false,
    pub fn verify(self: *@This(), _: anytype, allocator: std.mem.Allocator, _: []const u8, _: []const u8, path: []const u8, expected: attestation.Expected, _: []u8, _: i128) !attestation.Observed {
        self.calls += 1;
        if (self.block_cleanup) {
            const parent = std.fs.path.dirname(path) orelse return error.MutationFailed;
            var parent_storage: [std.fs.max_path_bytes:0]u8 = undefined;
            const parent_z = try std.fmt.bufPrintZ(&parent_storage, "{s}", .{parent});
            if (c.chmod(parent_z.ptr, 0o500) != 0) return error.MutationFailed;
        }
        if (self.fail) return error.ChildFailed;
        try std.testing.expectEqualStrings(file_name, expected.subject_name);
        if (self.original) |original| {
            try std.testing.expect(!std.mem.eql(u8, path, original));
            self.seen_private = true;
            const fd = c.open(original.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(c.mode_t, 0));
            if (fd < 0) return error.MutationFailed;
            defer _ = c.close(fd);
            _ = c.write(fd, "changed".ptr, "changed".len);
        }
        return .{ .parsed = try std.json.parseFromSlice(std.json.Value, allocator, "null", .{}), .verified = true, .run_id = 333, .run_attempt = 2, .subject_name = "manifest", .subject_sha256 = expected.subject_sha256 };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    bytes: []u8,
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    work_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *Fixture) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .bytes = try manifest.writeCanonical(std.testing.allocator, candidate()) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = self.bytes });
        _ = try absolute(&self.tmp, file_name, &self.manifest_path);
        _ = try absolute(&self.tmp, "private", &self.work_path);
    }
    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.bytes);
        self.tmp.cleanup();
    }
};

fn run(allocator: std.mem.Allocator, fixture: *Fixture, current: *const current_mod.CurrentReleaseAuthority, attestor: *Attestor, result: *composition.CurrentManifestInput) !void {
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    try composition.authenticatePathWith(attestor, &authority, &executor, allocator, context, current, std.mem.sliceTo(&fixture.manifest_path, 0), std.mem.sliceTo(&fixture.work_path, 0), "/opt/trusted/gh", "token", &output, std.time.ns_per_s, result);
}

test "canonical pathname publishes owned bytes private file and attestation despite original mutation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{ .original = std.mem.sliceTo(&fixture.manifest_path, 0) };
    var result: composition.CurrentManifestInput = .{};
    try run(std.testing.allocator, &fixture, &current, &attestor, &result);
    defer result.deinit(std.testing.allocator) catch {};
    try std.testing.expect(attestor.seen_private);
    try std.testing.expectEqualStrings("1.2.3", result.value().?.manifest.release.version);
    try std.testing.expectEqualStrings(fixture.bytes, result.bytes().?);
    var copied = result;
    try std.testing.expect(copied.value() == null);
}

test "authenticated candidate transfers the exact single-read input without reopening pathname" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var candidate_owner: candidate_mod.CurrentManifestCandidate = .{};
    try candidate_mod.read(std.testing.allocator, context, std.mem.sliceTo(&fixture.manifest_path, 0), &candidate_owner);
    const original_pointer = candidate_owner.bytes().?.ptr;
    var attestor = Attestor{ .original = std.mem.sliceTo(&fixture.manifest_path, 0) };
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.CurrentManifestInput = .{};
    try composition.authenticateCandidateWith(&attestor, &authority, &executor, std.testing.allocator, context, &current, &candidate_owner, std.mem.sliceTo(&fixture.work_path, 0), "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result);
    defer result.deinit(std.testing.allocator) catch {};
    try std.testing.expect(attestor.seen_private);
    try std.testing.expectEqual(original_pointer, result.bytes().?.ptr);
    try std.testing.expect(candidate_owner.value() == null);
    try std.testing.expectError(error.InvalidOwner, candidate_owner.takeInput());
}

test "candidate is preserved before consume and cleanup owns failures after consume" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    var candidate_owner: candidate_mod.CurrentManifestCandidate = .{};
    try candidate_mod.read(std.testing.allocator, context, std.mem.sliceTo(&fixture.manifest_path, 0), &candidate_owner);
    var attestor = Attestor{ .fail = true };
    var authority = Authority{};
    var executor = Executor{};
    var output: [8192]u8 = undefined;
    var result: composition.CurrentManifestInput = .{};
    try std.testing.expectError(error.InvalidCurrent, composition.authenticateCandidateWith(&attestor, &authority, &executor, std.testing.allocator, context, &current, &candidate_owner, std.mem.sliceTo(&fixture.work_path, 0), "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expect(candidate_owner.value() != null);
    current.owner = &current;
    current.release_id = 999;
    try std.testing.expectError(error.InvalidCurrent, composition.authenticateCandidateWith(&attestor, &authority, &executor, std.testing.allocator, context, &current, &candidate_owner, std.mem.sliceTo(&fixture.work_path, 0), "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expect(candidate_owner.value() != null);
    current.release_id = candidate().release.id;
    try std.testing.expectError(error.ChildFailed, composition.authenticateCandidateWith(&attestor, &authority, &executor, std.testing.allocator, context, &current, &candidate_owner, std.mem.sliceTo(&fixture.work_path, 0), "/opt/trusted/gh", "token", &output, std.time.ns_per_s, &result));
    try std.testing.expect(candidate_owner.value() == null);
    try std.testing.expect(result.value() == null);
    try std.testing.expect(result.bytes() == null);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "private", .{}));
}

test "noncanonical relative empty symlink directory and oversized inputs publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{};
    var result: composition.CurrentManifestInput = .{};
    var wrong: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var executor = Executor{};
    var output: [1]u8 = undefined;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wrong.json", .data = fixture.bytes });
    try std.testing.expectError(error.InvalidManifestPath, composition.authenticatePathWith(&attestor, &authority, &executor, std.testing.allocator, context, &current, try absolute(&fixture.tmp, "wrong.json", &wrong), std.mem.sliceTo(&fixture.work_path, 0), "/gh", "t", &output, 1, &result));
    try std.testing.expectError(error.InvalidManifestPath, composition.authenticatePathWith(&attestor, &authority, &executor, std.testing.allocator, context, &current, file_name, std.mem.sliceTo(&fixture.work_path, 0), "/gh", "t", &output, 1, &result));

    try fixture.tmp.dir.deleteFile(std.testing.io, file_name);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "" });
    try std.testing.expectError(error.InvalidManifestInput, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try fixture.tmp.dir.deleteFile(std.testing.io, file_name);
    try fixture.tmp.dir.symLink(std.testing.io, "wrong.json", file_name, .{});
    try std.testing.expectError(error.UnsafePath, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try fixture.tmp.dir.deleteFile(std.testing.io, file_name);
    try fixture.tmp.dir.createDir(std.testing.io, file_name, .default_dir);
    try std.testing.expectError(error.NotRegular, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try fixture.tmp.dir.deleteDir(std.testing.io, file_name);
    const too_large = try std.testing.allocator.alloc(u8, manifest.max_manifest_bytes + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'x');
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = too_large });
    try std.testing.expectError(error.TooLarge, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try std.testing.expectEqual(@as(usize, 0), attestor.calls);
}

test "occupied private destination fails before attestation and preserves it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(std.testing.io, "private", .default_dir);
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{};
    var result: composition.CurrentManifestInput = .{};
    try std.testing.expectError(error.DestinationExists, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try std.testing.expectEqual(@as(usize, 0), attestor.calls);
    _ = try fixture.tmp.dir.statFile(std.testing.io, "private", .{});
}

test "attestation failure removes private residue and publishes nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{ .fail = true };
    var result: composition.CurrentManifestInput = .{};
    try std.testing.expectError(error.ChildFailed, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try std.testing.expect(result.value() == null);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "private", .{}));

    var blocked: Fixture = undefined;
    try blocked.init();
    defer blocked.deinit();
    var blocked_attestor = Attestor{ .fail = true, .block_cleanup = true };
    var cleanup_result: composition.CurrentManifestInput = .{};
    try std.testing.expectError(error.CleanupFailed, run(std.testing.allocator, &blocked, &current, &blocked_attestor, &cleanup_result));
    try std.testing.expect(cleanup_result.value() == null);
    try std.testing.expect(cleanup_result.bytes() != null);
    const work = std.mem.sliceTo(&blocked.work_path, 0);
    if (c.chmod(work.ptr, 0o700) != 0) return error.MutationFailed;
    try cleanup_result.deinit(std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, blocked.tmp.dir.statFile(std.testing.io, "private", .{}));
}

test "preowned result and invalid current authority publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{};
    var result: composition.CurrentManifestInput = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    result = .{};
    current.owner = null;
    try std.testing.expectError(error.InvalidCurrent, run(std.testing.allocator, &fixture, &current, &attestor, &result));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "private", .{}));
}

test "cleanup failure preserves retry authority without an authenticated value" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{};
    var result: composition.CurrentManifestInput = .{};
    try run(std.testing.allocator, &fixture, &current, &attestor, &result);
    const work = std.mem.sliceTo(&fixture.work_path, 0);
    if (c.chmod(work.ptr, 0o500) != 0) return error.MutationFailed;
    try std.testing.expectError(error.CleanupFailed, result.deinit(std.testing.allocator));
    try std.testing.expect(result.value() == null);
    try std.testing.expect(result.bytes() != null);
    if (c.chmod(work.ptr, 0o700) != 0) return error.MutationFailed;
    try result.deinit(std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "private", .{}));
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var current = currentAuthority();
    current.owner = &current;
    var attestor = Attestor{};
    var result: composition.CurrentManifestInput = .{};
    try run(allocator, &fixture, &current, &attestor, &result);
    try result.deinit(allocator);
}
test "every successful allocation failure unwinds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}
test "product wrapper is compiled" {
    _ = composition.authenticatePath;
}
