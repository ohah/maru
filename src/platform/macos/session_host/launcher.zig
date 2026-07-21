//! detached-helper launcher — 앱이 `maru __session-host <socket>`를 부모와 독립된 프로세스로 띄운다(§10, §15
//! host launch = detached helper) — P3-d2d.
//!
//! GUI가 첫 persistent runtime을 필요로 할 때(discovery가 `spawn_host`로 판정, P3-d2b) 이 launcher가 session host
//! helper를 **double-fork + setsid**로 띄운다. 그러면 손자(host)는 부모(GUI)와 다른 세션·프로세스 그룹의 orphan이 되어
//! GUI가 종료·크래시해도 살아 남고(init이 reap), GUI는 중간 자식만 reap해 zombie를 남기지 않는다. 이것이 "GUI를 죽여도
//! host 생존"을 배포에서 성립시키는 수명 배선이다.
//!
//! macOS 전용(실 fork/exec/setsid). 순수 부분(argv 조립)은 non-macOS에서도 TDD하고, 실 spawn 메커니즘은 관찰 가능한
//! 자식(marker 파일)으로 process smoke한다. 실제 `maru` 바이너리를 host로 띄우는 end-to-end는 CLI 배선(아래 argv)이
//! 붙은 뒤 앱 통합/OS E2E에서 검증한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

// execv는 std.c 미노출이라 직접 extern(현재 environ 상속). launcher는 macOS 전용이라 링크 대상이 libc다.
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
// 상속 fd를 명시적으로 닫기 위한 descriptor table 크기(soft limit, macOS는 OPEN_MAX로 상한). std.c 미노출이라 extern.
extern "c" fn getdtablesize() c_int;

/// `maru <exe>`를 session host로 전환하는 hidden 서브커맨드 이름. main.zig dispatch와 이 launcher가 공유하는 단일 출처다.
pub const subcommand = "__session-host";

pub const SpawnError = error{ ForkFailed, OutOfMemory };

/// host helper의 argv를 조립한다(순수) — `[exe_path, "__session-host", socket_path]`. exec에 넘길 NUL 종단 포인터
/// 배열은 실 spawn 경로가 만들고, 이 함수는 사람이 읽고 테스트하기 쉬운 슬라이스 목록만 돌려준다(caller가 free).
pub fn sessionHostArgv(allocator: std.mem.Allocator, exe_path: []const u8, socket_path: []const u8) error{OutOfMemory}![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 3);
    argv[0] = exe_path;
    argv[1] = subcommand;
    argv[2] = socket_path;
    return argv;
}

/// `exe_path`를 `args`(NUL 종단 슬라이스들)로 **detached** 실행한다: double-fork로 손자를 부모와 독립시키고, setsid로
/// 새 세션 리더가 되게 하며, std fd를 `/dev/null`로 돌려 부모 터미널에 묶이지 않게 한다. 부모는 중간 자식만 waitpid로
/// reap하고 즉시 반환한다(손자는 orphan → init reap). exec 실패는 손자에서 `_exit(127)`로 끝난다.
pub fn spawnDetached(allocator: std.mem.Allocator, exe_path: [:0]const u8, args: []const [:0]const u8) SpawnError!void {
    if (builtin.os.tag != .macos) return error.ForkFailed;

    // exec argv: [exe_path, args..., null]. child가 exec 전에 쓰므로 부모 메모리라도 fork로 복제돼 안전하다.
    var argv = allocator.alloc(?[*:0]const u8, args.len + 2) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = exe_path.ptr;
    for (args, 0..) |a, i| argv[i + 1] = a.ptr;
    argv[args.len + 1] = null;

    const pid1 = c.fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 == 0) {
        // 중간 자식: 새 세션 리더가 된 뒤 다시 fork해 손자를 만든다. 중간 자식이 곧 죽으면 손자는 session leader가 아니라
        // orphan이 되어 controlling terminal을 다시 얻지 않는다(daemon 관용구).
        _ = c.setsid();
        const pid2 = c.fork();
        if (pid2 < 0) std.c._exit(127);
        if (pid2 == 0) {
            // stdio 위 상속 fd(GUI socket·PTY master·control-plane·capability fd)를 exec 전에 모두 닫는다. fork는 부모
            // fd 테이블을 복제하고 exec는 CLOEXEC 아닌 fd를 그대로 넘기므로, 닫지 않으면 detached host가 GUI 자원을
            // 물려받아 fd 누수·정보 노출이 생긴다(§11). 그다음 0/1/2를 /dev/null로 돌린다(닫힌 3번을 재사용).
            closeInheritedFds();
            redirectStdioToDevNull();
            _ = execv(exe_path.ptr, @ptrCast(argv.ptr));
            std.c._exit(127); // execv는 성공 시 반환하지 않는다 — 여기 오면 exec 실패.
        }
        std.c._exit(0); // 중간 자식 종료 → 손자 orphan(부모는 손자를 모른다).
    }
    // 부모(GUI): 중간 자식을 reap해 zombie를 안 남긴다. 손자(host)는 부모와 무관하게 산다.
    var status: c_int = undefined;
    _ = c.waitpid(pid1, &status, 0);
}

/// stdio(0·1·2) 위의 상속 fd를 모두 닫는다. CLOEXEC에 의존하지 않고 fd 3..getdtablesize()를 명시적으로 close해
/// detached host가 부모(GUI) fd를 하나도 물려받지 않게 한다(best-effort — 이미 닫힌 fd의 close는 무해). redirect보다
/// **먼저** 불러야 /dev/null redirect가 쓰는 fd 3이 곧바로 닫히지 않는다.
fn closeInheritedFds() void {
    const max_fd = getdtablesize();
    if (max_fd <= 3) return;
    var fd: c_int = 3;
    while (fd < max_fd) : (fd += 1) {
        _ = c.close(fd);
    }
}

/// detached host의 std fd를 `/dev/null`로 돌린다(부모 터미널 미점유). 열기 실패해도 exec는 진행한다(best-effort).
fn redirectStdioToDevNull() void {
    const fd = c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(c.mode_t, 0));
    if (fd < 0) return;
    _ = c.dup2(fd, 0);
    _ = c.dup2(fd, 1);
    _ = c.dup2(fd, 2);
    if (fd > 2) _ = c.close(fd);
}

// ─────────────────────────────────────────────────────────────────────────────
// 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 앱이 session host를 **부모와 독립된** 프로세스로 띄워야
// GUI가 죽어도 host가 산다. argv 조립(순수)이 `maru __session-host <socket>` 형태인지, double-fork spawn이 실제로
// 부모를 막지 않고 detached 자식을 실행하는지(관찰 가능한 marker 파일로) 고정한다. 실 fork/exec는 macOS opt-in이다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "launcher: sessionHostArgv builds [exe, __session-host, socket] (pure)" {
    const allocator = testing.allocator;
    const argv = try sessionHostArgv(allocator, "/usr/local/bin/maru", "/tmp/session-host/control.sock");
    defer allocator.free(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/usr/local/bin/maru", argv[0]);
    try testing.expectEqualStrings("__session-host", argv[1]);
    try testing.expectEqualStrings("/tmp/session-host/control.sock", argv[2]);
}

test "launcher: spawnDetached runs a detached child without blocking the parent (marker)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrintZ(&marker_buf, "/tmp/maru-sh-launch-{d}.marker", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.unlink(marker.ptr); // 이전 잔해 제거.

    // detached로 `/bin/sh -c 'touch <marker>'`를 띄운다. 부모(테스트)는 즉시 반환하고, 손자가 marker를 만든다.
    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "touch {s}", .{marker}) catch return error.SkipZigTest;
    const dash_c: [:0]const u8 = "-c";
    try spawnDetached(allocator, "/bin/sh", &.{ dash_c, cmd });

    // 손자가 marker를 만들 때까지 짧게 대기(부모는 손자를 reap하지 않으므로 파일 존재로 관찰).
    var attempts: usize = 0;
    var seen = false;
    while (attempts < 100) : (attempts += 1) {
        if (c.access(marker.ptr, 0) == 0) {
            seen = true;
            break;
        }
        _ = usleepMs(20);
    }
    _ = c.unlink(marker.ptr);
    try testing.expect(seen);
}

extern "c" fn usleep(usec: c_uint) c_int;
fn usleepMs(ms: c_uint) c_int {
    return usleep(ms * 1000);
}
