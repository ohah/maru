//! Native preparation outside the UI thread. Commit and L2 acknowledgment stay
//! with the main-thread owner until the later commit handshake is connected.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const grants = @import("document_grant.zig");
const transactions = @import("transaction.zig");
const Identity = @import("identity.zig").Identity;
const relative = maru.win32_relative_file;
const w = std.os.windows;
extern "kernel32" fn DuplicateHandle(w.HANDLE, w.HANDLE, w.HANDLE, *w.HANDLE, u32, w.BOOL, u32) callconv(maru.win32_abi.winapi) w.BOOL;

pub const max_bytes = 4 << 20;
const Native = struct {
    fn write(tx: *transactions.Transaction, io: std.Io, image: editor.save_request.Image) !void {
        try tx.prepareImage(io, image);
    }
};
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    attempt: grants.Attempt,
    image: editor.save_request.Image,
    thread_id: std.Thread.Id,
    preparation_error: ?anyerror = null,

    /// Main-thread owner revalidates the original grant and live request. The
    /// worker's copied image cannot acknowledge a different or revoked request.
    pub fn commit(self: *Prepared, io: std.Io, grant: *const grants.Grant, request: *const editor.save_request.Request) !void {
        if (self.preparation_error) |failure| return failure;
        if (!self.image.sameRequest(request.image())) return error.WrongSaveRequest;
        try grant.commit(io, &self.attempt, request);
    }

    pub fn close(self: *Prepared, io: std.Io) !void {
        defer self.allocator.free(self.image.bytes);
        try self.attempt.close(io);
    }
};
pub const Result = union(enum) {
    prepared: Prepared,
    failure: anyerror,

    pub fn close(self: *Result, io: std.Io) !void {
        if (self.* == .prepared) try self.prepared.close(io);
    }
};

const Job = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    name: []u8,
    identity: Identity,
    image: editor.save_request.Image,
    limit: usize,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,

    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        // A dropped result still owns a real prepared transaction. Settle its
        // cleanup with an independent provider, never a destroyed app context.
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        if (self.result) |*result| result.close(threaded.io()) catch {};
        threaded.deinit();
        _ = w.ntdll.NtClose(self.root.handle);
        self.allocator.free(self.name);
        self.allocator.free(self.image.bytes);
        self.allocator.destroy(self);
    }

    fn prepare(self: *Job, io: std.Io, comptime Driver: type) !Prepared {
        var pinned = try relative.open(self.allocator, self.root, self.name);
        errdefer pinned.deinit(io);
        if (!self.identity.eql(try Identity.capture(pinned.original.handle))) return error.IdentityChanged;
        var tx = try transactions.Transaction.beginExperimental(self.allocator, io, &pinned, self.image.expected_source_hash, self.limit);
        // Once a native attempt exists, even partial-write failure returns its
        // ownership. The host can retry rollback without losing the real handles
        // or mistaking a failed cleanup for an aborted save. No allocation follows.
        const preparation_error: ?anyerror = blk: {
            Driver.write(&tx, io, self.image) catch |failure| break :blk failure;
            break :blk null;
        };
        const image = self.image;
        self.image.bytes = &.{};
        return .{ .allocator = self.allocator, .attempt = .{ .pinned = pinned, .transaction = tx }, .image = image, .thread_id = std.Thread.getCurrentId(), .preparation_error = preparation_error };
    }

    fn run(self: *Job, comptime Driver: type) void {
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        self.result = if (self.prepare(threaded.io(), Driver)) |value| .{ .prepared = value } else |err| .{ .failure = err };
        threaded.deinit();
        self.done.store(true, .release);
        self.release();
    }
};

/// One owned preparation slot. Use a thread-safe allocator. Moving this owner
/// after submit is rejected; neither native handles nor bytes point into it.
pub const Worker = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    job: ?*Job = null,
    address: ?*Worker = null,

    pub fn submit(self: *Worker, grant: *const grants.Grant, request: *const editor.save_request.Request, limit: usize) !void {
        try self.submitWith(grant, request, limit, Native);
    }

    fn submitWith(self: *Worker, grant: *const grants.Grant, request: *const editor.save_request.Request, limit: usize, comptime Driver: type) !void {
        if (self.address != null and self.address != self) return error.CopiedSaveWorker;
        if (self.job != null) return error.SaveBusy;
        if (limit > max_bytes) return error.SaveLimitExceeded;
        try grant.validate(request);
        const image = try request.imageForWrite();
        if (image.bytes.len > limit) return error.FileTooLarge;
        const bytes = try self.allocator.dupe(u8, image.bytes);
        errdefer self.allocator.free(bytes);
        const name = try self.allocator.dupe(u8, grant.relative_path);
        errdefer self.allocator.free(name);
        var handle: w.HANDLE = undefined;
        if (!DuplicateHandle(w.GetCurrentProcess(), grant.root.handle, w.GetCurrentProcess(), &handle, 0, .FALSE, 2).toBool()) return error.HandleDuplicateFailed;
        errdefer _ = w.ntdll.NtClose(handle);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        var owned_image = image;
        owned_image.bytes = bytes;
        job.* = .{ .allocator = self.allocator, .root = .{ .handle = handle }, .name = name, .identity = grant.identity, .image = owned_image, .limit = limit };
        const Runner = struct {
            fn run(value: *Job) void {
                value.run(Driver);
            }
        };
        const thread = try std.Thread.spawn(.{}, Runner.run, .{job});
        thread.detach();
        self.job = job;
        self.address = self;
    }

    pub fn takeResult(self: *Worker) !?Result {
        if (self.address != null and self.address != self) return error.CopiedSaveWorker;
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        const result = job.result.?;
        job.result = null;
        self.job = null;
        job.release();
        return result;
    }

    pub fn deinit(self: *Worker, io: std.Io) !void {
        if (self.address != null and self.address != self) return error.CopiedSaveWorker;
        const job = self.job orelse return;
        self.job = null;
        // Test cleanup waits for allocator accounting. Production drops the
        // reference; a late preparation closes without any document callback.
        if (builtin.is_test) maru.app.detached_worker_wait.quietState(job, io);
        job.release();
    }
};

fn awaitResult(worker: *Worker) !Result {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (try worker.takeResult()) |result| return result;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.SavePreparationDidNotComplete;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    registry: *editor.document_registry.Registry,
    opened: grants.Opened,
    request: editor.save_request.Request,
    request_owned: bool = true,

    fn init() !Fixture {
        const a = std.testing.allocator;
        const registry = try a.create(editor.document_registry.Registry);
        registry.* = .{ .allocator = a };
        errdefer a.destroy(registry);
        errdefer registry.deinit() catch unreachable;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
        var opened = try grants.Grant.openExperimental(a, std.testing.io, tmp.dir, "file.txt", registry, 128);
        errdefer opened.grant.deinit(std.testing.io);
        errdefer _ = registry.release(opened.view) catch unreachable;
        const state = registry.get(opened.view).?;
        var selections: editor.selection.Selections = .{ .items = &.{}, .primary = 0 };
        const changes = [_]editor.delta.Change{.{ .start = 0, .end = 0, .text = "X" }};
        var inverse = try state.opened.?.file.apply(.{ .changes = &changes }, &selections);
        inverse.deinit();
        const request = try editor.save_request.Request.begin(a, registry, opened.view, 128);
        return .{ .tmp = tmp, .registry = registry, .opened = opened, .request = request };
    }

    fn deinit(self: *Fixture) void {
        const a = std.testing.allocator;
        if (self.request_owned) self.request.deinit();
        self.opened.grant.deinit(std.testing.io);
        _ = self.registry.release(self.opened.view) catch unreachable;
        self.registry.deinit() catch unreachable;
        a.destroy(self.registry);
        self.tmp.cleanup();
    }

    fn disk(self: *Fixture, expected: []const u8) !void {
        const bytes = try self.tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .limited(128));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
};

test "Windows save preparation worker owns a native image from another thread and retains final validation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit(std.testing.io) catch unreachable;
    try std.testing.expectError(error.SaveLimitExceeded, worker.submit(&fixture.opened.grant, &fixture.request, max_bytes + 1));
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    try std.testing.expectError(error.SaveBusy, worker.submit(&fixture.opened.grant, &fixture.request, 128));
    var copy = worker;
    try std.testing.expectError(error.CopiedSaveWorker, copy.takeResult());
    try std.testing.expectError(error.CopiedSaveWorker, copy.deinit(std.testing.io));
    var result = try awaitResult(&worker);
    defer result.close(std.testing.io) catch unreachable;
    try std.testing.expect(result == .prepared);
    try std.testing.expect(result.prepared.thread_id != std.Thread.getCurrentId());
    try fixture.disk("\xef\xbb\xbfbase\r\n");
    const state = fixture.registry.get(fixture.opened.view).?;
    state.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, result.prepared.commit(std.testing.io, &fixture.opened.grant, &fixture.request));
    state.opened.?.file.read_only = false;
    try result.prepared.commit(std.testing.io, &fixture.opened.grant, &fixture.request);
    try result.prepared.attempt.transaction.acknowledgeDocument(&fixture.request);
    try fixture.disk("\xef\xbb\xbfXbase\r\n");
}

test "Windows save preparation worker refuses corrupt bytes changed source and initial identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit(std.testing.io) catch unreachable;
    fixture.request.disk_hash ^= 1;
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    {
        var corrupt = try awaitResult(&worker);
        defer corrupt.close(std.testing.io) catch unreachable;
        try std.testing.expect(corrupt == .prepared);
        try std.testing.expectEqual(@as(?anyerror, error.CorruptSaveImage), corrupt.prepared.preparation_error);
        try std.testing.expectError(error.CorruptSaveImage, corrupt.prepared.commit(std.testing.io, &fixture.opened.grant, &fixture.request));
    }
    fixture.request.disk_hash ^= 1;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "outside" });
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    var changed = try awaitResult(&worker);
    defer changed.close(std.testing.io) catch unreachable;
    try std.testing.expect(changed == .failure);
    try std.testing.expectEqual(error.SourceChanged, changed.failure);
    fixture.opened.grant.identity.file[15] ^= 1;
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    var replaced = try awaitResult(&worker);
    defer replaced.close(std.testing.io) catch unreachable;
    try std.testing.expect(replaced == .failure);
    try std.testing.expectEqual(error.IdentityChanged, replaced.failure);
    fixture.opened.grant.identity.file[15] ^= 1;
    try fixture.disk("outside");
}

test "Windows save preparation worker late close rolls back an unread prepared image" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    try worker.deinit(std.testing.io);
    try std.testing.expect(worker.job == null);
    try fixture.disk("\xef\xbb\xbfbase\r\n");
    try std.testing.expect(!fixture.request.acknowledged);
}

test "Windows save preparation worker owns bytes and name after the originating request is released" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit(std.testing.io) catch unreachable;
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    fixture.request.deinit();
    fixture.request_owned = false;
    fixture.opened.grant.relative_path[0] = 'x';
    var result = try awaitResult(&worker);
    defer result.close(std.testing.io) catch unreachable;
    try std.testing.expect(result == .prepared);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", result.prepared.image.bytes);
    try std.testing.expectEqual(@as(u64, 0), fixture.registry.get(fixture.opened.view).?.persistence.live_save_images);
    try fixture.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save preparation worker keeps edits made after submit dirty after captured image commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit(std.testing.io) catch unreachable;
    try worker.submit(&fixture.opened.grant, &fixture.request, 128);
    const state = fixture.registry.get(fixture.opened.view).?;
    var selections: editor.selection.Selections = .{ .items = &.{}, .primary = 0 };
    const changes = [_]editor.delta.Change{.{ .start = 0, .end = 0, .text = "Y" }};
    var inverse = try state.opened.?.file.apply(.{ .changes = &changes }, &selections);
    inverse.deinit();
    var result = try awaitResult(&worker);
    defer result.close(std.testing.io) catch unreachable;
    try std.testing.expect(result == .prepared);
    try result.prepared.commit(std.testing.io, &fixture.opened.grant, &fixture.request);
    try result.prepared.attempt.transaction.acknowledgeDocument(&fixture.request);
    try fixture.disk("\xef\xbb\xbfXbase\r\n");
    try std.testing.expectEqualStrings("YXbase\r\n", state.opened.?.file.content);
    try std.testing.expect(state.opened.?.isDirty());
}

test "Windows save preparation worker unwinds every admission allocation without publishing a job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (0..3) |prefix| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = prefix });
        var worker: Worker = .{ .allocator = failing.allocator() };
        defer worker.deinit(std.testing.io) catch unreachable;
        try std.testing.expectError(error.OutOfMemory, worker.submit(&fixture.opened.grant, &fixture.request, 128));
        try std.testing.expect(worker.job == null and worker.address == null);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(@as(u64, 1), fixture.registry.get(fixture.opened.view).?.persistence.live_save_images);
    }
    try fixture.disk("\xef\xbb\xbfbase\r\n");
}

test "Windows save preparation worker retains a poisoned native attempt after real partial write failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const PartialWrite = struct {
        fn write(tx: *transactions.Transaction, io: std.Io, image: editor.save_request.Image) !void {
            tx.phase = .poisoned;
            try tx.file.writePositionalAll(io, image.bytes[0..2], 0);
            return error.InjectedPreparationFailure;
        }
    };
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer worker.deinit(std.testing.io) catch unreachable;
    try worker.submitWith(&fixture.opened.grant, &fixture.request, 128, PartialWrite);
    var result = try awaitResult(&worker);
    defer result.close(std.testing.io) catch unreachable;
    try std.testing.expect(result == .prepared);
    const prepared = &result.prepared;
    try std.testing.expectEqual(@as(?anyerror, error.InjectedPreparationFailure), prepared.preparation_error);
    try std.testing.expectEqual(transactions.Phase.poisoned, prepared.attempt.transaction.phase);
    try std.testing.expectEqual(transactions.Outcome.undetermined, try prepared.attempt.transaction.queryOutcome());
    try std.testing.expectError(error.InjectedPreparationFailure, prepared.commit(std.testing.io, &fixture.opened.grant, &fixture.request));
    try std.testing.expect(!fixture.request.acknowledged);
    try fixture.disk("\xef\xbb\xbfbase\r\n");
    try prepared.attempt.transaction.rollback();
    try std.testing.expectEqual(transactions.Outcome.aborted, try prepared.attempt.transaction.queryOutcome());
}
