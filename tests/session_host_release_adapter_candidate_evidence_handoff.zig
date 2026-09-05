//! Baseline evidence survives destruction of its private runner workspace.

const std = @import("std");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const handoff = @import("release_adapter_candidate_evidence_handoff");

const bytes = "{\"schema\":\"maru.session-host-release-evidence.v1\"}\n";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    source_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    destination_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    source: files.PinnedReleaseFile = .{},

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
        try self.tmp.dir.createDir(std.testing.io, "durable", .default_dir);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/evidence.json", .data = bytes });
        _ = try absolute(&self.tmp, "workspace", &self.root);
        _ = try absolute(&self.tmp, "workspace/evidence.json", &self.source_path);
        _ = try absolute(&self.tmp, "durable/evidence.json", &self.destination_path);
        try files.pinReleaseFileObserved(&self.source, self.sourcePath(), false, evidence.max_evidence_bytes);
    }

    fn deinit(self: *@This()) void {
        if (self.source.value() != null) self.source.deinit() catch {};
        self.tmp.cleanup();
    }

    fn rootPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.root, 0);
    }

    fn sourcePath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.source_path, 0);
    }

    fn destinationPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.destination_path, 0);
    }
};

fn absolute(tmp: *std.testing.TmpDir, suffix: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], suffix });
}

test "durable handoff survives source workspace deletion with equal bytes and distinct inode" {
    comptime _ = handoff.promote;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const source_view = fixture.source.value().?;
    var durable: handoff.DurableEvidence = .{};
    try handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable);
    var copied_owner = durable;
    try std.testing.expect(copied_owner.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied_owner.cleanup());
    const durable_view = try durable.revalidate();
    try std.testing.expectEqual(source_view.size, durable_view.observation.size);
    try std.testing.expectEqualStrings(&source_view.sha256, &durable_view.observation.sha256);
    try std.testing.expect(source_view.identity.device != durable_view.observation.identity.device or source_view.identity.inode != durable_view.observation.identity.inode);
    try fixture.source.deinit();
    try fixture.tmp.dir.deleteTree(std.testing.io, "workspace");
    const after = try durable.revalidate();
    try std.testing.expectEqualStrings(fixture.destinationPath(), after.path);
    const copied = try fixture.tmp.dir.readFileAlloc(std.testing.io, "durable/evidence.json", std.testing.allocator, .limited(evidence.max_evidence_bytes));
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings(bytes, copied);
    const original_leaf_byte = durable.leaf[0];
    durable.leaf[0] = if (original_leaf_byte == 'x') 'y' else 'x';
    try std.testing.expectError(error.InvalidOwner, durable.cleanup());
    _ = try fixture.tmp.dir.statFile(std.testing.io, "durable/evidence.json", .{});
    durable.leaf[0] = original_leaf_byte;
    try durable.cleanup();
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/evidence.json", .{}));
    try std.testing.expectError(error.InvalidOwner, durable.cleanup());
}

test "source direct-child and destination outside-workspace rules reject paths" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableEvidence = .{};
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, "relative", fixture.sourcePath(), fixture.destinationPath(), &durable));
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), "relative", fixture.destinationPath(), &durable));
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), "relative", &durable));
    var root_as_source: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const root_as_source_path = try std.fmt.bufPrintZ(&root_as_source, "{s}", .{fixture.rootPath()});
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), root_as_source_path, fixture.destinationPath(), &durable));
    var source_as_destination: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const source_as_destination_path = try std.fmt.bufPrintZ(&source_as_destination, "{s}", .{fixture.sourcePath()});
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), source_as_destination_path, &durable));
    var root_as_destination: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const root_as_destination_path = try std.fmt.bufPrintZ(&root_as_destination, "{s}", .{fixture.rootPath()});
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), root_as_destination_path, &durable));
    var nested: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const nested_path = try std.fmt.bufPrintZ(&nested, "{s}/nested/evidence.json", .{fixture.rootPath()});
    try std.testing.expectError(error.InvalidPath, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), nested_path, fixture.destinationPath(), &durable));
}

test "copied source preowned result and result-path alias fail before publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var copied = fixture.source;
    var durable: handoff.DurableEvidence = .{};
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, &copied, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable));
    durable.owner = &durable;
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable));
    durable = .{};
    const result_bytes = std.mem.asBytes(&durable);
    const alias: [:0]const u8 = result_bytes[0..1 :0];
    try std.testing.expectError(error.InvalidOwner, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), alias, &durable));
}

test "source pathname drift leaves durable destination absent" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.rename("workspace/evidence.json", fixture.tmp.dir, "workspace/old.json", std.testing.io);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/evidence.json", .data = bytes });
    var durable: handoff.DurableEvidence = .{};
    try std.testing.expectError(error.SourceChanged, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/evidence.json", .{}));
}

test "pre-existing durable destination is preserved" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/evidence.json", .data = "existing" });
    var durable: handoff.DurableEvidence = .{};
    try std.testing.expectError(error.DestinationExists, handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable));
    const existing = try fixture.tmp.dir.readFileAlloc(std.testing.io, "durable/evidence.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(existing);
    try std.testing.expectEqualStrings("existing", existing);
}

test "cleanup preserves a replacement destination" {
    var linked_fixture: Fixture = undefined;
    try linked_fixture.init();
    defer linked_fixture.deinit();
    var linked: handoff.DurableEvidence = .{};
    try handoff.promote(std.testing.allocator, &linked_fixture.source, linked_fixture.rootPath(), linked_fixture.sourcePath(), linked_fixture.destinationPath(), &linked);
    try linked_fixture.tmp.dir.hardLink("durable/evidence.json", linked_fixture.tmp.dir, "durable/alias.json", std.testing.io, .{});
    try std.testing.expectError(error.CleanupFailed, linked.cleanup());
    _ = try linked_fixture.tmp.dir.statFile(std.testing.io, "durable/evidence.json", .{});
    _ = try linked_fixture.tmp.dir.statFile(std.testing.io, "durable/alias.json", .{});

    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableEvidence = .{};
    try handoff.promote(std.testing.allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable);
    try fixture.tmp.dir.rename("durable/evidence.json", fixture.tmp.dir, "durable/held.json", std.testing.io);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "durable/evidence.json", .data = "replacement" });
    try std.testing.expectError(error.CleanupFailed, durable.cleanup());
    const replacement = try fixture.tmp.dir.readFileAlloc(std.testing.io, "durable/evidence.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("replacement", replacement);
}

fn promoteAllocation(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var durable: handoff.DurableEvidence = .{};
    handoff.promote(allocator, &fixture.source, fixture.rootPath(), fixture.sourcePath(), fixture.destinationPath(), &durable) catch |err| {
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "durable/evidence.json", .{}));
        return err;
    };
    try durable.cleanup();
}

test "allocation failure cannot publish partial durable evidence" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, promoteAllocation, .{});
}
