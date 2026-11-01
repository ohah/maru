//! Window-owned orchestration from root validation through native preparation to publication.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const protocol = maru.app.file_tree_root_validation;
const backend = maru.app.file_tree_backend;
const tree_mod = maru.session.file_tree;
const preparation = @import("file_tree_root_prepare.zig");
const Manager = @import("file_tree_root_commit.zig").Manager;
const Host = @import("file_tree_roots.zig").Host;
pub const Flow = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: Host,
    job: ?preparation.Job = null,
    owned: ?*preparation.Prepared = null,
    discard_owned: bool = false,
    retiring_owned: bool = false,
    cancel_requested: bool = false,
    notice: ?maru.i18n.Key = null,
    pub fn init(a: std.mem.Allocator, io: std.Io) Flow {
        return .{ .allocator = a, .io = io, .host = Host.init(a) };
    }
    pub fn busy(self: *const Flow) bool {
        return self.host.pending != null or self.job != null or self.owned != null;
    }
    pub fn start(self: *Flow, worker: *backend.Backend, tree: *const tree_mod.Tree, path: []const u8, operation: protocol.Operation) !void {
        if (self.busy()) return error.Busy;
        try self.host.start(worker, tree, path, operation);
        self.cancel_requested = false;
    }
    pub fn cancel(self: *Flow) void {
        self.cancel_requested = true;
        self.notice = null;
        self.host.cancel();
        if (self.job) |*job| job.cancel();
        if (self.owned != null) self.discard_owned = true;
    }
    pub fn takeNotice(self: *Flow) ?maru.i18n.Key {
        const notice = self.notice;
        self.notice = null;
        return notice;
    }
    /// Caller still owns result. Only successful preparation start takes its directory.
    pub fn accept(self: *Flow, worker: *backend.Backend, tree: *const tree_mod.Tree, result: *backend.Result) void {
        switch (self.host.consume(worker, tree, result)) {
            .ignored, .revalidating => {},
            .failed => |notice| self.notice = notice,
            .ready => |pending| {
                if (self.job != null or self.owned != null) {
                    self.notice = .fp_root_busy_retry;
                    return;
                }
                const dir = result.validated_dir orelse {
                    self.notice = .fp_root_capability_gone;
                    return;
                };
                self.job = preparation.Job.start(self.allocator, self.io, result.path, dir, pending) catch {
                    self.notice = .fp_root_watch_change_failed;
                    return;
                };
                result.validated_dir = null;
            },
        }
    }
    /// Call after close/Esc processing. Errors retain any not-yet-retired native owner.
    pub fn tick(self: *Flow, manager: *Manager, tree: *tree_mod.Tree, rows: *std.ArrayList(tree_mod.Row), primary: *?[]u8, worker: *backend.Backend, open: []const tree_mod.OpenState, allow_commit: bool) !bool {
        if (!allow_commit) self.cancel();
        if (self.job) |*job| {
            if (job.poll()) |outcome| switch (outcome) {
                .ready => |prepared| {
                    self.owned = prepared;
                    self.discard_owned = !allow_commit;
                },
                .discard => |prepared| {
                    self.owned = prepared;
                    self.discard_owned = true;
                },
                .failed => {
                    if (!self.cancel_requested) self.notice = .fp_root_watch_change_failed;
                },
                .canceled => {},
            };
            if (job.taken) {
                try job.deinit();
                self.job = null;
            }
        }
        if (self.owned) |prepared| {
            if (self.retiring_owned) {
                if (try prepared.pollRetire()) {
                    self.owned = null;
                    self.retiring_owned = false;
                }
                return false;
            }
            if (!self.discard_owned) {
                manager.commit(tree, rows, primary, worker, prepared, open) catch |err| {
                    self.notice = switch (err) {
                        error.StaleGeneration => .fp_root_stale_generation,
                        error.BackendBusy => .fp_root_scan_start_failed,
                        error.OutOfMemory => .fp_root_change_alloc_failed,
                        else => .fp_root_watch_change_failed,
                    };
                    self.discard_owned = true;
                    try self.retire(manager, prepared);
                    return false;
                };
                self.owned = null;
                return true;
            }
            try self.retire(manager, prepared);
        }
        return false;
    }
    /// Outside the render loop, for exceptional exit and completed close handling.
    pub fn shutdownBlocking(self: *Flow, manager: *Manager, tree: *tree_mod.Tree, rows: *std.ArrayList(tree_mod.Row), primary: *?[]u8, worker: *backend.Backend) !void {
        self.cancel();
        while (self.busy()) {
            _ = try self.tick(manager, tree, rows, primary, worker, &.{}, false);
            if (self.busy()) try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    fn retire(self: *Flow, manager: *Manager, prepared: *preparation.Prepared) !void {
        manager.discard(prepared) catch |err| switch (err) {
            error.OutOfMemory, error.RetirementBusy => {
                // The single held slot is also a bounded emergency retirement owner.
                self.retiring_owned = try prepared.release();
                if (!self.retiring_owned) self.owned = null;
                return;
            },
            else => return err,
        };
        self.owned = null;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    flow: Flow,
    manager: Manager,
    tree: tree_mod.Tree,
    rows: std.ArrayList(tree_mod.Row) = .empty,
    primary: ?[]u8 = null,
    worker: backend.Backend,
    fn init(manager_allocator: std.mem.Allocator) !Fixture {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "proof.txt", .data = "root flow proof" });
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try maru.path_shape.normalizeSeparators(a, buffer[0..try tmp.dir.realPath(io, &buffer)]);
        errdefer a.free(path);
        const worker = try backend.Backend.init(a, io);
        return .{ .tmp = tmp, .path = path, .flow = Flow.init(a, io), .manager = Manager.init(manager_allocator), .tree = tree_mod.Tree.init(a), .worker = worker };
    }
    fn drain(self: *Fixture) void {
        while (self.worker.takeResult()) |taken| {
            var result = taken;
            defer result.deinit(std.testing.allocator, std.testing.io);
            if (result.kind == .root_validation) self.flow.accept(&self.worker, &self.tree, &result);
        }
    }
    fn tick(self: *Fixture, allow: bool) !bool {
        return self.flow.tick(&self.manager, &self.tree, &self.rows, &self.primary, &self.worker, &.{}, allow);
    }
    fn awaitPreparation(self: *Fixture) !void {
        const io = std.testing.io;
        const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
        while (self.flow.job == null) {
            self.drain();
            if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.PreparationNotStarted;
            if (!self.flow.busy()) return error.PreparationNotStarted;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    fn settle(self: *Fixture, allow: bool) !bool {
        const io = std.testing.io;
        const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
        var changed = false;
        while (self.flow.busy()) {
            self.drain();
            changed = (try self.tick(allow)) or changed;
            if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.FlowTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return changed;
    }
    fn deinit(self: *Fixture) void {
        self.flow.cancel();
        _ = self.settle(false) catch unreachable;
        self.worker.quietForTest();
        self.worker.deinit();
        self.manager.shutdownBlocking() catch unreachable;
        self.rows.deinit(self.manager.allocator);
        self.tree.deinit();
        if (self.primary) |path| self.manager.allocator.free(path);
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};
test "Windows root flow publishes a validated directory and requests a repaint" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try std.testing.expect(try f.settle(true));
    try std.testing.expectEqual(@as(usize, 1), f.tree.rootCount());
    try std.testing.expectEqualStrings(f.path, f.primary.?);
    try std.testing.expect(f.rows.items[0] == .root and f.manager.active.items.len == 1);
    try std.testing.expect(f.flow.takeNotice() == null);
}
test "Windows root flow explicit cancel wins after native preparation starts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try f.awaitPreparation();
    f.flow.cancel();
    try std.testing.expect(!try f.settle(true));
    try std.testing.expectEqual(@as(usize, 0), f.tree.rootCount());
    try std.testing.expect(f.primary == null and f.manager.active.items.len == 0);
}
test "Windows root flow rejects new requests while native preparation owns its slot" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try f.awaitPreparation();
    try std.testing.expectError(error.Busy, f.flow.start(&f.worker, &f.tree, f.path, .add));
}
test "Windows root flow rejects stale publication after native preparation starts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try f.awaitPreparation();
    try f.tree.replaceExplicitRoots(&.{});
    try std.testing.expect(!try f.settle(true));
    try std.testing.expectEqual(maru.i18n.Key.fp_root_stale_generation, f.flow.takeNotice().?);
    try std.testing.expect(f.manager.active.items.len == 0 and f.primary == null);
}
test "Windows root flow keeps its native owner when retirement allocation fails" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var f = try Fixture.init(failing.allocator());
    defer f.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try f.awaitPreparation();
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!f.flow.job.?.state.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.PreparationTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    f.flow.cancel();
    try std.testing.expect(!try f.tick(true));
    try std.testing.expect(f.flow.owned != null and f.flow.retiring_owned and f.flow.job == null);
    try std.testing.expectError(error.Busy, f.flow.start(&f.worker, &f.tree, f.path, .add));
}

test "Windows root flow close priority cancels a completed preparation before publication" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try f.awaitPreparation();
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!f.flow.job.?.state.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.PreparationTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!try f.settle(false));
    try std.testing.expect(f.manager.active.items.len == 0 and f.primary == null and f.flow.takeNotice() == null);
}

test "Windows root flow shutdown drains a pending native preparation without publishing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    try f.flow.start(&f.worker, &f.tree, f.path, .replace);
    try f.awaitPreparation();
    try f.flow.shutdownBlocking(&f.manager, &f.tree, &f.rows, &f.primary, &f.worker);
    try std.testing.expect(!f.flow.busy() and f.tree.rootCount() == 0 and f.manager.active.items.len == 0);
}
