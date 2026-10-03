//! Assigned audit privilege on a duplicate current-thread token.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const abi = @import("maru").win32_abi;
extern "kernel32" fn GetCurrentProcess() callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetCurrentThread() callconv(abi.winapi) w.HANDLE;
extern "kernel32" fn GetCurrentThreadId() callconv(abi.winapi) u32;
extern "kernel32" fn GetLastError() callconv(abi.winapi) u32;
extern "advapi32" fn OpenProcessToken(w.HANDLE, u32, *w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn OpenThreadToken(w.HANDLE, u32, w.BOOL, *w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn DuplicateTokenEx(w.HANDLE, u32, ?*anyopaque, u32, u32, *w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn LookupPrivilegeValueW(?[*:0]const u16, [*:0]const u16, *Luid) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn AdjustTokenPrivileges(w.HANDLE, w.BOOL, *const Privileges, u32, ?*anyopaque, ?*u32) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn SetThreadToken(?*w.HANDLE, ?w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(abi.winapi) w.BOOL;
const Luid = extern struct { low: u32, high: i32 };
const Privileges = extern struct { count: u32 = 1, luid: Luid, attributes: u32 = 2 };
pub const Error = error{ UnsupportedPlatform, Unavailable, RestoreFailed, WrongThread };

// DuplicateTokenEx creates an independent token; AdjustTokenPrivileges cannot
// add an unassigned privilege. Only this duplicate is adjusted and attached.
// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-duplicatetokenex
// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges
pub const Scope = struct {
    previous: ?w.HANDLE,
    duplicate: w.HANDLE,
    thread: u32,

    pub fn enter() Error!Scope {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var previous: ?w.HANDLE = null;
        var base: w.HANDLE = undefined;
        if (OpenThreadToken(GetCurrentThread(), 14, .TRUE, &base).toBool()) {
            previous = base;
        } else {
            if (GetLastError() != 1008) return error.Unavailable; // ERROR_NO_TOKEN
            if (!OpenProcessToken(GetCurrentProcess(), 10, &base).toBool()) return error.Unavailable;
        }
        defer if (previous == null) {
            _ = w.ntdll.NtClose(base);
        };
        errdefer if (previous) |handle| {
            _ = w.ntdll.NtClose(handle);
        };
        var duplicate: w.HANDLE = undefined;
        // TOKEN_QUERY | TOKEN_IMPERSONATE | TOKEN_ADJUST_PRIVILEGES; level/type 2.
        if (!DuplicateTokenEx(base, 44, null, 2, 2, &duplicate).toBool()) return error.Unavailable;
        errdefer _ = w.ntdll.NtClose(duplicate);
        var luid: Luid = undefined;
        if (!LookupPrivilegeValueW(null, std.unicode.utf8ToUtf16LeStringLiteral("SeSecurityPrivilege"), &luid).toBool()) return error.Unavailable;
        const privileges: Privileges = .{ .luid = luid };
        if (!AdjustTokenPrivileges(duplicate, .FALSE, &privileges, 0, null, null).toBool() or GetLastError() != 0)
            return error.Unavailable;
        if (!SetThreadToken(null, duplicate).toBool()) return error.Unavailable;
        return .{ .previous = previous, .duplicate = duplicate, .thread = GetCurrentThreadId() };
    }

    pub fn leave(self: *Scope) Error!void {
        if (self.thread != GetCurrentThreadId()) return error.WrongThread;
        if (!SetThreadToken(null, self.previous).toBool()) return error.RestoreFailed;
        _ = w.ntdll.NtClose(self.duplicate);
        if (self.previous) |handle| _ = w.ntdll.NtClose(handle);
        self.* = undefined;
    }
};

fn privilegeAttributes(token: w.HANDLE) Error!?u32 {
    var luid: Luid = undefined;
    if (!LookupPrivilegeValueW(null, std.unicode.utf8ToUtf16LeStringLiteral("SeSecurityPrivilege"), &luid).toBool()) return error.Unavailable;
    var buffer: [4096]u8 align(8) = undefined;
    var len: u32 = 0;
    if (!GetTokenInformation(token, 3, &buffer, buffer.len, &len).toBool() or len < 4 or len > buffer.len) return error.Unavailable;
    const count = std.mem.readInt(u32, buffer[0..4], .little);
    if (count > (len - 4) / 12) return error.Unavailable;
    for (0..count) |i| {
        const offset = 4 + i * 12;
        if (std.mem.readInt(u32, buffer[offset..][0..4], .little) == luid.low and
            std.mem.readInt(i32, buffer[offset + 4 ..][0..4], .little) == luid.high)
            return std.mem.readInt(u32, buffer[offset + 8 ..][0..4], .little);
    }
    return null;
}
fn processAttributes() Error!?u32 {
    var token: w.HANDLE = undefined;
    if (!OpenProcessToken(GetCurrentProcess(), 8, &token).toBool()) return error.Unavailable;
    defer _ = w.ntdll.NtClose(token);
    return privilegeAttributes(token);
}
fn threadIdentity() Error!?u64 {
    var token: w.HANDLE = undefined;
    if (!OpenThreadToken(GetCurrentThread(), 8, .TRUE, &token).toBool()) {
        if (GetLastError() == 1008) return null;
        return error.Unavailable;
    }
    defer _ = w.ntdll.NtClose(token);
    var buffer: [128]u8 align(8) = undefined;
    var len: u32 = 0;
    if (!GetTokenInformation(token, 10, &buffer, buffer.len, &len).toBool() or len < 8) return error.Unavailable;
    return std.mem.readInt(u64, buffer[0..8], .little);
}

test "Windows safe save audit scope leaves process privileges unchanged and restores the thread" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const before = try processAttributes();
    if (before == null) return error.SkipZigTest;
    const identity = try threadIdentity();
    var scope = try Scope.enter();
    var left = false;
    defer if (!left) scope.leave() catch @panic("audit scope restoration failed");
    try std.testing.expect((try privilegeAttributes(scope.duplicate)).? & 2 != 0);
    try std.testing.expectEqual(before, try processAttributes());
    try scope.leave();
    left = true;
    try std.testing.expectEqual(identity, try threadIdentity());
    try std.testing.expectEqual(before, try processAttributes());
}

test "Windows safe save nested audit scope restores the exact prior impersonation token" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (try processAttributes() == null) return error.SkipZigTest;
    var outer = try Scope.enter();
    defer outer.leave() catch @panic("outer audit scope restoration failed");
    const identity = try threadIdentity();
    var inner = try Scope.enter();
    var left = false;
    defer if (!left) inner.leave() catch @panic("inner audit scope restoration failed");
    try std.testing.expect(identity != try threadIdentity());
    try inner.leave();
    left = true;
    try std.testing.expectEqual(identity, try threadIdentity());
}
