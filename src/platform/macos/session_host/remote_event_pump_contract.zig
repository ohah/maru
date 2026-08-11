//! 원격 generation event pump가 제품 계층에 전달하는 bounded 진행 계약이다.
//!
//! event settlement의 `Busy`를 종료나 일반 오류로 접지 않고 다음 frame의 재시도 권위로 남기며,
//! 한 frame이 보유할 수 있는 owner 수와 retained byte 상한을 같은 중립 상수에서 계산한다.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const max_owners_per_frame: usize = 16;
pub const retained_parts_per_owner: usize = 3;

pub const EventDrain = struct {
    metadata: bool = false,
    ended: bool = false,
};

pub const ProgressTag = enum(u8) {
    idle,
    event_pending,
    drained,
    ended,
};

pub const Progress = union(ProgressTag) {
    idle,
    event_pending,
    drained: EventDrain,
    ended,
};

pub const Budget = struct {
    owner_count: usize,
    retained_bytes: usize,
};

pub const BudgetError = error{ResourceExhausted};

pub fn frameBudget(owner_count: usize, retained_bytes: usize) BudgetError!Budget {
    if (owner_count > max_owners_per_frame) return error.ResourceExhausted;
    const per_owner = std.math.mul(
        usize,
        retained_parts_per_owner,
        protocol.max_control_json,
    ) catch return error.ResourceExhausted;
    const maximum = std.math.mul(usize, max_owners_per_frame, per_owner) catch
        return error.ResourceExhausted;
    if (retained_bytes > maximum) return error.ResourceExhausted;
    return .{ .owner_count = owner_count, .retained_bytes = retained_bytes };
}

pub fn nextCursor(current: usize, owner_count: usize, advanced: usize) BudgetError!usize {
    if (owner_count == 0) return 0;
    if (current >= owner_count or advanced > max_owners_per_frame) return error.ResourceExhausted;
    return (current + advanced) % owner_count;
}

test "C3-3b4 중립 pump 계약은 idle progress를 닫힌 값으로 표현한다" {
    const progress: Progress = .idle;
    try std.testing.expectEqual(ProgressTag.idle, std.meta.activeTag(progress));
}

test "C3-3b4 중립 pump 계약은 event_pending을 종료와 구분한다" {
    const pending: Progress = .event_pending;
    const ended: Progress = .ended;
    try std.testing.expect(std.meta.activeTag(pending) != std.meta.activeTag(ended));
}

test "C3-3b4 중립 pump 계약은 drained 결과만 EventDrain을 운반한다" {
    const progress: Progress = .{ .drained = .{ .metadata = true } };
    try std.testing.expect(progress.drained.metadata);
    try std.testing.expect(!progress.drained.ended);
}

test "C3-3b4 중립 pump 계약은 ended를 의미 성공과 구분한다" {
    const ended: Progress = .ended;
    try std.testing.expectEqual(ProgressTag.ended, std.meta.activeTag(ended));
    try std.testing.expect(std.meta.activeTag(ended) != std.meta.activeTag(Progress{ .drained = .{} }));
}

test "C3-3b4 중립 pump 계약은 frame retained budget을 checked 계산한다" {
    const maximum = max_owners_per_frame * retained_parts_per_owner * protocol.max_control_json;
    try std.testing.expectEqual(maximum, (try frameBudget(max_owners_per_frame, maximum)).retained_bytes);
    try std.testing.expectError(error.ResourceExhausted, frameBudget(max_owners_per_frame, maximum + 1));
}

test "C3-3b4 중립 pump 계약은 round-robin cursor의 16 owner 상한을 고정한다" {
    try std.testing.expectEqual(@as(usize, 16), try nextCursor(0, 17, max_owners_per_frame));
    try std.testing.expectError(error.ResourceExhausted, nextCursor(0, 17, max_owners_per_frame + 1));
}
