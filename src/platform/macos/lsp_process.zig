//! 언어 서버 자식 프로세스(docs/editor-surface-tooling.md §8.2a) — **posix fork+execve + 파이프 둘**(stdin 쓰기·stdout 읽기), stderr 는
//! `/dev/null`. `std.process.Child` 를 안 쓰는 것은 이 저장소의 결(`ssh_upload`·`git_backend`·`update_check` — 0.16 의 io 기반 Child 는
//! io 없는 자리에서 못 쓴다). 오래 사는 자식이라 **읽기는 비차단 fd 를 세션 tick 에서 drain** 하고(원격 스트리머와 같은 모양), 쓰기는
//! 작은 메시지라 그 자리에서 다 쓴다(파이프 버퍼 64 KB — 전문 didChange 가 그보다 크면 막히지 않게 `EAGAIN` 이면 남긴다).
//!
//! **PATH 탐색은 우리가 한다**(`session.git_locate.candidates` 와 같은 순회) — execve 는 절대 경로를 받는다. 못 찾으면 `null` 이고
//! 그것이 곧 「없음 — 설치」다.

const std = @import("std");
const builtin = @import("builtin");
const git_locate = @import("maru").session.git_locate;

pub const Process = struct {
    pid: std.c.pid_t,
    /// 자식 stdin(우리가 쓴다). 비차단.
    in_fd: c_int,
    /// 자식 stdout(우리가 읽는다). 비차단.
    out_fd: c_int,
    /// 아직 못 쓴 바이트(파이프가 찼을 때) — 다음 tick 에 이어 쓴다.
    pending_out: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Process, allocator: std.mem.Allocator) void {
        self.pending_out.deinit(allocator);
        if (self.in_fd >= 0) _ = std.c.close(self.in_fd);
        if (self.out_fd >= 0) _ = std.c.close(self.out_fd);
        self.in_fd = -1;
        self.out_fd = -1;
    }
};

/// PATH 에서 실행 파일을 찾는다(절대 경로 → `buf` 안). 없으면 `null`. `MARU_LSP_SERVER_OVERRIDE` 가 있으면 **그 경로를 이름과
/// 무관하게** 쓴다 — 판정자가 가짜 서버를 끼우는 자리(하니스 전용; 제품 사용자가 켤 이유가 없다).
pub fn locate(exe: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    if (envValue("MARU_LSP_SERVER_OVERRIDE")) |over| {
        // override 도 **실행 가능한 파일**이어야 한다 — 없는 경로를 주면 「없음」이다(판정자가 그 상태를 만드는 길).
        if (over.len == 0 or over.len > buf.len or !isExecutableFile(over)) return null;
        @memcpy(buf[0..over.len], over);
        return buf[0..over.len];
    }
    if (std.mem.indexOfScalar(u8, exe, '/') != null) return null; // 이름표는 이름이다 — 경로를 받지 않는다
    var it = git_locate.candidates(pathEnv());
    var cand: [std.fs.max_path_bytes]u8 = undefined;
    while (nextCandidate(&it, exe, &cand)) |candidate| {
        if (!isExecutableFile(candidate)) continue;
        if (candidate.len > buf.len) return null;
        @memcpy(buf[0..candidate.len], candidate);
        return buf[0..candidate.len];
    }
    return null;
}

fn nextCandidate(it: *git_locate.Iterator, exe: []const u8, buf: []u8) ?[]const u8 {
    // `git_locate` 는 후보를 `dir/git` 로 만든다 — 이름만 바꿔 같은 순회를 쓴다.
    while (it.next(buf)) |git_path| {
        const slash = std.mem.lastIndexOfScalar(u8, git_path, '/') orelse continue;
        const dir = git_path[0..slash];
        if (dir.len + 1 + exe.len > buf.len) continue;
        // `git_path` 는 `buf` 안이라 dir 은 이미 제자리다 — 이름만 덮는다.
        @memcpy(buf[dir.len + 1 ..][0..exe.len], exe);
        return buf[0 .. dir.len + 1 + exe.len];
    }
    return null;
}

fn isExecutableFile(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    if (std.c.access(z.ptr, std.posix.X_OK) != 0) return false;
    const dz = std.fmt.bufPrintZ(&buf, "{s}/", .{path}) catch return false;
    return std.c.access(dz.ptr, std.posix.F_OK) != 0;
}

fn pathEnv() []const u8 {
    return envValue("PATH") orelse "";
}

fn envValue(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        if (pair.len > name.len and pair[name.len] == '=' and std.mem.eql(u8, pair[0..name.len], name)) return pair[name.len + 1 ..];
    }
    return null;
}

pub const SpawnError = error{ Pipe, Fork, OutOfMemory };

/// 서버를 띄운다. `exe_path` 는 절대 경로(`locate` 의 결과), `args` 는 나머지 인자, `cwd` 는 root(서버가 상대 경로를 root 기준으로 풀게).
/// 환경은 상속한다(PATH 등 — 서버가 도구를 찾는다).
pub fn spawn(allocator: std.mem.Allocator, exe_path: []const u8, args: []const []const u8, cwd: []const u8) SpawnError!Process {
    var in_fds: [2]c_int = undefined; // 부모 → 자식(자식 stdin)
    var out_fds: [2]c_int = undefined; // 자식 → 부모(자식 stdout)
    if (std.c.pipe(&in_fds) != 0) return error.Pipe;
    if (std.c.pipe(&out_fds) != 0) {
        _ = std.c.close(in_fds[0]);
        _ = std.c.close(in_fds[1]);
        return error.Pipe;
    }
    for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1] }) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    _ = std.c.fcntl(in_fds[1], std.c.F.SETNOSIGPIPE, @as(c_int, 1)); // 서버가 먼저 죽어도 우리는 안 죽는다(ssh_upload 와 같은 실측)

    // argv/envp 를 fork 전에 만든다 — 자식에서 할당하면 안 된다.
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(allocator);
    var owned: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    const exe_z = try allocator.dupeZ(u8, exe_path);
    try owned.append(allocator, exe_z);
    try argv.append(allocator, exe_z.ptr);
    for (args) |a| {
        const z = try allocator.dupeZ(u8, a);
        try owned.append(allocator, z);
        try argv.append(allocator, z.ptr);
    }
    try argv.append(allocator, null);
    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);

    const pid = std.c.fork();
    if (pid < 0) {
        for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1] }) |fd| _ = std.c.close(fd);
        return error.Fork;
    }
    if (pid == 0) {
        _ = std.c.dup2(in_fds[0], 0);
        _ = std.c.dup2(out_fds[1], 1);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2); // §8.2a: 서버 로그는 우리 것이 아니다
            _ = std.c.close(devnull);
        }
        for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1] }) |fd| _ = std.c.close(fd);
        if (cwd_z.len > 0) _ = std.c.chdir(cwd_z.ptr);
        _ = std.c.execve(exe_z.ptr, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    _ = std.c.close(in_fds[0]);
    _ = std.c.close(out_fds[1]);
    setNonBlocking(in_fds[1]);
    setNonBlocking(out_fds[0]);
    return .{ .pid = pid, .in_fd = in_fds[1], .out_fd = out_fds[0] };
}

fn setNonBlocking(fd: c_int) void {
    const fl = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (fl >= 0) _ = std.c.fcntl(fd, std.c.F.SETFL, fl | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
}

/// 쓴다 — 파이프가 차면 남은 것을 `pending_out` 에 두고 다음 `flush` 가 잇는다. 상대가 닫혔으면 `false`(자식이 죽었다).
pub fn write(p: *Process, allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    if (p.pending_out.items.len > 0) {
        try p.pending_out.appendSlice(allocator, bytes);
        return flush(p, allocator);
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(p.in_fd, bytes[off..].ptr, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) {
            try p.pending_out.appendSlice(allocator, bytes[off..]);
            return true;
        }
        return false; // EPIPE 등 — 자식이 갔다
    }
    return true;
}

/// 밀린 것을 잇는다. 다 썼거나 아직 막혀 있으면 `true`, 상대가 닫혔으면 `false`.
pub fn flush(p: *Process, allocator: std.mem.Allocator) error{OutOfMemory}!bool {
    while (p.pending_out.items.len > 0) {
        const n = std.c.write(p.in_fd, p.pending_out.items.ptr, p.pending_out.items.len);
        if (n > 0) {
            const wrote: usize = @intCast(n);
            const rest = p.pending_out.items.len - wrote;
            std.mem.copyForwards(u8, p.pending_out.items[0..rest], p.pending_out.items[wrote..]);
            p.pending_out.shrinkRetainingCapacity(rest);
            continue;
        }
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) return true;
        return false;
    }
    _ = allocator;
    return true;
}

pub const ReadResult = enum { data, would_block, eof };

/// 비차단 읽기 한 번 — 있는 만큼 `into` 에 더한다. `eof` 면 자식 stdout 이 닫혔다(죽었다).
pub fn readInto(p: *Process, allocator: std.mem.Allocator, into: *std.ArrayList(u8), max_chunk: usize) error{OutOfMemory}!ReadResult {
    var chunk: [16 * 1024]u8 = undefined;
    var got_any = false;
    var budget = max_chunk;
    while (budget > 0) {
        const want = @min(chunk.len, budget);
        const n = std.c.read(p.out_fd, &chunk, want);
        if (n > 0) {
            const len: usize = @intCast(n);
            try into.appendSlice(allocator, chunk[0..len]);
            budget -= len;
            got_any = true;
            continue;
        }
        if (n == 0) return .eof;
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) break;
        return .eof; // 다른 오류도 「끝」으로 본다 — 호출자가 재시작한다
    }
    return if (got_any) .data else .would_block;
}

/// 자식이 끝났는지 비차단으로 본다. 끝났으면 `true`(거두었다).
pub fn reapIfExited(p: *Process) bool {
    var status: c_int = 0;
    const r = std.c.waitpid(p.pid, &status, std.c.W.NOHANG);
    return r == p.pid;
}

/// 죽인다(SIGTERM → 잠시 뒤 SIGKILL 은 호출자가 tick 으로) 하고 거둔다.
pub fn kill(p: *Process, sig: std.c.SIG) void {
    _ = std.c.kill(p.pid, sig);
}

pub fn reapBlocking(p: *Process) void {
    var status: c_int = 0;
    _ = std.c.waitpid(p.pid, &status, 0);
}
