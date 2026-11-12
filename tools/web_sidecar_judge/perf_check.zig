//! W9e② 판정 — 실제 CEF 154 에서 성능 trace 와 CPU·네트워크 조건(docs/plans/web-osr-backend.md 「W9e② 결정·실측」). 판정자가 **maru 역할**로
//! `trace`·`emulation`·사람 입력(`mouse`)을 보내고 `trace_state`·`trace_data`·`trace_frames`·`emulation_state` 를 모은다. 받은 gzip 은 maru 의
//! 순수 거르기(`web_osr_trace.filter` — 앱이 쓰는 그 함수)로 걸러 본다(`maru-web-trace-filter` 보조 실행 파일 — 한 파일이 두 모듈에 들 수 없다). 조건의 주인은 maru 의 판정 함수(`control_self_origin.ownerAlive` — 앱이 쓰는
//! 그 함수)를 진짜 자식 프로세스에 대어 본다. 페이지는 `emulation_check` 의 서버(127.0.0.1 과 localhost 는 다른 사이트).
//!
//! trace(`--trace`): tr-basic(보이는 에이전트 탭 — 기록·자동 멈춤·조각·프레임 집합·거르기 남김·스크린샷, 그 사이 다른 탭이 연 주소가 남긴 trace 에
//!   없다)·tr-hidden-focus(숨은 탭은 focus 흉내로 보이고 프레임이 나오며, 끝나면 다시 숨고 멈춘다 — 결정 5)·tr-mixed-content(사용자 탭 안의 같은
//!   사이트 iframe 이 같은 렌더러에서 일하면 거르기가 통째로 버린다 — F3)·tr-human-input(사람의 누름이면 버리고 이유를 싣는다)·tr-tab-closed
//!   (닫히면 실패, 다음 trace 는 된다)·tr-busy(브라우저에 하나)·tr-stop-early(요청 멈춤의 덮은 시간)·tr-guard(maru 경유 Tracing·IO 는 막힌다).
//! 조건(`--emulation` 의 끝): emu-cpu(4 배 — 지우면 돌아온다)·emu-cpu-process-shared(같은 렌더러의 남의 프레임이면 걸지 않고 이유)·
//!   emu-cpu-released-on-share(걸린 뒤 남의 프레임이 들어오면 곧 풂)·emu-net-latency·emu-net-offline(요청 막기 + navigator.onLine, 같은 프로세스의
//!   사용자 iframe 도 — 결정 3, 풀면 모두 돌아온다)·emu-net-dead-release(렌더러가 죽은 동안의 풀기는 쌓았다가 새 렌더러에)·emu-cond-human(사람이
//!   몰면 풂 — 풀림 회차)·emu-cond-owner-exit(주인 프로세스가 끝나면 maru 가 푼다 — 에이전트·MCP 둘)·emu-cond-shell-owner(사람이 셸에서 친
//!   CLI — 진짜 pty 의 대화형 셸이 띄운 foreground 작업에서 1g `findOrigin`·`ownerOf` 가 그 셸을 주인으로 찾고, 명령이 끝나도 남고 셸이 끝나면
//!   푼다 — 확인 결정 9).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const emu = @import("emulation_check.zig");
const self_origin = @import("control_self_origin");

const msg = protocol.message;
const Run = emu.Run;
const Session = emu.Session;
const Report = emu.Report;
const contains = emu.contains;

// ── 진짜 프로세스 정보(앱의 macOS 공급자와 같은 구조체 — 판정자는 `maru` 모듈을 받지 않는다) ─────────────────────

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
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn lookup(_: *anyopaque, pid: i32) ?self_origin.ProcInfo {
    var info: ProcBsdInfo = undefined;
    if (proc_pidinfo(pid, 3, 0, &info, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo)) return null;
    return .{ .pid = @bitCast(info.pbi_pid), .ppid = @bitCast(info.pbi_ppid), .pgid = @bitCast(info.pbi_pgid), .uid = info.pbi_uid, .has_ctty = false, .tpgid = 0, .start_us = info.pbi_start_tvsec *| std.time.us_per_s +| info.pbi_start_tvusec };
}
fn sessionOf(_: *anyopaque, _: i32) ?i32 {
    return null;
}
var provider_ctx: u8 = 0;
fn provider() self_origin.Provider {
    return .{ .ctx = &provider_ctx, .lookup = lookup, .session_of = sessionOf };
}

// ── W9e② 확인 결정 9: 진짜 pty 의 대화형 셸 — 1g 판정(제어 터미널·foreground 그룹·세션)을 앱의 macOS 공급자와 같은 값으로 ─────────

const proc_flag_controlt: u32 = 0x80;
const nodev: u32 = 0xffff_ffff;
const szomb: u32 = 5;
extern "c" fn getsid(pid: c_int) c_int;
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn setsid() c_int;
extern "c" fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
extern "c" fn getuid() u32;

/// 앱의 `control_self_origin_macos.procInfo` 와 같은 계산의 복제(제어 터미널·foreground 그룹·좀비 — 판정자는 `maru` 모듈을 받지 않는다).
fn fullLookup(_: *anyopaque, pid: i32) ?self_origin.ProcInfo {
    var info: ProcBsdInfo = undefined;
    if (pid <= 0 or proc_pidinfo(pid, 3, 0, &info, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo)) return null;
    const has_ctty = (info.pbi_flags & proc_flag_controlt) != 0 and info.e_tdev != nodev;
    return .{ .pid = @bitCast(info.pbi_pid), .ppid = @bitCast(info.pbi_ppid), .pgid = @bitCast(info.pbi_pgid), .uid = info.pbi_uid, .has_ctty = has_ctty, .tpgid = if (has_ctty) @bitCast(info.e_tpgid) else 0, .start_us = info.pbi_start_tvsec *| std.time.us_per_s +| info.pbi_start_tvusec, .zombie = info.pbi_status == szomb };
}
fn fullSessionOf(_: *anyopaque, pid: i32) ?i32 {
    const sid = getsid(pid);
    return if (sid > 0) sid else null;
}
pub fn fullProvider() self_origin.Provider {
    return .{ .ctx = &provider_ctx, .lookup = fullLookup, .session_of = fullSessionOf };
}

pub const Pty = struct { master: c_int, shell: i32 };

/// 새 세션의 대화형 `/bin/sh -i`(작업 제어가 켜진다)를 pty 에 띄운다(pane 의 셸 흉내). zsh 는 쓰지 않는다 — `-f` 도 `/etc/zshenv` 를 읽어
/// 기계마다 다른 백그라운드 작업이 생기면 `exit` 가 「running jobs」 로 한 번 거절된다(실측).
pub fn spawnShell() ?Pty {
    const m = posix_openpt(0x0002 | 0x20000); // O_RDWR | O_NOCTTY
    if (m < 0) return null;
    if (grantpt(m) != 0 or unlockpt(m) != 0) {
        _ = std.c.close(m);
        return null;
    }
    const name = ptsname(m) orelse {
        _ = std.c.close(m);
        return null;
    };
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(m);
        return null;
    }
    if (pid == 0) {
        _ = setsid();
        const sl = std.c.open(name, .{ .ACCMODE = .RDWR }, @as(c_uint, 0));
        if (sl < 0) std.c._exit(126);
        _ = ioctl(sl, 0x20007461, @as(c_int, 0)); // TIOCSCTTY
        _ = std.c.dup2(sl, 0);
        _ = std.c.dup2(sl, 1);
        _ = std.c.dup2(sl, 2);
        var fd: c_int = 3;
        while (fd < 1024) : (fd += 1) _ = std.c.close(fd);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-i", null };
        const envp = [_:null]?[*:0]const u8{ "TERM=dumb", "PATH=/usr/bin:/bin", "PS1=$ ", null };
        _ = std.c.execve("/bin/sh", &argv, &envp);
        std.c._exit(127);
    }
    return .{ .master = m, .shell = pid };
}

/// pty 출력을 버린다(아무도 읽지 않으면 셸의 끝내기가 출력 비우기에서 멈춘다 — 실측).
pub fn drain(m: c_int) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var pfd = [_]std.c.pollfd{.{ .fd = m, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pfd, 1, 0) <= 0) return;
        if (std.c.read(m, &buf, buf.len) <= 0) return;
    }
}

/// pty 출력에서 `tag` 뒤의 숫자를 기다린다(셸의 메아리 `tag$$` 는 건너뛴다).
pub fn readTagged(m: c_int, tag: []const u8, ms: i64) ?i32 {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        var pfd = [_]std.c.pollfd{.{ .fd = m, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pfd, 1, 100) <= 0) continue;
        const got = std.c.read(m, buf[n..].ptr, buf.len - n);
        if (got <= 0) return null;
        n += @intCast(got);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, buf[0..n], from, tag)) |at| {
            from = at + tag.len;
            var end = from;
            while (end < n and buf[end] >= '0' and buf[end] <= '9') end += 1;
            if (end > from and end < n) return std.fmt.parseInt(i32, buf[from..end], 10) catch null;
        }
        if (n == buf.len) n = 0;
    }
    return null;
}

fn shellOwner(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "ems");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?shellown=1"));
    r.pump(300);
    const base = benchOf(r, 1);
    const pty = spawnShell() orelse return error.SpawnFailed;
    // 거두기 전에 master 를 닫는다(LIFO — 닫지 않으면 끝나는 셸이 출력 비우기에서 멈춰 waitpid 가 영영 기다린다).
    defer reap(pty.shell);
    defer _ = std.c.close(pty.master);
    // 사람이 친 한 번짜리 명령 흉내 — foreground 작업이 되어 제 pid 를 알리고 머문다(`exec` 라 pid 그대로).
    const line = "sh -c 'echo MARU_CLI=$$; exec sleep 60'\n";
    _ = std.c.write(pty.master, line.ptr, line.len);
    const cli = readTagged(pty.master, "MARU_CLI=", 8000) orelse return error.NoCliPid;
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(200), .awake) catch {};
    var wall: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &wall);
    const now_us: u64 = @as(u64, @intCast(wall.sec)) * std.time.us_per_s + @as(u64, @intCast(@divTrunc(wall.nsec, 1000))); // 벽시계 — `start_us` 와 같은 시계
    const found = self_origin.findOrigin(fullProvider(), cli, getuid(), now_us);
    const origin = switch (found) {
        .origin => |o| o,
        .reject => |why| {
            report(false, "emu-cond-shell-owner", std.fmt.bufPrint(&d, "1g 거절 {s}", .{@tagName(why)}) catch "");
            return;
        },
    };
    const owner = self_origin.ownerOf(origin, false) orelse {
        report(false, "emu-cond-shell-owner", std.fmt.bufPrint(&d, "주인 없음 — job {d} peer {d} shell {d}", .{ origin.job_pid, origin.peer_pid, origin.shell_pid }) catch "");
        return;
    };
    const is_shell = owner.shell and owner.job.pid == pty.shell and origin.job_pid == cli and origin.peer_pid == cli;
    _ = try r.emulate(1, cpuOn(4));
    const slow = benchOf(r, 1);
    // 명령이 끝난다(사람이 친 CLI 는 곧 끝난다) — 주인은 셸이라 조건이 남는다(판정자가 maru 역할로 주인을 본다).
    _ = std.c.kill(cli, std.c.SIG.KILL);
    drain(pty.master);
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(300), .awake) catch {};
    const kept = self_origin.ownerAlive(fullProvider(), owner);
    const still = if (kept) benchOf(r, 1) else 0;
    // 셸이 끝난다(`exit`) — 판정자가 거두기 전에도 끝난 것으로 본다(이 macOS 의 `proc_pidinfo` 는 좀비에 0 을 돌려준다 — 실측).
    const bye = "exit\n";
    _ = std.c.write(pty.master, bye.ptr, bye.len);
    var gone = false;
    const deadline = os.nowMs() + 5000;
    while (os.nowMs() < deadline and !gone) {
        drain(pty.master);
        gone = !self_origin.ownerAlive(fullProvider(), owner);
        if (!gone) std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(50), .awake) catch {};
    }
    if (gone) _ = try r.emulate(1, .{ .browser = 0 });
    const back = benchOf(r, 1);
    report(is_shell and slow * 10 >= base * 25 and kept and still * 10 >= base * 25 and gone and back * 10 <= base * 16, "emu-cond-shell-owner", std.fmt.bufPrint(&d, "보통 {d} ms, 셸 {d} 에서 친 명령 {d}: 출처 job {d} peer {d} shell {d} → 주인 {s} {d}, 걸림 {d} ms, 명령 끝남 → 주인 살아 있음 {} {d} ms, 셸 exit → 끝남 {} → 지움 뒤 {d} ms", .{ base, pty.shell, cli, origin.job_pid, origin.peer_pid, origin.shell_pid, owner.kind(), owner.job.pid, slow, kept, still, gone, back }) catch "");
}

/// `sleep 120` 자식(주인 흉내) — pid.
fn spawnSleeper() ?i32 {
    const pid = std.c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sleep", "120", null };
        _ = std.c.execve("/bin/sleep", &argv, std.c.environ);
        std.c._exit(127);
    }
    return pid;
}

pub fn reap(pid: i32) void {
    _ = std.c.kill(pid, std.c.SIG.KILL);
    var st: c_int = 0;
    _ = std.c.waitpid(pid, &st, 0);
}

// ── trace 운전 ──────────────────────────────────────────────────────────────────────────────────────────────

pub var trace_gen: u32 = 100;

pub fn startTrace(r: *Run, b: u64, duration_ms: u32, screenshots: bool) !u32 {
    trace_gen += 1;
    r.tr_state_n = 0;
    r.tr_gz.clearRetainingCapacity();
    r.tr_gz_bad = false;
    r.tr_frames.clearRetainingCapacity();
    r.tr_frame_lens.clearRetainingCapacity();
    try r.host.send(.{ .trace = .{ .browser = b, .generation = trace_gen, .action = .start, .duration_ms = duration_ms, .screenshots = screenshots } });
    return trace_gen;
}

/// 그 세대의 마지막 상태가 끝(done·discarded·failed)인가.
pub fn lastState(r: *const Run, gen: u32) ?msg.TraceState {
    var i = r.tr_state_n;
    while (i > 0) {
        i -= 1;
        if (r.tr_states[i].generation == gen) return r.tr_states[i];
    }
    return null;
}

pub fn finishedAt(r: *Run, gen64: u64, _: u32) bool {
    const st = lastState(r, @intCast(gen64)) orelse return false;
    return st.state == .done or st.state == .discarded or st.state == .failed;
}

pub fn recordingAt(r: *Run, gen64: u64, _: u32) bool {
    const st = lastState(r, @intCast(gen64)) orelse return false;
    return st.state != .starting;
}

pub fn waitFinished(r: *Run, gen: u32, ms: u32) ?msg.TraceState {
    _ = r.until(finishedAt, gen, 0, ms);
    return lastState(r, gen);
}

/// 거른 결과(`trace_filter_main.zig` 의 `result.txt`).
pub const Filtered = struct {
    outcome: []const u8 = "-",
    kept: u64 = 0,
    dropped: u64 = 0,
    screenshots: u64 = 0,
    long_tasks: u64 = 0,
    /// 요약의 `frames_presented`(가족의 DrawFrame).
    frames: u64 = 0,
    gz: []u8 = &.{},
    foreign: []const u8 = "-",
    /// 결정 12: 가를 수 없어 뺀 이벤트 수(`comp_dropped=`).
    comp_dropped: u64 = 0,
    text: []u8 = &.{},

    pub fn deinit(self: *Filtered, gpa: std.mem.Allocator) void {
        gpa.free(self.gz);
        gpa.free(self.text);
    }
};

pub fn readAll(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn writeAll(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) return error.WriteFailed;
        at += @intCast(n);
    }
}

var filter_exe_buf: [1024]u8 = undefined;
var filter_exe: [:0]const u8 = "";
var work_dir_buf: [1024]u8 = undefined;
pub var work_dir: [:0]const u8 = "";

pub fn setup(host_path: []const u8, root: []const u8) !void {
    const dir = std.fs.path.dirname(host_path) orelse ".";
    filter_exe = try std.fmt.bufPrintSentinel(&filter_exe_buf, "{s}/maru-web-trace-filter", .{dir}, 0);
    work_dir = try std.fmt.bufPrintSentinel(&work_dir_buf, "{s}/trf", .{root}, 0);
    _ = std.c.mkdir(work_dir, 0o700);
}

/// 받은 gzip 과 프레임 집합을 maru 의 거르기에 넣는다.
pub fn filterNow(r: *const Run, gpa: std.mem.Allocator) !Filtered {
    var pb: [1100]u8 = undefined;
    try writeAll(try std.fmt.bufPrintSentinel(&pb, "{s}/trace.gz", .{work_dir}, 0), r.tr_gz.items);
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(gpa);
    for (r.tr_frames.items, r.tr_frame_lens.items) |*b, n| {
        try ids.appendSlice(gpa, b[0..n]);
        try ids.append(gpa, '\n');
    }
    try writeAll(try std.fmt.bufPrintSentinel(&pb, "{s}/frames.txt", .{work_dir}, 0), ids.items);
    // 결정 12: 앱처럼 마지막 `done` 의 프로세스 나눔 표시를 거르기에 넘긴다.
    var shared = false;
    var si = r.tr_state_n;
    while (si > 0) {
        si -= 1;
        if (r.tr_states[si].state == .done) {
            shared = r.tr_states[si].shared_process;
            break;
        }
    }
    try writeAll(try std.fmt.bufPrintSentinel(&pb, "{s}/shared.txt", .{work_dir}, 0), if (shared) "1" else "0");
    _ = std.c.unlink(try std.fmt.bufPrintSentinel(&pb, "{s}/result.txt", .{work_dir}, 0));
    if (!os.run(&.{ filter_exe.ptr, work_dir.ptr })) return error.FilterFailed;
    var out: Filtered = .{};
    errdefer out.deinit(gpa);
    out.text = try readAll(gpa, try std.fmt.bufPrintSentinel(&pb, "{s}/result.txt", .{work_dir}, 0));
    out.gz = try readAll(gpa, try std.fmt.bufPrintSentinel(&pb, "{s}/kept.gz", .{work_dir}, 0));
    var it = std.mem.tokenizeAny(u8, out.text, " \n");
    out.outcome = it.next() orelse "-";
    out.kept = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    out.dropped = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    out.screenshots = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    out.long_tasks = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    out.frames = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    _ = it.next(); // gz len
    out.foreign = it.next() orelse "-";
    if (std.mem.indexOf(u8, out.text, "comp_dropped=")) |at| {
        const rest = out.text[at + "comp_dropped=".len ..];
        var e: usize = 0;
        while (e < rest.len and std.ascii.isDigit(rest[e])) e += 1;
        out.comp_dropped = std.fmt.parseInt(u64, rest[0..e], 10) catch 0;
    }
    return out;
}

pub fn gunzipContains(gpa: std.mem.Allocator, gz: []const u8, needle: []const u8) bool {
    var in: std.Io.Reader = .fixed(gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = d.reader.streamRemaining(&out.writer) catch return false;
    return std.mem.indexOf(u8, out.written(), needle) != null;
}

pub fn runTrace(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try emu.startServer();
    try setup(host_path, root);
    basic(report, host_path, root) catch |e| report(false, "tr-basic", @errorName(e));
    hiddenFocus(report, host_path, root) catch |e| report(false, "tr-hidden-focus", @errorName(e));
    mixed(report, host_path, root) catch |e| report(false, "tr-mixed-content", @errorName(e));
    humanAndBusy(report, host_path, root) catch |e| report(false, "tr-human-input", @errorName(e));
    closedAndGuard(report, host_path, root) catch |e| report(false, "tr-tab-closed", @errorName(e));
}

fn basic(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "trb");
    defer sess.deinit();
    const r = &sess.run;
    const gpa = std.heap.c_allocator;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?t=1"));
    try r.create(2, emu.uLocal(&u, "/vp?first"));
    r.pump(500);
    const gen = try startTrace(r, 1, 2500, true);
    _ = r.until(recordingAt, gen, 0, 8000);
    const rec = lastState(r, gen);
    // 기록하는 동안 다른 탭(다른 사이트)이 비밀 주소로 옮긴다 — 남긴 trace 에 없어야 한다(o2→o3).
    try r.nav(2, emu.uLocal(&u, "/vp?token=OTHERTABSECRET"));
    _ = r.ev(1, "LONG(120)", &u);
    const done = waitFinished(r, gen, 30_000);
    var res = try filterNow(r, gpa);
    defer res.deinit(gpa);
    const raw_has = gunzipContains(gpa, r.tr_gz.items, "OTHERTABSECRET");
    const kept_has = res.gz.len > 0 and gunzipContains(gpa, res.gz, "OTHERTABSECRET");
    const ok = rec != null and rec.?.state == .recording and !rec.?.focus_emulated and done != null and done.?.state == .done and done.?.reason == .duration and
        done.?.gz_bytes == r.tr_gz.items.len and !r.tr_gz_bad and r.tr_frames.items.len > 0 and std.mem.eql(u8, res.outcome, "kept") and res.kept > 100 and
        res.screenshots > 0 and res.long_tasks >= 1 and res.gz.len > 0 and !kept_has;
    report(ok, "tr-basic", std.fmt.bufPrint(&d, "기록 {s} focus={} → 끝 {s}/{s} 덮음 {d} ms, gzip {d} B(조각 이음 {}), 프레임 {d}, 거르기 {s} 남김 {d}·버림 {d}·스크린샷 {d}·긴 작업 {d}, 다른 탭 주소: 원본 {} 남김 {}", .{
        if (rec) |x| @tagName(x.state) else "-", if (rec) |x| x.focus_emulated else false, if (done) |x| @tagName(x.state) else "-", if (done) |x| @tagName(x.reason) else "-", if (done) |x| x.covered_ms else 0, r.tr_gz.items.len, !r.tr_gz_bad, r.tr_frames.items.len, res.outcome, res.kept, res.dropped, res.screenshots, res.long_tasks, raw_has, kept_has,
    }) catch "");
    // 요청 멈춤 — 10 초를 1 초에 멈춘다.
    const g2 = try startTrace(r, 1, 10_000, false);
    _ = r.until(recordingAt, g2, 0, 8000);
    r.pump(1000);
    try r.host.send(.{ .trace = .{ .browser = 1, .generation = g2, .action = .stop } });
    const early = waitFinished(r, g2, 30_000);
    // 큰 trace(관측) — 10 초, 스크린샷 포함: 멈춤부터 끝까지(압축하지 않은 스트림을 읽어 sidecar 가 gzip 으로 묶는 시간).
    const g3 = try startTrace(r, 1, 10_000, true);
    _ = r.until(recordingAt, g3, 0, 8000);
    r.pump(10_000);
    const t0 = os.nowMs();
    const big = waitFinished(r, g3, 60_000);
    const dt = os.nowMs() - t0;
    report(big != null and big.?.state == .done, "tr-large(obs)", std.fmt.bufPrint(&d, "10 s → {s}/{s}, gzip {d} B, 멈춤 뒤 끝까지 ≈{d} ms(이 sidecar 빌드)", .{ if (big) |x| @tagName(x.state) else "-", if (big) |x| @tagName(x.reason) else "-", r.tr_gz.items.len, dt }) catch "");
    // trace 가 끝난 뒤에도 그 탭의 새 문서에 sidecar 의 문서 스크립트(위치 보정 — W5b2)가 들어간다: trace 가 그 탭의 DevTools 세션에서
    // `Page.disable` 을 보내면 Blink 가 `addScriptToEvaluateOnNewDocument` 를 지운다(구현 적대 리뷰 H1).
    var gb: [64]u8 = undefined;
    var gb2: [64]u8 = undefined;
    const geo_before = r.ev(2, "String(navigator.geolocation.__maruGeo)", &gb2);
    try r.nav(1, emu.uLoop(&u, "/tr?after=1"));
    r.pump(1500);
    const geo_after = r.ev(1, "String(navigator.geolocation.__maruGeo)", &gb);
    report(std.mem.eql(u8, geo_before, "1") and std.mem.eql(u8, geo_after, "1"), "tr-page-scripts-kept", std.fmt.bufPrint(&d, "trace 를 세 번 돈 탭의 새 문서 위치 보정 {s}(대조 — trace 없는 탭 {s})", .{ geo_after, geo_before }) catch "");
    report(early != null and early.?.state == .done and early.?.reason == .requested and early.?.covered_ms < 3000 and early.?.covered_ms >= 800, "tr-stop-early", std.fmt.bufPrint(&d, "{s}/{s} 덮음 {d} ms", .{ if (early) |x| @tagName(x.state) else "-", if (early) |x| @tagName(x.reason) else "-", if (early) |x| x.covered_ms else 0 }) catch "");
}

fn hiddenFocus(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "trh");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    var a: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    var c2: [200]u8 = undefined;
    var e2: [200]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?h=1"));
    try r.host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
    r.pump(800);
    const before = r.ev(1, "ST()", &a);
    const gen = try startTrace(r, 1, 3000, true);
    _ = r.until(recordingAt, gen, 0, 8000);
    const rec = lastState(r, gen);
    r.pump(300);
    const during1 = r.ev(1, "ST()", &b2);
    r.pump(1000);
    const during2 = r.ev(1, "ST()", &c2);
    // 기록 중 maru 의 레이아웃이 숨김을 다시 보내도(바뀜 기반이라 드물다) focus 흉내가 이긴다(PHASE0_v3 A2).
    try r.host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
    r.pump(300);
    const done = waitFinished(r, gen, 30_000);
    r.pump(800);
    const after1 = r.ev(1, "ST()", &e2);
    var f2: [200]u8 = undefined;
    r.pump(1000);
    const after2 = r.ev(1, "ST()", &f2);
    const frames = struct {
        fn of(s: []const u8) i64 {
            const at = std.mem.indexOf(u8, s, "\"frames\":") orelse return -1;
            var e = at + 9;
            while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
            return std.fmt.parseInt(i64, s[at + 9 .. e], 10) catch -1;
        }
    }.of;
    const ok = contains(before, "\"vis\":\"hidden\"") and rec != null and rec.?.focus_emulated and contains(during1, "\"vis\":\"visible\"") and frames(during2) > frames(during1) and
        done != null and done.?.state == .done and done.?.focus_emulated and contains(after1, "\"vis\":\"hidden\"") and frames(after2) == frames(after1);
    report(ok, "tr-hidden-focus", std.fmt.bufPrint(&d, "전 {s} | 기록 focus={} | 중 {s} → {s} | 끝 {s} focus={} | 뒤 {s} → {s}", .{ before, if (rec) |x| x.focus_emulated else false, during1, during2, if (done) |x| @tagName(x.state) else "-", if (done) |x| x.focus_emulated else false, after1, after2 }) catch "");
}

fn mixed(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "trm");
    defer sess.deinit();
    const r = &sess.run;
    const gpa = std.heap.c_allocator;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?m=1"));
    // 사용자 탭(localhost) 안의 127.0.0.1 iframe — T 의 렌더러 프로세스에 든다(o1).
    try r.create(2, emu.uLocal(&u, "/tu"));
    r.pump(1000);
    const gen = try startTrace(r, 1, 2500, false);
    const done = waitFinished(r, gen, 30_000);
    var res = try filterNow(r, gpa);
    defer res.deinit(gpa);
    const raw_has = gunzipContains(gpa, r.tr_gz.items, "IFRAMEWORK") or gunzipContains(gpa, r.tr_gz.items, "IFRAMEUSERSECRET");
    report(done != null and done.?.state == .done and std.mem.eql(u8, res.outcome, "mixed_content") and res.gz.len == 0, "tr-mixed-content", std.fmt.bufPrint(&d, "끝 {s}, 거르기 {s}(남의 프레임 {s}), 원본에 사용자 iframe 흔적 {}", .{ if (done) |x| @tagName(x.state) else "-", res.outcome, res.foreign, raw_has }) catch "");
    // 대조: 사용자 탭을 닫으면 같은 trace 가 남는다(헛폐기 없음).
    try r.host.send(.{ .destroy_browser = 2 });
    r.pump(1500);
    const g2 = try startTrace(r, 1, 2000, false);
    _ = waitFinished(r, g2, 30_000);
    var res2 = try filterNow(r, gpa);
    defer res2.deinit(gpa);
    report(std.mem.eql(u8, res2.outcome, "kept"), "tr-mixed-control", std.fmt.bufPrint(&d, "사용자 탭을 닫은 뒤 거르기 {s}(남김 {d})", .{ res2.outcome, res2.kept }) catch "");
}

fn humanAndBusy(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "tri");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?i=1"));
    try r.create(2, emu.uLocal(&u, "/tr?i=2"));
    r.pump(500);
    const gen = try startTrace(r, 1, 5000, false);
    _ = r.until(recordingAt, gen, 0, 8000);
    // 다른 탭의 trace 는 브라우저에 하나라 실패.
    trace_gen += 1;
    const busy_gen = trace_gen;
    try r.host.send(.{ .trace = .{ .browser = 2, .generation = busy_gen, .action = .start, .duration_ms = 2000 } });
    _ = r.until(finishedAt, busy_gen, 0, 5000);
    const busy = lastState(r, busy_gen);
    report(busy != null and busy.?.state == .failed and busy.?.reason == .busy, "tr-busy", std.fmt.bufPrint(&d, "둘째 start → {s}/{s}", .{ if (busy) |x| @tagName(x.state) else "-", if (busy) |x| @tagName(x.reason) else "-" }) catch "");
    r.userClick(1, 50, 50);
    const done = waitFinished(r, gen, 10_000);
    r.pump(1500);
    // 버린 뒤 자리가 풀린다(완료가 온 뒤) — 다음 trace 가 된다.
    const g2 = try startTrace(r, 2, 1500, false);
    _ = r.until(recordingAt, g2, 0, 8000);
    const next = lastState(r, g2);
    _ = waitFinished(r, g2, 20_000);
    report(done != null and done.?.state == .discarded and done.?.reason == .human_input and next != null and next.?.state == .recording, "tr-human-input", std.fmt.bufPrint(&d, "사람의 누름 → {s}/{s}, 다음 trace {s}", .{ if (done) |x| @tagName(x.state) else "-", if (done) |x| @tagName(x.reason) else "-", if (next) |x| @tagName(x.state) else "-" }) catch "");
}

fn closedAndGuard(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "trc");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?c=1"));
    try r.create(2, emu.uLocal(&u, "/tr?c=2"));
    r.pump(500);
    const gen = try startTrace(r, 1, 8000, false);
    _ = r.until(recordingAt, gen, 0, 8000);
    try r.host.send(.{ .destroy_browser = 1 });
    const done = waitFinished(r, gen, 10_000);
    r.pump(1000);
    const g2 = try startTrace(r, 2, 1500, false);
    _ = r.until(recordingAt, g2, 0, 8000);
    const next = lastState(r, g2);
    const fin = waitFinished(r, g2, 20_000);
    report(done != null and done.?.state == .failed and done.?.reason == .tab_closed and next != null and next.?.state == .recording and fin != null and fin.?.state == .done, "tr-tab-closed", std.fmt.bufPrint(&d, "닫힘 → {s}/{s}, 다음 탭 {s} → {s}", .{ if (done) |x| @tagName(x.state) else "-", if (done) |x| @tagName(x.reason) else "-", if (next) |x| @tagName(x.state) else "-", if (fin) |x| @tagName(x.state) else "-" }) catch "");
    var refused: usize = 0;
    for ([_][]const u8{ "Tracing.start", "Tracing.end", "IO.read", "HeapProfiler.takeHeapSnapshot", "Performance.getMetrics", "Profiler.enable" }) |m| {
        const st = r.call(2, m, "{}", 5000) catch null;
        if (st != null and st.? == .invalid_request) refused += 1; // 막은 메서드는 `invalid_request`(devtools.zig — Network.enable 과 같은 길)
    }
    const control = r.call(2, "Browser.getVersion", "{}", 5000) catch null;
    report(refused == 6 and control != null and control.? == .ok, "tr-guard", std.fmt.bufPrint(&d, "maru 경유 Tracing·IO·HeapProfiler·Performance·Profiler 거절 {d}/6, 대조 Browser.getVersion {s}", .{ refused, if (control) |c| @tagName(c) else "-" }) catch "");
}

// ── CPU·네트워크 조건(`--emulation` 의 끝) ────────────────────────────────────────────────────────────────

pub fn benchOf(r: *Run, b: u64) i64 {
    var o: [64]u8 = undefined;
    var best: i64 = std.math.maxInt(i64);
    for (0..3) |_| {
        const t = r.ev(b, "bench()", &o);
        const n = std.fmt.parseInt(i64, t, 10) catch continue;
        best = @min(best, n);
    }
    return best;
}

pub fn cpuOn(rate: f32) msg.Emulation {
    return .{ .browser = 0, .flags = .{ .cpu = true }, .cpu_rate = rate };
}

pub fn runConditions(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    try emu.startServer();
    cpu(report, host_path, root) catch |e| report(false, "emu-cpu", @errorName(e));
    network(report, host_path, root) catch |e| report(false, "emu-net-latency", @errorName(e));
    ownerExit(report, host_path, root) catch |e| report(false, "emu-cond-owner-exit", @errorName(e));
    shellOwner(report, host_path, root) catch |e| report(false, "emu-cond-shell-owner", @errorName(e));
}

fn cpu(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "emc");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?cpu=1"));
    r.pump(300);
    const base = benchOf(r, 1);
    const st = try r.emulate(1, cpuOn(4));
    const slow = benchOf(r, 1);
    _ = try r.emulate(1, .{ .browser = 0 });
    const back = benchOf(r, 1);
    const cpu_bit: u16 = 1 << 7;
    report(st != null and st.?.active_mask & cpu_bit != 0 and slow * 10 >= base * 25 and back * 10 <= base * 16, "emu-cpu", std.fmt.bufPrint(&d, "보통 {d} ms → 4 배 {d} ms(걸림 0x{x}) → 지움 {d} ms", .{ base, slow, if (st) |s| s.active_mask else 0, back }) catch "");
    // 걸린 뒤 같은 렌더러에 남의 프레임이 들어온다(사용자 탭 안의 같은 사이트 iframe) — 곧 풀고 이유(process_shared).
    _ = try r.emulate(1, cpuOn(4));
    try r.create(2, emu.uLocal(&u, "/tu"));
    r.pump(1500);
    const rel = r.st[1];
    const after_share = benchOf(r, 1);
    var o: [200]u8 = undefined;
    const iframe = r.ev(2, "IF()", &o);
    report(rel != null and rel.?.released_mask & cpu_bit != 0 and rel.?.cpu_release == .process_shared and after_share * 10 <= base * 16, "emu-cpu-released-on-share", std.fmt.bufPrint(&d, "풀림 0x{x} {s}, 그 뒤 {d} ms, 사용자 iframe {s}", .{ if (rel) |s| s.released_mask else 0, if (rel) |s| @tagName(s.cpu_release) else "-", after_share, iframe }) catch "");
    // maru 가 풀림을 받는다 — 그 무리를 뺀 상태(풀림 회차가 끝난다). 이제 걸면 걸지 않고 이유를 싣는다(나눔이 그대로다).
    _ = try r.emulate(1, .{ .browser = 0 });
    const cleared = r.st[1];
    const refused = try r.emulate(1, cpuOn(4));
    const still = benchOf(r, 1);
    var o2: [200]u8 = undefined;
    const iframe2 = r.ev(2, "IF()", &o2);
    report(cleared != null and cleared.?.released_mask == 0 and refused != null and refused.?.failed_mask & cpu_bit != 0 and refused.?.reason == .process_shared and still * 10 <= base * 16, "emu-cpu-process-shared", std.fmt.bufPrint(&d, "회차 끝 released=0x{x}, 다시 걸기 → 실패 0x{x} {s}, CPU {d} ms, 사용자 iframe {s}", .{ if (cleared) |s| s.released_mask else 0xffff, if (refused) |s| s.failed_mask else 0, if (refused) |s| @tagName(s.reason) else "-", still, iframe2 }) catch "");
    // 사람이 몰면 푼다(풀림 회차).
    try r.host.send(.{ .destroy_browser = 2 });
    r.pump(1500);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .cpu = true, .network = true }, .cpu_rate = 4, .latency_ms = 300 });
    r.userClick(1, 20, 20);
    r.pump(800);
    const hu = r.st[1];
    const after_human = benchOf(r, 1);
    var o3: [64]u8 = undefined;
    const ft = r.ev(1, "ft('/x?h')", &o3);
    report(hu != null and hu.?.released_mask == (1 << 7) | (1 << 8) and hu.?.cpu_release == .human_input and hu.?.network_release == .human_input and after_human * 10 <= base * 16 and !contains(ft, "err"), "emu-cond-human", std.fmt.bufPrint(&d, "사람의 누름 → 풀림 0x{x} {s}/{s}, CPU {d} ms, 가져오기 {s}", .{ if (hu) |s| s.released_mask else 0, if (hu) |s| @tagName(s.cpu_release) else "-", if (hu) |s| @tagName(s.network_release) else "-", after_human, ft }) catch "");
}

fn ftMs(s: []const u8) i64 {
    const sp = std.mem.lastIndexOfScalar(u8, s, ' ') orelse return -1;
    return std.fmt.parseInt(i64, s[sp + 1 ..], 10) catch -1;
}

fn network(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "emn");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    var o: [64]u8 = undefined;
    var o2: [64]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?net=1"));
    try r.create(2, emu.uLocal(&u, "/tu"));
    r.pump(1000);
    const st = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true }, .latency_ms = 500 });
    const slow = r.ev(1, "ft('/x?a')", &o);
    _ = try r.emulate(1, .{ .browser = 0 });
    const fast = r.ev(1, "ft('/x?b')", &o2);
    const net_bit: u16 = 1 << 8;
    report(st != null and st.?.active_mask & net_bit != 0 and ftMs(slow) >= 450 and ftMs(fast) >= 0 and ftMs(fast) < 300, "emu-net-latency", std.fmt.bufPrint(&d, "지연 500 → {s}(걸림 0x{x}), 지움 → {s}", .{ slow, if (st) |s| s.active_mask else 0, fast }) catch "");
    // 오프라인 — 요청 막기 + navigator.onLine(같은 렌더러의 사용자 iframe 도 — 결정 3).
    const off = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    var a: [200]u8 = undefined;
    var b: [200]u8 = undefined;
    var c: [64]u8 = undefined;
    const t_st = r.ev(1, "ST()", &a);
    const t_ft = r.ev(1, "ft('/x?c')", &c);
    const if_st = r.ev(2, "IF()", &b);
    _ = try r.emulate(1, .{ .browser = 0 });
    var a2: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    const t_back = r.ev(1, "ST()", &a2);
    const if_back = r.ev(2, "IF()", &b2);
    report(off != null and off.?.active_mask & net_bit != 0 and contains(t_st, "\"online\":false") and contains(t_ft, "err") and contains(if_st, "\"online\":false") and contains(t_back, "\"online\":true") and contains(if_back, "\"online\":true"), "emu-net-offline", std.fmt.bufPrint(&d, "오프라인 T {s} 가져오기 {s}, 사용자 iframe {s} | 지움 T {s}, iframe {s}", .{ t_st, t_ft, if_st[0..@min(if_st.len, 80)], t_back, if_back[0..@min(if_back.len, 80)] }) catch "");
    // 렌더러가 죽은 동안 오프라인을 풀면 — 쌓았다가 새 렌더러에(전에는 사라져 다시 불러온 뒤에도 오프라인이었다 — a3_dead2, W9d③ 엄격 끄기도 같은 길).
    try r.host.send(.{ .destroy_browser = 2 });
    r.pump(1000);
    _ = try r.emulate(1, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    const killed = r.killRenderers();
    _ = r.until(Run.goneAt, 1, 1, 8000);
    r.pump(500);
    _ = try r.emulate(1, .{ .browser = 0 });
    try r.action(1, .reload);
    r.pump(800);
    var e: [200]u8 = undefined;
    var f: [64]u8 = undefined;
    const revived = r.ev(1, "ST()", &e);
    const revived_ft = r.ev(1, "ft('/x?d')", &f);
    report(killed > 0 and contains(revived, "\"online\":true") and !contains(revived_ft, "err"), "emu-net-dead-release", std.fmt.bufPrint(&d, "렌더러 {d} 죽임, 죽은 동안 풂 → 다시 불러온 뒤 {s} 가져오기 {s}", .{ killed, revived, revived_ft }) catch "");
    // 조건을 쓴 적 없는 탭의 렌더러가 죽은 뒤 처음 거는 offline — 새 렌더러에서도 걸린다(구현 적대 리뷰 2 회차 M-a: 전에는 죽은 렌더러로
    // 곧 나가 사라졌다). main 위로 옮길 때(2026-11-12) 기대를 바꿨다: 옛 W9e② 는 죽은 동안 렌더러 쪽 명령(`Network.enable` 포함)을 쌓아 새 문서에서
    // 냈으므로 다시 불러온 **첫 문서 요청은 오프라인 밖**이었다(남은 틈 L-d — 이 판정은 그 꼴로 「문서가 서고 그 안의 onLine false」 를 봤다).
    // main 의 9 차 길(죽은 동안에도 보내고 그 첫 답에 다시 맞춘다)은 `Network.enable` 의 브라우저 쪽 몫이 곧 들어 ByRule 오프라인이 첫 문서
    // 요청부터 듣는다 — 살아 있는 탭의 오프라인 새로고침과 같다(오류 페이지). 그래서 다시 불러온 문서가 막혀 오류 페이지가 서고 그 렌더러의
    // `navigator.onLine` 도 거짓인지, 지운 뒤 다시 불러오면 문서가 서고 온라인인지 본다.
    try r.create(3, emu.uLoop(&u, "/tr?fresh=1"));
    _ = r.until(Run.loadsAt, 3, 1, 8000);
    r.pump(500);
    const killed2 = r.killRenderers();
    _ = r.until(Run.goneAt, 3, 1, 8000);
    r.pump(500);
    _ = try r.emulate(3, .{ .browser = 0, .flags = .{ .network = true, .offline = true } });
    try r.action(3, .reload);
    r.pump(1000);
    var g: [200]u8 = undefined;
    var h: [200]u8 = undefined;
    const fresh = r.ev(3, "location.protocol+'|'+navigator.onLine+'|'+(typeof ST)", &g);
    _ = try r.emulate(3, .{ .browser = 0 });
    try r.action(3, .reload);
    r.pump(800);
    const fresh_back = r.ev(3, "ST()", &h);
    report(killed2 > 0 and !contains(fresh, "http") and contains(fresh, "|false|undefined") and contains(fresh_back, "\"online\":true"), "emu-net-dead-set-fresh", std.fmt.bufPrint(&d, "렌더러 {d} 죽임, 조건 없던 탭에 죽은 동안 offline → 다시 불러온 첫 문서 {s}(오류 페이지·onLine 거짓이어야) → 지우고 다시 {s}", .{ killed2, fresh, fresh_back }) catch "");
}

fn ownerExit(report: Report, host_path: [:0]const u8, root: []const u8) !void {
    var sess: Session = undefined;
    try emu.open(&sess, host_path, root, "emo");
    defer sess.deinit();
    const r = &sess.run;
    var u: [256]u8 = undefined;
    var d: [1500]u8 = undefined;
    try r.create(1, emu.uLoop(&u, "/tr?own=1"));
    r.pump(300);
    const base = benchOf(r, 1);
    // 에이전트(CLI 의 주인)와 MCP 서버(holder) 흉내 — 진짜 자식 프로세스.
    const agent_pid = spawnSleeper() orelse return error.SpawnFailed;
    const mcp_pid = spawnSleeper() orelse return error.SpawnFailed;
    defer reap(agent_pid);
    defer reap(mcp_pid);
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(100), .awake) catch {};
    const agent_info = lookup(&provider_ctx, agent_pid) orelse return error.NoProcInfo;
    const mcp_info = lookup(&provider_ctx, mcp_pid) orelse return error.NoProcInfo;
    const cli_owner: self_origin.Owner = .{ .job = .{ .pid = agent_pid, .start_us = agent_info.start_us } };
    const mcp_owner: self_origin.Owner = .{ .job = .{ .pid = agent_pid, .start_us = agent_info.start_us }, .holder = .{ .pid = mcp_pid, .start_us = mcp_info.start_us } };
    _ = try r.emulate(1, cpuOn(4));
    const slow = benchOf(r, 1);
    const alive_before = self_origin.ownerAlive(provider(), cli_owner) and self_origin.ownerAlive(provider(), mcp_owner);
    // MCP 연결이 끊긴다 — holder 프로세스가 끝난다.
    reap(mcp_pid);
    const mcp_gone = !self_origin.ownerAlive(provider(), mcp_owner) and self_origin.ownerAlive(provider(), cli_owner);
    // 에이전트가 끝난다 — maru 가 그 무리를 지우고 보낸다(판정자가 maru 역할).
    reap(agent_pid);
    const cli_gone = !self_origin.ownerAlive(provider(), cli_owner);
    if (cli_gone) _ = try r.emulate(1, .{ .browser = 0 });
    const back = benchOf(r, 1);
    report(alive_before and mcp_gone and cli_gone and slow * 10 >= base * 25 and back * 10 <= base * 16, "emu-cond-owner-exit", std.fmt.bufPrint(&d, "보통 {d} ms, 걸림 {d} ms, 주인 살아 있음 {}, MCP 끊김 → holder 끝남 {}, 에이전트 끝남 {} → 지움 뒤 {d} ms", .{ base, slow, alive_before, mcp_gone, cli_gone, back }) catch "");
}
