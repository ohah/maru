//! Stage-3 preparation has one transaction owner and one irreversible durable commit point.

const std = @import("std");
const builtin = @import("builtin");
const phase = @import("release_adapter_candidate_stage3_preparation_phase");
const product = @import("release_adapter_candidate_stage3_preparation_product");
const evidence = @import("release_evidence");
const manifest_mod = @import("release_manifest");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");

const commit = "0123456789abcdef0123456789abcdef01234567";

fn productInputs(cli: *const product.PinnedCli, toolchain: *const product.ZigToolchainAuthority) product.Inputs {
    return .{
        .prerequisite = .{
            .context = .{ .repository = .{ .owner = "ohah", .name = "maru", .id = 1 }, .tag = "v1.2.3", .source_commit = commit, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 2, .run_attempt = 1 }, .protected_tag = true },
            .test_uuid = "01234567-89ab-4def-8123-456789abcdef",
            .paths = .{ .dmg = "/tmp/candidate.dmg", .frozen_executable = "/tmp/candidate-host", .dmg_work = "/tmp/dmg-work" },
            .bundles = .{ .dmg_bundle = "/tmp/dmg.bundle.json", .frozen_bundle = "/tmp/host.bundle.json" },
            .cli = .{ .path = "/usr/bin/gh", .pinned = cli },
        },
        .baseline = .{ .workspace_root = "/tmp/baseline", .app_paths = .{ .main_executable = "/tmp/maru-app", .cli_executable = "/tmp/maru-cli" }, .toolchain = toolchain, .source_directory_fd = 0 },
        .manifest = "/tmp/manifest/Maru-1.2.3-session-host-release.json",
        .durable_preparation = "/tmp/durable/stage3",
    };
}

const Event = enum { prerequisite, baseline, manifest, promote, fence, retain, clean_durable, clean_manifest, clean_baseline, clean_prerequisite, clean_deadline };

const Fake = struct {
    fail: ?phase.Stage = null,
    prerequisite_audit: bool = false,
    corrupt_preflight: bool = false,
    fail_after_retain_authority: bool = false,
    cleanup_fail: ?Event = null,
    cleanup_failed_once: bool = false,
    deadline: *u8,
    events: [24]Event = undefined,
    event_count: usize = 0,
    authority_checks: usize = 0,

    fn push(self: *@This(), event: Event) !void {
        self.events[self.event_count] = event;
        self.event_count += 1;
        if (self.cleanup_fail == event and !self.cleanup_failed_once) {
            self.cleanup_failed_once = true;
            return error.InjectedFailure;
        }
    }
    fn check(self: *@This(), deadline: *u8) !void {
        if (deadline != self.deadline) return error.WrongDeadline;
    }
    pub fn validatePreflight(self: *@This(), transaction: *phase.Transaction, _: *u8) !void {
        if (!transaction.isPristineForComposition()) return error.InvalidOwner;
        if (self.corrupt_preflight) transaction.audit_required = true;
    }
    pub fn validateAuthority(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        self.authority_checks += 1;
        if (self.fail_after_retain_authority and self.event_count != 0 and self.events[self.event_count - 1] == .retain)
            return error.InjectedAuthorityDrift;
    }
    pub fn runPrerequisite(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        try self.push(.prerequisite);
        if (self.fail == .prerequisite) return error.InjectedFailure;
    }
    pub fn prerequisiteNeedsAudit(self: *@This()) bool {
        return self.prerequisite_audit;
    }
    pub fn runBaseline(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        try self.push(.baseline);
        if (self.fail == .baseline) return error.InjectedFailure;
    }
    pub fn authorManifest(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        try self.push(.manifest);
        if (self.fail == .manifest) return error.InjectedFailure;
    }
    pub fn promoteDurable(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        try self.push(.promote);
        if (self.fail == .promote) return error.InjectedFailure;
    }
    pub fn fenceDurable(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        try self.push(.fence);
        if (self.fail == .fence) return error.InjectedFailure;
    }
    pub fn closeRetaining(self: *@This(), deadline: *u8) !void {
        try self.check(deadline);
        try self.push(.retain);
        if (self.fail == .retained_close) return error.InjectedFailure;
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.fail != .retained_close;
    }
    pub fn cleanupDurable(self: *@This()) !void {
        try self.push(.clean_durable);
    }
    pub fn cleanupManifest(self: *@This()) !void {
        try self.push(.clean_manifest);
    }
    pub fn cleanupBaseline(self: *@This()) !void {
        try self.push(.clean_baseline);
    }
    pub fn cleanupPrerequisite(self: *@This()) !void {
        try self.push(.clean_prerequisite);
    }
    pub fn cleanupDeadline(self: *@This()) !void {
        try self.push(.clean_deadline);
    }
};

fn expectEvents(fake: *const Fake, expected: []const Event) !void {
    try std.testing.expectEqualSlices(Event, expected, fake.events[0..fake.event_count]);
}

test "success commits retained durable preparation then removes local owners in reverse" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline };
    var transaction: phase.Transaction = .{};
    try phase.executeWith(&fake, &deadline, &transaction);
    try std.testing.expect(transaction.isPristineForComposition());
    try std.testing.expectEqual(@as(usize, 7), fake.authority_checks);
    try expectEvents(&fake, &.{ .prerequisite, .baseline, .manifest, .promote, .fence, .retain, .clean_manifest, .clean_baseline, .clean_prerequisite, .clean_deadline });
}

test "authority drift after retained close preserves durable commit for audit" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline, .fail_after_retain_authority = true };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&fake, &deadline, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expect(transaction.retainedCommit());
    try std.testing.expectEqual(phase.Stage.retained_close, transaction.auditStage());
    try std.testing.expectEqual(@as(usize, 7), fake.authority_checks);
    try expectEvents(&fake, &.{ .prerequisite, .baseline, .manifest, .promote, .fence, .retain });
    try phase.retryAuditCleanupWith(&fake, &transaction);
    try std.testing.expect(transaction.localCleanupComplete());
    for (fake.events[0..fake.event_count]) |event| try std.testing.expect(event != .clean_durable);
}

test "failure before draft mutation unwinds to pristine" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline, .fail = .prerequisite };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.InjectedFailure, phase.executeWith(&fake, &deadline, &transaction));
    try std.testing.expect(transaction.isPristineForComposition());
    try expectEvents(&fake, &.{ .prerequisite, .clean_prerequisite, .clean_deadline });
}

test "failure to unwind before draft retains only cleanup authority" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline, .fail = .prerequisite, .cleanup_fail = .clean_prerequisite };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.CleanupFailed, phase.executeWith(&fake, &deadline, &transaction));
    try std.testing.expect(transaction.needsCleanup());
    try phase.retryCleanupWith(&fake, &transaction);
    try std.testing.expect(transaction.isPristineForComposition());
}

test "draft mutation failure is audit terminal and never starts baseline" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline, .fail = .prerequisite, .prerequisite_audit = true };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&fake, &deadline, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expectEqual(phase.Stage.prerequisite, transaction.auditStage());
    try expectEvents(&fake, &.{.prerequisite});
}

test "every post-draft stage failure is audit terminal" {
    inline for (.{ phase.Stage.baseline, .manifest, .promote, .fence, .retained_close }) |failed_stage| {
        var deadline: u8 = 0;
        var fake = Fake{ .deadline = &deadline, .fail = failed_stage };
        var transaction: phase.Transaction = .{};
        try std.testing.expectError(error.AuditRequired, phase.executeWith(&fake, &deadline, &transaction));
        try std.testing.expect(transaction.needsAudit());
        try std.testing.expectEqual(failed_stage, transaction.auditStage());
    }
}

test "retained commit cleanup failure is audit and retry never removes durable bytes" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline, .cleanup_fail = .clean_baseline };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&fake, &deadline, &transaction));
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expect(transaction.retainedCommit());
    try std.testing.expect(!transaction.localCleanupComplete());
    try phase.retryAuditCleanupWith(&fake, &transaction);
    try std.testing.expect(transaction.needsAudit());
    try std.testing.expect(transaction.localCleanupComplete());
    for (fake.events[0..fake.event_count]) |event| try std.testing.expect(event != .clean_durable);
}

test "pre-owned and copied transaction are rejected before steps" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline };
    var original: phase.Transaction = .{};
    original.owner = &original;
    var copied = original;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&fake, &deadline, &original));
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&fake, &deadline, &copied));
    try std.testing.expectEqual(@as(usize, 0), fake.event_count);
}

test "preflight mutation fails closed and releases the caller deadline" {
    var deadline: u8 = 0;
    var fake = Fake{ .deadline = &deadline, .corrupt_preflight = true };
    var transaction: phase.Transaction = .{};
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&fake, &deadline, &transaction));
    try std.testing.expect(transaction.isPristineForComposition());
    try expectEvents(&fake, &.{.clean_deadline});
}

test "product exposes one final-address production owner and exact leaf callsites" {
    std.testing.refAllDecls(product);
    var execution: product.Execution = .{};
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(!execution.needsAudit());
    try std.testing.expectError(error.InvalidOwner, execution.retryCleanup());
    try std.testing.expectError(error.InvalidOwner, execution.retryAuditCleanup());

    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_stage3_preparation_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{
        "prerequisite.runBorrowingDeadline(", "baseline.runBorrowingDeadline(",          "candidate_manifest.author(",
        "preparation_handoff.promote(",       "self.execution.durable.closeRetaining()",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, needle));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "self.execution.durable.revalidate()"));
    inline for (.{ "candidate_authored_attestation", "draft_asset_attachment", "draft_asset_redownload", "draft_publication" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
}

test "product rejects invalid budget path overlap and dirty nested storage before authority access" {
    var cli: product.PinnedCli = undefined;
    var toolchain: product.ZigToolchainAuthority = undefined;
    var execution: product.Execution = .{};
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidBudget, product.run(std.testing.io, std.testing.allocator, productInputs(&cli, &toolchain), "token", &scratch, 0, &execution));
    try std.testing.expect(execution.isPristineForComposition());

    var value = productInputs(&cli, &toolchain);
    value.durable_preparation = "/tmp/baseline/durable";
    try std.testing.expectError(error.InvalidPath, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());

    value = productInputs(&cli, &toolchain);
    value.manifest = "/tmp/manifest/../Maru-1.2.3-session-host-release.json";
    try std.testing.expectError(error.InvalidPath, product.run(std.testing.io, std.testing.allocator, value, "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expect(execution.isPristineForComposition());

    execution.manifest.sha256[0] = 'x';
    try std.testing.expectError(error.InvalidOwner, product.run(std.testing.io, std.testing.allocator, productInputs(&cli, &toolchain), "token", &scratch, std.time.ns_per_s, &execution));
    try std.testing.expectEqual(@as(u8, 'x'), execution.manifest.sha256[0]);
}

test "nested prerequisite audit graph cannot be erased by local cleanup retry" {
    var execution: product.Execution = .{};
    execution.owner = &execution;
    execution.transaction.owner = &execution.transaction;
    execution.transaction.audit_required = true;
    execution.transaction.audit_stage = .prerequisite;
    execution.transaction.prerequisite_live = true;
    execution.transaction.deadline_live = true;
    execution.prerequisite.owner = &execution.prerequisite;
    execution.prerequisite.transaction.owner = &execution.prerequisite.transaction;
    execution.prerequisite.transaction.draft_attempted = true;
    execution.prerequisite.transaction.audit_required = true;
    execution.prerequisite.transaction.audit_stage = .draft;
    execution.deadline.owner = &execution.deadline;
    execution.deadline.started_ns = 1;
    execution.deadline.expires_ns = 2;
    try std.testing.expectError(error.CleanupFailed, execution.retryAuditCleanup());
    try std.testing.expect(execution.needsAudit());
    try std.testing.expect(!execution.transaction.localCleanupComplete());
    try std.testing.expect(execution.prerequisite.needsAudit());
}

test "product source keeps pathname roots in owner storage instead of forged sentinel slices" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_stage3_preparation_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "try copyParent("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "path[0..parent.len :0]"));
}

const PerfFixture = struct {
    tmp: std.testing.TmpDir,
    evidence_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    pinned: [2]files.PinnedReleaseFile = @splat(.{}),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDir(std.testing.io, "evidence", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "manifest", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "durable", .default_dir);
        const uuid = "123e4567-e89b-42d3-a456-426614174000";
        const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        const common: evidence.Common = .{ .test_uuid = uuid, .repository = .{ .id = 1, .owner = "ohah", .name = "maru" }, .release = .{ .id = 2, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 3, .run_attempt = 1 }, .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = exe_sha } };
        const default_leaf = "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
        const quit_leaf = "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
        const evidence_bytes = try evidence.assembleBaseline(std.testing.allocator, common, default_leaf, quit_leaf);
        defer std.testing.allocator.free(evidence_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence/baseline-evidence.json", .data = evidence_bytes });
        const evidence_path = try perfAbsolute(&self.tmp, "evidence/baseline-evidence.json", &self.evidence_path);
        const manifest_path = try perfAbsolute(&self.tmp, "manifest/Maru-1.2.3-session-host-release.json", &self.manifest_path);
        _ = try perfAbsolute(&self.tmp, "evidence", &self.evidence_root);
        _ = try perfAbsolute(&self.tmp, "manifest", &self.manifest_root);
        _ = try perfAbsolute(&self.tmp, "durable/prepared", &self.destination);
        try files.pinReleaseFileObserved(&self.pinned[0], evidence_path, false, evidence.max_evidence_bytes);
        const observed = self.pinned[0].value().?;
        const assets = [_]manifest_mod.Asset{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 1 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = exe_sha, .size = 1 },
            .{ .role = .evidence_summary, .name = handoff.evidence_name, .sha256 = &observed.sha256, .size = observed.size },
        };
        const manifest_bytes = try manifest_mod.writeCanonical(std.testing.allocator, .{ .schema = manifest_mod.schema, .role = .a, .repository = .{ .id = common.repository.id, .owner = common.repository.owner, .name = common.repository.name }, .release = .{ .id = common.release.id, .tag = common.release.tag, .version = common.release.version }, .source = .{ .commit = common.source.commit, .tree = common.source.tree }, .build = .{ .workflow_ref = common.build.workflow_ref, .run_id = common.build.run_id, .run_attempt = common.build.run_attempt }, .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 }, .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true }, .assets = &assets, .evidence = .{ .test_uuid = uuid, .summary_name = handoff.evidence_name, .summary_sha256 = &observed.sha256, .result = "passed" } });
        defer std.testing.allocator.free(manifest_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest/Maru-1.2.3-session-host-release.json", .data = manifest_bytes });
        try files.pinReleaseFileObserved(&self.pinned[1], manifest_path, false, manifest_mod.max_manifest_bytes);
    }
    fn deinit(self: *@This()) void {
        for (&self.pinned) |*value| if (value.value() != null) value.deinit() catch {};
        self.tmp.cleanup();
    }
};

const PerfSteps = struct {
    fixture: *PerfFixture,
    durable: handoff.DurablePreparation = .{},
    promote_ns: u64 = 0,
    fence_ns: u64 = 0,
    retain_ns: u64 = 0,
    cleanup_ns: u64 = 0,
    fn now() i128 {
        return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    }
    pub fn validatePreflight(_: *@This(), transaction: *phase.Transaction, _: *u8) !void {
        if (!transaction.isPristineForComposition()) return error.InvalidOwner;
    }
    pub fn validateAuthority(_: *@This(), _: *u8) !void {}
    pub fn runPrerequisite(_: *@This(), _: *u8) !void {}
    pub fn prerequisiteNeedsAudit(_: *@This()) bool {
        return false;
    }
    pub fn runBaseline(_: *@This(), _: *u8) !void {}
    pub fn authorManifest(_: *@This(), _: *u8) !void {}
    pub fn promoteDurable(self: *@This(), _: *u8) !void {
        const started = now();
        try handoff.promote(std.testing.allocator, .{
            .evidence = .{ .file = &self.fixture.pinned[0], .root = std.mem.sliceTo(&self.fixture.evidence_root, 0), .path = std.mem.sliceTo(&self.fixture.evidence_path, 0) },
            .manifest = .{ .file = &self.fixture.pinned[1], .root = std.mem.sliceTo(&self.fixture.manifest_root, 0), .path = std.mem.sliceTo(&self.fixture.manifest_path, 0) },
        }, std.mem.sliceTo(&self.fixture.destination, 0), &self.durable);
        self.promote_ns = @intCast(now() - started);
    }
    pub fn fenceDurable(self: *@This(), _: *u8) !void {
        const started = now();
        _ = try self.durable.revalidate();
        self.fence_ns = @intCast(now() - started);
    }
    pub fn closeRetaining(self: *@This(), _: *u8) !void {
        const started = now();
        try self.durable.closeRetaining();
        self.retain_ns = @intCast(now() - started);
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.durable.phase == .retained_closed;
    }
    pub fn cleanupDurable(self: *@This()) !void {
        if (self.durable.phase == .open or self.durable.phase == .cleanup_required) try self.durable.cleanup();
    }
    pub fn cleanupManifest(self: *@This()) !void {
        const started = now();
        try self.fixture.pinned[1].deinit();
        self.cleanup_ns += @intCast(now() - started);
    }
    pub fn cleanupBaseline(self: *@This()) !void {
        const started = now();
        try self.fixture.pinned[0].deinit();
        self.cleanup_ns += @intCast(now() - started);
    }
    pub fn cleanupPrerequisite(_: *@This()) !void {}
    pub fn cleanupDeadline(_: *@This()) !void {}
};

test "ReleaseFast records the actual durable stage3 boundary without touching app state" {
    const samples = 20;
    var promote: [samples]u64 = undefined;
    var fence: [samples]u64 = undefined;
    var retain: [samples]u64 = undefined;
    var cleanup: [samples]u64 = undefined;
    var total: [samples]u64 = undefined;
    const fd_before = try perfFdCount();
    for (0..samples) |index| {
        var fixture: PerfFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var deadline: u8 = 0;
        var steps = PerfSteps{ .fixture = &fixture };
        var transaction: phase.Transaction = .{};
        const started = PerfSteps.now();
        try phase.executeWith(&steps, &deadline, &transaction);
        total[index] = @intCast(PerfSteps.now() - started);
        promote[index] = steps.promote_ns;
        fence[index] = steps.fence_ns;
        retain[index] = steps.retain_ns;
        cleanup[index] = steps.cleanup_ns;
        _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/baseline-evidence.json", .{});
        _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/Maru-1.2.3-session-host-release.json", .{});
        var durable_dir = try fixture.tmp.dir.openDir(std.testing.io, "durable", .{ .iterate = true });
        defer durable_dir.close(std.testing.io);
        var iterator = durable_dir.iterate();
        var entries: usize = 0;
        while (try iterator.next(std.testing.io)) |entry| {
            try std.testing.expectEqualStrings("prepared", entry.name);
            entries += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), entries);
    }
    const fd_after = try perfFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    inline for (.{ &promote, &fence, &retain, &cleanup, &total }) |values| std.mem.sort(u64, values, {}, std.sort.asc(u64));
    if (builtin.mode == .ReleaseFast) std.debug.print("{{\"schema\":\"maru.session-host-release-stage3-preparation-product-perf.v1\",\"samples\":20,\"failures\":0,\"fd_delta\":0,\"residue\":0,\"promote_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"fence_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"retained_close_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"local_cleanup_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}},\"total_ns\":{{\"median\":{d},\"p95\":{d},\"max\":{d}}}}}\n", .{ promote[10], promote[18], promote[19], fence[10], fence[18], fence[19], retain[10], retain[18], retain[19], cleanup[10], cleanup[18], cleanup[19], total[10], total[18], total[19] });
}

fn perfAbsolute(tmp: *std.testing.TmpDir, suffix: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..len], suffix });
}

fn perfFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
