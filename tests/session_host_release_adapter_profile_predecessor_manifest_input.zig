//! Pre-publish profile endorsement to authenticated predecessor manifest contract.

const std = @import("std");
const manifest = @import("release_manifest");
const workspace_mod = @import("release_adapter_pre_publish_workspace");
const authenticated_mod = @import("release_adapter_github_manifest_attestation");
const post_publish = @import("release_adapter_github_predecessor_manifest_input");
const composition = @import("release_adapter_profile_predecessor_manifest_input");

const commit = "0123456789abcdef0123456789abcdef01234567";

const Fixture = struct {
    bytes: []u8,
    sha: [64]u8,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const value: manifest.Manifest = .{
            .schema = manifest.schema,
            .role = .a,
            .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" },
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &.{ .{ .role = .universal_dmg, .name = "Maru.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 }, .{ .role = .frozen_product_executable, .name = "maru-macos-app", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 }, .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 } },
            .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
        };
        const bytes = try manifest.writeCanonical(allocator, value);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return .{ .bytes = bytes, .sha = std.fmt.bytesToHex(digest, .lower) };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

const Profile = struct {
    const Axis = enum { release_id, tag, commit, manifest_sha };
    fixture: *Fixture,
    calls: usize = 0,
    baseline: bool = false,
    drift_at: usize = 0,
    drift_axis: Axis = .release_id,
    storage_override: ?[]const u8 = null,

    pub fn predecessor(self: *@This()) !manifest.Predecessor {
        self.calls += 1;
        if (self.baseline) return error.ProfileMismatch;
        const drift = self.drift_at == self.calls;
        return .{
            .release_id = if (drift and self.drift_axis == .release_id) 78 else 77,
            .tag = if (drift and self.drift_axis == .tag) "v1.2.2" else "v1.2.3",
            .commit = if (drift and self.drift_axis == .commit) "ffffffffffffffffffffffffffffffffffffffff" else commit,
            .manifest_sha256 = if (drift and self.drift_axis == .manifest_sha) "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" else &self.fixture.sha,
        };
    }

    pub fn storage(self: *@This()) []const u8 {
        return self.storage_override orelse std.mem.asBytes(self);
    }
};

const Deadline = struct {
    fail: bool = false,
    pub fn remaining(self: *@This()) !i128 {
        if (self.fail) return error.TimedOut;
        return 1;
    }
};

const Downloader = struct {
    fixture: *Fixture,
    calls: usize = 0,
    deadline_address: usize = 0,
    fail: bool = false,
    foreign_capture: bool = false,

    pub fn fetch(self: *@This(), deadline: anytype, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, expected: anytype, output: []u8) !composition.Downloaded {
        self.calls += 1;
        self.deadline_address = @intFromPtr(deadline);
        if (self.fail) return error.ChildFailed;
        try std.testing.expectEqualStrings("v1.2.3", expected.tag);
        try std.testing.expectEqualStrings(&self.fixture.sha, expected.sha256);
        @memcpy(output[0..self.fixture.bytes.len], self.fixture.bytes);
        if (self.foreign_capture)
            return .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = expected.sha256, .bytes = self.fixture.bytes };
        return .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = expected.sha256, .bytes = output[0..self.fixture.bytes.len] };
    }
};

const Authenticator = struct {
    calls: usize = 0,
    deadline_address: usize = 0,
    fail: bool = false,
    break_cleanup: bool = false,

    pub fn authenticate(self: *@This(), deadline: anytype, allocator: std.mem.Allocator, predecessor: manifest.Predecessor, bytes: []const u8, file: anytype, _: [:0]const u8, _: []const u8, _: []u8, result: *authenticated_mod.AuthenticatedManifest) !void {
        self.calls += 1;
        self.deadline_address = @intFromPtr(deadline);
        if (self.fail) return error.AttestationMismatch;
        const observed = try file.revalidate();
        try std.testing.expectEqualStrings(predecessor.manifest_sha256, observed.sha256);
        var parsed = try manifest.parseCanonical(allocator, bytes);
        var transferred = false;
        defer if (!transferred) parsed.deinit();
        const candidate = parsed.value();
        if (candidate.role != .a or candidate.release.id != predecessor.release_id or
            !std.mem.eql(u8, candidate.release.tag, predecessor.tag) or
            !std.mem.eql(u8, candidate.source.commit, predecessor.commit)) return error.InvalidPredecessor;
        result.* = .{ .owner = result, .parsed = parsed };
        transferred = true;
        if (self.break_cleanup) {
            try std.Io.Dir.deleteFileAbsolute(std.testing.io, observed.path);
            return error.AttestationMismatch;
        }
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, output: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(output, "{s}/{s}", .{ root[0..len], leaf });
}

fn run(profile: *Profile, downloader: *Downloader, authenticator: *Authenticator, deadline: *Deadline, workspace: *workspace_mod.Workspace, output: []u8, attestation: []u8, result: *composition.ProfileManifestInput) !void {
    return composition.authenticateUntilWith(downloader, authenticator, deadline, std.testing.allocator, profile, workspace, "/opt/trusted/gh", "token", output, attestation, result);
}

test "upgrade profile authenticates A with one deadline and explicit cleanup" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var profile = Profile{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    try run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result);
    try std.testing.expectEqual(@intFromPtr(&deadline), downloader.deadline_address);
    try std.testing.expectEqual(@intFromPtr(&deadline), authenticator.deadline_address);
    try std.testing.expectEqual(@as(usize, 5), profile.calls);
    @memset(output[0..fixture.bytes.len], 0xaa);
    try std.testing.expectEqual(@as(u64, 77), result.value().?.release.id);
    try result.deinit(std.testing.allocator);
    try workspace.cleanup();
}

test "baseline and every endorsement field drift at every fence never publish" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    var profile = Profile{ .fixture = &fixture, .baseline = true };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    try std.testing.expectError(error.ProfileMismatch, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    try std.testing.expectEqual(@as(usize, 0), downloader.calls);
    inline for (std.meta.tags(Profile.Axis)) |axis| {
        inline for (2..6) |drift_at| {
            profile = .{ .fixture = &fixture, .drift_at = drift_at, .drift_axis = axis };
            try std.testing.expectError(error.AuthorityChanged, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
            try std.testing.expect(result.value() == null);
        }
    }
    try workspace.cleanup();
}

test "download and attestation failure clean owned filesystem state" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var profile = Profile{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture, .fail = true };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    try std.testing.expectError(error.ChildFailed, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    downloader.fail = false;
    authenticator.fail = true;
    profile = .{ .fixture = &fixture };
    try std.testing.expectError(error.AttestationMismatch, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    try std.testing.expect(result.value() == null);
    try workspace.cleanup();
}

test "pre-owned and aliased output fail before callbacks" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var profile = Profile{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var workspace: workspace_mod.Workspace = .{};
    var output: [64]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    result = .{};
    profile.storage_override = std.mem.asBytes(&result);
    try std.testing.expectError(error.InvalidOwner, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    try std.testing.expectEqual(@as(usize, 0), downloader.calls);
}

test "final deadline expiry cleans authenticated output before publication" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var profile = Profile{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{ .fail = true };
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    try std.testing.expectError(error.TimedOut, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    try std.testing.expect(result.value() == null);
    try workspace.cleanup();
}

test "foreign downloader capture is rejected before filesystem mutation" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var profile = Profile{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture, .foreign_capture = true };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    try std.testing.expectError(error.InvalidDownload, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    try std.testing.expectEqual(@as(usize, 0), authenticator.calls);
    try std.testing.expect(result.value() == null);
    try workspace.cleanup();
}

test "uncertain cleanup preserves the top-level retry owner" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var profile = Profile{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{ .break_cleanup = true };
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [64]u8 = undefined;
    var result: composition.ProfileManifestInput = .{};
    try std.testing.expectError(error.CleanupFailed, run(&profile, &downloader, &authenticator, &deadline, &workspace, &output, &attestation, &result));
    try std.testing.expectEqual(&result, result.owner.?);
    try std.testing.expectError(error.CleanupFailed, result.deinit(std.testing.allocator));
}

test "production entrypoint remains concrete" {
    _ = composition.authenticateUntil;
    comptime {
        if (composition.ProfileManifestInput == post_publish.PredecessorManifestInput)
            @compileError("pre-publish profile provenance must be a nominal capability");
    }
}
