//! Stage-3 evidence and manifest cross a process boundary as one atomic directory.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const evidence = @import("release_evidence");
const manifest = @import("release_manifest");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
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

const Fixture = struct {
    tmp: std.testing.TmpDir,
    evidence_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    owners: [handoff.role_count]files.PinnedReleaseFile = @splat(.{}),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDir(std.testing.io, "evidence-root", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "manifest-root", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "durable", .default_dir);
        const evidence_bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
        defer std.testing.allocator.free(evidence_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence-root/baseline-evidence.json", .data = evidence_bytes });
        _ = try absolute(&self.tmp, "evidence-root", &self.evidence_root);
        _ = try absolute(&self.tmp, "manifest-root", &self.manifest_root);
        _ = try absolute(&self.tmp, "durable/prepared", &self.destination);
        const evidence_path = try absolute(&self.tmp, "evidence-root/baseline-evidence.json", &self.evidence_path);
        const manifest_path = try absolute(&self.tmp, "manifest-root/Maru-1.2.3-session-host-release.json", &self.manifest_path);
        try files.pinReleaseFileObserved(&self.owners[0], evidence_path, false, evidence.max_evidence_bytes);
        const observed = self.owners[0].value().?;
        const assets = [_]manifest.Asset{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = dmg_sha, .size = 100 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = exe_sha, .size = 200 },
            .{ .role = .evidence_summary, .name = handoff.evidence_name, .sha256 = &observed.sha256, .size = observed.size },
        };
        const bytes = try manifest.writeCanonical(std.testing.allocator, .{
            .schema = manifest.schema,
            .role = .a,
            .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
            .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
            .source = .{ .commit = common().source.commit, .tree = common().source.tree },
            .build = .{ .workflow_ref = common().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.example.maru", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = handoff.evidence_name, .summary_sha256 = &observed.sha256, .result = "passed" },
        });
        defer std.testing.allocator.free(bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest-root/Maru-1.2.3-session-host-release.json", .data = bytes });
        try files.pinReleaseFileObserved(&self.owners[1], manifest_path, false, manifest.max_manifest_bytes);
    }

    fn deinit(self: *@This()) void {
        for (&self.owners) |*owner| if (owner.value() != null) owner.deinit() catch {};
        self.tmp.cleanup();
    }

    fn sources(self: *@This()) handoff.Sources {
        return .{
            .evidence = .{ .file = &self.owners[0], .root = self.evidenceRoot(), .path = self.evidencePath() },
            .manifest = .{ .file = &self.owners[1], .root = self.manifestRoot(), .path = self.manifestPath() },
        };
    }

    fn evidenceRoot(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.evidence_root, 0);
    }
    fn manifestRoot(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.manifest_root, 0);
    }
    fn destinationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.destination, 0);
    }
    fn evidencePath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.evidence_path, 0);
    }
    fn manifestPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.manifest_path, 0);
    }
    fn closeSources(self: *@This()) !void {
        for (&self.owners) |*owner| try owner.deinit();
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], suffix });
}

test "preparation promotion is atomic semantically bound and survives source removal" {
    comptime _ = handoff.promote;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurablePreparation = .{};
    try handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable);
    var copied = durable;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.cleanup());
    const value = try durable.revalidate();
    try std.testing.expectEqualStrings(handoff.evidence_name, std.fs.path.basename(value.entries[0].path));
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", std.fs.path.basename(value.entries[1].path));
    try fixture.closeSources();
    try fixture.tmp.dir.deleteTree(std.testing.io, "evidence-root");
    try fixture.tmp.dir.deleteTree(std.testing.io, "manifest-root");
    _ = try durable.revalidate();
    try durable.cleanup();
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/prepared", .{}));
}

test "retained close preserves both leaves and revokes old authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurablePreparation = .{};
    try handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable);
    try durable.closeRetaining();
    try std.testing.expectEqual(handoff.Phase.retained_closed, durable.phase);
    try std.testing.expect(durable.value() == null);
    try std.testing.expectError(error.InvalidOwner, durable.revalidate());
    try std.testing.expectError(error.InvalidOwner, durable.cleanup());
    try std.testing.expectError(error.InvalidOwner, durable.closeRetaining());
    _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/baseline-evidence.json", .{});
    _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/Maru-1.2.3-session-host-release.json", .{});
}

test "owners roots identities and destination fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurablePreparation = .{};
    var sources = fixture.sources();
    var copied_owner = fixture.owners[1];
    sources.manifest.file = &copied_owner;
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable));
    sources = fixture.sources();
    sources.manifest = sources.evidence;
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable));
    sources = fixture.sources();
    sources.evidence.root = fixture.manifestRoot();
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable));
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, fixture.sources(), "relative", &durable));
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, fixture.sources(), fixture.evidenceRoot(), &durable));
    try fixture.tmp.dir.createDir(std.testing.io, "durable/prepared", .default_dir);
    try std.testing.expectError(error.DestinationExists, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));

    fixture.deinit();
    try fixture.init();
    try fixture.owners[0].deinit();
    const oversized_fd = c.open(fixture.evidencePath().ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(c.mode_t, 0));
    if (oversized_fd < 0) return error.FixtureFailed;
    if (c.ftruncate(oversized_fd, @intCast(evidence.max_evidence_bytes + 1)) != 0) {
        _ = c.close(oversized_fd);
        return error.FixtureFailed;
    }
    if (c.close(oversized_fd) != 0) return error.FixtureFailed;
    try files.pinReleaseFileObserved(&fixture.owners[0], fixture.evidencePath(), false, evidence.max_evidence_bytes + 1);
    try std.testing.expectError(error.TooLarge, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
}

test "malformed or cross-release source publishes nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try replaceHeld(&fixture.owners[1], fixture.manifestPath(), "{}\n", manifest.max_manifest_bytes);
    var durable: handoff.DurablePreparation = .{};
    try std.testing.expectError(error.InvalidJson, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
    try expectNoPublicationResidue(&fixture);

    fixture.deinit();
    try fixture.init();
    try mutateManifestRelease(&fixture);
    try std.testing.expectError(error.InvalidBinding, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
    try expectNoPublicationResidue(&fixture);

    fixture.deinit();
    try fixture.init();
    try mutateManifestCandidateDigest(&fixture);
    try std.testing.expectError(error.InvalidBinding, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
    try expectNoPublicationResidue(&fixture);
}

test "source drift leaves no final or staging directory" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.rename("manifest-root/Maru-1.2.3-session-host-release.json", fixture.tmp.dir, "manifest-root/old.json", std.testing.io);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest-root/Maru-1.2.3-session-host-release.json", .data = "{}\n" });
    var durable: handoff.DurablePreparation = .{};
    try std.testing.expectError(error.SourceChanged, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
    try expectNoPublicationResidue(&fixture);
}

test "publication checkpoints never expose a partial final directory" {
    inline for (std.meta.tags(handoff.TestCheckpoint)) |checkpoint| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var durable: handoff.DurablePreparation = .{};
        try std.testing.expectError(error.InjectedFailure, handoff.promoteFailingForTest(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable, checkpoint));
        if (durable.value() != null or durable.phase == .cleanup_required) {
            if (durable.phase == .open) _ = try durable.revalidate();
            try durable.cleanup();
        } else try expectNoPublicationResidue(&fixture);
    }
}

test "cleanup preserves replacements and retries partial unlink" {
    {
        var extra: Fixture = undefined;
        try extra.init();
        defer extra.deinit();
        var extra_durable: handoff.DurablePreparation = .{};
        try handoff.promote(std.testing.allocator, extra.sources(), extra.destinationPath(), &extra_durable);
        try extra.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/prepared/foreign", .data = "foreign" });
        try std.testing.expectError(error.FileChanged, extra_durable.revalidate());
        try std.testing.expectError(error.CleanupFailed, extra_durable.cleanup());
        const extra_foreign = try extra.tmp.dir.readFileAlloc(std.testing.io, "durable/prepared/foreign", std.testing.allocator, .limited(16));
        defer std.testing.allocator.free(extra_foreign);
        try std.testing.expectEqualStrings("foreign", extra_foreign);
    }

    var replacement: Fixture = undefined;
    try replacement.init();
    defer replacement.deinit();
    var durable: handoff.DurablePreparation = .{};
    try handoff.promote(std.testing.allocator, replacement.sources(), replacement.destinationPath(), &durable);
    try replacement.tmp.dir.rename("durable/prepared", replacement.tmp.dir, "durable/held", std.testing.io);
    try replacement.tmp.dir.createDir(std.testing.io, "durable/prepared", .default_dir);
    try replacement.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/prepared/foreign", .data = "foreign" });
    try std.testing.expectError(error.CleanupFailed, durable.cleanup());
    const foreign = try replacement.tmp.dir.readFileAlloc(std.testing.io, "durable/prepared/foreign", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);

    for (0..handoff.role_count + 1) |fail_after| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var partial: handoff.DurablePreparation = .{};
        try handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &partial);
        try std.testing.expectError(error.InjectedFailure, partial.cleanupFailingForTest(fail_after));
        try std.testing.expectEqual(handoff.Phase.cleanup_required, partial.phase);
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/prepared", .{}));
        try partial.cleanup();
        try expectNoStaging(&fixture);
    }

    var tomb: Fixture = undefined;
    try tomb.init();
    defer tomb.deinit();
    var partial: handoff.DurablePreparation = .{};
    try handoff.promote(std.testing.allocator, tomb.sources(), tomb.destinationPath(), &partial);
    try std.testing.expectError(error.InjectedFailure, partial.cleanupFailingForTest(0));
    try tomb.tmp.dir.createDir(std.testing.io, "durable/foreign-empty", .default_dir);
    @memset(&partial.directory_leaf, 0);
    @memcpy(partial.directory_leaf[0.."foreign-empty".len], "foreign-empty");
    partial.directory_leaf_len = "foreign-empty".len;
    try std.testing.expectError(error.CleanupFailed, partial.cleanup());
    _ = try tomb.tmp.dir.statFile(std.testing.io, "durable/foreign-empty", .{});
}

test "allocation failure cannot publish a partial preparation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPromotion, .{});
}

test "APFS preparation handoff records forty isolated samples without FD or staging leaks" {
    const sample_count = 40;
    var promote_ns: [sample_count]u64 = undefined;
    var revalidate_ns: [sample_count]u64 = undefined;
    var close_ns: [sample_count]u64 = undefined;
    const fd_before = try openFdCount();
    var failures: usize = 0;
    var retained_finals: usize = 0;
    for (0..sample_count) |index| {
        var fixture: Fixture = undefined;
        fixture.init() catch {
            failures += 1;
            continue;
        };
        defer fixture.deinit();
        var durable: handoff.DurablePreparation = .{};
        var started = monotonicNs();
        handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable) catch {
            failures += 1;
            continue;
        };
        promote_ns[index] = monotonicNs() - started;
        fixture.closeSources() catch {
            failures += 1;
            continue;
        };
        fixture.tmp.dir.deleteTree(std.testing.io, "evidence-root") catch {
            failures += 1;
            continue;
        };
        fixture.tmp.dir.deleteTree(std.testing.io, "manifest-root") catch {
            failures += 1;
            continue;
        };
        started = monotonicNs();
        _ = durable.revalidate() catch {
            failures += 1;
            continue;
        };
        revalidate_ns[index] = monotonicNs() - started;
        started = monotonicNs();
        durable.closeRetaining() catch {
            failures += 1;
            continue;
        };
        close_ns[index] = monotonicNs() - started;
        _ = fixture.tmp.dir.statFile(std.testing.io, "durable/prepared", .{}) catch {
            failures += 1;
            continue;
        };
        retained_finals += 1;
        expectNoStaging(&fixture) catch {
            failures += 1;
            continue;
        };
    }
    const fd_after = try openFdCount();
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(@as(usize, sample_count), retained_finals);
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, &promote_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, &revalidate_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, &close_ns, {}, std.sort.asc(u64));
    std.debug.print("preparation_handoff_apfs mode={s} samples=40 failures=0 fd_delta=0 promote_median_ns={d} promote_p95_ns={d} promote_max_ns={d} revalidate_median_ns={d} revalidate_p95_ns={d} revalidate_max_ns={d} close_median_ns={d} close_p95_ns={d} close_max_ns={d} retained_finals=40 staging_residue=0\n", .{ @tagName(builtin.mode), promote_ns[20], promote_ns[37], promote_ns[39], revalidate_ns[20], revalidate_ns[37], revalidate_ns[39], close_ns[20], close_ns[37], close_ns[39] });
}

test "preparation handoff is credential-free with one stage3 product caller" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_preparation_handoff.zig", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "stat.uid == c.geteuid()") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, source, "validOwnedDirectory("));
    inline for (.{ "GH_TOKEN", "release_adapter_github", "release_adapter_apple", "std.process", "std.posix.getenv" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
    var src = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer src.close(std.testing.io);
    var walker = try posixWalk(src, std.testing.allocator);
    defer walker.deinit();
    var unexpected_callers: usize = 0;
    var stage3_product_seen = false;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // The next-process adapter is the sole internal consumer and has its own whole-src
        // product-dormancy sentinel. It is not a product caller of the handoff operation.
        if (std.mem.eql(u8, entry.path, "platform/macos/session_host/release_adapter_candidate_preparation_reopen.zig")) continue;
        const product = try src.readFileAlloc(std.testing.io, entry.path, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(product);
        const callers = std.mem.count(u8, product, "release_adapter_candidate_preparation_handoff");
        if (std.mem.eql(u8, entry.path, "platform/macos/session_host/release_adapter_candidate_stage3_preparation_product.zig")) {
            try std.testing.expectEqual(@as(usize, 1), callers);
            stage3_product_seen = true;
        } else unexpected_callers += callers;
    }
    try std.testing.expect(stage3_product_seen);
    try std.testing.expectEqual(@as(usize, 0), unexpected_callers);
}

fn replaceHeld(owner: *files.PinnedReleaseFile, path: [:0]const u8, bytes: []const u8, cap: usize) !void {
    try owner.deinit();
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    if (c.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.FixtureFailed;
    try files.pinReleaseFileObserved(owner, path, false, cap);
}

fn mutateManifestRelease(fixture: *Fixture) !void {
    try fixture.owners[1].deinit();
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "manifest-root/Maru-1.2.3-session-host-release.json", std.testing.allocator, .limited(manifest.max_manifest_bytes));
    defer std.testing.allocator.free(bytes);
    const marker = "\"release\":{\"id\":456";
    const offset = std.mem.indexOf(u8, bytes, marker) orelse return error.FixtureFailed;
    const fd = c.open(fixture.manifestPath().ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const changed = [_]u8{'7'};
    if (c.pwrite(fd, &changed, changed.len, @intCast(offset + marker.len - 1)) != changed.len) return error.FixtureFailed;
    try files.pinReleaseFileObserved(&fixture.owners[1], fixture.manifestPath(), false, manifest.max_manifest_bytes);
}

fn mutateManifestCandidateDigest(fixture: *Fixture) !void {
    try fixture.owners[1].deinit();
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "manifest-root/Maru-1.2.3-session-host-release.json", std.testing.allocator, .limited(manifest.max_manifest_bytes));
    defer std.testing.allocator.free(bytes);
    const marker = "\"sha256\":\"aaaaaaaa";
    const offset = std.mem.indexOf(u8, bytes, marker) orelse return error.FixtureFailed;
    const fd = c.open(fixture.manifestPath().ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const changed = [_]u8{'c'};
    if (c.pwrite(fd, &changed, changed.len, @intCast(offset + marker.len - 1)) != changed.len) return error.FixtureFailed;
    try files.pinReleaseFileObserved(&fixture.owners[1], fixture.manifestPath(), false, manifest.max_manifest_bytes);
}

fn allocationPromotion(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurablePreparation = .{};
    handoff.promote(allocator, fixture.sources(), fixture.destinationPath(), &durable) catch |err| {
        if (durable.value() != null) durable.cleanup() catch {} else try expectNoPublicationResidue(&fixture);
        return err;
    };
    try durable.cleanup();
}

fn expectNoPublicationResidue(fixture: *Fixture) !void {
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/prepared", .{}));
    try expectNoStaging(fixture);
}

fn expectNoStaging(fixture: *Fixture) !void {
    var dir = try fixture.tmp.dir.openDir(std.testing.io, "durable", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".maru-preparation-"));
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
