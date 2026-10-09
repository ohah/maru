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
    };
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

test "socketpair 의 peer pid 는 그 소켓에 쓴 자기 자신이다" {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    _ = c.write(fds[1], "x", 1);
    try std.testing.expectEqual(c.getpid(), peerPid(fds[0]).?);
}
