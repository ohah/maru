//! macOS persistent session-host read CLI 실행 facade.
//! main dispatcher와 분리해 cache/discovery/transport/typed-exit 정책을 한 경계에서 소유한다.

const std = @import("std");
const runtime_cli = @import("maru").cli.runtime;
const admin_client = @import("admin_client.zig");

pub fn runRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: runtime_cli.Request,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const exe_raw = std.process.executablePathAlloc(io, allocator) catch {
        try stderr.writeAll("maru: cannot resolve the current executable\n");
        return exit(stdout, stderr, .protocol);
    };
    defer allocator.free(exe_raw);
    const exe = allocator.dupeZ(u8, exe_raw) catch return error.OutOfMemory;
    defer allocator.free(exe);
    const xdg = if (std.c.getenv("XDG_CACHE_HOME")) |value| std.mem.span(value) else null;
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else null;
    const base = (try runtime_cli.cacheBase(allocator, xdg, home)) orelse {
        try stderr.writeAll("maru: persistent session host is unavailable\n");
        return exit(stdout, stderr, .host_unavailable);
    };
    defer allocator.free(base);
    var client = switch (admin_client.connectCurrent(allocator, exe, base)) {
        .connected => |value| value,
        .unavailable => |reason| {
            if (reason == .out_of_memory) return error.OutOfMemory;
            const mapped = unavailableExit(reason).?;
            try stderr.print("maru: persistent session host {s}\n", .{@tagName(reason)});
            return exit(stdout, stderr, mapped);
        },
    };
    defer client.deinit();
    const params = try runtime_cli.paramsJson(allocator, request);
    defer if (params) |owned| allocator.free(owned);
    const payload = client.call(request.method(), params) catch |err| {
        const mapped: runtime_cli.ExitCode = switch (err) {
            error.EndpointAbsent => .host_unavailable,
            error.EndpointDenied, error.Unauthorized => .denied,
            error.IncompatibleVersion => .unsupported,
            error.AdminBusy => .busy,
            error.OutOfMemory => return error.OutOfMemory,
            else => .protocol,
        };
        try stderr.print("maru: persistent session host request failed ({s})\n", .{@errorName(err)});
        return exit(stdout, stderr, mapped);
    };
    defer allocator.free(payload);
    var remote_error: ?runtime_cli.RemoteError = null;
    var result = runtime_cli.decodeResponse(
        allocator,
        request,
        payload,
        .{
            .host_id = client.host_id,
            .build_id = client.build_id orelse {
                try stderr.writeAll("maru: malformed session host identity\n");
                return exit(stdout, stderr, .protocol);
            },
            .protocol_major = client.wire_major,
            .screen_codec_version = client.screen_codec_version,
            .upgrade_epoch = client.upgrade_epoch,
            .authority_generation = client.authority_generation,
            .lifecycle = client.lifecycle,
        },
        &remote_error,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Remote => {
            const code = remote_error orelse {
                try stderr.writeAll("maru: malformed session host response\n");
                return exit(stdout, stderr, .protocol);
            };
            try stderr.print("maru: session host rejected request ({s})\n", .{@tagName(code)});
            return exit(stdout, stderr, runtime_cli.remoteExitCode(code));
        },
        error.Malformed => {
            try stderr.writeAll("maru: malformed session host response\n");
            return exit(stdout, stderr, .protocol);
        },
    };
    defer result.deinit(allocator);
    try runtime_cli.render(result, request.output(), stdout);
    try stdout.flush();
}

fn unavailableExit(reason: admin_client.Unavailable) ?runtime_cli.ExitCode {
    return switch (reason) {
        .absent => .host_unavailable,
        .ambiguous, .protocol_error, .transient => .protocol,
        .denied => .denied,
        .unsupported => .unsupported,
        .busy => .busy,
        .out_of_memory => null,
    };
}

fn exit(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    code: runtime_cli.ExitCode,
) noreturn {
    stderr.flush() catch {};
    stdout.flush() catch {};
    std.process.exit(@intFromEnum(code));
}

test "post-discovery endpoint races are transport failures, not absent hosts" {
    try std.testing.expectEqual(runtime_cli.ExitCode.host_unavailable, unavailableExit(.absent).?);
    try std.testing.expectEqual(runtime_cli.ExitCode.protocol, unavailableExit(.transient).?);
    try std.testing.expectEqual(runtime_cli.ExitCode.protocol, unavailableExit(.ambiguous).?);
    try std.testing.expectEqual(runtime_cli.ExitCode.denied, unavailableExit(.denied).?);
    try std.testing.expect(unavailableExit(.out_of_memory) == null);
}
