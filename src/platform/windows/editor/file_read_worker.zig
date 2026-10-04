//! Bounded native read ownership. Workers carry values and selected handles,
//! never a Registry pointer or borrowed editor text. Notifications only ask for
//! a read; the app still decides whether its returned ticket is current.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const w = std.os.windows;
const Identity = @import("identity.zig").Identity;
const relative = maru.win32_relative_file;
extern "kernel32" fn DuplicateHandle(w.HANDLE, w.HANDLE, w.HANDLE, *w.HANDLE, u32, w.BOOL, u32) callconv(maru.win32_abi.winapi) w.BOOL;
extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(maru.win32_abi.winapi) w.HANDLE;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(maru.win32_abi.winapi) w.BOOL;

pub const max_bytes = 4 << 20;
var owner_clock: std.atomic.Value(u64) = .init(0);
/// Native read owners and app document books share a nonreusable namespace.
pub fn issueScope() !u64 {
    var previous = owner_clock.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, previous, 1) catch return error.ReadScopeExhausted;
        previous = owner_clock.cmpxchgWeak(previous, next, .monotonic, .monotonic) orelse return next;
    }
}
pub const Ticket = struct {
    source_id: u64,
    document: maru.session.editor.document_registry.Handle,
    epoch: u64,
    revision: u64,
    disk_hash: ?u64,

    pub fn matches(self: Ticket, current: Ticket) bool {
        return self.source_id == current.source_id and std.meta.eql(self.document, current.document) and self.epoch == current.epoch and self.revision == current.revision and self.disk_hash == current.disk_hash;
    }
};

const Authority = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    name: []u8,
    identity: Identity,
    ticket: Ticket,
    limit: usize,

    fn capture(a: std.mem.Allocator, root: std.Io.Dir, name: []const u8, identity: Identity, ticket: Ticket, limit: usize) !Authority {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (limit > max_bytes) return error.ReadLimitExceeded;
        if (name.len > std.fs.max_path_bytes) return error.InvalidPath;
        var segments = std.mem.splitAny(u8, name, "/\\");
        while (segments.next()) |segment| try relative.validateBasename(segment);
        const owned_name = try a.dupe(u8, name);
        errdefer a.free(owned_name);
        var handle: w.HANDLE = undefined;
        // DUPLICATE_SAME_ACCESS keeps the selected object and sharing contract.
        // https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle
        if (!DuplicateHandle(w.GetCurrentProcess(), root.handle, w.GetCurrentProcess(), &handle, 0, .FALSE, 2).toBool()) return error.ReadRootDuplicateFailed;
        return .{ .allocator = a, .root = .{ .handle = handle }, .name = owned_name, .identity = identity, .ticket = ticket, .limit = limit };
    }

    fn deinit(self: *Authority) void {
        // Closing retained native ownership must not dereference an app I/O
        // context that may already have been destroyed after product close.
        _ = w.ntdll.NtClose(self.root.handle);
        self.allocator.free(self.name);
    }
};

const Snapshot = struct {
    file: std.Io.File,
    identity: Identity,
    size: usize,

    fn open(authority: *const Authority, io: std.Io) !Snapshot {
        var pinned = try relative.open(authority.allocator, authority.root, authority.name);
        defer pinned.deinit(io);
        if (!authority.identity.eql(try Identity.capture(pinned.original.handle))) return error.IdentityChanged;
        // Share READ only: competing writers and namespace deletion cannot
        // mutate this snapshot. Reopen the verified object, never its pathname.
        // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-reopenfile
        const handle = ReOpenFile(pinned.original.handle, 0x80000000, 1, 0x00200000);
        if (handle == w.INVALID_HANDLE_VALUE) return error.SourceBusy;
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
        errdefer file.close(io);
        const identity = try Identity.capture(handle);
        if (!authority.identity.eql(identity)) return error.IdentityChanged;
        const size = (try file.stat(io)).size;
        if (size > authority.limit) return error.FileTooLarge;
        return .{ .file = file, .identity = identity, .size = @intCast(size) };
    }
};

pub const Image = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    identity: Identity,
    ticket: Ticket,
    sequence: u64,
    owner_id: u64 = 0,
    raw_hash: u64,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.bytes);
    }
};
pub const Failure = struct { ticket: Ticket, sequence: u64, owner_id: u64, problem: anyerror };
pub const Result = union(enum) {
    image: Image,
    failure: Failure,

    pub fn deinit(self: *Result) void {
        if (self.* == .image) self.image.deinit();
    }
};

fn readImage(authority: *const Authority, io: std.Io, sequence: u64) !Image {
    const snapshot = try Snapshot.open(authority, io);
    defer snapshot.file.close(io);
    const bytes = try authority.allocator.alloc(u8, snapshot.size);
    errdefer authority.allocator.free(bytes);
    if (try snapshot.file.readPositionalAll(io, bytes, 0) != bytes.len) return error.SourceChanged;
    return .{ .allocator = authority.allocator, .bytes = bytes, .identity = snapshot.identity, .ticket = authority.ticket, .sequence = sequence, .raw_hash = maru.session.editor.document_state.contentHash(bytes) };
}

const Job = struct {
    allocator: std.mem.Allocator,
    authority: Authority,
    sequence: u64,
    owner_id: u64,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,
    thread_id: std.Thread.Id = undefined,

    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*result| result.deinit();
        self.authority.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Job) void {
        self.thread_id = std.Thread.getCurrentId();
        // The app may disappear before this detached read finishes. Own the
        // I/O provider on this thread as well as the root/name/buffer storage.
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        self.result = if (readImage(&self.authority, threaded.io(), self.sequence)) |value| blk: {
            var image = value;
            image.owner_id = self.owner_id;
            break :blk .{ .image = image };
        } else |err| .{ .failure = .{ .ticket = self.authority.ticket, .sequence = self.sequence, .owner_id = self.owner_id, .problem = err } };
        threaded.deinit();
        self.done.store(true, .release);
        self.release();
    }
};

/// Main-thread owner. Use a thread-safe allocator; one pending or unconsumed
/// result occupies the slot. The app retains any additional dirty hint itself.
pub const Reader = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    job: ?*Job = null,
    issued: u64 = 0,
    address: ?*Reader = null,
    owner_id: u64 = 0,
    accepting: bool = false,

    pub fn submit(self: *Reader, root: std.Io.Dir, name: []const u8, identity: Identity, ticket: Ticket, limit: usize) !u64 {
        if (self.address != null and self.address != self) return error.CopiedReader;
        if (self.job != null) return error.ReadBusy;
        const sequence = std.math.add(u64, self.issued, 1) catch return error.ReadSequenceExhausted;
        const owner_id = if (self.owner_id != 0) self.owner_id else try issueScope();
        var authority = try Authority.capture(self.allocator, root, name, identity, ticket, limit);
        errdefer authority.deinit();
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .allocator = self.allocator, .authority = authority, .sequence = sequence, .owner_id = owner_id };
        const thread = try std.Thread.spawn(.{}, Job.run, .{job});
        thread.detach();
        // No fallible work after spawn: both native ownership and the owner
        // reference now have a published home, even if the worker finishes first.
        self.job = job;
        self.issued = sequence;
        self.address = self;
        self.owner_id = owner_id;
        self.accepting = true;
        return sequence;
    }

    pub fn takeResult(self: *Reader) !?Result {
        if (self.address != null and self.address != self) return error.CopiedReader;
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        const result = job.result.?;
        job.result = null;
        self.job = null;
        job.release();
        return result;
    }

    pub fn accepts(self: *const Reader, result: Result, current: Ticket) bool {
        if (!self.accepting or self.address != self) return false;
        return switch (result) {
            inline else => |value| value.owner_id == self.owner_id and value.sequence == self.issued and value.ticket.matches(current),
        };
    }

    pub fn deinit(self: *Reader, io: std.Io) !void {
        if (self.address != null and self.address != self) return error.CopiedReader;
        self.accepting = false;
        const job = self.job orelse return;
        self.job = null;
        // Product close only releases its reference; the worker retains all
        // handles/storage through completion. Tests settle before leak accounting.
        if (builtin.is_test) maru.app.detached_worker_wait.quietState(job, io);
        job.release();
    }
};

const test_ticket: Ticket = .{ .source_id = 1234, .document = .{ .slot = 7, .generation = 3 }, .epoch = 9, .revision = 12, .disk_hash = 123 };
fn fileIdentity(dir: std.Io.Dir, name: []const u8) !Identity {
    const file = try dir.openFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    return Identity.capture(file.handle);
}
fn awaitResult(reader: *Reader) !Result {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (try reader.takeResult()) |result| return result;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.ReadDidNotComplete;
}

test "Windows editor file read worker returns raw bytes and a ticket from another thread with bounded admission" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const bytes = "\xef\xbb\xbfbase\r\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = bytes });
    const identity = try fileIdentity(tmp.dir, "file.txt");
    var reader: Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    try std.testing.expect((try reader.takeResult()) == null);
    try std.testing.expectEqual(@as(u64, 1), try reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128));
    try std.testing.expectError(error.ReadBusy, reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128));
    var copied = reader;
    try std.testing.expectError(error.CopiedReader, copied.takeResult());
    try std.testing.expectError(error.CopiedReader, copied.deinit(io));
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!reader.job.?.done.load(.acquire) and std.Io.Clock.awake.now(io).nanoseconds < deadline) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expect(reader.job.?.done.load(.acquire));
    try std.testing.expect(reader.job.?.thread_id != std.Thread.getCurrentId());
    var result = try awaitResult(&reader);
    defer result.deinit();
    try std.testing.expect(result == .image);
    try std.testing.expectEqualStrings(bytes, result.image.bytes);
    try std.testing.expectEqual(maru.session.editor.document_state.contentHash(bytes), result.image.raw_hash);
    try std.testing.expect(identity.eql(result.image.identity));
    try std.testing.expect(reader.accepts(result, test_ticket));
    try std.testing.expect((try reader.takeResult()) == null);
}

test "Windows editor file read worker authority survives caller root and name storage release" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "owned" });
    const selected = try tmp.dir.openDir(io, ".", .{});
    const name = try a.dupe(u8, "file.txt");
    var authority = Authority.capture(a, selected, name, try fileIdentity(tmp.dir, "file.txt"), test_ticket, 128) catch |err| {
        selected.close(io);
        a.free(name);
        return err;
    };
    selected.close(io);
    a.free(name);
    defer authority.deinit();
    var image = try readImage(&authority, io, 1);
    defer image.deinit();
    try std.testing.expectEqualStrings("owned", image.bytes);
}

test "Windows editor file read worker rejects an equal byte replacement instead of refreshing its identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "same" });
    const identity = try fileIdentity(tmp.dir, "file.txt");
    try tmp.dir.rename("file.txt", tmp.dir, "old.txt", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "same" });
    var reader: Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    _ = try reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128);
    var result = try awaitResult(&reader);
    defer result.deinit();
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(error.IdentityChanged, result.failure.problem);
    try std.testing.expect(reader.accepts(result, test_ticket));
}

test "Windows editor file read worker snapshot fences actual competing write and delete handles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "stable" });
    var authority = try Authority.capture(std.testing.allocator, tmp.dir, "file.txt", try fileIdentity(tmp.dir, "file.txt"), test_ticket, 128);
    defer authority.deinit();
    const snapshot = try Snapshot.open(&authority, io);
    defer snapshot.file.close(io);
    for ([_]u32{ 0x40000000, 0x00010000 }) |access| {
        const other = ReOpenFile(snapshot.file.handle, access, 7, 0x00200000);
        const admitted = other != w.INVALID_HANDLE_VALUE;
        if (admitted) _ = CloseHandle(other);
        try std.testing.expect(!admitted);
    }
}

test "Windows editor file read worker reports an existing writer and enforces byte limits before allocation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "four" });
    const identity = try fileIdentity(tmp.dir, "file.txt");
    var authority = try Authority.capture(std.testing.allocator, tmp.dir, "file.txt", identity, test_ticket, 3);
    defer authority.deinit();
    try std.testing.expectError(error.FileTooLarge, Snapshot.open(&authority, io));
    authority.limit = 4;
    var exact = try readImage(&authority, io, 1);
    defer exact.deinit();
    try std.testing.expectEqualStrings("four", exact.bytes);
    authority.limit = 128;
    const writer = try tmp.dir.createFile(io, "file.txt", .{ .truncate = false });
    {
        defer writer.close(io);
        if (Snapshot.open(&authority, io)) |unexpected| {
            unexpected.file.close(io);
            return error.UnexpectedWriterAdmission;
        } else |err| try std.testing.expectEqual(error.SourceBusy, err);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
    var empty_authority = try Authority.capture(std.testing.allocator, tmp.dir, "empty.txt", try fileIdentity(tmp.dir, "empty.txt"), test_ticket, 0);
    defer empty_authority.deinit();
    var empty = try readImage(&empty_authority, io, 2);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);
    var reader: Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    try std.testing.expectError(error.ReadLimitExceeded, reader.submit(tmp.dir, "file.txt", identity, test_ticket, max_bytes + 1));
    try std.testing.expectEqual(@as(u64, 0), reader.issued);
    try std.testing.expectError(error.InvalidPath, reader.submit(tmp.dir, "../file.txt", identity, test_ticket, 128));
    const oversized_name = try std.testing.allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer std.testing.allocator.free(oversized_name);
    @memset(oversized_name, 'a');
    try std.testing.expectError(error.InvalidPath, reader.submit(tmp.dir, oversized_name, identity, test_ticket, 128));
    try std.testing.expect(reader.job == null);
}

test "Windows editor file read worker rejects older issued results and exhausted sequence without replacing its owner" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "body" });
    const identity = try fileIdentity(tmp.dir, "file.txt");
    var reader: Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    _ = try reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128);
    var first = try awaitResult(&reader);
    defer first.deinit();
    _ = try reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128);
    try std.testing.expect(!reader.accepts(first, test_ticket));
    var second = try awaitResult(&reader);
    defer second.deinit();
    try std.testing.expect(reader.accepts(second, test_ticket));
    // Identical document/revision/sequence values cannot cross reader ownership.
    var other: Reader = .{ .allocator = std.testing.allocator };
    defer other.deinit(io) catch unreachable;
    _ = try other.submit(tmp.dir, "file.txt", identity, test_ticket, 128);
    try std.testing.expect(!other.accepts(first, test_ticket));
    try reader.deinit(io);
    try std.testing.expect(!reader.accepts(second, test_ticket));
    // Reinitializing at the same address must not reuse the prior owner token.
    reader = .{ .allocator = std.testing.allocator };
    _ = try reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128);
    try std.testing.expect(!reader.accepts(first, test_ticket));
    var fresh = try awaitResult(&reader);
    defer fresh.deinit();
    try std.testing.expect(reader.accepts(fresh, test_ticket));
    reader.issued = std.math.maxInt(u64);
    try std.testing.expectError(error.ReadSequenceExhausted, reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128));
    try std.testing.expect(reader.job == null);
}

fn allocationPrefix(a: std.mem.Allocator, dir: std.Io.Dir, identity: Identity) !void {
    var authority = try Authority.capture(a, dir, "file.txt", identity, test_ticket, 128);
    defer authority.deinit();
    var image = try readImage(&authority, std.testing.io, 1);
    defer image.deinit();
    try std.testing.expectEqualStrings("prefix", image.bytes);
}
test "Windows editor file read worker allocation prefixes release every selected handle and byte buffer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "prefix" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{ tmp.dir, try fileIdentity(tmp.dir, "file.txt") });
}

test "Windows editor file read worker dropping pending ownership settles detached storage in tests" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "pending" });
    const identity = try fileIdentity(tmp.dir, "file.txt");
    var reader: Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    for (0..20) |_| {
        _ = try reader.submit(tmp.dir, "file.txt", identity, test_ticket, 128);
        try reader.deinit(io);
        try std.testing.expect(reader.job == null);
    }
    try std.testing.expectEqual(@as(u64, 20), reader.issued);
}

test "Windows editor file read worker ticket rejects each changed lifetime content and disk axis" {
    try std.testing.expect(test_ticket.matches(test_ticket));
    var other = test_ticket;
    other.source_id += 1;
    try std.testing.expect(!test_ticket.matches(other));
    other = test_ticket;
    other.document.slot += 1;
    try std.testing.expect(!test_ticket.matches(other));
    other = test_ticket;
    other.document.generation += 1;
    try std.testing.expect(!test_ticket.matches(other));
    other = test_ticket;
    other.epoch += 1;
    try std.testing.expect(!test_ticket.matches(other));
    other = test_ticket;
    other.revision += 1;
    try std.testing.expect(!test_ticket.matches(other));
    other = test_ticket;
    other.disk_hash = null;
    try std.testing.expect(!test_ticket.matches(other));
}
