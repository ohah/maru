//! Full security snapshots for unpublished save stages. No pathname authority.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const abi = @import("maru").win32_abi;

extern "kernel32" fn ReOpenFile(w.HANDLE, u32, u32, u32) callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetLastError() callconv(abi.winapi) u32;
extern "ntdll" fn NtQuerySecurityObject(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(abi.winapi) w.NTSTATUS;
extern "ntdll" fn NtSetSecurityObject(w.HANDLE, u32, *const anyopaque) callconv(abi.winapi) w.NTSTATUS;
extern "ntdll" fn RtlValidRelativeSecurityDescriptor(*const anyopaque, u32, u32) callconv(abi.winapi) w.BOOLEAN;

// BACKUP_SECURITY_INFORMATION includes owner/group/DACL and the entire SACL.
// Its query and restore rights are specified by Microsoft SECURITY_INFORMATION:
// https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information
const full_information: u32 = 0x00010000;
const query_access: u32 = 0x01020000; // ACCESS_SYSTEM_SECURITY | READ_CONTROL
const restore_access: u32 = 0x010e0000; // plus WRITE_DAC | WRITE_OWNER
const descriptor_capacity = 64 * 1024; // NTFS descriptor limit, ZwQuerySecurityObject remarks.
pub const Error = std.mem.Allocator.Error || error{ UnsupportedPlatform, SecurityUnavailable, NativeOpenFailed, NativeQueryFailed, InvalidDescriptor, RestoreFailed, SecurityChanged };

const Native = struct {
    fn open(file: std.Io.File, access: u32) Error!w.HANDLE {
        const handle = ReOpenFile(file.handle, access, 7, 0x02200000);
        if (handle == w.INVALID_HANDLE_VALUE) return switch (GetLastError()) {
            5, 1314 => error.SecurityUnavailable, // ERROR_ACCESS_DENIED / ERROR_PRIVILEGE_NOT_HELD
            else => error.NativeOpenFailed,
        };
        return handle;
    }
    fn close(handle: w.HANDLE) void {
        _ = w.ntdll.NtClose(handle);
    }
    fn query(handle: w.HANDLE, mask: u32, buffer: []u8) Error!usize {
        var needed: u32 = 0;
        switch (NtQuerySecurityObject(handle, mask, buffer.ptr, @intCast(buffer.len), &needed)) {
            .SUCCESS => {},
            .ACCESS_DENIED, .PRIVILEGE_NOT_HELD => return error.SecurityUnavailable,
            else => return error.NativeQueryFailed,
        }
        return needed;
    }
    fn set(handle: w.HANDLE, mask: u32, bytes: []const u8) Error!void {
        if (NtSetSecurityObject(handle, mask, bytes.ptr) != .SUCCESS) return error.RestoreFailed;
    }
};

fn readFor(comptime Api: type, handle: w.HANDLE, buffer: []u8) Error![]const u8 {
    const len = try Api.query(handle, full_information, buffer);
    if (len < 20 or len > buffer.len) return error.InvalidDescriptor;
    if (!RtlValidRelativeSecurityDescriptor(buffer.ptr, @intCast(len), 0).toBool())
        return error.InvalidDescriptor;
    return buffer[0..len];
}

fn restoreMask(bytes: []const u8) u32 {
    const control = std.mem.readInt(u16, bytes[2..4], .little);
    // Restore protection explicitly, including unprotected ACLs. Never assume that
    // the temporary file inherited the source's protection policy.
    return full_information |
        (if (control & 0x1000 != 0) @as(u32, 0x80000000) else @as(u32, 0x20000000)) |
        (if (control & 0x2000 != 0) @as(u32, 0x40000000) else @as(u32, 0x10000000));
}

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    handle: w.HANDLE,
    bytes: []align(4) u8,

    pub fn capture(allocator: std.mem.Allocator, file: std.Io.File) Error!Snapshot {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        return captureFor(allocator, file, Native);
    }

    fn captureFor(allocator: std.mem.Allocator, file: std.Io.File, comptime Api: type) Error!Snapshot {
        const handle = try Api.open(file, query_access);
        errdefer Api.close(handle);
        var buffer: [descriptor_capacity]u8 align(4) = undefined;
        const bytes = try readFor(Api, handle, &buffer);
        const owned = try allocator.alignedAlloc(u8, .@"4", bytes.len);
        @memcpy(owned, bytes);
        return .{ .allocator = allocator, .handle = handle, .bytes = owned };
    }

    pub fn deinit(self: *Snapshot) void {
        self.deinitFor(Native);
    }
    fn deinitFor(self: *Snapshot, comptime Api: type) void {
        Api.close(self.handle);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn check(self: *const Snapshot) Error!void {
        return self.checkFor(Native);
    }
    fn checkFor(self: *const Snapshot, comptime Api: type) Error!void {
        var buffer: [descriptor_capacity]u8 align(4) = undefined;
        const now = try readFor(Api, self.handle, &buffer);
        if (!std.mem.eql(u8, self.bytes, now)) return error.SecurityChanged;
    }

    pub fn restore(self: *const Snapshot, stage: std.Io.File) Error!void {
        return self.restoreFor(stage, Native);
    }
    fn restoreFor(self: *const Snapshot, stage: std.Io.File, comptime Api: type) Error!void {
        try self.checkFor(Api);
        const handle = try Api.open(stage, restore_access);
        defer Api.close(handle);
        try Api.set(handle, restoreMask(self.bytes), self.bytes);
        var buffer: [descriptor_capacity]u8 align(4) = undefined;
        const restored = try readFor(Api, handle, &buffer);
        if (!std.mem.eql(u8, self.bytes, restored)) return error.RestoreFailed;
        try self.checkFor(Api);
    }
};

// The I/O fault adapter uses real relative-descriptor validation. It exercises
// access masks, ownership, protection and both sides of the restore boundary.
const Fixture = struct {
    var closes: usize = 0;
    var writes: usize = 0;
    var changed: bool = false;
    var corrupt_restore: bool = false;
    var deny: bool = false;
    var change_on_write: bool = false;
    var protection: u16 = 0x3000;
    fn reset() void {
        closes = 0;
        writes = 0;
        changed = false;
        corrupt_restore = false;
        deny = false;
        change_on_write = false;
        protection = 0x3000;
    }
    fn open(file: std.Io.File, access: u32) Error!w.HANDLE {
        if (deny) return error.SecurityUnavailable;
        std.testing.expectEqual(if (@intFromPtr(file.handle) == 1) @as(u32, 0x01020000) else @as(u32, 0x010e0000), access) catch return error.InvalidDescriptor;
        return file.handle;
    }
    fn close(_: w.HANDLE) void {
        closes += 1;
    }
    fn query(handle: w.HANDLE, mask: u32, buffer: []u8) Error!usize {
        std.testing.expectEqual(@as(u32, 0x00010000), mask) catch return error.InvalidDescriptor;
        @memset(buffer[0..20], 0);
        buffer[0] = 1;
        var control: u16 = 0x8000 | protection;
        if ((changed and @intFromPtr(handle) == 1) or (corrupt_restore and @intFromPtr(handle) == 2)) control ^= 0x1000;
        std.mem.writeInt(u16, buffer[2..4], control, .little);
        return 20;
    }
    fn set(_: w.HANDLE, mask: u32, _: []const u8) Error!void {
        std.testing.expectEqual(full_information | (if (protection & 0x1000 != 0) @as(u32, 0x80000000) else @as(u32, 0x20000000)) | (if (protection & 0x2000 != 0) @as(u32, 0x40000000) else @as(u32, 0x10000000)), mask) catch return error.InvalidDescriptor;
        writes += 1;
        if (change_on_write) changed = true;
    }
};
fn fixtureFile(n: usize) std.Io.File {
    return .{ .handle = @ptrFromInt(n), .flags = .{ .nonblocking = false } };
}

test "Windows safe save full security requests all parts and restores protection" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_]u16{ 0, 0x1000, 0x2000, 0x3000 }) |protection| {
        Fixture.reset();
        Fixture.protection = protection;
        var snapshot = try Snapshot.captureFor(std.testing.allocator, fixtureFile(1), Fixture);
        try snapshot.restoreFor(fixtureFile(2), Fixture);
        snapshot.deinitFor(Fixture);
        try std.testing.expectEqual(@as(usize, 1), Fixture.writes);
        try std.testing.expectEqual(@as(usize, 2), Fixture.closes);
    }
}
test "Windows safe save full security rejects a changed source before restoring" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    Fixture.reset();
    var snapshot = try Snapshot.captureFor(std.testing.allocator, fixtureFile(1), Fixture);
    defer snapshot.deinitFor(Fixture);
    Fixture.changed = true;
    try std.testing.expectError(error.SecurityChanged, snapshot.restoreFor(fixtureFile(2), Fixture));
    try std.testing.expectEqual(@as(usize, 0), Fixture.writes);
}
test "Windows safe save full security verifies the restored descriptor" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    Fixture.reset();
    var snapshot = try Snapshot.captureFor(std.testing.allocator, fixtureFile(1), Fixture);
    defer snapshot.deinitFor(Fixture);
    Fixture.corrupt_restore = true;
    try std.testing.expectError(error.RestoreFailed, snapshot.restoreFor(fixtureFile(2), Fixture));
    try std.testing.expectEqual(@as(usize, 1), Fixture.closes);
}
test "Windows safe save full security detects a source change during restoration" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    Fixture.reset();
    var snapshot = try Snapshot.captureFor(std.testing.allocator, fixtureFile(1), Fixture);
    defer snapshot.deinitFor(Fixture);
    Fixture.change_on_write = true;
    try std.testing.expectError(error.SecurityChanged, snapshot.restoreFor(fixtureFile(2), Fixture));
    try std.testing.expectEqual(@as(usize, 1), Fixture.closes);
}
test "Windows safe save full security unavailable authority never restores" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    Fixture.reset();
    Fixture.deny = true;
    try std.testing.expectError(error.SecurityUnavailable, Snapshot.captureFor(std.testing.allocator, fixtureFile(1), Fixture));
    try std.testing.expectEqual(@as(usize, 0), Fixture.writes);
}
fn allocationFixture(allocator: std.mem.Allocator) !void {
    Fixture.reset();
    var snapshot = Snapshot.captureFor(allocator, fixtureFile(1), Fixture) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), Fixture.closes);
        return err;
    };
    snapshot.deinitFor(Fixture);
    try std.testing.expectEqual(@as(usize, 1), Fixture.closes);
}
test "Windows safe save full security releases authority after allocation failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}

test "Windows safe save full security owns an aligned descriptor after an odd allocation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    Fixture.reset();
    var storage: [128]u8 align(4) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    _ = try fixed.allocator().alloc(u8, 1);
    var snapshot = try Snapshot.captureFor(fixed.allocator(), fixtureFile(1), Fixture);
    defer snapshot.deinitFor(Fixture);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(snapshot.bytes.ptr) % 4);
}
