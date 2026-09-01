//! One-owner predecessor manifest input composition and cleanup contract.

const std = @import("std");
const manifest = @import("release_manifest");
const workspace_mod = @import("release_adapter_pre_publish_workspace");
const authenticated_mod = @import("release_adapter_github_manifest_attestation");
const composition = @import("release_adapter_github_predecessor_manifest_input");

const commit = "0123456789abcdef0123456789abcdef01234567";

const Fixture = struct {
    a_bytes: []u8,
    a_sha: [64]u8,
    current_manifest: manifest.Manifest,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const a: manifest.Manifest = .{
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
        const bytes = try manifest.writeCanonical(allocator, a);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const sha = std.fmt.bytesToHex(digest, .lower);
        return .{ .a_bytes = bytes, .a_sha = sha, .current_manifest = .{
            .schema = manifest.schema,
            .role = .b,
            .repository = a.repository,
            .release = .{ .id = 78, .tag = "v1.2.4", .version = "1.2.4" },
            .source = .{ .commit = "2222222222222222222222222222222222222222", .tree = "3333333333333333333333333333333333333333" },
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.4", .run_id = 444, .run_attempt = 1 },
            .compatibility = a.compatibility,
            .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.4", .bundle_version = "124", .team_id = a.signing.team_id, .designated_requirement_sha256 = a.signing.designated_requirement_sha256, .architectures = a.signing.architectures, .notarization = "accepted", .stapled = true },
            .assets = a.assets,
            .evidence = a.evidence,
            .predecessor = .{ .release_id = 77, .tag = "v1.2.3", .commit = commit, .manifest_sha256 = undefined },
        } };
    }

    fn bind(self: *Fixture) void {
        self.current_manifest.predecessor.?.manifest_sha256 = &self.a_sha;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.a_bytes);
    }
};

const Current = struct {
    fixture: *Fixture,
    valid: bool = true,
    revalidations: usize = 0,
    pub fn value(self: *const @This()) ?struct { manifest: *const manifest.Manifest } {
        return if (self.valid) .{ .manifest = &self.fixture.current_manifest } else null;
    }
    pub fn revalidate(self: *@This()) !void {
        self.revalidations += 1;
        if (!self.valid) return error.InvalidCurrent;
    }
};

const Deadline = struct {};
const AliasDeadline = struct { byte: u8 = 0 };

const Downloader = struct {
    fixture: *Fixture,
    calls: usize = 0,
    deadline_address: usize = 0,
    fail: bool = false,
    pub fn fetch(self: *@This(), deadline: anytype, _: std.mem.Allocator, executable: [:0]const u8, token: []const u8, expected: anytype, output: []u8) !composition.Downloaded {
        self.calls += 1;
        self.deadline_address = @intFromPtr(deadline);
        if (self.fail) return error.ChildFailed;
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("token", token);
        try std.testing.expectEqualStrings("v1.2.3", expected.tag);
        try std.testing.expectEqualStrings(&self.fixture.a_sha, expected.sha256);
        @memcpy(output[0..self.fixture.a_bytes.len], self.fixture.a_bytes);
        return .{ .name = "Maru-1.2.3-session-host-release.json", .sha256 = expected.sha256, .bytes = output[0..self.fixture.a_bytes.len] };
    }
};

const Authenticator = struct {
    calls: usize = 0,
    deadline_address: usize = 0,
    fail: bool = false,
    pub fn authenticate(self: *@This(), deadline: anytype, allocator: std.mem.Allocator, predecessor: manifest.Predecessor, bytes: []const u8, file: anytype, executable: [:0]const u8, token: []const u8, _: []u8, result: *authenticated_mod.AuthenticatedManifest) !void {
        self.calls += 1;
        self.deadline_address = @intFromPtr(deadline);
        if (self.fail) return error.AttestationMismatch;
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("token", token);
        const observed = try file.revalidate();
        try std.testing.expectEqualStrings(predecessor.manifest_sha256, observed.sha256);
        var parsed = try manifest.parseCanonical(allocator, bytes);
        errdefer parsed.deinit();
        const candidate = parsed.value();
        if (candidate.role != .a or candidate.predecessor != null or candidate.release.id != predecessor.release_id or
            !std.mem.eql(u8, candidate.release.tag, predecessor.tag) or !std.mem.eql(u8, candidate.source.commit, predecessor.commit))
            return error.InvalidPredecessor;
        result.* = .{ .owner = result, .parsed = parsed };
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, output: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(output, "{s}/{s}", .{ root[0..len], leaf });
}

test "authenticated B composes A with one deadline and owns cleanup" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.bind();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var current = Current{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var download_output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation_output: [1024]u8 = undefined;
    var result: composition.PredecessorManifestInput = .{};
    const current_source = composition.Current.from(&current);
    try composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, current_source, &workspace, "/opt/trusted/gh", "token", &download_output, &attestation_output, &result);
    try std.testing.expectEqual(@intFromPtr(&deadline), downloader.deadline_address);
    try std.testing.expectEqual(@intFromPtr(&deadline), authenticator.deadline_address);
    try std.testing.expectEqual(@as(usize, 2), current.revalidations);
    @memset(download_output[0..fixture.a_bytes.len], 0xaa);
    try std.testing.expectEqual(@as(u64, 77), result.value().?.release.id);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit(std.testing.allocator);
    try workspace.cleanup();
}

test "invalid current and pre-owned result do not touch workspace or children" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.bind();
    var current = Current{ .fixture = &fixture, .valid = false };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [32]u8 = undefined;
    var result: composition.PredecessorManifestInput = .{};
    var foreign_workspace: workspace_mod.Workspace = .{};
    var current_source = composition.Current.from(&current);
    try std.testing.expectError(error.InvalidCurrent, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, current_source, &foreign_workspace, "/opt/trusted/gh", "token", &output, &attestation, &result));
    result.owner = &result;
    current.valid = true;
    current_source = composition.Current.from(&current);
    try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, current_source, &foreign_workspace, "/opt/trusted/gh", "token", &output, &attestation, &result));
    try std.testing.expectEqual(@as(usize, 0), downloader.calls);
    try std.testing.expectEqual(@as(usize, 0), authenticator.calls);
}

test "copied workspace is rejected before download" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.bind();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var copied = workspace;
    var current = Current{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [32]u8 = undefined;
    var result: composition.PredecessorManifestInput = .{};
    try std.testing.expectError(error.InvalidWorkspace, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, composition.Current.from(&current), &copied, "/opt/trusted/gh", "token", &output, &attestation, &result));
    try std.testing.expectEqual(@as(usize, 0), downloader.calls);
    try workspace.cleanup();
}

test "overlapping owners are rejected before download or workspace mutation" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.bind();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var current = Current{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture, .fail = true };
    var authenticator = Authenticator{};
    var deadline = AliasDeadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [32]u8 = undefined;
    var result: composition.PredecessorManifestInput = .{};
    const current_source = composition.Current.from(&current);

    const Case = struct { download: []u8, attestation: []u8 };
    const cases = [_]Case{
        .{ .download = output[0..32], .attestation = output[16..48] },
        .{ .download = std.mem.asBytes(&result), .attestation = &attestation },
        .{ .download = std.mem.asBytes(&workspace), .attestation = &attestation },
        .{ .download = std.mem.asBytes(&current), .attestation = &attestation },
        .{ .download = std.mem.asBytes(&deadline), .attestation = &attestation },
        .{ .download = std.mem.asBytes(&fixture.current_manifest), .attestation = &attestation },
        .{ .download = fixture.a_sha[0..], .attestation = &attestation },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidOwner, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, current_source, &workspace, "/opt/trusted/gh", "token", case.download, case.attestation, &result));
    }
    try std.testing.expectEqual(@as(usize, 0), downloader.calls);
    try std.testing.expectEqual(@as(usize, 0), authenticator.calls);
    _ = try workspace.childPath(.predecessor_manifest, &path);
    try workspace.cleanup();
}

test "download and A authentication failures leave no child residue" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.bind();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var current = Current{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture, .fail = true };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [32]u8 = undefined;
    var result: composition.PredecessorManifestInput = .{};
    try std.testing.expectError(error.ChildFailed, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, composition.Current.from(&current), &workspace, "/opt/trusted/gh", "token", &output, &attestation, &result));
    _ = try workspace.childPath(.predecessor_manifest, &path);
    downloader.fail = false;
    authenticator.fail = true;
    try std.testing.expectError(error.AttestationMismatch, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, composition.Current.from(&current), &workspace, "/opt/trusted/gh", "token", &output, &attestation, &result));
    _ = try workspace.childPath(.predecessor_manifest, &path);
    try workspace.cleanup();
}

test "A drift is rejected and product wrapper is compiled" {
    _ = composition.authenticateUntil;
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    fixture.bind();
    fixture.current_manifest.predecessor.?.commit = "ffffffffffffffffffffffffffffffffffffffff";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var workspace: workspace_mod.Workspace = .{};
    try workspace_mod.prepare(&workspace, try absolute(&tmp, "phase", &path));
    var current = Current{ .fixture = &fixture };
    var downloader = Downloader{ .fixture = &fixture };
    var authenticator = Authenticator{};
    var deadline = Deadline{};
    var output: [manifest.max_manifest_bytes]u8 = undefined;
    var attestation: [32]u8 = undefined;
    var result: composition.PredecessorManifestInput = .{};
    try std.testing.expectError(error.InvalidPredecessor, composition.authenticateUntilWith(&downloader, &authenticator, &deadline, std.testing.allocator, composition.Current.from(&current), &workspace, "/opt/trusted/gh", "token", &output, &attestation, &result));
    try std.testing.expect(result.value() == null);
    _ = try workspace.childPath(.predecessor_manifest, &path);
    try workspace.cleanup();
}
