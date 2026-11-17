//! 1g self-origin 판정(`maru.session.control_self_origin`)의 macOS 공급자 — 소켓 peer pid(`LOCAL_PEERPID`),
//! 프로세스 정보(`proc_pidinfo(PROC_PIDTBSDINFO)`), 세션 번호(`getsid`).
//!
//! **peer pid 는 auth 프레임을 읽은 뒤에 읽는다.** `LOCAL_PEERPID` 는 그 소켓을 마지막으로 다룬 프로세스(xnu `last_pid`)라,
//! 그 프레임을 쓴 프로세스에 가장 가까운 것은 그 프레임을 읽은 직후다(같은 fd 를 나눠 가진 다른 프로세스가 끼어들 수 있지만
//! 그것은 이미 그 fd 를 쥔 협조자다). 그 사이 끝나고 pid 가 재사용되는 경우는 시작
//! 시각(연결을 받은 뒤에 시작했으면 거절)으로 가른다.
//!
//! **pane 의 뿌리(`/usr/bin/login`)는 root 소유라 `proc_pidinfo` 로 못 읽는다**(EPERM — 같은 사용자만). 그래서 판정은
//! 사용자 소유인 foreground 조상에서 멈추고(그 위 login 에 닿으면 거절), pane 과는 `getsid`(권한 검사 없음)로 잇는다.
const std = @import("std");
const c = std.c;
const maru = @import("maru");
const so = maru.session.control_self_origin;

/// `struct proc_bsdinfo`(SDK `sys/proc_info.h`) — 쓰는 필드만 이름을 붙이고 크기는 SDK 와 같게 못박는다.
const ProcBsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [16]u8,
    pbi_name: [32]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

comptime {
    // `PROC_PIDTBSDINFO_SIZE` — 어긋나면 커널이 0 을 돌려 판정이 늘 거절로 닫힌다(열리지는 않는다).
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_pgid") == 100);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_start_tvsec") == 120);
}

const proc_pidtbsdinfo: c_int = 3;
const proc_flag_controlt: u32 = 0x80;
const nodev: u32 = 0xffff_ffff;
/// `<sys/proc.h>` 의 `SZOMB` — 끝났고 부모가 아직 거두지 않았다(W9e② 조건의 주인 판정).
const szomb: u32 = 5;
const sol_local: c_int = 0;
const local_peerpid: c_int = 2;

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn getsid(pid: c.pid_t) c.pid_t;
extern "c" fn getpgrp() c.pid_t;
extern "c" fn getsockopt(fd: c.fd_t, level: c_int, name: c_int, value: ?*anyopaque, len: *c.socklen_t) c_int;

/// 소켓에 마지막으로 쓴 프로세스의 pid(실패면 null).
pub fn peerPid(fd: c.fd_t) ?i32 {
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or len != @sizeOf(c.pid_t) or pid <= 0) return null;
    return pid;
}

pub fn procInfo(pid: i32) ?so.ProcInfo {
    if (pid <= 0) return null;
    var info: ProcBsdInfo = undefined;
    const n = proc_pidinfo(pid, proc_pidtbsdinfo, 0, &info, @sizeOf(ProcBsdInfo));
    if (n != @sizeOf(ProcBsdInfo)) return null;
    const has_ctty = (info.pbi_flags & proc_flag_controlt) != 0 and info.e_tdev != nodev;
    return .{
        .pid = @bitCast(info.pbi_pid),
        .ppid = @bitCast(info.pbi_ppid),
        .pgid = @bitCast(info.pbi_pgid),
        .uid = info.pbi_uid,
        .has_ctty = has_ctty,
        .tpgid = if (has_ctty) @bitCast(info.e_tpgid) else 0,
        .start_us = info.pbi_start_tvsec *| std.time.us_per_s +| info.pbi_start_tvusec,
        .zombie = info.pbi_status == szomb,
    };
}

extern "c" fn proc_name(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;

/// 그 프로세스의 실행 파일 이름(`proc_name` — `p_name`, 최대 32 바이트). 못 읽으면(끝났다·남의 것) `null`. 신뢰 감사 기록의 컨트롤 상대
/// (계획 workspace-trust-audit TA2)가 쓴다.
pub fn procName(pid: i32, buf: *[64]u8) ?[]const u8 {
    if (pid <= 0) return null;
    const n = proc_name(pid, buf, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

pub fn sessionOf(pid: i32) ?i32 {
    const sid = getsid(pid);
    return if (sid > 0) sid else null;
}

fn lookupThunk(_: *anyopaque, pid: i32) ?so.ProcInfo {
    return procInfo(pid);
}

fn sessionThunk(_: *anyopaque, pid: i32) ?i32 {
    return sessionOf(pid);
}

var provider_ctx: u8 = 0;

/// 실제 OS 를 읽는 공급자(상태 없음).
pub fn provider() so.Provider {
    return .{ .ctx = &provider_ctx, .lookup = lookupThunk, .session_of = sessionThunk };
}

// ── pane 안 tmux 잇기의 공급자(`so.tmuxClientSessions`) ───────────────────────────────────────────────────────────────────────

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// `struct proc_fdinfo`(SDK `sys/proc_info.h`) — fd 번호와 종류.
const ProcFdInfo = extern struct { proc_fd: i32, proc_fdtype: u32 };
const proc_pidlistfds: c_int = 1;
const proc_pidfdsocketinfo: c_int = 3;
const prox_fdtype_socket: u32 = 2;
/// `struct socket_fdinfo` 의 크기와 쓰는 칸의 자리(SDK 의 `offsetof` 실측 — `open_access/spike/off.c`). 구조체 전부를 옮겨 적지 않고 바이트로
/// 읽는다(안쪽 공용체·`vinfo_stat` 가 길다). 자리가 어긋나면 pcb 가 맞지 않아 잇기가 늘 실패로 닫힌다(열리지는 않는다) — 아래 socketpair 시험이 잡는다.
const socket_fdinfo_size: usize = 792;
const soi_pcb_at: usize = 168;
const soi_family_at: usize = 184;
const unsi_conn_pcb_at: usize = 272;
const af_unix: i32 = 1;

/// `unixSockets` 의 fd 목록 자리(4096 개 — 그보다 많으면 앞 4096 개만 본다; 잇기가 실패로 닫힐 뿐 열리지는 않는다).
var fd_list_buf: [4096]ProcFdInfo = undefined;

/// 살아 있는 pid 들(`buf` 를 채운다). 실패하면 빈 것.
pub fn listPids(buf: []i32) []const i32 {
    const n = proc_listallpids(buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int) / @sizeOf(i32)) * @sizeOf(i32)));
    if (n <= 0) return buf[0..0];
    return buf[0..@min(@as(usize, @intCast(n)), buf.len)];
}

/// 그 프로세스의 unix 소켓들(pcb 와 상대 pcb). 못 읽으면(끝났다·남의 것) 빈 것.
pub fn unixSockets(pid: i32, buf: []so.UnixSock) []const so.UnixSock {
    if (pid <= 0 or buf.len == 0) return buf[0..0];
    // fd 목록 — 창이 많은 tmux 서버는 pty·소켓 fd 가 수백이다. 앞 256 개만 보던 판은 뒤쪽(나중에 받은 클라이언트 연결)을 놓쳤다(적대 검증 R1).
    // 메인 스레드만 부른다(`resolveSelfOrigin`·시험) — 32 KiB 라 스택에 두지 않는다.
    const fds = &fd_list_buf;
    const bytes = proc_pidinfo(pid, proc_pidlistfds, 0, fds, @sizeOf(@TypeOf(fd_list_buf)));
    if (bytes <= 0) return buf[0..0];
    const count = @min(@as(usize, @intCast(bytes)) / @sizeOf(ProcFdInfo), fds.len);
    var n: usize = 0;
    var info: [socket_fdinfo_size]u8 align(8) = undefined;
    for (fds[0..count]) |fd| {
        if (fd.proc_fdtype != prox_fdtype_socket) continue;
        if (proc_pidfdinfo(pid, fd.proc_fd, proc_pidfdsocketinfo, &info, socket_fdinfo_size) != socket_fdinfo_size) continue;
        if (std.mem.readInt(i32, info[soi_family_at..][0..4], .little) != af_unix) continue;
        buf[n] = .{ .pcb = std.mem.readInt(u64, info[soi_pcb_at..][0..8], .little), .conn_pcb = std.mem.readInt(u64, info[unsi_conn_pcb_at..][0..8], .little) };
        n += 1;
        if (n == buf.len) break;
    }
    return buf[0..n];
}

/// 실행 파일 이름이 `tmux` 인가.
pub fn isTmux(pid: i32) bool {
    var buf: [64]u8 = undefined;
    const name = procName(pid, &buf) orelse return false;
    return std.mem.eql(u8, name, "tmux");
}

fn pidsThunk(_: *anyopaque, buf: []i32) []const i32 {
    return listPids(buf);
}

fn unixSocketsThunk(_: *anyopaque, pid: i32, buf: []so.UnixSock) []const so.UnixSock {
    return unixSockets(pid, buf);
}

fn isTmuxThunk(_: *anyopaque, pid: i32) bool {
    return isTmux(pid);
}

/// 실제 OS 를 읽는 tmux 잇기 공급자(상태 없음).
pub fn tmuxProvider() so.TmuxProvider {
    return .{ .base = provider(), .ctx = &provider_ctx, .pids = pidsThunk, .unix_sockets = unixSocketsThunk, .is_tmux = isTmuxThunk };
}

/// 지금 벽시계(µs) — `ProcInfo.start_us` 와 같은 시계.
pub fn nowUs() u64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(u64, @intCast(tv.sec)) *| std.time.us_per_s +| @as(u64, @intCast(tv.usec));
}

test "자기 프로세스의 정보가 OS 와 맞는다 — 구조체 레이아웃이 어긋나면 여기서 걸린다" {
    const me = c.getpid();
    const info = procInfo(me) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(me, info.pid);
    try std.testing.expectEqual(c.getppid(), info.ppid);
    try std.testing.expectEqual(getpgrp(), info.pgid);
    try std.testing.expectEqual(c.getuid(), info.uid);
    try std.testing.expect(info.start_us > 0 and info.start_us <= nowUs());
    try std.testing.expectEqual(getsid(me), sessionOf(me).?);
}

test "자기 프로세스의 실행 파일 이름 — 판정자 바이너리 이름(`test`)이고, 없는 pid 는 이름이 없다" {
    var buf: [64]u8 = undefined;
    const name = procName(c.getpid(), &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expect(name.len > 0 and name.len <= 32);
    try std.testing.expect(std.mem.indexOfScalar(u8, name, 0) == null);
    try std.testing.expect(procName(0, &buf) == null);
    try std.testing.expect(procName(-1, &buf) == null);
}

test "socketpair 의 peer pid 는 그 소켓에 쓴 자기 자신이다" {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    _ = c.write(fds[1], "x", 1);
    try std.testing.expectEqual(c.getpid(), peerPid(fds[0]).?);
}

test "tmux 잇기의 소켓 고리 — fd 가 수백 개인 프로세스(창이 많은 tmux 서버)에서도 높은 번호의 소켓을 본다(적대 검증 R1)" {
    // 앞 fd 를 600 개 채운 뒤 socketpair — 고리가 fd 목록의 뒤쪽에 있다. 목록을 앞 256 개만 보던 판은 이것을 놓쳐 거절로 닫혔다.
    var fillers: [600]c.fd_t = undefined;
    var n: usize = 0;
    defer for (fillers[0..n]) |fd| {
        _ = c.close(fd);
    };
    while (n < fillers.len) : (n += 1) {
        const fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
        if (fd < 0) break;
        fillers[n] = fd;
    }
    if (n < 400) return error.SkipZigTest; // fd 상한이 낮은 환경
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    var buf: [64]so.UnixSock = undefined;
    var paired = false;
    for (unixSockets(c.getpid(), &buf)) |a| for (unixSockets(c.getpid(), &buf)) |b| {
        if (a.pcb != 0 and a.pcb != b.pcb and a.conn_pcb == b.pcb and b.conn_pcb == a.pcb) paired = true;
    };
    try std.testing.expect(paired);
}

test "tmux 잇기의 소켓 고리 — socketpair 의 두 끝은 서로의 pcb 를 상대로 갖는다(칸 자리가 SDK 와 맞는지), 자기 pid 는 목록에 있다" {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    var buf: [64]so.UnixSock = undefined;
    const socks = unixSockets(c.getpid(), &buf);
    // 두 끝 a·b 가 a.conn == b.pcb 이고 b.conn == a.pcb 인 쌍이 있다.
    var paired = false;
    for (socks) |a| for (socks) |b| {
        if (a.pcb != 0 and a.pcb != b.pcb and a.conn_pcb == b.pcb and b.conn_pcb == a.pcb) paired = true;
    };
    try std.testing.expect(paired);
    var pids: [16384]i32 = undefined;
    try std.testing.expect(std.mem.indexOfScalar(i32, listPids(&pids), c.getpid()) != null);
    try std.testing.expect(!isTmux(c.getpid())); // 시험 바이너리 이름은 tmux 가 아니다
    try std.testing.expectEqual(@as(usize, 0), unixSockets(-1, &buf).len);
}
