//! Profile-authored final fencing retains the selected subjects and their bundles.

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
const fence = @import("release_adapter_profile_authored_attestation_fence");
const context_mod = @import("release_adapter_context");
const profile = @import("release_adapter_profile_endorsement");
const selector = @import("release_adapter_profile_authored_attestation_selector");
const evidence = @import("release_evidence");
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");
const command = @import("release_adapter_profile_authored_attestation_fence_command");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const requirement_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
const predecessor_manifest_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const predecessor_dmg_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const predecessor_exe_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const baseline_document = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"baseline_a\"}\n";
const upgrade_document = "{\"schema\":\"maru.session-host-release-profile.v1\",\"profile\":\"upgrade_b\",\"predecessor\":{\"release_id\":400,\"tag\":\"v1.2.2\",\"commit\":\"3333333333333333333333333333333333333333\",\"manifest_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}}\n";

extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*c]?[*:0]u8;

test "profile-authored final fence exposes a move-only owner" {
    _ = fence.Fence;
    try std.testing.expect(true);
}

const NoCalls = struct {
    calls: usize = 0,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        return error.UnexpectedCall;
    }
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        return error.UnexpectedCall;
    }
    pub fn verifyBundleWith(self: *@This(), _: *NoCalls, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, expected: anytype, _: []u8, _: i128) !Observation {
        self.calls += 1;
        return .{ .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256 };
    }
};

const Observation = struct {
    verified: bool = true,
    run_id: u64 = 789,
    run_attempt: u64 = 2,
    subject_name: []const u8,
    subject_sha256: []const u8,
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};

const Environment = struct {
    document: ?[]const u8 = null,
    calls: usize = 0,
    drift_at: ?usize = null,
    fn value(self: *@This()) profile.Environment {
        return .{ .context = self, .read_fn = read };
    }
    fn read(raw: *anyopaque, name: [:0]const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, name, profile.environment_name)) return null;
        self.calls += 1;
        if (self.drift_at) |at| if (self.calls >= at) return upgrade_document;
        return self.document;
    }
};

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "1111111111111111111111111111111111111111",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn common() evidence.Common {
    return .{
        .test_uuid = uuid,
        .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = context().source_commit, .tree = "2222222222222222222222222222222222222222" },
        .build = .{ .workflow_ref = context().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
        .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = exe_sha },
    };
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

const BaselineFixture = struct {
    tmp: std.testing.TmpDir,
    roots: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    sources: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    preparation: [std.fs.max_path_bytes:0]u8 = @splat(0),
    baseline: [std.fs.max_path_bytes:0]u8 = @splat(0),
    upgrade: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    timing: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_bundle: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_bundle: [std.fs.max_path_bytes:0]u8 = @splat(0),
    timing_bundle: [std.fs.max_path_bytes:0]u8 = @splat(0),
    owners: [2]files.PinnedReleaseFile = @splat(.{}),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        for ([_][]const u8{ "evidence", "manifest", "durable", "bundles" }) |name| try self.tmp.dir.createDir(std.testing.io, name, .default_dir);
        const evidence_bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
        defer std.testing.allocator.free(evidence_bytes);
        if (c.fchmodat(self.tmp.dir.handle, "durable", 0o700, 0) != 0) return error.FixtureFailed;
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence/baseline-evidence.json", .data = evidence_bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bundles/evidence.bundle", .data = "evidence bundle" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bundles/manifest.bundle", .data = "manifest bundle" });
        _ = try absolute(&self.tmp, "evidence", &self.roots[0]);
        _ = try absolute(&self.tmp, "manifest", &self.roots[1]);
        const evidence_path = try absolute(&self.tmp, "evidence/baseline-evidence.json", &self.sources[0]);
        const manifest_source = try absolute(&self.tmp, "manifest/Maru-1.2.3-session-host-release.json", &self.sources[1]);
        _ = try absolute(&self.tmp, "durable/prepared", &self.preparation);
        _ = try absolute(&self.tmp, "durable/prepared/baseline-evidence.json", &self.baseline);
        _ = try absolute(&self.tmp, "durable/prepared/upgrade-evidence.json", &self.upgrade);
        _ = try absolute(&self.tmp, "durable/prepared/Maru-1.2.3-session-host-release.json", &self.manifest_path);
        _ = try absolute(&self.tmp, "durable/profile-upgrade-timing.json", &self.timing);
        _ = try absolute(&self.tmp, "bundles/evidence.bundle", &self.evidence_bundle);
        _ = try absolute(&self.tmp, "bundles/manifest.bundle", &self.manifest_bundle);
        _ = try absolute(&self.tmp, "bundles/timing.bundle", &self.timing_bundle);
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
            .build = .{ .workflow_ref = context().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
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

    fn replaceWithUpgrade(self: *@This()) !void {
        try self.tmp.dir.deleteTree(std.testing.io, "durable/prepared");
        try self.tmp.dir.deleteFile(std.testing.io, "evidence/baseline-evidence.json");
        const predecessor: evidence.Predecessor = .{
            .release_id = 400,
            .tag = "v1.2.2",
            .commit = "3333333333333333333333333333333333333333",
            .manifest_sha256 = predecessor_manifest_sha,
            .dmg_sha256 = predecessor_dmg_sha,
            .executable_sha256 = predecessor_exe_sha,
        };
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
            .build = .{ .workflow_ref = context().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
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
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bundles/timing.bundle", .data = "timing bundle" });
    }

    fn deinit(self: *@This()) void {
        for (&self.owners) |*owner| if (owner.value() != null) owner.deinit() catch {};
        self.tmp.cleanup();
    }
    fn root(self: *@This(), index: usize) [:0]const u8 {
        return std.mem.sliceTo(&self.roots[index], 0);
    }
    fn source(self: *@This(), index: usize) [:0]const u8 {
        return std.mem.sliceTo(&self.sources[index], 0);
    }
    fn preparationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.preparation, 0);
    }
    fn paths(self: *@This()) selector.Paths {
        return .{ .preparation = self.preparationPath(), .baseline_evidence = std.mem.sliceTo(&self.baseline, 0), .upgrade_evidence = std.mem.sliceTo(&self.upgrade, 0), .manifest = std.mem.sliceTo(&self.manifest_path, 0), .timing = std.mem.sliceTo(&self.timing, 0) };
    }
    fn projection(self: *@This()) selector.Projection {
        const selected = self.paths();
        return .{ .evidence_path = selected.baseline_evidence, .evidence_name = handoff.baseline_evidence_name, .manifest_path = selected.manifest, .manifest_name = "Maru-1.2.3-session-host-release.json", .timing_required = false, .timing_path = "", .timing_name = "" };
    }
    fn bundles(self: *@This()) fence.BundlePaths {
        return .{ .evidence = std.mem.sliceTo(&self.evidence_bundle, 0), .manifest = std.mem.sliceTo(&self.manifest_bundle, 0), .timing = "" };
    }
    fn upgradeProjection(self: *@This()) selector.Projection {
        const selected = self.paths();
        return .{ .evidence_path = selected.upgrade_evidence, .evidence_name = handoff.upgrade_evidence_name, .manifest_path = selected.manifest, .manifest_name = "Maru-1.2.3-session-host-release.json", .timing_required = true, .timing_path = selected.timing, .timing_name = "profile-upgrade-timing.json" };
    }

    fn upgradeBundles(self: *@This()) fence.BundlePaths {
        return .{ .evidence = std.mem.sliceTo(&self.evidence_bundle, 0), .manifest = std.mem.sliceTo(&self.manifest_bundle, 0), .timing = std.mem.sliceTo(&self.timing_bundle, 0) };
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], suffix });
}

const Deadline = struct {
    calls: usize = 0,
    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        return 1_000_000_000;
    }
};

const Authority = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.ExecutableChanged;
    }
};

const Verifier = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    mutate_at: ?usize = null,
    mutate_path: ?[:0]const u8 = null,
    names: [3][]const u8 = @splat(""),
    pub fn verifyBundleWith(self: *@This(), _: *Verifier, _: std.mem.Allocator, _: []const u8, path: []const u8, _: []const u8, expected: anytype, _: []u8, _: i128) !Observation {
        const index = self.calls;
        self.calls += 1;
        if (self.fail_at == self.calls) return error.VerificationFailed;
        if (self.mutate_at == self.calls) {
            const target = self.mutate_path orelse return error.BadTest;
            const fd = c.open(target.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
            if (fd < 0) return error.FixtureFailed;
            defer _ = c.close(fd);
            const changed = [_]u8{'X'};
            if (c.pwrite(fd, &changed, changed.len, 0) != changed.len) return error.FixtureFailed;
        }
        self.names[index] = std.fs.path.basename(path);
        return .{ .subject_name = expected.subject_name, .subject_sha256 = expected.subject_sha256 };
    }
};

test "baseline final fence verifies evidence then manifest and retains both bundles" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment = Environment{ .document = baseline_document };
    var authority = Authority{};
    var verifier = Verifier{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: fence.Fence = .{};
    try fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result);
    const view = result.value().?;
    try std.testing.expectEqual(@as(usize, 2), view.verified_count);
    try std.testing.expectEqualStrings(handoff.baseline_evidence_name, verifier.names[0]);
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", verifier.names[1]);
    try std.testing.expectEqual(@as(usize, 2), verifier.calls);
    try std.testing.expectEqual(@as(usize, 5), authority.calls);
    try std.testing.expectEqual(@as(usize, 5), deadline.calls);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    _ = try result.revalidate(std.testing.allocator, context(), environment.value());
    try result.deinit();
    try std.testing.expect(result.isPristineForComposition());
}

test "upgrade final fence verifies evidence manifest then timing and retains three bundles" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.replaceWithUpgrade();
    var environment = Environment{ .document = upgrade_document };
    var authority = Authority{};
    var verifier = Verifier{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: fence.Fence = .{};
    try fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), environment.value(), fixture.paths(), fixture.upgradeProjection(), fixture.upgradeBundles(), "/opt/trusted/gh", &output, &result);
    const view = result.value().?;
    try std.testing.expectEqual(@as(usize, 3), view.verified_count);
    try std.testing.expectEqualStrings(handoff.upgrade_evidence_name, verifier.names[0]);
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", verifier.names[1]);
    try std.testing.expectEqualStrings("profile-upgrade-timing.json", verifier.names[2]);
    try std.testing.expectEqual(@as(usize, 3), verifier.calls);
    try std.testing.expectEqual(@as(usize, 7), authority.calls);
    try std.testing.expectEqual(@as(usize, 7), deadline.calls);
    _ = try result.revalidate(std.testing.allocator, context(), environment.value());
    try result.deinit();
}

test "partial verifier failure publishes no owner and closes every held descriptor" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment = Environment{ .document = baseline_document };
    var authority = Authority{};
    var verifier = Verifier{ .fail_at = 2 };
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: fence.Fence = .{};
    try std.testing.expectError(error.VerificationFailed, fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result));
    try std.testing.expectEqual(@as(usize, 2), verifier.calls);
    try std.testing.expect(result.isPristineForComposition());
}

test "bundle mutation during verification invalidates the graph and publishes nothing" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment = Environment{ .document = baseline_document };
    var authority = Authority{};
    var verifier = Verifier{ .mutate_at = 1, .mutate_path = fixture.bundles().evidence };
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: fence.Fence = .{};
    try std.testing.expectError(error.FileChanged, fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), verifier.calls);
    try std.testing.expect(result.isPristineForComposition());
}

test "hardlinked bundles are rejected before verifier publication" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const bundles = fixture.bundles();
    if (c.unlink(bundles.manifest.ptr) != 0 or c.link(bundles.evidence.ptr, bundles.manifest.ptr) != 0) return error.FixtureFailed;
    var environment = Environment{ .document = baseline_document };
    var authority = Authority{};
    var verifier = Verifier{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: fence.Fence = .{};
    try std.testing.expectError(error.PathAlias, fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), environment.value(), fixture.paths(), fixture.projection(), bundles, "/opt/trusted/gh", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
    try std.testing.expect(result.isPristineForComposition());
}

test "baseline timing exchange is rejected before every external callback" {
    var environment = Environment{};
    var callbacks = NoCalls{};
    var result: fence.Fence = .{};
    var output: [8192]u8 = undefined;
    const paths: selector.Paths = .{
        .preparation = "/private/tmp/prepared",
        .baseline_evidence = "/private/tmp/prepared/baseline-evidence.json",
        .upgrade_evidence = "/private/tmp/prepared/upgrade-evidence.json",
        .manifest = "/private/tmp/prepared/Maru-1.2.3-session-host-release.json",
        .timing = "/private/tmp/profile-upgrade-timing.json",
    };
    const exchanged: selector.Projection = .{
        .evidence_path = paths.baseline_evidence,
        .evidence_name = "baseline-evidence.json",
        .manifest_path = paths.manifest,
        .manifest_name = "Maru-1.2.3-session-host-release.json",
        .timing_required = true,
        .timing_path = paths.timing,
        .timing_name = "profile-upgrade-timing.json",
    };
    try std.testing.expectError(error.ProjectionMismatch, fence.composeBundlesUntilWith(
        &callbacks,
        &callbacks,
        &callbacks,
        &callbacks,
        std.testing.allocator,
        context(),
        environment.value(),
        paths,
        exchanged,
        .{ .evidence = "/private/tmp/evidence.bundle", .manifest = "/private/tmp/manifest.bundle", .timing = "/private/tmp/timing.bundle" },
        "/opt/trusted/gh",
        &output,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 0), environment.calls);
    try std.testing.expectEqual(@as(usize, 0), callbacks.calls);
    try std.testing.expect(result.isPristineForComposition());
}

test "profile and CLI authority drift publish no final fence" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var verifier = Verifier{};
    var deadline = Deadline{};
    var output: [8192]u8 = undefined;
    var result: fence.Fence = .{};

    var drifting_environment = Environment{ .document = baseline_document, .drift_at = 3 };
    var authority = Authority{};
    try std.testing.expectError(error.AuthorityChanged, fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), drifting_environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result));
    try std.testing.expect(result.isPristineForComposition());

    var stable_environment = Environment{ .document = baseline_document };
    authority = .{ .fail_at = 2 };
    verifier = .{};
    deadline = .{};
    try std.testing.expectError(error.ExecutableChanged, fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), stable_environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), verifier.calls);
    try std.testing.expect(result.isPristineForComposition());
}

test "missing empty oversized and symlink bundles fail before verification" {
    const Scenario = enum { missing, empty, oversized, symlink };
    inline for ([_]Scenario{ .missing, .empty, .oversized, .symlink }) |scenario| {
        var fixture: BaselineFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const bundle_path = fixture.bundles().evidence;
        switch (scenario) {
            .missing => if (c.unlink(bundle_path.ptr) != 0) return error.FixtureFailed,
            .symlink => {
                if (c.unlink(bundle_path.ptr) != 0 or c.symlink("manifest.bundle", bundle_path.ptr) != 0) return error.FixtureFailed;
            },
            .empty, .oversized => {
                const fd = c.open(bundle_path.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
                if (fd < 0) return error.FixtureFailed;
                defer _ = c.close(fd);
                const size: c.off_t = if (scenario == .empty) 0 else @intCast(16 * 1024 * 1024 + 1);
                if (c.ftruncate(fd, size) != 0) return error.FixtureFailed;
            },
        }
        var environment = Environment{ .document = baseline_document };
        var authority = Authority{};
        var verifier = Verifier{};
        var deadline = Deadline{};
        var output: [8192]u8 = undefined;
        var result: fence.Fence = .{};
        const actual = fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, std.testing.allocator, context(), environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result);
        if (scenario == .missing or scenario == .symlink) try std.testing.expectError(error.UnsafePath, actual) else try std.testing.expectError(error.TooLarge, actual);
        try std.testing.expectEqual(@as(usize, 0), verifier.calls);
        try std.testing.expect(result.isPristineForComposition());
    }
}

test "every allocation failure unwinds the final fence owner" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var environment = Environment{ .document = baseline_document };
        var authority = Authority{};
        var verifier = Verifier{};
        var deadline = Deadline{};
        var output: [8192]u8 = undefined;
        var result: fence.Fence = .{};
        fence.composeBundlesUntilWith(&authority, &verifier, &verifier, &deadline, failing.allocator(), context(), environment.value(), fixture.paths(), fixture.projection(), fixture.bundles(), "/opt/trusted/gh", &output, &result) catch |err| switch (err) {
            error.OutOfMemory, error.AuthorityChanged => {
                try std.testing.expect(result.isPristineForComposition());
                continue;
            },
            else => return err,
        };
        try result.deinit();
        break;
    }
    try std.testing.expect(fail_index > 0);
}

test "invalid bundle graph is rejected before every external callback" {
    var environment = Environment{};
    var callbacks = NoCalls{};
    var result: fence.Fence = .{};
    var output: [8192]u8 = undefined;
    const paths: selector.Paths = .{
        .preparation = "/private/tmp/prepared",
        .baseline_evidence = "/private/tmp/prepared/baseline-evidence.json",
        .upgrade_evidence = "/private/tmp/prepared/upgrade-evidence.json",
        .manifest = "/private/tmp/prepared/Maru-1.2.3-session-host-release.json",
        .timing = "/private/tmp/profile-upgrade-timing.json",
    };
    const expected: selector.Projection = .{
        .evidence_path = paths.baseline_evidence,
        .evidence_name = "baseline-evidence.json",
        .manifest_path = paths.manifest,
        .manifest_name = "Maru-1.2.3-session-host-release.json",
        .timing_required = false,
        .timing_path = "",
        .timing_name = "",
    };
    try std.testing.expectError(error.PathAlias, fence.composeBundlesUntilWith(
        &callbacks,
        &callbacks,
        &callbacks,
        &callbacks,
        std.testing.allocator,
        context(),
        environment.value(),
        paths,
        expected,
        .{ .evidence = paths.baseline_evidence, .manifest = "/private/tmp/manifest.bundle", .timing = "" },
        "/opt/trusted/gh",
        &output,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 0), environment.calls);
    try std.testing.expectEqual(@as(usize, 0), callbacks.calls);
    try std.testing.expect(result.isPristineForComposition());

    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, fence.composeBundlesUntilWith(
        &callbacks,
        &callbacks,
        &callbacks,
        &callbacks,
        std.testing.allocator,
        context(),
        environment.value(),
        paths,
        expected,
        .{ .evidence = "/private/tmp/evidence.bundle", .manifest = "/private/tmp/manifest.bundle", .timing = "" },
        "/opt/trusted/gh",
        &output,
        &result,
    ));
    result = .{};
    const aliased_output = std.mem.asBytes(&result)[0..128];
    try std.testing.expectError(error.InvalidInput, fence.composeBundlesUntilWith(
        &callbacks,
        &callbacks,
        &callbacks,
        &callbacks,
        std.testing.allocator,
        context(),
        environment.value(),
        paths,
        expected,
        .{ .evidence = "/private/tmp/evidence.bundle", .manifest = "/private/tmp/manifest.bundle", .timing = "" },
        "/opt/trusted/gh",
        aliased_output,
        &result,
    ));
    try std.testing.expectEqual(@as(usize, 0), callbacks.calls);
    try std.testing.expect(result.isPristineForComposition());
}

fn fenceArgs(paths: selector.Paths, projection: selector.Projection, bundles: fence.BundlePaths) [command.argument_count][]const u8 {
    return .{
        "fence",
        "--preparation",
        paths.preparation,
        "--baseline-evidence",
        paths.baseline_evidence,
        "--upgrade-evidence",
        paths.upgrade_evidence,
        "--manifest",
        paths.manifest,
        "--timing",
        paths.timing,
        "--evidence-path",
        projection.evidence_path,
        "--evidence-name",
        projection.evidence_name,
        "--manifest-path",
        projection.manifest_path,
        "--manifest-name",
        projection.manifest_name,
        "--timing-required",
        if (projection.timing_required) "true" else "false",
        "--timing-path",
        projection.timing_path,
        "--timing-name",
        projection.timing_name,
        "--evidence-bundle",
        bundles.evidence,
        "--manifest-bundle",
        bundles.manifest,
        "--timing-bundle",
        bundles.timing,
        "--github-cli",
        "/opt/trusted/gh",
        "--github-cli-sha256",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
}

test "fence command parser accepts exact baseline and upgrade tuples" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var baseline_args = fenceArgs(fixture.paths(), fixture.projection(), fixture.bundles());
    const baseline = try command.parse(&baseline_args);
    try std.testing.expect(!baseline.projection.timing_required);
    try std.testing.expectEqualStrings("", baseline.bundles.timing);
    try fixture.replaceWithUpgrade();
    var upgrade_args = fenceArgs(fixture.paths(), fixture.upgradeProjection(), fixture.upgradeBundles());
    const upgrade = try command.parse(&upgrade_args);
    try std.testing.expect(upgrade.projection.timing_required);
    try std.testing.expectEqualStrings("profile-upgrade-timing.json", upgrade.projection.timing_name);
}

test "fence command execution owns output only after internal cleanup" {
    _ = command.compose;
    var execution: command.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(execution.output() == null);
}

test "fence command parser rejects duplicate control and profile tuple exchange" {
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var args = fenceArgs(fixture.paths(), fixture.projection(), fixture.bundles());
    args[1] = "--manifest";
    try std.testing.expectError(error.InvalidArguments, command.parse(&args));
    args = fenceArgs(fixture.paths(), fixture.projection(), fixture.bundles());
    args[4] = "/tmp/injected\npath";
    try std.testing.expectError(error.InvalidArguments, command.parse(&args));
    args = fenceArgs(fixture.paths(), fixture.projection(), fixture.bundles());
    args[22] = "true";
    try std.testing.expectError(error.InvalidProfileTuple, command.parse(&args));
}

test "actual fresh fence processes verify both profiles without FD or stderr residue" {
    const samples = 20;
    if (_NSGetArgc().* < 4) return error.SkipZigTest;
    const process_argv = _NSGetArgv().*;
    const executable_input = std.mem.span(process_argv[2] orelse return error.SkipZigTest);
    const verifier_input = std.mem.span(process_argv[3] orelse return error.SkipZigTest);
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, executable_input, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const verifier = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, verifier_input, std.testing.allocator);
    defer std.testing.allocator.free(verifier);
    const verifier_sha = try executableSha256(verifier);
    var fixture: BaselineFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var environment = try processEnvironment(baseline_document);
    defer environment.deinit();

    const warm = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{"/usr/bin/true"},
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
    });
    defer std.testing.allocator.free(warm.stdout);
    defer std.testing.allocator.free(warm.stderr);
    switch (warm.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.ChildFailed,
    }

    const fd_before = try openFdCount();
    var baseline_ns: [samples]u64 = undefined;
    var upgrade_ns: [samples]u64 = undefined;
    for (0..samples) |index| {
        const started = monotonicNs();
        const output = try runFenceProcess(executable, verifier, &verifier_sha, fixture.paths(), fixture.projection(), fixture.bundles(), &environment);
        baseline_ns[index] = monotonicNs() - started;
        defer std.testing.allocator.free(output);
        try expectFenceOutput(output, fixture.projection(), fixture.bundles());
        try expectAndRemoveVerificationMarkers(fixture.bundles(), 2);
    }

    try fixture.replaceWithUpgrade();
    try environment.put(profile.environment_name, upgrade_document);
    for (0..samples) |index| {
        const started = monotonicNs();
        const output = try runFenceProcess(executable, verifier, &verifier_sha, fixture.paths(), fixture.upgradeProjection(), fixture.upgradeBundles(), &environment);
        upgrade_ns[index] = monotonicNs() - started;
        defer std.testing.allocator.free(output);
        try expectFenceOutput(output, fixture.upgradeProjection(), fixture.upgradeBundles());
        try expectAndRemoveVerificationMarkers(fixture.upgradeBundles(), 3);
    }
    try runFenceProcessFailure(executable, verifier, &verifier_sha, fixture.paths(), fixture.upgradeProjection(), fixture.upgradeBundles(), &environment);
    try expectNoVerificationMarkers(fixture.upgradeBundles());
    const fd_after = try openFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, &baseline_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, &upgrade_ns, {}, std.sort.asc(u64));
    std.debug.print("profile_authored_attestation_fence_process schema=maru.session-host-profile-authored-attestation-fence-process-perf.v1 mode={s} samples_per_profile={d} failures=0 rejected_invalid=1 fd_delta=0 stderr_bytes=0 baseline_verifications=2 upgrade_verifications=3 baseline_median_ns={d} baseline_p95_ns={d} baseline_max_ns={d} upgrade_median_ns={d} upgrade_p95_ns={d} upgrade_max_ns={d} residue=0\n", .{
        @tagName(builtin.mode),               samples,
        baseline_ns[samples / 2],             baseline_ns[(samples * 95 - 1) / 100],
        baseline_ns[samples - 1],             upgrade_ns[samples / 2],
        upgrade_ns[(samples * 95 - 1) / 100], upgrade_ns[samples - 1],
    });
}

fn processEnvironment(profile_document: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    errdefer map.deinit();
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },
        .{ .key = "GITHUB_REPOSITORY_ID", .value = "123" },
        .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },
        .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },
        .{ .key = "GITHUB_SHA", .value = context().source_commit },
        .{ .key = "GITHUB_WORKFLOW_REF", .value = context().build.workflow_ref },
        .{ .key = "GITHUB_RUN_ID", .value = "789" },
        .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },
        .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },
        .{ .key = profile.environment_name, .value = profile_document },
    };
    for (values) |entry| try map.put(entry.key, entry.value);
    return map;
}

fn executableSha256(path: []const u8) ![64]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(128 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn runFenceProcess(executable: []const u8, verifier: []const u8, verifier_sha: *const [64]u8, paths: selector.Paths, projection_value: selector.Projection, bundles: fence.BundlePaths, environment: *const std.process.Environ.Map) ![]u8 {
    var args = fenceArgs(paths, projection_value, bundles);
    args[32] = verifier;
    args[34] = verifier_sha;
    var argv: [1 + command.argument_count][]const u8 = undefined;
    argv[0] = executable;
    @memcpy(argv[1..], &args);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .environ_map = environment,
        .stdout_limit = .limited(command.max_output_bytes),
        .stderr_limit = .limited(1),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.ChildFailed,
    }
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
    return result.stdout;
}

fn runFenceProcessFailure(executable: []const u8, verifier: []const u8, verifier_sha: *const [64]u8, paths: selector.Paths, projection_value: selector.Projection, bundles: fence.BundlePaths, environment: *const std.process.Environ.Map) !void {
    var args = fenceArgs(paths, projection_value, bundles);
    args[32] = verifier;
    args[34] = verifier_sha;
    args[14] = "forged-evidence.json";
    var argv: [1 + command.argument_count][]const u8 = undefined;
    argv[0] = executable;
    @memcpy(argv[1..], &args);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .environ_map = environment,
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 1), code),
        else => return error.ChildFailed,
    }
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

fn expectFenceOutput(actual: []const u8, projection_value: selector.Projection, bundles: fence.BundlePaths) !void {
    var storage: [command.max_output_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&storage, "evidence-path={s}\ntiming-path={s}\nevidence-bundle-path={s}\nmanifest-bundle-path={s}\ntiming-bundle-path={s}\n", .{ projection_value.evidence_path, projection_value.timing_path, bundles.evidence, bundles.manifest, bundles.timing });
    try std.testing.expectEqualStrings(expected, actual);
}

fn markerPath(path: []const u8, storage: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}.verified", .{path});
}

fn expectAndRemoveVerificationMarkers(bundles: fence.BundlePaths, expected: usize) !void {
    var observed: usize = 0;
    for ([_][]const u8{ bundles.evidence, bundles.manifest, bundles.timing }) |bundle_path| {
        if (bundle_path.len == 0) continue;
        var storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const marker = try markerPath(bundle_path, &storage);
        _ = try std.Io.Dir.cwd().statFile(std.testing.io, marker, .{});
        try std.Io.Dir.cwd().deleteFile(std.testing.io, marker);
        observed += 1;
    }
    try std.testing.expectEqual(expected, observed);
}

fn expectNoVerificationMarkers(bundles: fence.BundlePaths) !void {
    for ([_][]const u8{ bundles.evidence, bundles.manifest, bundles.timing }) |bundle_path| {
        if (bundle_path.len == 0) continue;
        var storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const marker = try markerPath(bundle_path, &storage);
        _ = std.Io.Dir.cwd().statFile(std.testing.io, marker, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return error.UnexpectedVerification;
    }
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
