//! Native handle-relative traversal for editor safe-save. A save must keep these
//! handles alive through commit; checking a string and reopening it is not authority.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const abi = @import("maru").win32_abi;

pub const Error = std.mem.Allocator.Error || error{ InvalidPath, OpenFailed, ReparsePoint, NotRegular, HardLinked, UnsupportedPlatform };

pub const Pinned = struct {
    allocator: std.mem.Allocator,
    directories: std.ArrayList(w.HANDLE) = .empty,
    basename: []u8,
    original: std.Io.File,

    pub fn parent(self: *const Pinned) std.Io.Dir {
        return .{ .handle = self.directories.items[self.directories.items.len - 1] };
    }

    pub fn deinit(self: *Pinned, io: std.Io) void {
        self.original.close(io);
        for (self.directories.items) |handle| _ = w.ntdll.NtClose(handle);
        self.directories.deinit(self.allocator);
        self.allocator.free(self.basename);
        self.* = undefined;
    }
};

fn validSegment(segment: []const u8) bool {
    if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    // ADS, rooted/device namespaces and embedded NUL are not document names.
    for (segment) |ch| if (ch == ':' or ch == 0 or ch == '/' or ch == '\\') return false;
    return true;
}

fn validate(relative: []const u8) Error!void {
    var it = std.mem.splitAny(u8, relative, "/\\");
    while (it.next()) |segment| if (!validSegment(segment)) return error.InvalidPath;
}

// Microsoft NtCreateFile: RootDirectory + FILE_OPEN_REPARSE_POINT, and
// FILE_SHARE_DELETE controls whether competing deletion handles can open.
// https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile
fn openAt(allocator: std.mem.Allocator, parent: w.HANDLE, name: []const u8, directory: bool) Error!w.HANDLE {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPath,
    };
    defer allocator.free(wide);
    if (wide.len > std.math.maxInt(u16) / 2) return error.InvalidPath;
    var unicode: w.UNICODE_STRING = .{ .Length = @intCast(wide.len * 2), .MaximumLength = @intCast(wide.len * 2), .Buffer = wide.ptr };
    const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent, .ObjectName = &unicode };
    var status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const result = w.ntdll.NtCreateFile(&handle, .{
        .SPECIFIC = if (directory) .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true } } else .{ .FILE = .{ .READ_DATA = true, .READ_ATTRIBUTES = true } },
        .STANDARD = .{ .SYNCHRONIZE = true },
    }, &attrs, &status, null, .{}, .{
        .READ = true,
        .WRITE = true,
        // Directories stay pinned against rename/delete. The original leaf may be
        // atomically replaced by the later commit operation, so it shares delete.
        .DELETE = !directory,
    }, .OPEN, .{
        .DIRECTORY_FILE = directory,
        .NON_DIRECTORY_FILE = !directory,
        .IO = .SYNCHRONOUS_NONALERT,
        .OPEN_REPARSE_POINT = true,
    }, null, 0);
    if (result != .SUCCESS) return error.OpenFailed;
    errdefer _ = w.ntdll.NtClose(handle);
    var tag: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
    if (w.ntdll.NtQueryInformationFile(handle, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag) != .SUCCESS) return error.OpenFailed;
    if (tag.FileAttributes & 0x400 != 0) return error.ReparsePoint;
    var info: w.FILE.STANDARD_INFORMATION = undefined;
    if (w.ntdll.NtQueryInformationFile(handle, &status, &info, @sizeOf(@TypeOf(info)), .Standard) != .SUCCESS) return error.OpenFailed;
    if (info.Directory.toBool() != directory) return error.NotRegular;
    if (!directory and info.NumberOfLinks != 1) return error.HardLinked;
    return handle;
}

pub fn open(allocator: std.mem.Allocator, root: std.Io.Dir, relative: []const u8) Error!Pinned {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    try validate(relative);
    var dirs: std.ArrayList(w.HANDLE) = .empty;
    errdefer {
        for (dirs.items) |handle| _ = w.ntdll.NtClose(handle);
        dirs.deinit(allocator);
    }
    // NT names do not normalize "."; an empty relative name reopens the selected root.
    const root_handle = try openAt(allocator, root.handle, "", true);
    dirs.append(allocator, root_handle) catch |err| {
        _ = w.ntdll.NtClose(root_handle);
        return err;
    };
    var it = std.mem.splitAny(u8, relative, "/\\");
    var segment = it.next().?;
    while (it.next()) |next| {
        const child = try openAt(allocator, dirs.items[dirs.items.len - 1], segment, true);
        dirs.append(allocator, child) catch |err| {
            _ = w.ntdll.NtClose(child);
            return err;
        };
        segment = next;
    }
    const basename = try allocator.dupe(u8, segment);
    errdefer allocator.free(basename);
    const leaf = try openAt(allocator, dirs.items[dirs.items.len - 1], segment, false);
    return .{ .allocator = allocator, .directories = dirs, .basename = basename, .original = .{ .handle = leaf, .flags = .{ .nonblocking = false } } };
}

// These tests use disposable roots only; no repository file is modified.
test "Windows safe save rejects traversal ADS and device namespaces before I/O" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ "", "/a", "a/", "a//b", "../a", "a/../b", "a/./b", "C:\\a", "a:stream", "a\x00b", "\\\\?\\C:\\a" }) |path|
        try std.testing.expectError(error.InvalidPath, open(std.testing.allocator, std.Io.Dir.cwd(), path));
}

test "Windows safe save pins every parent and releases rename locks" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/한글.txt", .data = "original" });
    var pinned = try open(std.testing.allocator, tmp.dir, "a/b/한글.txt");
    var released = false;
    defer if (!released) pinned.deinit(io);
    var buffer: [64]u8 = undefined;
    const n = try pinned.original.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualStrings("original", buffer[0..n]);
    try std.testing.expectEqual(w.NTSTATUS.SHARING_VIOLATION, deletionProbe(tmp.dir.handle));
    // Keep the namespace check too; other descendants may also prevent rename.
    if (tmp.dir.rename("a", tmp.dir, "moved", io)) |_| return error.TestUnexpectedResult else |_| {}
    pinned.deinit(io);
    released = true;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, deletionProbe(tmp.dir.handle));
    try tmp.dir.rename("a", tmp.dir, "moved", io);
}

fn allocationPrefix(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    var pinned = open(allocator, root, "a/b/file.txt") catch |err| {
        // Heap accounting alone cannot see leaked kernel handles. A failed
        // prefix must also release every directory's DELETE-sharing lock.
        if (err == error.OutOfMemory) try std.testing.expectEqual(w.NTSTATUS.SUCCESS, deletionProbe(root.handle));
        return err;
    };
    defer pinned.deinit(std.testing.io);
}

test "Windows safe save traversal unwinds every allocation prefix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a/b");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a/b/file.txt", .data = "x" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{tmp.dir});
}

extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn DeviceIoControl(w.HANDLE, u32, ?*const anyopaque, u32, ?*anyopaque, u32, *u32, ?*anyopaque) callconv(abi.winapi) w.BOOL;

fn absoluteWide(allocator: std.mem.Allocator, dir: std.Io.Dir, child: []const u8) ![:0]u16 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &root);
    const path = try std.fs.path.join(allocator, &.{ root[0..n], child });
    defer allocator.free(path);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
}

test "Windows safe save rejects hard-linked originals without touching either name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "original" });
    const original = try absoluteWide(a, tmp.dir, "file.txt");
    defer a.free(original);
    const linked = try absoluteWide(a, tmp.dir, "other.txt");
    defer a.free(linked);
    if (!CreateHardLinkW(linked, original, null).toBool()) return error.TestUnexpectedResult;
    try expectRefused(error.HardLinked, a, tmp.dir, "file.txt");
    const bytes = try tmp.dir.readFileAlloc(io, "other.txt", a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("original", bytes);
}

fn makeJunction(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, target: []const u8) !void {
    const link = try absoluteWide(allocator, dir, name);
    defer allocator.free(link);
    const destination = try absoluteWide(allocator, dir, target);
    defer allocator.free(destination);
    const handle = CreateFileW(link, 0x40000000, 3, null, 3, 0x02200000, null);
    if (handle == w.INVALID_HANDLE_VALUE) return error.TestUnexpectedResult;
    defer _ = w.ntdll.NtClose(handle);
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer
    // Official REPARSE_DATA_BUFFER / mount-point layout. No shell or privileges
    // are needed for a junction; both target and link live inside the disposable root.
    var data: extern struct {
        tag: u32 = 0xa0000003,
        length: u16 = 0,
        reserved: u16 = 0,
        substitute_offset: u16 = 0,
        substitute_length: u16 = 0,
        print_offset: u16 = 0,
        print_length: u16 = 0,
        path: [4096]u16 = @splat(0),
    } = .{};
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    const n = prefix.len + destination.len;
    if (n + 2 > data.path.len) return error.TestUnexpectedResult;
    @memcpy(data.path[0..prefix.len], prefix);
    @memcpy(data.path[prefix.len..n], destination);
    data.substitute_length = @intCast(n * 2);
    data.print_offset = @intCast((n + 1) * 2);
    data.length = @intCast(8 + (n + 2) * 2);
    var returned: u32 = 0;
    if (!DeviceIoControl(handle, 0x000900a4, &data, 8 + @as(u32, data.length), null, 0, &returned, null).toBool()) return error.TestUnexpectedResult;
}

test "Windows safe save rejects intermediate junction instead of escaping the grant" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "grant/jump");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/file.txt", .data = "outside" });
    try makeJunction(a, tmp.dir, "grant/jump", "outside");
    var grant = try tmp.dir.openDir(io, "grant", .{});
    defer grant.close(io);
    try expectRefused(error.ReparsePoint, a, grant, "jump/file.txt");
    const bytes = try tmp.dir.readFileAlloc(io, "outside/file.txt", a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("outside", bytes);
}

fn expectRefused(expected: anyerror, allocator: std.mem.Allocator, root: std.Io.Dir, name: []const u8) !void {
    if (open(allocator, root, name)) |value| {
        var unexpected = value;
        unexpected.deinit(std.testing.io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(expected, err);
}

// Ask the kernel for DELETE access directly. A failed rename alone can be
// caused by descendants or unrelated locks and cannot prove SHARE_DELETE policy.
fn deletionProbe(root: w.HANDLE) w.NTSTATUS {
    var name = w.UNICODE_STRING{ .Length = 2, .MaximumLength = 2, .Buffer = @constCast(std.unicode.utf8ToUtf16LeStringLiteral("a").ptr) };
    const attrs = w.OBJECT.ATTRIBUTES{ .RootDirectory = root, .ObjectName = &name };
    var status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const result = w.ntdll.NtCreateFile(&handle, .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true } }, &attrs, &status, null, .{}, .{ .READ = true, .WRITE = true, .DELETE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true }, null, 0);
    if (result == .SUCCESS) _ = w.ntdll.NtClose(handle);
    return result;
}
