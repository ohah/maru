//! Atomically publish a prepared root model, rows and native watch ownership.
//! Native preparation and retirement completion stay outside the commit section.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const tree_mod = maru.session.file_tree;
const backend = maru.app.file_tree_backend;
const Prepared = @import("file_tree_root_prepare.zig").Prepared;
pub const max_retired = 2 * tree_mod.max_roots;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    active: std.ArrayList(*Prepared) = .empty,
    retired: std.ArrayList(*Prepared) = .empty,
    pub fn init(a: std.mem.Allocator) Manager {
        return .{ .allocator = a };
    }
    fn assetFor(self: *const Manager, path: []const u8) ?*Prepared {
        for (self.active.items) |asset| if (std.mem.eql(u8, asset.path, path)) return asset;
        return null;
    }
    /// On success only, the caller's reference to prepared becomes manager-owned.
    pub fn commit(self: *Manager, tree: *tree_mod.Tree, rows: *std.ArrayList(tree_mod.Row), primary: *?[]u8, worker: *backend.Backend, prepared: *Prepared, open: []const tree_mod.OpenState) !void {
        if (prepared.pending.expected_root_generation != tree.rootGeneration()) return error.StaleGeneration;
        if (prepared.pending.round != 1 or prepared.pending.identity == null or prepared.references != 1 or
            prepared.directory == null or prepared.watcher == null) return error.InvalidPrepared;
        for (self.active.items) |asset| if (asset.references == 0) return error.InvalidWatchOwner;
        var candidate = try tree.cloneForRootTransaction();
        defer candidate.deinit();
        switch (prepared.pending.operation) {
            .replace => try candidate.replaceExplicitRoots(&.{prepared.path}),
            .add => try candidate.addExplicitRoot(prepared.path),
            .none => return error.InvalidOperation,
        }
        if (self.retired.items.len + self.active.items.len + candidate.rootCount() > max_retired) return error.RetirementBusy;
        var watches: std.ArrayList(*Prepared) = .empty;
        defer watches.deinit(self.allocator);
        try watches.ensureTotalCapacity(self.allocator, candidate.rootCount());
        for (0..candidate.rootCount()) |index| {
            const path = candidate.rootAt(index).?;
            const asset = if (std.mem.eql(u8, path, prepared.path)) prepared else self.assetFor(path) orelse return error.MissingWatch;
            const identity = asset.pending.identity orelse return error.MissingIdentity;
            if (!candidate.pinRootIdentity(path, identity)) return error.MissingRoot;
            watches.appendAssumeCapacity(asset);
        }
        if (!candidate.pinRootIdentity(prepared.path, prepared.pending.identity.?)) return error.MissingRoot;
        var staged_rows: std.ArrayList(tree_mod.Row) = .empty;
        defer staged_rows.deinit(self.allocator);
        try candidate.buildRows(self.allocator, open, &staged_rows);
        maru.cell_text.classifyFileTreeRows(staged_rows.items);
        const staged_primary = try self.allocator.dupe(u8, candidate.rootAt(0).?);
        var primary_owned = true;
        defer if (primary_owned) self.allocator.free(staged_primary);
        try self.retired.ensureUnusedCapacity(self.allocator, self.active.items.len);
        const scan_path = candidate.takeScanRequestForPath(prepared.path) orelse return error.MissingScan;
        var scan_owned = true;
        defer if (scan_owned) self.allocator.free(scan_path);
        if (!worker.submitValidatedRootScan(scan_path, candidate.rootGeneration(), prepared.directory.?)) return error.BackendBusy;
        scan_owned = false;
        prepared.directory = null;
        // All fallible preparation finished before the worker accepted its capability.
        self.publish(tree, rows, primary, &candidate, &staged_rows, &watches, staged_primary);
        primary_owned = false;
    }
    fn publish(self: *Manager, tree: *tree_mod.Tree, rows: *std.ArrayList(tree_mod.Row), primary: *?[]u8, candidate: *tree_mod.Tree, staged_rows: *std.ArrayList(tree_mod.Row), watches: *std.ArrayList(*Prepared), staged_primary: ?[]u8) void {
        std.mem.swap(tree_mod.Tree, tree, candidate);
        std.mem.swap(std.ArrayList(tree_mod.Row), rows, staged_rows);
        std.mem.swap(std.ArrayList(*Prepared), &self.active, watches);
        for (watches.items) |old| {
            var retained = false;
            for (self.active.items) |current| if (current == old) {
                retained = true;
                break;
            };
            if (!retained and (old.release() catch unreachable)) self.retired.appendAssumeCapacity(old);
        }
        const old_primary = primary.*;
        primary.* = staged_primary;
        if (old_primary) |path| self.allocator.free(path);
    }
    /// Adopt startup's already-open watch. Failure leaves the native watch caller-owned.
    pub fn adopt(self: *Manager, io: std.Io, path: []const u8, watch: *@import("directory_watch.zig").Watcher, identity: tree_mod.ScanIdentity, generation: u64) !void {
        const owned = try maru.path_shape.normalizeSeparators(self.allocator, path);
        errdefer self.allocator.free(owned);
        if (self.assetFor(owned) != null) return error.DuplicateRoot;
        if (self.active.items.len >= tree_mod.max_roots) return error.TooManyRoots;
        if (watch.address != watch or watch.closing or identity.value.kind != @backingInt(tree_mod.IdentityKind.directory)) return error.InvalidWatchOwner;
        const asset = try self.allocator.create(Prepared);
        errdefer self.allocator.destroy(asset);
        try self.active.ensureUnusedCapacity(self.allocator, 1);
        asset.* = .{ .allocator = self.allocator, .io = io, .path = owned, .directory = null, .watcher = watch, .pending = .{ .request_id = 0, .expected_root_generation = generation, .operation = .none, .round = 1, .identity = identity.value } };
        self.active.appendAssumeCapacity(asset);
    }
    pub fn remove(self: *Manager, tree: *tree_mod.Tree, rows: *std.ArrayList(tree_mod.Row), primary: *?[]u8, path: []const u8, expected_generation: u64, open: []const tree_mod.OpenState) !void {
        if (expected_generation != tree.rootGeneration()) return error.StaleGeneration;
        for (self.active.items) |asset| if (asset.references == 0) return error.InvalidWatchOwner;
        var candidate = try tree.cloneForRootTransaction();
        defer candidate.deinit();
        if (!try candidate.removeExplicitRoot(path)) return error.MissingRoot;
        if (self.retired.items.len + self.active.items.len + candidate.rootCount() > max_retired) return error.RetirementBusy;
        var watches: std.ArrayList(*Prepared) = .empty;
        defer watches.deinit(self.allocator);
        try watches.ensureTotalCapacity(self.allocator, candidate.rootCount());
        for (0..candidate.rootCount()) |index| {
            const retained_path = candidate.rootAt(index).?;
            const asset = self.assetFor(retained_path) orelse return error.MissingWatch;
            const identity = asset.pending.identity orelse return error.MissingIdentity;
            if (!candidate.pinRootIdentity(retained_path, identity)) return error.MissingRoot;
            watches.appendAssumeCapacity(asset);
        }
        var staged_rows: std.ArrayList(tree_mod.Row) = .empty;
        defer staged_rows.deinit(self.allocator);
        try candidate.buildRows(self.allocator, open, &staged_rows);
        maru.cell_text.classifyFileTreeRows(staged_rows.items);
        const staged_primary: ?[]u8 = if (candidate.rootAt(0)) |remaining| try self.allocator.dupe(u8, remaining) else null;
        var primary_owned = true;
        defer if (primary_owned) {
            if (staged_primary) |value| self.allocator.free(value);
        };
        try self.retired.ensureUnusedCapacity(self.allocator, self.active.items.len);
        self.publish(tree, rows, primary, &candidate, &staged_rows, &watches, staged_primary);
        primary_owned = false;
    }

    pub fn discard(self: *Manager, prepared: *Prepared) !void {
        if (self.retired.items.len >= max_retired) return error.RetirementBusy;
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        if (try prepared.release()) self.retired.appendAssumeCapacity(prepared);
    }
    pub fn pollRetired(self: *Manager) !void {
        var index: usize = 0;
        while (index < self.retired.items.len) {
            if (try self.retired.items[index].pollRetire()) {
                _ = self.retired.swapRemove(index);
            } else index += 1;
        }
    }
    pub fn pollChanges(self: *Manager) !bool {
        var changed = false;
        for (self.active.items) |asset| {
            const watch = asset.watcher orelse return error.MissingWatch;
            changed = (try watch.poll()) or changed;
        }
        return changed;
    }
    pub fn beginShutdown(self: *Manager) !void {
        try self.retired.ensureUnusedCapacity(self.allocator, self.active.items.len);
        for (self.active.items) |asset| if (asset.references == 0) return error.InvalidWatchOwner;
        for (self.active.items) |asset| if (try asset.release()) self.retired.appendAssumeCapacity(asset);
        self.active.clearRetainingCapacity();
    }
    /// Outside the render loop. No queue allocation is needed during shutdown.
    pub fn shutdownBlocking(self: *Manager) !void {
        while (self.active.items.len != 0) {
            const asset = self.active.items[self.active.items.len - 1];
            if (asset.references != 0 and !try asset.release()) {
                self.active.items.len -= 1;
                continue;
            }
            try asset.destroyRetiredBlocking();
            self.active.items.len -= 1;
        }
        while (self.retired.items.len != 0) {
            const asset = self.retired.items[self.retired.items.len - 1];
            try asset.destroyRetiredBlocking();
            self.retired.items.len -= 1;
        }
        try self.deinit();
    }
    pub fn deinit(self: *Manager) !void {
        if (self.active.items.len != 0 or self.retired.items.len != 0) return error.WatchesStillOwned;
        self.active.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.active = .empty;
        self.retired = .empty;
    }
};

fn shutdownForTest(manager: *Manager) void {
    manager.beginShutdown() catch unreachable;
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (manager.retired.items.len != 0) {
        manager.pollRetired() catch unreachable;
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) unreachable;
        io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
    }
    manager.deinit() catch unreachable;
}
fn preparedForTest(tmp: *std.testing.TmpDir, path: []const u8, generation: u64, operation: maru.app.file_tree_root_validation.Operation) !*Prepared {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root = (try backend.validateRootSnapshot(a, io, path)) orelse return error.InvalidFixture;
    defer root.deinit(a, io);
    _ = tmp;
    const preparation = @import("file_tree_root_prepare.zig");
    var job = try preparation.Job.start(a, io, root.path, root.dir.?, .{ .request_id = 7, .expected_root_generation = generation, .operation = operation, .round = 1, .identity = root.identity });
    root.dir = null;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (true) {
        if (job.poll()) |result| {
            try job.deinit();
            switch (result) {
                .ready => |ready| return ready,
                .failed => |failure| return failure,
                else => return error.UnexpectedCancellation,
            }
        }
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.PreparationTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn nativeResultForTest(worker: *backend.Backend) !backend.Result {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (worker.takeResult()) |result| return result;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.ScanTimeout;
}
test "Windows root transaction publishes prepared rows and transfers the first scan capability" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var manager = Manager.init(a);
    defer shutdownForTest(&manager);
    var tree = tree_mod.Tree.init(a);
    defer tree.deinit();
    var rows: std.ArrayList(tree_mod.Row) = .empty;
    defer rows.deinit(a);
    var primary: ?[]u8 = null;
    defer if (primary) |value| a.free(value);
    var worker = try backend.Backend.init(a, io);
    defer worker.deinit();
    defer worker.quietForTest();
    var prepared: ?*Prepared = try preparedForTest(&tmp, path, tree.rootGeneration(), .replace);
    defer if (prepared) |owned| manager.discard(owned) catch unreachable;
    const outcome = manager.commit(&tree, &rows, &primary, &worker, prepared.?, &.{});
    if (outcome) |_| {
        prepared = null;
    } else |_| {}
    try outcome;
    try std.testing.expectEqual(@as(usize, 1), tree.rootCount());
    try std.testing.expectEqual(@as(usize, 1), manager.active.items.len);
    try std.testing.expect(manager.active.items[0].directory == null);
    try std.testing.expectEqualStrings(tree.rootAt(0).?, primary.?);
    try std.testing.expect(rows.items[0] == .root);
    var result = try nativeResultForTest(&worker);
    defer result.deinit(a, io);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(tree.rootGeneration(), result.expected_root_generation);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,
    manager: Manager,
    tree: tree_mod.Tree,
    rows: std.ArrayList(tree_mod.Row) = .empty,
    primary: ?[]u8 = null,
    worker: backend.Backend,
    fn init(tree_allocator: std.mem.Allocator) !Fixture {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        var tmp_owned = true;
        errdefer if (tmp_owned) tmp.cleanup();
        try tmp.dir.createDir(io, "alpha", .default_dir);
        try tmp.dir.createDir(io, "beta", .default_dir);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const base = try a.dupe(u8, buffer[0..try tmp.dir.realPath(io, &buffer)]);
        var base_owned = true;
        errdefer if (base_owned) a.free(base);
        var self: Fixture = .{ .tmp = tmp, .base = base, .manager = Manager.init(a), .tree = tree_mod.Tree.init(tree_allocator), .worker = try backend.Backend.init(a, io) };
        tmp_owned = false;
        base_owned = false;
        errdefer self.deinit();
        var first: ?*Prepared = try self.prepare("alpha", .replace);
        defer if (first) |owned| self.manager.discard(owned) catch unreachable;
        try self.commit(&first);
        var scan = try nativeResultForTest(&self.worker);
        defer scan.deinit(a, io);
        if (!scan.ok) return error.InitialScanFailed;
        return self;
    }
    fn prepare(self: *Fixture, name: []const u8, operation: maru.app.file_tree_root_validation.Operation) !*Prepared {
        const path = try std.fs.path.join(std.testing.allocator, &.{ self.base, name });
        defer std.testing.allocator.free(path);
        return preparedForTest(&self.tmp, path, self.tree.rootGeneration(), operation);
    }
    fn commit(self: *Fixture, owned: *?*Prepared) !void {
        try self.manager.commit(&self.tree, &self.rows, &self.primary, &self.worker, owned.*.?, &.{});
        owned.* = null;
    }
    fn deinit(self: *Fixture) void {
        self.worker.quietForTest();
        self.worker.deinit();
        shutdownForTest(&self.manager);
        self.rows.deinit(std.testing.allocator);
        self.tree.deinit();
        if (self.primary) |path| std.testing.allocator.free(path);
        std.testing.allocator.free(self.base);
        self.tmp.cleanup();
    }
};
test "Windows root transaction rejects stale prepared generation before publishing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var prepared: ?*Prepared = try f.prepare("beta", .replace);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    prepared.?.pending.expected_root_generation -= 1;
    const generation = f.tree.rootGeneration();
    try std.testing.expectError(error.StaleGeneration, f.commit(&prepared));
    try std.testing.expectEqual(generation, f.tree.rootGeneration());
    try std.testing.expectEqualStrings(f.manager.active.items[0].path, f.tree.rootAt(0).?);
}
test "Windows root transaction requires completed validation metadata" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var prepared: ?*Prepared = try f.prepare("beta", .replace);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    prepared.?.pending.round = 0;
    try std.testing.expectError(error.InvalidPrepared, f.commit(&prepared));
    try std.testing.expectEqual(@as(usize, 1), f.manager.active.items.len);
}
test "Windows root transaction backend refusal preserves model rows and native ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var prepared: ?*Prepared = try f.prepare("beta", .replace);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    f.worker.quietForTest();
    f.worker.deinit();
    const generation = f.tree.rootGeneration();
    const row_storage = f.rows.items.ptr;
    const primary = f.primary.?.ptr;
    try std.testing.expectError(error.BackendBusy, f.commit(&prepared));
    try std.testing.expectEqual(generation, f.tree.rootGeneration());
    try std.testing.expect(row_storage == f.rows.items.ptr and primary == f.primary.?.ptr);
    try std.testing.expect(prepared.?.directory != null);
    _ = try prepared.?.directory.?.stat(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), f.manager.active.items.len);
}
test "Windows root transaction add retains the previous root and its watch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const first = f.manager.active.items[0];
    var prepared: ?*Prepared = try f.prepare("beta", .add);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    try f.commit(&prepared);
    try std.testing.expectEqual(@as(usize, 2), f.tree.rootCount());
    try std.testing.expectEqual(@as(usize, 2), f.manager.active.items.len);
    try std.testing.expect(f.manager.active.items[0] == first and f.manager.retired.items.len == 0);
    var scan = try nativeResultForTest(&f.worker);
    defer scan.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expect(scan.ok);
    try std.testing.expectEqual(f.tree.rootGeneration(), scan.expected_root_generation);
}
test "Windows root transaction allocation failure cannot consume the prepared capability" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var f = try Fixture.init(failing.allocator());
    defer f.deinit();
    var prepared: ?*Prepared = try f.prepare("beta", .replace);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    const generation = f.tree.rootGeneration();
    const storage = f.rows.items.ptr;
    failing.fail_index = failing.alloc_index;
    const outcome = f.commit(&prepared);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.OutOfMemory, outcome);
    try std.testing.expectEqual(generation, f.tree.rootGeneration());
    try std.testing.expect(storage == f.rows.items.ptr);
    try std.testing.expect(prepared != null and prepared.?.directory != null);
}
test "Windows root transaction rejects replacement identity before the first successful enumeration" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const pinned = f.tree.roots.items[0].identity.?;
    var wrong: tree_mod.ScanIdentity = .{ .value = pinned };
    wrong.value.inode ^= 1;
    try std.testing.expectError(error.IdentityMismatch, f.tree.applySnapshotWithIdentity(f.tree.rootAt(0).?, wrong, &.{}));
}

test "Windows root transaction remove last root retires its watch without deleting the folder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const asset = f.manager.active.items[0];
    try f.manager.remove(&f.tree, &f.rows, &f.primary, f.tree.rootAt(0).?, f.tree.rootGeneration(), &.{});
    try std.testing.expectEqual(@as(usize, 0), f.tree.rootCount());
    try std.testing.expect(f.primary == null and f.rows.items[0] == .empty and f.manager.active.items.len == 0);
    try std.testing.expectEqual(@as(usize, 1), f.manager.retired.items.len);
    try std.testing.expect(f.manager.retired.items[0] == asset and asset.references == 0);
    const dir = try f.tmp.dir.openDir(std.testing.io, "alpha", .{});
    defer dir.close(std.testing.io);
}
test "Windows root transaction remove retains the other root watch and updates its primary path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var prepared: ?*Prepared = try f.prepare("beta", .add);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    try f.commit(&prepared);
    var scan = try nativeResultForTest(&f.worker);
    defer scan.deinit(std.testing.allocator, std.testing.io);
    const remaining = f.manager.active.items[1];
    try f.manager.remove(&f.tree, &f.rows, &f.primary, f.tree.rootAt(0).?, f.tree.rootGeneration(), &.{});
    try std.testing.expectEqual(@as(usize, 1), f.tree.rootCount());
    try std.testing.expect(f.manager.active.items[0] == remaining and remaining.references == 1);
    try std.testing.expectEqualStrings(remaining.path, f.primary.?);
    try std.testing.expectEqual(@as(usize, 1), f.manager.retired.items.len);
}
test "Windows root transaction remove rejects a stale menu generation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const generation = f.tree.rootGeneration();
    const rows = f.rows.items.ptr;
    try std.testing.expectError(error.StaleGeneration, f.manager.remove(&f.tree, &f.rows, &f.primary, f.tree.rootAt(0).?, generation - 1, &.{}));
    try std.testing.expectEqual(generation, f.tree.rootGeneration());
    try std.testing.expect(rows == f.rows.items.ptr);
}
test "Windows root transaction remove cannot consume an unknown root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const missing = try std.fs.path.join(std.testing.allocator, &.{ f.tree.rootAt(0).?, "missing" });
    defer std.testing.allocator.free(missing);
    const generation = f.tree.rootGeneration();
    try std.testing.expectError(error.MissingRoot, f.manager.remove(&f.tree, &f.rows, &f.primary, missing, generation, &.{}));
    try std.testing.expectEqual(generation, f.tree.rootGeneration());
    try std.testing.expectEqual(@as(usize, 1), f.manager.active.items.len);
}
test "Windows root transaction remove allocation failure leaves model and watch references unchanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var f = try Fixture.init(failing.allocator());
    defer f.deinit();
    const generation = f.tree.rootGeneration();
    const active = f.manager.active.items[0];
    const rows = f.rows.items.ptr;
    failing.fail_index = failing.alloc_index;
    const outcome = f.manager.remove(&f.tree, &f.rows, &f.primary, f.tree.rootAt(0).?, generation, &.{});
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.OutOfMemory, outcome);
    try std.testing.expectEqual(generation, f.tree.rootGeneration());
    try std.testing.expect(f.manager.active.items[0] == active and active.references == 1 and f.manager.retired.items.len == 0 and f.rows.items.ptr == rows);
}
test "Windows root transaction adopts startup native watch and validated identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const identity = try backend.captureDirectoryIdentity(io, tmp.dir);
    var manager = Manager.init(a);
    defer shutdownForTest(&manager);
    const watch_type = @import("directory_watch.zig").Watcher;
    var watch: ?*watch_type = try watch_type.createRecursive(a, tmp.dir);
    defer if (watch) |retained| retained.destroy() catch unreachable;
    const pointer = watch.?;
    try manager.adopt(io, path, watch.?, identity, 17);
    watch = null;
    try std.testing.expectEqual(@as(usize, 1), manager.active.items.len);
    const asset = manager.active.items[0];
    try std.testing.expect(std.mem.indexOfScalar(u8, asset.path, '\\') == null);
    try std.testing.expect(asset.watcher == pointer and asset.directory == null and asset.references == 1);
    try std.testing.expect(asset.pending.identity != null);
    try std.testing.expect(identity.value.eql(asset.pending.identity.?));
    try std.testing.expectEqual(@as(u64, 17), asset.pending.expected_root_generation);
}
test "Windows root transaction startup adoption failure leaves native handles caller owned" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var manager = Manager.init(failing.allocator());
    defer manager.deinit() catch unreachable;
    const watch = try @import("directory_watch.zig").Watcher.createRecursive(a, tmp.dir);
    defer watch.destroy() catch unreachable;
    try std.testing.expectError(error.OutOfMemory, manager.adopt(io, path, watch, try backend.captureDirectoryIdentity(io, tmp.dir), 17));
    try std.testing.expectEqual(@as(usize, 0), manager.active.items.len);
    const native = maru.win32_file_identity.Identity;
    try std.testing.expect((try native.capture(watch.handle)).eql(try native.capture(tmp.dir.handle)));
}
test "Windows root transaction duplicate startup adoption cannot steal another native watch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const identity = try backend.captureDirectoryIdentity(io, tmp.dir);
    var manager = Manager.init(a);
    defer shutdownForTest(&manager);
    const watch_type = @import("directory_watch.zig").Watcher;
    var first: ?*watch_type = try watch_type.createRecursive(a, tmp.dir);
    defer if (first) |retained| retained.destroy() catch unreachable;
    try manager.adopt(io, path, first.?, identity, 17);
    first = null;
    var second: ?*watch_type = try watch_type.createRecursive(a, tmp.dir);
    defer if (second) |retained| retained.destroy() catch unreachable;
    const outcome = manager.adopt(io, path, second.?, identity, 17);
    if (outcome) |_| {
        second = null;
    } else |_| {}
    try std.testing.expectError(error.DuplicateRoot, outcome);
    try std.testing.expectEqual(@as(usize, 1), manager.active.items.len);
}

test "Windows root transaction shutdown drains active and retired native watches without queue allocation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var prepared: ?*Prepared = try f.prepare("beta", .replace);
    defer if (prepared) |owned| f.manager.discard(owned) catch unreachable;
    try f.commit(&prepared);
    try std.testing.expect(f.manager.active.items.len == 1 and f.manager.retired.items.len == 1);
    try f.manager.shutdownBlocking();
    try std.testing.expect(f.manager.active.items.len == 0 and f.manager.retired.items.len == 0);
    try f.manager.shutdownBlocking();
}
