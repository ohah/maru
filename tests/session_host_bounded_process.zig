//! Release adapter와 upgrade codesign이 공유할 외부 명령 실행 경계를 실제 macOS process로 검증한다.
//!
//! 성공 결과는 bounded stdout/stderr와 exit 0을 모두 만족해야 하며 timeout은 child만 아니라 같은 process
//! group의 descendant까지 종료해야 다음 release job에 프로세스나 pipe owner를 남기지 않는다.

const std = @import("std");
const process = @import("bounded_process");

const shell: [:0]const u8 = "/bin/sh";

test "bounded process captures merged stdout and stderr at the exact byte cap" {
    var output: [4]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf ab; printf cd >&2" };
    try std.testing.expectEqualStrings(
        "abcd",
        try process.runCapture(std.testing.io, shell, &argv, &output, std.time.ns_per_s),
    );
}

test "bounded process rejects cap plus one without publishing a prefix" {
    var output: [4]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf abcde" };
    try std.testing.expectError(
        error.OutputTooLarge,
        process.runCapture(std.testing.io, shell, &argv, &output, std.time.ns_per_s),
    );
}

test "bounded process rejects nonzero and signaled terminal status" {
    var output: [16]u8 = undefined;
    const relative: [:0]const u8 = "bin/sh";
    const relative_argv = [_:null]?[*:0]const u8{relative.ptr};
    try std.testing.expectError(
        error.InvalidExecutable,
        process.runCapture(std.testing.io, relative, &relative_argv, &output, std.time.ns_per_s),
    );
    const empty_output: [0]u8 = .{};
    const valid_argv = [_:null]?[*:0]const u8{shell.ptr};
    try std.testing.expectError(
        error.InvalidBudget,
        process.runCapture(std.testing.io, shell, &valid_argv, &empty_output, std.time.ns_per_s),
    );
    const nonzero = [_:null]?[*:0]const u8{ shell.ptr, "-c", "exit 7" };
    try std.testing.expectError(
        error.ChildFailed,
        process.runCapture(std.testing.io, shell, &nonzero, &output, std.time.ns_per_s),
    );
    const signaled = [_:null]?[*:0]const u8{ shell.ptr, "-c", "kill -TERM $$" };
    try std.testing.expectError(
        error.ChildFailed,
        process.runCapture(std.testing.io, shell, &signaled, &output, std.time.ns_per_s),
    );
}

test "bounded process timeout kills a descendant that retains the capture pipe" {
    var output: [16]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{
        shell.ptr,
        "-c",
        "(trap '' TERM; sleep 10) & exec 1>&- 2>&-; exit 0",
    };
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try std.testing.expectError(
        error.TimedOut,
        process.runCapture(std.testing.io, shell, &argv, &output, 80 * std.time.ns_per_ms),
    );
    const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - start;
    try std.testing.expect(elapsed >= 50 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < std.time.ns_per_s);
}
