//! 입력 편집과 적용된 결과의 수명. 시간·요청 신원은 앱이 주입하고 I/O는 다루지 않는다.
const std = @import("std");
const request = @import("request.zig");
const results = @import("results.zig");
pub const debounce_ms: u64 = 300;
pub const Phase = enum { idle, waiting, composing, running, complete, cancelled, partial, failed };
pub const State = struct {
    model: results.Model = .{},
    generation: u64 = 1,
    identity: ?request.Identity = null,
    phase: Phase = .idle,
    due_ms: ?u64 = null,
    excluded: usize = 0,
    failure: ?anyerror = null,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.model.deinit(a);
        self.* = .{};
    }
    /// 이전 입력으로 계산한 결과와 그 클릭 신원부터 폐기한다. 취소 중 worker는 앱이 수거한다.
    pub fn invalidate(self: *State, a: std.mem.Allocator) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.identity = null;
        self.due_ms = null;
        self.model.deinit(a);
        self.excluded = 0;
        self.failure = null;
        self.phase = .idle;
    }
    pub fn changed(self: *State, a: std.mem.Allocator, now_ms: u64, nonempty: bool) void {
        self.invalidate(a);
        if (!nonempty) return;
        self.phase = .waiting;
        self.due_ms = now_ms +| debounce_ms;
    }
    /// 조합 문자열은 확정 검색어로 취급하지 않는다. clear 콜백도 확정 신호를 대신할 수 없다.
    pub fn preedit(self: *State, a: std.mem.Allocator) void {
        self.invalidate(a);
        self.phase = .composing;
    }
    pub fn ready(self: *const State, now_ms: u64, input_transaction: bool) bool {
        if (input_transaction or self.phase != .waiting) return false;
        return if (self.due_ms) |due| now_ms >= due else false;
    }
    pub fn begin(self: *State, a: std.mem.Allocator, identity: request.Identity) void {
        self.invalidate(a);
        self.identity = identity;
        self.phase = .running;
    }
    pub fn accepts(self: *const State, identity: request.Identity) bool {
        return self.phase == .running and self.identity != null and std.meta.eql(self.identity.?, identity);
    }
    /// 소유권은 성공할 때만 넘어온다. stale 행을 해제하는 것은 batch 소유자의 책임이다.
    pub fn append(self: *State, a: std.mem.Allocator, identity: request.Identity, row: request.Row) !bool {
        if (!self.accepts(identity)) return false;
        self.model.append(a, row) catch |err| {
            self.invalidate(a);
            self.phase = .failed;
            self.failure = err;
            return err;
        };
        return true;
    }
    /// visible 인덱스가 실패하면 표시와 입력을 함께 폐기한다. 불완전한 행 표는 공개하지 않는다.
    pub fn publish(self: *State, a: std.mem.Allocator) !void {
        self.model.rebuild(a) catch |err| {
            self.invalidate(a);
            self.phase = .failed;
            self.failure = err;
            return err;
        };
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
    pub fn finish(self: *State, identity: request.Identity, status: request.Status, excluded: usize, failure: ?anyerror) bool {
        if (!self.accepts(identity) or status == .running) return false;
        self.phase = switch (status) {
            .running => unreachable,
            .complete => .complete,
            .cancelled => .cancelled,
            .partial => .partial,
            .failed => .failed,
        };
        self.excluded = excluded;
        self.failure = failure;
        return true;
    }
    pub fn cancel(self: *State, a: std.mem.Allocator) void {
        self.invalidate(a);
        self.phase = .cancelled;
    }
};
const first: request.Identity = .{ .request = 1, .root = 2, .models = 3 };
test "project search dock debounce restarts on editing and respects IME transaction" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.changed(std.testing.allocator, 100, true);
    try std.testing.expect(!state.ready(399, false));
    try std.testing.expect(state.ready(400, false));
    try std.testing.expect(!state.ready(400, true));
    state.changed(std.testing.allocator, 390, true);
    try std.testing.expect(!state.ready(400, false));
    try std.testing.expect(state.ready(690, false));
    state.changed(std.testing.allocator, 700, false);
    try std.testing.expect(!state.ready(1000, false));
}
test "project search dock preedit Enter cannot start a search before confirmed change" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.changed(std.testing.allocator, 100, true);
    state.preedit(std.testing.allocator);
    try std.testing.expect(!state.ready(10000, false));
    state.changed(std.testing.allocator, 10000, true);
    try std.testing.expect(!state.ready(10299, false));
    try std.testing.expect(state.ready(10300, false));
}
test "project search dock late completion cannot revive cancelled or edited results" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(std.testing.allocator, first);
    const generation = state.generation;
    state.changed(std.testing.allocator, 0, true);
    try std.testing.expect(state.generation != generation);
    try std.testing.expect(!state.finish(first, .complete, 0, null));
    var second = first;
    second.request = 2;
    state.begin(std.testing.allocator, second);
    try std.testing.expect(!state.finish(first, .failed, 1, error.InvalidQuery));
    state.cancel(std.testing.allocator);
    try std.testing.expect(!state.finish(second, .complete, 0, null));
    try std.testing.expectEqual(Phase.cancelled, state.phase);
}
test "project search dock failed partial and zero results remain distinguishable" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(std.testing.allocator, first);
    try std.testing.expect(state.finish(first, .partial, 2, null));
    try std.testing.expectEqual(Phase.partial, state.phase);
    try std.testing.expectEqual(@as(usize, 2), state.excluded);
    state.begin(std.testing.allocator, first);
    try std.testing.expect(state.finish(first, .failed, 0, error.InvalidQuery));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expect(state.failure.? == error.InvalidQuery);
    state.begin(std.testing.allocator, first);
    try std.testing.expect(state.finish(first, .complete, 0, null));
    try std.testing.expectEqual(Phase.complete, state.phase);
    try std.testing.expectEqual(@as(usize, 0), state.model.visible.items.len);
}

fn ownedRow(a: std.mem.Allocator) !request.Row {
    const parsed = try @import("event.zig").parse(a,
        \\{"type":"match","data":{"path":{"text":"a.zig"},"lines":{"text":"foo"},"line_number":1,"submatches":[{"start":0,"end":3,"match":{"text":"foo"}}]}}
    );
    return .{ .source = .disk, .match = parsed.match };
}
test "project search dock stale batch leaves row ownership with its caller" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    state.begin(a, first);
    state.changed(a, 100, true);
    var row = try ownedRow(a);
    defer row.match.deinit(a);
    try std.testing.expect(!try state.append(a, first, row));
    try std.testing.expectEqual(@as(usize, 0), state.model.rows.items.len);
}
test "project search dock failed publication clears visible rows and request identity" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    state.begin(a, first);
    var row = try ownedRow(a);
    if (!try state.append(a, first, row)) row.match.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.publish(failing.allocator()));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expect(state.identity == null);
    try std.testing.expectEqual(@as(usize, 0), state.model.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.model.visible.items.len);
    try std.testing.expect(!state.finish(first, .complete, 0, null));
}
