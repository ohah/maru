//! 판정자가 쓰는 macOS 호출(W1b). 표준 라이브러리가 공개하지 않는 것만 직접 선언한다.

const std = @import("std");

pub extern "c" fn fork() c_int;
pub extern "c" fn sandbox_check(pid: c_int, operation: ?[*:0]const u8, kind: c_int) c_int;
pub extern "c" fn proc_listchildpids(ppid: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;
pub extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;
extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

pub fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    _ = nanosleep(&ts, null);
}

pub fn random64() u64 {
    var value: u64 = undefined;
    arc4random_buf(@ptrCast(&value), @sizeOf(u64));
    return value;
}

/// `pid` 의 직계 자식 pid. 넘치는 것은 버린다(판정에는 충분하다).
pub fn children(pid: c_int, out: []c_int) []c_int {
    const n = proc_listchildpids(pid, out.ptr, @intCast(out.len * @sizeOf(c_int)));
    if (n <= 0) return out[0..0];
    return out[0..@min(@as(usize, @intCast(n)), out.len)];
}

pub fn alive(pid: c_int) bool {
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

pub fn executablePath(pid: c_int, buf: []u8) []const u8 {
    const n = proc_pidpath(pid, buf.ptr, @intCast(buf.len));
    if (n <= 0) return "";
    return buf[0..@intCast(n)];
}
