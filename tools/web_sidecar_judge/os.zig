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

extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?*anyopaque, size: usize, position: u32, options: c_int) isize;

/// Time Machine 이 백업에서 빼는 표시(`NSURLIsExcludedFromBackupKey` 가 다는 확장 속성)가 있는가.
pub fn excludedFromBackup(path: [*:0]const u8) bool {
    return getxattr(path, "com.apple.metadata:com_apple_backup_excludeItem", null, 0, 0, 0) > 0;
}

/// 단조 시계(ms) — 판정 기한을 잰다.
pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// `since`(유닉스 초) 이후에 생긴 `maru-web-*` 크래시 보고의 수. 판정 중 어느 host·helper 가 죽어도 — 종료 코드를
/// 판정하지 않는 자리(부모 사망·재실행)에서도 — 놓치지 않는다(실측: 통과한 실행 속에 host 크래시가 있었다).
pub fn crashReportsSince(since: i64) usize {
    const home = std.c.getenv("HOME") orelse return 0;
    var path_buf: [1024]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}/Library/Logs/DiagnosticReports", .{std.mem.span(home)}) catch return 0;
    const dir = opendir(dir_path) orelse return 0;
    defer _ = closedir(dir);
    var count: usize = 0;
    while (readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (!std.mem.startsWith(u8, name, "maru-web-") or !std.mem.endsWith(u8, name, ".ips")) continue;
        var file_buf: [1024]u8 = undefined;
        const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        const fd = std.c.open(file, .{ .ACCMODE = .RDONLY });
        if (fd < 0) continue;
        defer _ = std.c.close(fd);
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) == 0 and st.mtime().sec >= since) count += 1;
    }
    return count;
}

pub fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

const Dirent = extern struct {
    ino: u64,
    seekoff: u64,
    reclen: u16,
    namlen: u16,
    kind: u8,
    name: [1024]u8,
};
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn closedir(dir: *anyopaque) c_int;
extern "c" fn readdir(dir: *anyopaque) ?*Dirent;
