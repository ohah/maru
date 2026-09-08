//! Credential-free profile selection owns freshly reopened authored subjects.

const std = @import("std");
const c = std.c;
const evidence = @import("release_evidence");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");
const profile = @import("release_adapter_profile_endorsement");
const selector = @import("release_adapter_profile_authored_attestation_selector");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const requirement_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
const predecessor_manifest_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const predecessor_dmg_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const predecessor_exe_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const baseline_document = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n";
const upgrade_document = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":400,\"tag\":\"v1.2.2\",\"commit\":\"3333333333333333333333333333333333333333\",\"manifest_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}}\n";

fn trustedContext() context_mod.Context {
    return .{ .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = "1111111111111111111111111111111111111111", .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 }, .protected_tag = true };
}

fn common() evidence.Common {
    return .{ .test_uuid = uuid, .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = trustedContext().source_commit, .tree = "2222222222222222222222222222222222222222" }, .build = .{ .workflow_ref = trustedContext().build.workflow_ref, .run_id = 789, .run_attempt = 2 }, .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = exe_sha } };
}

fn defaultLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
}

fn quitLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
}

fn upgradeLeaf(comptime count: u64) []const u8 {
    return std.fmt.comptimePrint("{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, predecessor_exe_sha, exe_sha, requirement_sha, count, if (count == 1) requirement_sha else predecessor_manifest_sha });
}

const Environment = struct {
    document: []const u8,
    calls: usize = 0,
    drift_at: ?usize = null,
    fn value(self: *@This()) profile.Environment {
        return .{ .context = self, .read_fn = read };
    }
    fn read(raw: *anyopaque, name: [:0]const u8) ?[]const u8 {
        if (!std.mem.eql(u8, name, profile.environment_name)) return null;
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.drift_at) |at| if (self.calls >= at) return upgrade_document;
        return self.document;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    roots: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    sources: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    preparation: [std.fs.max_path_bytes:0]u8 = @splat(0),
    baseline: [std.fs.max_path_bytes:0]u8 = @splat(0),
    upgrade: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    timing: [std.fs.max_path_bytes:0]u8 = @splat(0),
    owners: [2]files.PinnedReleaseFile = @splat(.{}),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        for ([_][]const u8{ "evidence", "manifest", "durable" }) |name| try self.tmp.dir.createDir(std.testing.io, name, .default_dir);
        if (c.fchmodat(self.tmp.dir.handle, "durable", 0o700, 0) != 0) return error.FixtureFailed;
        const evidence_bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
        defer std.testing.allocator.free(evidence_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence/baseline-evidence.json", .data = evidence_bytes });
        _ = try absolute(&self.tmp, "evidence", &self.roots[0]);
        _ = try absolute(&self.tmp, "manifest", &self.roots[1]);
        const evidence_path = try absolute(&self.tmp, "evidence/baseline-evidence.json", &self.sources[0]);
        const manifest_source = try absolute(&self.tmp, "manifest/Maru-1.2.3-session-host-release.json", &self.sources[1]);
        _ = try absolute(&self.tmp, "durable/prepared", &self.preparation);
        _ = try absolute(&self.tmp, "durable/prepared/baseline-evidence.json", &self.baseline);
        _ = try absolute(&self.tmp, "durable/prepared/upgrade-evidence.json", &self.upgrade);
        _ = try absolute(&self.tmp, "durable/prepared/Maru-1.2.3-session-host-release.json", &self.manifest_path);
        _ = try absolute(&self.tmp, "durable/profile-upgrade-timing.json", &self.timing);
        try files.pinReleaseFileObserved(&self.owners[0], evidence_path, false, evidence.max_evidence_bytes);
        const observed = self.owners[0].value().?;
        const assets = [_]manifest.Asset{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 100 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = exe_sha, .size = 200 },
            .{ .role = .evidence_summary, .name = handoff.baseline_evidence_name, .sha256 = &observed.sha256, .size = observed.size },
        };
        const manifest_bytes = try manifest.writeCanonical(std.testing.allocator, .{
            .schema = manifest.schema,
            .role = .a,
            .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = common().source.commit, .tree = common().source.tree },
            .build = .{ .workflow_ref = trustedContext().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.example.maru", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = handoff.baseline_evidence_name, .summary_sha256 = &observed.sha256, .result = "passed" },
        });
        defer std.testing.allocator.free(manifest_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest/Maru-1.2.3-session-host-release.json", .data = manifest_bytes });
        try files.pinReleaseFileObserved(&self.owners[1], manifest_source, false, manifest.max_manifest_bytes);
        var durable: handoff.DurablePreparation = .{};
        try handoff.promote(std.testing.allocator, .{
            .evidence = .{ .file = &self.owners[0], .root = self.root(0), .path = self.source(0) },
            .manifest = .{ .file = &self.owners[1], .root = self.root(1), .path = self.source(1) },
        }, self.preparationPath(), &durable);
        try durable.closeRetaining();
        for (&self.owners) |*owner| try owner.deinit();
    }

    fn deinit(self: *@This()) void {
        for (&self.owners) |*owner| if (owner.value() != null) owner.deinit() catch {};
        self.tmp.cleanup();
    }

    fn replaceWithUpgrade(self: *@This()) !void {
        try self.tmp.dir.deleteTree(std.testing.io, "durable/prepared");
        try self.tmp.dir.deleteFile(std.testing.io, "evidence/baseline-evidence.json");
        const predecessor: evidence.Predecessor = .{ .release_id = 400, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha, .dmg_sha256 = predecessor_dmg_sha, .executable_sha256 = predecessor_exe_sha };
        const evidence_bytes = try evidence.assembleUpgrade(std.testing.allocator, common(), predecessor, upgradeLeaf(1), upgradeLeaf(evidence.near_max_runtime_count));
        defer std.testing.allocator.free(evidence_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence/upgrade-evidence.json", .data = evidence_bytes });
        _ = try absolute(&self.tmp, "evidence/upgrade-evidence.json", &self.sources[0]);
        try files.pinReleaseFileObserved(&self.owners[0], self.source(0), false, evidence.max_evidence_bytes);
        const observed = self.owners[0].value().?;
        const assets = [_]manifest.Asset{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 100 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = exe_sha, .size = 200 },
            .{ .role = .evidence_summary, .name = handoff.upgrade_evidence_name, .sha256 = &observed.sha256, .size = observed.size },
        };
        const manifest_bytes = try manifest.writeCanonical(std.testing.allocator, .{
            .schema = manifest.schema,
            .role = .b,
            .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = common().source.commit, .tree = common().source.tree },
            .build = .{ .workflow_ref = trustedContext().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.example.maru", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = handoff.upgrade_evidence_name, .summary_sha256 = &observed.sha256, .result = "passed" },
            .predecessor = .{ .release_id = 400, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha },
        });
        defer std.testing.allocator.free(manifest_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest/Maru-1.2.3-session-host-release.json", .data = manifest_bytes });
        try files.pinReleaseFileObserved(&self.owners[1], self.source(1), false, manifest.max_manifest_bytes);
        var durable: handoff.DurablePreparation = .{};
        try handoff.promote(std.testing.allocator, .{
            .evidence = .{ .file = &self.owners[0], .root = self.root(0), .path = self.source(0) },
            .manifest = .{ .file = &self.owners[1], .root = self.root(1), .path = self.source(1) },
        }, self.preparationPath(), &durable);
        try durable.closeRetaining();
        for (&self.owners) |*owner| try owner.deinit();
        const timing_bytes = "{\"schema\":\"maru.session-host-profile-upgrade-timing.v1\",\"profile\":\"upgrade_b\",\"repository_id\":123,\"repository\":\"ohah/maru\",\"tag\":\"v1.2.3\",\"source_commit\":\"1111111111111111111111111111111111111111\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":789,\"run_attempt\":2,\"predecessor_auth_ns\":10,\"signed_one_ns\":20,\"signed_near_max_ns\":30,\"runner_phase_ns\":60,\"profile_phase_ns\":80}\n";
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/profile-upgrade-timing.json", .data = timing_bytes });
        if (c.fchmodat(self.tmp.dir.handle, "durable/profile-upgrade-timing.json", 0o600, 0) != 0) return error.FixtureFailed;
    }
    fn root(self: *@This(), i: usize) [:0]const u8 {
        return std.mem.sliceTo(&self.roots[i], 0);
    }
    fn source(self: *@This(), i: usize) [:0]const u8 {
        return std.mem.sliceTo(&self.sources[i], 0);
    }
    fn preparationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.preparation, 0);
    }
    fn paths(self: *@This()) selector.Paths {
        return .{ .preparation = self.preparationPath(), .baseline_evidence = std.mem.sliceTo(&self.baseline, 0), .upgrade_evidence = std.mem.sliceTo(&self.upgrade, 0), .manifest = std.mem.sliceTo(&self.manifest_path, 0), .timing = std.mem.sliceTo(&self.timing, 0) };
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], suffix });
}

test "baseline selector fresh-reopens the exact evidence and manifest pair" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment: Environment = .{ .document = baseline_document };
    var plan: selector.Plan = .{};
    try selector.select(std.testing.allocator, trustedContext(), environment.value(), fixture.paths(), &plan);
    const selected = plan.value().?;
    try std.testing.expectEqualStrings(handoff.baseline_evidence_name, selected.evidence_name);
    try std.testing.expect(!selected.timing_required);
    try std.testing.expectEqualStrings("", selected.timing_path);
    var copied = plan;
    try std.testing.expect(copied.value() == null);
    _ = try plan.fence(std.testing.allocator, trustedContext(), environment.value());
    try plan.deinit();
    try std.testing.expect(environment.calls >= 6);
}

test "profile mismatch and baseline timing presence fail before a plan exists" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var upgrade_environment: Environment = .{ .document = upgrade_document };
    var plan: selector.Plan = .{};
    try std.testing.expectError(error.ProfileMismatch, selector.select(std.testing.allocator, trustedContext(), upgrade_environment.value(), fixture.paths(), &plan));
    try std.testing.expect(plan.isPristineForComposition());
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/profile-upgrade-timing.json", .data = "foreign" });
    var baseline_environment: Environment = .{ .document = baseline_document };
    try std.testing.expectError(error.UnexpectedTiming, selector.select(std.testing.allocator, trustedContext(), baseline_environment.value(), fixture.paths(), &plan));
    try std.testing.expect(plan.isPristineForComposition());
}

test "upgrade selector fresh-reopens timing as the third retained subject" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.replaceWithUpgrade();
    var environment: Environment = .{ .document = upgrade_document };
    var plan: selector.Plan = .{};
    try selector.select(std.testing.allocator, trustedContext(), environment.value(), fixture.paths(), &plan);
    const selected = plan.value().?;
    try std.testing.expectEqualStrings(handoff.upgrade_evidence_name, selected.evidence_name);
    try std.testing.expect(selected.timing_required);
    try std.testing.expectEqualStrings("profile-upgrade-timing.json", selected.timing_name);
    _ = try plan.fence(std.testing.allocator, trustedContext(), environment.value());
    try plan.deinit();
    _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/profile-upgrade-timing.json", .{});
}

test "borrowed path mutation is isolated and predecessor substitution is rejected" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var baseline_environment: Environment = .{ .document = baseline_document };
    var plan: selector.Plan = .{};
    try selector.select(std.testing.allocator, trustedContext(), baseline_environment.value(), fixture.paths(), &plan);
    const original = fixture.baseline[1];
    fixture.baseline[1] = if (original == 'x') 'y' else 'x';
    _ = try plan.fence(std.testing.allocator, trustedContext(), baseline_environment.value());
    fixture.baseline[1] = original;
    plan.selected = .upgrade_b;
    try std.testing.expect(plan.value() == null);
    plan.selected = .baseline_a;
    try plan.deinit();

    try fixture.replaceWithUpgrade();
    const wrong_predecessor = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":400,\"tag\":\"v1.2.2\",\"commit\":\"3333333333333333333333333333333333333333\",\"manifest_sha256\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"}}\n";
    var wrong_environment: Environment = .{ .document = wrong_predecessor };
    try std.testing.expectError(error.ProfileMismatch, selector.select(std.testing.allocator, trustedContext(), wrong_environment.value(), fixture.paths(), &plan));
    try std.testing.expect(plan.isPristineForComposition());
}

test "path graph preflight runs before environment and environment drift leaves no owner" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment: Environment = .{ .document = baseline_document };
    var paths = fixture.paths();
    var nested_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    paths.timing = try std.fmt.bufPrintZ(&nested_storage, "{s}/profile-upgrade-timing.json", .{paths.preparation});
    var plan: selector.Plan = .{};
    try std.testing.expectError(error.InvalidPath, selector.select(std.testing.allocator, trustedContext(), environment.value(), paths, &plan));
    try std.testing.expectEqual(@as(usize, 0), environment.calls);
    environment.drift_at = 3;
    try std.testing.expectError(error.AuthorityChanged, selector.select(std.testing.allocator, trustedContext(), environment.value(), fixture.paths(), &plan));
    try std.testing.expect(plan.isPristineForComposition());
}

test "held subject mutation invalidates the final fence" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment: Environment = .{ .document = baseline_document };
    var plan: selector.Plan = .{};
    try selector.select(std.testing.allocator, trustedContext(), environment.value(), fixture.paths(), &plan);
    const evidence_path = fixture.paths().baseline_evidence;
    if (c.chmod(evidence_path.ptr, 0o644) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.FileChanged, plan.fence(std.testing.allocator, trustedContext(), environment.value()));
    if (c.chmod(evidence_path.ptr, 0o600) != 0) return error.FixtureFailed;
    try plan.deinit();
}

test "every allocation failure unwinds selector ownership" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var environment: Environment = .{ .document = baseline_document };
        var plan: selector.Plan = .{};
        selector.select(failing.allocator(), trustedContext(), environment.value(), fixture.paths(), &plan) catch |err| switch (err) {
            error.OutOfMemory, error.AuthorityChanged => {
                try std.testing.expect(plan.isPristineForComposition());
                continue;
            },
            else => return err,
        };
        try plan.deinit();
        break;
    }
    try std.testing.expect(fail_index > 0);
}
