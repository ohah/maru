//! Explicit archive log selection through the Windows Shell, after fresh identity proof.
const std = @import("std");
const maru = @import("maru");
const abi = maru.win32_abi;
const detail = maru.app.agent_session_archive_detail_backend;
const origin = maru.app.agent_session_archive_backend.source_identity;
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(abi.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(abi.winapi) void;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(abi.winapi) void;
extern "shell32" fn SHParseDisplayName([*:0]const u16, ?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(abi.winapi) i32;
extern "shell32" fn SHOpenFolderAndSelectItems(*const anyopaque, u32, ?[*]const *const anyopaque, u32) callconv(abi.winapi) i32;

pub fn verifiedFile(io: std.Io, source: detail.Source) !std.Io.File {
    if (source.origin == null or !std.fs.path.isAbsolute(source.source_path) or
        std.mem.indexOfScalar(u8, source.source_path, 0) != null) return error.StaleArchiveSource;
    const file = std.Io.Dir.cwd().openFile(io, source.source_path, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.SymLinkLoop => return error.StaleArchiveSource,
        else => return err,
    };
    errdefer file.close(io);
    const stat = try file.stat(io);
    const actual = try origin.capture(file);
    if (stat.kind != .file or stat.inode != source.inode or actual == null or actual.?.volume != source.device or
        !origin.same(actual, source.origin)) return error.StaleArchiveSource;
    return file;
}

// Microsoft requires a background thread for SHParseDisplayName and COM initialization
// before SHOpenFolderAndSelectItems. A PIDL selects the file without shell command parsing.
// https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shparsedisplayname
// https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shopenfolderandselectitems
fn showDefault(path: [:0]const u16) !void {
    if (CoInitializeEx(null, 2) < 0) return error.ShellInitializationFailed;
    defer CoUninitialize();
    var pidl: ?*anyopaque = null;
    defer if (pidl) |value| CoTaskMemFree(value);
    if (SHParseDisplayName(path.ptr, null, &pidl, 0, null) != 0) return error.ShellRevealFailed;
    const selected = pidl orelse return error.ShellRevealFailed;
    if (SHOpenFolderAndSelectItems(selected, 0, null, 0) != 0) return error.ShellRevealFailed;
}

pub const Receipt = struct { request_id: u64, identity: u64, failure: ?anyerror };
pub const Owner = struct {
    io: std.Io,
    job: ?*Job = null,
    const a = std.heap.smp_allocator;
    pub const Show = *const fn ([:0]const u16) anyerror!void;
    const Job = struct {
        io: std.Io,
        source: detail.Source,
        request_id: u64,
        identity: u64,
        show: Show,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *Job) void {
            self.execute() catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
        fn execute(self: *Job) !void {
            const file = try verifiedFile(self.io, self.source);
            defer file.close(self.io); // Keep the proven object alive through Shell selection.
            const path = try a.dupe(u8, self.source.source_path);
            defer a.free(path);
            for (path) |*c| if (c.* == '/') {
                c.* = '\\';
            };
            const wide = try std.unicode.wtf8ToWtf16LeAllocZ(a, path);
            defer a.free(wide);
            try self.show(wide);
        }
    };
    pub fn start(self: *Owner, source: detail.Source, request_id: u64, identity: u64) !bool {
        return self.startWith(source, request_id, identity, showDefault);
    }
    pub fn startWith(self: *Owner, source: detail.Source, request_id: u64, identity: u64, show: Show) !bool {
        if (self.job != null) return false;
        const path = try a.dupe(u8, source.source_path);
        errdefer a.free(path);
        const job = try a.create(Job);
        errdefer a.destroy(job);
        var owned = source;
        owned.source_path = path;
        job.* = .{ .io = self.io, .source = owned, .request_id = request_id, .identity = identity, .show = show };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        return true;
    }
    pub fn take(self: *Owner) ?Receipt {
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        job.thread.?.join();
        const result: Receipt = .{ .request_id = job.request_id, .identity = job.identity, .failure = job.failure };
        a.free(job.source.source_path);
        a.destroy(job);
        self.job = null;
        return result;
    }
    pub fn deinit(self: *Owner) void {
        if (self.job) |job| {
            job.thread.?.join();
            a.free(job.source.source_path);
            a.destroy(job);
            self.job = null;
        }
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    source: detail.Source,
    fn init(a: std.mem.Allocator, io: std.Io) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const name = "경로, 테스트.jsonl";
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "reveal fixture" });
        var buffer: [4096]u8 = undefined;
        const dir = buffer[0..try tmp.dir.realPath(io, &buffer)];
        const path = try std.fs.path.join(a, &.{ dir, name });
        errdefer a.free(path);
        const file = try tmp.dir.openFile(io, name, .{ .follow_symlinks = false });
        defer file.close(io);
        const stat = try file.stat(io);
        const id = try origin.capture(file);
        return .{ .tmp = tmp, .path = path, .source = .{ .provider = .codex, .source_path = path, .inode = stat.inode, .device = id.?.volume, .origin = id } };
    }
    fn deinit(self: *Fixture, a: std.mem.Allocator) void {
        a.free(self.path);
        self.tmp.cleanup();
    }
};
fn expectRejected(io: std.Io, source: detail.Source) !void {
    const file = verifiedFile(io, source) catch |err| {
        try std.testing.expectEqual(error.StaleArchiveSource, err);
        return;
    };
    file.close(io);
    return error.TestExpectedError;
}
const Mock = struct {
    var calls: std.atomic.Value(u32) = .init(0);
    fn show(path: [:0]const u16) !void {
        if (path.len == 0 or std.mem.indexOfScalar(u16, path, '/') != null) return error.InvalidNativePath;
        _ = calls.fetchAdd(1, .seq_cst);
    }
};
fn waitReceipt(owner: *Owner) !Receipt {
    const deadline = std.Io.Clock.awake.now(owner.io).nanoseconds + 4 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(owner.io).nanoseconds < deadline) {
        if (owner.take()) |receipt| return receipt;
        try std.Io.sleep(owner.io, std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}
test "Windows editor host archive reveal rejects missing forged and replaced sources" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(a, io);
    defer fixture.deinit(a);
    const good = try verifiedFile(io, fixture.source);
    good.close(io);
    var bad = fixture.source;
    bad.origin = null;
    try expectRejected(io, bad);
    bad = fixture.source;
    bad.origin.?.file[15] ^= 1;
    try expectRejected(io, bad);
    bad = fixture.source;
    bad.origin.?.volume ^= 1;
    try expectRejected(io, bad);
    try fixture.tmp.dir.rename("경로, 테스트.jsonl", fixture.tmp.dir, "moved.jsonl", io);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "경로, 테스트.jsonl", .data = "competitor" });
    try expectRejected(io, fixture.source);
}
test "Windows editor host archive reveal worker owns path gates Shell and preserves correlated receipt" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(a, io);
    defer fixture.deinit(a);
    var owner: Owner = .{ .io = io };
    defer owner.deinit();
    Mock.calls.store(0, .seq_cst);
    try std.testing.expect(try owner.startWith(fixture.source, 4, 7, Mock.show));
    try std.testing.expect(owner.job.?.source.source_path.ptr != fixture.path.ptr);
    try std.testing.expect(!(try owner.startWith(fixture.source, 5, 8, Mock.show)));
    const ready = try waitReceipt(&owner);
    try std.testing.expect(ready.failure == null);
    try std.testing.expectEqual(@as(u64, 4), ready.request_id);
    try std.testing.expectEqual(@as(u64, 7), ready.identity);
    try std.testing.expectEqual(@as(u32, 1), Mock.calls.load(.seq_cst));
    var forged = fixture.source;
    forged.origin.?.file[15] ^= 1;
    try std.testing.expect(try owner.startWith(forged, 6, 7, Mock.show));
    const refused = try waitReceipt(&owner);
    try std.testing.expectEqual(error.StaleArchiveSource, refused.failure.?);
    try std.testing.expectEqual(@as(u64, 6), refused.request_id);
    try std.testing.expectEqual(@as(u32, 1), Mock.calls.load(.seq_cst));
    try std.testing.expect(try owner.startWith(fixture.source, 8, 7, Mock.show));
    owner.deinit(); // The accepted operation must drain before the fixture disappears.
    try std.testing.expectEqual(@as(u32, 2), Mock.calls.load(.seq_cst));
}
