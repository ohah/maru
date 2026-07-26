//! OS-중립 session-host wire 정책의 단일 출처.
//! macOS transport protocol과 public CLI DTO가 함께 소비하는 typed error/응답 상한만 둔다.

const std = @import("std");

pub const max_inventory_runtimes: usize = 4096;

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
