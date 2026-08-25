//! macOS product adapter for public `maru attach`.
//!
//! Argument policy remains in `cli/attach.zig`; pre-raw transport and the live poll loop keep
//! their existing single owners. This file is deliberately the only product caller that joins
//! those halves and maps their typed terminal outcomes to the stable public exit vocabulary.

const std = @import("std");
const attach_cli = @import("maru").cli.attach;
const runtime_cli = @import("maru").cli.runtime;
const short_endpoint = @import("short_endpoint.zig");
const client_pump = @import("client_pump.zig");
const external_attach = @import("external_attach.zig");
const external_loop_owner = @import("external_loop_owner.zig");
const external_loop_policy = @import("external_loop_policy.zig");
const external_pump_owner = @import("external_pump_owner.zig");
const external_tty = @import("external_tty.zig");
const external_tty_output = @import("external_tty_output.zig");

const c = std.c;
const posix = std.posix;

pub fn runRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: attach_cli.Request,
    stderr: *std.Io.Writer,
) !attach_cli.ExitCode {
    // Reject an unusable or split terminal before discovery. Apart from avoiding an attachment
    // that can never be rendered safely, this guarantees one-sided/non-matching TTY invocations
    // make zero host connections.
    terminalPreflight(posix.STDIN_FILENO, posix.STDOUT_FILENO) catch |err| {
        try stderr.print("maru attach: terminal rejected ({s})\n", .{@errorName(err)});
        return .denied;
    };

    // **캐시가 아니라 런타임 base 다**(계약 §10). 앱이 host 를 그 자리에 등록하므로 CLI 도 같은
    // 자리를 봐야 한다 — `XDG_CACHE_HOME`/`~/.cache` 를 보던 때는 앱이 띄운 host 를 **한 번도
    // 못 찾았다**(`absent`). 경로의 단일 출처는 `short_endpoint` 다.
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base: []const u8 = short_endpoint.currentUserRootPathIn(&base_buf) catch {
        try stderr.writeAll("maru attach: persistent session host is unavailable\n");
        return .host_unavailable;
    };

    var prepared = switch (external_attach.prepare(allocator, io, base, request)) {
        .prepared => |value| value,
        .failed => |code| return code,
    };
    defer prepared.deinit();

    var owner: external_loop_owner.IntegratedStackOwner = .{};
    owner.prepareInPlace(
        &prepared,
        allocator,
        io,
        posix.STDIN_FILENO,
        posix.STDOUT_FILENO,
    ) catch |err| {
        try stderr.print("maru attach: terminal preparation failed ({s})\n", .{@errorName(err)});
        return prepareExit(err);
    };
    defer _ = owner.teardown();

    owner.commit() catch |err| {
        try stderr.print("maru attach: terminal activation failed ({s})\n", .{@errorName(err)});
        return commitExit(err);
    };
    const result = owner.run(io) catch |err| {
        try stderr.print("maru attach: session loop failed ({s})\n", .{@errorName(err)});
        return .internal;
    };
    if (!teardownClean(result.teardown)) {
        try stderr.writeAll("maru attach: terminal restoration failed\n");
        return .internal;
    }
    return runResultExit(result.cause, result.terminal_reason);
}

const TerminalPreflightError = error{
    InvalidInputTerminal,
    InvalidOutputTerminal,
    TerminalIdentityMismatch,
};

fn terminalPreflight(stdin_fd: c.fd_t, stdout_fd: c.fd_t) TerminalPreflightError!void {
    // `std.posix.tcgetattr` treats ENOTTY as an unexpected errno in Debug and prints a stack
    // trace before our typed catch can map it. Check the public predicate first so ordinary pipe
    // or redirected invocations remain a quiet denied exit rather than looking like a crash.
    if (c.isatty(stdin_fd) != 1) return error.InvalidInputTerminal;
    if (c.isatty(stdout_fd) != 1) return error.InvalidOutputTerminal;
    _ = external_tty.RawTty.inspect(stdin_fd) catch return error.InvalidInputTerminal;
    var output: external_tty_output.DedicatedOutput = .{};
    output.initInPlace(stdout_fd) catch return error.InvalidOutputTerminal;
    defer output.deinit();

    var input_stat: c.Stat = undefined;
    if (c.fstat(stdin_fd, &input_stat) != 0 or
        input_stat.mode & posix.S.IFMT != posix.S.IFCHR)
        return error.InvalidInputTerminal;
    if (input_stat.rdev != (output.ttyDevice() catch return error.InvalidOutputTerminal))
        return error.TerminalIdentityMismatch;
}

fn prepareExit(err: external_loop_owner.PrepareError) attach_cli.ExitCode {
    return switch (err) {
        error.TtyInspectionFailed,
        error.OutputRejected,
        error.InvalidSize,
        => .denied,
        else => .internal,
    };
}

fn commitExit(err: external_pump_owner.PreRawCommitError) attach_cli.ExitCode {
    return switch (err) {
        error.TerminalChanged, error.RawEnterFailed => .denied,
        else => .internal,
    };
}

fn teardownClean(result: external_pump_owner.PreRawTeardownResult) bool {
    return switch (result) {
        .cleaned, .already_dead => true,
        else => false,
    };
}

fn runResultExit(
    cause: external_loop_policy.CleanupCause,
    reason: ?client_pump.TerminalReason,
) attach_cli.ExitCode {
    return switch (cause) {
        .local_detach => .success,
        .revoked => .denied,
        .deadline => .protocol,
        .signal => .internal,
        .host_error => if (reason) |terminal| switch (terminal) {
            .eof, .socket_error => .host_unavailable,
            .runtime_ended => .runtime_not_found,
            .resource_exhausted => .busy,
            .revoked => .denied,
            .protocol_error,
            .request_id_exhausted,
            .deadline_exceeded,
            .invariant_failure,
            => .protocol,
        } else .protocol,
    };
}

test "p5c3c-3b public attach maps cleanup outcomes to stable exits" {
    try std.testing.expectEqual(attach_cli.ExitCode.success, runResultExit(.local_detach, null));
    try std.testing.expectEqual(attach_cli.ExitCode.denied, runResultExit(.revoked, .revoked));
    try std.testing.expectEqual(attach_cli.ExitCode.host_unavailable, runResultExit(.host_error, .eof));
    try std.testing.expectEqual(attach_cli.ExitCode.runtime_not_found, runResultExit(.host_error, .runtime_ended));
    try std.testing.expectEqual(attach_cli.ExitCode.busy, runResultExit(.host_error, .resource_exhausted));
    try std.testing.expectEqual(attach_cli.ExitCode.protocol, runResultExit(.deadline, .deadline_exceeded));
}
