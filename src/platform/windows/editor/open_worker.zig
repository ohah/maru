//! Initial native reads and zero-write capability probes without Registry access.
//! Cancellation keeps the job alive until native ownership has actually drained.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const native = @import("native_open.zig");
const backups = @import("backup_store.zig");
const w = std.os.windows;
extern "kernel32" fn SetFileAttributesW([*:0]const u16, u32) callconv(maru.win32_abi.winapi) w.BOOL;
pub const max_bytes = 4 << 20;
pub const ReadonlyImage = struct {
    path: []u8,
    bytes: []u8,
    raw_hash: u64,

    pub fn deinit(self: *ReadonlyImage) void {
        std.heap.smp_allocator.free(self.path);
        std.heap.smp_allocator.free(self.bytes);
    }
};
pub const Result = struct {
    snapshot: ?native.Snapshot = null,
    readonly: ?ReadonlyImage = null,
    /// Borrowed only from the owned snapshot/readonly bytes in this Result.
    document: ?maru.session.editor.document.Document = null,
    /// Independently owned CPU preparation; no Registry or view crosses threads.
    file: ?maru.session.editor.edit_doc.EditableFile = null,
    recovery_checked: bool = false,
    recovery: ?backups.Record = null,
    recovery_owner: ?backups.LocalData = null,
    recovery_failure: ?anyerror = null,
    failure: ?anyerror = null,
    cancelled: bool = false,
    consumed: bool = false,
    thread_id: std.Thread.Id,

    pub fn deinit(self: *Result, io: std.Io) void {
        if (self.recovery) |*record| record.deinit();
        self.recovery = null;
        if (self.recovery_owner) |*owner| owner.deinit(io);
        self.recovery_owner = null;
        if (self.file) |*file| file.deinit();
        self.file = null;
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
    recover: bool = false,
    localappdata: ?[]u8 = null,
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
        errdefer a.free(path);
        const file = try maru.session.editor.edit_doc.EditableFile.init(a, bytes, true);
        return .{ .readonly = .{ .path = path, .bytes = bytes, .raw_hash = maru.session.editor.document_state.contentHash(bytes) }, .document = parsed, .file = file, .thread_id = std.Thread.getCurrentId() };
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
        var file = maru.session.editor.edit_doc.EditableFile.init(std.heap.smp_allocator, snapshot.bytes, false) catch |err| {
            snapshot.deinit(io);
            return .{ .failure = err, .cancelled = self.cancel_requested.load(.acquire), .thread_id = thread_id };
        };
        if (self.cancel_requested.load(.acquire)) {
            file.deinit();
            snapshot.deinit(io);
            return .{ .cancelled = true, .thread_id = thread_id };
        }
        return .{ .snapshot = snapshot, .document = parsed, .file = file, .thread_id = thread_id };
    }
    fn readRecovery(self: *Job, io: std.Io, result: *Result) !void {
        result.recovery_checked = true;
        if (result.failure != null or result.cancelled or result.snapshot == null) return;
        const a = std.heap.smp_allocator;
        const environment = if (self.localappdata == null) maru.os_env.allocValue(a, "LOCALAPPDATA") else null;
        defer if (environment) |value| a.free(value);
        var owner = backups.LocalData.openExisting(a, io, self.localappdata orelse environment, max_bytes) catch |err| {
            // Absence is different from unreadable recovery data. Never create
            // or repair a backup directory merely to open the original file.
            if (err == error.NotFound or err == error.FileNotFound) return;
            return err;
        };
        var owner_owned = true;
        defer if (owner_owned) owner.deinit(io);
        // The native grant's selected path is also the persisted document key.
        // Tree paths can have different separators; using them loses backups.
        result.recovery = try owner.store.read(io, .{ .path = .{ .path = result.snapshot.?.path, .disk_hash = result.snapshot.?.raw_hash } });
        if (result.recovery != null) {
            // The app needs this pinned store to remove the record on its first
            // save/close, before any later backup maintenance has run.
            result.recovery_owner = owner;
            owner_owned = false;
        }
    }

    fn run(self: *Job, comptime Driver: type) void {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.result = self.perform(threaded.io(), Driver);
        if (self.recover) self.readRecovery(threaded.io(), &self.result.?) catch |err| {
            if (err == error.OutOfMemory) self.result.?.failure = err else self.result.?.recovery_failure = err;
        };
        if (self.cancel_requested.load(.acquire)) {
            self.result.?.deinit(threaded.io());
            self.result.?.cancelled = true;
        }
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
    pub fn startForAppWithRecovery(self: *Worker, path: []const u8, limit: usize, localappdata: ?[]const u8) !void {
        const kind = maru.session.file_panel_bridge.openKindForPath(path) orelse return error.UnsupportedFileKind;
        if (kind != .text) return error.NeedsWebPanel;
        return self.startRecoveryMode(path, limit, true, true, localappdata, Native);
    }
    fn startWith(self: *Worker, path: []const u8, limit: usize, comptime Driver: type) !void {
        return self.startMode(path, limit, false, Driver);
    }
    fn startMode(self: *Worker, path: []const u8, limit: usize, readonly_fallback: bool, comptime Driver: type) !void {
        return self.startRecoveryMode(path, limit, readonly_fallback, false, null, Driver);
    }
    fn startRecoveryMode(self: *Worker, path: []const u8, limit: usize, readonly_fallback: bool, recover: bool, localappdata: ?[]const u8, comptime Driver: type) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.checkOwner();
        if (self.job != null) return error.OpenBusy;
        if (limit > max_bytes) return error.ReadLimitExceeded;
        if (path.len == 0 or path.len > std.fs.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const owned = try std.heap.smp_allocator.dupe(u8, path);
        errdefer std.heap.smp_allocator.free(owned);
        if (localappdata) |root| if (root.len > std.fs.max_path_bytes or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidPath;
        const owned_local = if (localappdata) |root| try std.heap.smp_allocator.dupe(u8, root) else null;
        errdefer if (owned_local) |root| std.heap.smp_allocator.free(root);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .path = owned, .limit = limit, .readonly_fallback = readonly_fallback, .recover = recover, .localappdata = owned_local };
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
        if (job.localappdata) |root| std.heap.smp_allocator.free(root);
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

fn recoveryRoot(tmp: *std.testing.TmpDir) ![]u8 {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    return std.testing.allocator.dupe(u8, path[0..len]);
}

test "Windows initial open worker owns recovery bytes and preserves the original disk baseline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    const root = try recoveryRoot(&tmp);
    defer std.testing.allocator.free(root);
    {
        var owner = try backups.LocalData.open(std.testing.allocator, std.testing.io, root, max_bytes);
        defer owner.deinit(std.testing.io);
        try owner.store.write(std.testing.io, .{ .path = .{ .path = path, .disk_hash = 42 } }, "recover\r\n");
    }
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForAppWithRecovery(path, 128, root);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.recovery_checked and result.failure == null and result.recovery_failure == null);
    try std.testing.expect(result.thread_id != std.Thread.getCurrentId());
    try std.testing.expect(result.recovery != null);
    try std.testing.expectEqualStrings("recover\r\n", result.recovery.?.parsed.content);
    try std.testing.expectEqual(@as(u64, 42), result.recovery.?.parsed.doc.path.disk_hash);
    try std.testing.expect(result.snapshot.?.raw_hash != 42);
    result.deinit(std.testing.io);
    try worker.startForAppWithRecovery(path, 128, root);
    const deadline = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromSeconds(5));
    while (!worker.job.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).durationTo(deadline).nanoseconds <= 0) return error.OpenTimeout;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try worker.cancel();
    var cancelled = (try worker.takeResult()).?;
    defer cancelled.deinit(std.testing.io);
    try std.testing.expect(cancelled.cancelled and cancelled.recovery != null);
    try std.testing.expectEqualStrings("recover\r\n", cancelled.recovery.?.parsed.content);
}

test "Windows initial open worker absence never creates a recovery store" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    const root = try recoveryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForAppWithRecovery(path, 128, root);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.recovery_checked and result.failure == null and result.recovery_failure == null and result.recovery == null);
    if (backups.LocalData.openExisting(std.testing.allocator, std.testing.io, root, max_bytes)) |value| {
        var owner = value;
        owner.deinit(std.testing.io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.NotFound, err);
}

test "Windows initial open worker distinguishes unreadable recovery from absence" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    const root = try recoveryRoot(&tmp);
    defer std.testing.allocator.free(root);
    {
        var owner = try backups.LocalData.open(std.testing.allocator, std.testing.io, root, max_bytes);
        defer owner.deinit(std.testing.io);
        const doc: maru.session.editor.backup.Doc = .{ .path = .{ .path = path, .disk_hash = 42 } };
        try owner.store.write(std.testing.io, doc, "recover");
        var name_buffer: [maru.session.editor.backup.max_file_name_len]u8 = undefined;
        const name = maru.session.editor.backup.fileName(&name_buffer, doc);
        try owner.store.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "bad" });
    }
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForAppWithRecovery(path, 128, root);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.recovery_checked and result.failure == null and result.snapshot != null);
    try std.testing.expectEqual(@as(?anyerror, error.BadHeader), result.recovery_failure);
    try std.testing.expect(result.recovery == null);
}

test "Windows initial open worker recovery uses the native path rather than tree separators" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(&tmp);
    defer std.testing.allocator.free(path);
    for (path) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    const root = try recoveryRoot(&tmp);
    defer std.testing.allocator.free(root);
    {
        var snapshot = try native.Snapshot.openPath(std.testing.allocator, std.testing.io, path, 128);
        defer snapshot.deinit(std.testing.io);
        try std.testing.expect(!std.mem.eql(u8, path, snapshot.path));
        var owner = try backups.LocalData.open(std.testing.allocator, std.testing.io, root, max_bytes);
        defer owner.deinit(std.testing.io);
        try owner.store.write(std.testing.io, .{ .path = .{ .path = snapshot.path, .disk_hash = 42 } }, "tree-recovery");
    }
    var worker: Worker = .{ .allocator = std.testing.allocator };
    defer drain(&worker);
    try worker.startForAppWithRecovery(path, 128, root);
    var result = try awaitResult(&worker);
    defer result.deinit(std.testing.io);
    try std.testing.expect(result.recovery_checked and result.recovery != null);
    try std.testing.expectEqualStrings(result.snapshot.?.path, result.recovery.?.parsed.doc.path.path);
    try std.testing.expectEqualStrings("tree-recovery", result.recovery.?.parsed.content);
}
