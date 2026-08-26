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

/// 이 test 프로세스와 **그 자식들**이 사용자의 공용 session-host registry 를 절대 건드리지 않게 한다.
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
/// `overwrite=0` 이라 이미 값을 정한 실행(전용 격리 하니스)은 그대로 존중한다. 실패는 무시한다 — 격리는
/// 라이브러리 기본값이 한 번 더 받치고 있고, runner 가 여기서 죽으면 테스트 자체를 못 돌린다.
fn isolateSessionHostRoot() void {
    var buf: [64]u8 = undefined;
    const root = std.fmt.bufPrintZ(&buf, "/tmp/maru-t{d}", .{std.c.getpid()}) catch return;
    _ = setenv("MARU_SESSION_HOST_ROOT", root.ptr, 0);
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

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    isolateSessionHostRoot();

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

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (test_functions, 0..) |test_fn, index| {
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
