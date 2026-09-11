//! macOS 제품 성능 artifact가 공유하는 환경·실행 파일 지문 leaf.
//!
//! 지문은 배포 provenance가 아니라 한 측정 묶음 안의 drift 검출용이다. pathname만 믿지 않고
//! 열린 regular-file vnode를 끝까지 읽은 뒤 identity와 size/time을 다시 확인한다.

const std = @import("std");

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;

pub const Environment = struct {
    os_release: []u8,
    machine_model: []u8,
    logical_cpu_count: u32,

    pub fn capture(allocator: std.mem.Allocator) !Environment {
        const os_release = try sysctlString(allocator, "kern.osrelease");
        errdefer allocator.free(os_release);
        const machine_model = try sysctlString(allocator, "hw.model");
        errdefer allocator.free(machine_model);
        return .{
            .os_release = os_release,
            .machine_model = machine_model,
            .logical_cpu_count = try sysctlU32("hw.logicalcpu"),
        };
    }

    pub fn deinit(self: *Environment, allocator: std.mem.Allocator) void {
        allocator.free(self.os_release);
        allocator.free(self.machine_model);
        self.* = undefined;
    }
};

pub fn sha256File(path: [*:0]const u8) ![32]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.ExecutableOpenFailed;
    defer _ = std.c.close(fd);
    var before: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &before) != 0 or !std.posix.S.ISREG(before.mode) or before.size <= 0)
        return error.InvalidExecutable;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = std.c.pread(fd, &buffer, buffer.len, @intCast(offset));
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) continue;
            return error.ExecutableReadFailed;
        }
        if (count == 0) break;
        const chunk = buffer[0..@intCast(count)];
        hasher.update(chunk);
        offset = std.math.add(usize, offset, chunk.len) catch return error.InvalidExecutable;
    }
    var after: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &after) != 0 or offset != @as(usize, @intCast(before.size)) or
        before.dev != after.dev or before.ino != after.ino or before.size != after.size or
        before.mtimespec.sec != after.mtimespec.sec or before.mtimespec.nsec != after.mtimespec.nsec or
        before.ctimespec.sec != after.ctimespec.sec or before.ctimespec.nsec != after.ctimespec.nsec)
        return error.ExecutableChanged;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn sysctlString(allocator: std.mem.Allocator, comptime name: [:0]const u8) ![]u8 {
    var len: usize = 0;
    if (sysctlbyname(name.ptr, null, &len, null, 0) != 0 or len <= 1 or len > 4096)
        return error.SysctlUnavailable;
    const bytes = try allocator.alloc(u8, len - 1);
    errdefer allocator.free(bytes);
    var actual = len;
    if (sysctlbyname(name.ptr, bytes.ptr, &actual, null, 0) != 0 or actual != len)
        return error.SysctlUnavailable;
    return bytes;
}

fn sysctlU32(comptime name: [:0]const u8) !u32 {
    var value: u32 = 0;
    var len: usize = @sizeOf(u32);
    if (sysctlbyname(name.ptr, &value, &len, null, 0) != 0 or len != @sizeOf(u32) or value == 0)
        return error.SysctlUnavailable;
    return value;
}
