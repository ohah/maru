//! Exit-code based Zig test runner used by Maru's default test graph.
//!
//! Zig 0.16's Build server runner currently starts some test binaries with
//! `--listen=-`.  Keep this runner intentionally close to the standard
//! terminal runner, but never enter that stdin IPC protocol: every discovered
//! test still runs, and failures, testing-allocator leaks, and error logs keep
//! a non-zero exit status.
const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const testing = std.testing;

// 전용 C3-3b3 runner가 값을 채우지 않는 일반 test artifact도 링크될 수 있도록 pristine 채널을 제공한다.
pub export var maru_c3b3_death_stage_raw: u8 = 0;
pub export var maru_c3b3_death_child_path: [1024]u8 = [_]u8{0} ** 1024;
pub export var maru_c3b3_death_child_path_len: usize = 0;

pub const std_options: std.Options = .{
    .logFn = log,
};

/// **지금 도는 판정자의 번호**(`builtin.test_functions` 안의 위치 + 1, 아직 아무것도 안 돌면 0). 첫 테스트 직전부터
/// 각 테스트를 부르기 **직전**에 바뀐다.
///
/// 판정자들은 한 프로세스의 전역을 나눠 쓴다. 앞선 판정자가 올려 두고 안 되돌린 전역이 뒤 판정자를 깨는 일이
/// 실행 순서에 따라 나타났다 사라졌다(2026-10-01 — 선언 순서가 바뀌자 프레임 도장이 남아 판정자 넷이 깨졌다).
/// 이 번호로 그런 전역은 **자기를 쓴 판정자 안에서만** 유효하게 만들 수 있다 — 쓸 때 번호를 함께 적고, 읽을 때
/// 번호가 다르면 「없음」으로 본다(`client.zig` 의 UI 프레임 도장). 제품 코드는 `@hasDecl(@import("root"), …)` 로
/// 읽어 이 러너가 아닌 곳(제품 빌드·기본 러너)에서는 0 이다 — extern 이 아니라 링크를 깨지 않는다.
pub var maru_test_generation: u64 = 0;

/// **fork 된 판정자 자식이 panic 하면 DWARF 를 읽지 않는다** — 함수 이름 수준의 스택만 찍고 끝낸다.
///
/// fail-stop 판정자는 일부러 panic 하는 자식을 fork 하고, 부모는 그 자식의 종료 상태와 stderr 의 **panic 메시지
/// 일부**만 본다(스택 내용·`thread N panic:` 접두를 대조하는 판정자는 0 — 2026-10-01 전수 확인). 그런데 기본 처리기는
/// 소스 위치를 붙이려고 바이너리의 DWARF line table 을 통째로 파싱한다 — 147 MB Debug 집계 바이너리에서 자식 하나에
/// 2~3 초였고(`sample`: `debug.Dwarf.runLineNumberProgram`·`SrcLocCache`), 자식 셋을 띄우는 판정자 하나가 9.9 초였다.
///
/// 러너가 띄운 프로세스 **자신**의 panic 은 기본 그대로다(전체 트레이스). 자식에서도 메시지는 그대로 쓰고, 스택은
/// libc `backtrace_symbols_fd`(심볼 테이블 — DWARF 없음)로 함수 이름까지 남기며, 끝은 기본과 같은 `abort()`(SIGABRT)다.
/// 전체 트레이스가 필요하면 `MARU_TEST_CHILD_PANIC_TRACE=1`. macOS 전용 — `getpid`·`getenv` 를 다른 판정자와 같은
/// 규칙으로 macOS 에서만 참조한다(`envPrefix` 주석).
pub const panic = std.debug.FullPanic(testRunnerPanic);
var runner_pid: std.c.pid_t = 0;
extern "c" fn backtrace(buffer: [*]?*anyopaque, size: c_int) c_int;
extern "c" fn backtrace_symbols_fd(buffer: [*]const ?*anyopaque, size: c_int, fd: c_int) void;

fn testRunnerPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (builtin.os.tag == .macos and runner_pid != 0 and std.c.getpid() != runner_pid and
        getenv("MARU_TEST_CHILD_PANIC_TRACE") == null)
    {
        const prefix = "panic: ";
        _ = std.c.write(2, prefix.ptr, prefix.len);
        if (msg.len != 0) _ = std.c.write(2, msg.ptr, msg.len);
        const note = "\n(forked test child: symbol-only stack, MARU_TEST_CHILD_PANIC_TRACE=1 for the full trace)\n";
        _ = std.c.write(2, note.ptr, note.len);
        var frames: [64]?*anyopaque = undefined;
        const count = backtrace(&frames, @intCast(frames.len));
        if (count > 0) backtrace_symbols_fd(&frames, count, 2);
        std.c.abort();
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

var log_err_count: std.atomic.Value(usize) = .init(0);
var is_fuzz_test: bool = false;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn _NSGetArgv() *[*:null]?[*:0]u8;
extern var environ: [*:null]?[*:0]u8;

/// 이 test 프로세스와 **그 자식들**이 사용자의 session-host registry와 workspace를 절대 건드리지 않게 한다.
///
/// 왜 runner 인가. 격리를 라이브러리 기본값(`builtin.is_test`)만으로 하면 test 프로세스 자신만 옮겨가고,
/// test 가 spawn 하는 **제품 바이너리**(`MARU_SESSION_HOST_PRODUCT_EXE` 계열)는 `is_test` 가 false 라
/// 다시 `/tmp/maru-<uid>` 로 돌아간다. 환경변수는 fork/exec 로 상속되므로 여기서 한 번 심으면 그 자식까지
/// 함께 옮겨간다(`launcher.clearSessionHostTestEnvironment` 도 이 이름은 지우지 않는다).
///
/// 실측 배경(2026-08-27): `test-session-host` 와 `test-macos-app-host-abi` 가 사용자의 `/tmp/maru-501/sh`
/// 에 가짜 host socket 을 남겼고, 그 가짜가 `maru host status` 를 ambiguous 로 만들어 **실행 중인 앱이
/// 복구 세션을 adopt 하지 못하고 크래시 로그도 없이 종료**됐다. 두 번 반복된 사고다.
///
/// inherited roots are untrusted: 부모 셸의 값이 제품 root를 가리킬 수 있으므로 언제나 이 process의
/// PID root로 덮어쓴다. 같은 이유로 AppKit/Foundation이 workspace checkpoint 위치를 정할 때 보는
/// `CFFIXED_USER_HOME`도 덮어쓴다.
///
/// **`HOME` 은 실제 사용자 홈일 때만 실행마다 새 임시 홈(`/tmp/maru-home-<pid>-XXXXXX`)으로 바꾼다**(2026-10-04). 제품 자식은 `HOME` 에서 캐시를
/// 유도한다 — 테스트가 띄운 `maru __session-host` 가 실제 `~/.cache/maru/agent-turn-events/` 에 칸을 만들고 그
/// 안의 죽은 host 칸을 **지우는 정리까지** 돌았다. 셸은 `~/.bash_history` 를, terminfo 는 `~/.cache/maru/terminfo`
/// 를 썼다. 예전에는 「PTY·shell fixture 의 의미가 달라진다」며 두었으나, 전체 `zig build test` 를 가짜 `HOME` 으로
/// 돌려 새로 빨개지는 판정자가 0 개임을 실측했다. 이미 다른 곳을 가리키는 `HOME`(앱 스모크 빌드 스텝의
/// fixture home)은 그 스텝의 격리이므로 그대로 둔다. 이미 설정된 `XDG_*` 는 **어느 경우든** 지금 `HOME` 아래로
/// 옮긴다 — 부모 셸의 `XDG_CACHE_HOME` 이 실제 캐시를 가리키면 `HOME` 만 옮겨서는 소용없다(`reexecWithIsolatedHome`).
/// 예전에는 `HOME` 을 바꿀 때만 옮겨서, fixture home 을 받은 스텝은 셸의 실제 `XDG_*` 를 그대로 물려받았다(2026-10-06 재현).
///
/// ⚠️ **login(1) 로 감싼 셸은 이 격리 밖이다**(2026-10-06 재현). macOS PTY 의 login 래퍼(`/usr/bin/login -flp <user>
/// /bin/bash … exec -l <shell>`)는 `-p` 로 나머지 환경(`XDG_*` 포함)은 지키지만 **`HOME` 은 사용자 DB 의 실제 홈으로 다시
/// 정한다.** 그래서 `login = true` 로 PTY 를 띄우는 판정자(`pty/macos.zig` 의 login wrapper 판정자들)와 앱 스모크의
/// 대화형 셸은 실제 홈의 시작 파일(`~/.profile`·`~/.zshrc` …)을 읽고 로그인 기록을 갱신하며, 대화형 셸은 사용자 설정에
/// 따라 history 를 실제 홈에 쓸 수 있다. 제품 자식(`maru __session-host`)과 `controlled_smoke`(`/bin/sh -c`, login 아님)는
/// 격리가 그대로 먹는다. **이 격리를 믿고 login 셸 판정자가 실제 홈에 쓰는 일을 만들지 않는다.**
/// 어느 주입이든 실패하면 test process는 시작하지 않는다. 라이브러리의 `builtin.is_test` 기본값은 이
/// process만 보호하며, 환경을 못 받은 제품 child는 사용자 공용 namespace와 workspace로 돌아가므로 여기서
/// 계속 실행할 안전한 fallback은 없다.
fn isolateSessionHostRoot() error{IsolationFailed}!void {
    // **macOS 전용이다.** session host 자체가 macOS 기능이고, 무엇보다 `setenv` 는 libc 심볼이라
    // libc 를 링크하지 않는 Linux test 바이너리에서는 **링크 단계에서 실패한다**(CI 의 ubuntu 오라클
    // 잡이 그렇게 깨졌다). `comptime` 분기라 그 대상에서는 아래 코드와 심볼 참조가 통째로 사라진다.
    if (comptime builtin.os.tag != .macos) return;
    var buf: [64]u8 = undefined;
    const root = std.fmt.bufPrintZ(&buf, "/tmp/maru-t{d}", .{std.c.getpid()}) catch
        return error.IsolationFailed;
    if (setenv("MARU_SESSION_HOST_ROOT", root.ptr, 1) != 0)
        return error.IsolationFailed;
    if (setenv("CFFIXED_USER_HOME", root.ptr, 1) != 0)
        return error.IsolationFailed;
    const real_home = homeIsRealUserHome();
    if (real_home or xdgOutsideHome()) try reexecWithIsolatedHome(real_home);
}

/// `replace_home` 이면 실제 홈 대신 새 임시 홈(`/tmp/maru-home-<pid>-XXXXXX`)을 세우고, 아니면 지금 `HOME` 을 둔 채
/// 그 밖을 가리키는 `XDG_*` 만 옮겨서 **이 바이너리를 그 환경으로 다시 exec 한다.**
///
/// 왜 exec 인가: 시작 뒤 `setenv` 로만 바꾸면 libc 의 `environ` 은 새 값을, std 가 시작 때 붙잡은 envp 조각
/// (`init.environ` → `testing.environ`·`testing.io_instance`·debug Io)은 **실제 홈**을 본다. 한 프로세스 안에서
/// 두 홈이 갈려, 실측 2026-10-04 에 app-host-abi 샤드 둘에서 판정자 12 개가 결정적으로 빨갰다 — 같은 러너를
/// `zig build` 바깥에서 가짜 `HOME` 으로 띄운 실행은 0 개였다. 조각을 사후에 갈아 끼우면 libc 가 다음 `setenv`
/// 에서 배열을 재할당할 때 그 조각이 해제된 메모리를 가리킨다. exec 는 처음부터 그 환경으로 시작한 것과 같고,
/// **pid 를 유지**하므로 `/tmp/maru-t<pid>` 와 정리 규칙(`kill -0`)이 그대로다. argv 도 그대로라
/// `_NSGetArgc` 로 fixture 게이트를 판단하는 판정자들도 영향이 없다.
///
/// `XDG_*` 는 **지우지 않고**(macOS libc 의 `unsetenv` 는 배열을 제자리에서 줄여 std 의 조각 훑기를 죽인다 —
/// `std_environ_view.zig`), 이미 설정된 것만 홈 아래로 바꾼다. 없는 것은 `HOME` 에서 유도된다.
/// session root 와 같은 자리는 쓰지 않는다 — root 안에는 session host 의 것만 둔다. 이름은 `maru-<태그>-<pid>-…`
/// 꼴이라 `tools/clean-tmp-fixtures.sh` 가 앞에서부터 pid 를 읽어 거둔다. exec 된 쪽은 홈이 실제가 아니고 `XDG_*` 가
/// 모두 홈 아래라 다시 돌지 않는다.
///
/// **임시 홈은 `mkdtemp` 로 실행마다 새로 만든다**(2026-10-07). 예전에는 `/tmp/maru-home-<pid>` 를 `mkdir` 하고
/// `EEXIST` 를 받아들였다 — ① pid 가 재사용되면 이전 실행이 남긴 `~/.cache/maru`(죽은 host 칸·terminfo)를 물려받아
/// 「코드와 무관한 간헐 실패」 부류(`clean-tmp-fixtures.sh` 머리말)가 됐고, ② `/tmp` 는 누구나 쓰므로 다른 사용자가
/// 같은 이름의 디렉터리나 **심볼릭 링크**를 미리 두면 그 자리를 그대로 홈으로 썼다. `mkdtemp` 는 없는 이름을 0700 으로
/// 원자적으로 만든다.
fn reexecWithIsolatedHome(replace_home: bool) error{IsolationFailed}!void {
    var home_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const home: [:0]const u8 = if (replace_home) blk: {
        const template = std.fmt.bufPrintZ(&home_buf, "/tmp/maru-home-{d}-XXXXXX", .{std.c.getpid()}) catch
            return error.IsolationFailed;
        // 셸이 `cd ~` 하고 제품이 `~/.cache/maru` 를 만들 수 있게 미리 세운다.
        const made = mkdtemp(template.ptr) orelse return error.IsolationFailed;
        if (setenv("HOME", made, 1) != 0)
            return error.IsolationFailed;
        break :blk template;
    } else blk: {
        // **복사해 둔다** — 아래 `setenv` 가 환경 배열을 재할당해도 기준 홈이 흔들리지 않게.
        const current = std.mem.span(getenv("HOME") orelse return error.IsolationFailed);
        break :blk std.fmt.bufPrintZ(&home_buf, "{s}", .{current}) catch return error.IsolationFailed;
    };
    const xdg = [_]struct { name: [*:0]const u8, sub: []const u8 }{
        .{ .name = "XDG_CACHE_HOME", .sub = ".cache" },
        .{ .name = "XDG_CONFIG_HOME", .sub = ".config" },
        .{ .name = "XDG_DATA_HOME", .sub = ".local/share" },
        .{ .name = "XDG_STATE_HOME", .sub = ".local/state" },
    };
    for (xdg) |x| {
        const current = getenv(x.name) orelse continue;
        if (!replace_home and pathUnder(std.mem.span(current), home)) continue; // fixture 가 자기 홈 아래에 둔 것은 그대로
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const value = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ home, x.sub }) catch return error.IsolationFailed;
        if (setenv(x.name, value.ptr, 1) != 0) return error.IsolationFailed;
    }
    var exe_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var exe_len: u32 = std.fs.max_path_bytes;
    if (std.c._NSGetExecutablePath(&exe_buf, &exe_len) != 0) return error.IsolationFailed;
    _ = std.c.execve(@ptrCast(&exe_buf), _NSGetArgv().*, environ);
    return error.IsolationFailed; // execve 는 성공하면 돌아오지 않는다
}

/// 이미 설정된 `XDG_*` 중 지금 `HOME` 밖을 가리키는 것이 있는가. `HOME` 이 없으면 아니다 — 명시 환경으로 자기 자신을
/// 다시 띄우는 fixture 자식들이고(`homeIsRealUserHome` 과 같은 규칙), 옮길 기준 홈도 없다.
fn xdgOutsideHome() bool {
    const home = std.mem.span(getenv("HOME") orelse return false);
    for ([_][*:0]const u8{ "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) |name| {
        const value = std.mem.span(getenv(name) orelse continue);
        if (!pathUnder(value, home)) return true;
    }
    return false;
}

/// `path` 가 `dir` 자신이거나 그 아래인가 — 끝 `/` 는 무시하고 **경로 칸 단위**로 본다(`/tmp/h` 는 `/tmp/home` 의 조상이 아니다).
fn pathUnder(path: []const u8, dir: []const u8) bool {
    const p = std.mem.trimEnd(u8, path, "/");
    const d = std.mem.trimEnd(u8, dir, "/");
    if (d.len == 0) return false;
    if (!std.mem.startsWith(u8, p, d)) return false;
    return p.len == d.len or p[d.len] == '/';
}

/// 지금 `HOME` 이 이 사용자의 실제 홈(OS 사용자 DB)인가. **없으면 아니다** — 명시 환경으로 자기 자신을 다시 띄우는
/// fixture 자식들이 그렇고, 그때는 제품의 홈 유도가 null 이라 샐 곳이 없다. 사용자 DB 를 못 읽으면 「실제」로 본다.
fn homeIsRealUserHome() bool {
    const home = std.mem.span(getenv("HOME") orelse return false);
    const pw = std.c.getpwuid(std.c.getuid()) orelse return true;
    const dir = std.mem.span(pw.dir orelse return true);
    return std.mem.eql(u8, std.mem.trimEnd(u8, home, "/"), std.mem.trimEnd(u8, dir, "/"));
}

fn optionValue(args: std.process.Args, prefix: []const u8) ?usize {
    // windows/wasi는 인자 이터레이션 모델이 달라 이 옵션을 읽지 않는다. `comptime if (...) return null;`로 쓰면
    // 조건이 참인 타깃(=windows)에서 "comptime에 return 불가"로 **컴파일이 깨진다** — macOS에선 조건이 거짓이라
    // 본문이 평가되지 않아 드러나지 않던 Windows 전용 결함이었다. 조건이 comptime-known이라 평범한 if로도 폴딩된다.
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (!std.mem.startsWith(u8, arg, prefix)) continue;
        return std.fmt.parseInt(usize, arg[prefix.len..], 10) catch std.process.exit(1);
    }
    return null;
}

/// 이 바이너리에 **컴파일된** 테스트 수(필터가 몇 개를 골랐는가).
fn expectedTestCount(args: std.process.Args) ?usize {
    return optionValue(args, "--maru-expect-tests=");
}

/// 실제로 **통과한** 테스트 수. `--maru-expect-tests` 와 다른 질문에 답한다 —
/// 그쪽은 「골라졌는가」이고 이쪽은 「돌았는가」다.
///
/// **왜 둘 다 필요한가**: `error.SkipZigTest` 로 나간 행도 컴파일된 수에는 든다. 그래서 env 로 건너뛰는
/// 행(프로세스 전역을 흔들어 aggregate 에서 빼는 부류)이 있는 게이트에서는, 그 env 가 실수로 켜지면
/// **증거가 0 인데 초록**이 된다. 그 실패 모드는 「없어진 것」과 「원래 없던 것」을 구분할 수 없어 가장
/// 나쁘다 — 그래서 개수를 세는 쪽으로 답한다.
fn expectedPassedCount(args: std.process.Args) ?usize {
    return optionValue(args, "--maru-expect-passed=");
}

/// **셸이 무시(`SIG_IGN`)로 물려준 SIGINT·SIGQUIT 를 기본 처분으로 되돌린다** — 테스트를 하나도 돌리기 전에.
///
/// 비대화형 `sh` 의 비동기 목록(`… &`)은 자식을 SIGINT·SIGQUIT 무시 상태로 띄운다(POSIX — 잡 제어가 없을 때).
/// `tools/run-test-shards.sh` 가 샤드를 그렇게 띄우고, `mise run check &` 같은 백그라운드 실행도 같다. 셸 쪽에서는
/// 못 고친다 — 비대화형 셸은 **들어올 때 이미 무시된 신호를 `trap` 으로 되돌리지 못한다**(macOS `/bin/sh` = bash 3.2
/// 로 실측: `( trap - INT QUIT; … ) &` 도 무시 그대로). 그래서 테스트 프로세스인 여기서 되돌린다.
///
/// 무시 상태가 남으면 `external_tty` 가 설계대로 raw 진입을 거부해(`UnsupportedSignalDisposition` — 종료 신호가
/// 기본 처분이어야 raw 를 되돌릴 수 있다) 그 부류 판정자 19개가 `RawEnterFailed` 등으로 죽고, `fork` 자식도 그
/// 상태를 물려받았다(2026-09-30 — 러너 계측으로 네 샤드 모두 첫 테스트 전부터 `SIG_IGN` 이었다). 되돌리면 19개가
/// 다 산다. 기본 처분이면 Ctrl-C 가 테스트 프로세스를 끝내는 것도 사람의 기대와 같다.
fn restoreInheritedIgnoredSignals() void {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return,
    }
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .INT, .QUIT }) |sig| {
        var current: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &current);
        // 무시로 물려받은 것만 되돌린다 — 다른 처리기는 누군가의 의도라 건드리지 않는다.
        if (current.handler.handler == std.posix.SIG.IGN) std.posix.sigaction(sig, &default_action, null);
    }
}

/// skip/keep prefix 는 **env 로** 받는다(argv 아님). **왜 argv 가 아닌가**: 일부 판정자가
/// `_NSGetArgc() >= 3` 으로 「fixture 게이트인가」를 판단해 fixture 없으면 SkipZigTest 한다. skip 설정을
/// argv 로 넘기면 argc 가 늘어 그 판정자들이 fixture 가 있다고 오판하고 돌다 죽는다(실측 2026-09-06,
/// P3-e4d-2a). env 는 argc 를 안 건드린다. CSV 원시 값을 돌려준다.
fn envPrefix(name: [*:0]const u8) ?[]const u8 {
    // **macOS 전용이다** — 이 필터를 쓰는 곳이 macOS 게이트뿐이고, `getenv` 는 libc 심볼이라 libc 를 안
    // 링크한 리눅스 테스트 바이너리에서 참조만으로 링크가 깨진다. 조건이 comptime-known 이라 평범한 if 로도
    // 접혀 비-macOS 에서는 getenv 참조가 사라진다(`optionValue`·`isolateSessionHostRoot` 와 같은 규칙).
    if (builtin.os.tag != .macos) return null;
    const raw = getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

/// 이름이 CSV 안 어느 prefix 로든 시작하면 참. **왜 startsWith 인가**: 모듈 경로(`session_host.` 등)로
/// 거르되, 다른 모듈 테스트의 «설명»에 그 문자열이 우연히 들어 있어도 안 걸리게 — 이름의 «머리»만 본다.
fn matchesPrefix(name: []const u8, csv: ?[]const u8) bool {
    const list = csv orelse return false;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |prefix| {
        if (prefix.len == 0) continue;
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// `MARU_TEST_SHARD="i/n"`: 컴파일된 테스트를 **이름 해시 mod n** 으로 n 개 프로세스에 나눠, 이 프로세스는 자기 몫
/// (`hash(name) % n == i`)만 돌린다. **인덱스가 아니라 이름**인 이유는 테스트가 하나 늘 때 남의 배정이
/// 밀리지 않게 하는 것이다(실측 2026-09-10: 밀린 배정이 실 프로세스 스모크를 한 샤드에 몰아 CI 를 세 번
/// 막았다). 같은 바이너리를 n 번 띄우면 되므로 컴파일은 한 번이고, 러너의 pid 루트 격리
/// (`isolateSessionHostRoot`)가 샤드마다 다른 네임스페이스를 준다. **왜 인덱스인가**: 이름 접두로 나누면 한 모듈
/// (app_session 1,127개·237초)이 한 샤드에 몰린다. 인덱스는 모듈 안에서도 고르게 섞인다(실측 2026-09-06, CI
/// macos-15 3 vCPU: 4,557개 355초 직렬 → 4샤드 시뮬레이션 94초). prefix 필터 **뒤에** 적용하므로 `kept`·`filtered`
/// 가드는 샤드와 무관하고, 컴파일 수(`--maru-expect-tests`)도 그대로다. `--maru-expect-passed` 와는 함께 쓰지
/// 않는다 — 그쪽은 프로세스 하나가 다 돌았다는 전제다.
const Shard = struct { index: usize, count: usize };

fn invalidShard(raw: []const u8) noreturn {
    std.debug.print("invalid MARU_TEST_SHARD {s} — expected i/n with i < n\n", .{raw});
    std.process.exit(1);
}

fn envShard() ?Shard {
    const raw = envPrefix("MARU_TEST_SHARD") orelse return null;
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse invalidShard(raw);
    const index = std.fmt.parseInt(usize, raw[0..slash], 10) catch invalidShard(raw);
    const count = std.fmt.parseInt(usize, raw[slash + 1 ..], 10) catch invalidShard(raw);
    if (count == 0 or index >= count) invalidShard(raw);
    return .{ .index = index, .count = count };
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    isolateSessionHostRoot() catch std.process.exit(1);

    comptime if (builtin.fuzz) {
        @compileError("Maru's simple test runner does not support Zig fuzz mode; add a server-mode fuzz gate first");
    };

    const test_functions = builtin.test_functions;
    if (expectedTestCount(init.args)) |expected| {
        if (test_functions.len != expected) {
            std.debug.print(
                "focused test selection mismatch: expected {d}, compiled {d}\n",
                .{ expected, test_functions.len },
            );
            std.process.exit(1);
        }
    }
    const root_node = std.Progress.start(runner_io, .{
        .root_name = "Test",
        .estimated_total_items = test_functions.len,
    });
    const have_tty = Io.File.stderr().isTty(runner_io) catch unreachable;
    restoreInheritedIgnoredSignals();
    if (builtin.os.tag == .macos) runner_pid = std.c.getpid();

    // **컴파일은 됐지만 여기서는 안 돌린다** — `--maru-skip-prefix` 로 시작하는 이름은 다른 잡이 이미 도는
    // 것(예: `session_host.` 는 `test-session-host` 가 모듈 그래프째 돈다). `--maru-keep-prefix` 는 그 예외다
    // (그 잡에 없어 여기서만 도는 모듈). 컴파일 수(`--maru-expect-tests`)는 그대로라 «골라졌는가»는 불변이고,
    // 실행만 건너뛰어 러너 시간을 던다.
    const skip_prefixes = envPrefix("MARU_TEST_SKIP_PREFIX");
    const keep_prefixes = envPrefix("MARU_TEST_KEEP_PREFIX");
    // `MARU_TEST_KEEP_ONLY_PREFIX`: 이것으로 시작하는 이름 **만** 돌린다(나머지는 FILTERED). 같은 모듈 그래프를
    // 루트만 달리해 컴파일한 바이너리가 다른 바이너리의 테스트를 통째로 다시 도는 «번짐»을, 자기 몫만 남기고 끊는
    // 용도다(예: client_external_rx_read_test_support — 1,589개 중 1,555개가 client_external_pump 바이너리와 동일).
    const keep_only_prefixes = envPrefix("MARU_TEST_KEEP_ONLY_PREFIX");
    const shard = envShard();
    var kept: usize = 0;
    var filtered: usize = 0;
    var other_shard: usize = 0;

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (test_functions, 0..) |test_fn, index| {
        // 다른 샤드의 몫은 FILTERED 줄도 찍지 않는다 — 샤드 n 개가 같은 줄을 n 번 찍으면 로그를 못 읽는다. 다만
        // `filtered`·`kept` 는 샤드와 무관하게 세어 아래 가드가 어느 샤드에서나 같은 답을 내게 한다.
        // **이름 해시로 나눈다** — 인덱스 순차(`index % n`)면 테스트 **하나가 늘 때 그 뒤 전부 밀려**,
        // 실 프로세스를 띄우는 스모크가 한 샤드에 몰릴 수 있다. 2026-09-10 에 그것이 세 번 CI 를 막았고
        // **매번 다른 테스트**였다(`C3-3b6` 둘, `runActualTerminate` 하나) — CI 와 로컬이 같은 자리였으니
        // 부하가 아니라 배정이다. 해시는 **이름에만** 달려 있어 새 테스트가 남의 배정을 흔들지 않는다.
        //
        // ⚠️ 이것은 **재발을 줄이지 보장하지는 않는다.** 해시는 안정적일 뿐 균등하지 않고, 실 프로세스
        // 스모크가 우연히 한 샤드에 모이는 것을 막지 못한다 — 그 보장은 「그 테스트들을 샤드 밖으로」
        // (#3494 가 하나를 그렇게 뺐다)나 락으로 직렬화하는 별개 축이다.
        const mine = if (shard) |s| std.hash.Wyhash.hash(0, test_fn.name) % s.count == s.index else true;
        if (keep_only_prefixes != null and !matchesPrefix(test_fn.name, keep_only_prefixes)) {
            filtered += 1;
            if (!have_tty and mine) std.debug.print("{d}/{d} {s}...FILTERED\n", .{ index + 1, test_functions.len, test_fn.name });
            continue;
        }
        if (keep_only_prefixes != null) kept += 1;
        if (matchesPrefix(test_fn.name, skip_prefixes) and !matchesPrefix(test_fn.name, keep_prefixes)) {
            filtered += 1;
            if (!have_tty and mine) std.debug.print("{d}/{d} {s}...FILTERED\n", .{ index + 1, test_functions.len, test_fn.name });
            continue;
        }
        if (!mine) {
            other_shard += 1;
            continue;
        }
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) leaked += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;
        is_fuzz_test = false;

        @atomicStore(u64, &maru_test_generation, @as(u64, index) + 1, .monotonic);
        const test_node = root_node.start(test_fn.name, 0);
        if (!have_tty) std.debug.print("{d}/{d} {s}...", .{ index + 1, test_functions.len, test_fn.name });
        if (test_fn.func()) |_| {
            passed += 1;
            test_node.end();
            if (!have_tty) std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...SKIP\n", .{ index + 1, test_functions.len, test_fn.name });
                } else {
                    std.debug.print("SKIP\n", .{});
                }
                test_node.end();
            },
            else => {
                failed += 1;
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...FAIL ({t})\n", .{ index + 1, test_functions.len, test_fn.name, err });
                } else {
                    std.debug.print("FAIL ({t})\n", .{err});
                }
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                test_node.end();
            },
        }
    }
    root_node.end();

    const passed_count = passed;
    const skipped_count = skipped;
    const failed_count = failed;
    const leaked_count = leaked;
    const logged_errors = log_err_count.load(.acquire);
    if (passed_count == test_functions.len) {
        std.debug.print("All {d} tests passed.\n", .{passed_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{
            passed_count,
            skipped_count,
            failed_count,
        });
    }
    if (logged_errors != 0) std.debug.print("{d} errors were logged.\n", .{logged_errors});
    if (filtered != 0) std.debug.print("{d} tests filtered by prefix.\n", .{filtered});
    // skip prefix 를 줬는데 하나도 안 걸렸다 = prefix 오타/이름 규칙 변화. 조용히 시간만 그대로 쓰지 말고 빨개진다.
    // keep-only 를 줬는데 하나도 안 남았다 = prefix 오타. 조용히 «0개 돌리고 초록»이 되지 않게 빨개진다.
    if (keep_only_prefixes != null and kept == 0) {
        std.debug.print("keep-only prefix kept no tests — check MARU_TEST_KEEP_ONLY_PREFIX\n", .{});
        std.process.exit(1);
    }
    if (skip_prefixes != null and filtered == 0) {
        std.debug.print("skip prefix matched no tests — check --maru-skip-prefix\n", .{});
        std.process.exit(1);
    }
    if (shard) |s| {
        std.debug.print("shard {d}/{d}: {d} tests belong to other shards.\n", .{ s.index, s.count, other_shard });
        // 샤드가 하나도 안 돌렸다 = n 이 테스트 수보다 크거나 필터와 겹쳐 비었다. 조용히 «0개 돌리고 초록»이 되지 않게 빨개진다.
        if (passed_count + skipped_count + failed_count == 0) {
            std.debug.print("shard ran no tests — check MARU_TEST_SHARD\n", .{});
            std.process.exit(1);
        }
    }
    if (leaked_count != 0) std.debug.print("{d} tests leaked memory.\n", .{leaked_count});
    if (failed_count != 0 or leaked_count != 0 or logged_errors != 0) std.process.exit(1);
    // **돌았는지도 센다.** 위 실패 판정은 SKIP 을 통과로 흘려보내므로, 그것만으로는 «증거가 만들어졌는가»
    // 에 답하지 못한다(`expectedPassedCount` 주석).
    if (expectedPassedCount(init.args)) |expected_passed| {
        if (passed_count != expected_passed) {
            std.debug.print(
                "focused test evidence mismatch: expected {d} passed, got {d} passed / {d} skipped\n",
                .{ expected_passed, passed_count, skipped_count },
            );
            std.process.exit(1);
        }
    }
    // 모든 test-local defer와 progress 정산 뒤에는 C runtime 종료 hook이
    // aggregate의 검증 결과를 다시 바꾸지 못하도록 확정된 status를 게시한다.
    switch (builtin.os.tag) {
        .linux => std.os.linux.exit_group(0),
        else => if (builtin.link_libc) std.c._exit(0) else std.process.exit(0),
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err))
        _ = log_err_count.fetchAdd(1, .monotonic);
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}
