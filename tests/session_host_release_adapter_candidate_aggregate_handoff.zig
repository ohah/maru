//! Evidence and four local attestation bundles cross validator processes atomically.

const std = @import("std");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_aggregate_handoff");

const source_names = [_][]const u8{
    "evidence.json",
    "dmg.bundle.json",
    "frozen.bundle.json",
    "evidence.bundle.json",
    "manifest.bundle.json",
};
const source_bytes = [_][]const u8{
    "{\"schema\":\"maru.session-host-release-evidence.v1\"}\n",
    "dmg attestation bundle\n",
    "frozen executable attestation bundle\n",
    "evidence attestation bundle\n",
    "manifest attestation bundle\n",
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    workspace_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    bundle_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination: [std.fs.max_path_bytes:0]u8 = @splat(0),
    paths: [handoff.role_count][std.fs.max_path_bytes:0]u8 = @splat(@splat(0)),
    owners: [handoff.role_count]files.PinnedReleaseFile = @splat(.{}),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "bundles", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "durable", .default_dir);
        for (source_names, source_bytes, 0..) |name, bytes, index| {
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const sub_path = try std.fmt.bufPrint(&relative, "{s}/{s}", .{ if (index == 0) "workspace" else "bundles", name });
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = bytes });
        }
        _ = try absolute(&self.tmp, "workspace", &self.workspace_root);
        _ = try absolute(&self.tmp, "bundles", &self.bundle_root);
        _ = try absolute(&self.tmp, "durable/handoff", &self.destination);
        for (source_names, 0..) |name, index| {
            var relative: [std.fs.max_path_bytes]u8 = undefined;
            const sub_path = try std.fmt.bufPrint(&relative, "{s}/{s}", .{ if (index == 0) "workspace" else "bundles", name });
            const path = try absolute(&self.tmp, sub_path, &self.paths[index]);
            try files.pinReleaseFileObserved(&self.owners[index], path, false, if (index == 0) evidence.max_evidence_bytes else handoff.max_attestation_bundle_bytes);
        }
    }

    fn deinit(self: *@This()) void {
        for (&self.owners) |*owner| if (owner.value() != null) owner.deinit() catch {};
        self.tmp.cleanup();
    }

    fn sources(self: *@This()) handoff.Sources {
        return .{
            .evidence = self.source(0),
            .candidate_dmg_bundle = self.source(1),
            .candidate_frozen_bundle = self.source(2),
            .evidence_bundle = self.source(3),
            .manifest_bundle = self.source(4),
        };
    }

    fn source(self: *@This(), index: usize) handoff.Source {
        return .{
            .file = &self.owners[index],
            .root = if (index == 0) self.workspaceRoot() else self.bundleRoot(),
            .path = std.mem.sliceTo(&self.paths[index], 0),
        };
    }

    fn workspaceRoot(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.workspace_root, 0);
    }
    fn bundleRoot(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.bundle_root, 0);
    }
    fn destinationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.destination, 0);
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

test "aggregate promotion is atomic and survives source removal" {
    comptime _ = handoff.promote;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const sources = fixture.sources();
    var durable: handoff.DurableAggregate = .{};
    try handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable);
    var copied = durable;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.cleanup());
    const original_name_byte = durable.names[1][0];
    durable.names[1][0] = if (original_name_byte == 'x') 'y' else 'x';
    try std.testing.expect(durable.value() == null);
    try std.testing.expectError(error.InvalidOwner, durable.cleanup());
    durable.names[1][0] = original_name_byte;
    const initial = try durable.revalidate();
    try std.testing.expectEqual(@as(usize, handoff.role_count), initial.entries.len);
    for (initial.entries, 0..) |entry, index| {
        try std.testing.expectEqualStrings(handoff.destinationName(@enumFromInt(index), source_names[0]), std.fs.path.basename(entry.path));
        try std.testing.expectEqualStrings(&sources.at(@enumFromInt(index)).file.value().?.sha256, &entry.observation.sha256);
    }
    try fixture.closeSources();
    try fixture.tmp.dir.deleteTree(std.testing.io, "workspace");
    try fixture.tmp.dir.deleteTree(std.testing.io, "bundles");
    _ = try durable.revalidate();
    try durable.cleanup();
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/handoff", .{}));
}

test "retained close preserves the complete aggregate and revokes old authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableAggregate = .{};
    try handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable);
    try durable.closeRetaining();
    try std.testing.expectEqual(handoff.Phase.retained_closed, durable.phase);
    try std.testing.expect(durable.value() == null);
    try std.testing.expectError(error.InvalidOwner, durable.revalidate());
    try std.testing.expectError(error.InvalidOwner, durable.cleanup());
    try std.testing.expectError(error.InvalidOwner, durable.closeRetaining());
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
    for (0..handoff.role_count) |index| {
        const name = handoff.destinationName(@enumFromInt(index), source_names[0]);
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&path, "durable/handoff/{s}", .{name});
        _ = try fixture.tmp.dir.statFile(std.testing.io, sub_path, .{});
    }
}

test "source owners roots identities and destination are fail closed" {
    const product_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_aggregate_handoff.zig", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(product_source);
    try std.testing.expect(std.mem.indexOf(u8, product_source, "stat.uid == c.geteuid()") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, product_source, "validOwnedDirectory("));
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableAggregate = .{};
    var sources = fixture.sources();
    var copied_owner = fixture.owners[1];
    sources.candidate_dmg_bundle.file = &copied_owner;
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable));
    sources = fixture.sources();
    sources.manifest_bundle = sources.evidence_bundle;
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable));
    sources = fixture.sources();
    sources.evidence.root = fixture.bundleRoot();
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, sources, fixture.destinationPath(), &durable));
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, fixture.sources(), "relative", &durable));
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, fixture.sources(), fixture.workspaceRoot(), &durable));
    try fixture.tmp.dir.createDir(std.testing.io, "durable/handoff", .default_dir);
    try std.testing.expectError(error.DestinationExists, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
}

test "source drift leaves no final or staging directory" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.rename("bundles/dmg.bundle.json", fixture.tmp.dir, "bundles/old.json", std.testing.io);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bundles/dmg.bundle.json", .data = source_bytes[1] });
    var durable: handoff.DurableAggregate = .{};
    try std.testing.expectError(error.SourceChanged, handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable));
    try expectNoPublicationResidue(&fixture);
}

test "publication checkpoints never expose a partial final aggregate" {
    inline for (std.meta.tags(handoff.TestCheckpoint)) |checkpoint| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var durable: handoff.DurableAggregate = .{};
        try std.testing.expectError(error.InjectedFailure, handoff.promoteFailingForTest(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable, checkpoint));
        if (durable.value() != null) {
            _ = try durable.revalidate();
            try durable.cleanup();
        } else {
            try expectNoPublicationResidue(&fixture);
        }
    }
}

test "cleanup preserves replacement directory and files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableAggregate = .{};
    try handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable);
    try fixture.tmp.dir.rename("durable/handoff", fixture.tmp.dir, "durable/held", std.testing.io);
    try fixture.tmp.dir.createDir(std.testing.io, "durable/handoff", .default_dir);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/handoff/foreign", .data = "foreign" });
    try std.testing.expectError(error.CleanupFailed, durable.cleanup());
    const foreign = try fixture.tmp.dir.readFileAlloc(std.testing.io, "durable/handoff/foreign", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);
}

test "cleanup tomb retries every partial unlink boundary without final visibility" {
    for (0..handoff.role_count + 1) |fail_after| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var durable: handoff.DurableAggregate = .{};
        try handoff.promote(std.testing.allocator, fixture.sources(), fixture.destinationPath(), &durable);
        try std.testing.expectError(error.InjectedFailure, durable.cleanupFailingForTest(fail_after));
        try std.testing.expectEqual(handoff.Phase.cleanup_required, durable.phase);
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/handoff", .{}));
        try durable.cleanup();
        try expectNoStaging(&fixture);
    }
}

fn allocationPromotion(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableAggregate = .{};
    handoff.promote(allocator, fixture.sources(), fixture.destinationPath(), &durable) catch |err| {
        if (durable.value() != null) durable.cleanup() catch {} else try expectNoPublicationResidue(&fixture);
        return err;
    };
    try durable.cleanup();
}

test "allocation failure cannot publish a partial aggregate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPromotion, .{});
}

test "APFS aggregate handoff records forty isolated samples without FD or staging leaks" {
    const sample_count = 40;
    var promote_ns: [sample_count]u64 = undefined;
    var revalidate_ns: [sample_count]u64 = undefined;
    var close_ns: [sample_count]u64 = undefined;
    const fd_before = try openFdCount();
    var failures: usize = 0;
    for (0..sample_count) |index| {
        var fixture: Fixture = undefined;
        fixture.init() catch {
            failures += 1;
            continue;
        };
        defer fixture.deinit();
        var durable: handoff.DurableAggregate = .{};
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
        fixture.tmp.dir.deleteTree(std.testing.io, "workspace") catch {
            failures += 1;
            continue;
        };
        fixture.tmp.dir.deleteTree(std.testing.io, "bundles") catch {
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
        expectNoStaging(&fixture) catch {
            failures += 1;
            continue;
        };
    }
    const fd_after = try openFdCount();
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, &promote_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, &revalidate_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, &close_ns, {}, std.sort.asc(u64));
    std.debug.print("aggregate_handoff_apfs samples=40 failures=0 fd_delta=0 promote_median_ns={d} promote_p95_ns={d} promote_max_ns={d} revalidate_median_ns={d} revalidate_p95_ns={d} revalidate_max_ns={d} close_median_ns={d} close_p95_ns={d} close_max_ns={d} staging_residue=0\n", .{
        promote_ns[20], promote_ns[37], promote_ns[39], revalidate_ns[20], revalidate_ns[37], revalidate_ns[39], close_ns[20], close_ns[37], close_ns[39],
    });
}

fn expectNoPublicationResidue(fixture: *Fixture) !void {
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/handoff", .{}));
    try expectNoStaging(fixture);
}

fn expectNoStaging(fixture: *Fixture) !void {
    var dir = try fixture.tmp.dir.openDir(std.testing.io, "durable", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".maru-aggregate-"));
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
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
