//! Window-owned root request routing. Disk validation stays on the shared worker.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const protocol = maru.app.file_tree_root_validation;
const backend = maru.app.file_tree_backend;
const Tree = maru.session.file_tree.Tree;

pub const Completion = union(enum) { ignored, revalidating, ready: protocol.Pending, failed: maru.i18n.Key };
pub const Host = struct {
    allocator: std.mem.Allocator,
    last_request_id: u64 = 0,
    pending: ?protocol.Pending = null,
    pub fn init(allocator: std.mem.Allocator) Host {
        return .{ .allocator = allocator };
    }
    pub fn start(self: *Host, worker: *backend.Backend, tree: *const Tree, path: []const u8, operation: protocol.Operation) !void {
        if (self.pending != null) return error.Busy;
        if (operation == .none or path.len == 0 or path.len > std.fs.max_path_bytes or
            !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (self.last_request_id == std.math.maxInt(u64)) return error.RequestIdExhausted;
        const owned = try self.allocator.dupe(u8, path);
        self.last_request_id += 1;
        const pending: protocol.Pending = .{ .request_id = self.last_request_id, .expected_root_generation = tree.rootGeneration(), .operation = operation };
        if (!worker.submitRootValidation(owned, pending.request_id, pending.expected_root_generation, @backingInt(operation), 0)) {
            self.allocator.free(owned);
            return error.BackendBusy;
        }
        self.pending = pending;
    }
    pub fn cancel(self: *Host) void {
        self.pending = null;
    }
    /// Borrows result: the caller retains its path and directory capability.
    /// A ready result is not a commit; model/watcher/row staging must still succeed.
    pub fn consume(self: *Host, worker: *backend.Backend, tree: *const Tree, result: *const backend.Result) Completion {
        const pending = self.pending orelse return .ignored;
        switch (protocol.evaluate(pending, protocol.Reply.fromBackend(result), tree.rootGeneration())) {
            .ignore => return .ignored,
            .failed => |failure| {
                self.pending = null;
                return .{ .failed = failure.notice };
            },
            .revalidate => |identity| {
                const canonical = self.allocator.dupe(u8, result.path) catch {
                    self.pending = null;
                    return .{ .failed = .fp_root_revalidate_alloc_failed };
                };
                if (!worker.submitRootValidation(canonical, pending.request_id, pending.expected_root_generation, @backingInt(pending.operation), 1)) {
                    self.allocator.free(canonical);
                    self.pending = null;
                    return .{ .failed = .fp_root_revalidate_start_failed };
                }
                self.pending.?.round = 1;
                self.pending.?.identity = identity;
                return .revalidating;
            },
            .ready => {
                self.pending = null;
                return .{ .ready = pending };
            },
        }
    }
};

fn awaitResult(worker: *backend.Backend) !backend.Result {
    var rounds: usize = 0;
    while (rounds < 5000) : (rounds += 1) {
        if (worker.takeResult()) |result| return result;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.RootWorkerTimeout;
}
fn privatePath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const native = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    return maru.path_shape.normalizeSeparators(std.testing.allocator, native);
}

test "Windows tree root host validates two native rounds and consumes readiness once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try privatePath(&tmp);
    defer a.free(path);
    var worker = try backend.Backend.init(a, io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    try host.start(&worker, &tree, path, .add);
    const id = host.pending.?.request_id;
    var first = try awaitResult(&worker);
    defer first.deinit(a, io);
    try std.testing.expect(host.consume(&worker, &tree, &first) == .revalidating);
    try std.testing.expectEqual(@as(u8, 1), host.pending.?.round);
    var second = try awaitResult(&worker);
    defer second.deinit(a, io);
    const completion = host.consume(&worker, &tree, &second);
    try std.testing.expect(completion == .ready);
    try std.testing.expectEqual(id, completion.ready.request_id);
    try std.testing.expectEqual(protocol.Operation.add, completion.ready.operation);
    try std.testing.expect(second.validated_dir != null);
    try std.testing.expect(host.pending == null and host.consume(&worker, &tree, &second) == .ignored);
    try std.testing.expectEqual(@as(usize, 0), tree.rootCount());
}
test "Windows tree root host cancellation ignores a real late reply and never reuses its id" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try privatePath(&tmp);
    defer a.free(path);
    var worker = try backend.Backend.init(a, io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    try host.start(&worker, &tree, path, .replace);
    const old_id = host.pending.?.request_id;
    host.cancel();
    var old = try awaitResult(&worker);
    defer old.deinit(a, io);
    try std.testing.expect(host.consume(&worker, &tree, &old) == .ignored);
    try host.start(&worker, &tree, path, .replace);
    try std.testing.expect(host.pending.?.request_id > old_id);
    try std.testing.expect(host.consume(&worker, &tree, &old) == .ignored);
    var fresh = try awaitResult(&worker);
    defer fresh.deinit(a, io);
    host.cancel();
}
test "Windows tree root host busy request leaves its active routing identity unchanged" {
    const a = std.testing.allocator;
    var worker = try backend.Backend.init(a, std.testing.io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    host.pending = .{ .request_id = 4, .expected_root_generation = 1, .operation = .add };
    try std.testing.expectError(error.Busy, host.start(&worker, &tree, "C:/ignored", .replace));
    try std.testing.expectEqual(@as(u64, 4), host.pending.?.request_id);
    try std.testing.expectEqual(@as(u64, 0), host.last_request_id);
}
test "Windows tree root host exhausted ids do not submit another native job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var worker = try backend.Backend.init(a, std.testing.io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    host.last_request_id = std.math.maxInt(u64);
    try std.testing.expectError(error.RequestIdExhausted, host.start(&worker, &tree, "C:/ignored", .replace));
    try std.testing.expect(host.pending == null);
}
test "Windows tree root host input allocation failure never publishes pending work" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var worker = try backend.Backend.init(a, std.testing.io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var host = Host.init(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, host.start(&worker, &tree, "C:/ignored", .replace));
    try std.testing.expect(host.pending == null and host.last_request_id == 0);
}
test "Windows tree root host native completion rejects a changed live root generation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try privatePath(&tmp);
    defer a.free(path);
    var worker = try backend.Backend.init(a, io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    try host.start(&worker, &tree, path, .replace);
    var result = try awaitResult(&worker);
    defer result.deinit(a, io);
    try tree.replaceExplicitRoots(&.{path});
    const completion = host.consume(&worker, &tree, &result);
    try std.testing.expect(completion == .failed);
    try std.testing.expectEqual(maru.i18n.Key.fp_root_stale_generation, completion.failed);
    try std.testing.expect(host.pending == null);
}

test "Windows tree root host rejected submission frees its request and consumes its id" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var worker = try backend.Backend.init(a, std.testing.io);
    worker.deinit();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    try std.testing.expectError(error.BackendBusy, host.start(&worker, &tree, "C:/ignored", .replace));
    try std.testing.expect(host.pending == null and host.last_request_id == 1);
    try std.testing.expectError(error.BackendBusy, host.start(&worker, &tree, "C:/ignored", .replace));
    try std.testing.expectEqual(@as(u64, 2), host.last_request_id);
}
test "Windows tree root host revalidation refusal clears pending ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try privatePath(&tmp);
    defer a.free(path);
    var worker = try backend.Backend.init(a, io);
    defer worker.deinit();
    defer worker.quietForTest();
    var tree = Tree.init(a);
    defer tree.deinit();
    var host = Host.init(a);
    try host.start(&worker, &tree, path, .replace);
    var result = try awaitResult(&worker);
    defer result.deinit(a, io);
    worker.quietForTest();
    worker.deinit();
    const completion = host.consume(&worker, &tree, &result);
    try std.testing.expect(completion == .failed);
    try std.testing.expectEqual(maru.i18n.Key.fp_root_revalidate_start_failed, completion.failed);
    try std.testing.expect(host.pending == null);
}
