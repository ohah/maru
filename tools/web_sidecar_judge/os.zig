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

/// Time Machine 이 이 경로를 백업에서 빼는가 — sidecar 가 단 값을 되읽지 않고 `tmutil isexcluded` 에게 묻는다(속성이
/// 있기만 하고 값이 틀려도 통과하던 판정을 고쳤다 — 적대 검증).
pub fn excludedFromBackup(path: [*:0]const u8) bool {
    var out: [2]c_int = undefined;
    if (std.c.pipe(&out) != 0) return false;
    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = std.c.dup2(out[1], 1);
        _ = std.c.close(out[0]);
        _ = std.c.close(out[1]);
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/tmutil", "isexcluded", path };
        const envp = [_:null]?[*:0]const u8{};
        _ = std.c.execve("/usr/bin/tmutil", &argv, &envp);
        std.c._exit(127);
    }
    _ = std.c.close(out[1]);
    defer _ = std.c.close(out[0]);
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(out[0], buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return std.mem.indexOf(u8, buf[0..len], "[Excluded]") != null;
}

/// 단조 시계(ms) — 판정 기한을 잰다.
pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Mach-O 실행 파일의 `LC_UUID` 를 크래시 보고가 쓰는 모양(소문자 8-4-4-4-12)으로. 못 읽으면 null.
pub fn machoUuid(path: [*:0]const u8, out: *[36]u8) ?[]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var head: [64 * 1024]u8 = undefined;
    const n = std.c.read(fd, &head, head.len);
    if (n < 32) return null;
    const bytes = head[0..@intCast(n)];
    if (std.mem.readInt(u32, bytes[0..4], .little) != 0xfeedfacf) return null; // 64 비트 단일 아키텍처만
    const ncmds = std.mem.readInt(u32, bytes[16..20], .little);
    var at: usize = 32;
    var i: u32 = 0;
    while (i < ncmds and at + 8 <= bytes.len) : (i += 1) {
        const cmd = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        if (cmd == 0x1b and at + 24 <= bytes.len) { // LC_UUID
            const u = bytes[at + 8 ..][0..16];
            return std.fmt.bufPrint(out, "{x}-{x}-{x}-{x}-{x}", .{ u[0..4], u[4..6], u[6..8], u[8..10], u[10..16] }) catch null;
        }
        if (size < 8) return null;
        at += size;
    }
    return null;
}

/// `since`(유닉스 초) 이후에 생긴 크래시 보고 가운데 **이 빌드의 실행 파일**(`uuids` — `machoUuid`)이 낸 것의 수. 판정 중
/// 어느 host·helper 가 죽어도 — 종료 코드를 판정하지 않는 자리(부모 사망·재실행)에서도 — 놓치지 않는다(실측: 통과한
/// 실행 속에 host 크래시가 있었다). 보고의 실행 경로는 가려져(`\/private\/tmp\/*\/…`) 쓸 수 없어, 보고 머리의
/// `slice_uuid` 로 다른 작업 트리·설치본의 크래시를 가른다.
pub fn crashReportsSince(since: i64, uuids: []const []const u8) usize {
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
        if (std.c.fstat(fd, &st) != 0 or st.mtime().sec < since) continue;
        var head: [1024]u8 = undefined;
        const n = std.c.read(fd, &head, head.len);
        if (n <= 0) continue;
        for (uuids) |uuid| {
            var key: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&key, "\"slice_uuid\":\"{s}\"", .{uuid}) catch continue;
            if (std.mem.indexOf(u8, head[0..@intCast(n)], needle) != null) {
                count += 1;
                break;
            }
        }
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

/// 명령을 돌려 끝날 때까지 기다린다. 종료 코드 0 이면 참.
pub fn run(argv: []const ?[*:0]const u8) bool {
    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        var args: [8:null]?[*:0]const u8 = @splat(null);
        for (argv, 0..) |arg, i| args[i] = arg;
        const envp = [_:null]?[*:0]const u8{};
        _ = std.c.execve(argv[0].?, &args, &envp);
        std.c._exit(127);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return false;
    return status == 0;
}
