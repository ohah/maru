//! Session-host 제품 프로세스로 진입하는 hidden CLI command의 OS-중립 단일 출처.
//!
//! launcher와 `main.zig` dispatch가 같은 값을 import해야 `maru <socket>`처럼 command가 빠지거나 양쪽 문자열이
//! 서로 달라지는 회귀를 만들지 않는다. Upgrade argv도 producer와 consumer가 문자열을 따로 해석하지 않도록
//! strict tagged invocation으로 여기서 한 번만 파싱한다.

const std = @import("std");
const upgrade_fd_layout = @import("upgrade_fd_layout.zig");

pub const subcommand = "__session-host";
pub const upgrade_preflight_flag = "--upgrade-preflight";
pub const upgrade_restore_flag = "--upgrade-restore";
pub const release_compatibility_flag = "--release-compatibility";
pub const target_role = "target";
pub const rollback_role = "rollback";
pub const preflight_fd_arg = "3";
pub const preflight_fd: i32 = std.fmt.parseInt(i32, preflight_fd_arg, 10) catch
    @compileError("session-host preflight fd literal must stay a valid descriptor");
pub const max_invocation_args: usize = 7;

pub const RestoreRole = enum { target, rollback };

pub const DaemonInvocation = struct {
    session_dir: []const u8,
    socket_path: []const u8,
    host_id: u128,
};

pub const RestoreInvocation = struct {
    role: RestoreRole,
    session_dir: []const u8,
    socket_path: []const u8,
    host_id: u128,
    attempt_id: u128,
    layout: upgrade_fd_layout.Layout,

    pub fn primarySlot(self: RestoreInvocation) i32 {
        return self.layout.primarySlot();
    }

    pub fn backupSlot(self: RestoreInvocation) i32 {
        return self.layout.backupSlot();
    }

    pub fn ownerSlot(self: RestoreInvocation) i32 {
        return self.layout.ownerSlot();
    }
};

pub const Invocation = union(enum) {
    daemon: DaemonInvocation,
    preflight,
    release_compatibility,
    restore: RestoreInvocation,
};

pub const ParseError = error{InvalidInvocation};

pub const RestoreArgBuffers = struct {
    host_id: [32]u8 = undefined,
    attempt_id: [32]u8 = undefined,
    first_runtime_slot: [5]u8 = undefined,
};

/// Destructive executor가 raw argv 의미를 재구현하지 않도록 typed invocation을 parser의 exact 7개 grammar로 만든다.
pub fn formatRestoreArgs(
    invocation: RestoreInvocation,
    buffers: *RestoreArgBuffers,
) ParseError![max_invocation_args][]const u8 {
    if (!invocation.layout.valid() or invocation.host_id == 0) return error.InvalidInvocation;
    _ = try absolutePath(invocation.session_dir);
    _ = try absolutePath(invocation.socket_path);
    const host_id = std.fmt.bufPrint(&buffers.host_id, "{x:0>32}", .{invocation.host_id}) catch
        return error.InvalidInvocation;
    const attempt_id = std.fmt.bufPrint(&buffers.attempt_id, "{x:0>32}", .{invocation.attempt_id}) catch
        return error.InvalidInvocation;
    const first = std.fmt.bufPrint(
        &buffers.first_runtime_slot,
        "{d}",
        .{invocation.layout.first_runtime_slot},
    ) catch return error.InvalidInvocation;
    return .{
        upgrade_restore_flag,
        if (invocation.role == .target) target_role else rollback_role,
        invocation.session_dir,
        invocation.socket_path,
        host_id,
        attempt_id,
        first,
    };
}

/// `maru __session-host` 뒤 argv를 전량 받은 strict parser. 남는 인자, uppercase/짧은 ID, 상대 경로,
/// overflow slot은 모두 거부해 main·executor·restore bootstrap이 같은 의미를 소비하게 한다.
pub fn parse(args: []const []const u8) ParseError!Invocation {
    if (args.len == 1 and std.mem.eql(u8, args[0], release_compatibility_flag))
        return .release_compatibility;
    if (args.len == 2 and std.mem.eql(u8, args[0], upgrade_preflight_flag) and
        std.mem.eql(u8, args[1], preflight_fd_arg))
        return .preflight;
    if (args.len == 3) return .{ .daemon = .{
        .session_dir = try absolutePath(args[0]),
        .socket_path = try absolutePath(args[1]),
        .host_id = try lowerHexId(args[2], false),
    } };
    if (args.len == 7 and std.mem.eql(u8, args[0], upgrade_restore_flag)) {
        const role: RestoreRole = if (std.mem.eql(u8, args[1], target_role))
            .target
        else if (std.mem.eql(u8, args[1], rollback_role))
            .rollback
        else
            return error.InvalidInvocation;
        const first = std.fmt.parseInt(i64, args[6], 10) catch return error.InvalidInvocation;
        const layout = upgrade_fd_layout.Layout.init(first) catch return error.InvalidInvocation;
        return .{ .restore = .{
            .role = role,
            .session_dir = try absolutePath(args[2]),
            .socket_path = try absolutePath(args[3]),
            .host_id = try lowerHexId(args[4], false),
            .attempt_id = try lowerHexId(args[5], true),
            .layout = layout,
        } };
    }
    return error.InvalidInvocation;
}

fn absolutePath(value: []const u8) ParseError![]const u8 {
    if (value.len == 0 or value[0] != '/' or std.mem.indexOfScalar(u8, value, 0) != null or
        !std.unicode.utf8ValidateSlice(value))
        return error.InvalidInvocation;
    return value;
}

fn lowerHexId(value: []const u8, allow_zero: bool) ParseError!u128 {
    if (value.len != 32) return error.InvalidInvocation;
    for (value) |byte|
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
            return error.InvalidInvocation;
    const id = std.fmt.parseInt(u128, value, 16) catch return error.InvalidInvocation;
    if (!allow_zero and id == 0) return error.InvalidInvocation;
    return id;
}

test "session host entrypoint strictly parses daemon preflight and restore roles" {
    const daemon = try parse(&.{
        "/tmp/maru-session",
        "/tmp/maru-session/control.sock",
        "000000000000000000000000000000aa",
    });
    try std.testing.expectEqual(@as(u128, 0xAA), daemon.daemon.host_id);
    try std.testing.expect((try parse(&.{ upgrade_preflight_flag, preflight_fd_arg })) == .preflight);
    try std.testing.expect((try parse(&.{release_compatibility_flag})) == .release_compatibility);
    const target = try parse(&.{
        upgrade_restore_flag,
        target_role,
        "/tmp/maru-session",
        "/tmp/maru.sock",
        "000000000000000000000000000000aa",
        "000000000000000000000000000000bb",
        "40",
    });
    try std.testing.expectEqual(RestoreRole.target, target.restore.role);
    try std.testing.expectEqual(@as(i32, 296), target.restore.primarySlot());
    try std.testing.expectEqual(@as(i32, 298), target.restore.ownerSlot());
    const zero_attempt = try parse(&.{
        upgrade_restore_flag,
        target_role,
        "/tmp/maru-session",
        "/tmp/maru.sock",
        "000000000000000000000000000000aa",
        "00000000000000000000000000000000",
        "40",
    });
    try std.testing.expectEqual(@as(u128, 0), zero_attempt.restore.attempt_id);
    var buffers: RestoreArgBuffers = .{};
    const formatted = try formatRestoreArgs(zero_attempt.restore, &buffers);
    const reparsed = try parse(&formatted);
    try std.testing.expectEqual(RestoreRole.target, reparsed.restore.role);
    try std.testing.expectEqual(@as(u128, 0), reparsed.restore.attempt_id);
    try std.testing.expectEqual(zero_attempt.restore.layout.first_runtime_slot, reparsed.restore.layout.first_runtime_slot);
}

test "session host entrypoint rejects drifted roles ids paths slots and trailing argv" {
    for ([_][]const []const u8{
        &.{ upgrade_preflight_flag, "4" },
        &.{ "relative", "/tmp/socket", "000000000000000000000000000000aa" },
        &.{ "/tmp/dir", "/tmp/socket", "000000000000000000000000000000AA" },
        &.{ upgrade_restore_flag, "other", "/tmp/dir", "/tmp/socket", "000000000000000000000000000000aa", "000000000000000000000000000000bb", "40" },
        &.{ upgrade_restore_flag, target_role, "/tmp/dir", "/tmp/socket", "000000000000000000000000000000aa", "000000000000000000000000000000bb", "2" },
        &.{ upgrade_restore_flag, target_role, "/tmp/dir", "/tmp/socket", "000000000000000000000000000000aa", "000000000000000000000000000000bb", "65278" },
        &.{ "/tmp/dir", "/tmp/socket", "000000000000000000000000000000aa", "extra" },
    }) |invalid|
        try std.testing.expectError(error.InvalidInvocation, parse(invalid));
}
