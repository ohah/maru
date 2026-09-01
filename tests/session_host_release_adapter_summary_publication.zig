//! Authenticated validation owners publish exactly one canonical audit file.

const std = @import("std");
const manifest = @import("release_manifest");
const summary = @import("release_adapter_summary");
const publication = @import("release_adapter_summary_publication");
const current_observation = @import("release_adapter_github_current_observation");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

const release_assets = [_]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 101 },
    .{ .role = .frozen_product_executable, .name = "maru-macos-app", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 202 },
    .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 303 },
};

fn candidate(role: manifest.Role) manifest.Manifest {
    return .{
        .schema = manifest.schema,
        .role = role,
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .release = .{ .id = if (role == .a) 76 else 77, .tag = if (role == .a) "v1.2.2" else "v1.2.3", .version = if (role == .a) "1.2.2" else "1.2.3" },
        .source = .{ .commit = if (role == .a) "2222222222222222222222222222222222222222" else "3333333333333333333333333333333333333333", .tree = "1111111111111111111111111111111111111111" },
        .build = .{ .workflow_ref = if (role == .a) "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.2" else "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = if (role == .a) 332 else 333, .run_attempt = 2 },
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 180 },
        .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = if (role == .a) "1.2.2" else "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = &release_assets,
        .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
        .predecessor = if (role == .b) .{ .release_id = 76, .tag = "v1.2.2", .commit = "2222222222222222222222222222222222222222", .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" } else null,
    };
}

const Current = struct {
    value_: manifest.Manifest,
    valid: bool = true,
    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return if (self.valid) &self.value_ else null;
    }
};

const Attested = struct {
    value_: manifest.Manifest,
    observed: ?struct { verified: bool } = .{ .verified = true },
    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        return &self.value_;
    }
};

const Held = struct {
    calls: usize = 0,
    pub fn revalidateSummary(self: *@This()) !summary.PredecessorAssetsView {
        self.calls += 1;
        return .{ .source_commit = "2222222222222222222222222222222222222222" };
    }
};

const Recorder = struct {
    calls: usize = 0,
    fail: bool = false,
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    pub fn publish(self: *@This(), path: [:0]const u8, bytes: []const u8) !void {
        try std.testing.expectEqualStrings("/unused/summary.json", path);
        self.calls += 1;
        if (self.fail) return error.PublishFailed;
        try std.testing.expect(bytes.len <= self.bytes.len);
        @memcpy(self.bytes[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

test "production publication entrypoints compile through both closed owner graphs" {
    var current: current_observation.CurrentObservation = .{};
    try std.testing.expectError(error.InvalidOwner, publication.publishPrePublish(std.testing.allocator, &current, "/unused/summary.json"));
    var predecessor: authenticated_manifest.AuthenticatedManifest = .{};
    var held: predecessor_assets.AuthenticatedPredecessorAssets = .{};
    try std.testing.expectError(error.InvalidOwner, publication.publishPredecessor(std.testing.allocator, &predecessor, &held, "/unused/summary.json"));
}

test "production current owner publishes exact canonical bytes mode 0600 and preserves destination" {
    const manifest_bytes = try manifest.writeCanonical(std.testing.allocator, candidate(.b));
    defer std.testing.allocator.free(manifest_bytes);
    const parsed = try manifest.parseCanonical(std.testing.allocator, manifest_bytes);
    var current: current_observation.CurrentObservation = .{ .parsed = parsed };
    current.owner = &current;
    defer current.deinit() catch unreachable;
    const expected = try summary.encodePrePublish(std.testing.allocator, &current);
    defer std.testing.allocator.free(expected);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "summary.json", &path_buf);
    try publication.publishPrePublish(std.testing.allocator, &current, path);
    const actual = try tmp.dir.readFileAlloc(std.testing.io, "summary.json", std.testing.allocator, .limited(summary.max_summary_bytes));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const stat = try tmp.dir.statFile(std.testing.io, "summary.json", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try std.testing.expectError(error.DestinationExists, publication.publishPrePublish(std.testing.allocator, &current, path));
    const preserved = try tmp.dir.readFileAlloc(std.testing.io, "summary.json", std.testing.allocator, .limited(summary.max_summary_bytes));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings(expected, preserved);
}

test "both phases encode before one publish and publisher owns no borrowed bytes" {
    var recorder = Recorder{};
    var current = Current{ .value_ = candidate(.b) };
    try publication.publishPrePublishWith(&recorder, std.testing.allocator, &current, "/unused/summary.json");
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(std.mem.indexOf(u8, recorder.bytes[0..recorder.len], "\"phase\":\"pre_publish\"") != null);
    recorder = .{};
    var predecessor = Attested{ .value_ = candidate(.a) };
    var held = Held{};
    try publication.publishPredecessorWith(&recorder, std.testing.allocator, &predecessor, &held, "/unused/summary.json");
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(usize, 2), held.calls);
    try std.testing.expect(std.mem.indexOf(u8, recorder.bytes[0..recorder.len], "\"phase\":\"verify_predecessor\"") != null);
}

test "owner validation publishes zero and publication failure is terminal" {
    var recorder = Recorder{};
    var current = Current{ .value_ = candidate(.b), .valid = false };
    try std.testing.expectError(error.InvalidOwner, publication.publishPrePublishWith(&recorder, std.testing.allocator, &current, "/unused/summary.json"));
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
    current.valid = true;
    recorder.fail = true;
    try std.testing.expectError(error.PublishFailed, publication.publishPrePublishWith(&recorder, std.testing.allocator, &current, "/unused/summary.json"));
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var recorder = Recorder{};
    var current = Current{ .value_ = candidate(.b) };
    try publication.publishPrePublishWith(&recorder, allocator, &current, "/unused/summary.json");
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "every allocation prefix publishes zero or one complete summary and unwinds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}
