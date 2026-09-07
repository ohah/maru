const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const product = @import("release_adapter_profile_stage3_preparation_product");
const evidence = @import("release_evidence");
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");

const Event = enum {
    start_deadline,
    preflight,
    validate_profile,
    author_manifest,
    promote_durable,
    fence_durable,
    close_retaining,
    cleanup_durable,
    cleanup_manifest,
    cleanup_deadline,
};

const Fake = struct {
    events: [32]Event = @splat(.start_deadline),
    count: usize = 0,
    fail_event: ?Event = null,
    cleanup_fail_event: ?Event = null,
    fail_validation: usize = 0,
    validation_count: usize = 0,
    retained: bool = false,

    fn record(self: *@This(), event: Event) !void {
        self.events[self.count] = event;
        self.count += 1;
        if (event == .validate_profile) {
            self.validation_count += 1;
            if (self.fail_event == event and self.validation_count == self.fail_validation) return error.InjectedFailure;
        } else if (self.fail_event == event) return error.InjectedFailure;
    }

    pub fn startDeadline(self: *@This(), budget_ns: i128, deadline: *product.Deadline) !void {
        if (budget_ns <= 0 or !deadline.isPristineForComposition()) return error.InvalidBudget;
        try self.record(.start_deadline);
        deadline.* = .{ .owner = deadline, .started_ns = 1, .expires_ns = budget_ns + 1 };
    }
    pub fn validatePreflight(self: *@This(), transaction: *product.Transaction, deadline: *product.Deadline) !void {
        if (!transaction.isPristineForComposition() or deadline.owner != deadline) return error.InvalidOwner;
        try self.record(.preflight);
    }
    pub fn validateProfile(self: *@This(), _: *product.Deadline) !void {
        try self.record(.validate_profile);
    }
    pub fn authorManifest(self: *@This(), _: *product.Deadline) !void {
        try self.record(.author_manifest);
    }
    pub fn promoteDurable(self: *@This(), _: *product.Deadline) !void {
        try self.record(.promote_durable);
    }
    pub fn fenceDurable(self: *@This(), _: *product.Deadline) !void {
        try self.record(.fence_durable);
    }
    pub fn closeRetaining(self: *@This(), _: *product.Deadline) !void {
        try self.record(.close_retaining);
        self.retained = true;
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.retained;
    }
    pub fn cleanupDurable(self: *@This()) !void {
        try self.record(.cleanup_durable);
        if (self.cleanup_fail_event == .cleanup_durable) return error.InjectedCleanupFailure;
        self.retained = false;
    }
    pub fn cleanupManifest(self: *@This()) !void {
        try self.record(.cleanup_manifest);
        if (self.cleanup_fail_event == .cleanup_manifest) return error.InjectedCleanupFailure;
    }
    pub fn manifestStillLive(self: *@This()) bool {
        return self.cleanup_fail_event == .cleanup_manifest;
    }
    pub fn cleanupDeadline(self: *@This(), deadline: *product.Deadline) !void {
        try self.record(.cleanup_deadline);
        if (self.cleanup_fail_event == .cleanup_deadline) return error.InjectedCleanupFailure;
        deadline.* = .{};
    }
    pub fn deadlineStillLive(self: *@This(), _: *product.Deadline) bool {
        return self.cleanup_fail_event == .cleanup_deadline;
    }
};

test "upgrade stage3 consumes a profile owner once and retains one durable preparation" {
    var fake = Fake{};
    var execution: product.Execution = .{};
    try product.runWith(&fake, 100, &execution);
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(fake.retained);
    try std.testing.expectEqualSlices(Event, &.{
        .start_deadline,
        .preflight,
        .validate_profile,
        .author_manifest,
        .validate_profile,
        .promote_durable,
        .validate_profile,
        .fence_durable,
        .validate_profile,
        .close_retaining,
        .validate_profile,
        .cleanup_manifest,
        .cleanup_deadline,
    }, fake.events[0..fake.count]);
}

test "pre-retention failure preserves the borrowed profile and exposes exact audit stage" {
    var fake = Fake{ .fail_event = .promote_durable };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
    try std.testing.expectEqual(product.Stage.promote, execution.auditStage());
    try std.testing.expect(!execution.retainedCommit());
    try std.testing.expectEqual(@as(usize, 0), count(fake.events[0..fake.count], .cleanup_durable));
}

test "every mutating stage failure requires audit at the exact stage" {
    const cases = [_]struct { event: Event, stage: product.Stage }{
        .{ .event = .author_manifest, .stage = .manifest },
        .{ .event = .promote_durable, .stage = .promote },
        .{ .event = .fence_durable, .stage = .fence },
        .{ .event = .close_retaining, .stage = .retained_close },
    };
    inline for (cases) |case| {
        var fake = Fake{ .fail_event = case.event };
        var execution: product.Execution = .{};
        try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
        try std.testing.expectEqual(case.stage, execution.auditStage());
    }
    const validation_stages = [_]product.Stage{ .manifest, .promote, .fence, .retained_close };
    inline for (validation_stages, 2..) |stage, validation_index| {
        var fake = Fake{ .fail_event = .validate_profile, .fail_validation = validation_index };
        var execution: product.Execution = .{};
        try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
        try std.testing.expectEqual(stage, execution.auditStage());
    }
}

test "preflight and initial profile failures unwind without publishing an owner" {
    inline for (.{ Event.preflight, Event.validate_profile }) |event| {
        var fake = Fake{ .fail_event = event, .fail_validation = 1 };
        var execution: product.Execution = .{};
        try std.testing.expectError(error.InjectedFailure, product.runWith(&fake, 100, &execution));
        try std.testing.expect(execution.isPristineForComposition());
        try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_deadline));
    }
}

test "failed initial cleanup remains retryable and never becomes an audit result" {
    var fake = Fake{ .fail_event = .validate_profile, .fail_validation = 1, .cleanup_fail_event = .cleanup_deadline };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.CleanupFailed, product.runWith(&fake, 100, &execution));
    try std.testing.expect(execution.transaction.needsCleanup());
    try std.testing.expectEqual(product.Stage.none, execution.auditStage());
    fake.cleanup_fail_event = null;
    try product.retryCleanupWith(&fake, &execution);
    try std.testing.expect(execution.transaction.isPristineForComposition());
}

test "post-retention failure keeps the durable commit and retry cleans only local owners" {
    var fake = Fake{ .fail_event = .validate_profile, .fail_validation = 5 };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
    try std.testing.expect(execution.retainedCommit());
    try std.testing.expectEqual(product.Stage.retained_close, execution.auditStage());
    fake.fail_event = null;
    try product.retryAuditCleanupWith(&fake, &execution);
    try std.testing.expect(execution.localCleanupComplete());
    try std.testing.expectEqual(@as(usize, 0), count(fake.events[0..fake.count], .cleanup_durable));
    try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_manifest));
    try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_deadline));
}

test "best-effort local cleanup continues after manifest failure and retry closes only residue" {
    var fake = Fake{ .cleanup_fail_event = .cleanup_manifest };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
    try std.testing.expectEqual(product.Stage.local_cleanup, execution.auditStage());
    try std.testing.expect(execution.retainedCommit());
    try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_deadline));
    try std.testing.expect(!execution.transaction.deadline_live);
    try std.testing.expect(execution.transaction.manifest_live);
    fake.cleanup_fail_event = null;
    try product.retryAuditCleanupWith(&fake, &execution);
    try std.testing.expect(execution.localCleanupComplete());
    try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_deadline));
}

test "product surface does not accept caller profile predecessor timing or success scalars" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_profile_stage3_preparation_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    const start = std.mem.indexOf(u8, source, "pub const Inputs = struct") orelse return error.ContractMissing;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, "\n};") orelse return error.ContractMissing;
    const inputs = tail[0 .. end + 3];
    inline for (.{ "\n    predecessor:", "\n    timing:", "\n    success:", "\n    evidence:" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, inputs, forbidden) == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "&value.upgrade.deadline"));
    try std.testing.expect(std.mem.indexOf(u8, source, "value.upgrade.predecessor.revalidate(") != null);
}

test "production run keeps borrowed inputs in its stack-owned adapter until ownership starts" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_profile_stage3_preparation_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    const execution_start = std.mem.indexOf(u8, source, "pub const Execution = struct") orelse return error.ContractMissing;
    const execution_tail = source[execution_start..];
    const execution_end = std.mem.indexOf(u8, execution_tail, "\n};\n\npub fn run") orelse return error.ContractMissing;
    const execution = execution_tail[0..execution_end];
    try std.testing.expect(std.mem.indexOf(u8, execution, "inputs: ?Inputs") == null);
    try std.testing.expect(std.mem.indexOf(u8, execution, "allocator: std.mem.Allocator") == null);

    const run_start = std.mem.indexOf(u8, source, "pub fn run(") orelse return error.ContractMissing;
    const run_tail = source[run_start..];
    const run_end = std.mem.indexOf(u8, run_tail, "\n}\n\npub fn runWith") orelse return error.ContractMissing;
    const run_body = run_tail[0..run_end];
    try std.testing.expect(std.mem.indexOf(u8, run_body, "execution.owner =") == null);
    try std.testing.expect(std.mem.indexOf(u8, run_body, ".inputs = inputs") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "runOwned(&steps") != null);
}

test "profile stage3 composition records actual APFS preparation samples without FD or staging leaks" {
    const samples: usize = if (builtin.mode == .ReleaseFast) 40 else 1;
    var elapsed: [40]u64 = undefined;
    const fd_before = try openFdCount();
    for (0..samples) |index| {
        var fixture: FilesystemFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var execution: product.Execution = .{};
        var steps = FilesystemSteps{ .fixture = &fixture, .execution = &execution };
        const started = monotonicNs();
        try product.runWith(&steps, 30 * std.time.ns_per_s, &execution);
        elapsed[index] = monotonicNs() - started;
        _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/upgrade-evidence.json", .{});
        _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/Maru-1.2.3-session-host-release.json", .{});
        try expectNoStaging(&fixture);
    }
    const fd_after = try openFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, elapsed[0..samples], {}, std.sort.asc(u64));
    std.debug.print("profile_stage3_preparation_apfs mode={s} samples={d} failures=0 fd_delta=0 median_ns={d} p95_ns={d} max_ns={d} retained_finals={d} staging_residue=0\n", .{
        @tagName(builtin.mode), samples, elapsed[samples / 2], elapsed[(samples * 95 - 1) / 100], elapsed[samples - 1], samples,
    });
}

fn count(events: []const Event, expected: Event) usize {
    var result: usize = 0;
    for (events) |event| if (event == expected) {
        result += 1;
    };
    return result;
}

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const requirement_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
const predecessor_manifest_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const predecessor_dmg_sha = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const predecessor_exe_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

fn common() evidence.Common {
    return .{ .test_uuid = uuid, .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 }, .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = exe_sha } };
}

fn upgradeLeaf(comptime runtime_count: u64) []const u8 {
    return std.fmt.comptimePrint("{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, predecessor_exe_sha, exe_sha, requirement_sha, runtime_count, if (runtime_count == 1) requirement_sha else predecessor_manifest_sha });
}

const FilesystemFixture = struct {
    tmp: std.testing.TmpDir,
    evidence_owner: files.PinnedReleaseFile = .{},
    evidence_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    durable_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_bytes: []u8 = &.{},

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDir(std.testing.io, "evidence", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "manifest", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "durable", .default_dir);
        const predecessor: evidence.Predecessor = .{ .release_id = 400, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = predecessor_manifest_sha, .dmg_sha256 = predecessor_dmg_sha, .executable_sha256 = predecessor_exe_sha };
        const evidence_bytes = try evidence.assembleUpgrade(std.testing.allocator, common(), predecessor, upgradeLeaf(1), upgradeLeaf(evidence.near_max_runtime_count));
        defer std.testing.allocator.free(evidence_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence/upgrade-evidence.json", .data = evidence_bytes });
        _ = try absolute(&self.tmp, "evidence", &self.evidence_root);
        _ = try absolute(&self.tmp, "manifest", &self.manifest_root);
        const evidence_path = try absolute(&self.tmp, "evidence/upgrade-evidence.json", &self.evidence_path);
        _ = try absolute(&self.tmp, "manifest/Maru-1.2.3-session-host-release.json", &self.manifest_path);
        _ = try absolute(&self.tmp, "durable/prepared", &self.durable_path);
        try files.pinReleaseFileObserved(&self.evidence_owner, evidence_path, false, evidence.max_evidence_bytes);
        const observed = self.evidence_owner.value().?;
        const assets = [_]manifest.Asset{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 100 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = exe_sha, .size = 200 },
            .{ .role = .evidence_summary, .name = handoff.upgrade_evidence_name, .sha256 = &observed.sha256, .size = observed.size },
        };
        self.manifest_bytes = try manifest.writeCanonical(std.testing.allocator, .{
            .schema = manifest.schema,
            .role = .b,
            .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = common().source.commit, .tree = common().source.tree },
            .build = .{ .workflow_ref = common().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.example.maru", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = handoff.upgrade_evidence_name, .summary_sha256 = &observed.sha256, .result = "passed" },
            .predecessor = .{ .release_id = 400, .tag = "v1.2.2", .commit = predecessor.commit, .manifest_sha256 = predecessor_manifest_sha },
        });
    }

    fn deinit(self: *@This()) void {
        if (self.evidence_owner.value() != null) self.evidence_owner.deinit() catch {};
        if (self.manifest_bytes.len != 0) std.testing.allocator.free(self.manifest_bytes);
        self.tmp.cleanup();
    }
};

const FilesystemSteps = struct {
    fixture: *FilesystemFixture,
    execution: *product.Execution,

    pub fn startDeadline(_: *@This(), budget_ns: i128, deadline: *product.Deadline) !void {
        deadline.* = .{ .owner = deadline, .started_ns = 1, .expires_ns = budget_ns + 1 };
    }
    pub fn validatePreflight(_: *@This(), transaction: *product.Transaction, deadline: *product.Deadline) !void {
        if (!transaction.isPristineForComposition() or deadline.owner != deadline) return error.InvalidOwner;
    }
    pub fn validateProfile(self: *@This(), _: *product.Deadline) !void {
        _ = try self.fixture.evidence_owner.revalidate(std.mem.sliceTo(&self.fixture.evidence_path, 0));
        if (self.execution.manifest.value() != null) _ = try self.execution.manifest.revalidate(std.mem.sliceTo(&self.fixture.manifest_path, 0));
        if (self.execution.durable.phase == .open) _ = try self.execution.durable.revalidate();
    }
    pub fn authorManifest(self: *@This(), _: *product.Deadline) !void {
        try self.fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest/Maru-1.2.3-session-host-release.json", .data = self.fixture.manifest_bytes });
        try files.pinReleaseFileObserved(&self.execution.manifest, std.mem.sliceTo(&self.fixture.manifest_path, 0), false, manifest.max_manifest_bytes);
    }
    pub fn promoteDurable(self: *@This(), _: *product.Deadline) !void {
        try handoff.promote(std.testing.allocator, .{
            .evidence = .{ .file = &self.fixture.evidence_owner, .root = std.mem.sliceTo(&self.fixture.evidence_root, 0), .path = std.mem.sliceTo(&self.fixture.evidence_path, 0) },
            .manifest = .{ .file = &self.execution.manifest, .root = std.mem.sliceTo(&self.fixture.manifest_root, 0), .path = std.mem.sliceTo(&self.fixture.manifest_path, 0) },
        }, std.mem.sliceTo(&self.fixture.durable_path, 0), &self.execution.durable);
    }
    pub fn fenceDurable(self: *@This(), _: *product.Deadline) !void {
        _ = try self.execution.durable.revalidate();
    }
    pub fn closeRetaining(self: *@This(), _: *product.Deadline) !void {
        try self.execution.durable.closeRetaining();
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.execution.durable.phase == .retained_closed;
    }
    pub fn cleanupDurable(self: *@This()) !void {
        try self.execution.durable.cleanup();
    }
    pub fn cleanupManifest(self: *@This()) !void {
        try self.execution.manifest.deinit();
    }
    pub fn manifestStillLive(self: *@This()) bool {
        return self.execution.manifest.value() != null;
    }
    pub fn cleanupDeadline(_: *@This(), deadline: *product.Deadline) !void {
        deadline.* = .{};
    }
    pub fn deadlineStillLive(_: *@This(), deadline: *product.Deadline) bool {
        return !deadline.isPristineForComposition();
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], suffix });
}

fn expectNoStaging(fixture: *FilesystemFixture) !void {
    var dir = try fixture.tmp.dir.openDir(std.testing.io, "durable", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".maru-preparation-"));
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var result: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| result += 1;
    return result;
}

fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
