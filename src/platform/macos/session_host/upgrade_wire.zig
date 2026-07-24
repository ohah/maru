//! `host.upgrade.prepare/status`의 OS-중립 typed 계약.
//!
//! Server는 JSON을 이 DTO로 정규화하고 daemon owner에게 borrowed view를 넘긴다. Owner는 accepted를 반환하기 전에
//! 필요한 문자열을 복사해야 한다. 실제 quiesce/exec는 reply-and-close 뒤 daemon loop가 pending attempt를 take한 후다.

const std = @import("std");
const limits = @import("upgrade_limits.zig");

pub const max_target_path_bytes = limits.max_target_path_bytes;
pub const max_build_id_bytes = limits.max_build_id_bytes;

pub const PrepareRequest = struct {
    attempt_id: u128,
    target_path: []const u8,
    target_build_id: []const u8,
    target_sha256: [32]u8,
    handoff_reader_min: u16,
    handoff_reader_max: u16,
};

pub const AttemptStatus = enum {
    pending,
    resumed,
    rolled_back,
    committed,
    failed_nonretryable,
};

pub const AttemptReason = enum {
    none,
    exec_failed,
    restore_failed,
    rollback_exec_failed,
    promotion_failed,
    target_invalid,
    runtime_changed,
    handoff_failed,
    state_too_large,
    deadline_exceeded,
    authority_poisoned,
    runtime_resume_failed,
};

pub const AttemptReport = struct {
    status: AttemptStatus,
    reason: AttemptReason = .none,
};

pub const PrepareDecision = union(enum) {
    accepted,
    completed: AttemptReport,
    busy,
    conflict,
    unsupported,
    invalid_target,
    resource_exhausted,
};

pub const ArmDecision = enum {
    armed,
    not_pending,
    conflict,
};

pub const Ops = struct {
    ctx: *anyopaque,
    /// Admission lease 안에서는 target 검증/복사와 pending metadata 게시까지만 한다. Quiesce는 accepted reply가 전량
    /// write되고 connection lease가 해제된 뒤 daemon outer loop가 시작해야 한다.
    stage_pending: *const fn (ctx: *anyopaque, request: PrepareRequest) PrepareDecision,
    /// accepted response가 완성되기 전 write 실패 시 `.staged` reservation을 회수한다.
    cancel_unaccepted: *const fn (ctx: *anyopaque, attempt_id: u128) void,
    /// accepted response 전량 write 뒤 exact pending attempt만 실행 가능 상태로 바꾼다. Quiesce/exec는 하지 않는다.
    arm_accepted: *const fn (ctx: *anyopaque, attempt_id: u128) ArmDecision,
    status: *const fn (ctx: *anyopaque, attempt_id: u128) ?AttemptReport,
};

pub fn validReport(report: AttemptReport) bool {
    return switch (report.status) {
        .pending => report.reason == .none,
        .committed => report.reason == .none or report.reason == .promotion_failed,
        .resumed => switch (report.reason) {
            .exec_failed, .target_invalid, .runtime_changed, .handoff_failed, .state_too_large, .deadline_exceeded => true,
            else => false,
        },
        .rolled_back => report.reason == .restore_failed or report.reason == .target_invalid,
        .failed_nonretryable => report.reason == .rollback_exec_failed or
            report.reason == .authority_poisoned or
            report.reason == .runtime_resume_failed,
    };
}

pub fn parsePrepare(params: std.json.ObjectMap) ?PrepareRequest {
    if (params.count() != 6) return null;
    const attempt_raw = stringField(params, "attempt_id") orelse return null;
    const attempt_id = parseLowerHex128(attempt_raw) orelse return null;
    const target_path = stringField(params, "target_path") orelse return null;
    if (target_path.len == 0 or target_path.len > max_target_path_bytes or target_path[0] != '/' or
        std.mem.indexOfScalar(u8, target_path, 0) != null)
        return null;
    const target_build_id = stringField(params, "target_build_id") orelse return null;
    if (target_build_id.len == 0 or target_build_id.len > max_build_id_bytes or
        std.mem.indexOfScalar(u8, target_build_id, 0) != null)
        return null;
    const sha_raw = stringField(params, "target_sha256") orelse return null;
    const target_sha256 = parseLowerHex256(sha_raw) orelse return null;
    const reader_min = unsigned16(params, "handoff_reader_min") orelse return null;
    const reader_max = unsigned16(params, "handoff_reader_max") orelse return null;
    if (reader_min == 0 or reader_min > reader_max) return null;
    return .{
        .attempt_id = attempt_id,
        .target_path = target_path,
        .target_build_id = target_build_id,
        .target_sha256 = target_sha256,
        .handoff_reader_min = reader_min,
        .handoff_reader_max = reader_max,
    };
}

pub fn parseStatus(params: std.json.ObjectMap) ?u128 {
    if (params.count() != 1) return null;
    return parseLowerHex128(stringField(params, "attempt_id") orelse return null);
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn unsigned16(obj: std.json.ObjectMap, name: []const u8) ?u16 {
    const raw = switch (obj.get(name) orelse return null) {
        .integer => |value| value,
        else => return null,
    };
    return std.math.cast(u16, raw);
}

fn parseLowerHex128(raw: []const u8) ?u128 {
    if (raw.len != 32 or !isLowerHex(raw)) return null;
    return std.fmt.parseInt(u128, raw, 16) catch null;
}

fn parseLowerHex256(raw: []const u8) ?[32]u8 {
    if (raw.len != 64 or !isLowerHex(raw)) return null;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return null;
    return result;
}

fn isLowerHex(raw: []const u8) bool {
    for (raw) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test "upgrade prepare parser accepts one exact bounded request and rejects ambiguity" {
    const allocator = std.testing.allocator;
    const good =
        \\{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, good, .{});
    defer parsed.deinit();
    const request = parsePrepare(parsed.value.object).?;
    try std.testing.expectEqual(@as(u128, 0xAABB), request.attempt_id);
    try std.testing.expectEqual(@as(u16, 1), request.handoff_reader_min);

    const extra =
        \\{"attempt_id":"0000000000000000000000000000aabb","target_path":"/x","target_build_id":"b","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1,"extra":true}
    ;
    var extra_parsed = try std.json.parseFromSlice(std.json.Value, allocator, extra, .{});
    defer extra_parsed.deinit();
    try std.testing.expect(parsePrepare(extra_parsed.value.object) == null);
}
