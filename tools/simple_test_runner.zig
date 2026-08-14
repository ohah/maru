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

fn expectedTestCount(args: std.process.Args) ?usize {
    comptime if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    const prefix = "--maru-expect-tests=";
    while (iterator.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (!std.mem.startsWith(u8, arg, prefix)) continue;
        return std.fmt.parseInt(usize, arg[prefix.len..], 10) catch std.process.exit(1);
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

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
    // 모든 test-local defer와 progress 정산 뒤에는 C runtime 종료 hook이
    // aggregate의 검증 결과를 다시 바꾸지 못하도록 확정된 status를 게시한다.
    if (builtin.link_libc) std.c._exit(0) else std.process.exit(0);
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
