const std = @import("std");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const candidate_manifest = @import("release_adapter_candidate_manifest");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const predecessor_manifest_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const predecessor_dmg_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const predecessor_exe_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const requirement_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

fn common() evidence.Common {
    return .{ .test_uuid = uuid, .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 }, .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = exe_sha } };
}
fn defaultLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
}
fn quitLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
}
fn predecessor() evidence.Predecessor {
    return .{ .release_id = 400, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha, .dmg_sha256 = predecessor_dmg_sha, .executable_sha256 = predecessor_exe_sha };
}
fn upgradeLeaf(comptime count: u64) []const u8 {
    return std.fmt.comptimePrint("{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, predecessor_exe_sha, exe_sha, requirement_sha, count, if (count == 1) requirement_sha else predecessor_manifest_sha });
}

const Authority = struct {
    calls: usize = 0,
    drift: bool = false,
    role_b: bool = false,
    swap_path: ?[:0]const u8 = null,
    alias_bytes: ?[]const u8 = null,
    assets: [3]manifest.Asset = undefined,
    summary_sha: [64]u8 = undefined,
    pub fn revalidate(self: *@This(), profile: evidence.Profile, summary: files.ExecutableObservation, paths: candidate_manifest.Paths) !candidate_manifest.Bundle {
        self.calls += 1;
        if (self.calls == 3) if (self.swap_path) |swap_path|
            if (std.c.rename(swap_path.ptr, paths.evidence.ptr) != 0) return error.SwapFailed;
        const wanted_profile: evidence.Profile = if (self.role_b) .upgrade_b else .baseline_a;
        if (profile != wanted_profile) return error.RoleMismatch;
        const tree = if (self.drift and self.calls > 2) "3333333333333333333333333333333333333333" else common().source.tree;
        var expected_common = common();
        if (self.alias_bytes) |bytes| expected_common.test_uuid = bytes[0..36];
        expected_common.source.tree = tree;
        self.summary_sha = summary.sha256;
        self.assets = .{
            .{ .role = .universal_dmg, .name = std.fs.path.basename(paths.dmg), .sha256 = dmg_sha, .size = 100 },
            .{ .role = .frozen_product_executable, .name = std.fs.path.basename(paths.frozen_executable), .sha256 = exe_sha, .size = 200 },
            .{ .role = .evidence_summary, .name = std.fs.path.basename(paths.evidence), .sha256 = &self.summary_sha, .size = summary.size },
        };
        return .{ .expected = if (self.role_b) .{ .upgrade_b = .{ .common = expected_common, .predecessor = predecessor(), .designated_requirement_sha256 = requirement_sha } } else .{ .baseline_a = expected_common }, .designated_requirement_sha256 = requirement_sha, .value = .{ .schema = manifest.schema, .role = if (self.role_b) .b else .a, .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = common().source.commit, .tree = tree }, .build = .{ .workflow_ref = common().build.workflow_ref, .run_id = common().build.run_id, .run_attempt = common().build.run_attempt }, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.example.maru", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &self.assets, .evidence = .{ .test_uuid = uuid, .summary_name = std.fs.path.basename(paths.evidence), .summary_sha256 = &self.summary_sha, .result = "passed" }, .predecessor = if (self.role_b) .{ .release_id = predecessor().release_id, .tag = predecessor().tag, .commit = predecessor().commit, .manifest_sha256 = predecessor().manifest_sha256 } else null } };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    evidence_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *@This(), role_b: bool) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        const bytes = if (role_b)
            try evidence.assembleUpgrade(std.testing.allocator, common(), predecessor(), upgradeLeaf(1), upgradeLeaf(evidence.near_max_runtime_count))
        else
            try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
        defer std.testing.allocator.free(bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = bytes });
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(std.testing.io, &root);
        _ = try std.fmt.bufPrintZ(&self.evidence_path, "{s}/evidence.json", .{root[0..n]});
        _ = try std.fmt.bufPrintZ(&self.output_path, "{s}/Maru-1.2.3-session-host-release.json", .{root[0..n]});
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn paths(self: *@This()) candidate_manifest.Paths {
        return .{ .dmg = "/tmp/Maru.dmg", .frozen_executable = "/tmp/maru-session-host", .evidence = std.mem.sliceTo(&self.evidence_path, 0), .output = std.mem.sliceTo(&self.output_path, 0) };
    }
};

test "held evidence chooses role and publishes canonical manifest" {
    comptime _ = candidate_manifest.author;
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var authority: Authority = .{};
    var result: files.PinnedReleaseFile = .{};
    try candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result);
    defer result.deinit() catch {};
    try std.testing.expectEqual(@as(usize, 3), authority.calls);
    _ = try held.revalidate(f.paths().evidence);
    const input = try result.readHeldAlloc(std.testing.allocator, f.paths().output, manifest.max_manifest_bytes);
    var owned = input;
    defer owned.deinit(std.testing.allocator);
    var parsed = try manifest.parseCanonical(std.testing.allocator, input.bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(manifest.Role.a, parsed.value().role);
}

test "role B is inferred from held evidence and binds predecessor" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var authority: Authority = .{ .role_b = true };
    var result: files.PinnedReleaseFile = .{};
    try candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result);
    defer result.deinit() catch {};
    var input = try result.readHeldAlloc(std.testing.allocator, f.paths().output, manifest.max_manifest_bytes);
    defer input.deinit(std.testing.allocator);
    var parsed = try manifest.parseCanonical(std.testing.allocator, input.bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(manifest.Role.b, parsed.value().role);
    try std.testing.expectEqual(predecessor().release_id, parsed.value().predecessor.?.release_id);
}

test "authority drift publishes nothing" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var authority: Authority = .{ .drift = true };
    var result: files.PinnedReleaseFile = .{};
    try std.testing.expectError(error.AuthorityChanged, candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "Maru-1.2.3-session-host-release.json", .{}));
}

test "malformed evidence existing output and allocation failure publish nothing" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = "{}\n" });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try f.tmp.dir.realPath(std.testing.io, &root);
    var bad_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const bad_path = try std.fmt.bufPrintZ(&bad_path_buf, "{s}/bad.json", .{root[0..n]});
    var bad_held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&bad_held, bad_path, false, evidence.max_evidence_bytes);
    defer bad_held.deinit() catch {};
    var authority: Authority = .{};
    var result: files.PinnedReleaseFile = .{};
    try std.testing.expectError(error.InvalidJson, candidate_manifest.authorWith(std.testing.allocator, &authority, &bad_held, .{ .dmg = "/tmp/Maru.dmg", .frozen_executable = "/tmp/maru-session-host", .evidence = bad_path, .output = f.paths().output }, &result));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "Maru-1.2.3-session-host-release.json", .{}));

    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru-1.2.3-session-host-release.json", .data = "foreign" });
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, candidate_manifest.authorWith(failing.allocator(), &authority, &held, f.paths(), &result));
    try std.testing.expectError(error.DestinationExists, candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result));
    const foreign = try f.tmp.dir.readFileAlloc(std.testing.io, "Maru-1.2.3-session-host-release.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);
}

test "every injected allocation failure leaves manifest absent" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var authority: Authority = .{};
        var result: files.PinnedReleaseFile = .{};
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        candidate_manifest.authorWith(failing.allocator(), &authority, &held, f.paths(), &result) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(result.value() == null);
            try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "Maru-1.2.3-session-host-release.json", .{}));
            continue;
        };
        try result.deinit();
        break;
    }
    try std.testing.expect(fail_index > 0);
}

test "copied evidence owner and preowned result fail before publication" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var copied = held;
    var authority: Authority = .{};
    var result: files.PinnedReleaseFile = .{};
    try std.testing.expectError(error.InvalidOwner, candidate_manifest.authorWith(std.testing.allocator, &authority, &copied, f.paths(), &result));
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "Maru-1.2.3-session-host-release.json", .{}));
}

test "nested authority bundle cannot alias result storage" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var result: files.PinnedReleaseFile = .{};
    var authority: Authority = .{ .alias_bytes = std.mem.asBytes(&result) };
    try std.testing.expectError(error.InvalidOwner, candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "Maru-1.2.3-session-host-release.json", .{}));
}

test "evidence replacement during final authority check publishes nothing" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "swap.json", .data = "foreign\n" });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try f.tmp.dir.realPath(std.testing.io, &root);
    var swap_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const swap_path = try std.fmt.bufPrintZ(&swap_buf, "{s}/swap.json", .{root[0..n]});
    var held: files.PinnedReleaseFile = .{};
    try files.pinReleaseFileObserved(&held, f.paths().evidence, false, evidence.max_evidence_bytes);
    defer held.deinit() catch {};
    var authority: Authority = .{ .swap_path = swap_path };
    var result: files.PinnedReleaseFile = .{};
    try std.testing.expectError(error.EvidenceChanged, candidate_manifest.authorWith(std.testing.allocator, &authority, &held, f.paths(), &result));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "Maru-1.2.3-session-host-release.json", .{}));
    const foreign = try f.tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign\n", foreign);
}
