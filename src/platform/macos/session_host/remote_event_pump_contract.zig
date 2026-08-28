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

pub const Selection = struct {
    count: usize,
    /// Number of consecutive round-robin owners consumed from `cursor`. Priority owners do not
    /// advance this cursor, otherwise a continuously active stream could make quiet owners skip
    /// their only probe turn forever.
    round_robin_advanced: usize,
};

/// Builds one bounded frame after the owner at `cursor` has acted as the shared-connection probe.
/// The caller samples `priority` after that probe has demultiplexed readable wire input. Buffered
/// target streams take the remaining slots first; quiet owners then fill the unused slots in
/// round-robin order. No handle is selected twice and the retained-owner cap never changes.
pub fn selectAfterProbe(
    handles: []const u64,
    cursor: usize,
    priority: []const bool,
    out: []u64,
) BudgetError!Selection {
    if (handles.len == 0) return .{ .count = 0, .round_robin_advanced = 0 };
    if (handles.len != priority.len or cursor >= handles.len or out.len < @min(handles.len, max_owners_per_frame))
        return error.ResourceExhausted;
    const limit = @min(handles.len, max_owners_per_frame);
    out[0] = handles[cursor];
    var count: usize = 1;

    for (handles, priority, 0..) |handle, ready, index| {
        if (count == limit) break;
        if (!ready or index == cursor) continue;
        out[count] = handle;
        count += 1;
    }

    var round_robin_advanced: usize = 1;
    var offset: usize = 1;
    while (count < limit and offset < handles.len) : (offset += 1) {
        const index = (cursor + offset) % handles.len;
        if (priority[index]) continue;
        out[count] = handles[index];
        count += 1;
        round_robin_advanced = offset + 1;
    }
    return .{ .count = count, .round_robin_advanced = round_robin_advanced };
}

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

test "P4 E3c probe 뒤 준비된 owner는 같은 frame의 16 owner 안에서 우선된다" {
    var handles: [100]u64 = undefined;
    var priority = [_]bool{false} ** 100;
    for (&handles, 0..) |*handle, index| handle.* = index + 1;
    priority[99] = true;
    var selected: [max_owners_per_frame]u64 = undefined;
    const result = try selectAfterProbe(&handles, 0, &priority, &selected);
    try std.testing.expectEqual(@as(usize, max_owners_per_frame), result.count);
    try std.testing.expectEqual(@as(u64, 1), selected[0]);
    try std.testing.expectEqual(@as(u64, 100), selected[1]);
    try std.testing.expectEqual(@as(usize, 15), result.round_robin_advanced);
}

test "P4 E3c priority는 probe를 중복하지 않고 quiet frame은 기존 round-robin이다" {
    const handles = [_]u64{ 10, 20, 30, 40 };
    var selected: [max_owners_per_frame]u64 = undefined;
    const probe_ready = [_]bool{ false, true, false, false };
    const first = try selectAfterProbe(&handles, 1, &probe_ready, &selected);
    try std.testing.expectEqualSlices(u64, &.{ 20, 30, 40, 10 }, selected[0..first.count]);
    try std.testing.expectEqual(@as(usize, 4), first.round_robin_advanced);

    const quiet = [_]bool{false} ** handles.len;
    const second = try selectAfterProbe(&handles, 2, &quiet, &selected);
    try std.testing.expectEqualSlices(u64, &.{ 30, 40, 10, 20 }, selected[0..second.count]);
    try std.testing.expectEqual(@as(usize, 4), second.round_robin_advanced);
}
