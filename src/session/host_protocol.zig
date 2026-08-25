//! OS-중립 session-host wire 정책의 단일 출처.
//! macOS transport protocol과 public CLI DTO가 함께 소비하는 typed error/응답 상한만 둔다.

const std = @import("std");

pub const max_inventory_runtimes: usize = 4096;
pub const max_control_json: usize = 256 * 1024;
/// `runtime.list`/`runtime.get` 이 싣는 window title 의 상한(§8). 원격이 정하는 임의 길이 문자열을
/// 그대로 실으면 inventory 응답 하나가 프레임 예산을 흔든다. **자를 때는 UTF-8 경계를 지킨다.**
pub const max_title_bytes: usize = 128;

pub const ErrorCode = enum {
    host_unavailable,
    invalid_request,
    incompatible_version,
    unauthorized,
    runtime_not_found,
    stale_host,
    controller_busy,
    invalid_generation,
    payload_too_large,
    queue_invalidated,
    host_shutting_down,
    upgrade_busy,
    attempt_conflict,
    upgrade_unsupported,
    invalid_target,
    resource_exhausted,
    internal,

    pub fn wireName(self: ErrorCode) []const u8 {
        return @tagName(self);
    }

    pub fn fromWireName(name: []const u8) ?ErrorCode {
        inline for (@typeInfo(ErrorCode).@"enum".fields) |field|
            if (std.mem.eql(u8, name, field.name))
                return @enumFromInt(field.value);
        return null;
    }
};

test "session host error wire names round trip exhaustively" {
    inline for (@typeInfo(ErrorCode).@"enum".fields) |field| {
        const code: ErrorCode = @enumFromInt(field.value);
        try std.testing.expectEqual(code, ErrorCode.fromWireName(code.wireName()).?);
    }
    try std.testing.expect(ErrorCode.fromWireName("future_error") == null);
}
