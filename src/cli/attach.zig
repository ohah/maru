//! Public `maru attach`의 OS-neutral policy boundary.
//! argv/role intent, canonical runtime id, deterministic resolver reduction and typed exit mapping만 소유한다.
//! TTY syscalls, manifest enumeration, socket transport and process exit are platform/main adapters.

const std = @import("std");
const host_protocol = @import("../session/host_protocol.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    internal = 1,
    usage = 2,
    host_unavailable = 3,
    denied = 4,
    unsupported = 5,
    busy = 6,
    runtime_not_found = 7,
    protocol = 8,
};

pub const Intent = enum {
    default_controller,
    read_only,
    take_over,
    /// 화면 레코드 스트림을 stdout 으로 흘린다(§8). observer 로 붙고 **ANSI 로 그리지 않는다** —
    /// 소비자가 터미널이 아니라 다른 maru 라서, 자를 이유도 폭을 두 번 해석할 이유도 없다.
    stream,
};

pub const Request = struct {
    runtime_id: u128,
    intent: Intent,
};

pub const Command = union(enum) {
    attach: Request,
    help,
};

pub const ParseError = error{
    MissingRuntimeId,
    InvalidRuntimeId,
    ConflictingOptions,
    DuplicateOption,
    UnknownOption,
    UnexpectedArgument,
};

pub const help =
    \\usage: maru attach [--read-only | --take-over | --stream] <32-lower-hex-runtime-id>
    \\
    \\Attach this terminal to an existing persistent runtime without starting a host.
    \\
    \\  --stream  observe and write the screen record stream to stdout instead of drawing it.
    \\
;

pub const Probe = enum {
    match,
    runtime_not_found,
    host_unavailable,
    denied,
    busy,
    protocol,
    out_of_memory,
};

pub const Resolution = union(enum) {
    selected: usize,
    failed: ExitCode,
};

pub const RemoteError = host_protocol.ErrorCode;

/// Public attach owns the stable process-exit policy; platform adapters only decode the canonical
/// typed wire error and delegate here.
pub fn remoteExitCode(code: RemoteError) ExitCode {
    return switch (code) {
        .host_unavailable, .stale_host, .host_shutting_down => .host_unavailable,
        .incompatible_version, .upgrade_unsupported => .unsupported,
        .unauthorized => .denied,
        .runtime_not_found => .runtime_not_found,
        .controller_busy, .invalid_generation, .upgrade_busy, .resource_exhausted => .busy,
        .internal => .internal,
        .invalid_request,
        .payload_too_large,
        .queue_invalidated,
        .attempt_conflict,
        .invalid_target,
        => .protocol,
    };
}

pub fn requestsController(intent: Intent) bool {
    return intent == .default_controller;
}

pub fn requiresTransfer(intent: Intent) bool {
    return intent == .take_over;
}

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingRuntimeId;
    if (isHelp(args[0])) {
        if (args.len != 1) return error.UnexpectedArgument;
        return .help;
    }

    var runtime_id: ?u128 = null;
    var intent: Intent = .default_controller;
    var option_seen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--read-only") or std.mem.eql(u8, arg, "--take-over") or
            std.mem.eql(u8, arg, "--stream"))
        {
            const next: Intent = if (std.mem.eql(u8, arg, "--read-only"))
                .read_only
            else if (std.mem.eql(u8, arg, "--take-over"))
                .take_over
            else
                .stream;
            if (option_seen) {
                if (intent == next) return error.DuplicateOption;
                return error.ConflictingOptions;
            }
            option_seen = true;
            intent = next;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        if (runtime_id != null) return error.UnexpectedArgument;
        runtime_id = parseRuntimeId(arg) orelse return error.InvalidRuntimeId;
    }
    return .{ .attach = .{
        .runtime_id = runtime_id orelse return error.MissingRuntimeId,
        .intent = intent,
    } };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn parseRuntimeId(text: []const u8) ?u128 {
    if (text.len != 32) return null;
    for (text) |byte|
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    const value = std.fmt.parseInt(u128, text, 16) catch return null;
    return if (value == 0) null else value;
}

pub fn resolve(probes: []const Probe) Resolution {
    if (probes.len == 0) return .{ .failed = .host_unavailable };

    var matches: usize = 0;
    var selected: usize = 0;
    var failure: ?ExitCode = null;
    for (probes, 0..) |probe, index| switch (probe) {
        .match => {
            matches += 1;
            selected = index;
        },
        .runtime_not_found => {},
        .host_unavailable => failure = strongerFailure(failure, .host_unavailable),
        .busy => failure = strongerFailure(failure, .busy),
        .protocol => failure = strongerFailure(failure, .protocol),
        .denied => failure = strongerFailure(failure, .denied),
        .out_of_memory => failure = strongerFailure(failure, .internal),
    };
    if (failure) |code| return .{ .failed = code };
    if (matches == 0) return .{ .failed = .runtime_not_found };
    if (matches != 1) return .{ .failed = .denied };
    return .{ .selected = selected };
}

fn strongerFailure(current: ?ExitCode, candidate: ExitCode) ExitCode {
    const current_code = current orelse return candidate;
    return if (failureRank(candidate) > failureRank(current_code)) candidate else current_code;
}

fn failureRank(code: ExitCode) u8 {
    return switch (code) {
        .internal => 5,
        .denied => 4,
        .protocol => 3,
        .busy => 2,
        .host_unavailable => 1,
        else => 0,
    };
}

test "attach parser accepts canonical id and each mutually exclusive intent" {
    const id_text = "0000000000000000000000000000002a";
    const plain = try parse(&.{id_text});
    try std.testing.expectEqual(Intent.default_controller, plain.attach.intent);
    try std.testing.expectEqual(@as(u128, 0x2a), plain.attach.runtime_id);

    const read_only = try parse(&.{ "--read-only", id_text });
    try std.testing.expectEqual(Intent.read_only, read_only.attach.intent);
    const take_over = try parse(&.{ id_text, "--take-over" });
    try std.testing.expectEqual(Intent.take_over, take_over.attach.intent);
}

test "attach parser rejects noncanonical ids, option conflicts, duplicates and extras" {
    try std.testing.expectError(error.MissingRuntimeId, parse(&.{}));
    try std.testing.expectError(error.InvalidRuntimeId, parse(&.{"2a"}));
    try std.testing.expectError(error.InvalidRuntimeId, parse(&.{"0000000000000000000000000000002A"}));
    try std.testing.expectError(error.InvalidRuntimeId, parse(&.{"00000000000000000000000000000000"}));
    try std.testing.expectError(
        error.ConflictingOptions,
        parse(&.{ "--read-only", "--take-over", "0000000000000000000000000000002a" }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parse(&.{ "--read-only", "--read-only", "0000000000000000000000000000002a" }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        parse(&.{ "--wat", "0000000000000000000000000000002a" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parse(&.{ "0000000000000000000000000000002a", "0000000000000000000000000000002b" }),
    );
}

test "attach help is exact and accepts only a standalone help option" {
    try std.testing.expect((try parse(&.{"--help"})) == .help);
    try std.testing.expect((try parse(&.{"-h"})) == .help);
    try std.testing.expectError(
        error.UnexpectedArgument,
        parse(&.{ "--help", "0000000000000000000000000000002a" }),
    );
    try std.testing.expectEqualStrings(
        "usage: maru attach [--read-only | --take-over | --stream] <32-lower-hex-runtime-id>\n\n" ++
            "Attach this terminal to an existing persistent runtime without starting a host.\n\n" ++
            "  --stream  observe and write the screen record stream to stdout instead of drawing it.\n",
        help,
    );
}

test "--stream 은 다른 역할 옵션과 배타이고 중복도 거부한다" {
    // 기존 셋과 **같은 규칙**을 타야 한다 — 새 옵션만 조용히 관대해지면 그 조합이 어떤 역할로
    // 붙는지 사용자가 예측할 수 없다.
    const id = "0000000000000000000000000000002a";
    const parsed = try parse(&.{ "--stream", id });
    try std.testing.expectEqual(Intent.stream, parsed.attach.intent);
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "--stream", "--stream", id }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "--stream", "--read-only", id }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "--take-over", "--stream", id }));
}

test "resolver reduction requires complete evidence and exactly one match" {
    try std.testing.expectEqual(ExitCode.host_unavailable, resolve(&.{}).failed);
    try std.testing.expectEqual(
        ExitCode.runtime_not_found,
        resolve(&.{ .runtime_not_found, .runtime_not_found }).failed,
    );
    try std.testing.expectEqual(@as(usize, 1), resolve(&.{ .runtime_not_found, .match }).selected);
    try std.testing.expectEqual(ExitCode.denied, resolve(&.{ .match, .match }).failed);
    try std.testing.expectEqual(ExitCode.busy, resolve(&.{ .match, .busy }).failed);
}

test "resolver inconclusive precedence is order independent" {
    const expected = [_]struct {
        probes: []const Probe,
        exit: ExitCode,
    }{
        .{ .probes = &.{ .host_unavailable, .busy }, .exit = .busy },
        .{ .probes = &.{ .busy, .protocol }, .exit = .protocol },
        .{ .probes = &.{ .protocol, .denied }, .exit = .denied },
        .{ .probes = &.{ .denied, .out_of_memory }, .exit = .internal },
    };
    for (expected) |case| {
        try std.testing.expectEqual(case.exit, resolve(case.probes).failed);
        var reversed: [2]Probe = .{ case.probes[1], case.probes[0] };
        try std.testing.expectEqual(case.exit, resolve(&reversed).failed);
    }
}

test "attach intent requests controller only for default and transfer only for takeover" {
    try std.testing.expect(requestsController(.default_controller));
    try std.testing.expect(!requestsController(.read_only));
    try std.testing.expect(!requestsController(.take_over));
    try std.testing.expect(!requiresTransfer(.default_controller));
    try std.testing.expect(!requiresTransfer(.read_only));
    try std.testing.expect(requiresTransfer(.take_over));
}

test "attach maps every canonical remote error to one stable exit" {
    const expected = [_]ExitCode{
        .host_unavailable, // host_unavailable
        .protocol, // invalid_request
        .unsupported, // incompatible_version
        .denied, // unauthorized
        .runtime_not_found,
        .host_unavailable, // stale_host
        .busy, // controller_busy
        .busy, // invalid_generation
        .protocol, // payload_too_large
        .protocol, // queue_invalidated
        .host_unavailable, // host_shutting_down
        .busy, // upgrade_busy
        .protocol, // attempt_conflict
        .unsupported, // upgrade_unsupported
        .protocol, // invalid_target
        .busy, // resource_exhausted
        .internal,
    };
    inline for (std.meta.fields(RemoteError)) |field| {
        const code: RemoteError = @enumFromInt(field.value);
        try std.testing.expectEqual(expected[field.value], remoteExitCode(code));
    }
}
