//! Native directory notifications are hints to revalidate documents, never
//! evidence that a particular file changed. The host owns debounce and hashes.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const w = std.os.windows;
const cc = maru.win32_abi.winapi;
const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    position: u64 = 0,
    event: ?w.HANDLE = null,
};
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(cc) ?w.HANDLE;
extern "kernel32" fn ResetEvent(w.HANDLE) callconv(cc) w.BOOL;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(cc) w.BOOL;
extern "kernel32" fn ReadDirectoryChangesW(w.HANDLE, *anyopaque, u32, w.BOOL, u32, ?*u32, *Overlapped, ?*anyopaque) callconv(cc) w.BOOL;
extern "kernel32" fn GetOverlappedResult(w.HANDLE, *Overlapped, *u32, w.BOOL) callconv(cc) w.BOOL;
extern "kernel32" fn CancelIoEx(w.HANDLE, *Overlapped) callconv(cc) w.BOOL;
comptime {
    if (@sizeOf(usize) == 8 and @sizeOf(Overlapped) != 32) @compileError("OVERLAPPED ABI mismatch");
}

/// Heap ownership keeps both OVERLAPPED and its buffer at a stable address.
/// An empty counted name selects the root handle's object, not its pathname.
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    handle: w.HANDLE,
    event: w.HANDLE,
    overlapped: Overlapped = .{},
    buffer: [16 * 1024]u8 align(4) = undefined,
    pending: bool = false,
    address: *Watcher,
    recursive: bool = false,

    pub fn create(a: std.mem.Allocator, dir: std.Io.Dir) !*Watcher {
        return createMode(a, dir, false);
    }

    pub fn createRecursive(a: std.mem.Allocator, dir: std.Io.Dir) !*Watcher {
        return createMode(a, dir, true);
    }

    fn createMode(a: std.mem.Allocator, dir: std.Io.Dir, recursive: bool) !*Watcher {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const self = try a.create(Watcher);
        errdefer a.destroy(self);
        var empty = [_]u16{0};
        var name: w.UNICODE_STRING = .{ .Length = 0, .MaximumLength = 0, .Buffer = &empty };
        const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = dir.handle, .ObjectName = &name };
        var status: w.IO_STATUS_BLOCK = undefined;
        var handle: w.HANDLE = undefined;
        const opened = w.ntdll.NtCreateFile(&handle, @bitCast(@as(u32, 1)), &attrs, &status, null, .{}, .{ .READ = true, .WRITE = true, .DELETE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = true, .IO = .ASYNCHRONOUS }, null, 0);
        if (opened != .SUCCESS) return error.WatchOpenFailed;
        errdefer _ = CloseHandle(handle);
        const identity = @import("file_identity.zig").Identity;
        if (!(try identity.capture(handle)).eql(try identity.capture(dir.handle))) return error.WatchIdentityChanged;
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.WatchEventFailed;
        errdefer _ = CloseHandle(event);
        self.* = .{ .allocator = a, .handle = handle, .event = event, .address = self, .recursive = recursive };
        try self.arm();
        return self;
    }

    fn arm(self: *Watcher) !void {
        if (self.address != self) return error.CopiedWatcher;
        if (self.pending) return error.WatchAlreadyPending;
        if (!ResetEvent(self.event).toBool()) return error.WatchEventFailed;
        self.overlapped = .{ .event = self.event };
        // FILE_NAME, DIR_NAME, ATTRIBUTES, SIZE and LAST_WRITE. Document
        // groups watch one directory; the explorer watches its selected subtree.
        // Microsoft ReadDirectoryChangesW: even a zero-byte overflow completion
        // requires re-enumeration; notification payload is never authority.
        if (!ReadDirectoryChangesW(self.handle, &self.buffer, self.buffer.len, if (self.recursive) .TRUE else .FALSE, 0x1f, null, &self.overlapped, null).toBool()) {
            if (w.GetLastError() != .IO_PENDING) return error.WatchArmFailed;
        }
        self.pending = true;
    }

    pub fn poll(self: *Watcher) !bool {
        if (self.address != self) return error.CopiedWatcher;
        if (!self.pending) {
            // A completed/cancelled watch or failed re-arm may be retried.
            // Ask for a full rescan because changes in the gap are not known.
            try self.arm();
            return true;
        }
        var bytes: u32 = 0;
        if (!GetOverlappedResult(self.handle, &self.overlapped, &bytes, .FALSE).toBool()) {
            const failure = w.GetLastError();
            if (failure == .IO_INCOMPLETE) return false;
            if (failure == .OPERATION_ABORTED) {
                self.pending = false;
                return error.WatchCancelled;
            }
            return error.WatchReadFailed;
        }
        self.pending = false;
        // Re-arm before returning the hint; changes during revalidation then
        // queue into the same kernel-owned directory notification buffer.
        try self.arm();
        return true;
    }

    pub fn destroy(self: *Watcher) !void {
        if (self.address != self) return error.CopiedWatcher;
        if (self.pending) {
            // Cancellation requests are not completion. Microsoft CancelIoEx
            // forbids releasing OVERLAPPED storage until I/O has completed.
            if (!CancelIoEx(self.handle, &self.overlapped).toBool() and w.GetLastError() != .NOT_FOUND) return error.WatchCancelFailed;
            var bytes: u32 = 0;
            if (!GetOverlappedResult(self.handle, &self.overlapped, &bytes, .TRUE).toBool() and w.GetLastError() != .OPERATION_ABORTED) return error.WatchCompletionUnresolved;
            self.pending = false;
        }
        _ = CloseHandle(self.event);
        _ = CloseHandle(self.handle);
        const a = self.allocator;
        a.destroy(self);
    }
};

/// A lease identifies a directory group independently of array compaction.
pub const Lease = struct { owner: *Groups, id: u64 };
pub const GroupKey = struct { owner: *Groups, id: u64 };
pub const Groups = struct {
    const Member = struct { id: u64, group_id: u64 };
    const Entry = struct {
        watcher: *Watcher,
        identity: @import("file_identity.zig").Identity,
        id: u64,
        references: usize = 1,
        dirty: bool = false,
        due_ns: i128 = 0,
    };
    pub const Notice = struct { group: GroupKey, problem: ?anyerror = null };
    pub const hard_cap = 64;
    pub const debounce_ns = 200 * std.time.ns_per_ms;
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    members: std.ArrayList(Member) = .empty,
    limit: usize = hard_cap,
    issued: u64 = 0,
    cursor: usize = 0,

    pub fn acquire(self: *Groups, dir: std.Io.Dir) !Lease {
        const identity = try @import("file_identity.zig").Identity.capture(dir.handle);
        const next = std.math.add(u64, self.issued, 1) catch return error.WatchGenerationExhausted;
        for (self.entries.items) |*entry| if (entry.identity.eql(identity)) {
            const references = std.math.add(usize, entry.references, 1) catch return error.WatchReferenceExhausted;
            try self.members.ensureUnusedCapacity(self.allocator, 1);
            self.members.appendAssumeCapacity(.{ .id = next, .group_id = entry.id });
            entry.references = references;
            self.issued = next;
            return .{ .owner = self, .id = next };
        };
        if (self.entries.items.len >= @min(self.limit, hard_cap)) return error.TooManyDirectoryWatches;
        try self.members.ensureUnusedCapacity(self.allocator, 1);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const watcher = try Watcher.create(self.allocator, dir);
        // All allocations precede publication. Native pending storage then
        // transfers to the group in a nonfallible append.
        self.entries.appendAssumeCapacity(.{ .watcher = watcher, .identity = identity, .id = next });
        self.members.appendAssumeCapacity(.{ .id = next, .group_id = next });
        self.issued = next;
        return .{ .owner = self, .id = next };
    }

    fn index(self: *Groups, lease: Lease) !usize {
        if (lease.owner != self) return error.StaleWatchLease;
        for (self.members.items, 0..) |member, i| if (member.id == lease.id) return i;
        return error.StaleWatchLease;
    }

    /// The app routes a directory hint to every still-subscribed document,
    /// including peers whose lease ID differs from the shared directory ID.
    /// Resolving membership each time prevents a closed document from being
    /// revalidated when compacted storage is reused by another directory.
    pub fn receives(self: *Groups, lease: Lease, group: GroupKey) !bool {
        const member_index = try self.index(lease);
        if (group.owner != self) return false;
        return self.members.items[member_index].group_id == group.id;
    }

    pub fn release(self: *Groups, lease: Lease) !void {
        const member_index = try self.index(lease);
        const group_id = self.members.items[member_index].group_id;
        var i: usize = 0;
        while (self.entries.items[i].id != group_id) : (i += 1) {}
        const entry = &self.entries.items[i];
        if (entry.references > 1) {
            entry.references -= 1;
            _ = self.members.orderedRemove(member_index);
            return;
        }
        try entry.watcher.destroy();
        _ = self.entries.orderedRemove(i);
        _ = self.members.orderedRemove(member_index);
    }

    /// Polling performs no file read or hash. The app can move revalidation to
    /// its I/O worker after this bounded directory scan and trailing debounce.
    pub fn poll(self: *Groups, now_ns: i128) ?Notice {
        if (self.entries.items.len == 0) return null;
        for (0..self.entries.items.len) |offset| {
            const i = (self.cursor + offset) % self.entries.items.len;
            const entry = &self.entries.items[i];
            const changed = entry.watcher.poll() catch |err| {
                self.cursor = (i + 1) % self.entries.items.len;
                return .{ .group = .{ .owner = self, .id = entry.id }, .problem = err };
            };
            if (changed) {
                entry.dirty = true;
                entry.due_ns = now_ns +| debounce_ns;
            }
        }
        for (self.entries.items) |*entry| if (entry.dirty and now_ns >= entry.due_ns) {
            entry.dirty = false;
            return .{ .group = .{ .owner = self, .id = entry.id } };
        };
        return null;
    }

    pub fn deinit(self: *Groups) !void {
        // Remove only owners whose cancellation is confirmed. Failure retains
        // every still-live entry and pending buffer for a later cleanup retry.
        while (self.entries.items.len != 0) {
            const entry = self.entries.items[self.entries.items.len - 1];
            try entry.watcher.destroy();
            var i = self.members.items.len;
            while (i != 0) {
                i -= 1;
                if (self.members.items[i].group_id == entry.id) _ = self.members.orderedRemove(i);
            }
            _ = self.entries.pop();
        }
        self.members.deinit(self.allocator);
        self.members = .empty;
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }
};

fn awaitHint(watcher: *Watcher) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        if (try watcher.poll()) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.MissingDirectoryHint;
}

test "Windows editor directory watch polls idle without blocking and drains pending cancellation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const watcher = try Watcher.create(std.testing.allocator, tmp.dir);
    defer watcher.destroy() catch unreachable;
    for (0..100) |_| try std.testing.expect(!try watcher.poll());
    try std.testing.expect(watcher.pending);
}

test "Windows editor directory watch rearms after create and subsequent byte writes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const watcher = try Watcher.create(std.testing.allocator, tmp.dir);
    defer watcher.destroy() catch unreachable;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "one" });
    try awaitHint(watcher);
    try std.testing.expect(watcher.pending);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "two" });
    try awaitHint(watcher);
}

test "Windows editor directory watch survives caller directory handle closure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const selected = try tmp.dir.openDir(std.testing.io, ".", .{});
    const watcher = Watcher.create(std.testing.allocator, selected) catch |err| {
        selected.close(std.testing.io);
        return err;
    };
    selected.close(std.testing.io);
    defer watcher.destroy() catch unreachable;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "changed" });
    try awaitHint(watcher);
}

test "Windows editor directory watch rejects copied ownership and overlapping arm" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const watcher = try Watcher.create(std.testing.allocator, tmp.dir);
    defer watcher.destroy() catch unreachable;
    try std.testing.expectError(error.WatchAlreadyPending, watcher.arm());
    var copied = watcher.*;
    try std.testing.expectError(error.CopiedWatcher, copied.poll());
    try std.testing.expectError(error.CopiedWatcher, copied.destroy());
    try std.testing.expect(!try watcher.poll());
}

test "Windows editor directory watch remains bound to a moved selected directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "selected", .default_dir);
    const selected = try tmp.dir.openDir(std.testing.io, "selected", .{});
    const watcher = Watcher.create(std.testing.allocator, selected) catch |err| {
        selected.close(std.testing.io);
        return err;
    };
    selected.close(std.testing.io);
    defer watcher.destroy() catch unreachable;
    try tmp.dir.rename("selected", tmp.dir, "moved", std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "moved/file.txt", .data = "same directory object" });
    try awaitHint(watcher);
}

test "Windows editor directory watch resumes after actual completed cancellation with a conservative rescan" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const watcher = try Watcher.create(std.testing.allocator, tmp.dir);
    defer watcher.destroy() catch unreachable;
    try std.testing.expect(CancelIoEx(watcher.handle, &watcher.overlapped).toBool());
    var bytes: u32 = 0;
    try std.testing.expect(!GetOverlappedResult(watcher.handle, &watcher.overlapped, &bytes, .TRUE).toBool());
    try std.testing.expectEqual(w.Win32Error.OPERATION_ABORTED, w.GetLastError());
    try std.testing.expectError(error.WatchCancelled, watcher.poll());
    try std.testing.expect(!watcher.pending);
    try std.testing.expect(try watcher.poll());
    try std.testing.expect(watcher.pending);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "after.txt", .data = "after cancellation" });
    try awaitHint(watcher);
}

fn allocationPrefix(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const watcher = try Watcher.create(a, dir);
    try watcher.destroy();
}

test "Windows editor directory watch allocation prefixes never strand native handles or pending storage" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{tmp.dir});
}

test "Windows editor directory watch groups deduplicate identity but issue independently revocable members" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var groups: Groups = .{ .allocator = std.testing.allocator };
    defer groups.deinit() catch unreachable;
    const first = try groups.acquire(tmp.dir);
    const second = try groups.acquire(tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), groups.entries.items.len);
    try std.testing.expect(first.id != second.id);
    const hint: GroupKey = .{ .owner = &groups, .id = first.id };
    try std.testing.expect(try groups.receives(first, hint));
    try std.testing.expect(try groups.receives(second, hint));
    try groups.release(first);
    try std.testing.expectError(error.StaleWatchLease, groups.receives(first, hint));
    try std.testing.expect(try groups.receives(second, hint));
    try std.testing.expectError(error.StaleWatchLease, groups.release(first));
    try std.testing.expectEqual(@as(usize, 1), groups.entries.items[0].references);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "survivor.txt", .data = "surviving document" });
    try awaitHint(groups.entries.items[0].watcher);
    try groups.release(second);
    try std.testing.expectEqual(@as(usize, 0), groups.entries.items.len);
}

test "Windows editor directory watch group capacity counts directories instead of documents and recovers after release" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    var groups: Groups = .{ .allocator = std.testing.allocator, .limit = 1 };
    defer groups.deinit() catch unreachable;
    const one = try groups.acquire(first.dir);
    const peer = try groups.acquire(first.dir);
    try std.testing.expectError(error.TooManyDirectoryWatches, groups.acquire(second.dir));
    try groups.release(one);
    try std.testing.expectError(error.TooManyDirectoryWatches, groups.acquire(second.dir));
    try groups.release(peer);
    const fresh = try groups.acquire(second.dir);
    try std.testing.expect(!(try groups.receives(fresh, .{ .owner = &groups, .id = one.id })));
    try std.testing.expect(try groups.receives(fresh, .{ .owner = &groups, .id = fresh.id }));
    try std.testing.expectError(error.StaleWatchLease, groups.release(one));
    try groups.release(fresh);
}

test "Windows editor directory watch group refuses foreign owner and exhausted generation without changing references" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var one: Groups = .{ .allocator = std.testing.allocator };
    defer one.deinit() catch unreachable;
    var two: Groups = .{ .allocator = std.testing.allocator };
    defer two.deinit() catch unreachable;
    const lease = try one.acquire(tmp.dir);
    const other = try two.acquire(tmp.dir);
    try std.testing.expect(!(try two.receives(other, .{ .owner = &one, .id = lease.id })));
    try std.testing.expectError(error.StaleWatchLease, two.receives(lease, .{ .owner = &two, .id = other.id }));
    try std.testing.expectError(error.StaleWatchLease, two.release(lease));
    one.issued = std.math.maxInt(u64);
    try std.testing.expectError(error.WatchGenerationExhausted, one.acquire(tmp.dir));
    try std.testing.expectEqual(@as(usize, 1), one.entries.items[0].references);
    try two.release(other);
    try one.release(lease);
}

test "Windows editor directory watch group debounces a native event before publishing its directory identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var groups: Groups = .{ .allocator = std.testing.allocator };
    defer groups.deinit() catch unreachable;
    const lease = try groups.acquire(tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "changed" });
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!groups.entries.items[0].dirty and std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        try std.testing.expect(groups.poll(0) == null);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(groups.entries.items[0].dirty);
    // Creation and writing can complete separate native notifications. Drain
    // those at the same logical time before checking the quiet-period boundary.
    for (0..20) |_| {
        try io.sleep(.fromMilliseconds(1), .awake);
        try std.testing.expect(groups.poll(0) == null);
    }
    try std.testing.expect(groups.poll(Groups.debounce_ns - 1) == null);
    const notice = groups.poll(Groups.debounce_ns) orelse return error.MissingDirectoryHint;
    try std.testing.expect(notice.problem == null and notice.group.owner == &groups);
    try std.testing.expectEqual(groups.members.items[0].group_id, notice.group.id);
    try std.testing.expect(groups.poll(Groups.debounce_ns) == null);
    try groups.release(lease);
}

fn groupAllocationPrefix(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    var groups: Groups = .{ .allocator = a };
    defer groups.deinit() catch unreachable;
    const one = try groups.acquire(dir);
    const peer = try groups.acquire(dir);
    try groups.release(one);
    try groups.release(peer);
}

test "Windows editor directory watch group allocation prefixes never publish stranded subscriptions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, groupAllocationPrefix, .{tmp.dir});
}

// Inspect only completed test I/O, before re-arm can let the kernel overwrite
// its buffer. Production consumers continue to treat every payload as a hint.
fn awaitNamedHint(watcher: *Watcher, expected: []const u8) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        var bytes: u32 = 0;
        if (!GetOverlappedResult(watcher.handle, &watcher.overlapped, &bytes, .FALSE).toBool()) {
            if (w.GetLastError() != .IO_INCOMPLETE) return error.WatchReadFailed;
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }
        watcher.pending = false;
        var matched = false;
        var offset: usize = 0;
        while (offset + 12 <= bytes) {
            const entry = watcher.buffer[offset..bytes];
            const next = std.mem.readInt(u32, entry[0..4], .little);
            const length = std.mem.readInt(u32, entry[8..12], .little);
            if (length > entry.len - 12) break;
            if (length == expected.len * 2) {
                matched = true;
                for (expected, 0..) |character, i| {
                    const encoded = entry[12 + i * 2 ..][0..2];
                    if (std.mem.readInt(u16, encoded, .little) != character) matched = false;
                }
            }
            if (matched or next == 0 or next > entry.len) break;
            offset += next;
        }
        try watcher.arm();
        if (matched) return;
    }
    return error.MissingNamedDirectoryHint;
}

test "Windows editor directory watch recursive root observes nested create and delete" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.createDir(io, "nested/deep", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deep/existing.txt", .data = "before" });
    const watcher = try Watcher.createRecursive(std.testing.allocator, tmp.dir);
    defer watcher.destroy() catch unreachable;
    // NTFS may complete setup metadata notifications after handle creation.
    // Drain them before attributing any completion to the deep file write.
    var quiet_since = std.Io.Clock.awake.now(io).nanoseconds;
    const quiet_deadline = quiet_since + 5 * std.time.ns_per_s;
    while (true) {
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (try watcher.poll()) quiet_since = now;
        if (now - quiet_since >= 250 * std.time.ns_per_ms) break;
        if (now >= quiet_deadline) return error.WatchNeverSettled;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // A root-only watch can report the immediate directory's metadata when
    // its children are added. An existing file two levels down distinguishes
    // subtree delivery from that incidental parent notification.
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deep/existing.txt", .data = "after" });
    try awaitNamedHint(watcher, "nested\\deep\\existing.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/new.txt", .data = "new" });
    try awaitHint(watcher);
    try tmp.dir.deleteFile(io, "nested/new.txt");
    try awaitHint(watcher);
}
