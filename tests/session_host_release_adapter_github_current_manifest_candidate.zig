const std = @import("std");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const candidate_mod = @import("release_adapter_github_current_manifest_candidate");

const file_name = "Maru-1.2.3-session-host-release.json";
const commit = "0123456789abcdef0123456789abcdef01234567";
const context: context_mod.Context = .{ .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = commit, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };

fn value() manifest.Manifest {
    return .{ .schema = manifest.schema, .role = .b, .repository = context.repository, .release = .{ .id = 77, .tag = context.tag, .version = "1.2.3" }, .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" }, .build = context.build, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &.{ .{ .role = .universal_dmg, .name = "Maru.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 }, .{ .role = .frozen_product_executable, .name = "maru-macos-app", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 }, .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 } }, .evidence = .{ .test_uuid = "123e4567-e89b-12d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" }, .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "2222222222222222222222222222222222222222", .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" } };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

test "canonical pathname publishes parsed owned candidate and transfers its exact input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try manifest.writeCanonical(std.testing.allocator, value());
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = bytes });
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var candidate: candidate_mod.CurrentManifestCandidate = .{};
    try candidate_mod.read(std.testing.allocator, context, try absolute(&tmp, file_name, &path), &candidate);
    try std.testing.expectEqualStrings("1.2.3", candidate.value().?.release.version);
    try std.testing.expectEqualStrings(bytes, candidate.bytes().?);
    var copied = candidate;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.takeInput());
    const pointer = candidate.bytes().?.ptr;
    var input = try candidate.takeInput();
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqual(pointer, input.bytes.ptr);
    try std.testing.expect(candidate.value() == null);
    try std.testing.expectError(error.InvalidOwner, candidate.takeInput());
}

test "relative wrong basename symlink empty and noncanonical input publish nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru-empty-session-host-release.json", .data = "" });
    try tmp.dir.symLink(std.testing.io, file_name, "Maru-linked-session-host-release.json", .{});
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var candidate: candidate_mod.CurrentManifestCandidate = .{};
    try std.testing.expectError(error.InvalidManifestPath, candidate_mod.read(std.testing.allocator, context, file_name, &candidate));
    try std.testing.expectError(error.InvalidManifestInput, candidate_mod.read(std.testing.allocator, context, try absolute(&tmp, file_name, &path), &candidate));
    var wrong_context = context;
    wrong_context.tag = "vlinked";
    try std.testing.expectError(error.InvalidManifestInput, candidate_mod.read(std.testing.allocator, wrong_context, try absolute(&tmp, "Maru-linked-session-host-release.json", &path), &candidate));
    wrong_context.tag = "vempty";
    try std.testing.expectError(error.InvalidManifestInput, candidate_mod.read(std.testing.allocator, wrong_context, try absolute(&tmp, "Maru-empty-session-host-release.json", &path), &candidate));
    try std.testing.expect(candidate.value() == null);
}

test "copied and pre-owned candidates cannot publish or consume" {
    var occupied: candidate_mod.CurrentManifestCandidate = .{};
    occupied.owner = &occupied;
    try std.testing.expectError(error.InvalidOwner, candidate_mod.read(std.testing.allocator, context, "/tmp/Maru-1.2.3-session-host-release.json", &occupied));
    var empty: candidate_mod.CurrentManifestCandidate = .{};
    try std.testing.expectError(error.InvalidOwner, empty.takeInput());
}

fn allocationHarness(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try manifest.writeCanonical(std.testing.allocator, value());
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = bytes });
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var candidate: candidate_mod.CurrentManifestCandidate = .{};
    candidate_mod.read(allocator, context, try absolute(&tmp, file_name, &path), &candidate) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    try candidate.deinit(allocator);
}

test "all allocation failures publish nothing and release ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationHarness, .{});
}
