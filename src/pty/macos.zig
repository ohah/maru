const std = @import("std");
const builtin = @import("builtin"); // 이 파일은 macOS 전용이지만 테스트는 Linux CI에서도 컴파일된다 — skip 가드용
const terminal = @import("../terminal.zig");
const types = @import("types.zig");
// maru 자체 terminfo 로컬 캐시(경로·버전·컴파일 명령)의 단일 출처. `maru terminfo` 서브커맨드(cli)와 공유해,
// 서브커맨드로 재컴파일한 캐시를 여기 spawn 자동 컴파일이 그대로 재사용한다(top-level 중립 모듈 — color.zig 결).
const terminfo_cache = @import("../terminfo_cache.zig");
const user_paths = @import("../user_paths.zig"); // 캐시 base 판정(OS 인자 순수 정책 — 계약 §5.3)

// macOS의 첫 backend는 openpty로 master/slave fd만 만들고 fork/exec는 직접 한다.
// 이 경계가 있어야 cwd/env/stdio/controlling-terminal 실패를 단계별 artifact로 남길 수 있다.
extern "c" fn openpty(
    amaster: *std.c.fd_t,
    aslave: *std.c.fd_t,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*std.posix.winsize,
) c_int;

// Used by the session-close grace window between escalation signals.
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;
extern "c" fn waitid(idtype: c_int, id: c_uint, info: *std.c.siginfo_t, options: c_int) c_int;
const waitid_pid: c_int = 1;
const waitid_nohang: c_int = 0x00000001;
const waitid_exited: c_int = 0x00000004;
const waitid_nowait: c_int = 0x00000020;

fn probeChildExitedWithoutReap(pid: std.c.pid_t) error{ChildProbeFailed}!bool {
    while (true) {
        var info = std.mem.zeroes(std.c.siginfo_t);
        const rc = waitid(
            waitid_pid,
            @intCast(pid),
            &info,
            waitid_nohang | waitid_exited | waitid_nowait,
        );
        if (rc == 0) return info.pid == pid;
        if (std.posix.errno(rc) == .INTR) continue;
        return error.ChildProbeFailed;
    }
}

// 포그라운드 프로세스 감지(foregroundProcessNames) — tcgetpgrp: 터미널 포그라운드 pgid,
// proc_listpgrppids: 그 그룹의 실제 구성원, proc_name: 각 pid의 프로세스 이름. 모두 macOS 공개 libSystem/libproc API다.
// login(1) wrapper가 group leader로 남는 제품 spawn 경로에서는 leader 하나만 보면 실제 agent child를 놓치므로 그룹을 열거한다.
extern "c" fn tcgetpgrp(fd: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
extern "c" fn proc_listpgrppids(pgrpid: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;
// proc_listchildpids: 그 pid의 **직속 자식** 목록. 에이전트(claude/codex)는 도구를 실행할 때 자식을 별도 프로세스
// 그룹으로 띄우므로(실측: claude pgid 33854 ↔ 자식 pgid 83612) foreground pgid 열거로는 그 자식을 못 본다.
// 세션 신원 env는 **자식에게만** 내려오므로(agentSessionIdentity) 자식을 직접 열거해야 한다. 공개 libproc API.
extern "c" fn proc_listchildpids(ppid: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;
// proc_pid_rusage: pid 하나의 누적 자원 사용량. 공개 libproc API(<libproc.h>, macOS 10.9+).
// **V0을 쓴다** — 필요한 세 필드(ri_phys_footprint·ri_user_time·ri_system_time)가 V0에 이미 있고 V2와 값이
// 같은데(실측), 필드가 11개(96바이트)뿐이라 손으로 옮기는 extern struct가 틀릴 여지가 가장 작다.
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: ?*anyopaque) c_int;
const rusage_info_v0: c_int = 0;

/// `struct rusage_info_v0`(<sys/resource.h>) 미러. 순서·크기가 헤더와 **정확히** 같아야 한다 —
/// 어긋나면 컴파일러가 못 잡고 값만 조용히 쓰레기가 된다. 아래 comptime 단언이 크기 드리프트를 잡는다.
const RusageInfoV0 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
};
comptime {
    // 16 + 10×8 = 96. 헤더가 바뀌거나 필드를 빠뜨리면 여기서 멈춘다.
    if (@sizeOf(RusageInfoV0) != 96) @compileError("rusage_info_v0 레이아웃이 헤더와 어긋난다");
}

/// 한 pid의 자원 표본. 실패(죽은 pid·권한 밖)면 null — **구조체를 읽지 않는다.**
/// `rc != 0`이면 out이 안 채워져 쓰레기가 나온다(실측: 7.6e12 MB). 샘플링 중 프로세스가 사라지는 것은 정상이다.
pub fn processResourceSample(pid: std.c.pid_t) ?types.ProcessResourceSample {
    var info: RusageInfoV0 = undefined;
    if (proc_pid_rusage(@intCast(pid), rusage_info_v0, &info) != 0) return null;
    return .{
        .pid = @intCast(pid),
        .footprint_bytes = info.phys_footprint,
        .cpu_ns = info.user_time +| info.system_time,
    };
}

/// **이 앱 프로세스 자신**의 표본. 터미널 트리와 달리 pid를 받지 않는다 — 셀 자신이라 `getpid()`다.
/// 상태바가 이 값을 "모든 창 공유" 행으로 합계에 넣는다(docs/status-bar.md §4.1 "앱 자신은 센다").
pub fn selfResourceSample() ?types.ProcessResourceSample {
    return processResourceSample(std.c.getpid());
}

/// `root`와 그 자손의 표본을 `out`에 채우고 개수를 돌려준다(깊이·개수 상한 안에서).
/// `proc_listchildpids`는 **직속 자식만** 주므로 재귀한다. 상한은 폭주 방어다 — fork 폭탄이나 순환에서
/// tick을 붙잡지 않는다(docs/status-bar.md §6 "비용과 게이트").
pub fn processTreeSamples(root: std.c.pid_t, out: []types.ProcessResourceSample) usize {
    if (out.len == 0 or root <= 0) return 0;
    var n: usize = 0;
    collectProcessTree(root, out, &n, 0);
    return n;
}

const max_process_tree_depth: u32 = 8;

fn collectProcessTree(pid: std.c.pid_t, out: []types.ProcessResourceSample, n: *usize, depth: u32) void {
    if (n.* >= out.len or depth > max_process_tree_depth) return;
    if (processResourceSample(pid)) |sample| {
        out[n.*] = sample;
        n.* += 1;
    }
    // 표본을 못 얻어도 자식은 훑는다 — 부모가 권한 밖이어도 자식이 우리 것일 수 있다.
    // ⚠️ `proc_listchildpids`는 **pid 개수**를 돌려준다(바이트가 아니다 — 이 파일 위쪽 905·922행이 같은 규약을
    // 쓴다). 바이트로 보고 4로 나누면 자식이 늘 0이 되어 트리를 못 내려간다(실측으로 그렇게 깨져 있었다).
    var kids: [64]c_int = undefined;
    const child_count = proc_listchildpids(@intCast(pid), &kids, @intCast(@sizeOf(@TypeOf(kids))));
    if (child_count <= 0) return;
    const count = @min(@as(usize, @intCast(child_count)), kids.len);
    for (kids[0..count]) |kid| {
        if (kid <= 0 or kid == pid) continue; // 자기 자신을 자식으로 받으면 무한 재귀다
        collectProcessTree(@intCast(kid), out, n, depth + 1);
    }
}
extern "c" fn getpgid(pid: c_int) c_int;
// proc_pidinfo + PROC_PIDVNODEPATHINFO: pid 하나의 **현재 작업 디렉터리**를 커널에서 직접 읽는다. 공개 libproc
// API(<libproc.h>)다(clean-room: 공개 API 호출만 하고 레퍼런스 코드 표현은 옮기지 않는다 — docs/project-rules.md).
//
// 예전 주석은 "iTerm2·Ghostty가 같은 목적으로 쓰는 사실상 표준 경로"라고 적었는데 **틀렸다** — 레퍼런스 소스로
// 확인하니 Ghostty는 커널을 전혀 묻지 않고 OSC 7만 쓴다(2026-08-13 확인). iTerm2는 확인하지 못했다. 근거는
// 레퍼런스가 아니라 아래 "왜 필요한가"의 실측 세 갈래다. 자세한 내용은 docs/editor-surface-dock.md §3.5.
//
// **왜 필요한가**: `TerminalCore.currentCwd()`는 OSC 7 전용이고 그 보고자는 maru의 zsh precmd 훅뿐이다. 그래서
// ⑴ bash/fish는 cwd가 처음부터 없고, ⑵ claude·codex 같은 전체화면 TUI가 시작하며 RIS(ESC c)를 보내면
// `fullReset`이 cwd를 지워 그 프로그램이 떠 있는 내내 빈 값이 된다(실측). 커널을 물어보면 셸 종류·화면 리셋과
// 무관하게 답이 나온다.
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
const proc_pidvnodepathinfo: c_int = 9;

// `struct proc_vnodepathinfo`를 **손으로 미러하지 않는다.** 그 안의 `vinfo_stat`은 필드가 20개가 넘어,
// `RusageInfoV0`(96 B·11필드) 주석이 경고한 "컴파일러가 못 잡고 값만 조용히 쓰레기가 되는" 위험이 훨씬 크다.
// 우리가 쓰는 건 첫 멤버 `pvi_cdir`의 `vip_path` 하나뿐이므로 **바이트 버퍼 + 오프셋 상수 + 반환 크기 검증**으로
// 읽는다. 상수 유도(<sys/proc_info.h>):
//   vinfo_stat      = 136  (dev4+mode2+nlink2+ino8+uid4+gid4 + i64×10 + blksize4+flags4+gen4+rdev4 + qspare16)
//   vnode_info      = 152  (vinfo_stat 136 + vi_type 4 + vi_pad 4 + fsid_t 8)
//   vnode_info_path = 1176 (vnode_info 152 + vip_path[MAXPATHLEN=1024])
//   proc_vnodepathinfo = 2352 (pvi_cdir + pvi_rdir)
// 오프셋이 틀어져도 조용히 넘어가지 않도록, ⑴ `proc_pidinfo` 반환 바이트가 **정확히 2352**일 때만 읽고
// ⑵ 아래 "자기 pid의 cwd가 getcwd와 같다" 테스트가 레이아웃 드리프트를 실행 시점에 잡는다.
const vnodepathinfo_size: c_int = 2352;
const vnodepathinfo_cdir_path_offset: usize = 152;
const vnodepathinfo_max_path: usize = 1024;

/// `pid`의 현재 작업 디렉터리를 `out`에 채워 돌려준다. 못 얻으면 null — **부분 경로를 돌려주지 않는다**
/// (자른 경로로 엉뚱한 디렉터리를 저장소 루트로 오인하면 남의 저장소 상태를 보여 주게 된다).
///
/// 죽은 pid·권한 밖·다른 사용자 프로세스는 실패가 정상이다(호출자가 다음 후보로 넘어간다).
pub fn processCwdForPid(pid: std.c.pid_t, out: []u8) ?[]const u8 {
    if (pid <= 0) return null;
    var info: [@as(usize, @intCast(vnodepathinfo_size))]u8 = undefined;
    const rc = proc_pidinfo(@intCast(pid), proc_pidvnodepathinfo, 0, &info, vnodepathinfo_size);
    // 부분 응답(rc < size)은 구조체가 덜 채워졌다는 뜻이라 경로 자리가 쓰레기다. 크기가 정확할 때만 읽는다.
    if (rc != vnodepathinfo_size) return null;
    const raw = info[vnodepathinfo_cdir_path_offset..][0..vnodepathinfo_max_path];
    const len = std.mem.indexOfScalar(u8, raw, 0) orelse return null; // NUL이 없으면 잘린 응답이다
    if (len == 0 or raw[0] != '/') return null; // 절대경로가 아니면 우리가 쓸 수 있는 값이 아니다
    if (len > out.len) return null; // 자르지 않는다 — 다른 디렉터리를 가리키게 된다
    @memcpy(out[0..len], raw[0..len]);
    return out[0..len];
}
// KERN_PROCARGS2: pid의 argv/envp 덤프(공개 macOS sysctl — ps·libproc도 같은 방식). codex처럼 `#!/usr/bin/env node`
// 스크립트로 도는 에이전트는 proc_name이 "node"라 미감지되므로, comm이 인터프리터면 argv[1] 스크립트 basename
// ("codex")으로 분류한다. clean-room: 공개 sysctl API 사용(코드 표현 복사 아님).
extern "c" fn sysctl(name: [*c]c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
const ctl_kern: c_int = 1;
const kern_procargs2: c_int = 49;
// KERN_PROCARGS2 sysctl 버퍼(argv+envp 전체를 담아야 sysctl이 성공 — 부족하면 ENOMEM). kern.argmax(=1MB) 상한이라
// 256KB면 현실 거의 모든 argv+envp를 담는다(초과 시 ENOMEM → comm 폴백). **틱 스레드 전용**(pollAgentKinds 단일
// 호출 경로)이라 단일 정적 버퍼를 공유한다 — 다른 스레드에서 foregroundProcessNames를 부르면 동기화 필요.
var procargs_buf: [256 * 1024]u8 = undefined;

/// comm이 스크립트 인터프리터면 true — 그때만 argv[1](스크립트 경로)로 에이전트를 식별한다. 정확 일치라
/// `vim codex.md`(comm="vim")는 argv 검사를 안 타 오탐하지 않는다.
fn isInterpreterName(name: []const u8) bool {
    const interps = [_][]const u8{ "node", "deno", "bun", "python", "python3", "ruby" };
    for (interps) |it| if (std.mem.eql(u8, name, it)) return true;
    return false;
}

fn lastPathComponent(path: []const u8) []const u8 {
    var end: usize = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1; // 끝 슬래시 제거("/opt/tool/" → "tool")
    var i: usize = end;
    while (i > 0) : (i -= 1) if (path[i - 1] == '/') return path[i..end];
    return path[0..end];
}

/// KERN_PROCARGS2 버퍼에서 argv[1] basename을 파싱하는 순수 함수(sysctl과 분리해 단위 테스트). 레이아웃:
/// [argc:int][exec_path\0][\0 패딩][argv0\0][argv1\0]…[envp…]. argv[1](스크립트 경로)의 basename 반환(없으면 null).
fn parseArgv1Basename(data: []const u8) ?[]const u8 {
    if (data.len <= @sizeOf(c_int)) return null;
    // argc(첫 int, macOS는 항상 little-endian). argv[1]이 존재하려면 argc >= 2 — 아니면 argv[0] 다음은 argv가
    // 아니라 envp라, 그걸 argv[1]로 오독한다(인자 없는 bare `node`/`python` REPL → env 값 기반 오분류 위험).
    const argc: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
    if (argc < 2) return null;
    var off: usize = @sizeOf(c_int); // argc(int) 건너뜀
    while (off < data.len and data[off] != 0) off += 1; // exec_path 문자열
    while (off < data.len and data[off] == 0) off += 1; // null 패딩
    while (off < data.len and data[off] != 0) off += 1; // argv[0]
    while (off < data.len and data[off] == 0) off += 1; // argv[0]·argv[1] 구분 null
    const start = off; // argv[1] 시작
    while (off < data.len and data[off] != 0) off += 1;
    if (off <= start) return null; // argv[1] 없음
    const base = lastPathComponent(data[start..off]);
    return if (base.len == 0) null else base; // 끝-슬래시뿐인 비정상 경로면 null
}

/// KERN_PROCARGS2 버퍼의 **envp**에서 `key=`로 시작하는 값을 뽑는 순수 함수(sysctl과 분리해 단위 테스트).
///
/// 레이아웃은 `[argc:int][exec_path\0][\0 패딩][argv0\0]…[argv{argc-1}\0][envp0\0][envp1\0]…`이다. argv를
/// argc개 건너뛴 뒤부터가 envp라, **argc를 세지 않고** 전체를 훑으면 argv에 있는 `FOO=bar` 꼴 인자를 환경변수로
/// 오독한다(에이전트에 `--env X=Y`를 넘기는 경우가 실제로 있다).
///
/// 에이전트가 **자식에게** 세션 신원을 env로 내려주므로(claude `CLAUDE_CODE_SESSION_ID`, codex `CODEX_THREAD_ID`)
/// 이 파서가 사이드바 대화 결속의 근거가 된다 — 추측(활동 상관) 대신 provider가 스스로 밝힌 값을 쓴다.
pub fn parseEnvValue(data: []const u8, key: []const u8) ?[]const u8 {
    if (data.len <= @sizeOf(c_int)) return null;
    const argc: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
    var off: usize = @sizeOf(c_int);
    while (off < data.len and data[off] != 0) off += 1; // exec_path
    while (off < data.len and data[off] == 0) off += 1; // null 패딩
    // argv를 argc개 건너뛴다 — 그 뒤부터가 envp다.
    var consumed: u32 = 0;
    while (consumed < argc and off < data.len) : (consumed += 1) {
        while (off < data.len and data[off] != 0) off += 1;
        while (off < data.len and data[off] == 0) off += 1;
    }
    // envp를 `key=` 접두로 훑는다.
    while (off < data.len) {
        const start = off;
        while (off < data.len and data[off] != 0) off += 1;
        const entry = data[start..off];
        while (off < data.len and data[off] == 0) off += 1;
        if (entry.len == 0) break; // envp 끝(빈 문자열 뒤는 apple[] 영역)
        if (entry.len > key.len and std.mem.startsWith(u8, entry, key) and entry[key.len] == '=') {
            const value = entry[key.len + 1 ..];
            return if (value.len == 0) null else value;
        }
    }
    return null;
}

/// KERN_PROCARGS2 바이트에서 **argv[0]** basename 추출 — parseArgv1Basename과 같되 argv[1]이 아니라 argv[0]에서 멈춘다.
/// comm이 버전으로 바뀐 에이전트(claude "2.1.197")를 argv[0]="claude"로 되짚는 폴백용. argc>=1이면 argv[0]이 존재한다.
fn parseArgv0Basename(data: []const u8) ?[]const u8 {
    if (data.len <= @sizeOf(c_int)) return null;
    const argc: u32 = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
    if (argc < 1) return null;
    var off: usize = @sizeOf(c_int); // argc(int) 건너뜀
    while (off < data.len and data[off] != 0) off += 1; // exec_path 문자열
    while (off < data.len and data[off] == 0) off += 1; // null 패딩
    const start = off; // argv[0] 시작
    while (off < data.len and data[off] != 0) off += 1;
    if (off <= start) return null; // argv[0] 없음
    const base = lastPathComponent(data[start..off]);
    return if (base.len == 0) null else base;
}

// Claude Code(v2.1.197+)는 실행 중 process.title(=comm)을 **버전 문자열**("2.1.197")로 바꿔, foregroundProcessName의
// comm 기반 감지가 comm="claude"가 아니라 "2.1.197"을 읽어 실패했다(실측). 이 테스트는 그 폴백 파서(argv[0] basename)가
// claude를 되짚는지 고정한다 — comm이 숫자로 시작하면 foregroundProcessName이 이 결과를 쓴다. (KERN_PROCARGS2 실 sysctl은
// 프로세스 필요라, 순수 파서만 검증.)
test "parseEnvValue: argv를 건너뛰고 envp에서만 값을 찾는다" {
    // KERN_PROCARGS2 레이아웃: [argc][exec_path\0][패딩\0][argv0\0]…[envp…]
    // argc=2, argv[1]이 `CLAUDE_CODE_SESSION_ID=fake`인 함정 — argv를 안 건너뛰면 이걸 환경변수로 오독한다.
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    const argc: u32 = 2;
    buf[0] = @intCast(argc & 0xFF);
    buf[1] = @intCast((argc >> 8) & 0xFF);
    buf[2] = @intCast((argc >> 16) & 0xFF);
    buf[3] = @intCast((argc >> 24) & 0xFF);
    n = 4;
    const parts = [_][]const u8{
        "/usr/bin/claude", // exec_path
        "", // 패딩
        "claude", // argv[0]
        "CLAUDE_CODE_SESSION_ID=from-argv", // argv[1] — 함정
        "PATH=/bin", // envp[0]
        "CLAUDE_CODE_SESSION_ID=03e06864-real", // envp[1] — 정답
        "HOME=/Users/me",
    };
    for (parts) |part| {
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
        buf[n] = 0;
        n += 1;
    }
    const got = parseEnvValue(buf[0..n], "CLAUDE_CODE_SESSION_ID") orelse return error.NotFound;
    try std.testing.expectEqualStrings("03e06864-real", got);

    // codex 키도 같은 파서로 읽는다.
    try std.testing.expect(parseEnvValue(buf[0..n], "CODEX_THREAD_ID") == null);
    // 접두만 같고 `=`가 아닌 키는 매치되지 않아야 한다(CLAUDE_CODE_SESSION_ID_EXTRA 같은 변수 오독 방지).
    try std.testing.expect(parseEnvValue(buf[0..n], "CLAUDE_CODE_SESSION") == null);
    // 값이 빈 변수는 없는 것으로 본다.
    try std.testing.expect(parseEnvValue(buf[0..n], "PATH") != null);
    try std.testing.expect(parseEnvValue(buf[0..4], "PATH") == null); // envp 없음
}

test "parseArgv0Basename: comm이 버전으로 바뀐 claude를 argv[0]으로 되짚는다" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, &[_]u8{ 2, 0, 0, 0 }); // argc=2 (LE int)
    try buf.appendSlice(a, "/Users/x/.local/share/mise/installs/node/24/bin/claude"); // exec_path
    try buf.append(a, 0);
    try buf.appendSlice(a, &[_]u8{ 0, 0, 0 }); // null 패딩
    try buf.appendSlice(a, "claude"); // argv[0] = "claude"(버전으로 안 바뀐 원본)
    try buf.append(a, 0);
    try buf.appendSlice(a, "--dangerously-skip-permissions"); // argv[1]
    try buf.append(a, 0);
    try std.testing.expectEqualStrings("claude", parseArgv0Basename(buf.items) orelse return error.TestUnexpectedNull);

    // 경로 포함 argv[0]도 basename만.
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(a);
    try buf2.appendSlice(a, &[_]u8{ 1, 0, 0, 0 }); // argc=1
    try buf2.appendSlice(a, "/opt/x/codex"); // exec_path
    try buf2.append(a, 0);
    try buf2.append(a, 0); // 패딩
    try buf2.appendSlice(a, "/opt/x/codex"); // argv[0] = 경로
    try buf2.append(a, 0);
    try std.testing.expectEqualStrings("codex", parseArgv0Basename(buf2.items) orelse return error.TestUnexpectedNull);

    // argc=0(비정상)이면 null.
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgv0Basename(&[_]u8{ 0, 0, 0, 0 }));
}

/// 포그라운드 pgid의 argv[1] 스크립트 basename(KERN_PROCARGS2). 정적 procargs_buf의 슬라이스다.
fn foregroundScriptBasename(pgid: c_int) ?[]const u8 {
    var mib = [_]c_int{ ctl_kern, kern_procargs2, pgid };
    var size: usize = procargs_buf.len;
    if (sysctl(&mib, 3, &procargs_buf, &size, null, 0) != 0) return null;
    return parseArgv1Basename(procargs_buf[0..size]);
}

/// 포그라운드 pgid의 **argv[0] basename**(정적 procargs_buf 슬라이스). comm이 버전 문자열로 바뀐 에이전트(Claude Code가
/// process.title을 "2.1.197"로 설정)를 argv[0]="claude"로 되짚는 용도 — foregroundScriptBasename(argv[1])과 같은 규약.
fn foregroundArgv0Basename(pgid: c_int) ?[]const u8 {
    var mib = [_]c_int{ ctl_kern, kern_procargs2, pgid };
    var size: usize = procargs_buf.len;
    if (sysctl(&mib, 3, &procargs_buf, &size, null, 0) != 0) return null;
    return parseArgv0Basename(procargs_buf[0..size]);
}

test "parseArgv1Basename: node 래퍼의 argv[1] 스크립트 basename 추출(codex 감지)" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, &[_]u8{ 3, 0, 0, 0 }); // argc=3 (LE int)
    try buf.appendSlice(a, "/Users/x/.local/share/node/24/bin/node"); // exec_path
    try buf.append(a, 0);
    try buf.appendSlice(a, &[_]u8{ 0, 0, 0 }); // null 패딩
    try buf.appendSlice(a, "node"); // argv[0]
    try buf.append(a, 0);
    try buf.appendSlice(a, "/Users/x/.local/share/node/24/bin/codex"); // argv[1] = 스크립트 경로
    try buf.append(a, 0);
    try buf.appendSlice(a, "--resume"); // argv[2]
    try buf.append(a, 0);
    const r = parseArgv1Basename(buf.items) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("codex", r);

    // argv[1] 없는(인자 없는 인터프리터, argc=1) 경우 — argv[0] 다음에 envp가 와도 argc 게이트로 null이어야 한다
    // (envp를 argv[1]로 오독하면 안 됨 — 회귀 방지).
    var bare: std.ArrayList(u8) = .empty;
    defer bare.deinit(a);
    try bare.appendSlice(a, &[_]u8{ 1, 0, 0, 0 }); // argc=1
    try bare.appendSlice(a, "/bin/node"); // exec_path
    try bare.append(a, 0);
    try bare.append(a, 0); // 패딩
    try bare.appendSlice(a, "node"); // argv[0]만
    try bare.append(a, 0);
    try bare.appendSlice(a, "PATH=/usr/local/bin:/usr/bin"); // envp[0] — argc 게이트 없으면 이걸 argv[1]로 오독("bin" 반환)
    try bare.append(a, 0);
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgv1Basename(bare.items));

    // 끝-슬래시 경로는 그 앞 컴포넌트를 반환(빈 문자열로 안 떨어짐).
    try std.testing.expectEqualStrings("tool", lastPathComponent("/opt/tool/"));
    try std.testing.expectEqualStrings("node", lastPathComponent("node"));
}

test "isInterpreterName: node/python 등만 true, 에이전트·일반 명령은 false" {
    try std.testing.expect(isInterpreterName("node"));
    try std.testing.expect(isInterpreterName("python3"));
    try std.testing.expect(!isInterpreterName("claude")); // 네이티브 에이전트는 comm 그대로 분류
    try std.testing.expect(!isInterpreterName("codex"));
    try std.testing.expect(!isInterpreterName("vim")); // 일반 명령 → argv 검사 안 탐(오탐 방지)
    try std.testing.expect(!isInterpreterName("node_modules")); // 정확 일치라 prefix 오탐 없음
}

const tio_cs_ctty: c_int = 0x20007461;
const tio_cs_winsz: c_int = @bitCast(@as(u32, 0x80087467));

// master fd에 요청하는 입력 이벤트는 readable(POLL.IN)뿐이다. HUP/ERR/NVAL은
// output-only 플래그라 events에 넣어도 무시되고 revents로만 전달된다.
const poll_in_events: i16 = @intCast(std.posix.POLL.IN);
const poll_readable_revents: i16 = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR);

pub const PtySession = struct {
    master_fd: std.atomic.Value(std.posix.fd_t),
    child_pid: std.c.pid_t,
    size: terminal.Size,
    // Normal spawn은 true다. Exec-restore는 working fd/wake pipe를 먼저
    // materialize하되 전체 host graph가 durable commit되기 전까지 false로
    // 둔다. false인 session의 close/deinit은 descriptor만 회수하고 child에
    // signal/waitpid를 절대 하지 않는다.
    owns_child_lifecycle: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reaping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // close()가 reader thread의 blocking poll을 즉시 깨우기 위한 self-pipe.
    // wake_write로 1바이트를 보내면 poll이 곧바로 반환하므로 timeout 폴링 없이
    // close를 관측한다(close 지연 ~0, 출력 없는 pane의 주기적 wakeup 0).
    // master_fd는 reader가 끝난(join) 뒤 deinit에서만 닫아 fd 재사용 레이스를 없앤다.
    wake_read_fd: std.posix.fd_t,
    wake_write_fd: std.atomic.Value(std.posix.fd_t),

    /// Live host exec-upgrade eligibility. 이 값들은 serialization 대상이 아니라 quiesce barrier가 모두 false/open임을
    /// 증명하는 lifecycle guard다.
    pub fn upgradeEligible(self: *const PtySession) bool {
        return self.master_fd.load(.acquire) >= 0 and
            self.owns_child_lifecycle.load(.acquire) and
            !self.exited.load(.acquire) and
            !self.closing.load(.acquire) and
            !self.reaping.load(.acquire);
    }

    /// Reader가 pause된 동안 child가 exit해도 status를 소비하지 않고 감지한다. `WNOWAIT`가 owner drain의
    /// exact-once wait/reap 권위를 보존하므로 upgrade abort 뒤 같은 reader가 EOF를 관측해 정상 종료시킬 수 있다.
    pub fn childExitedWithoutReap(self: *const PtySession) error{ChildProbeFailed}!bool {
        return probeChildExitedWithoutReap(self.child_pid);
    }

    pub fn inheritedMasterFd(self: *const PtySession) ?std.posix.fd_t {
        const fd = self.master_fd.load(.acquire);
        return if (fd >= 0) fd else null;
    }

    pub fn childPid(self: *const PtySession) std.c.pid_t {
        return self.child_pid;
    }

    pub fn canonicalSize(self: *const PtySession) terminal.Size {
        return self.size;
    }

    pub const MasterIdentity = struct {
        dev: i64,
        ino: u64,
        rdev: i64,
    };

    pub fn masterIdentity(self: *const PtySession) !MasterIdentity {
        var stat: std.posix.Stat = undefined;
        if (std.c.fstat(self.master_fd.load(.acquire), &stat) != 0 or !std.posix.S.ISCHR(stat.mode))
            return error.InvalidPtyIdentity;
        return .{
            .dev = stat.dev,
            .ino = @intCast(stat.ino),
            .rdev = stat.rdev,
        };
    }

    /// Target image의 pre-commit PTY adoption. 이 타입은 child lifecycle을 소유하지 않으므로 `discard`가
    /// signal/waitpid를 절대 호출하지 않는다. inherited slot은 rollback exec를 위해 caller가 계속 소유한다.
    pub const PreparedAdoption = struct {
        inherited_slot: std.posix.fd_t,
        working_fd: std.posix.fd_t,
        child_pid: std.c.pid_t,
        size: terminal.Size,
        wake_read_fd: std.posix.fd_t,
        wake_write_fd: std.posix.fd_t,
        committed: bool = false,

        pub fn prepare(inherited_slot: std.posix.fd_t, child_pid: std.c.pid_t, size: terminal.Size) !PreparedAdoption {
            return prepareExact(inherited_slot, child_pid, size, null);
        }

        pub fn prepareExact(
            inherited_slot: std.posix.fd_t,
            child_pid: std.c.pid_t,
            size: terminal.Size,
            expected_identity: ?MasterIdentity,
        ) !PreparedAdoption {
            try validateInheritedMaster(inherited_slot, child_pid, size, expected_identity);

            const working_fd = std.c.fcntl(inherited_slot, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
            if (working_fd < 0) return error.FcntlFailed;
            errdefer closeFd(working_fd);
            var wake_fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&wake_fds) != 0) return error.PipeFailed;
            errdefer {
                closeFd(wake_fds[0]);
                closeFd(wake_fds[1]);
            }
            try setCloseOnExec(wake_fds[0]);
            try setCloseOnExec(wake_fds[1]);
            try setNonBlocking(wake_fds[0]);
            return .{
                .inherited_slot = inherited_slot,
                .working_fd = working_fd,
                .child_pid = child_pid,
                .size = size,
                .wake_read_fd = wake_fds[0],
                .wake_write_fd = wake_fds[1],
            };
        }

        /// Allocation/dup 없이 inherited master의 pre-commit identity와 child liveness를 검증한다.
        /// Bootstrap과 PreparedAdoption이 같은 경계를 소비해 두 검증 수준이 달라지지 않게 한다.
        pub fn validateInheritedMaster(
            inherited_slot: std.posix.fd_t,
            child_pid: std.c.pid_t,
            size: terminal.Size,
            expected_identity: ?MasterIdentity,
        ) !void {
            if (inherited_slot < 3 or child_pid <= 0 or size.cols < 2 or size.rows < 1) return error.InvalidInheritedPty;
            const fd_flags = std.c.fcntl(inherited_slot, std.c.F.GETFD, @as(c_int, 0));
            if (fd_flags < 0 or fd_flags & std.c.FD_CLOEXEC != 0) return error.InvalidInheritedPty;
            var stat: std.posix.Stat = undefined;
            if (std.c.fstat(inherited_slot, &stat) != 0 or !std.posix.S.ISCHR(stat.mode)) return error.InvalidInheritedPty;
            if (expected_identity) |expected| {
                if (@as(i64, stat.dev) != expected.dev or
                    @as(u64, @intCast(stat.ino)) != expected.ino or
                    @as(i64, stat.rdev) != expected.rdev) return error.InvalidInheritedPty;
            }
            const raw_flags = std.c.fcntl(inherited_slot, std.c.F.GETFL, @as(c_int, 0));
            if (raw_flags < 0) return error.InvalidInheritedPty;
            const open_flags: std.c.O = @bitCast(@as(u32, @intCast(raw_flags)));
            if (!open_flags.NONBLOCK or open_flags.ACCMODE != .RDWR) return error.InvalidInheritedPty;
            var window_size: std.c.winsize = undefined;
            if (std.c.ioctl(inherited_slot, std.c.T.IOCGWINSZ, &window_size) < 0 or
                window_size.col != size.cols or window_size.row != size.rows) return error.InvalidInheritedPty;
            // kill(pid, 0)는 생존/권한 probe일 뿐 waitpid가 아니어서 exit status를 소비하지 않는다.
            const probe_signal: std.c.SIG = @enumFromInt(0);
            const probe_rc = std.c.kill(child_pid, probe_signal);
            if (probe_rc != 0 and std.posix.errno(probe_rc) != .PERM) return error.InvalidInheritedPty;
            // kill(pid, 0)는 zombie에도 성공한다. Target pre-commit에서 WNOWAIT로 한 번 더 확인해 old encode의
            // 마지막 probe 뒤 종료한 child를 live로 commit하지 않는다. status는 소비하지 않아 성공 commit 또는
            // rollback image 중 실제 owner가 exact-once로 reap한다.
            if (probeChildExitedWithoutReap(child_pid) catch return error.InvalidInheritedPty)
                return error.InvalidInheritedPty;
        }

        pub fn discard(self: *PreparedAdoption) void {
            if (self.committed) return;
            if (self.working_fd >= 0) closeFd(self.working_fd);
            if (self.wake_read_fd >= 0) closeFd(self.wake_read_fd);
            if (self.wake_write_fd >= 0) closeFd(self.wake_write_fd);
            self.working_fd = -1;
            self.wake_read_fd = -1;
            self.wake_write_fd = -1;
        }

        /// Host-global ownership transfer 직전의 마지막 fallible child probe.
        /// 다중 runtime caller는 **전량** revalidate한 뒤에만 각 항목의
        /// `materialize`를 수행한다. 이후 graph가 materialized session들을
        /// 다시 전량 검증하고 `commitPreparedOwnership`을 호출해야 앞
        /// runtime만 새 owner가 되는 partial commit을 피할 수 있다.
        pub fn revalidate(self: *const PreparedAdoption) !void {
            std.debug.assert(!self.committed);
            // prepare와 host-global all-or-none commit 사이에는 다른 runtime 준비, owner lease 검증, allocation이
            // 들어간다. 그 사이 child가 끝나면 kill(pid, 0)는 zombie에도 성공하므로 commit 직전 WNOWAIT probe가
            // 마지막 권위다. status를 소비하지 않아 old/rollback owner가 exact-once로 reap할 수 있다.
            if (probeChildExitedWithoutReap(self.child_pid) catch return error.InvalidInheritedPty)
                return error.InvalidInheritedPty;
        }

        /// Working descriptor와 wake pipe를 PtySession 주소에 옮기지만 child
        /// lifecycle owner로는 아직 승격하지 않는다. 이 상태의 normal deinit은
        /// child를 건드리지 않으므로 이후 runtime 준비 실패가 rollback-safe하다.
        pub fn materialize(self: *PreparedAdoption) PtySession {
            std.debug.assert(!self.committed);
            self.committed = true;
            const result = PtySession{
                .master_fd = std.atomic.Value(std.posix.fd_t).init(self.working_fd),
                .child_pid = self.child_pid,
                .size = self.size,
                .owns_child_lifecycle = .init(false),
                .wake_read_fd = self.wake_read_fd,
                .wake_write_fd = std.atomic.Value(std.posix.fd_t).init(self.wake_write_fd),
            };
            self.working_fd = -1;
            self.wake_read_fd = -1;
            self.wake_write_fd = -1;
            return result;
        }
    };

    /// Materialized restore session의 마지막 fallible child probe. Host-global
    /// graph는 전량 성공을 확인한 뒤에만 `commitPreparedOwnership`을 호출한다.
    pub fn revalidatePreparedOwnership(self: *const PtySession) !void {
        if (self.owns_child_lifecycle.load(.acquire) or
            self.master_fd.load(.acquire) < 0 or
            self.closing.load(.acquire) or
            self.exited.load(.acquire) or
            self.reaping.load(.acquire))
            return error.InvalidInheritedPty;
        if (probeChildExitedWithoutReap(self.child_pid) catch return error.InvalidInheritedPty)
            return error.InvalidInheritedPty;
    }

    /// 전량 revalidate 이후의 allocation/syscall-free owner transfer.
    pub fn commitPreparedOwnership(self: *PtySession) void {
        std.debug.assert(!self.owns_child_lifecycle.load(.acquire));
        self.owns_child_lifecycle.store(true, .release);
    }

    pub fn spawn(allocator: std.mem.Allocator, request: types.SpawnRequest) !PtySession {
        try validateRequest(request);

        // login=true면 login(1)으로 감싸 전체 로그인 세션을 셋업한다(Terminal.app·Ghostty와 동일).
        // 셋업 실패(getpwuid 등 — 정상 사용자에선 사실상 없음)면 평범한 비-login 셸로 fallback한다
        // (Ghostty와 동일하게 dash-argv0가 아니라 그냥 plain).
        var login_wrap: ?MacosLogin = if (request.login)
            (MacosLogin.build(allocator, request) catch |err| blk: {
                std.log.scoped(.pty).warn("login(1) 래핑 실패({}) — 비-login 셸로 fallback", .{err});
                break :blk null;
            })
        else
            null;
        defer if (login_wrap) |*lw| lw.deinit(allocator);

        const eff_command: []const u8 = if (login_wrap != null) "/usr/bin/login" else request.command;
        const eff_args: []const []const u8 = if (login_wrap) |lw| lw.args else request.args;

        const command_z = try allocator.dupeZ(u8, eff_command);
        defer allocator.free(command_z);

        const cwd_z = if (request.cwd) |cwd| try allocator.dupeZ(u8, cwd) else null;
        defer if (cwd_z) |cwd| allocator.free(cwd);

        var argv_storage = try ArgvStorage.init(allocator, eff_command, eff_args);
        defer argv_storage.deinit();

        // 중립 계약의 `shell_integration`(파일 갈래)을 이 백엔드의 메커니즘 이름(`zdotdir` = zsh `ZDOTDIR`)으로
        // 넘긴다 — 매핑이 백엔드 몫이라는 계약 그대로다(docs/windows-platform.md §4.2).
        var env_storage = try EnvStorage.initWithParentSnapshot(allocator, request.env, request.parent_env, request.env_overrides, request.term, if (request.shell_integration) |si| si.assetsDir() else null, request.ssh_integration_bin, request.pane_id, request.hook_instance, request.hook_pane);
        defer env_storage.deinit();

        var window_size = winsizeFromTerminalSize(request.size);
        var master_fd: std.c.fd_t = undefined;
        var slave_fd: std.c.fd_t = undefined;
        if (openpty(&master_fd, &slave_fd, null, null, &window_size) < 0) return error.OpenptyFailed;
        errdefer {
            closeFd(master_fd);
            closeFd(slave_fd);
        }

        try setCloseOnExec(master_fd);
        // master fd를 non-blocking으로 둔다. write는 버퍼에 들어가는 만큼만 쓰고 EAGAIN이면
        // 0을 돌려줘(아래 writeFd) 큰 붙여넣기가 UI tick을 동결시키지 않는다 — poll만으로는
        // 512B 여유를 보장 못 해 blocking fd에선 write가 막힐 수 있었다(#5). reader는 poll-
        // readable 후 read하므로 EAGAIN은 드문 race이고 readEvent가 재시도한다.
        try setNonBlocking(master_fd);

        // close()가 blocking poll을 깨우는 self-pipe. child에게 새지 않도록 양 끝을
        // close-on-exec로 둔다(exec 시 닫히고, 다른 session spawn에도 상속되지 않는다).
        var wake_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&wake_fds) != 0) return error.PipeFailed;
        errdefer {
            closeFd(wake_fds[0]);
            closeFd(wake_fds[1]);
        }
        try setCloseOnExec(wake_fds[0]);
        try setCloseOnExec(wake_fds[1]);
        // read end는 non-blocking — write-pending wake(Phase 2 §8)가 반복돼도 drainWake가 누적 바이트를
        // EAGAIN까지 비울 수 있게(블로킹 없이). close-wake는 poll만 깨우고 read는 안 하므로 영향 없다.
        try setNonBlocking(wake_fds[0]);

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            childExec(command_z, argv_storage.argv.ptr, env_storage.envpPtr(), cwd_z, master_fd, slave_fd);
        }

        closeFd(slave_fd);
        return .{
            .master_fd = std.atomic.Value(std.posix.fd_t).init(master_fd),
            .child_pid = pid,
            .size = request.size,
            .wake_read_fd = wake_fds[0],
            .wake_write_fd = std.atomic.Value(std.posix.fd_t).init(wake_fds[1]),
        };
    }

    pub fn close(self: *PtySession) void {
        // close는 reader thread를 깨우고 child를 정리하는 lifecycle API다.
        // deinit처럼 객체를 undefined로 만들지 않기 때문에 app은 close -> reader.join
        // -> deinit 순서로 안전하게 종료할 수 있다. master fd는 여기서 닫지 않고
        // deinit(=join 이후)에서 닫는다. reader가 아직 그 fd 번호로 poll/read 중일 때
        // 닫으면 OS가 번호를 재사용해 reader가 엉뚱한 fd를 읽을 수 있기 때문이다.
        self.closing.store(true, .release);

        // closing을 올린 뒤 self-pipe로 reader의 blocking poll을 즉시 깨운다.
        self.signalWake();

        if (self.owns_child_lifecycle.load(.acquire) and
            !self.exited.load(.acquire) and !self.reaping.swap(true, .acq_rel))
        {
            shutdownChild(self.child_pid, self.master_fd.load(.acquire));
            self.exited.store(true, .release);
        }
    }

    pub fn deinit(self: *PtySession) void {
        // reader가 이미 join된 상태에서만 호출되는 단계라(close -> join -> deinit),
        // 여기서 비로소 master fd와 self-pipe를 닫는다.
        self.close();

        const fd = self.master_fd.swap(-1, .acq_rel);
        if (fd >= 0) closeFd(fd);

        const wake_write = self.wake_write_fd.swap(-1, .acq_rel);
        if (wake_write >= 0) closeFd(wake_write);
        closeFd(self.wake_read_fd);

        self.* = undefined;
    }

    fn signalWake(self: *PtySession) void {
        const fd = self.wake_write_fd.load(.acquire);
        if (fd < 0) return;
        // 1바이트만 보내면 충분하다. close는 많아야 두 번(stopAndJoin + deinit)
        // 호출되고 pipe 버퍼는 넉넉하므로 가득 차 blocking될 일은 없다.
        var byte = [_]u8{0};
        while (true) {
            const rc = std.c.write(fd, &byte, byte.len);
            if (rc >= 0) return;
            if (std.posix.errno(rc) == .INTR) continue;
            return; // best-effort: 이미 신호됐거나 닫힌 경우는 무시한다.
        }
    }

    /// 메인 스레드가 write_queue에 입력을 넣은 뒤 I/O 스레드의 poll을 깨운다(docs/io-render-threading.md
    /// §8 P2-3b — 단일 writer). wake self-pipe를 재사용한다: waitIo가 wake를 보면 closing 플래그로
    /// write-wake(아직 안 닫힘 → 재-poll로 POLLOUT 반영) vs close-wake(SessionClosed)를 구분한다.
    pub fn signalWrite(self: *PtySession) void {
        self.signalWake();
    }

    /// 단일 I/O 루프(docs/plans/io-render-threading.md §8 Phase 2)용 I/O 준비 상태. closing이면 waitIo가
    /// error.SessionClosed. 둘 다 false면 write-pending wake(호출자가 write 큐 확인 후 다음 poll에 POLLOUT 반영).
    pub const IoReady = struct { readable: bool = false, writable: bool = false };

    /// 비차단 read 결과: 읽은 길이 / EOF(자식 stdio 닫힘) / EAGAIN(데이터 아직 없음 — 재시도).
    pub const ReadOutcome = union(enum) { data: usize, eof, again };

    /// 한 번의 poll로 master(POLLIN | POLLOUT if want_write) + wake self-pipe를 기다린다(timeout -1). 단일 I/O
    /// 루프가 read·write를 한 poll에서 인터리브하는 기반(write가 막혀도 read 진전). closing이면 SessionClosed.
    /// wake가 오면 바이트를 비우고(drainWake), closing이면 SessionClosed·아니면 write-pending이라 준비된 read/write
    /// 없이 반환(호출자 재-poll). wake/close를 master보다 먼저 확인한다(close 직후 재사용된 fd가 readable로 보여도
    /// 오인 안 하게 — 기존 readEvent 동작 보존).
    pub fn waitIo(self: *PtySession, want_write: bool) !IoReady {
        while (true) {
            if (self.closing.load(.acquire)) return error.SessionClosed;
            const fd = self.master_fd.load(.acquire);
            if (fd < 0) return error.SessionClosed;
            var want: i16 = poll_in_events;
            if (want_write) want |= @as(i16, @intCast(std.posix.POLL.OUT));
            var fds = [_]std.posix.pollfd{
                .{ .fd = fd, .events = want, .revents = 0 },
                .{ .fd = self.wake_read_fd, .events = poll_in_events, .revents = 0 },
            };
            _ = try std.posix.poll(&fds, -1);

            if (self.closing.load(.acquire)) return error.SessionClosed;
            if (fds[1].revents != 0) {
                self.drainWake();
                if (self.closing.load(.acquire)) return error.SessionClosed;
                return .{}; // write-pending wake — 준비된 read/write 없음(호출자가 want_write로 재-poll)
            }
            const r = fds[0].revents;
            if ((r & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0) return error.PollFailed;
            const readable = (r & poll_readable_revents) != 0;
            const writable = want_write and (r & @as(i16, @intCast(std.posix.POLL.OUT))) != 0;
            if (readable or writable) return .{ .readable = readable, .writable = writable };
            // POLLIN/HUP/ERR도 OUT도 아닌 드문 spurious wakeup — 다시 기다린다.
        }
    }

    /// wake self-pipe에 쌓인 바이트를 비운다(read end가 O_NONBLOCK이라 EAGAIN까지 비차단). write-pending wake가
    /// 반복돼도 누적되지 않게. close-wake는 waitIo가 closing을 먼저 봐 여기 오지 않는다.
    fn drainWake(self: *PtySession) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.wake_read_fd, &buf) catch return; // EAGAIN 등 → 비움 완료
            if (n == 0) return;
        }
    }

    /// 비차단으로 master를 buf에 읽는다(호출자가 waitIo로 readable 확인 후). EOF는 0바이트 또는 EIO(일부 Unix가
    /// 슬레이브 close를 EIO로 보고)로 통일. EAGAIN(readable과 read 사이 race)은 .again으로 재시도 신호.
    pub fn readChunk(self: *PtySession, buf: []u8) !ReadOutcome {
        const fd = self.activeMasterFd() catch return error.SessionClosed;
        const n = std.posix.read(fd, buf) catch |err| switch (err) {
            error.InputOutput => return .eof,
            error.WouldBlock => return .again,
            else => {
                if (self.closing.load(.acquire)) return error.SessionClosed;
                return err;
            },
        };
        if (n == 0) return .eof;
        return .{ .data = n };
    }

    /// EOF를 본 뒤 자식을 reap한다(블로킹 waitpid 금지 — close가 항상 끼어들 수 있게). 보통 EOF가 이미 종료를
    /// 뜻해 WNOHANG로 즉시 거둔다. 자식이 stdio만 닫고 살아있으면(daemonize) kqueue로 실제 종료/close를 기다렸다
    /// 재시도. double-reap은 reaping swap-guard로 막는다(close와 경합 시 한쪽만 reap). 반환: 종료 코드 / null=close로 중단.
    pub fn reapAfterEof(self: *PtySession) !?types.ExitStatus {
        while (true) {
            if (self.closing.load(.acquire)) return null;
            if (self.reaping.swap(true, .acq_rel)) return null;

            const reaped = reapNoHang(self.child_pid) catch |err| {
                self.reaping.store(false, .release);
                return err;
            };
            if (reaped) |status| {
                self.exited.store(true, .release);
                return status;
            }

            self.reaping.store(false, .release);
            try self.waitChildExitOrClosing();
        }
    }

    /// reapAfterEof의 **비차단** 형제: 자식이 이미 죽었으면 종료 상태를, 아직 살아있으면 `null`을 즉시 돌려준다
    /// (kqueue로 종료를 기다리지 않는다). read/write/poll에서 EOF가 아닌 I/O 오류를 만난 reader가 "이 오류가 정말
    /// 자식 종료인지"를 **검증**하는 데 쓴다 — 죽었으면 `.exited`(EOF 경로와 동치인 검증된 종료)로, 살아있으면
    /// `.read_error`(surface만 unusable 표시, 워크스페이스 유지)로 방출하게 해서, Ctrl+C가 유발한 일시적 write 오류
    /// 같은 미검증 신호가 산 셸을 죽이고 좌측 탭을 통째로 닫던 루트커즈(read_error 무검증 종료)를 막는다.
    /// double-reap은 reapAfterEof와 같은 reaping swap-guard로 막는다(close·EOF-reap과 경합 시 한쪽만 거둔다).
    /// 성공(죽음) 시 `exited`를 세워 이후 close()가 shutdownChild를 건너뛰게 한다(중복 신호 없음).
    pub fn reapIfExited(self: *PtySession) !?types.ExitStatus {
        if (self.closing.load(.acquire)) return null;
        if (self.reaping.swap(true, .acq_rel)) return null; // 다른 곳이 이미 reap 중 — 미검증으로 취급(null)

        const reaped = reapNoHang(self.child_pid) catch |err| {
            self.reaping.store(false, .release);
            return err;
        };
        if (reaped) |status| {
            self.exited.store(true, .release);
            return status; // 성공 시 reaping=true 유지(reapAfterEof와 동일 — 자식은 이미 거둬졌다)
        }

        self.reaping.store(false, .release); // 아직 살아있다 — 다음 검증이 다시 시도할 수 있게 가드 반납
        return null;
    }

    /// 출력 이벤트를 하나 읽어 반환한다(blocking). 큐-기반 경로와 reader-processing 모두 사용. 내부적으로
    /// waitIo(write 없음)+readChunk+reapAfterEof로 조립한다(Phase 2 P2-2 — 동작 보존). EOF면 reap해
    /// exited/SessionClosed.
    pub fn readEvent(self: *PtySession, allocator: std.mem.Allocator) !types.PtyEvent {
        if (self.exited.load(.acquire)) return error.NoMoreEvents;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const ready = try self.waitIo(false);
            if (!ready.readable) continue; // write-pending wake(이 경로엔 안 옴) — 다시 기다린다
            switch (try self.readChunk(&buffer)) {
                .again => continue,
                .data => |n| {
                    const owned = try allocator.dupe(u8, buffer[0..n]);
                    return .{ .output = owned };
                },
                .eof => return if (try self.reapAfterEof()) |status|
                    .{ .exited = status }
                else
                    error.SessionClosed,
            }
        }
    }

    pub fn writeInput(self: *PtySession, bytes: []const u8) !void {
        const fd = try self.activeMasterFd();
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try writeFd(fd, bytes[written..]);
            if (n == 0) {
                // non-blocking 버퍼가 찼다 — writable이 될 때까지(또는 close) 기다렸다 재시도한다.
                // 키 입력은 작아 거의 안 걸리지만, 전량 전달 계약은 지킨다.
                try self.waitWritableOrClosing(fd);
                continue;
            }
            written += n;
        }
    }

    fn waitWritableOrClosing(self: *PtySession, fd: std.posix.fd_t) !void {
        if (self.closing.load(.acquire)) return error.SessionClosed;
        var fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 },
            .{ .fd = self.wake_read_fd, .events = poll_in_events, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch return error.WriteFailed;
        if (self.closing.load(.acquire)) return error.SessionClosed;
    }

    /// non-blocking 한 청크 쓰기: master fd가 O_NONBLOCK이라 버퍼에 들어가는 만큼만 쓰고(부분
    /// 쓰기 가능) 쓴 길이를 돌려준다. 버퍼가 차면 EAGAIN→0 — 자식이 stdin을 안 읽어도 절대
    /// 막히지 않는다(블록 fd+poll은 512B 여유를 보장 못 해 막힐 수 있었다, #5). 큰 붙여넣기를
    /// tick에 걸쳐 흘려보내는 paste 큐가 쓴다.
    pub fn writeInputNonBlocking(self: *PtySession, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;
        const fd = try self.activeMasterFd();
        return try writeFd(fd, bytes[0..@min(bytes.len, 512)]);
    }

    pub fn resize(self: *PtySession, size: terminal.Size) !void {
        const fd = try self.activeMasterFd();
        var window_size = winsizeFromTerminalSize(size);
        if (std.c.ioctl(fd, tio_cs_winsz, &window_size) < 0) return error.IoctlFailed;
        self.size = size;
    }

    pub fn currentSize(self: *PtySession) !terminal.Size {
        const fd = try self.activeMasterFd();
        var window_size: std.posix.winsize = undefined;
        if (std.c.ioctl(fd, std.c.T.IOCGWINSZ, &window_size) < 0) return error.IoctlFailed;
        return .{ .cols = window_size.col, .rows = window_size.row };
    }

    /// 에이전트가 **자식에게 내려주는 세션 신원**을 읽는다 — claude는 `CLAUDE_CODE_SESSION_ID`(그 값이 곧
    /// `<id>.jsonl` 파일명), codex는 `CODEX_THREAD_ID`(rollout 파일명의 uuid이자 `session_meta.id`)다.
    ///
    /// **왜 자식인가**: 두 provider 모두 자기 프로세스 env에는 이 값을 두지 않고(실측) 자식을 띄울 때만 주입한다.
    /// 그래서 `agent_pid`의 직속 자식을 열거해 첫 매치를 반환한다. 자식은 도구 실행 중에만 존재하므로 호출자가
    /// **한 번 얻은 값을 캐시**해야 한다 — 못 얻으면 null이고, 그때는 호출자가 활동 상관 폴백으로 내려간다.
    ///
    /// 값은 `out`에 복사해 슬라이스로 돌려준다(정적 procargs_buf를 가리키지 않게 — 다음 호출이 덮는다).
    /// **틱 스레드 전용**(procargs_buf 공유).
    pub fn agentSessionIdentity(agent_pid: i32, key: []const u8, out: []u8) ?[]const u8 {
        if (agent_pid <= 0 or out.len == 0) return null;
        // **손자까지 본다.** claude는 단일 프로세스라 도구 자식이 직속이지만, codex는 npm wrapper를 거쳐
        // (node wrapper → rust 바이너리) 도구 자식이 **손자**가 될 수 있다 — 한 단계만 보면 그 provider에서
        // 통째로 무동작이 된다. 깊이 2면 관측된 모든 배치를 덮고, 프로세스 수가 적어(에이전트당 한 자릿수)
        // 비용도 무시할 만하다.
        if (scanChildrenForEnv(agent_pid, key, out)) |found| return found;
        var top: [64]c_int = undefined;
        const top_count = proc_listchildpids(@intCast(agent_pid), &top, @intCast(@sizeOf(@TypeOf(top))));
        if (top_count > 0) {
            const n: usize = @min(@as(usize, @intCast(top_count)), top.len);
            for (top[0..n]) |kid| {
                if (kid <= 0) continue;
                if (scanChildrenForEnv(kid, key, out)) |found| return found;
            }
        }
        return null;
    }

    /// `ppid`의 **직속 자식**만 훑어 `key=` 환경변수를 찾는다(agentSessionIdentity의 한 단계).
    fn scanChildrenForEnv(ppid: i32, key: []const u8, out: []u8) ?[]const u8 {
        var kids: [64]c_int = undefined;
        // **반환값은 자식 개수다 — 바이트가 아니다.** 형제 API(`proc_listpids`·`proc_listpgrppids`)가 바이트를
        // 돌려주므로 나누고 싶어지지만, 실측하면 `ret=2, buf=[2397, 1862]`처럼 개수와 pid가 정확히 맞는다
        // (ps로 대조 확인). 나누면 자식 2개가 0으로 접혀 이 경로 전체가 조용히 무동작이 된다(적대적 검증에서 발견).
        const child_count = proc_listchildpids(@intCast(ppid), &kids, @intCast(@sizeOf(@TypeOf(kids))));
        if (child_count <= 0) return null;
        const count: usize = @min(@as(usize, @intCast(child_count)), kids.len);
        for (kids[0..count]) |kid| {
            if (kid <= 0) continue;
            var mib = [_]c_int{ ctl_kern, kern_procargs2, kid };
            var size: usize = procargs_buf.len;
            if (sysctl(&mib, mib.len, &procargs_buf, &size, null, 0) != 0) continue;
            const value = parseEnvValue(procargs_buf[0..size], key) orelse continue;
            const n = @min(value.len, out.len);
            @memcpy(out[0..n], value[0..n]);
            return out[0..n];
        }
        return null;
    }

    /// 이 PTY의 foreground process group 구성원 이름을 bounded fixed buffer에 채운다. 제품 spawn은 login(1)이
    /// group leader로 남고 실제 shell/agent가 같은 group의 child가 될 수 있어 leader PID 하나만 조회하면 안 된다.
    /// proc_listpgrppids 뒤 getpgid를 다시 확인해 열거와 이름 조회 사이 PID 재사용도 다른 그룹 이름으로 오인하지 않는다.
    /// comm이 interpreter/버전 문자열이면 argv basename으로 해소하지만, provider 판정은 app 계층이 맡는다.
    /// **틱 스레드에서만 호출**(정적 procargs_buf 공유, close와 fd lifecycle 규약은 foregroundProcessGroup과 동일).
    /// 이 세션의 프로세스 트리(셸 + 자손) 자원 표본. 상태바 리소스 항목이 backend seam으로 가져간다.
    /// 뿌리는 `child_pid`다 — login(1) wrapper가 뿌리여도 그 자손을 재귀로 훑으므로 실제 셸·에이전트가 잡힌다.
    /// 닫히는 중이면 0(죽은 pid를 훑어 봐야 실패만 쌓인다).
    pub fn resourceSamples(self: *PtySession, out: []types.ProcessResourceSample) usize {
        if (out.len == 0 or self.closing.load(.acquire) or self.exited.load(.acquire)) return 0;
        return processTreeSamples(self.child_pid, out);
    }

    pub fn foregroundProcessNames(self: *PtySession, out: []types.ForegroundProcessName) usize {
        if (out.len == 0 or self.closing.load(.acquire)) return 0;
        const fd = self.master_fd.load(.acquire);
        if (fd < 0) return 0;
        const pgid = tcgetpgrp(fd);
        if (pgid <= 0) return 0;

        var pids: [64]c_int = undefined;
        const listed = proc_listpgrppids(pgid, &pids, @intCast(@sizeOf(@TypeOf(pids))));
        if (listed <= 0) return 0;
        const pid_count = @min(@as(usize, @intCast(listed)), pids.len);
        var count: usize = 0;
        for (pids[0..pid_count]) |pid| {
            if (count == out.len) break;
            if (pid <= 0 or getpgid(pid) != pgid) continue;
            const dst = &out[count];
            const name = resolveProcessName(pid, &dst.bytes) orelse continue;
            dst.pid = pid;
            dst.len = @intCast(name.len);
            count += 1;
        }
        return count;
    }

    fn resolveProcessName(pid: c_int, out: []u8) ?[]const u8 {
        const n = proc_name(pid, out.ptr, @intCast(out.len));
        if (n <= 0) return null; // 0=실패(버퍼<32 포함). proc_name은 항상 buffersize보다 짧다.
        const comm = out[0..@intCast(n)];
        // comm이 인터프리터(node 등)면 argv[1] 스크립트 basename으로 교체 — codex 등 `#!/usr/bin/env node` 스크립트
        // 에이전트는 comm="node"라 안 잡히므로. 스크립트 basename은 정적 procargs_buf 슬라이스라 out으로 복사해 반환한다
        // (호출자가 다음 호출 전에 동기 소비 — out과 procargs_buf는 별개 버퍼라 겹침 없음).
        if (isInterpreterName(comm)) {
            if (foregroundScriptBasename(pid)) |script| {
                const m = @min(script.len, out.len);
                if (m > 0) {
                    std.mem.copyForwards(u8, out[0..m], script[0..m]);
                    return out[0..m];
                }
            }
        } else if (comm.len > 0 and std.ascii.isDigit(comm[0])) {
            // comm이 **버전 문자열처럼**(숫자로 시작, 예 "2.1.197") 보이면 argv[0] basename으로 교체 — Claude Code(v2.1.197+)
            // 처럼 에이전트가 실행 중 자기 process.title(=comm)을 버전으로 바꾸면 comm="claude"가 아니라 "2.1.197"로 읽혀
            // 감지가 실패한다(실측). argv[0]은 그대로 "claude"라 그걸 쓴다(node 인터프리터 폴백과 같은 패턴, argv[0] 인덱스만 다름).
            if (foregroundArgv0Basename(pid)) |a0| {
                const m = @min(a0.len, out.len);
                if (m > 0) {
                    std.mem.copyForwards(u8, out[0..m], a0[0..m]);
                    return out[0..m];
                }
            }
        }
        return comm;
    }

    /// 현재 foreground process group id. observer가 값 변화만 매 100ms 확인하고, 실제 proc_name 재조회는
    /// 변화 시 또는 저주기 재검증 때 수행한다.
    pub fn foregroundProcessGroup(self: *PtySession) ?i32 {
        if (self.closing.load(.acquire)) return null;
        const fd = self.master_fd.load(.acquire);
        if (fd < 0) return null;
        const pgid = tcgetpgrp(fd);
        return if (pgid > 0) pgid else null;
    }

    /// 이 터미널이 **서 있는 폴더**를 커널에서 읽는다(OSC 7이 없거나 지워졌을 때의 권위 있는 출처).
    ///
    /// **foreground PGID를 그대로 PID로 쓰면 안 된다.** 제품 spawn은 `/usr/bin/login`이 wrapper로 남고 실제
    /// 셸이 같은 그룹의 child로 도는데(위 `foregroundProcessNames` 주석·테스트가 같은 사실을 고정한다), leader만
    /// 조회하면 **login wrapper의 cwd(홈 등)** 를 읽어 "터미널이 서 있는 폴더"가 통째로 틀린다. 그러면 소스
    /// 컨트롤 뷰가 남의 저장소를 보여 준다 — 실측으로 재현했고 아래 login wrapper 테스트가 그 회귀를 막는다.
    ///
    /// 조회 순서:
    /// 1. **foreground group의 leader가 아닌 구성원** — login wrapper 아래의 실제 셸·에이전트가 여기 있다.
    ///    파이프라인(`a | b`)이면 구성원이 여럿이지만 전부 같은 셸에서 나와 cwd를 물려받으므로 아무나 맞다.
    /// 2. **leader 자신** — claude·vim처럼 자기 프로세스 그룹을 만든 경우 구성원이 하나뿐이고 그게 정답이다.
    /// 3. **child_pid** — foreground를 못 얻는 과도기(그룹 전환 중, tcgetpgrp 실패)의 폴백. 이 세션의 뿌리다.
    ///
    /// 열거와 조회 사이의 PID 재사용은 `getpgid` 재확인으로 막는다 — 그 사이 죽은 pid 자리에 들어온 **무관한
    /// 프로세스의 cwd**를 읽으면 조용히 엉뚱한 저장소가 잡힌다(`foregroundProcessNames`와 같은 규율).
    ///
    /// 닫히는 중이거나 이미 종료한 세션은 조회하지 않는다 — 죽은 pid를 훑어 봐야 실패만 쌓인다.
    /// syscall이 있으므로 **매 프레임 부르지 않는다**(호출자가 OSC 7이 빈 경우로 한정하고 저주기로 캐시한다).
    pub fn processCwd(self: *PtySession, out: []u8) ?[]const u8 {
        if (out.len == 0 or self.closing.load(.acquire) or self.exited.load(.acquire)) return null;
        if (self.foregroundProcessGroup()) |pgid| {
            var pids: [64]c_int = undefined;
            const listed = proc_listpgrppids(pgid, &pids, @intCast(@sizeOf(@TypeOf(pids))));
            if (listed > 0) {
                const count = @min(@as(usize, @intCast(listed)), pids.len);
                for (pids[0..count]) |pid| {
                    if (pid <= 0 or pid == pgid or getpgid(pid) != pgid) continue;
                    if (processCwdForPid(pid, out)) |cwd| return cwd;
                }
            }
            if (getpgid(pgid) == pgid) {
                if (processCwdForPid(pgid, out)) |cwd| return cwd;
            }
        }
        return processCwdForPid(self.child_pid, out);
    }

    fn activeMasterFd(self: *PtySession) !std.posix.fd_t {
        // close()는 master fd를 닫지 않고 closing 플래그만 올린다(close 주석 참고).
        // 그래서 닫힌 세션 여부는 fd 음수가 아니라 closing으로 판단한다.
        if (self.closing.load(.acquire)) return error.SessionClosed;
        const fd = self.master_fd.load(.acquire);
        if (fd < 0) return error.SessionClosed;
        return fd;
    }

    // EOF를 봤지만 child가 아직 살아 있을 때(stdio만 닫은 daemonize 경우) 호출한다.
    // bare blocking waitpid 대신 kqueue로 child의 실제 종료(EVFILT_PROC/NOTE_EXIT)와
    // close의 self-pipe wake(EVFILT_READ)를 함께 기다린다. 그래서 child가 끝내 종료하지
    // 않아도 close()/stopAndJoin이 우리를 깨워 join이 멈추지 않는다.
    fn waitChildExitOrClosing(self: *PtySession) !void {
        const kq = std.c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        defer closeFd(kq);

        // EV_RECEIPT로 각 등록의 성공/실패를 eventlist로 즉시 돌려받는다(대기 안 함).
        var changes = [_]std.c.Kevent{
            .{
                .ident = @intCast(self.child_pid),
                .filter = std.c.EVFILT.PROC,
                .flags = std.c.EV.ADD | std.c.EV.RECEIPT,
                .fflags = std.c.NOTE.EXIT,
                .data = 0,
                .udata = 0,
            },
            .{
                .ident = @intCast(self.wake_read_fd),
                .filter = std.c.EVFILT.READ,
                .flags = std.c.EV.ADD | std.c.EV.RECEIPT,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        };
        var receipts: [changes.len]std.c.Kevent = undefined;
        const reg = std.c.kevent(kq, &changes, changes.len, &receipts, receipts.len, null);
        if (reg < 0) return error.KeventFailed;

        var idx: usize = 0;
        while (idx < @as(usize, @intCast(reg))) : (idx += 1) {
            const ev = receipts[idx];
            if ((ev.flags & std.c.EV.ERROR) == 0 or ev.data == 0) continue;
            // child가 등록 직전에 종료해 PROC 등록이 실패하면(ESRCH 등) NOTE_EXIT를
            // 못 받는다. 그냥 반환해 호출부의 WNOHANG 재시도가 zombie를 거두게 한다.
            if (ev.filter == std.c.EVFILT.PROC) return;
            // wake pipe 등록 실패는 비정상이므로 에러로 알린다.
            return error.KeventFailed;
        }

        // child 종료(NOTE_EXIT) 또는 close wake가 올 때까지 막는다. 어느 쪽이든
        // 깨어나면 호출부가 closing/WNOHANG로 다음에 무엇을 할지 다시 정한다.
        var events: [changes.len]std.c.Kevent = undefined;
        while (true) {
            const n = std.c.kevent(kq, &changes, 0, &events, events.len, null);
            if (n >= 0) return;
            if (std.posix.errno(n) == .INTR) continue;
            return error.KeventFailed;
        }
    }
};

test "processResourceSample: 자기 프로세스는 그럴듯한 값을 준다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const me = std.c.getpid();
    const s = processResourceSample(me) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, @intCast(me)), s.pid);
    // 살아서 이 코드를 돌고 있으니 메모리는 1 MiB 이상이고, 테스트 프로세스가 64 GiB를 쓸 리는 없다.
    // (상한이 있어야 **레이아웃이 어긋나 엉뚱한 필드를 읽는 경우**를 잡는다 — 그때 값이 천문학적으로 튄다.)
    try std.testing.expect(s.footprint_bytes > 1024 * 1024);
    try std.testing.expect(s.footprint_bytes < 64 * 1024 * 1024 * 1024);
    try std.testing.expect(s.cpu_ns > 0);
    try std.testing.expect(s.cpu_ns < 24 * std.time.ns_per_hour);
}

test "processResourceSample: 없는 pid는 null이다(쓰레기값을 읽지 않는다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // pid 0은 커널 자리라 rusage가 실패한다. 실패를 null로 돌려주지 않으면 미초기화 구조체를 읽어
    // 7.6e12 MB 같은 값이 나온다(실측).
    try std.testing.expect(processResourceSample(0) == null);
}

test "processCwdForPid: 자기 pid의 cwd가 getcwd와 정확히 같다(레이아웃 드리프트 감지)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // `proc_vnodepathinfo`를 손으로 미러하지 않고 **오프셋 상수**로 읽으므로, 그 상수가 틀리면 컴파일러가 못 잡는다.
    // 이 테스트가 그 안전망이다 — 커널이 우리에게 준 경로와 libc가 아는 cwd가 바이트 단위로 같아야 한다.
    // macOS SDK가 구조체 레이아웃을 바꾸면 여기서 먼저 깨진다(제품에서 남의 저장소를 보여 주기 전에).
    // 저장소가 쓰는 libc getcwd 패턴 그대로다(`git_backend.zig` 테스트들과 동일 — std.Io엔 getcwd가 없다).
    var expect_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expect_ptr = std.c.getcwd(&expect_buf, expect_buf.len) orelse return error.TestUnexpectedResult;
    const expected = std.mem.span(@as([*:0]u8, @ptrCast(expect_ptr)));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = processCwdForPid(std.c.getpid(), &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, got);
}

test "processCwdForPid: 못 읽는 pid와 좁은 버퍼는 null이다(자른 경로를 돌려주지 않는다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // pid 0은 커널 자리라 조회가 실패한다. 실패를 null로 접지 않으면 미초기화 버퍼를 경로로 읽는다.
    try std.testing.expect(processCwdForPid(0, &buf) == null);
    try std.testing.expect(processCwdForPid(-1, &buf) == null);

    // **자르지 않는다.** cwd가 `/Users/me/work/repo`인데 `/Users/me`로 잘라 주면 호출자가 엉뚱한 상위
    // 디렉터리를 저장소 루트로 잡아 **남의 저장소 상태**를 보여 준다. 그래서 모자라면 실패다.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(processCwdForPid(std.c.getpid(), &tiny) == null);
    var none: [0]u8 = undefined;
    try std.testing.expect(processCwdForPid(std.c.getpid(), &none) == null);
}

test "processTreeSamples: 뿌리뿐 아니라 **자손까지** 담는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [64]types.ProcessResourceSample = undefined;
    const me = std.c.getpid();

    // **뿌리만 확인하면 자식 열거가 깨져도 통과한다.** 실제로 그렇게 깨져 있었다:
    // `proc_listchildpids`는 pid **개수**를 돌려주는데 바이트로 보고 4로 나눠 자식이 늘 0이었고,
    // 제품에서는 뿌리가 setuid root인 `login(1)`이라 그 자신은 EPERM으로 표본이 안 잡혀 **합계가 0**이었다.
    // 그래서 여기서 자식을 하나 만들어 트리가 실제로 내려가는지 본다.
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        // 자식: 부모가 표본을 뜰 때까지 살아 있기만 하면 된다(그 뒤 부모가 죽인다).
        // Zig 0.16 std.c에 usleep이 없다 — 저장소가 쓰는 poll 대기 패턴을 그대로 쓴다.
        while (true) {
            var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
            _ = std.c.poll(@ptrCast(&delay_fd), 0, 50);
        }
        std.c._exit(0);
    }
    defer {
        _ = std.c.kill(child, std.c.SIG.KILL);
        var status: c_int = 0;
        _ = std.c.waitpid(child, &status, 0);
    }

    const n = processTreeSamples(me, &buf);
    try std.testing.expect(n >= 2); // 나 + 방금 만든 자식
    try std.testing.expect(n <= buf.len);
    try std.testing.expectEqual(@as(i32, @intCast(me)), buf[0].pid);
    var saw_child = false;
    for (buf[0..n]) |sample| {
        if (sample.pid == @as(i32, @intCast(child))) saw_child = true;
    }
    try std.testing.expect(saw_child);

    // out이 비면 아무것도 안 쓴다(경계).
    var empty: [0]types.ProcessResourceSample = undefined;
    try std.testing.expectEqual(@as(usize, 0), processTreeSamples(me, &empty));
    // 유효하지 않은 뿌리도 안전하다.
    try std.testing.expectEqual(@as(usize, 0), processTreeSamples(0, &buf));
}

// execve는 argv 문자열들이 child가 exec될 때까지 유효해야 한다.
// 그래서 request의 slice를 그대로 빌려 쓰지 않고, null-terminated 복사본을 session spawn 중에 보관한다.
const ArgvStorage = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    argv: [:null]?[*:0]const u8,

    // argv[0]=command(경로 그대로), argv[1..]=args. login shell 셋업은 spawn에서 login(1) 래핑으로
    // 처리하므로(MacosLogin) 여기는 평범하게 둔다.
    fn init(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !ArgvStorage {
        const argc = 1 + args.len;
        const strings = try allocator.alloc([:0]u8, argc);
        errdefer allocator.free(strings);

        var initialized: usize = 0;
        errdefer {
            for (strings[0..initialized]) |owned| allocator.free(owned);
        }

        strings[0] = try allocator.dupeZ(u8, command);
        initialized += 1;

        for (args, 0..) |arg, index| {
            strings[index + 1] = try allocator.dupeZ(u8, arg);
            initialized += 1;
        }

        const argv = try allocator.allocSentinel(?[*:0]const u8, argc, null);
        errdefer allocator.free(argv);
        for (strings, 0..) |arg, index| argv[index] = arg.ptr;

        return .{ .allocator = allocator, .strings = strings, .argv = argv };
    }

    fn deinit(self: *ArgvStorage) void {
        for (self.strings) |arg| self.allocator.free(arg);
        self.allocator.free(self.strings);
        self.allocator.free(self.argv);
    }
};

// macOS login(1) 래핑 — Terminal.app·Ghostty와 동일하게 전체 로그인 세션(getlogin()·SHELL·utmp·
// hushlogin)을 셋업한 뒤 셸을 login shell로 exec한다. 단순히 argv[0]에 `-`만 붙이면 .zprofile은
// 읽지만 getlogin()/SHELL/세션 env가 안 잡혀, 그에 의존하는 셸 설정(예: $TERM_PROGRAM별 키바인딩)이
// 어긋난다(실측: Cmd+Left는 되는데 Cmd+Right는 안 됨). 형태(Ghostty가 Apple login.c를 읽고 찾은):
//   /usr/bin/login [-q] -flp <user> /bin/bash --noprofile --norc -c "exec -l '<shell>' '<args>'"
//   -f 인증 생략, -l login(1)이 cwd를 home으로 안 바꾸게, -p env 보존, -q hushlogin(.hushlogin 있을 때).
//   설정 무로드 bash가 `exec -l`로 최종 셸을 login shell로 교체한다(bash가 zsh보다 exec ~2배 빠름).
const MacosLogin = struct {
    owned: [][]u8, // 동적 할당 인자(username 복사, "exec -l ..." 문자열) — deinit이 해제
    args: [][]const u8, // ArgvStorage에 넘길 login(1) 인자(리터럴 + owned 슬라이스 혼합)

    fn build(allocator: std.mem.Allocator, request: types.SpawnRequest) !MacosLogin {
        const pw = std.c.getpwuid(std.c.getuid()) orelse return error.NoPasswd;
        const username = std.mem.span(pw.name orelse return error.NoUsername);

        // hushlogin: 홈에 .hushlogin이 있으면 login 배너를 억제(-q). login(1) -l은 cwd 기준으로
        // 보므로 우리가 홈을 직접 확인해 -q를 준다(Ghostty와 동일 이유).
        const hush = if (pw.dir) |dir_ptr| blk: {
            const home = std.mem.span(dir_ptr);
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/.hushlogin", .{home}) catch break :blk false;
            break :blk std.c.access(path.ptr, std.posix.F_OK) == 0;
        } else false;

        // "exec -l '<command>' '<arg1>' ..." — bash가 실행해 최종 셸을 login shell로 교체한다. command·args를 각각
        // 작은따옴표로 감싼다(appendSingleQuoted) — 경로/인자에 공백·셸 메타문자가 있어도(예: `/Applications/My App/sh`)
        // bash가 word-split·해석하지 않게 한다. command는 resolveConfiguredShell이 절대경로만 통과시키므로 `exec`가 PATH
        // 검색 없이 그 경로를 실행한다.
        var cmd_buf: std.ArrayList(u8) = .empty;
        defer cmd_buf.deinit(allocator);
        try cmd_buf.appendSlice(allocator, "exec -l ");
        try types.appendSingleQuoted(allocator, &cmd_buf, request.command);
        for (request.args) |a| {
            try cmd_buf.append(allocator, ' ');
            try types.appendSingleQuoted(allocator, &cmd_buf, a);
        }
        const exec_cmd = try cmd_buf.toOwnedSlice(allocator);
        errdefer allocator.free(exec_cmd);
        const user_dup = try allocator.dupe(u8, username);
        errdefer allocator.free(user_dup);

        var owned: std.ArrayList([]u8) = .empty;
        errdefer owned.deinit(allocator);
        try owned.append(allocator, exec_cmd);
        try owned.append(allocator, user_dup);

        var args: std.ArrayList([]const u8) = .empty;
        errdefer args.deinit(allocator);
        if (hush) try args.append(allocator, "-q");
        try args.append(allocator, "-flp");
        try args.append(allocator, user_dup);
        try args.append(allocator, "/bin/bash");
        try args.append(allocator, "--noprofile");
        try args.append(allocator, "--norc");
        try args.append(allocator, "-c");
        try args.append(allocator, exec_cmd);

        return .{
            .owned = try owned.toOwnedSlice(allocator),
            .args = try args.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *MacosLogin, allocator: std.mem.Allocator) void {
        for (self.owned) |s| allocator.free(s);
        allocator.free(self.owned);
        allocator.free(self.args);
    }
};

/// bash `-c "exec -l ..."`에 토큰 하나를 **작은따옴표로 감싸** 붙인다 — 셸 경로/인자에 공백·셸 메타문자(`$`·`;`·`&`·
/// 따옴표 등)가 있어도 bash가 word-split·해석하지 않고 문자 그대로 넘기게 한다. POSIX 규칙: 토큰을 `'...'`로 감싸고
/// 내부의 `'`는 `'\''`(따옴표 닫기 → 이스케이프된 `'` → 다시 열기)로 끊는다. 빈 토큰은 `''`가 돼 안전하다.

// `/bin/sh -c <cmd>`를 돌려 기다린다(POSIX). std.c에 노출이 없어 직접 선언한다(setenv/unsetenv와 같은 결).
extern "c" fn system(command: [*:0]const u8) c_int;

const ResolvedTerm = struct { term: []const u8, terminfo_dir: ?[]const u8 };

// 전환 #1(기본값 xterm-maru): 자식 셸에 줄 TERM/TERMINFO를 정한다. term이 "xterm-maru"면 embed된
// 소스를 maru 자기 캐시(`~/.cache/maru/terminfo`)에 (없으면) 컴파일하고, xterm-maru가 해석되면
// TERM=xterm-maru + TERMINFO=캐시로 쓴다 — 로컬 프로그램이 설치 없이 찾는다(비침습: ~/.terminfo 안 건드림).
// tic이 없거나 컴파일 실패면 xterm-256color로 폴백 → 로컬이 절대 안 깨진다(Ghostty Exec.zig 동작 비교).
// 프로세스 1회만 판정해 캐시한다(이후 spawn은 재사용 — 가벼운 race는 무해, 결과 동일). dir은 프로세스
// 동안 모든 spawn이 env에 쓰므로 page_allocator로 의도적 leak(작은 문자열).
var g_resolved_term: ?ResolvedTerm = null;

fn resolveTerm(term: []const u8) ResolvedTerm {
    if (!std.mem.eql(u8, term, terminfo_cache.term_name)) return .{ .term = term, .terminfo_dir = null };
    if (g_resolved_term) |r| return r;
    const r = computeMaruTerminfo();
    g_resolved_term = r;
    return r;
}

fn computeMaruTerminfo() ResolvedTerm {
    const fallback = ResolvedTerm{ .term = "xterm-256color", .terminfo_dir = null };
    const page = std.heap.page_allocator;
    const home_z = std.c.getenv("HOME") orelse return fallback;
    const home = std.mem.span(home_z);
    // base 판정은 `user_paths.cacheBaseFor`가 소유한다(XDG 최우선, Windows는 %LOCALAPPDATA% — 계약 §5.3).
    const xdg = if (std.c.getenv("XDG_CACHE_HOME")) |x| std.mem.span(x) else null;
    const local = if (std.c.getenv("LOCALAPPDATA")) |l| std.mem.span(l) else null;
    const base = user_paths.cacheBaseFor(@import("builtin").os.tag, xdg, local);
    const dir = terminfo_cache.cacheDirZ(page, base, home) catch return fallback;
    // 버전 마커가 현재 embed 내용과 일치하고 xterm-maru가 해석되면 재컴파일 skip, 아니면(업데이트로 캡이
    // 바뀜·마커 없음) 캐시를 자동 재컴파일한다 — terminfo를 늘려도 기존 캐시에 자동 반영된다(stale 방지).
    // 같은 캐시·마커를 `maru terminfo` 서브커맨드(cli/terminfo.zig)가 공유한다.
    // **경로는 여기서 한 번만 정한다** — 셸에 리터럴로 넘긴다(예전엔 셸이 다시 확장해 규칙이 둘이었다).
    const cmd = terminfo_cache.autoCompileCommand(page, dir, terminfo_cache.version()) catch {
        page.free(dir);
        return fallback;
    };
    defer page.free(cmd);
    if (system(cmd.ptr) == 0) return .{ .term = terminfo_cache.term_name, .terminfo_dir = dir }; // dir은 의도적 leak(프로세스 수명)
    page.free(dir);
    return fallback;
}

// env가 비어 있으면 부모 환경을 그대로 상속한다.
// 명시 env가 있으면 execve가 요구하는 null-terminated envp 배열로 바꿔 child에게만 전달한다.
const EnvStorage = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    envp: ?[:null]?[*:0]const u8,

    /// owned env 문자열을 entries에 추가하되 append 실패(OOM)면 그 문자열을 해제한다 — errdefer가 entries.items만
    /// 풀어 append 인자에서 만든 dupe가 새는 것을 막는 OOM-safe 관용구(부모 복사·TERM·COLORTERM·TERM_PROGRAM·ZDOTDIR 공용).
    fn appendOwnedEnv(allocator: std.mem.Allocator, entries: *std.ArrayList([:0]u8), owned: [:0]u8) !void {
        entries.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }

    /// 훅 pane 칸 없이 부르는 얇은 래퍼(테스트·부모 스냅샷이 없는 경로). 제품 spawn 은
    /// `initWithParentSnapshot` 을 직접 부른다 — 훅 경로의 두 칸이 함께 실리는 곳은 거기다.
    fn init(allocator: std.mem.Allocator, env: []const []const u8, env_overrides: []const []const u8, term: []const u8, zdotdir: ?[]const u8, ssh_integration_bin: ?[]const u8, pane_id: ?u64, hook_instance: ?[]const u8) !EnvStorage {
        return initWithParentSnapshot(allocator, env, null, env_overrides, term, zdotdir, ssh_integration_bin, pane_id, hook_instance, null);
    }

    fn initWithParentSnapshot(allocator: std.mem.Allocator, env: []const []const u8, parent_env: ?[]const []const u8, env_overrides: []const []const u8, term: []const u8, zdotdir: ?[]const u8, ssh_integration_bin: ?[]const u8, pane_id: ?u64, hook_instance: ?[]const u8, hook_pane: ?[]const u8) !EnvStorage {
        var entries: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (entries.items) |owned| allocator.free(owned);
            entries.deinit(allocator);
        }

        if (env.len == 0) {
            // 부모 환경을 물려주되 TERM/COLORTERM은 Maru 값으로 덮어쓴다(appendParentEnv). 부모 TERM을 그대로 주면
            // (예: 멀티플렉서 TERM, 또는 Maru 동작과 안 맞는 terminfo) zsh의 SIGWINCH redraw가 wrap 행 수를 잘못
            // 계산해(상대 커서 이동 \e[A 횟수가 어긋남) 프롬프트가 중복된다. 기본 xterm-256color는 Maru의 xterm식
            // (auto-wrap + deferred wrap) 동작과 맞는다. 단 사용자 config(`term =`)로 바꿀 수 있다.
            try appendParentEnv(allocator, &entries, parent_env, term, zdotdir, ssh_integration_bin);
        } else {
            // 명시 env(테스트 등): 부모 상속·일반 maru override 없이 그대로 쓰되 process-local selector는 예약 키라
            // 제거한다. non-null pane_id면 공통 tail에서 현재 값만 다시 넣는다.
            for (env) |entry| {
                if (isPaneSelectorEntry(entry)) continue;
                try appendOwnedEnv(allocator, &entries, try allocator.dupeZ(u8, entry));
            }
        }

        // 사용자 config `env.<KEY>`를 부모/명시 env + 일반 maru override(TERM 등) 위에 적용한다. 단 아래 내부
        // selector는 Term identity의 단일 출처라 사용자 값보다 마지막에 다시 upsert한다.
        for (env_overrides) |ov| {
            if (isPaneSelectorEntry(ov)) continue;
            try upsertEnv(allocator, &entries, ov);
        }

        // control-plane selector는 사용자가 env.*로 덮어쓸 수 없는 내부 예약 키다.
        if (pane_id) |pid| {
            const value = try std.fmt.allocPrint(allocator, "MARU_PANE_ID={d}", .{pid});
            defer allocator.free(value);
            try upsertEnv(allocator, &entries, value);
        }
        // 훅 로그 경로의 두 칸도 같은 부류다 — null 이면 주입하지 않고, 그러면 훅이 조용히 나간다
        // (fail-closed: 값이 유효하지 않은 경로에서 남의 인스턴스 디렉터리에 쓰지 않는다).
        //
        // **여기서 한 번 더 검사한다.** 모양의 단일 출처는 계약 모듈(`agent_hook_command`)이지만, 이 env 를
        // 쓰는 것이 **실제로 파일이 만들어지는 자리**다(훅이 `<로그>/<인스턴스>/<pane>.ndjson` 에 append 한다).
        // 그래서 이 층은 모양 전체를 다시 판정하지 않고 **경로를 벗어나지 못한다는 성질 하나**만 지킨다 —
        // 같은 규칙의 복사가 아니라 다른 일을 하는 가드다(실측 2026-08-20: 검증이 없을 때 `../outside/pwned`
        // 가 로그 디렉터리 밖에 파일을 만들었다).
        if (hook_instance) |token| {
            if (isSafePathSegment(token)) {
                const value = try std.fmt.allocPrint(allocator, "MARU_HOOK_INSTANCE={s}", .{token});
                defer allocator.free(value);
                try upsertEnv(allocator, &entries, value);
            }
        }
        if (hook_pane) |token| {
            if (isSafePathSegment(token)) {
                const value = try std.fmt.allocPrint(allocator, "MARU_HOOK_PANE={s}", .{token});
                defer allocator.free(value);
                try upsertEnv(allocator, &entries, value);
            }
        }

        return materialize(allocator, &entries);
    }

    /// entries를 owned strings + sentinel envp로 굳혀 EnvStorage를 만든다(부모/명시 두 경로 공용 tail).
    /// toOwnedSlice가 entries 버퍼 소유권을 strings로 옮기므로(entries는 비워짐), 호출자 errdefer(entries)는
    /// 이후 빈 리스트를 보고 아무것도 안 푼다(이중 free 없음).
    fn materialize(allocator: std.mem.Allocator, entries: *std.ArrayList([:0]u8)) !EnvStorage {
        const strings = try entries.toOwnedSlice(allocator);
        errdefer {
            for (strings) |owned| allocator.free(owned);
            allocator.free(strings);
        }
        const envp = try allocator.allocSentinel(?[*:0]const u8, strings.len, null);
        for (strings, 0..) |entry, i| envp[i] = entry.ptr;
        return .{ .allocator = allocator, .strings = strings, .envp = envp };
    }

    /// `env_overrides`의 "KEY=VALUE"를 entries에 upsert한다 — 같은 KEY("KEY=" 접두)가 있으면 그 자리에서 교체
    /// (덮어쓰기), 없으면 끝에 추가. '='가 없으면 graceful skip(loader가 형식을 보장하지만 안전하게 무시).
    fn upsertEnv(allocator: std.mem.Allocator, entries: *std.ArrayList([:0]u8), override: []const u8) !void {
        const eq = std.mem.indexOfScalar(u8, override, '=') orelse return;
        const key_prefix = override[0 .. eq + 1]; // "KEY=" (= 포함) — 정확한 키 경계 매칭
        const owned = try allocator.dupeZ(u8, override);
        for (entries.items, 0..) |entry, i| {
            if (std.mem.startsWith(u8, entry, key_prefix)) {
                allocator.free(entry);
                entries.items[i] = owned;
                return;
            }
        }
        entries.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }

    // 부모 환경(std.c.environ)을 entries에 복사하되 TERM은 인자 값(기본 xterm-256color, 사용자 config로 변경
    // 가능)으로, COLORTERM은 truecolor로 교체한다. zdotdir이 있으면 ZDOTDIR을 그 값으로 주입하고(셸 통합),
    // 기존 ZDOTDIR은 MARU_ZDOTDIR_PREV로 보존해 통합 .zshenv가 복원한다. ssh_integration_bin이 있으면(opt-in)
    // MARU_BIN/MARU_SSH_INTEGRATION을 주입해 통합 .zshenv가 ssh를 maru ssh로 라우팅하게 한다. entries 소유권·
    // errdefer는 호출자(init)가 가진다(materialize에서 굳힌다).
    fn appendParentEnv(allocator: std.mem.Allocator, entries: *std.ArrayList([:0]u8), parent_env: ?[]const []const u8, term: []const u8, zdotdir: ?[]const u8, ssh_integration_bin: ?[]const u8) !void {
        // 부모의 모든 env entry를 복사한다. 단 TERM/COLORTERM(+통합 시 ZDOTDIR/MARU_ZDOTDIR_PREV)은
        // 건너뛰고 아래에서 우리 값으로 넣는다(중복 키는 첫 항목이 이기므로 부모 것을 빼야 한다).
        var old_zdotdir: ?[]const u8 = null; // environ 슬라이스(프로세스 수명 동안 유효) — 루프 후 사용
        var inherited: std.ArrayListUnmanaged([]const u8) = .empty;
        defer inherited.deinit(allocator);
        if (parent_env) |snapshot| {
            try inherited.appendSlice(allocator, snapshot);
        } else {
            const environ = std.c.environ;
            var index: usize = 0;
            while (environ[index]) |entry| : (index += 1) {
                try inherited.append(allocator, std.mem.span(entry));
            }
        }
        for (inherited.items) |slice| {
            if (std.mem.startsWith(u8, slice, "TERM=") or std.mem.startsWith(u8, slice, "COLORTERM=")) continue;
            // 부모(런처/상위 터미널)의 TERMINFO도 떨군다 — 아래에서 maru 캐시를 가리키거나, 폴백이면 안 준다.
            // 부모 TERMINFO를 그대로 두면 xterm-maru를 엉뚱한 DB에서 찾아 못 찾을 수 있다.
            if (std.mem.startsWith(u8, slice, "TERMINFO=")) continue;
            // 부모(런처/상위 터미널)가 남긴 TERM_PROGRAM(+VERSION)을 떨군다 — 아래에서 ghostty로 덮어쓴다(알림 식별용).
            if (std.mem.startsWith(u8, slice, "TERM_PROGRAM=") or std.mem.startsWith(u8, slice, "TERM_PROGRAM_VERSION=")) continue;
            // 런처(빌드 도구·부모 셸·CI)가 남긴 색-강제 override를 떨군다. supports-color(codex 등)는
            // CLICOLOR_FORCE!=0 / FORCE_COLOR을 env_force_color로 먼저 평가해 색 레벨을 강제하는데, 흔히 1(basic
            // 16색)이라 COLORTERM=truecolor를 무시하고 truecolor를 끈다(실측: `zig build`로 띄운 maru에서 상속된
            // CLICOLOR_FORCE=1 때문에 codex가 입력창 회색 컴포저를 truecolor로 못 그림 — GUI 실행 시엔 없어 정상).
            // maru가 터미널이므로 색 capability는 위 COLORTERM/TERM으로만 알린다 — 이 force 변수는 자식에 안 넘긴다.
            if (std.mem.startsWith(u8, slice, "CLICOLOR_FORCE=") or std.mem.startsWith(u8, slice, "FORCE_COLOR=")) continue;
            if (zdotdir != null) {
                if (std.mem.startsWith(u8, slice, "ZDOTDIR=")) {
                    old_zdotdir = slice["ZDOTDIR=".len..];
                    continue;
                }
                if (std.mem.startsWith(u8, slice, "MARU_ZDOTDIR_PREV=")) continue; // stale 제거
            }
            // ssh 라우팅을 주입할 거면 부모가 남긴 동명 키를 떨군다(중복 키는 첫 항목이 이기므로).
            if (ssh_integration_bin != null and
                (std.mem.startsWith(u8, slice, "MARU_BIN=") or std.mem.startsWith(u8, slice, "MARU_SSH_INTEGRATION="))) continue;
            // 부모가 남긴 MARU_PANE_ID는 항상 떨군다. non-null이면 tail에서 현재 GUI surface id를 새로 넣고,
            // persistent child처럼 null이면 selector 자체가 없어야 한다. maru를 maru 팬 안에서 띄웠을 때 바깥
            // 팬 id를 상속하면 다른 surface를 self로 오인한다. 이게 #1131 env-상속 오염을 원천 차단하는 지점이다.
            if (isPaneSelectorEntry(slice)) continue;
            // 바깥 **터미널 멀티플렉서**의 신원도 같은 이유로 떨군다. maru가 spawn하는 셸은 tmux pane이
            // **아닌데**, maru를 tmux 팬 안에서 띄우면(`zig build run`·`nohup ./Maru.app/...`) 그 셸이 바깥
            // 서버의 `TMUX`/`TMUX_PANE`를 물려받아 "나는 tmux 안"이라고 착각한다. 그 거짓말을 믿는 도구가
            // 오작동한다 — 실측: 셸 통합/프롬프트가 OSC를 **DCS passthrough**(`\ePtmux;…`)로 감싸 내보내는데
            // 바깥 maru는 tmux가 아니라 그걸 못 풀어, cwd 보고(OSC 7)가 통째로 유실되고 사이드바의 경로·git
            // 브랜치 줄이 사라졌다(OSC 133은 감싸지 않는 구현이라 도착해, 원인이 한참 가려졌다). `tmux` 명령이
            // 엉뚱한 서버를 조작하는 것도 같은 뿌리다. `MARU_PANE_ID`를 떨구는 것과 **같은 부류**의 오염 차단이다.
            if (isMultiplexerEntry(slice)) continue;
            // append 인자 안에서 dupe하면 OOM 시 새므로(errdefer는 entries.items만 해제) appendOwnedEnv로 묶는다.
            try appendOwnedEnv(allocator, entries, try allocator.dupeZ(u8, slice));
        }
        // 전환 #1: TERM이 xterm-maru면 embed 소스를 캐시에 컴파일하고 TERMINFO를 거기로, 안 되면
        // xterm-256color 폴백(로컬 안 깨짐). 그 외 term은 그대로(사용자 명시값).
        const resolved = resolveTerm(term);
        try appendOwnedEnv(allocator, entries, try std.fmt.allocPrintSentinel(allocator, "TERM={s}", .{resolved.term}, 0));
        if (resolved.terminfo_dir) |dir| {
            try appendOwnedEnv(allocator, entries, try std.fmt.allocPrintSentinel(allocator, "TERMINFO={s}", .{dir}, 0));
        }
        try appendOwnedEnv(allocator, entries, try allocator.dupeZ(u8, "COLORTERM=truecolor"));
        // Claude Code/Codex 등 TUI는 데스크톱 알림을 보낼 터미널을 TERM_PROGRAM 화이트리스트
        // (iTerm.app/ghostty/kitty/WezTerm)로 식별한다 — maru는 그 명단에 없어 기본(auto)에선 OSC 9 알림을
        // 못 받는다(사용자가 settings.json·config.toml 수동 설정 필요; preferredNotifChannel은 env override가
        // 불가해 우회 못 함). maru를 ghostty로 식별시켜 무설정 자동 알림을 받는다. ghostty를 고른 건 maru가 kitty
        // graphics·OSC 9/133/777을 ghostty와 같은 셋으로 지원해 식별 후 기대되는 기능과 어긋나지 않기 때문이다
        // (iTerm.app은 inline-image OSC 1337을 기대해 부적합). maru는 OSC 9를 직접 파싱해(core.zig) 네이티브
        // 알림으로 띄운다. 베이스/결정: 알림 호환을 위한 식별값일 뿐 — 사용자가 config.term으로 TERM은 바꿔도 이 값은 고정.
        try appendOwnedEnv(allocator, entries, try allocator.dupeZ(u8, "TERM_PROGRAM=ghostty"));
        if (zdotdir) |zd| {
            try appendOwnedEnv(allocator, entries, try std.fmt.allocPrintSentinel(allocator, "ZDOTDIR={s}", .{zd}, 0));
            if (old_zdotdir) |prev| {
                try appendOwnedEnv(allocator, entries, try std.fmt.allocPrintSentinel(allocator, "MARU_ZDOTDIR_PREV={s}", .{prev}, 0));
            }
        }
        // opt-in ssh 라우팅: 통합 .zshenv가 둘 다 보고 ssh()를 정의한다(둘 중 하나라도 없으면 평범한 ssh).
        // MARU_BIN은 현재 maru 실행 파일(같은 바이너리가 `maru ssh`를 처리 — main.zig). 값은 호출자 소유라
        // 여기서 dupe해 envp 수명에 맞춘다.
        if (ssh_integration_bin) |bin| {
            try appendOwnedEnv(allocator, entries, try std.fmt.allocPrintSentinel(allocator, "MARU_BIN={s}", .{bin}, 0));
            try appendOwnedEnv(allocator, entries, try allocator.dupeZ(u8, "MARU_SSH_INTEGRATION=1"));
        }
        // MARU_PANE_ID는 init tail에서 사용자 env override 뒤 최종 upsert한다. 여기서는 부모의 stale 값을
        // 위에서 제거만 해 내부 selector가 정확히 한 번 들어가게 한다.
    }

    fn isPaneSelectorEntry(entry: []const u8) bool {
        // **셋 다 내부 예약 키다.** `MARU_PANE_ID` 는 control-plane self selector이고,
        // `MARU_HOOK_INSTANCE`/`MARU_HOOK_PANE` 은 에이전트 훅 로그 경로의 두 칸이다(docs/agent-hooks.md §4).
        // 부모에게서 상속된 값이 남으면 **다른 인스턴스·다른 pane 의 로그에 쓰게** 되므로 같은 규율로 떨군다.
        return std.mem.startsWith(u8, entry, "MARU_PANE_ID=") or
            std.mem.startsWith(u8, entry, "MARU_HOOK_INSTANCE=") or
            std.mem.startsWith(u8, entry, "MARU_HOOK_PANE=");
    }

    /// 훅 로그 경로의 한 칸으로 써도 안전한가 — **지키는 성질은 «그 값이 로그 디렉터리를 벗어나지
    /// 못한다»** 뿐이다(모양의 단일 출처는 `session.agent_hook_command` 의 TokenClass 다).
    ///
    /// `/` 는 칸을 쪼개고 `.` 는 `..` 로 상위로 올라가며, `=` 는 env 항목 자체를 쪼갠다. 빈 값은 경로를
    /// `//` 로 접어 인스턴스 칸 없이 상위 디렉터리에 쓰게 만든다.
    fn isSafePathSegment(token: []const u8) bool {
        if (token.len == 0) return false;
        for (token) |ch| switch (ch) {
            '/', '.', '=', 0 => return false,
            else => {},
        };
        return true;
    }

    /// 바깥 터미널 멀티플렉서가 자기 pane 안 프로세스에만 세우는 신원 변수인가. maru가 그 안에서 실행됐어도
    /// **maru가 spawn하는 셸은 그 pane이 아니므로** 상속하면 거짓이 된다(위 호출부 주석이 실측 증상의 단일 출처).
    fn isMultiplexerEntry(entry: []const u8) bool {
        return std.mem.startsWith(u8, entry, "TMUX=") or std.mem.startsWith(u8, entry, "TMUX_PANE=");
    }

    // 두 init 경로 모두 owned envp를 만든다(빈 env면 부모 복사 + TERM 덮어쓰기, 명시 env면 그대로).
    // 그래서 항상 owned 메모리를 해제하고 owned envp를 반환한다(예전 uses_parent 분기는 제거됨).
    fn deinit(self: *EnvStorage) void {
        for (self.strings) |entry| self.allocator.free(entry);
        self.allocator.free(self.strings);
        self.allocator.free(self.envp.?);
    }

    fn envpPtr(self: *const EnvStorage) [*:null]const ?[*:0]const u8 {
        return self.envp.?.ptr;
    }
};

fn validateRequest(request: types.SpawnRequest) !void {
    if (request.command.len == 0) return error.EmptyCommand;
    if (request.size.cols == 0 or request.size.rows == 0) return error.InvalidSize;
    for (request.env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=') == null) return error.InvalidEnvironmentEntry;
    }
}

fn childExec(
    command: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[:0]const u8,
    master_fd: std.posix.fd_t,
    slave_fd: std.posix.fd_t,
) noreturn {
    // Child process에서는 Zig error를 부모에게 안전하게 돌려줄 수 없다.
    // 실패 지점별로 보수적인 exit code를 남기고 즉시 종료해 parent가 lifecycle event로 관측하게 한다.
    if (std.c.setsid() < 0) std.c._exit(126);
    if (std.c.ioctl(slave_fd, tio_cs_ctty, @as(c_int, 0)) < 0) std.c._exit(126);
    if (cwd) |dir| {
        // cwd 실패는 setsid/ioctl/dup2와 달리 **복구 가능**하다: 요청한 디렉터리가 사라졌거나(복원/TOCTOU — 검사
        // 후 spawn 사이 삭제) 접근 불가여도 셸을 잃는 것보다 다른 디렉터리에서라도 여는 게 낫다. 죽지 않고(_exit
        // 126 제거) $HOME으로 폴백하고, $HOME도 없거나 실패하면 상속 cwd 그대로 둔다. async-signal-safe만 사용
        // (envp 스캔·chdir, 할당 없음). 이게 cwd 정합성의 단일 권위 — Zig 쪽 usableRestoreCwd는 이른 필터일 뿐이다.
        if (std.c.chdir(dir.ptr) < 0) {
            if (homeFromEnv(envp)) |home| _ = std.c.chdir(home);
        }
    }
    if (std.c.dup2(slave_fd, 0) < 0) std.c._exit(126);
    if (std.c.dup2(slave_fd, 1) < 0) std.c._exit(126);
    if (std.c.dup2(slave_fd, 2) < 0) std.c._exit(126);

    _ = std.c.close(master_fd);
    if (slave_fd > 2) _ = std.c.close(slave_fd);

    _ = std.c.execve(command.ptr, argv, envp);
    std.c._exit(127);
}

/// envp("KEY=VALUE" C 문자열들, null 종단 배열)에서 HOME 값을 찾는다(없으면 null). child의 chdir 폴백용 —
/// async-signal-safe(순수 스캔, 할당·syscall 없음). 반환 포인터는 envp가 가리키는 문자열 내부(복사 없음).
fn homeFromEnv(envp: [*:null]const ?[*:0]const u8) ?[*:0]const u8 {
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (std.mem.startsWith(u8, e, "HOME=") and e.len > "HOME=".len) return entry + "HOME=".len;
    }
    return null;
}

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    if (std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) return error.FcntlFailed;
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    // master fd는 parent runtime만 소유해야 한다. exec된 child에게 새면 EOF/exit 감지가 늦어질 수 있다.
    const flags = std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    if (std.c.fcntl(fd, std.c.F.SETFD, flags | std.c.FD_CLOEXEC) < 0) return error.FcntlFailed;
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        if (rc >= 0) return @intCast(rc);

        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        if (err == .AGAIN) return 0; // non-blocking: 지금은 더 못 쓴다(버퍼 참)
        return error.WriteFailed;
    }
}

// Closing a session whose child is still alive escalates SIGHUP -> SIGTERM ->
// SIGKILL, giving the child a bounded grace window to exit (and run shell close
// traps) at each step before forcing the next. SIGKILL cannot be caught so the
// child is guaranteed to terminate — but the reap is a BOUNDED poll
// (reapBoundedAfterKill), NOT a blocking wait4: it gives up after ~3s rather than
// risk close()/deinit hanging forever (observed wait4(pid, 0) never returning under
// reader-thread reap races; 22-minute hang). On give-up the dead child is left for
// launchd/init to harvest as an orphan — a zombie bounded to process lifetime,
// which is preferred over an unbounded hang (so a zombie CAN briefly remain, only
// until the parent process exits). This is intentionally synchronous in deinit.
const shutdown_grace_attempts = 6;
const shutdown_grace_interval_ms = 10;

// PTY master 에 쌓인 채 안 읽힌 출력을 버린다. 자식을 종료시키는 시점에는 reader 가 이미 멈춰 있어 아무도
// master 를 읽지 않는다. 그 상태에서 출력이 남아 있으면 자식은 — SIGKILL 을 받아도 — exit 의 tty close 에서
// 출력이 빠지길 기다리며 멈추고(ttywait), waitpid 는 계속 0(살아 있음)을 돌려준다. 아래 SIGKILL 뒤 300 회
// 폴링을 다 소진하고 포기하던 원인이 이것이다. 실측(2026-09-06, runtime_manager U2 pause 판정자):
// `sh -c 'while :; do printf x; done'` 의 close 가 4,077ms(포기) → 15ms(SIGHUP 에서 거둠).
// tcflush 는 std.c 에 없어 직접 선언한다. best-effort — 이미 닫힌 fd 면 실패해도 reap 폴링은 그대로 간다.
extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;
const TCIOFLUSH: c_int = 3;
fn discardUnreadMasterOutput(master_fd: std.posix.fd_t) void {
    if (master_fd < 0) return;
    _ = tcflush(master_fd, TCIOFLUSH);
}

fn shutdownChild(pid: std.c.pid_t, master_fd: std.posix.fd_t) void {
    if (pid <= 0) return;

    if (signalAndReap(pid, .HUP, master_fd)) return;
    if (signalAndReap(pid, .TERM, master_fd)) return;

    // Last resort: SIGKILL is uncatchable. 그래도 reap을 무한 blocking wait4로 기다리지 않는다 —
    // 멀티스레드 + reader thread의 reap 경합, PTY 버퍼 상태 등으로 wait4(pid, 0)이 영영 안
    // 돌아오는 경우가 관측됐다(close/deinit이 22분 hang). bounded poll로 바꿔, SIGKILL 후
    // 정해진 창 안에 reap되면 거두고(보통 수 ms), 안 되면 포기한다 — close는 절대 막히지 않는다.
    // 남은 자식은 부모(테스트/앱) 종료 시 launchd/init이 거둔다(고아 reap). reaped 못 해도
    // zombie 누수는 프로세스 수명 한정이라 무한 hang보다 안전하다.
    _ = std.c.kill(-pid, .KILL);
    _ = std.c.kill(pid, .KILL);
    reapBoundedAfterKill(pid, master_fd);
}

// SIGKILL 이후 유계 reap: WNOHANG poll을 짧게 반복하며 최대 shutdown_kill_reap_attempts번
// 기다린다. 무한 blocking wait4 대신 — close/deinit이 어떤 OS 이상에서도 막히지 않게.
const shutdown_kill_reap_attempts = 300; // 300 × 10ms = 최대 3s(보통 1~2회에 거둠)
fn reapBoundedAfterKill(pid: std.c.pid_t, master_fd: std.posix.fd_t) void {
    var attempt: usize = 0;
    while (attempt < shutdown_kill_reap_attempts) : (attempt += 1) {
        discardUnreadMasterOutput(master_fd);
        if (tryReap(pid) != .alive) return; // reaped 또는 이미 gone
        sleepMillis(shutdown_grace_interval_ms);
    }
    // 여기 도달 = SIGKILL 후에도 정해진 창 안에 reap 안 됨(드문 OS 이상). 무한 대기 대신 포기한다.
}

// Sends `sig` to the child's process group (setsid made it a leader) and to the
// child directly, then polls a bounded grace window. Returns true once the child
// has been reaped or is already gone, false if it is still alive after the
// window so the caller can escalate.
fn signalAndReap(pid: std.c.pid_t, sig: std.c.SIG, master_fd: std.posix.fd_t) bool {
    _ = std.c.kill(-pid, sig);
    _ = std.c.kill(pid, sig);

    var attempt: usize = 0;
    while (attempt < shutdown_grace_attempts) : (attempt += 1) {
        discardUnreadMasterOutput(master_fd);
        if (tryReap(pid) != .alive) return true;
        sleepMillis(shutdown_grace_interval_ms);
    }
    discardUnreadMasterOutput(master_fd);
    return tryReap(pid) != .alive;
}

test "close: 바쁜 writer 자식도 1초 안에 거둔다 — 안 읽힌 PTY 출력이 exit 를 막지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var session = try PtySession.spawn(std.testing.allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "while :; do printf x; done" },
        .size = .{ .cols = 20, .rows = 4 },
    });
    defer session.deinit();
    const pid = session.child_pid;
    sleepMillis(100); // 아무도 master 를 읽지 않으니 자식은 곧 PTY 출력 버퍼를 채우고 write 에 막힌다
    const started_ns = std.Io.Clock.real.now(std.testing.io).nanoseconds;
    session.close();
    const elapsed_ms = @divFloor(std.Io.Clock.real.now(std.testing.io).nanoseconds - started_ns, std.time.ns_per_ms);
    // 고치기 전: SIGHUP·SIGTERM 유예창을 지나 SIGKILL 뒤 300 회 폴링까지 다 소진(4 초)하고도 못 거뒀다.
    try std.testing.expect(elapsed_ms < 1000);
    // close 가 실제로 거뒀다: 이미 reap 된 pid 는 waitpid 가 -1(ECHILD)을 돌려준다. 못 거뒀으면 0(아직 살아 있음).
    var status: c_int = 0;
    try std.testing.expectEqual(@as(std.c.pid_t, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
}

const ReapResult = enum { reaped, alive, gone };

fn tryReap(pid: std.c.pid_t) ReapResult {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return .reaped;
        if (rc == 0) return .alive;

        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        // ECHILD (already reaped) or any other error: nothing left to wait on.
        return .gone;
    }
}

fn sleepMillis(ms: u32) void {
    const req: std.c.timespec = .{
        .sec = 0,
        .nsec = @intCast(@as(u64, ms) * std.time.ns_per_ms),
    };
    // Best-effort grace delay; an EINTR just shortens this window, which is fine.
    _ = nanosleep(&req, null);
}

// Non-blocking reap. Returns the decoded status if the child has become a
// zombie, null if it is still running, or an error if there is nothing to wait
// on. The reader uses this so it never blocks indefinitely in waitpid: when the
// child is still alive it waits for the real exit via kqueue instead (see
// waitChildExitOrClosing), which a close() can always interrupt.
fn reapNoHang(pid: std.c.pid_t) !?types.ExitStatus {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return decodeExitStatus(status);
        if (rc == 0) return null;
        const err = std.posix.errno(rc);
        if (err == .INTR) continue;
        return error.WaitPidFailed; // ECHILD 등: 거둘 child가 없다.
    }
}

fn decodeExitStatus(status: c_int) types.ExitStatus {
    // macOS sys/wait.h: _WSTATUS(x) = x & 0x7f selects exit vs signal vs stop.
    const wstatus = status & 0x7f;
    // WIFEXITED: low 7 bits are 0 → normal exit, code in bits 8..15.
    if (wstatus == 0) {
        return .{ .exited = @intCast((status >> 8) & 0xff) };
    }
    // WIFSTOPPED: low 7 bits are 0x7f. waitForChild does not pass WUNTRACED so a
    // stopped child is not expected here; report it as unknown rather than as a
    // bogus terminating signal 0x7f.
    if (wstatus == 0x7f) {
        return .{ .unknown = status };
    }
    // WIFSIGNALED: terminating signal in the low 7 bits.
    return .{ .signaled = @intCast(wstatus) };
}

fn winsizeFromTerminalSize(size: terminal.Size) std.posix.winsize {
    return .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
}

test "prepared inherited PTY adoption discard never signals or reaps the live child" {
    var session = try PtySession.spawn(std.testing.allocator, .{
        .command = "/bin/sleep",
        .args = &.{"5"},
        .size = .{ .cols = 40, .rows = 10 },
    });
    defer session.deinit();
    const source = session.inheritedMasterFd() orelse return error.TestUnexpectedResult;
    var slot: c_int = 200;
    while (slot < 1000 and std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0)) >= 0) : (slot += 1) {}
    if (slot >= 1000 or std.c.dup2(source, slot) < 0) return error.SkipZigTest;
    defer _ = std.c.close(slot);
    const slot_flags = std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0));
    try std.testing.expect(slot_flags >= 0);
    try std.testing.expect(std.c.fcntl(slot, std.c.F.SETFD, slot_flags & ~@as(c_int, std.c.FD_CLOEXEC)) == 0);

    var prepared = try PtySession.PreparedAdoption.prepare(slot, session.childPid(), session.canonicalSize());
    prepared.discard();
    const probe_signal: std.c.SIG = @enumFromInt(0);
    try std.testing.expect(std.c.kill(session.childPid(), probe_signal) == 0);
    try session.writeInput("still-owned");
}

test "prepared inherited PTY adoption rejects a different same-sized PTY master" {
    var expected_session = try PtySession.spawn(std.testing.allocator, .{
        .command = "/bin/sleep",
        .args = &.{"5"},
        .size = .{ .cols = 40, .rows = 10 },
    });
    defer expected_session.deinit();
    var replacement_session = try PtySession.spawn(std.testing.allocator, .{
        .command = "/bin/sleep",
        .args = &.{"5"},
        .size = .{ .cols = 40, .rows = 10 },
    });
    defer replacement_session.deinit();
    const replacement = replacement_session.inheritedMasterFd() orelse return error.TestUnexpectedResult;
    var slot: c_int = 201;
    while (slot < 1000 and std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0)) >= 0) : (slot += 1) {}
    if (slot >= 1000 or std.c.dup2(replacement, slot) < 0) return error.SkipZigTest;
    defer _ = std.c.close(slot);
    const slot_flags = std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0));
    try std.testing.expect(std.c.fcntl(slot, std.c.F.SETFD, slot_flags & ~@as(c_int, std.c.FD_CLOEXEC)) == 0);

    try std.testing.expectError(
        error.InvalidInheritedPty,
        PtySession.PreparedAdoption.prepareExact(
            slot,
            expected_session.childPid(),
            expected_session.canonicalSize(),
            try expected_session.masterIdentity(),
        ),
    );
}

test "prepared inherited PTY adoption rejects a zombie without consuming its exit status" {
    var session = try PtySession.spawn(std.testing.allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "exit 7" },
        .size = .{ .cols = 40, .rows = 10 },
    });
    defer session.deinit();

    var attempts: usize = 0;
    while (attempts < 2000 and !(try session.childExitedWithoutReap())) : (attempts += 1)
        sleepMillis(1);
    try std.testing.expect(try session.childExitedWithoutReap());

    const source = session.inheritedMasterFd() orelse return error.TestUnexpectedResult;
    var slot: c_int = 202;
    while (slot < 1000 and std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0)) >= 0) : (slot += 1) {}
    if (slot >= 1000 or std.c.dup2(source, slot) < 0) return error.SkipZigTest;
    defer _ = std.c.close(slot);
    const slot_flags = std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0));
    try std.testing.expect(std.c.fcntl(slot, std.c.F.SETFD, slot_flags & ~@as(c_int, std.c.FD_CLOEXEC)) == 0);

    try std.testing.expectError(
        error.InvalidInheritedPty,
        PtySession.PreparedAdoption.prepareExact(
            slot,
            session.childPid(),
            session.canonicalSize(),
            try session.masterIdentity(),
        ),
    );
    try std.testing.expectEqual(types.ExitStatus{ .exited = 7 }, (try session.reapIfExited()).?);
}

test "prepared inherited PTY adoption rechecks child liveness at commit without consuming status" {
    var session = try PtySession.spawn(std.testing.allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "sleep 0.05; exit 9" },
        .size = .{ .cols = 40, .rows = 10 },
    });
    defer session.deinit();

    const source = session.inheritedMasterFd() orelse return error.TestUnexpectedResult;
    var slot: c_int = 203;
    while (slot < 1000 and std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0)) >= 0) : (slot += 1) {}
    if (slot >= 1000 or std.c.dup2(source, slot) < 0) return error.SkipZigTest;
    defer _ = std.c.close(slot);
    const slot_flags = std.c.fcntl(slot, std.c.F.GETFD, @as(c_int, 0));
    try std.testing.expect(std.c.fcntl(slot, std.c.F.SETFD, slot_flags & ~@as(c_int, std.c.FD_CLOEXEC)) == 0);

    var prepared = try PtySession.PreparedAdoption.prepareExact(
        slot,
        session.childPid(),
        session.canonicalSize(),
        try session.masterIdentity(),
    );
    defer prepared.discard();

    var attempts: usize = 0;
    while (attempts < 2000 and !(try session.childExitedWithoutReap())) : (attempts += 1)
        sleepMillis(1);
    try std.testing.expect(try session.childExitedWithoutReap());
    try std.testing.expectError(error.InvalidInheritedPty, prepared.revalidate());
    try std.testing.expectEqual(types.ExitStatus{ .exited = 9 }, (try session.reapIfExited()).?);
}

test "decodeExitStatus reports normal exit code" {
    try std.testing.expectEqual(types.ExitStatus{ .exited = 7 }, decodeExitStatus(7 << 8));
}

test "decodeExitStatus reports a terminating signal" {
    // Killed by SIGKILL(9): low 7 bits hold the signal, with or without the
    // 0x80 core-dump flag.
    try std.testing.expectEqual(types.ExitStatus{ .signaled = 9 }, decodeExitStatus(9));
    try std.testing.expectEqual(types.ExitStatus{ .signaled = 9 }, decodeExitStatus(0x80 | 9));
}

test "decodeExitStatus reports a stopped child as unknown" {
    // WIFSTOPPED status (low 7 bits == 0x7f) must not be mistaken for signal 0x7f.
    try std.testing.expectEqual(types.ExitStatus{ .unknown = 0x137f }, decodeExitStatus(0x137f));
}

// 이 테스트가 증명하는 것: 비차단 reap 프리미티브 reapIfExited가 (A) 살아있는 자식엔 즉시 null을, (B) 이미
// 종료한 자식엔 실제 종료 상태를 돌려준다는 것. 왜 터미널에 중요한가: reader가 read/write/poll I/O 오류를 만났을
// 때 "자식이 정말 죽었는지"를 이 프리미티브로 검증해, 살아있으면 read_error(탭 유지)·죽었으면 exited(정상 닫기)로
// 분기한다. 이 검증이 없으면 Ctrl+C가 유발한 일시적 I/O 오류가 미검증 종료로 처리돼 산 셸을 죽이고 좌측 워크스페이스
// 탭을 통째로 닫는다(사용자 보고 버그의 루트커즈). 실 PTY spawn이 필요하므로 macOS 백엔드에서만 컴파일된다.
test "reapIfExited: 살아있는 자식엔 null, 종료한 자식엔 상태를 비차단으로 (read_error 무검증 종료 방지의 검증 프리미티브)" {
    const allocator = std.testing.allocator;

    // (A) 살아있는 자식(sleep): 비차단이라 kqueue 대기 없이 즉시 null. reaping 가드는 반납돼 다음 검증이 재시도 가능.
    var alive = try PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "sleep 30" },
        .size = .{ .cols = 20, .rows = 3 },
    });
    try std.testing.expect((try alive.reapIfExited()) == null);
    try std.testing.expect((try alive.reapIfExited()) == null); // 가드 반납 확인 — 반복 호출도 null
    alive.deinit(); // sleep을 shutdownChild(SIGHUP→TERM→KILL)로 정리

    // (B) 이미 종료한 자식(exit 7): 실제 종료 상태를 돌려준다 → reader가 .exited로 승격해 정상 닫힘 경로를 탄다.
    // 종료 관측까지 비차단으로 bounded 폴링(자식이 방금 fork돼 아직 안 죽었을 수 있으므로).
    var dead = try PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "exit 7" },
        .size = .{ .cols = 20, .rows = 3 },
    });
    var status: ?types.ExitStatus = null;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        status = try dead.reapIfExited();
        if (status != null) break;
        sleepMillis(1); // 자식이 방금 fork돼 아직 안 죽었을 수 있으니 잠깐 양보 후 재폴링

    }
    try std.testing.expectEqual(types.ExitStatus{ .exited = 7 }, status.?);
    dead.deinit(); // exited=true라 close는 shutdownChild를 건너뛴다(double-reap 없음)
}

// 제품과 같은 login wrapper 아래 실제 child를 띄워, foreground PGID를 PID로 가정하지 않고 현재 구성원을
// 돌려주는지 검증한다. login leader가 exec/exit해 PGID와 같은 PID가 사라져도 group은 child가 있는 동안 유효하다.
test "foregroundProcessNames: login group leader가 사라져도 같은 foreground group의 child를 열거한다" {
    const allocator = std.testing.allocator;
    var session = try PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "sleep 1" },
        .login = true,
        .size = .{ .cols = 20, .rows = 3 },
    });
    defer session.deinit();

    var names: [16]types.ForegroundProcessName = undefined;
    var count: usize = 0;
    var saw_group_child = false;
    var attempt: usize = 0;
    while (attempt < 2000) : (attempt += 1) {
        count = session.foregroundProcessNames(&names);
        const pgid = session.foregroundProcessGroup() orelse 0;
        for (names[0..count]) |*name| {
            if (name.pid != pgid and std.mem.eql(u8, name.slice(), "sleep")) saw_group_child = true;
        }
        if (saw_group_child) break;
        sleepMillis(1); // login이 command child를 fork/exec할 시간을 bounded하게 기다린다.
    }

    try std.testing.expect(count >= 1);
    try std.testing.expect(saw_group_child);
}

// **제품 spawn 경로(login wrapper)에서 cwd를 맞게 집는가.** 위 `foregroundProcessNames` 테스트가 증명하듯
// login 아래에서는 실제 명령이 **PGID와 다른 PID**로 돈다. foreground PGID를 그대로 pid로 써서 조회하면
// login wrapper 자신의 cwd(홈 등)를 읽어, "터미널이 서 있는 폴더"가 통째로 틀린다 — 그러면 소스 컨트롤 뷰가
// 남의 저장소를 보여 준다. 자식이 실제로 `cd`한 자리를 돌려주는지 고정한다.
test "processCwd: login wrapper 아래에서도 PGID가 아니라 실제 child의 cwd를 집는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // `/` 는 어떤 테스트 실행 위치와도 다르므로, wrapper의 cwd를 읽었는지 자식의 cwd를 읽었는지 구분된다.
    var session = try PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "cd / && sleep 2" },
        .login = true,
        .size = .{ .cols = 20, .rows = 3 },
    });
    defer session.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var attempt: usize = 0;
    var got: ?[]const u8 = null;
    while (attempt < 2000) : (attempt += 1) {
        if (session.processCwd(&buf)) |cwd| {
            if (std.mem.eql(u8, cwd, "/")) {
                got = cwd;
                break;
            }
        }
        sleepMillis(1); // login이 command child를 fork/exec하고 cd할 시간을 bounded하게 기다린다.
    }
    try std.testing.expect(got != null);
}

// **`cd` 하면 따라오는가.** 사용자가 다른 저장소로 옮기는 가장 흔한 방법이 `cd`인데, cwd를 spawn 시점에 한 번만
// 읽고 캐시하면 영영 안 따라온다. 살아 있는 셸에 실제로 `cd`를 쳐 넣어 값이 **바뀌는지**를 본다 — 한 번 읽어
// 맞는 것과 변화를 추적하는 것은 다르다(GUI 없이 검증할 수 있는 가장 깊은 지점).
test "processCwd: 살아 있는 셸이 cd하면 그 자리를 따라간다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var session = try PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .size = .{ .cols = 20, .rows = 3 },
    });
    defer session.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 먼저 시작 cwd(= 테스트 프로세스의 cwd)가 보이는지 확인한다. 이게 `/`가 아니어야 아래 단언이 의미를 갖는다.
    var attempt: usize = 0;
    var saw_start = false;
    while (attempt < 2000) : (attempt += 1) {
        if (session.processCwd(&buf)) |cwd| {
            if (!std.mem.eql(u8, cwd, "/")) {
                saw_start = true;
                break;
            }
        }
        sleepMillis(1);
    }
    if (!saw_start) return error.SkipZigTest; // 저장소가 `/`에 있는 비정상 환경

    try session.writeInput("cd /\n");
    attempt = 0;
    var followed = false;
    while (attempt < 2000) : (attempt += 1) {
        if (session.processCwd(&buf)) |cwd| {
            if (std.mem.eql(u8, cwd, "/")) {
                followed = true;
                break;
            }
        }
        sleepMillis(1);
    }
    try std.testing.expect(followed);
}

// 실제 Darwin proc_listchildpids + KERN_PROCARGS2 경로를 고정한다. 순수 parseEnvValue 테스트만으로는
// sandbox/PTY 아래에서 자식 환경을 읽지 못하는 회귀를 잡지 못하므로, parent shell이 살아 있는 동안
// provider-native env를 가진 도구 자식을 띄운다.
test "validateRequest rejects requests that cannot produce a reliable PTY" {
    // Invalid spawn input should fail before openpty/fork so tests and users do
    // not get half-created child processes with confusing lifecycle artifacts.
    try std.testing.expectError(
        error.EmptyCommand,
        validateRequest(.{ .command = "" }),
    );
    try std.testing.expectError(
        error.InvalidSize,
        validateRequest(.{ .command = "/bin/sh", .size = .{ .cols = 0, .rows = 24 } }),
    );
    try std.testing.expectError(
        error.InvalidEnvironmentEntry,
        validateRequest(.{ .command = "/bin/sh", .env = &.{"NOT_AN_ENV_PAIR"} }),
    );
}

test "EnvStorage empty env inherits the parent but forces TERM/COLORTERM to Maru's values" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
    defer storage.deinit();

    var term_count: usize = 0;
    var colorterm_count: usize = 0;
    var maru_term = false;
    var maru_colorterm = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const slice = std.mem.span(entry);
        if (std.mem.startsWith(u8, slice, "TERM=")) {
            term_count += 1;
            maru_term = std.mem.eql(u8, slice, "TERM=xterm-256color");
        }
        if (std.mem.startsWith(u8, slice, "COLORTERM=")) {
            colorterm_count += 1;
            maru_colorterm = std.mem.eql(u8, slice, "COLORTERM=truecolor");
        }
    }
    // 부모 TERM/COLORTERM은 제거되고 Maru 값이 정확히 하나씩 있어야 한다(중복 키는 첫 항목이
    // 이기므로 부모 것이 남으면 override가 안 먹는다).
    try std.testing.expectEqual(@as(usize, 1), term_count);
    try std.testing.expectEqual(@as(usize, 1), colorterm_count);
    try std.testing.expect(maru_term);
    try std.testing.expect(maru_colorterm);
    try std.testing.expect(i >= 2); // 부모 env도 물려받았다(최소 PATH 등)
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "EnvStorage forces TERM_PROGRAM to ghostty (알림 식별 — 부모 값 덮어씀, VERSION strip)" {
    // Claude Code/Codex가 TERM_PROGRAM 화이트리스트로 알림 터미널을 식별하므로 maru를 ghostty로 알린다.
    // 부모(상위 터미널/런처)가 남긴 TERM_PROGRAM·VERSION은 제거되고 ghostty 하나만 남아야 한다(중복 키는 첫 항목이 이김).
    _ = setenv("TERM_PROGRAM", "Apple_Terminal", 1);
    _ = setenv("TERM_PROGRAM_VERSION", "447", 1);
    defer _ = unsetenv("TERM_PROGRAM");
    defer _ = unsetenv("TERM_PROGRAM_VERSION");

    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
    defer storage.deinit();

    var tp_count: usize = 0;
    var tpv_count: usize = 0;
    var is_ghostty = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const slice = std.mem.span(entry);
        if (std.mem.startsWith(u8, slice, "TERM_PROGRAM=")) {
            tp_count += 1;
            is_ghostty = std.mem.eql(u8, slice, "TERM_PROGRAM=ghostty");
        }
        if (std.mem.startsWith(u8, slice, "TERM_PROGRAM_VERSION=")) tpv_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), tp_count); // 부모 Apple_Terminal 제거 + ghostty 하나만
    try std.testing.expect(is_ghostty);
    try std.testing.expectEqual(@as(usize, 0), tpv_count); // 부모 VERSION은 strip하고 주입 안 함
}

test "EnvStorage strips launcher color-force overrides (CLICOLOR_FORCE/FORCE_COLOR)" {
    // 런처(빌드 도구·CI·부모 셸)가 남긴 색-강제 override는 supports-color류(codex 등)가 env_force_color로
    // 먼저 평가해 색 레벨을 강제(흔히 basic 16색)하므로 COLORTERM=truecolor를 무시한다 → truecolor 꺼짐
    // (실측: `zig build`로 띄운 maru에서 상속된 CLICOLOR_FORCE=1 때문에 codex 입력창 회색 컴포저가 안 그려짐).
    // maru는 색 capability를 COLORTERM/TERM으로만 알리므로 이 force 변수를 자식 env에 넘기지 않는다.
    _ = setenv("CLICOLOR_FORCE", "1", 1);
    _ = setenv("FORCE_COLOR", "1", 1);
    defer {
        _ = unsetenv("CLICOLOR_FORCE");
        _ = unsetenv("FORCE_COLOR");
    }
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
    defer storage.deinit();
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const slice = std.mem.span(entry);
        try std.testing.expect(!std.mem.startsWith(u8, slice, "CLICOLOR_FORCE="));
        try std.testing.expect(!std.mem.startsWith(u8, slice, "FORCE_COLOR="));
    }
    try std.testing.expect(i >= 2); // 나머지 부모 env는 그대로 물려받았다
}

test "EnvStorage strips the outer multiplexer identity (TMUX/TMUX_PANE)" {
    // maru를 tmux 팬 안에서 띄우면(`zig build run`·터미널에서 직접 실행) 그 신원이 자식 셸까지 흘러
    // "나는 tmux 안"이라는 거짓이 된다 — maru가 spawn한 셸은 그 pane이 아니다. 실측 증상: 셸 통합/프롬프트가
    // OSC를 DCS passthrough(`\ePtmux;…`)로 감싸 내보내 바깥 maru가 못 풀고, cwd 보고(OSC 7)가 통째로 유실돼
    // 사이드바의 경로·git 브랜치 줄이 사라졌다. `MARU_PANE_ID`와 같은 부류의 상속 오염이라 같이 떨군다.
    _ = setenv("TMUX", "/private/tmp/tmux-501/default,1591,2", 1);
    _ = setenv("TMUX_PANE", "%2", 1);
    defer {
        _ = unsetenv("TMUX");
        _ = unsetenv("TMUX_PANE");
    }
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
    defer storage.deinit();
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const slice = std.mem.span(entry);
        try std.testing.expect(!std.mem.startsWith(u8, slice, "TMUX="));
        try std.testing.expect(!std.mem.startsWith(u8, slice, "TMUX_PANE="));
    }
    try std.testing.expect(i >= 2); // 나머지 부모 env는 그대로 물려받았다

    // **명시 env는 그대로 통과한다** — 호출자가 준 env는 상속 오염이 아니라 의도된 값이다(기존 계약 보존).
    var explicit = try EnvStorage.init(std.testing.allocator, &.{"TMUX=explicit"}, &.{}, "xterm-256color", null, null, null, null);
    defer explicit.deinit();
    try std.testing.expectEqualStrings("TMUX=explicit", std.mem.span(explicit.envpPtr()[0].?));
}

test "EnvStorage explicit env is passed through verbatim (term arg ignored)" {
    // 명시 env면 term 인자는 무시된다(테스트가 완전한 env를 직접 준다).
    var storage = try EnvStorage.init(std.testing.allocator, &.{ "FOO=bar", "TERM=dumb" }, &.{}, "xterm-ghostty", null, null, null, null);
    defer storage.deinit();
    const envp = storage.envpPtr();
    try std.testing.expectEqualStrings("FOO=bar", std.mem.span(envp[0].?));
    try std.testing.expectEqualStrings("TERM=dumb", std.mem.span(envp[1].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), envp[2]);
}

// env.<KEY> 주입(config) — 부모 상속 위에 upsert. 같은 KEY는 덮어쓰고 없으면 추가("부모 + 사용자" 정책).
fn envValueCount(storage: *const EnvStorage, key_prefix: []const u8) struct { count: usize, last: ?[]const u8 } {
    var count: usize = 0;
    var last: ?[]const u8 = null;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const slice = std.mem.span(entry);
        if (std.mem.startsWith(u8, slice, key_prefix)) {
            count += 1;
            last = slice[key_prefix.len..];
        }
    }
    return .{ .count = count, .last = last };
}

test "EnvStorage parent snapshot preserves caller environment while applying Maru overrides" {
    var storage = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{},
        &.{ "MARU_TEST_GUI_ENV=fresh", "MARU_PANE_ID=7", "TERM=stale", "FORCE_COLOR=1" },
        &.{},
        "xterm-256color",
        null,
        null,
        null,
        null,
        null,
    );
    defer storage.deinit();
    try std.testing.expectEqualStrings("fresh", envValueCount(&storage, "MARU_TEST_GUI_ENV=").last.?);
    try std.testing.expectEqualStrings("xterm-256color", envValueCount(&storage, "TERM=").last.?);
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&storage, "FORCE_COLOR=").count);
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&storage, "MARU_PANE_ID=").count);
}

test "EnvStorage treats MARU_PANE_ID as reserved in explicit env and overrides" {
    var omitted = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{ "KEEP=1", "MARU_PANE_ID=7" },
        null,
        &.{"MARU_PANE_ID=8"},
        "ignored",
        null,
        null,
        null,
        null,
        null,
    );
    defer omitted.deinit();
    try std.testing.expectEqualStrings("1", envValueCount(&omitted, "KEEP=").last.?);
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&omitted, "MARU_PANE_ID=").count);

    var injected = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{"MARU_PANE_ID=7"},
        null,
        &.{"MARU_PANE_ID=8"},
        "ignored",
        null,
        null,
        42,
        null,
        null,
    );
    defer injected.deinit();
    try std.testing.expectEqual(@as(usize, 1), envValueCount(&injected, "MARU_PANE_ID=").count);
    try std.testing.expectEqualStrings("42", envValueCount(&injected, "MARU_PANE_ID=").last.?);
}

test "EnvStorage treats MARU_HOOK_INSTANCE as reserved — 상속·override 로 남의 인스턴스에 못 쓴다" {
    // 훅 로그 경로의 인스턴스 칸이다(docs/agent-hooks.md §4). 부모에게서 상속되거나 사용자 override 로
    // 들어오면 **다른 maru 인스턴스의 디렉터리에 쓰게** 되므로 `MARU_PANE_ID` 와 같은 규율로 다룬다.
    var omitted = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{ "KEEP=1", "MARU_HOOK_INSTANCE=111" },
        null,
        &.{"MARU_HOOK_INSTANCE=222"},
        "ignored",
        null,
        null,
        null,
        null,
        null,
    );
    defer omitted.deinit();
    try std.testing.expectEqualStrings("1", envValueCount(&omitted, "KEEP=").last.?);
    // null 이면 **아무 값도 남지 않는다** — fail-closed(훅이 조용히 나간다).
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&omitted, "MARU_HOOK_INSTANCE=").count);

    var injected = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{"MARU_HOOK_INSTANCE=111"},
        null,
        &.{"MARU_HOOK_INSTANCE=222"},
        "ignored",
        null,
        null,
        null,
        "4242",
        null,
    );
    defer injected.deinit();
    const inst = envValueCount(&injected, "MARU_HOOK_INSTANCE=");
    try std.testing.expectEqual(@as(usize, 1), inst.count); // 중복 없이 한 번
    try std.testing.expectEqualStrings("4242", inst.last.?); // 우리 값이 이긴다
}

test "EnvStorage 는 MARU_HOOK_PANE 도 예약 키로 다룬다 — 남의 pane 로그에 못 쓴다" {
    // 훅 로그 경로의 pane 칸이다(docs/agent-hooks.md §4). `MARU_PANE_ID`(control-plane selector)와 **갈라진**
    // 변수지만 규율은 같다 — 상속·override 로 들어온 값이 남으면 자식이 **남의 pane 파일에** append 한다.
    var omitted = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{ "KEEP=1", "MARU_HOOK_PANE=111" },
        &.{"MARU_HOOK_PANE=222"},
        &.{"MARU_HOOK_PANE=333"},
        "ignored",
        null,
        null,
        null,
        null,
        null,
    );
    defer omitted.deinit();
    try std.testing.expectEqualStrings("1", envValueCount(&omitted, "KEEP=").last.?);
    // null 이면 아무 값도 남지 않는다 — fail-closed(훅이 조용히 나간다).
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&omitted, "MARU_HOOK_PANE=").count);

    var injected = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{"MARU_HOOK_PANE=111"},
        &.{"MARU_HOOK_PANE=222"},
        &.{"MARU_HOOK_PANE=333"},
        "ignored",
        null,
        null,
        null,
        "host_0000000000000000000000000000000a",
        "0000000000000000000000000000002a",
    );
    defer injected.deinit();
    const pane = envValueCount(&injected, "MARU_HOOK_PANE=");
    try std.testing.expectEqual(@as(usize, 1), pane.count); // 중복 없이 한 번
    try std.testing.expectEqualStrings("0000000000000000000000000000002a", pane.last.?);
    // host 소유 인스턴스 칸도 그대로 실린다 — 이 층은 모양을 다시 만들지 않고 받은 토큰을 쓴다.
    const inst = envValueCount(&injected, "MARU_HOOK_INSTANCE=");
    try std.testing.expectEqual(@as(usize, 1), inst.count);
    try std.testing.expectEqualStrings("host_0000000000000000000000000000000a", inst.last.?);
}

test "경로를 벗어나는 훅 토큰은 주입하지 않는다 — 이 층이 실제로 파일이 생기는 자리다" {
    // 모양의 단일 출처는 계약 모듈(`session.agent_hook_command`)이지만, **파일이 실제로 만들어지는 것은**
    // 이 env 를 받은 훅이다. 그래서 여기서는 모양 전체가 아니라 «로그 디렉터리를 벗어나지 못한다» 는
    // 성질만 다시 지킨다. 실측(2026-08-20): 검증이 없을 때 `../outside/pwned` 가 밖에 파일을 만들었다.
    for ([_][]const u8{ "..", "../outside/pwned", "a/b", "a.b", "", "a=b" }) |bad| {
        var storage = try EnvStorage.initWithParentSnapshot(
            std.testing.allocator,
            &.{},
            null,
            &.{},
            "ignored",
            null,
            null,
            null,
            bad,
            bad,
        );
        defer storage.deinit();
        try std.testing.expectEqual(@as(usize, 0), envValueCount(&storage, "MARU_HOOK_INSTANCE=").count);
        try std.testing.expectEqual(@as(usize, 0), envValueCount(&storage, "MARU_HOOK_PANE=").count);
    }
    // 나쁜 칸 하나가 좋은 칸을 끌어내리지 않는다 — 그러면 훅은 경로를 다 못 만들어 조용히 나간다(fail-closed).
    var partial = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{},
        null,
        &.{},
        "ignored",
        null,
        null,
        null,
        "4242",
        "../pwned",
    );
    defer partial.deinit();
    try std.testing.expectEqualStrings("4242", envValueCount(&partial, "MARU_HOOK_INSTANCE=").last.?);
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&partial, "MARU_HOOK_PANE=").count);
}

test "부모의 MARU_HOOK_INSTANCE 는 상속 경로에서도 떨어진다" {
    // maru 안에서 maru 를 띄우는 경우(중첩) 부모 값이 살아 있으면 자식이 **부모 인스턴스의** 로그에 쓴다.
    var storage = try EnvStorage.initWithParentSnapshot(
        std.testing.allocator,
        &.{},
        &.{ "MARU_HOOK_INSTANCE=999", "KEEP=1" },
        &.{},
        "xterm-256color",
        null,
        null,
        null,
        null,
        null,
    );
    defer storage.deinit();
    try std.testing.expectEqualStrings("1", envValueCount(&storage, "KEEP=").last.?);
    try std.testing.expectEqual(@as(usize, 0), envValueCount(&storage, "MARU_HOOK_INSTANCE=").count);
}

test "EnvStorage env_overrides: 새 KEY는 추가, 기존 KEY(maru TERM)는 덮어쓴다 (부모 상속 위 upsert)" {
    // 부모 상속 경로(env=&.{}) + 사용자 override. FOO는 새 키라 추가, TERM은 maru가 먼저 넣은 값을 사용자가 덮어쓴다.
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{ "FOO=bar", "TERM=screen-256color" }, "xterm-256color", null, null, null, null);
    defer storage.deinit();

    const foo = envValueCount(&storage, "FOO=");
    try std.testing.expectEqual(@as(usize, 1), foo.count); // 새 키 한 번
    try std.testing.expectEqualStrings("bar", foo.last.?);

    const term = envValueCount(&storage, "TERM=");
    try std.testing.expectEqual(@as(usize, 1), term.count); // 중복 없이 한 번(override가 maru 값을 교체)
    try std.testing.expectEqualStrings("screen-256color", term.last.?); // 사용자 값이 이김
}

test "EnvStorage env_overrides: 명시 env 위에도 upsert (KEY 덮어쓰기·추가, 중복 없음)" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{ "A=1", "B=2" }, &.{ "B=3", "C=4" }, "xterm-ghostty", null, null, null, null);
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 1), envValueCount(&storage, "A=").count);
    try std.testing.expectEqualStrings("1", envValueCount(&storage, "A=").last.?);
    const b = envValueCount(&storage, "B=");
    try std.testing.expectEqual(@as(usize, 1), b.count); // 덮어써 한 번만
    try std.testing.expectEqualStrings("3", b.last.?);
    try std.testing.expectEqualStrings("4", envValueCount(&storage, "C=").last.?); // 새 키 추가
}

test "ArgvStorage uses the command path as argv[0] and appends args" {
    var storage = try ArgvStorage.init(std.testing.allocator, "/bin/zsh", &.{"-i"});
    defer storage.deinit();
    try std.testing.expectEqualStrings("/bin/zsh", std.mem.span(storage.argv[0].?));
    try std.testing.expectEqualStrings("-i", std.mem.span(storage.argv[1].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), storage.argv[2]);
}

test "MacosLogin wraps the shell in login(1) -flp <user> bash exec -l" {
    var lw = try MacosLogin.build(std.testing.allocator, .{ .command = "/bin/zsh", .args = &.{"-i"}, .login = true });
    defer lw.deinit(std.testing.allocator);
    // -q(hushlogin)는 환경 의존이라 빼고, 핵심 구조를 확인한다.
    var saw_flp = false;
    var saw_bash = false;
    var saw_exec = false;
    for (lw.args) |a| {
        if (std.mem.eql(u8, a, "-flp")) saw_flp = true;
        if (std.mem.eql(u8, a, "/bin/bash")) saw_bash = true;
        if (std.mem.eql(u8, a, "exec -l '/bin/zsh' '-i'")) saw_exec = true; // command·args는 작은따옴표로 감싼다
    }
    try std.testing.expect(saw_flp);
    try std.testing.expect(saw_bash);
    try std.testing.expect(saw_exec); // 최종 셸을 login shell로 교체하는 exec 명령
}

test "MacosLogin.build: 셸 경로·인자를 작은따옴표로 감싸 공백·따옴표 word-split 방지" {
    // 공백 있는 셸 경로 + 인자에 작은따옴표 포함 → exec_cmd(owned[0])가 각 토큰을 '…'로 감싸고 내부 '는 '\''로 끊는다.
    var lw = try MacosLogin.build(std.testing.allocator, .{
        .command = "/Applications/My Shell/bin/sh",
        .args = &.{ "-i", "a'b" },
        .login = true,
        .size = .{ .cols = 80, .rows = 24 },
    });
    defer lw.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("exec -l '/Applications/My Shell/bin/sh' '-i' 'a'\\''b'", lw.owned[0]);
}

test "EnvStorage empty env uses the supplied TERM (configurable)" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-ghostty", null, null, null, null);
    defer storage.deinit();
    var found = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(entry), "TERM=xterm-ghostty")) found = true;
    }
    try std.testing.expect(found); // config term이 셸 env에 반영된다
}

test "EnvStorage injects ZDOTDIR for shell integration and preserves the old one" {
    var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", "/cache/maru/zsh", null, null, null);
    defer storage.deinit();
    var saw_zdotdir = false;
    const envp = storage.envpPtr();
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(entry), "ZDOTDIR=/cache/maru/zsh")) saw_zdotdir = true;
    }
    try std.testing.expect(saw_zdotdir); // 통합 디렉터리가 ZDOTDIR로 주입됨
}

test "EnvStorage injects MARU_BIN + MARU_SSH_INTEGRATION only when ssh routing is opt-in" {
    // opt-in on: 통합 .zshenv가 ssh를 maru ssh로 라우팅하도록 두 키를 모두 주입한다(바이너리 경로 +
    // 게이트 플래그). 둘 중 하나라도 빠지면 .zshenv가 함수를 정의하지 않아 라우팅이 조용히 안 된다.
    {
        var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, "/Applications/Maru.app/Contents/MacOS/maru", null, null);
        defer storage.deinit();
        var saw_bin = false;
        var saw_flag = false;
        const envp = storage.envpPtr();
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const s = std.mem.span(entry);
            if (std.mem.eql(u8, s, "MARU_BIN=/Applications/Maru.app/Contents/MacOS/maru")) saw_bin = true;
            if (std.mem.eql(u8, s, "MARU_SSH_INTEGRATION=1")) saw_flag = true;
        }
        try std.testing.expect(saw_bin);
        try std.testing.expect(saw_flag);
    }
    // opt-in off(기본): 두 키 모두 없어야 한다 — 평범한 ssh가 그대로 동작(graceful).
    {
        var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
        defer storage.deinit();
        const envp = storage.envpPtr();
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const s = std.mem.span(entry);
            try std.testing.expect(!std.mem.startsWith(u8, s, "MARU_BIN="));
            try std.testing.expect(!std.mem.startsWith(u8, s, "MARU_SSH_INTEGRATION="));
        }
    }
}

test "EnvStorage keeps MARU_PANE_ID as the surface selector" {
    {
        var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, 42, null);
        defer storage.deinit();
        var saw_pane = false;
        const envp = storage.envpPtr();
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const value = std.mem.span(entry);
            if (std.mem.eql(u8, value, "MARU_PANE_ID=42")) saw_pane = true;
        }
        try std.testing.expect(saw_pane);
    }
    // 사용자 env override나 명시 env가 내부 selector를 위조해도 spawn request의 Term identity가 마지막에 이긴다.
    {
        var storage = try EnvStorage.init(
            std.testing.allocator,
            &.{"MARU_PANE_ID=7"},
            &.{"MARU_PANE_ID=1"},
            "xterm-256color",
            null,
            null,
            42,
            null,
        );
        defer storage.deinit();
        var pane_count: usize = 0;
        const envp = storage.envpPtr();
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const value = std.mem.span(entry);
            if (std.mem.startsWith(u8, value, "MARU_PANE_ID=")) {
                pane_count += 1;
                try std.testing.expectEqualStrings("MARU_PANE_ID=42", value);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), pane_count);
    }
    // selector가 null이면 관련 env가 없다.
    {
        var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
        defer storage.deinit();
        const envp = storage.envpPtr();
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            try std.testing.expect(!std.mem.startsWith(u8, std.mem.span(entry), "MARU_PANE_ID="));
        }
    }
}

test "EnvStorage treats MARU_AGENT_MAPPING_ID as an ordinary environment key" {
    const old_value: ?[:0]u8 = if (std.c.getenv("MARU_AGENT_MAPPING_ID")) |raw|
        try std.testing.allocator.dupeZ(u8, std.mem.span(raw))
    else
        null;
    defer if (old_value) |value| {
        _ = setenv("MARU_AGENT_MAPPING_ID", value.ptr, 1);
        std.testing.allocator.free(value);
    } else {
        _ = unsetenv("MARU_AGENT_MAPPING_ID");
    };
    _ = setenv("MARU_AGENT_MAPPING_ID", "parent-value", 1);

    // 부모 base만 선택하면 일반 키처럼 그대로 상속된다.
    {
        var storage = try EnvStorage.init(std.testing.allocator, &.{}, &.{}, "xterm-256color", null, null, null, null);
        defer storage.deinit();
        const got = envValueCount(&storage, "MARU_AGENT_MAPPING_ID=");
        try std.testing.expectEqual(@as(usize, 1), got.count);
        try std.testing.expectEqualStrings("parent-value", got.last.?);
    }
    // 부모 base 뒤 env.* upsert가 마지막 값을 갖는다.
    {
        var storage = try EnvStorage.init(
            std.testing.allocator,
            &.{},
            &.{"MARU_AGENT_MAPPING_ID=override-value"},
            "xterm-256color",
            null,
            null,
            null,
            null,
        );
        defer storage.deinit();
        const got = envValueCount(&storage, "MARU_AGENT_MAPPING_ID=");
        try std.testing.expectEqual(@as(usize, 1), got.count);
        try std.testing.expectEqualStrings("override-value", got.last.?);
    }
    // explicit base는 부모와 합치지 않고 명시된 값을 그대로 쓴다.
    {
        var storage = try EnvStorage.init(
            std.testing.allocator,
            &.{ "MARU_AGENT_MAPPING_ID=explicit-value", "MARU_AGENT_MAPPING_IDX=keep" },
            &.{},
            "xterm-256color",
            null,
            null,
            null,
            null,
        );
        defer storage.deinit();
        const got = envValueCount(&storage, "MARU_AGENT_MAPPING_ID=");
        try std.testing.expectEqual(@as(usize, 1), got.count);
        try std.testing.expectEqualStrings("explicit-value", got.last.?);
        try std.testing.expectEqualStrings("keep", envValueCount(&storage, "MARU_AGENT_MAPPING_IDX=").last.?);
    }
    // explicit base에서도 같은 upsert 규칙을 쓴다.
    {
        var storage = try EnvStorage.init(
            std.testing.allocator,
            &.{ "FOO=ok", "MARU_AGENT_MAPPING_ID=explicit-value" },
            &.{"MARU_AGENT_MAPPING_ID=override-value"},
            "xterm-256color",
            null,
            null,
            null,
            null,
        );
        defer storage.deinit();
        const got = envValueCount(&storage, "MARU_AGENT_MAPPING_ID=");
        try std.testing.expectEqual(@as(usize, 1), got.count);
        try std.testing.expectEqualStrings("override-value", got.last.?);
        try std.testing.expectEqualStrings("ok", envValueCount(&storage, "FOO=").last.?);
    }
}
