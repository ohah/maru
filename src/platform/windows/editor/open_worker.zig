//! Initial native reads and zero-write capability probes without Registry access.
//! Cancellation keeps the job alive until native ownership has actually drained.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const native = @import("native_open.zig");
const w = std.os.windows;
extern "kernel32" fn SetFileAttributesW([*:0]const u16, u32) callconv(maru.win32_abi.winapi) w.BOOL;
pub const max_bytes = 4 << 20;
pub const ReadonlyImage = struct {
    path: []u8,
    bytes: []u8,
    raw_hash: u64,

    fn deinit(self: *ReadonlyImage) void {
        std.heap.smp_allocator.free(self.path);
        std.heap.smp_allocator.free(self.bytes);
    }
};
pub const Result = struct {
    snapshot: ?native.Snapshot = null,
    readonly: ?ReadonlyImage = null,
    /// Borrowed only from the owned snapshot/readonly bytes in this Result.
    document: ?maru.session.editor.document.Document = null,
    failure: ?anyerror = null,
    cancelled: bool = false,
    thread_id: std.Thread.Id,

    pub fn deinit(self: *Result, io: std.Io) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(io);
        if (self.readonly) |*image| image.deinit();
        self.snapshot = null;
        self.readonly = null;
        self.document = null;
    }
};
const Native = struct {
    fn open(path: []const u8, limit: usize, io: std.Io) !native.Snapshot {
        var snapshot = try native.Snapshot.openPath(std.heap.smp_allocator, io, path, limit);
        errdefer snapshot.deinit(io);
        try snapshot.probe(io, limit);
        return snapshot;
    }
};
const Job = struct {
    path: []u8,
    limit: usize,
    readonly_fallback: bool = false,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,

    fn readOnly(self: *Job, io: std.Io) !Result {
        // Capability failure permits viewing, never a weaker editable grant.
        // Both paths use Windows absolute namespace admission and the same cap.
        _ = try native.rootForPath(self.path);
        const a = std.heap.smp_allocator;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.path, a, .limited(self.limit));
        errdefer a.free(bytes);
        const parsed = try maru.session.editor.document.open(bytes, true);
        const path = try a.dupe(u8, self.path);
        return .{ .readonly = .{ .path = path, .bytes = bytes, .raw_hash = maru.session.editor.document_state.contentHash(bytes) }, .document = parsed, .thread_id = std.Thread.getCurrentId() };
    }

    fn perform(self: *Job, io: std.Io, comptime Driver: type) Result {
        const thread_id = std.Thread.getCurrentId();
        if (self.cancel_requested.load(.acquire)) return .{ .cancelled = true, .thread_id = thread_id };
        var snapshot = Driver.open(self.path, self.limit, io) catch |err| {
            if (err == error.OutOfMemory or !self.readonly_fallback) return .{
                .failure = err,
                .cancelled = self.cancel_requested.load(.acquire),
                .thread_id = thread_id,
            };
            var fallback = self.readOnly(io) catch |failure| return .{
                .failure = failure,
                .cancelled = self.cancel_requested.load(.acquire),
                .thread_id = thread_id,
            };
            if (self.cancel_requested.load(.acquire)) {
                fallback.deinit(io);
                return .{ .cancelled = true, .thread_id = thread_id };
            }
            return fallback;
        };
        const parsed = maru.session.editor.document.open(snapshot.bytes, false) catch |err| {
            snapshot.deinit(io);
            return .{ .failure = err, .cancelled = self.cancel_requested.load(.acquire), .thread_id = thread_id };
        };
        if (self.cancel_requested.load(.acquire)) {
            snapshot.deinit(io);
            return .{ .cancelled = true, .thread_id = thread_id };
        }
        return .{ .snapshot = snapshot, .document = parsed, .thread_id = thread_id };
    }
    fn run(self: *Job, comptime Driver: type) void {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.result = self.perform(threaded.io(), Driver);
        threaded.deinit();
        // The detached thread never touches Job after this release publication.
        self.done.store(true, .release);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    job: ?*Job = null,
    address: ?*Worker = null,
    owner_thread: ?std.Thread.Id = null,

    pub fn start(self: *Worker, path: []const u8, limit: usize) !void {
        return self.startWith(path, limit, Native);
    }
    pub fn startForApp(self: *Worker, path: []const u8, limit: usize) !void {
        const kind = maru.session.file_panel_bridge.openKindForPath(path) orelse return error.UnsupportedFileKind;
        if (kind != .text) return error.NeedsWebPanel;
        return self.startMode(path, limit, true, Native);
    }
    fn startWith(self: *Worker, path: []const u8, limit: usize, comptime Driver: type) !void {
        return self.startMode(path, limit, false, Driver);
    }
    fn startMode(self: *Worker, path: []const u8, limit: usize, readonly_fallback: bool, comptime Driver: type) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.checkOwner();
        if (self.job != null) return error.OpenBusy;
        if (limit > max_bytes) return error.ReadLimitExceeded;
        if (path.len == 0 or path.len > std.fs.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const owned = try std.heap.smp_allocator.dupe(u8, path);
        errdefer std.heap.smp_allocator.free(owned);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .path = owned, .limit = limit, .readonly_fallback = readonly_fallback };
        const thread = try std.Thread.spawn(.{}, Job.run, .{ job, Driver });
        thread.detach();
        self.address = self;
        self.owner_thread = std.Thread.getCurrentId();
        self.job = job;
    }
    fn checkOwner(self: *const Worker) !void {
        if (self.address) |owner| if (owner != self) return error.CopiedOpenOwner;
        if (self.owner_thread) |owner| if (owner != std.Thread.getCurrentId()) return error.WrongOpenThread;
    }
    pub fn cancel(self: *Worker) !void {
        try self.checkOwner();
        const job = self.job orelse return;
        job.cancel_requested.store(true, .release);
    }
    pub fn takeResult(self: *Worker) !?Result {
        try self.checkOwner();
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        var result = job.result.?;
        // A late cancel can win before the app takes ownership even if native
        // work has finished. Return the snapshot for explicit caller disposal.
        if (job.cancel_requested.load(.acquire)) result.cancelled = true;
        std.heap.smp_allocator.free(job.path);
        self.allocator.destroy(job);
        self.job = null;
        return result;
    }
    pub fn deinit(self: *Worker) !void {
        try self.checkOwner();
        if (self.job != null) return error.OpenBusy;
        self.address = null;
        self.owner_thread = null;
    }
};

fn awaitResult(worker: *Worker) !Result {
    const deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromSeconds(5));
    while (true) {
        if (try worker.takeResult()) |result| return result;
        if (std.Io.Clock.awake.now(std.testing.io).durationTo(deadline).nanoseconds <= 0) return error.OpenTimeout;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
}
fn drain(worker: *Worker) void {
    if (worker.job != null) {
        worker.cancel() catch unreachable;
        var result = awaitResult(worker) catch unreachable;
        result.deinit(std.testing.io);
    }
    worker.deinit() catch unreachable;
}
fn fixturePath(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    return std.fs.path.join(std.testing.allocator, &.{ path[0..len], "file.txt" });
}

test "Windows initial open worker reads probes and retains original bytes off owner thread" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.start(path, 128);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.failure == null and !result.cancelled);
    try std.testing.expect(result.thread_id != std.Thread.getCurrentId());
    try std.testing.expectEqualStrings("\xef\xbb\xbfbase\r\n", result.snapshot.?.bytes);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\xef\xbb\xbfbase\r\n", bytes);
}

const Held = struct {
    var entered: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    fn open(path: []const u8, limit: usize, io: std.Io) !native.Snapshot {
        entered.store(true, .release);
        while (!release.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        return Native.open(path, limit, io);
    }
};
test "Windows initial open worker active cancellation drains before releasing owned job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    Held.entered.store(false, .release);
    Held.release.store(false, .release);
    defer Held.release.store(true, .release);
    try worker.startWith(path, 128, Held);
    while (!Held.entered.load(.acquire)) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    try worker.cancel();
    try std.testing.expectError(error.OpenBusy, worker.deinit());
    try std.testing.expect(try worker.takeResult() == null);
    Held.release.store(true, .release);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.cancelled and result.snapshot == null);
    try std.testing.expect(result.thread_id != std.Thread.getCurrentId());
}

test "Windows initial open worker copied owner cannot cancel consume or destroy a live job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.start(path, 128);
    var copy = worker;
    try std.testing.expectError(error.CopiedOpenOwner, copy.cancel());
    try std.testing.expectError(error.CopiedOpenOwner, copy.takeResult());
    try std.testing.expectError(error.CopiedOpenOwner, copy.deinit());
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.snapshot != null);
}

test "Windows initial open worker invalid paths and read limit never return a snapshot" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try std.testing.expectError(error.ReadLimitExceeded, worker.start(path, max_bytes + 1));
    try std.testing.expectError(error.InvalidPath, worker.start("bad\x00path", 128));
    try worker.start(path, 6);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?anyerror, error.FileTooLarge), result.failure);
    try std.testing.expect(result.snapshot == null);
}

test "Windows initial open worker late cancellation retains snapshot for caller disposal" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.start(path, 128);
    while (!worker.job.?.done.load(.acquire)) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    try worker.cancel();
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.cancelled and result.snapshot != null);
    try std.testing.expect(try worker.takeResult() == null);
}

test "Windows initial open worker readonly source fails capability before editable admission" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(wide);
    try std.testing.expect(SetFileAttributesW(wide, 1).toBool());
    defer _ = SetFileAttributesW(wide, 0x80);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.start(path, 128);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.failure != null and result.snapshot == null);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\xef\xbb\xbfbase\r\n", bytes);
}

test "Windows initial open worker app readonly fallback owns raw BOM bytes and readonly document" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(wide);
    try std.testing.expect(SetFileAttributesW(wide, 1).toBool());
    defer _ = SetFileAttributesW(wide, 0x80);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForApp(path, 128);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.failure == null and result.snapshot == null and result.readonly != null);
    try std.testing.expect(result.document.?.read_only and result.document.?.format.has_bom);
    try std.testing.expectEqualStrings("base\r\n", result.document.?.content);
    try std.testing.expectEqualStrings(path, result.readonly.?.path);
    try std.testing.expectEqualStrings("\xef\xbb\xbfbase\r\n", result.readonly.?.bytes);
    try std.testing.expectEqual(maru.session.editor.document_state.contentHash("\xef\xbb\xbfbase\r\n"), result.readonly.?.raw_hash);
    try std.testing.expect(result.thread_id != std.Thread.getCurrentId());
}

test "Windows initial open worker rejects invalid UTF8 without publishing native ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "bad\xff" });
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForApp(path, 128);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?anyerror, error.NotUtf8), result.failure);
    try std.testing.expect(result.snapshot == null and result.readonly == null and result.document == null);
}

test "Windows initial open worker parses mixed line endings without normalizing native bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    const raw = "\xef\xbb\xbfalpha\r\nbeta\ngamma\r\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = raw });
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForApp(path, 128);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.failure == null and result.snapshot != null and result.readonly == null);
    try std.testing.expect(!result.document.?.read_only);
    try std.testing.expect(result.document.?.format.has_bom and result.document.?.format.mixed_endings);
    try std.testing.expectEqual(.crlf, result.document.?.format.dominant_ending);
    try std.testing.expectEqualStrings(raw[3..], result.document.?.content);
    try std.testing.expectEqualStrings(raw, result.snapshot.?.bytes);
}

const OutOfMemory = struct {
    fn open(_: []const u8, _: usize, _: std.Io) !native.Snapshot {
        return error.OutOfMemory;
    }
};
test "Windows initial open worker app OOM never becomes readonly fallback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startMode(path, 128, true, OutOfMemory);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), result.failure);
    try std.testing.expect(result.snapshot == null and result.readonly == null and result.document == null);
}

test "Windows initial open worker fallback retains read cap and web kind admission" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try std.testing.expectError(error.NeedsWebPanel, worker.startForApp("D:\\fixture.md", 128));
    try worker.startForApp(path, 6);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.failure != null and result.snapshot == null and result.readonly == null);
}
