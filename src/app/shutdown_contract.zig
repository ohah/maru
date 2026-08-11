//! 앱 종료가 backend 구현과 UI 조합 경계를 건널 때 공유하는 포인터 없는 값 계약이다.

const std = @import("std");
const compatibility = @import("session_host_compatibility");
const wire = @import("shutdown_wire_contract");

pub const Digest = wire.Digest;
pub const zero_digest = wire.zero_digest;
pub const ShutdownOperation = wire.ShutdownOperation;
pub const InventoryAttempt = wire.InventoryAttempt;
pub const ShutdownAttemptKey = wire.ShutdownAttemptKey;
pub const ShutdownConnectionReceipt = wire.ShutdownConnectionReceipt;
pub const PreConnectionReason = wire.PreConnectionReason;
pub const PostConnectionReason = wire.PostConnectionReason;
pub const BoundedUnconfirmed = wire.BoundedUnconfirmed;
pub const ShutdownAdminOutcome = wire.ShutdownAdminOutcome;

pub const ShutdownProfile = compatibility.ShutdownProfile;

pub const ShutdownDiagnosticReason = wire.ShutdownDiagnosticReason;
pub const ShutdownElapsedBucket = wire.ShutdownElapsedBucket;
pub const ShutdownDiagnostic = wire.ShutdownDiagnostic;
pub const bucketShutdownElapsed = wire.bucketShutdownElapsed;

fn recursivelyPointerFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .optional, .error_union, .@"fn" => false,
        .array => |info| recursivelyPointerFree(info.child),
        .@"struct" => |info| blk: {
            for (info.fields) |field| if (!recursivelyPointerFree(field.type)) break :blk false;
            break :blk true;
        },
        .@"union" => |info| blk: {
            for (info.fields) |field| if (!recursivelyPointerFree(field.type)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

test "C3-3b6 중립 계약의 operation과 inventory 조합은 닫힌 enum만 허용한다" {
    try std.testing.expectEqual(2, @typeInfo(ShutdownOperation).@"enum".fields.len);
    try std.testing.expectEqual(3, @typeInfo(InventoryAttempt).@"enum".fields.len);
}

test "C3-3b6 중립 계약의 ShutdownAttemptKey는 exact target과 attempt만 담는 포인터 없는 값이다" {
    try std.testing.expect(comptime recursivelyPointerFree(ShutdownAttemptKey));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ShutdownAttemptKey));
}

test "C3-3b6 중립 계약의 ShutdownConnectionReceipt는 connection과 GUI lease를 포인터 없이 결속한다" {
    try std.testing.expect(comptime recursivelyPointerFree(ShutdownConnectionReceipt));
    try std.testing.expect(@offsetOf(ShutdownConnectionReceipt, "lease_generation") > @offsetOf(ShutdownConnectionReceipt, "connection_identity"));
}

test "C3-3b6 중립 계약의 bounded_unconfirmed은 connection 전후 evidence를 서로 바꾸지 못한다" {
    try std.testing.expectEqual(3, @typeInfo(PreConnectionReason).@"enum".fields.len);
    try std.testing.expectEqual(4, @typeInfo(PostConnectionReason).@"enum".fields.len);
    try std.testing.expectEqual(2, @typeInfo(BoundedUnconfirmed).@"union".fields.len);
}

test "C3-3b6 중립 계약의 ShutdownAdminOutcome은 여덟 terminal과 진행 상태만 허용한다" {
    try std.testing.expectEqual(8, @typeInfo(ShutdownAdminOutcome).@"union".fields.len);
    try std.testing.expect(comptime recursivelyPointerFree(ShutdownAdminOutcome));
}

test "C3-3b6 중립 계약의 N-1 shutdown profile은 artifact와 capability boolean을 exact field로 고정한다" {
    try std.testing.expectEqual(5, @typeInfo(ShutdownProfile).@"struct".fields.len);
    try std.testing.expect(comptime recursivelyPointerFree(ShutdownProfile));
}

test "C3-3b6 중립 계약의 shutdown diagnostic은 식별자와 문자열을 싣지 않는 포인터 없는 DTO다" {
    try std.testing.expect(comptime recursivelyPointerFree(ShutdownDiagnostic));
    try std.testing.expectEqual(5, @typeInfo(ShutdownDiagnostic).@"struct".fields.len);
}

test "C3-3b6 중립 계약의 elapsed bucket은 다섯 경계 전후와 clock regression을 닫는다" {
    const ms = std.time.ns_per_ms;
    const s = std.time.ns_per_s;
    try std.testing.expectEqual(ShutdownElapsedBucket.lt100ms, bucketShutdownElapsed(9, 10));
    const boundaries = [_]struct { value: u64, before: ShutdownElapsedBucket, after: ShutdownElapsedBucket }{
        .{ .value = 100 * ms, .before = .lt100ms, .after = .lt500ms },
        .{ .value = 500 * ms, .before = .lt500ms, .after = .lt1s },
        .{ .value = s, .before = .lt1s, .after = .lt5s },
        .{ .value = 5 * s, .before = .lt5s, .after = .lt15s },
        .{ .value = 15 * s, .before = .lt15s, .after = .ge15s },
    };
    for (boundaries) |row| {
        try std.testing.expectEqual(row.before, bucketShutdownElapsed(row.value - 1, 0));
        try std.testing.expectEqual(row.after, bucketShutdownElapsed(row.value, 0));
        try std.testing.expectEqual(row.after, bucketShutdownElapsed(row.value + 1, 0));
    }
    try std.testing.expectEqual(ShutdownElapsedBucket.ge15s, bucketShutdownElapsed(std.math.maxInt(u64), 0));
}
