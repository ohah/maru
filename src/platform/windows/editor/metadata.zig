//! Handle-bound cloning into an unpublished stage. This is not a publish permit:
//! BackupRead/Write omit audit SACLs without ACCESS_SYSTEM_SECURITY.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const abi = @import("maru").win32_abi;
const staging = @import("stage.zig");

extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn BackupRead(w.HANDLE, ?[*]u8, u32, *u32, w.BOOL, w.BOOL, *?*anyopaque) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn BackupWrite(w.HANDLE, ?[*]const u8, u32, *u32, w.BOOL, w.BOOL, *?*anyopaque) callconv(abi.winapi) w.BOOL;
extern "ntdll" fn NtQuerySecurityObject(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(abi.winapi) w.NTSTATUS;
extern "ntdll" fn NtSetSecurityObject(w.HANDLE, u32, *const anyopaque) callconv(abi.winapi) w.NTSTATUS;

// Native user-mode counterparts of the WDK EA routines (same counted FILE_FULL_EA_INFORMATION).
// https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-zwseteafile
extern "ntdll" fn NtSetEaFile(w.HANDLE, *w.IO_STATUS_BLOCK, *const anyopaque, u32) callconv(abi.winapi) w.NTSTATUS;
extern "ntdll" fn NtQueryEaFile(w.HANDLE, *w.IO_STATUS_BLOCK, *anyopaque, u32, w.BOOLEAN, ?*const anyopaque, u32, ?*u32, w.BOOLEAN) callconv(abi.winapi) w.NTSTATUS;

pub const Error = error{ UnsupportedPlatform, SourceBusy, QueryFailed, UnsupportedMetadata, ReadFailed, WriteFailed, TruncatedBackup, UnsafeStream, SourceChanged };

pub const Source = struct {
    file: std.Io.File,
    basic: w.FILE.BASIC_INFORMATION,
    identity: w.LARGE_INTEGER,
    size: w.LARGE_INTEGER,

    pub fn open(original: std.Io.File) Error!Source {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        // Reopen the object, not its old pathname. READ-only sharing fences new
        // writers and deletion while cloning. Existing writable handles reject us.
        const handle = ReOpenFile(original.handle, 0x80000000, 1, 0x02200000);
        if (handle == w.INVALID_HANDLE_VALUE) return error.SourceBusy;
        errdefer _ = w.ntdll.NtClose(handle);
        const basic = try query(w.FILE.BASIC_INFORMATION, handle, .Basic);
        const standard = try query(w.FILE.STANDARD_INFORMATION, handle, .Standard);
        if (standard.Directory.toBool() or standard.NumberOfLinks != 1) return error.UnsupportedMetadata;
        // These attributes need distinct native operations, not a BASIC bit copy.
        // Fail the unpublished clone rather than silently dropping them.
        if (basic.FileAttributes.REPARSE_POINT or basic.FileAttributes.ENCRYPTED or basic.FileAttributes.COMPRESSED or basic.FileAttributes.SPARSE_FILE or basic.FileAttributes.READONLY) return error.UnsupportedMetadata;
        return .{ .file = .{ .handle = handle, .flags = .{ .nonblocking = false } }, .basic = basic, .identity = (try query(w.FILE.INTERNAL_INFORMATION, handle, .Internal)).IndexNumber, .size = standard.EndOfFile };
    }

    pub fn deinit(self: *Source, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }

    fn checkStable(self: *const Source) Error!void {
        const now = try query(w.FILE.BASIC_INFORMATION, self.file.handle, .Basic);
        const standard = try query(w.FILE.STANDARD_INFORMATION, self.file.handle, .Standard);
        if (self.basic.ChangeTime != now.ChangeTime or self.basic.LastWriteTime != now.LastWriteTime or @as(u32, @bitCast(self.basic.FileAttributes)) != @as(u32, @bitCast(now.FileAttributes)) or standard.EndOfFile != self.size or standard.NumberOfLinks != 1) return error.SourceChanged;
    }
};

fn query(comptime T: type, handle: w.HANDLE, class: w.FILE.INFORMATION_CLASS) Error!T {
    var status: w.IO_STATUS_BLOCK = undefined;
    var value: T = undefined;
    if (w.ntdll.NtQueryInformationFile(handle, &status, &value, @sizeOf(T), class) != .SUCCESS) return error.QueryFailed;
    return value;
}

fn Reader(comptime Api: type) type {
    return struct {
        handle: w.HANDLE,
        context: ?*anyopaque = null,
        buffer: [64 * 1024]u8 = undefined,
        cursor: usize = 0,
        len: usize = 0,

        fn deinit(self: *@This()) void {
            var ignored: u32 = 0;
            _ = Api.read(self.handle, null, 0, &ignored, .TRUE, .FALSE, &self.context);
        }

        fn exact(self: *@This(), out: []u8, eof_ok: bool) Error!bool {
            var n: usize = 0;
            while (n < out.len) {
                if (self.cursor == self.len) {
                    var read: u32 = 0;
                    if (!Api.read(self.handle, &self.buffer, self.buffer.len, &read, .FALSE, .TRUE, &self.context).toBool()) return error.ReadFailed;
                    if (read > self.buffer.len) return error.ReadFailed;
                    if (read == 0) {
                        if (eof_ok and n == 0) return false;
                        return error.TruncatedBackup;
                    }
                    self.cursor = 0;
                    self.len = read;
                }
                const take = @min(out.len - n, self.len - self.cursor);
                @memcpy(out[n..][0..take], self.buffer[self.cursor..][0..take]);
                self.cursor += take;
                n += take;
            }
            return true;
        }
    };
}

fn Writer(comptime Api: type) type {
    return struct {
        handle: w.HANDLE,
        context: ?*anyopaque = null,
        buffer: [64 * 1024]u8 = undefined,
        len: usize = 0,

        fn deinit(self: *@This()) void {
            var ignored: u32 = 0;
            _ = Api.write(self.handle, null, 0, &ignored, .TRUE, .FALSE, &self.context);
        }

        fn feed(self: *@This(), bytes: []const u8) Error!void {
            var n: usize = 0;
            while (n < bytes.len) {
                const take = @min(bytes.len - n, self.buffer.len - self.len);
                @memcpy(self.buffer[self.len..][0..take], bytes[n..][0..take]);
                n += take;
                self.len += take;
                if (self.len == self.buffer.len) try self.flush();
            }
        }

        fn flush(self: *@This()) Error!void {
            var n: usize = 0;
            while (n < self.len) {
                var written: u32 = 0;
                if (!Api.write(self.handle, self.buffer[n..].ptr, @intCast(self.len - n), &written, .FALSE, .TRUE, &self.context).toBool()) return error.WriteFailed;
                if (written == 0 or written > self.len - n) return error.WriteFailed;
                n += written;
            }
            self.len = 0;
        }
    };
}

// WIN32_STREAM_ID has a 20-byte prefix, followed by counted UTF-16 name and data.
// Never replay LINK or REPARSE records: those can alter namespace outside the owned file.
// https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-win32_stream_id
fn validateStream(id: u32, name: []const u8) Error!void {
    if (id < 1 or id > 4) return error.UnsupportedMetadata;
    if (id != 4) {
        if (name.len != 0) return error.UnsafeStream;
        return;
    }
    if (name.len < 16 or name.len % 2 != 0 or name.len > 65534) return error.UnsafeStream;
    const suffix = [_]u16{ ':', '$', 'D', 'A', 'T', 'A' };
    const units = name.len / 2;
    if (std.mem.readInt(u16, name[0..2], .little) != ':') return error.UnsafeStream;
    for (suffix, 0..) |ch, i| {
        const offset = (units - suffix.len + i) * 2;
        if (std.mem.readInt(u16, name[offset..][0..2], .little) != ch) return error.UnsafeStream;
    }
    for (1..units - suffix.len) |i| {
        const ch = std.mem.readInt(u16, name[i * 2 ..][0..2], .little);
        if (ch == 0 or ch == '/' or ch == '\\' or ch == ':') return error.UnsafeStream;
    }
}

pub const Report = struct {
    streams: usize = 0,
    security_streams: usize = 0,
    named_streams: usize = 0,
    // A publisher must resolve this gap; readable ACL cloning is not full audit coverage.
    audit_complete: bool = false,
};

/// Clone readable owner/group/DACL, primary data, EAs and ADS into the owned stage.
/// The caller still owns cleanup and must not interpret this as permission to publish.
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-backupread
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-backupwrite
const Native = struct {
    const read = BackupRead;
    const write = BackupWrite;
};

pub fn cloneReadable(source: *const Source, stage: *staging.Stage) Error!Report {
    return cloneFor(source, stage, Native);
}

fn cloneFor(source: *const Source, stage: *staging.Stage, comptime Api: type) Error!Report {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    try source.checkStable();
    var reader: Reader(Api) = .{ .handle = source.file.handle };
    defer reader.deinit();
    var writer: Writer(Api) = .{ .handle = stage.file.handle };
    defer writer.deinit();
    var header: [20]u8 = undefined;
    var name_buffer: [65534]u8 = undefined;
    var data: [64 * 1024]u8 = undefined;
    var report: Report = .{};
    while (try reader.exact(&header, true)) {
        const id = std.mem.readInt(u32, header[0..4], .little);
        const size = std.mem.readInt(u64, header[8..16], .little);
        const name_size = std.mem.readInt(u32, header[16..20], .little);
        if (size > std.math.maxInt(i64) or name_size > name_buffer.len or name_size % 2 != 0) return error.UnsafeStream;
        const name = name_buffer[0..name_size];
        _ = try reader.exact(name, false);
        try validateStream(id, name);
        try writer.feed(&header);
        try writer.feed(name);
        var remaining = size;
        while (remaining != 0) {
            const part = data[0..@as(usize, @intCast(@min(remaining, data.len)))];
            _ = try reader.exact(part, false);
            try writer.feed(part);
            remaining -= part.len;
        }
        report.streams += 1;
        if (id == 3) report.security_streams += 1;
        if (id == 4) report.named_streams += 1;
    }
    if (report.security_streams != 1) return error.ReadFailed;
    try writer.flush();
    try source.checkStable();
    var basic = source.basic;
    // New content gets a new write/change time; preserve creation/access and flags.
    basic.LastWriteTime = 0;
    basic.ChangeTime = 0;
    var status: w.IO_STATUS_BLOCK = undefined;
    if (w.ntdll.NtSetInformationFile(stage.file.handle, &status, &basic, @sizeOf(@TypeOf(basic)), .Basic) != .SUCCESS) return error.WriteFailed;
    return report;
}

fn descriptor(handle: w.HANDLE, buffer: []u8) ![]u8 {
    var needed: u32 = 0;
    if (NtQuerySecurityObject(handle, 7, buffer.ptr, @intCast(buffer.len), &needed) != .SUCCESS or needed > buffer.len) return error.QueryFailed;
    return buffer[0..needed];
}

fn dacl(sd: []const u8) []const u8 {
    const offset = std.mem.readInt(u32, sd[16..20], .little);
    if (offset == 0) return &.{};
    const size = std.mem.readInt(u16, sd[offset + 2 ..][0..2], .little);
    return sd[offset..][0..size];
}

fn sidAt(sd: []const u8, field: usize) []const u8 {
    const offset = std.mem.readInt(u32, sd[field..][0..4], .little);
    if (offset == 0) return &.{};
    return sd[offset..][0 .. 8 + @as(usize, sd[offset + 1]) * 4];
}

fn makeOwnerOnly(original: std.Io.File) !void {
    const handle = ReOpenFile(original.handle, 0x10000000, 7, 0x02200000);
    if (handle == w.INVALID_HANDLE_VALUE) return error.SourceBusy;
    defer _ = w.ntdll.NtClose(handle);
    var current: [4096]u8 align(4) = undefined;
    const sd = try descriptor(handle, &current);
    const owner = sidAt(sd, 4);
    var custom: [1024]u8 align(4) = @splat(0);
    custom[0] = 1;
    std.mem.writeInt(u16, custom[2..4], 0x9004, .little); // self-relative, DACL present/protected
    std.mem.writeInt(u32, custom[16..20], 20, .little);
    custom[20] = 2;
    const acl_size: u16 = @intCast(8 + 8 + owner.len);
    std.mem.writeInt(u16, custom[22..24], acl_size, .little);
    std.mem.writeInt(u16, custom[24..26], 1, .little);
    // One explicit ACCESS_ALLOWED ACE for the source's actual owner.
    std.mem.writeInt(u16, custom[30..32], @intCast(8 + owner.len), .little);
    std.mem.writeInt(u32, custom[32..36], 0x001f01ff, .little);
    @memcpy(custom[36..][0..owner.len], owner);
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, NtSetSecurityObject(handle, 0x80000004, &custom));
    var ea: [20]u8 align(4) = @splat(0);
    ea[5] = 3;
    std.mem.writeInt(u16, ea[6..8], 8, .little);
    @memcpy(ea[8..11], "Tag");
    @memcpy(ea[12..20], "ea-value");
    var ea_status: w.IO_STATUS_BLOCK = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, NtSetEaFile(handle, &ea_status, &ea, ea.len));
    var basic = try query(w.FILE.BASIC_INFORMATION, handle, .Basic);
    basic.CreationTime = 132000000000000000;
    basic.FileAttributes.HIDDEN = true;
    var status: w.IO_STATUS_BLOCK = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtSetInformationFile(handle, &status, &basic, @sizeOf(@TypeOf(basic)), .Basic));
}

test "Windows safe save metadata clones owner DACL creation flags and large named streams" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "original primary" });
    const large = try allocator.alloc(u8, 131079);
    defer allocator.free(large);
    for (large, 0..) |*ch, i| ch.* = @truncate(i);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt:meta", .data = large });
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt:second", .data = "second stream" });
    var pinned = try @import("maru").win32_relative_file.open(allocator, tmp.dir, "source.txt");
    defer pinned.deinit(io);
    try makeOwnerOnly(pinned.original);
    var source = try Source.open(pinned.original);
    defer source.deinit(io);
    var stage = try staging.create(allocator, io, &pinned);
    defer stage.deinit(io);
    var before_buf: [4096]u8 align(4) = undefined;
    var after_buf: [4096]u8 align(4) = undefined;
    const before = try descriptor(source.file.handle, &before_buf);
    const report = try cloneReadable(&source, &stage);
    try std.testing.expectEqual(@as(usize, 1), report.security_streams);
    try std.testing.expectEqual(@as(usize, 2), report.named_streams);
    try std.testing.expect(!report.audit_complete);
    const after = try descriptor(stage.file.handle, &after_buf);
    try std.testing.expectEqual(std.mem.readInt(u16, before[2..4], .little) & 0x1000, std.mem.readInt(u16, after[2..4], .little) & 0x1000);
    try std.testing.expectEqualSlices(u8, dacl(before), dacl(after));
    try std.testing.expectEqualSlices(u8, sidAt(before, 4), sidAt(after, 4));
    try std.testing.expectEqualSlices(u8, sidAt(before, 8), sidAt(after, 8));
    var ea_buf: [256]u8 align(4) = undefined;
    var ea_status: w.IO_STATUS_BLOCK = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, NtQueryEaFile(stage.file.handle, &ea_status, &ea_buf, ea_buf.len, .TRUE, null, 0, null, .TRUE));
    try std.testing.expectEqual(@as(u8, 3), ea_buf[5]);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, ea_buf[6..8], .little));
    var source_ea: [256]u8 align(4) = undefined;
    var source_ea_status: w.IO_STATUS_BLOCK = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, NtQueryEaFile(source.file.handle, &source_ea_status, &source_ea, source_ea.len, .TRUE, null, 0, null, .TRUE));
    // NTFS canonicalizes EA names to uppercase; compare actual source metadata.
    try std.testing.expectEqualSlices(u8, source_ea[0..source_ea_status.Information], ea_buf[0..ea_status.Information]);
    try std.testing.expectEqualStrings("ea-value", ea_buf[12..20]);
    const basic = try query(w.FILE.BASIC_INFORMATION, stage.file.handle, .Basic);
    try std.testing.expect(basic.FileAttributes.HIDDEN);
    try std.testing.expectEqual(source.basic.CreationTime, basic.CreationTime);
    var primary: [64]u8 = undefined;
    try std.testing.expectEqualStrings("original primary", primary[0..try stage.file.readPositionalAll(io, &primary, 0)]);
    try stage.write(io, "new");
    try std.testing.expectEqualStrings("new", primary[0..try stage.file.readPositionalAll(io, &primary, 0)]);
    // ADS share checks differ from the primary stream; read them while the owned stage stays open.
    const meta_name = try std.fmt.allocPrint(allocator, "{s}:meta", .{stage.name});
    defer allocator.free(meta_name);
    const meta = try pinned.parent().openFile(io, meta_name, .{});
    defer meta.close(io);
    const copied = try allocator.alloc(u8, large.len + 1);
    defer allocator.free(copied);
    try std.testing.expectEqualSlices(u8, large, copied[0..try meta.readPositionalAll(io, copied, 0)]);
    try std.testing.expectEqualStrings("original primary", primary[0..try source.file.readPositionalAll(io, &primary, 0)]);
}

test "Windows safe save metadata source binds the original after namespace replacement and fences writers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "original" });
    var pinned = try @import("maru").win32_relative_file.open(std.testing.allocator, tmp.dir, "source.txt");
    defer pinned.deinit(io);
    try tmp.dir.rename("source.txt", tmp.dir, "displaced.txt", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "foreign" });
    var source = try Source.open(pinned.original);
    defer source.deinit(io);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("original", bytes[0..try source.file.readPositionalAll(io, &bytes, 0)]);
    if (tmp.dir.openFile(io, "displaced.txt", .{ .mode = .read_write })) |file| {
        file.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
    if (tmp.dir.rename("displaced.txt", tmp.dir, "again.txt", io)) |_| return error.TestUnexpectedResult else |_| {}
}

test "Windows safe save metadata source refuses an existing writer instead of racing it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "original" });
    var pinned = try @import("maru").win32_relative_file.open(std.testing.allocator, tmp.dir, "source.txt");
    defer pinned.deinit(io);
    const writer = try tmp.dir.openFile(io, "source.txt", .{ .mode = .read_write });
    defer writer.close(io);
    try std.testing.expectError(error.SourceBusy, Source.open(pinned.original));
}

test "Windows safe save metadata never replays namespace records or path-bearing stream names" {
    try std.testing.expectError(error.UnsupportedMetadata, validateStream(5, &.{}));
    try std.testing.expectError(error.UnsupportedMetadata, validateStream(8, &.{}));
    try std.testing.expectError(error.UnsupportedMetadata, validateStream(10, &.{}));
    try std.testing.expectError(error.UnsafeStream, validateStream(1, "named"));
    for ([_][]const u8{ ":a/b:$DATA", ":a\\b:$DATA", ":a:b:$DATA", "C:a:$DATA", ":a:$INDEX_ALLOCATION", ":$DATA" }) |name| {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, name);
        defer std.testing.allocator.free(wide);
        try std.testing.expectError(error.UnsafeStream, validateStream(4, std.mem.sliceAsBytes(wide)));
    }
    const valid = std.unicode.utf8ToUtf16LeStringLiteral(":meta:$DATA");
    try validateStream(4, std.mem.sliceAsBytes(valid));
}

test "Windows safe save metadata detects changed source attributes before copying" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "original" });
    var pinned = try @import("maru").win32_relative_file.open(std.testing.allocator, tmp.dir, "source.txt");
    defer pinned.deinit(io);
    var source = try Source.open(pinned.original);
    defer source.deinit(io);
    var stage = try staging.create(std.testing.allocator, io, &pinned);
    defer stage.deinit(io);
    // Attribute-only access is not fenced by Windows data sharing checks.
    // The stable metadata check must catch it independently of the data lock.
    const mutator = ReOpenFile(pinned.original.handle, 0x00100180, 1, 0x02200000);
    if (mutator == w.INVALID_HANDLE_VALUE) return error.SourceBusy;
    defer _ = w.ntdll.NtClose(mutator);
    var basic = source.basic;
    basic.FileAttributes.HIDDEN = true;
    var status: w.IO_STATUS_BLOCK = undefined;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, w.ntdll.NtSetInformationFile(mutator, &status, &basic, @sizeOf(@TypeOf(basic)), .Basic));
    try std.testing.expectError(error.SourceChanged, cloneReadable(&source, &stage));
    try std.testing.expectEqual(@as(u64, 0), (try stage.file.stat(io)).size);
}

test "Windows safe save metadata partial restore aborts both native contexts and removes the owned stage" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "original" });
    const large = try allocator.alloc(u8, 196617);
    defer allocator.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt:meta", .data = large });
    var pinned = try @import("maru").win32_relative_file.open(allocator, tmp.dir, "source.txt");
    defer pinned.deinit(io);
    var source = try Source.open(pinned.original);
    defer source.deinit(io);
    var stage = try staging.create(allocator, io, &pinned);
    var closed = false;
    defer if (!closed) stage.deinit(io);
    const name = try allocator.dupe(u8, stage.name);
    defer allocator.free(name);
    const Failure = struct {
        var writes: usize = 0;
        var read_aborts: usize = 0;
        var write_aborts: usize = 0;
        fn read(handle: w.HANDLE, bytes: ?[*]u8, len: u32, count: *u32, abort: w.BOOL, security: w.BOOL, context: *?*anyopaque) w.BOOL {
            if (abort.toBool()) read_aborts += 1;
            return BackupRead(handle, bytes, len, count, abort, security, context);
        }
        fn write(handle: w.HANDLE, bytes: ?[*]const u8, len: u32, count: *u32, abort: w.BOOL, security: w.BOOL, context: *?*anyopaque) w.BOOL {
            if (abort.toBool()) {
                write_aborts += 1;
            } else {
                writes += 1;
                // The first 64KiB restore is real and leaves an ADS restore in flight.
                if (writes == 2) return .FALSE;
            }
            return BackupWrite(handle, bytes, len, count, abort, security, context);
        }
    };
    Failure.writes = 0;
    Failure.read_aborts = 0;
    Failure.write_aborts = 0;
    try std.testing.expectError(error.WriteFailed, cloneFor(&source, &stage, Failure));
    stage.deinit(io);
    closed = true;
    if (pinned.parent().statFile(io, name, .{})) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.FileNotFound, err);
    try std.testing.expectEqual(@as(usize, 2), Failure.writes);
    try std.testing.expectEqual(@as(usize, 1), Failure.read_aborts);
    try std.testing.expectEqual(@as(usize, 1), Failure.write_aborts);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("original", bytes[0..try source.file.readPositionalAll(io, &bytes, 0)]);
}
