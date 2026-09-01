//! macOS persistent session-host admin CLI 실행 facade.
//! main dispatcher와 분리해 cache/discovery/transport/typed-exit 정책을 한 경계에서 소유한다.

const std = @import("std");
const runtime_cli = @import("maru").cli.runtime;
const short_endpoint = @import("short_endpoint.zig");
const admin_client = @import("admin_client.zig");

pub fn runRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: runtime_cli.Request,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (rejectNonTtyWithoutConfirmation(request, std.c.isatty(0) == 1)) {
        try stderr.writeAll(runtime_cli.runtime_help);
        return exit(stdout, stderr, .usage);
    }
    const exe_raw = std.process.executablePathAlloc(io, allocator) catch {
        try stderr.writeAll("maru: cannot resolve the current executable\n");
        return exit(stdout, stderr, .protocol);
    };
    defer allocator.free(exe_raw);
    const exe = allocator.dupeZ(u8, exe_raw) catch return error.OutOfMemory;
    defer allocator.free(exe);
    // **캐시가 아니라 런타임 base 다**(계약 §10). 앱이 host 를 그 자리에 등록하므로 CLI 도 같은
    // 자리를 봐야 한다 — `XDG_CACHE_HOME`/`~/.cache` 를 보던 때는 앱이 띄운 host 를 **한 번도
    // 못 찾았다**(`absent`). 경로의 단일 출처는 `short_endpoint` 다.
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base: []const u8 = short_endpoint.currentUserRootPathIn(&base_buf) catch {
        try stderr.writeAll("maru: persistent session host is unavailable\n");
        return exit(stdout, stderr, .host_unavailable);
    };

    if (request == .runtime_end and !request.runtime_end.assume_yes) {
        var preview_call = try callCurrent(
            allocator,
            exe,
            base,
            .{ .runtime_get = .{
                .runtime_id = request.runtime_end.runtime_id,
                .output = .text,
            } },
            stderr,
            stdout,
            null,
        );
        defer preview_call.result.deinit(allocator);
        const meta = switch (preview_call.result) {
            .runtime_get => |value| value,
            else => unreachable,
        };
        const preview_host_id = preview_call.host_id;
        try stderr.print(
            "End runtime {s} ({d}x{d}, controller={s}, observers={d})? [y/N] ",
            .{
                &meta.runtime_id,
                meta.cols,
                meta.rows,
                if (meta.has_controller) "yes" else "no",
                meta.observer_count,
            },
        );
        try stderr.flush();
        if (!readConfirmation()) {
            try stderr.writeAll("\nmaru: runtime was not ended\n");
            return exit(stdout, stderr, .not_confirmed);
        }
        try stderr.writeByte('\n');
        try stderr.flush();
        var result_call = try callCurrent(
            allocator,
            exe,
            base,
            request,
            stderr,
            stdout,
            preview_host_id,
        );
        defer result_call.result.deinit(allocator);
        try runtime_cli.render(result_call.result, request.output(), stdout);
        try stdout.flush();
        return;
    }

    var result_call = try callCurrent(allocator, exe, base, request, stderr, stdout, null);
    defer result_call.result.deinit(allocator);
    // **`runtime get` 은 한 번 더 묻는다**(S11-6): 「누가 무엇을 선언했나」. `runtime.get` 의 응답
    // 모양은 adopt 가 쓰는 exact 재검증이라 넓히지 못한다 — 그래서 별도 조회다.
    if (request == .runtime_get) {
        if (tryViewports(allocator, exe, base, request.runtime_get.runtime_id)) |declared| {
            result_call.result.runtime_get.declared_len = declared.len;
            result_call.result.runtime_get.declared_total = declared.total;
            @memcpy(
                result_call.result.runtime_get.declared[0..declared.len],
                declared.view(),
            );
        }
    }
    try runtime_cli.render(result_call.result, request.output(), stdout);
    try stdout.flush();
}

/// **실패는 「선언이 없다」로 접는다.** 이 조회는 부가 정보라, 이것 때문에 `runtime get` 이 통째로
/// 지면 안 된다 — 이 명령을 모르는 옛 host 에 붙으면 실제로 그렇게 된다.
fn tryViewports(
    allocator: std.mem.Allocator,
    exe: [:0]const u8,
    base: []const u8,
    runtime_id: u128,
) ?runtime_cli.DeclaredViewports {
    var client = switch (admin_client.connectCurrent(allocator, exe, base)) {
        .connected => |value| value,
        .unavailable => return null,
    };
    defer client.deinit();
    const request: runtime_cli.Request = .{ .runtime_viewports = .{ .runtime_id = runtime_id } };
    const params = runtime_cli.paramsJson(allocator, request) catch return null;
    defer if (params) |owned| allocator.free(owned);
    const payload = client.call(request.method(), params) catch return null;
    defer allocator.free(payload);
    var remote: ?runtime_cli.RemoteError = null;
    var decoded = runtime_cli.decodeResponse(
        allocator,
        request,
        payload,
        null,
        &remote,
    ) catch return null;
    defer decoded.deinit(allocator);
    return switch (decoded) {
        .runtime_viewports => |value| value,
        else => null,
    };
}

const CallResult = struct {
    result: runtime_cli.Result,
    host_id: u128,
};

fn callCurrent(
    allocator: std.mem.Allocator,
    exe: [:0]const u8,
    base: []const u8,
    request: runtime_cli.Request,
    stderr: *std.Io.Writer,
    stdout: *std.Io.Writer,
    expected_host_id: ?u128,
) !CallResult {
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
    if (expected_host_id) |expected| {
        if (!samePreviewHost(expected, client.host_id)) {
            try stderr.writeAll("maru: persistent session host changed after confirmation\n");
            return exit(stdout, stderr, .host_unavailable);
        }
    }
    if (request == .runtime_end)
        client.requireAdminRuntimeEnd() catch |err| {
            try stderr.writeAll("maru: persistent session host does not support runtime end\n");
            return exit(stdout, stderr, runtimeEndCapabilityExit(err));
        };
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
    const result = runtime_cli.decodeResponse(
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
    return .{ .result = result, .host_id = client.host_id };
}

fn samePreviewHost(expected: u128, actual: u128) bool {
    return expected == actual;
}

fn rejectNonTtyWithoutConfirmation(request: runtime_cli.Request, is_tty: bool) bool {
    return request == .runtime_end and !request.runtime_end.assume_yes and !is_tty;
}

fn runtimeEndCapabilityExit(_: anyerror) runtime_cli.ExitCode {
    return .unsupported;
}

fn readConfirmation() bool {
    var input: [16]u8 = undefined;
    var used: usize = 0;
    while (used < input.len) {
        const count = std.c.read(0, input[used..].ptr, input.len - used);
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) continue;
            return false;
        }
        if (count == 0) break;
        const end = used + @as(usize, @intCast(count));
        if (std.mem.indexOfScalar(u8, input[used..end], '\n')) |offset| {
            used += offset + 1;
            return runtime_cli.confirmationAccepted(input[0..used]);
        }
        used = end;
    }
    return false;
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

test "interactive mutation authority is pinned to the preview host identity" {
    try std.testing.expect(samePreviewHost(0xAA, 0xAA));
    try std.testing.expect(!samePreviewHost(0xAA, 0xBB));
}

test "non-tty rejection and missing mutation capability are local pre-request exits" {
    const end: runtime_cli.Request = .{ .runtime_end = .{
        .runtime_id = 0xAA,
        .assume_yes = false,
    } };
    try std.testing.expect(rejectNonTtyWithoutConfirmation(end, false));
    try std.testing.expect(!rejectNonTtyWithoutConfirmation(end, true));
    try std.testing.expectEqual(
        runtime_cli.ExitCode.unsupported,
        runtimeEndCapabilityExit(error.IncompatibleVersion),
    );
}
