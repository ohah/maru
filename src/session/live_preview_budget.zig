const std = @import("std");

pub const max_workers: usize = 8;
pub const max_source_bytes: usize = max_workers * 8 * 1024 * 1024;
pub const max_result_bytes: usize = max_workers * 2 * 1024 * 1024;

pub const Candidate = struct {
    surface_id: u64,
    priority: Priority,
};

pub const Priority = enum(u32) {
    visible = 1,
    focused = 2,
};

/// 앱 전역 라이브 프리뷰 desired-selection 정책. platform은 현재 보이는 후보만 제출하고, 이 모델은 포커스 후보를
/// 먼저 고른 뒤 직전 visible selection을 유지해 dictionary 순서 변화가 worker churn을 만들지 않게 한다.
/// 실제 running/enabling reservation과 revoke-first 전이는 Swift LivePreviewTransitionState가 소유한다.
/// worker별 8/2 MiB 상한과 max_workers를 곱한 값이 앱 전체 64/16 MiB hard cap이다.
pub const LivePreviewBudget = struct {
    selected: [max_workers]u64 = [_]u64{0} ** max_workers,
    selected_len: usize = 0,

    pub fn reconcile(self: *LivePreviewBudget, candidates: []const Candidate, out: []u64) usize {
        return self.reconcileMapped(candidates, struct {
            fn map(candidate: Candidate) Candidate {
                return candidate;
            }
        }.map, out);
    }

    pub fn reconcileMapped(self: *LivePreviewBudget, raw_candidates: anytype, mapper: anytype, out: []u64) usize {
        var next: [max_workers]u64 = [_]u64{0} ** max_workers;
        var next_len: usize = 0;

        appendMappedSorted(raw_candidates, mapper, .focused, &next, &next_len);
        for (self.selected[0..self.selected_len]) |surface_id| {
            if (candidatePriorityMapped(raw_candidates, mapper, surface_id) != null) appendUnique(&next, &next_len, surface_id);
        }
        appendMappedSorted(raw_candidates, mapper, null, &next, &next_len);

        self.selected = next;
        self.selected_len = next_len;
        const written = @min(out.len, next_len);
        @memcpy(out[0..written], next[0..written]);
        return written;
    }

    fn candidatePriorityMapped(raw_candidates: anytype, mapper: anytype, surface_id: u64) ?Priority {
        for (raw_candidates) |raw| {
            const candidate: Candidate = mapper(raw);
            if (candidate.surface_id == surface_id) return candidate.priority;
        }
        return null;
    }

    /// Swift dictionary iteration order must not decide which newly visible surfaces receive the remaining slots.
    /// At most eight selections are needed, so repeated minimum scans keep the policy deterministic and allocation-free.
    fn appendMappedSorted(raw_candidates: anytype, mapper: anytype, priority: ?Priority, out: *[max_workers]u64, len: *usize) void {
        while (len.* < max_workers) {
            var selected: ?u64 = null;
            for (raw_candidates) |raw| {
                const candidate: Candidate = mapper(raw);
                if (priority) |required| if (candidate.priority != required) continue;
                if (candidate.surface_id == 0 or contains(out, len.*, candidate.surface_id)) continue;
                if (selected == null or candidate.surface_id < selected.?) selected = candidate.surface_id;
            }
            appendUnique(out, len, selected orelse return);
        }
    }

    fn contains(out: *const [max_workers]u64, len: usize, surface_id: u64) bool {
        for (out[0..len]) |existing| if (existing == surface_id) return true;
        return false;
    }

    fn appendUnique(out: *[max_workers]u64, len: *usize, surface_id: u64) void {
        if (surface_id == 0 or len.* >= max_workers) return;
        for (out[0..len.*]) |existing| if (existing == surface_id) return;
        out[len.*] = surface_id;
        len.* += 1;
    }
};

test "live preview budget prioritizes focused and preserves visible selections" {
    var budget: LivePreviewBudget = .{};
    var out: [max_workers]u64 = undefined;
    var initial: [10]Candidate = undefined;
    for (&initial, 0..) |*candidate, index| candidate.* = .{ .surface_id = @intCast(index + 1), .priority = .visible };
    try std.testing.expectEqual(@as(usize, 8), budget.reconcile(&initial, &out));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);

    var refocused = initial;
    refocused[9].priority = .focused;
    try std.testing.expectEqual(@as(usize, 8), budget.reconcile(&refocused, &out));
    try std.testing.expectEqualSlices(u64, &.{ 10, 1, 2, 3, 4, 5, 6, 7 }, &out);
}

test "live preview budget caps imply global byte ceilings" {
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), max_source_bytes);
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), max_result_bytes);
}

test "live preview budget chooses new candidates deterministically without platform sorting" {
    var budget: LivePreviewBudget = .{};
    var out: [max_workers]u64 = undefined;
    const candidates = [_]Candidate{
        .{ .surface_id = 9, .priority = .visible },
        .{ .surface_id = 5, .priority = .focused },
        .{ .surface_id = 3, .priority = .visible },
        .{ .surface_id = 2, .priority = .focused },
    };
    try std.testing.expectEqual(@as(usize, 4), budget.reconcile(&candidates, &out));
    try std.testing.expectEqualSlices(u64, &.{ 2, 5, 3, 9 }, out[0..4]);
}
