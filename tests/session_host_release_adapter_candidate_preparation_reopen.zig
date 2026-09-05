//! A fresh owner semantically reopens retained stage-3 preparation bytes.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const evidence = @import("release_evidence");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_preparation_handoff");
const reopen = @import("release_adapter_candidate_preparation_reopen");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const exe_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const requirement_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

fn trustedContext() context_mod.Context {
    return .{
        .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "1111111111111111111111111111111111111111",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn common() evidence.Common {
    return .{ .test_uuid = uuid, .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" }, .build = .{ .workflow_ref = trustedContext().build.workflow_ref, .run_id = 789, .run_attempt = 2 }, .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = exe_sha } };
}

fn defaultLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
}

fn quitLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ exe_sha ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    roots: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    source_paths: [2][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    owners: [2]files.PinnedReleaseFile = @splat(.{}),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        for ([_][]const u8{ "evidence", "manifest", "durable" }) |name| try self.tmp.dir.createDir(std.testing.io, name, .default_dir);
        const evidence_bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
        defer std.testing.allocator.free(evidence_bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence/baseline-evidence.json", .data = evidence_bytes });
        _ = try absolute(&self.tmp, "evidence", &self.roots[0]);
        _ = try absolute(&self.tmp, "manifest", &self.roots[1]);
        const evidence_path = try absolute(&self.tmp, "evidence/baseline-evidence.json", &self.source_paths[0]);
        const manifest_path = try absolute(&self.tmp, "manifest/Maru-1.2.3-session-host-release.json", &self.source_paths[1]);
        _ = try absolute(&self.tmp, "durable/prepared", &self.destination);
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
            .build = .{ .workflow_ref = trustedContext().build.workflow_ref, .run_id = 789, .run_attempt = 2 },
            .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
            .signing = .{ .bundle_id = "com.example.maru", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "ABCDE12345", .designated_requirement_sha256 = requirement_sha, .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
            .assets = &assets,
            .evidence = .{ .test_uuid = uuid, .summary_name = handoff.evidence_name, .summary_sha256 = &observed.sha256, .result = "passed" },
        });
        defer std.testing.allocator.free(bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest/Maru-1.2.3-session-host-release.json", .data = bytes });
        try files.pinReleaseFileObserved(&self.owners[1], manifest_path, false, manifest.max_manifest_bytes);
    }

    fn deinit(self: *@This()) void {
        for (&self.owners) |*owner| if (owner.value() != null) owner.deinit() catch {};
        self.tmp.cleanup();
    }

    fn prepare(self: *@This()) !void {
        var owner: handoff.DurablePreparation = .{};
        try handoff.promote(std.testing.allocator, .{
            .evidence = .{ .file = &self.owners[0], .root = self.root(0), .path = self.sourcePath(0) },
            .manifest = .{ .file = &self.owners[1], .root = self.root(1), .path = self.sourcePath(1) },
        }, self.destinationPath(), &owner);
        try owner.closeRetaining();
        for (&self.owners) |*source| try source.deinit();
        try self.tmp.dir.deleteTree(std.testing.io, "evidence");
        try self.tmp.dir.deleteTree(std.testing.io, "manifest");
    }

    fn root(self: *@This(), index: usize) [:0]const u8 {
        return std.mem.sliceTo(&self.roots[index], 0);
    }
    fn sourcePath(self: *@This(), index: usize) [:0]const u8 {
        return std.mem.sliceTo(&self.source_paths[index], 0);
    }
    fn destinationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.destination, 0);
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], suffix });
}

test "retained preparation reopens in a fresh final-address owner" {
    comptime _ = reopen.open;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var result: reopen.ReopenedPreparation = .{};
    try reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.close(std.testing.allocator));
    const view = result.value().?;
    try std.testing.expectEqualStrings(handoff.evidence_name, std.fs.path.basename(view.entries[0].path));
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", std.fs.path.basename(view.entries[1].path));
    result.context.run_attempt += 1;
    try std.testing.expect(result.value() == null);
    result.context.run_attempt -= 1;
    _ = try result.fence(std.testing.allocator);
    try result.close(std.testing.allocator);
    try std.testing.expect(result.value() == null);
    _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/baseline-evidence.json", .{});
}

test "trusted context mismatch and unprotected input fail before publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var result: reopen.ReopenedPreparation = .{};
    var wrong = trustedContext();
    wrong.build.run_attempt = 3;
    try std.testing.expectError(error.ManifestMismatch, reopen.open(std.testing.allocator, wrong, fixture.destinationPath(), &result));
    wrong = trustedContext();
    wrong.protected_tag = false;
    try std.testing.expectError(error.UntrustedContext, reopen.open(std.testing.allocator, wrong, fixture.destinationPath(), &result));
    const manifest_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/Maru-1.2.3-session-host-release.json", .{fixture.destinationPath()}, 0);
    defer std.testing.allocator.free(manifest_path);
    const fd = c.open(manifest_path.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "durable/prepared/Maru-1.2.3-session-host-release.json", std.testing.allocator, .limited(manifest.max_manifest_bytes));
    defer std.testing.allocator.free(bytes);
    const marker = "\"run_attempt\":2";
    const offset = std.mem.indexOf(u8, bytes, marker) orelse return error.FixtureFailed;
    if (c.pwrite(fd, "3", 1, @intCast(offset + marker.len - 1)) != 1) return error.FixtureFailed;
    try std.testing.expectError(error.InvalidBinding, reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result));
    try std.testing.expect(result.value() == null);
}

test "inventory pathname and owner-only modes fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var result: reopen.ReopenedPreparation = .{};
    try std.testing.expectError(error.InvalidPath, reopen.open(std.testing.allocator, trustedContext(), "relative", &result));
    if (c.chmod(fixture.destinationPath().ptr, 0o755) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.InvalidMode, reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result));
    if (c.chmod(fixture.destinationPath().ptr, 0o700) != 0) return error.FixtureFailed;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/prepared/foreign", .data = "x" });
    try std.testing.expectError(error.InvalidInventory, reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result));
    try fixture.tmp.dir.deleteFile(std.testing.io, "durable/prepared/foreign");
    const evidence_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ fixture.destinationPath(), handoff.evidence_name }, 0);
    defer std.testing.allocator.free(evidence_path);
    if (c.chmod(evidence_path.ptr, 0o644) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.InvalidMode, reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result));

    fixture.deinit();
    try fixture.init();
    try fixture.prepare();
    const held_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ fixture.destinationPath(), handoff.evidence_name }, 0);
    defer std.testing.allocator.free(held_path);
    var alias_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const alias = try absolute(&fixture.tmp, "durable/evidence-alias", &alias_storage);
    if (c.link(held_path.ptr, alias.ptr) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.PathAlias, reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result));
}

test "full fence rejects byte and directory pathname replacement" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var result: reopen.ReopenedPreparation = .{};
    try reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result);
    const evidence_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ fixture.destinationPath(), handoff.evidence_name }, 0);
    defer std.testing.allocator.free(evidence_path);
    const fd = c.open(evidence_path.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.FixtureFailed;
    defer _ = c.close(fd);
    if (c.pwrite(fd, "X", 1, 0) != 1) return error.FixtureFailed;
    try std.testing.expectError(error.FileChanged, result.fence(std.testing.allocator));
    try result.deinit();

    fixture.deinit();
    try fixture.init();
    try fixture.prepare();
    result = .{};
    try reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result);
    try fixture.tmp.dir.rename("durable/prepared", fixture.tmp.dir, "durable/held", std.testing.io);
    try fixture.tmp.dir.createDir(std.testing.io, "durable/prepared", .default_dir);
    try std.testing.expectError(error.FileChanged, result.fence(std.testing.allocator));
    try result.deinit();
}

test "allocation failure cannot publish or consume retained bytes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationOpen, .{});
}

fn allocationOpen(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var result: reopen.ReopenedPreparation = .{};
    reopen.open(allocator, trustedContext(), fixture.destinationPath(), &result) catch |err| {
        try std.testing.expect(result.value() == null);
        _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/baseline-evidence.json", .{});
        return err;
    };
    try result.close(allocator);
}

test "APFS semantic reopen records forty isolated samples without FD leaks" {
    const count = 40;
    var open_ns: [count]u64 = undefined;
    var fence_ns: [count]u64 = undefined;
    var close_ns: [count]u64 = undefined;
    const fd_before = try openFdCount();
    var successes: usize = 0;
    var failures: usize = 0;
    for (0..count) |_| {
        const sample = measureSample() catch {
            failures += 1;
            continue;
        };
        open_ns[successes] = sample.open_ns;
        fence_ns[successes] = sample.fence_ns;
        close_ns[successes] = sample.close_ns;
        successes += 1;
    }
    const fd_after = try openFdCount();
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(@as(usize, count), successes);
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, open_ns[0..successes], {}, std.sort.asc(u64));
    std.mem.sort(u64, fence_ns[0..successes], {}, std.sort.asc(u64));
    std.mem.sort(u64, close_ns[0..successes], {}, std.sort.asc(u64));
    std.debug.print("preparation_reopen_apfs mode={s} samples={d} failures={d} fd_delta={d} reopen_median_ns={d} reopen_p95_ns={d} reopen_max_ns={d} fence_median_ns={d} fence_p95_ns={d} fence_max_ns={d} close_median_ns={d} close_p95_ns={d} close_max_ns={d} retained_finals={d}\n", .{ @tagName(builtin.mode), successes, failures, @as(i64, fd_after) - @as(i64, fd_before), open_ns[20], open_ns[37], open_ns[39], fence_ns[20], fence_ns[37], fence_ns[39], close_ns[20], close_ns[37], close_ns[39], successes });
}

const Sample = struct { open_ns: u64, fence_ns: u64, close_ns: u64 };

fn measureSample() !Sample {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.prepare();
    var result: reopen.ReopenedPreparation = .{};
    defer if (result.value() != null) result.deinit() catch {};
    var started = monotonicNs();
    try reopen.open(std.testing.allocator, trustedContext(), fixture.destinationPath(), &result);
    const open_ns = monotonicNs() - started;
    started = monotonicNs();
    _ = try result.fence(std.testing.allocator);
    const fence_ns = monotonicNs() - started;
    started = monotonicNs();
    try result.close(std.testing.allocator);
    const close_ns = monotonicNs() - started;
    _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/prepared/Maru-1.2.3-session-host-release.json", .{});
    return .{ .open_ns = open_ns, .fence_ns = fence_ns, .close_ns = close_ns };
}

test "semantic reopen is credential-free and product-dormant" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_preparation_reopen.zig", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "GH_TOKEN", "release_adapter_github", "release_adapter_apple", "std.process", "std.posix.getenv" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
    var src = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer src.close(std.testing.io);
    var walker = try posixWalk(src, std.testing.allocator);
    defer walker.deinit();
    var product_callers: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const product = try src.readFileAlloc(std.testing.io, entry.path, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(product);
        product_callers += std.mem.count(u8, product, "release_adapter_candidate_preparation_reopen");
    }
    try std.testing.expectEqual(@as(usize, 0), product_callers);
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
