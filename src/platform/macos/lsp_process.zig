//! 언어 서버 자식 프로세스(docs/editor-surface-tooling.md §8.2a) — **posix fork+execve + 파이프 둘**(stdin 쓰기·stdout 읽기), stderr 는
//! `/dev/null`. `std.process.Child` 를 안 쓰는 것은 이 저장소의 결(`ssh_upload`·`git_backend`·`update_check` — 0.16 의 io 기반 Child 는
//! io 없는 자리에서 못 쓴다). 오래 사는 자식이라 **읽기는 비차단 fd 를 세션 tick 에서 drain** 하고(원격 스트리머와 같은 모양), 쓰기는
//! 작은 메시지라 그 자리에서 다 쓴다(파이프 버퍼 64 KB — 전문 didChange 가 그보다 크면 막히지 않게 `EAGAIN` 이면 남긴다).
//!
//! **서버는 자기 프로세스 그룹의 우두머리다**(`setpgid(0, 0)`) — 서버가 띄운 빌드(zls 의 `zig build`·rust-analyzer 의 `cargo check`)는
//! 그 그룹에 들어가므로, 내릴 때 **그룹째**(`killpg`) 죽여야 손자가 고아로 남지 않는다(§8.2a 「수명·재시작」).
//!
//! **찾기는 우리가 한다**(`session.git_locate.candidates` 와 같은 순회 — PATH 다음 통상 설치 위치) — execve 는 절대 경로를 받는다. 못 찾으면 `null` 이고
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
    /// 아직 못 쓴 바이트(파이프가 찼을 때) — 다음 tick 에 이어 쓴다. `max_pending_bytes` 를 넘기면 쓰지 않고 `stalled` 를 세운다.
    pending_out: std.ArrayList(u8) = .empty,
    /// 서버가 stdin 을 읽지 않아 밀린 것이 상한을 넘었다 — 호출자가 「죽었다」로 보고 재시작한다(§8.2a).
    stalled: bool = false,
    /// 이미 거두었다(`reapIfExited` 가 성공) — 같은 pid 를 다시 `waitpid` 하지 않는다(그 pid 가 우리의 다른 자식으로 다시 쓰였을 수
    /// 있다 — 막는 `waitpid` 면 그 자식이 끝날 때까지 메인 스레드가 선다).
    reaped: bool = false,

    pub fn deinit(self: *Process, allocator: std.mem.Allocator) void {
        self.pending_out.deinit(allocator);
        if (self.in_fd >= 0) _ = std.c.close(self.in_fd);
        if (self.out_fd >= 0) _ = std.c.close(self.out_fd);
        self.in_fd = -1;
        self.out_fd = -1;
    }
};

/// PATH, 그다음 통상 설치 위치(`git_locate.fallback_dirs`)에서 실행 파일을 찾는다(절대 경로 → `buf` 안). 없으면 `null`. `MARU_LSP_SERVER_OVERRIDE` 가 있으면 **그 경로를 이름과
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

/// 밀린 쓰기의 상한 — **이미 밀려 있을 때** 더 쌓는 양에만 건다(밀린 것이 없을 때 들어온 메시지 하나는 크기와 무관하게 받는다 —
/// JSON 이스케이프로 4 MiB 문서가 몇 배로 불어나도 정상 서버를 죽이지 않게). 밀린 동안 tick 의 didChange 는 새로 쌓지 않고 최신 하나로
/// 합치지만(`editor/lsp.zig` `syncOne`), 위치 요청 직전 동기화는 편집마다 전문을 보낸다 — 바쁜 단일 스레드 서버가 몇 초 못 읽는
/// 사이의 편집 열 몇 번(4 MiB 문서 기준)을 담는 크기로 둔다. 이것을 넘는 것은 서버가 stdin 을 **안 읽는다**는 뜻이라 더 쌓지 않고
/// 재시작한다 — 상한이 없으면 멈춘 서버 하나가 편집마다 메모리를 키운다.
pub const max_pending_bytes: usize = 64 * 1024 * 1024;

pub const SpawnError = error{ Pipe, Fork, OutOfMemory };

/// 자식이 `execve` 전에 그만둔 종료 코드 — 프로세스 그룹을 못 만들었거나 root 로 `chdir` 하지 못했다. 그 상태로 서버를 띄우면
/// 그룹째 내릴 수 없거나(손자가 남는다) 앱의 작업 디렉터리에서 엉뚱한 root 를 보게 된다(§8.1 「canonical cwd=root」). 부모에게는
/// 「곧 죽은 서버」로 보여 재시작 경로(backoff → 「실패」)를 탄다.
pub const exit_setup_failed: u8 = 126;

/// 서버를 띄운다. `exe_path` 는 절대 경로(`locate` 의 결과), `args` 는 나머지 인자, `cwd` 는 root(서버가 상대 경로를 root 기준으로 풀게).
/// 환경은 상속한다(PATH 등 — 서버가 도구를 찾는다). 자식은 **새 프로세스 그룹**의 우두머리다(파일 머리 주석).
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
        // 그룹을 먼저 만든다 — 부모도 같은 호출을 한다(아래). 어느 쪽이 먼저 돌든 `execve` 전에 그룹이 선다.
        if (std.c.setpgid(0, 0) != 0) std.c._exit(exit_setup_failed);
        _ = std.c.dup2(in_fds[0], 0);
        _ = std.c.dup2(out_fds[1], 1);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2); // §8.2a: 서버 로그는 우리 것이 아니다
            _ = std.c.close(devnull);
        }
        for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1] }) |fd| _ = std.c.close(fd);
        if (cwd_z.len > 0 and std.c.chdir(cwd_z.ptr) != 0) std.c._exit(exit_setup_failed);
        _ = std.c.execve(exe_z.ptr, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    // 자식이 아직 `setpgid` 에 닿기 전이어도 그룹이 서게 부모가 한 번 더 한다(경쟁을 닫는 관례). 자식이 이미 exec 했으면 EACCES,
    // 이미 끝났으면 ESRCH — 둘 다 자식 쪽 호출이 이미 그룹을 세웠거나 그럴 필요가 없어진 경우라 무시한다.
    _ = std.c.setpgid(pid, pid);
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

/// 쓴다 — 파이프가 차면 남은 것을 `pending_out` 에 두고 다음 `flush` 가 잇는다. 상대가 닫혔거나 밀린 것이 상한을 넘으면
/// `false`(넘었으면 `stalled` 도 선다 — 호출자가 죽은 서버로 다룬다).
pub fn write(p: *Process, allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    if (p.stalled) return false;
    if (p.pending_out.items.len > 0) {
        if (!try queue(p, allocator, bytes)) return false;
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
        if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) return queue(p, allocator, bytes[off..]);
        return false; // EPIPE 등 — 자식이 갔다
    }
    return true;
}

/// 밀린 것에 더한다 — 이미 밀려 있는데 상한을 넘으면 더하지 않고 `stalled` 를 세운다(그 메시지를 **통째로** 거절한다). 메모리가
/// 모자라도 `stalled` 다: 헤더만 들어가고 본문이 빠진 채 다음 `flush` 가 나가면 그 뒤 스트림 전체가 어긋난다 — 호출자는 `flush`
/// 전에 `stalled` 를 보고 재시작한다.
fn queue(p: *Process, allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    if (p.pending_out.items.len > 0 and p.pending_out.items.len + bytes.len > max_pending_bytes) {
        p.stalled = true;
        return false;
    }
    p.pending_out.appendSlice(allocator, bytes) catch {
        p.stalled = true;
        return false;
    };
    return true;
}

/// 밀린 것을 잇는다. 다 썼거나 아직 막혀 있으면 `true`, 상대가 닫혔으면 `false`.
pub fn flush(p: *Process, allocator: std.mem.Allocator) error{OutOfMemory}!bool {
    _ = allocator;
    // 쓴 만큼 앞을 **한 번에** 당긴다 — 부분 쓰기마다 남은 전체를 옮기면 큰 밀림에서 O(n²) 복사가 메인 스레드에서 돈다.
    var off: usize = 0;
    defer if (off > 0) {
        const rest = p.pending_out.items.len - off;
        std.mem.copyForwards(u8, p.pending_out.items[0..rest], p.pending_out.items[off..]);
        p.pending_out.shrinkRetainingCapacity(rest);
    };
    while (off < p.pending_out.items.len) {
        const n = std.c.write(p.in_fd, p.pending_out.items[off..].ptr, p.pending_out.items.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) return true;
        return false;
    }
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

/// 자식이 끝났는지 비차단으로 본다. 끝났으면 `true`(거두었다 — `reaped`).
pub fn reapIfExited(p: *Process) bool {
    if (p.reaped) return true;
    var status: c_int = 0;
    const r = std.c.waitpid(p.pid, &status, std.c.W.NOHANG);
    if (r == p.pid) p.reaped = true;
    return p.reaped;
}

/// 내릴 서버 하나 — 세션의 `Process` 에서 떼어 낸 조각(pid·stdout fd). 세션 메모리를 가리키지 않으므로 세션보다 오래 사는 거두기
/// 스레드가 들고 가도 된다. 떼어 낸 뒤 그 pid 를 기다리는 것은 이 조각뿐이다(세션은 다시 보지 않는다 — 같은 pid 를 두 쪽이 기다리면
/// 한쪽이 다른 자식으로 다시 쓰인 pid 를 기다리게 된다).
pub const Lowering = struct {
    pid: std.c.pid_t,
    out_fd: c_int,
    reaped: bool,
};

/// 세션 쪽 `Process` 를 놓고 `Lowering` 을 돌려준다. **stdin 을 닫는다**(EOF) — 서버가 스스로 내려갈 기회다(실측: rust-analyzer·
/// clangd·zls·tsgo·typescript-language-server·pyright·gopls 모두 EOF 만으로 끝난다; zls 는 이때 제 `zig build` 트리를 정리하고, gopls 의
/// telemetry 자식은 다른 세션이라 `killpg` 가 못 닿지만 부모가 끝나면 스스로 끝난다). 남은 것은 그룹째 내린다. 밀린 쓰기는 버린다.
pub fn handOff(p: *Process, allocator: std.mem.Allocator) Lowering {
    if (p.in_fd >= 0) _ = std.c.close(p.in_fd);
    p.in_fd = -1;
    const l: Lowering = .{ .pid = p.pid, .out_fd = p.out_fd, .reaped = p.reaped };
    p.out_fd = -1;
    p.deinit(allocator);
    return l;
}

/// SIGKILL 뒤 서버 하나를 거두기까지 기다리는 상한 — PTY 의 `reapBoundedAfterKill` 과 같은 크기(보통 수 ms 에 거둔다; 큰 서버는
/// 메모리를 놓는 데 더 걸린다). 이 기다림은 **메인 스레드 밖**(거두기 스레드)이거나, 창이 이미 내려간 앱 종료·판정자에서만 돈다. 끊긴
/// 네트워크 볼륨의 I/O 대기처럼 SIGKILL 이 안 먹으면 포기한다 — 좀비 하나가 남는다.
pub const reap_after_kill_ms: u64 = 3_000;

/// 서버들을 내린다(**막는다**). `grace_ms` 동안 EOF 로 스스로 끝나기를 기다리고(그동안 stdout 을 비워 마지막 출력에 파이프가 차 서지
/// 않게), 남은 것을 **그룹째** SIGKILL 한 뒤 하나씩 거두고 fd 를 닫는다. 이미 끝나 거둔 서버도 그룹에 남은 손자를 위해 `killpg` 한다 —
/// 구성원이 남아 있으면 그 그룹 id 는 다른 프로세스에 다시 쓰이지 않는다(POSIX); 구성원이 없으면 `ESRCH` 다. 거둔 뒤 이것까지는 길어야
/// `grace_ms` 이고 macOS 는 pid 를 차례로 돌려 쓰며(최대 99999) 쓰이는 그룹 id 를 건너뛰므로, 그 사이 같은 번호가 새 그룹이 될 일은 없다.
pub fn lowerAll(items: []Lowering, grace_ms: u64) void {
    var waited: u64 = 0;
    while (waited < grace_ms) : (waited += 5) {
        var left: usize = 0;
        for (items) |*l| {
            drainDiscard(l.out_fd);
            if (!reapNoHang(l)) left += 1;
        }
        if (left == 0) break;
        sleepMs(5);
    }
    for (items) |*l| _ = std.c.kill(-l.pid, std.c.SIG.KILL); // 음수 pid = 그 그룹 전체(`killpg`)
    for (items) |*l| {
        if (!l.reaped) {
            _ = std.c.kill(l.pid, std.c.SIG.KILL); // 그룹이 서기 전에 끝난 경계(자식이 `setpgid` 전에 죽었다)에서도 서버 자신은 죽인다
            var ms: u64 = 0;
            while (!reapNoHang(l) and ms < reap_after_kill_ms) : (ms += 1) sleepMs(1);
        }
        if (l.out_fd >= 0) _ = std.c.close(l.out_fd);
        l.out_fd = -1;
    }
}

/// **메인 스레드를 막지 않고** 내린다(창 닫기·`lsp.enabled` 끄기·죽은 서버 거두기) — 조각들을 프로세스 수명 할당자로 옮겨 detach 된
/// 스레드가 `lowerAll` 을 돈다. 제품의 결이 이것이다(`app_session.zig` `deinit`: 「멈춘 I/O 로 창 닫기가 굳는 것이 훨씬 나쁘다」).
/// 스레드는 세션 메모리를 만지지 않으므로 세션보다 오래 살아도 된다. 옮기거나 스레드를 띄우지 못하면 이 자리에서 돈다.
pub fn lowerDetached(items: []Lowering, grace_ms: u64) void {
    if (items.len == 0) return;
    const owned = std.heap.c_allocator.dupe(Lowering, items) catch return lowerAll(items, grace_ms);
    const thread = std.Thread.spawn(.{}, lowerWorker, .{ owned, grace_ms }) catch {
        std.heap.c_allocator.free(owned);
        return lowerAll(items, grace_ms);
    };
    thread.detach();
}

fn lowerWorker(owned: []Lowering, grace_ms: u64) void {
    lowerAll(owned, grace_ms);
    std.heap.c_allocator.free(owned);
}

/// 지금 곧바로 그룹째 내리고 거둔다(막는다 — 판정자·세션 정리의 마지막 자리).
pub fn stopNow(p: *Process, allocator: std.mem.Allocator) void {
    var l = handOff(p, allocator);
    lowerAll((&l)[0..1], 0);
}

fn reapNoHang(l: *Lowering) bool {
    if (l.reaped) return true;
    while (true) {
        var status: c_int = 0;
        const r = std.c.waitpid(l.pid, &status, std.c.W.NOHANG);
        if (r == l.pid) break;
        if (r < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        if (r < 0) break; // ECHILD — 더 기다릴 것이 없다
        return false; // 아직 살아 있다
    }
    l.reaped = true;
    return true;
}

/// 서버 stdout 에 와 있는 것을 읽어 버린다 — 내려가는 서버가 마지막 출력을 쓰다 파이프(64 KB)가 차 멈추지 않게. fd 는 비차단이다.
fn drainDiscard(fd: c_int) void {
    var chunk: [16 * 1024]u8 = undefined;
    while (fd >= 0) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) return;
    }
}

fn sleepMs(ms: u64) void {
    const nap: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&nap, null);
}
