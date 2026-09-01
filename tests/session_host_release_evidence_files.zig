//! Canonical release evidence가 actual filesystem의 stable leaf bytes에서만 publication되는지 검증한다.

const std = @import("std");
const evidence = @import("release_evidence");
const evidence_files = @import("release_evidence_files");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const sha_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const sha_d = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const sha_e = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const sha_f = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

fn common() evidence.Common {
    return .{
        .test_uuid = uuid,
        .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 },
        .candidate = .{ .dmg_sha256 = sha_a, .executable_sha256 = sha_b },
    };
}

fn predecessor() evidence.Predecessor {
    return .{ .release_id = 400, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = sha_c, .dmg_sha256 = sha_d, .executable_sha256 = sha_e };
}

fn defaultLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ sha_a ++ "\",\"candidate_executable_sha256\":\"" ++ sha_b ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
}

fn quitLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ sha_a ++ "\",\"candidate_executable_sha256\":\"" ++ sha_b ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
}

fn upgradeLeaf(comptime count: u64) []const u8 {
    const runtime_set = if (count == 1) sha_f else sha_c;
    return std.fmt.comptimePrint("{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, sha_e, sha_b, sha_f, count, runtime_set });
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

fn expectAbsent(tmp: *std.testing.TmpDir, leaf: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, leaf, .{}));
}

test "baseline leaves publish one rebound canonical aggregate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default.json", .data = defaultLeaf() });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "quit.json", .data = quitLeaf() });
    var a: [std.fs.max_path_bytes:0]u8 = undefined;
    var b: [std.fs.max_path_bytes:0]u8 = undefined;
    var out: [std.fs.max_path_bytes:0]u8 = undefined;
    try evidence_files.publishBaseline(std.testing.allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "default.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "quit.json", &b),
        .output_path = try absolute(&tmp, "evidence.json", &out),
    });
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(evidence.max_evidence_bytes));
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .baseline_a = common() });
}

test "upgrade leaves publish exact one and near-max roles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.json", .data = upgradeLeaf(1) });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "near.json", .data = upgradeLeaf(evidence.near_max_runtime_count) });
    var a: [std.fs.max_path_bytes:0]u8 = undefined;
    var b: [std.fs.max_path_bytes:0]u8 = undefined;
    var out: [std.fs.max_path_bytes:0]u8 = undefined;
    var wrong_predecessor = predecessor();
    wrong_predecessor.executable_sha256 = sha_b;
    try std.testing.expectError(error.LeafMismatch, evidence_files.publishUpgrade(std.testing.allocator, .{
        .common = common(),
        .predecessor = wrong_predecessor,
        .designated_requirement_sha256 = sha_f,
        .one_path = try absolute(&tmp, "one.json", &a),
        .near_max_path = try absolute(&tmp, "near.json", &b),
        .output_path = try absolute(&tmp, "evidence.json", &out),
    }));
    try expectAbsent(&tmp, "evidence.json");
    try evidence_files.publishUpgrade(std.testing.allocator, .{
        .common = common(),
        .predecessor = predecessor(),
        .designated_requirement_sha256 = sha_f,
        .one_path = try absolute(&tmp, "one.json", &a),
        .near_max_path = try absolute(&tmp, "near.json", &b),
        .output_path = try absolute(&tmp, "evidence.json", &out),
    });
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(evidence.max_evidence_bytes));
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .upgrade_b = .{
        .common = common(),
        .predecessor = predecessor(),
        .designated_requirement_sha256 = sha_f,
    } });
}

test "symlink and hardlink leaf aliases publish nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "leaf.json", .data = defaultLeaf() });
    try tmp.dir.symLink(std.testing.io, "leaf.json", "linked.json", .{});
    var a: [std.fs.max_path_bytes:0]u8 = undefined;
    var b: [std.fs.max_path_bytes:0]u8 = undefined;
    var out: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.UnsafePath, evidence_files.publishBaseline(std.testing.allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "linked.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "leaf.json", &b),
        .output_path = try absolute(&tmp, "out.json", &out),
    }));
    try expectAbsent(&tmp, "out.json");

    try std.testing.expectEqual(@as(c_int, 0), std.c.linkat(tmp.dir.handle, "leaf.json", tmp.dir.handle, "alias.json", 0));
    try std.testing.expectError(error.PathAlias, evidence_files.publishBaseline(std.testing.allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "leaf.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "alias.json", &b),
        .output_path = try absolute(&tmp, "out.json", &out),
    }));
    try expectAbsent(&tmp, "out.json");
}

test "malformed and identity-drift leaves publish nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = "{}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "quit.json", .data = quitLeaf() });
    var a: [std.fs.max_path_bytes:0]u8 = undefined;
    var b: [std.fs.max_path_bytes:0]u8 = undefined;
    var out: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.InvalidLeaf, evidence_files.publishBaseline(std.testing.allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "bad.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "quit.json", &b),
        .output_path = try absolute(&tmp, "out.json", &out),
    }));
    try expectAbsent(&tmp, "out.json");

    const drift = try std.mem.replaceOwned(u8, std.testing.allocator, defaultLeaf(), sha_b, sha_c);
    defer std.testing.allocator.free(drift);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = drift });
    try std.testing.expectError(error.LeafMismatch, evidence_files.publishBaseline(std.testing.allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "bad.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "quit.json", &b),
        .output_path = try absolute(&tmp, "out.json", &out),
    }));
    try expectAbsent(&tmp, "out.json");
}

test "existing output is preserved exactly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default.json", .data = defaultLeaf() });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "quit.json", .data = quitLeaf() });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out.json", .data = "existing" });
    var a: [std.fs.max_path_bytes:0]u8 = undefined;
    var b: [std.fs.max_path_bytes:0]u8 = undefined;
    var out: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.DestinationExists, evidence_files.publishBaseline(std.testing.allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "default.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "quit.json", &b),
        .output_path = try absolute(&tmp, "out.json", &out),
    }));
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "out.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("existing", bytes);
}

fn publishAllocation(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default.json", .data = defaultLeaf() });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "quit.json", .data = quitLeaf() });
    var a: [std.fs.max_path_bytes:0]u8 = undefined;
    var b: [std.fs.max_path_bytes:0]u8 = undefined;
    var out: [std.fs.max_path_bytes:0]u8 = undefined;
    evidence_files.publishBaseline(allocator, .{
        .common = common(),
        .default_false_path = try absolute(&tmp, "default.json", &a),
        .signed_app_quit_path = try absolute(&tmp, "quit.json", &b),
        .output_path = try absolute(&tmp, "out.json", &out),
    }) catch |err| {
        try expectAbsent(&tmp, "out.json");
        return err;
    };
}

test "allocation failure never leaves a partial publication" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, publishAllocation, .{});
}
