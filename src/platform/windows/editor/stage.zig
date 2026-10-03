//! Unpublished safe-save file. Cleanup follows the opened object, never a pathname.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const pinned_path = @import("maru").win32_relative_file;

pub const Error = std.mem.Allocator.Error || error{ UnsupportedPlatform, InvalidName, CreateFailed, NameCollision, RandomFailed };

pub const Stage = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    file: std.Io.File,

    pub fn deinit(self: *Stage, io: std.Io) void {
        // DELETE_ON_CLOSE owns this exact object even if an attempted operation failed.
        self.file.close(io);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn write(self: *Stage, io: std.Io, text: []const u8) !void {
        // Metadata cloning can leave an old primary stream. Positional replacement
        // plus exact length removes its suffix while leaving named streams alone.
        try self.file.writePositionalAll(io, text, 0);
        try self.file.setLength(io, text.len);
        try self.file.sync(io);
    }
};

// Microsoft NtCreateFile: CREATE rejects collisions; RootDirectory avoids reopening
// authority by string; DELETE_ON_CLOSE requires DELETE and removes the owned object.
// https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile
fn createNamed(allocator: std.mem.Allocator, parent: std.Io.Dir, name: []const u8) Error!Stage {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    for (name) |ch| if (ch == 0 or ch == ':' or ch == '/' or ch == '\\') return error.InvalidName;
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidName,
    };
    defer allocator.free(wide);
    if (wide.len > std.math.maxInt(u16) / 2) return error.InvalidName;
    var unicode: w.UNICODE_STRING = .{ .Length = @intCast(wide.len * 2), .MaximumLength = @intCast(wide.len * 2), .Buffer = wide.ptr };
    const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent.handle, .ObjectName = &unicode };
    var status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const result = w.ntdll.NtCreateFile(&handle, .{
        .SPECIFIC = .{ .FILE = .{ .READ_DATA = true, .WRITE_DATA = true, .READ_EA = true, .WRITE_EA = true, .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
        // A future metadata restore needs these rights on the already-owned file.
        .STANDARD = .{ .RIGHTS = .REQUIRED, .SYNCHRONIZE = true },
    }, &attrs, &status, null, .{}, .{}, .CREATE, .{
        .NON_DIRECTORY_FILE = true,
        .IO = .SYNCHRONOUS_NONALERT,
        .OPEN_REPARSE_POINT = true,
        .DELETE_ON_CLOSE = true,
    }, null, 0);
    if (result == .OBJECT_NAME_COLLISION) return error.NameCollision;
    if (result != .SUCCESS) return error.CreateFailed;
    errdefer _ = w.ntdll.NtClose(handle);
    return .{ .allocator = allocator, .name = try allocator.dupe(u8, name), .file = .{ .handle = handle, .flags = .{ .nonblocking = false } } };
}

/// The caller keeps the path pins alive through staging and the eventual commit.
pub fn create(allocator: std.mem.Allocator, io: std.Io, pinned: *const pinned_path.Pinned) Error!Stage {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        io.randomSecure(&random) catch return error.RandomFailed;
        const hex = std.fmt.bytesToHex(random, .lower);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, ".maru-save-{s}.tmp", .{hex}) catch unreachable;
        return createNamed(allocator, pinned.parent(), name) catch |err| switch (err) {
            error.NameCollision => continue,
            else => return err,
        };
    }
    return error.NameCollision;
}

fn expectAbsent(dir: std.Io.Dir, name: []const u8) !void {
    if (dir.statFile(std.testing.io, name, .{})) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.FileNotFound, err);
}

test "Windows safe save stage writes exact content and cleans the unpublished object" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    var pinned = try pinned_path.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var stage = try create(std.testing.allocator, io, &pinned);
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const name = try std.testing.allocator.dupe(u8, stage.name);
    defer std.testing.allocator.free(name);
    try stage.write(io, "long text to truncate");
    try stage.write(io, "new");
    var bytes: [64]u8 = undefined;
    const n = try stage.file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("new", bytes[0..n]);
    try std.testing.expectEqual(@as(u64, 3), (try stage.file.stat(io)).size);
    const old_n = try pinned.original.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("original", bytes[0..old_n]);
    stage.deinit(io);
    closed = true;
    try expectAbsent(pinned.parent(), name);
}

test "Windows safe save stage collision does not open or truncate an existing file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collision.tmp", .data = "foreign" });
    try std.testing.expectError(error.NameCollision, createNamed(std.testing.allocator, tmp.dir, "collision.tmp"));
    var bytes: [64]u8 = undefined;
    const file = try tmp.dir.openFile(std.testing.io, "collision.tmp", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqualStrings("foreign", bytes[0..try file.readPositionalAll(std.testing.io, &bytes, 0)]);
}

fn allocationPrefix(allocator: std.mem.Allocator, parent: std.Io.Dir) !void {
    var stage = createNamed(allocator, parent, "allocation.tmp") catch |err| {
        try expectAbsent(parent, "allocation.tmp");
        return err;
    };
    stage.deinit(std.testing.io);
    try expectAbsent(parent, "allocation.tmp");
}

test "Windows safe save stage unwinds kernel objects at every allocation failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefix, .{tmp.dir});
}

test "Windows safe save stage rejects traversal and cannot be reopened by another reader" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ".", "..", "../outside", "bad:stream", "a/b", "a\\b" }) |name| {
        try std.testing.expectError(error.InvalidName, createNamed(std.testing.allocator, tmp.dir, name));
    }
    var stage = try createNamed(std.testing.allocator, tmp.dir, "exclusive.tmp");
    defer stage.deinit(std.testing.io);
    if (tmp.dir.openFile(std.testing.io, "exclusive.tmp", .{})) |file| {
        file.close(std.testing.io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "Windows safe save stage carries native metadata restore access on its owned handle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stage = try createNamed(std.testing.allocator, tmp.dir, "metadata.tmp");
    defer stage.deinit(std.testing.io);
    var status: w.IO_STATUS_BLOCK = undefined;
    var access: w.FILE.ACCESS_INFORMATION = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtQueryInformationFile(stage.file.handle, &status, &access, @sizeOf(@TypeOf(access)), .Access));
    try std.testing.expect(access.AccessFlags.STANDARD.RIGHTS.READ_CONTROL);
    try std.testing.expect(access.AccessFlags.STANDARD.RIGHTS.WRITE_DAC);
    try std.testing.expect(access.AccessFlags.STANDARD.RIGHTS.WRITE_OWNER);
    try std.testing.expect(access.AccessFlags.SPECIFIC.FILE.READ_EA);
    try std.testing.expect(access.AccessFlags.SPECIFIC.FILE.WRITE_EA);
}

test "Windows safe save stage flush failure propagates and leaves the original unchanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "original.txt", .data = "original" });
    var pinned = try pinned_path.open(std.testing.allocator, tmp.dir, "original.txt");
    defer pinned.deinit(io);
    var stage = try createNamed(std.testing.allocator, pinned.parent(), "flush.tmp");
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const Failure = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    };
    // Every write still goes to the real native file. Only the durability operation fails.
    var vtable = io.vtable.*;
    vtable.fileSync = Failure.sync;
    var failing_io = io;
    failing_io.vtable = &vtable;
    try std.testing.expectError(error.InputOutput, stage.write(failing_io, "candidate"));
    var bytes: [64]u8 = undefined;
    const n = try pinned.original.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("original", bytes[0..n]);
    stage.deinit(io);
    closed = true;
    try expectAbsent(pinned.parent(), "flush.tmp");
}
