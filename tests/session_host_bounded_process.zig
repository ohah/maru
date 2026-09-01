//! Release adapter와 upgrade codesign이 공유할 외부 명령 실행 경계를 실제 macOS process로 검증한다.
//!
//! 성공 결과는 bounded stdout/stderr와 exit 0을 모두 만족해야 하며 timeout은 child만 아니라 같은 process
//! group의 descendant까지 종료해야 다음 release job에 프로세스나 pipe owner를 남기지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
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

test "bounded process stdout-only capture never admits stderr into protocol bytes" {
    var output: [4]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf json; printf warning >&2" };
    const environment = [_:null]?[*:0]const u8{};
    try std.testing.expectEqualStrings(
        "json",
        try process.runCaptureEnvironmentStdout(
            std.testing.io,
            shell,
            &argv,
            &environment,
            &output,
            std.time.ns_per_s,
        ),
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
    const missing: [:0]const u8 = "/definitely/missing/maru-bounded-process";
    const missing_argv = [_:null]?[*:0]const u8{missing.ptr};
    try std.testing.expectError(
        error.ChildFailed,
        process.runCapture(std.testing.io, missing, &missing_argv, &output, std.time.ns_per_s),
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

test "bounded process can replace inherited environment exactly" {
    var output: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf '%s|%s' \"$ONLY_CHILD\" \"${HOME-unset}\"" };
    const environment = [_:null]?[*:0]const u8{"ONLY_CHILD=present"};
    try std.testing.expectEqualStrings(
        "present|unset",
        try process.runCaptureEnvironment(
            std.testing.io,
            shell,
            &argv,
            &environment,
            &output,
            std.time.ns_per_s,
        ),
    );
}

test "bounded process closes ambient descriptors when no inheritance is requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ambient", .data = "secret" });
    var ambient_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const ambient_path = try temporaryPath(&tmp, "ambient", &ambient_path_storage);
    const ambient_fd = c.open(ambient_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = false }, @as(c.mode_t, 0));
    try std.testing.expect(ambient_fd >= 3);
    defer _ = c.close(ambient_fd);
    var fd_storage: [32]u8 = undefined;
    const fd_entry = try std.fmt.bufPrintZ(&fd_storage, "AMBIENT_FD={d}", .{ambient_fd});
    const environment = [_:null]?[*:0]const u8{fd_entry.ptr};
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "if [ -e /dev/fd/$AMBIENT_FD ]; then printf leaked; else printf closed; fi" };
    var output: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "closed",
        try process.runCaptureEnvironment(std.testing.io, shell, &argv, &environment, &output, std.time.ns_per_s),
    );
}

test "bounded process binds one directory as child cwd without mutating parent authority" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "held", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "held/leaf", .data = "payload" });
    var directory_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const directory_path = try temporaryPath(&tmp, "held", &directory_path_storage);
    const directory_fd = c.open(directory_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, @as(c.mode_t, 0));
    try std.testing.expect(directory_fd >= 3);
    defer _ = c.close(directory_fd);
    var leaf_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const leaf_path = try temporaryPath(&tmp, "held/leaf", &leaf_path_storage);
    const ambient_fd = c.open(leaf_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = false }, @as(c.mode_t, 0));
    try std.testing.expect(ambient_fd >= 3 and ambient_fd != directory_fd);
    defer _ = c.close(ambient_fd);
    const flags_before = c.fcntl(directory_fd, c.F.GETFD, @as(c_int, 0));
    var stat_before: std.posix.Stat = undefined;
    try std.testing.expect(flags_before >= 0 and c.fstat(directory_fd, &stat_before) == 0);
    try tmp.dir.rename("held", tmp.dir, "held-moved", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "held", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "held/leaf", .data = "replacement" });
    var fd_storage: [32]u8 = undefined;
    const fd_entry = try std.fmt.bufPrintZ(&fd_storage, "AMBIENT_FD={d}", .{ambient_fd});
    const environment = [_:null]?[*:0]const u8{fd_entry.ptr};
    const argv = [_:null]?[*:0]const u8{ shell.ptr, "-c", "printf '%s|' \"$(/bin/cat ./leaf)\"; if [ -e /dev/fd/$AMBIENT_FD ]; then printf leaked; else printf closed; fi" };
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "payload|closed",
        try process.runCaptureEnvironmentStdoutDirectory(std.testing.io, shell, &argv, &environment, directory_fd, &output, std.time.ns_per_s),
    );
    const flags_after = c.fcntl(directory_fd, c.F.GETFD, @as(c_int, 0));
    var stat_after: std.posix.Stat = undefined;
    try std.testing.expect(flags_after == flags_before and c.fstat(directory_fd, &stat_after) == 0);
    try std.testing.expect(stat_after.dev == stat_before.dev and stat_after.ino == stat_before.ino);
    try std.testing.expectError(
        error.InvalidDirectoryFd,
        process.runCaptureEnvironmentStdoutDirectory(std.testing.io, shell, &argv, &environment, 0, &output, std.time.ns_per_s),
    );
    const closed_fd = c.dup(directory_fd);
    try std.testing.expect(closed_fd >= 3 and c.close(closed_fd) == 0);
    try std.testing.expectError(
        error.InvalidDirectoryFd,
        process.runCaptureEnvironmentStdoutDirectory(std.testing.io, shell, &argv, &environment, closed_fd, &output, std.time.ns_per_s),
    );
    try std.testing.expectError(
        error.InvalidDirectoryFd,
        process.runCaptureEnvironmentStdoutDirectory(std.testing.io, shell, &argv, &environment, ambient_fd, &output, std.time.ns_per_s),
    );
}

fn temporaryPath(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..root_len], leaf });
}
