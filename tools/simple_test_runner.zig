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

var log_err_count: std.atomic.Value(usize) = .init(0);
var is_fuzz_test: bool = false;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

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
/// `CFFIXED_USER_HOME`도 덮어쓴다. `HOME`까지 바꾸면 PTY·shell fixture의 의미가 달라지므로 건드리지 않는다.
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
    var kept: usize = 0;
    var filtered: usize = 0;

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (test_functions, 0..) |test_fn, index| {
        if (keep_only_prefixes != null and !matchesPrefix(test_fn.name, keep_only_prefixes)) {
            filtered += 1;
            if (!have_tty) std.debug.print("{d}/{d} {s}...FILTERED\n", .{ index + 1, test_functions.len, test_fn.name });
            continue;
        }
        if (keep_only_prefixes != null) kept += 1;
        if (matchesPrefix(test_fn.name, skip_prefixes) and !matchesPrefix(test_fn.name, keep_prefixes)) {
            filtered += 1;
            if (!have_tty) std.debug.print("{d}/{d} {s}...FILTERED\n", .{ index + 1, test_functions.len, test_fn.name });
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
