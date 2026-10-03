//! Test-only native namespace attacker. Every path stays in a disposable root.
const std = @import("std");
const maru = @import("maru");
const w = std.os.windows;
const abi = maru.win32_abi;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn DeviceIoControl(w.HANDLE, u32, ?*const anyopaque, u32, ?*anyopaque, u32, *u32, ?*anyopaque) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn MoveFileW([*:0]const u16, [*:0]const u16) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn GetLastError() callconv(abi.winapi) u32;

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    junction: bool = false,
    pub fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "grant/nested");
        try tmp.dir.createDirPath(std.testing.io, "outside");
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "grant/nested/original.txt", .data = "original-long-content" });
        return .{ .tmp = tmp };
    }
    pub fn deinit(self: *Fixture) void {
        // Remove the tag before recursive cleanup can traverse its destination.
        if (self.junction) self.clear() catch @panic("fixture junction cleanup failed");
        self.tmp.cleanup();
    }
    fn wide(self: *Fixture, child: []const u8) ![:0]u16 {
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(std.testing.io, &root);
        const path = try std.fs.path.join(std.testing.allocator, &.{ root[0..n], child });
        defer std.testing.allocator.free(path);
        return std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    }
    fn parent(self: *Fixture) !w.HANDLE {
        const path = try self.wide("grant/nested");
        defer std.testing.allocator.free(path);
        const handle = CreateFileW(path, 0x40000000, 3, null, 3, 0x02200000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return error.FixtureOpenFailed;
        return handle;
    }
    pub fn escape(self: *Fixture) !void {
        try self.tmp.dir.rename("grant/nested/original.txt", self.tmp.dir, "outside/original.txt", std.testing.io);
        const destination = try self.wide("outside");
        defer std.testing.allocator.free(destination);
        const handle = try self.parent();
        defer _ = w.ntdll.NtClose(handle);
        // SDK REPARSE_DATA_BUFFER mount-point layout: offsets and lengths are bytes.
        // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer
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
        if (n + 2 > data.path.len) return error.FixturePathTooLong;
        @memcpy(data.path[0..prefix.len], prefix);
        @memcpy(data.path[prefix.len..n], destination);
        data.substitute_length = @intCast(n * 2);
        data.print_offset = @intCast((n + 1) * 2);
        data.length = @intCast(8 + (n + 2) * 2);
        var returned: u32 = 0;
        if (!DeviceIoControl(handle, 0x900a4, &data, 8 + @as(u32, data.length), null, 0, &returned, null).toBool()) return error.FixtureJunctionFailed;
        self.junction = true;
    }
    pub fn clear(self: *Fixture) !void {
        const handle = try self.parent();
        defer _ = w.ntdll.NtClose(handle);
        const data: extern struct { tag: u32 = 0xa0000003, length: u16 = 0, reserved: u16 = 0 } = .{};
        var returned: u32 = 0;
        if (!DeviceIoControl(handle, 0x900ac, &data, @sizeOf(@TypeOf(data)), null, 0, &returned, null).toBool()) return error.FixtureJunctionCleanupFailed;
        self.junction = false;
    }
    pub fn returnOriginalError(self: *Fixture) !u32 {
        const from = try self.wide("outside/original.txt");
        defer std.testing.allocator.free(from);
        const to = try self.wide("grant/nested/original.txt");
        defer std.testing.allocator.free(to);
        if (MoveFileW(from, to).toBool()) return 0;
        return GetLastError();
    }
    pub fn expectOriginal(self: *Fixture) !void {
        const bytes = try self.tmp.dir.readFileAlloc(std.testing.io, "outside/original.txt", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("original-long-content", bytes);
    }
};
