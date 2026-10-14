//! Save As의 순서·취소 판정. 파일 쓰기와 경로 전환은 호출자가 성공 경계에서 수행한다.
//! UI가 사라져도 접수한 쓰기의 결과를 정산하므로 소비자 수명과 연산 수명을 섞지 않는다.
const std = @import("std");

pub const Phase = enum { preparing, waiting_source, writing, succeeded, failed, cancelled };
pub const Route = enum { source, deferred, destination };
pub const State = struct {
    phase: Phase = .preparing,

    /// 접수 시점부터 같은 문서의 후속 저장을 보류한다. 원본 선행 요청은 actor가 따로 정산한다.
    pub fn accept(self: *State) error{InvalidPhase}!void {
        if (self.phase != .preparing) return error.InvalidPhase;
        self.phase = .waiting_source;
    }
    /// 입력 확정과 선행 요청 정산을 모두 통과해야 worker에 snapshot을 넘길 수 있다.
    pub fn start(self: *State, source_settled: bool, input_settled: bool) error{InvalidPhase}!bool {
        if (self.phase != .waiting_source) return error.InvalidPhase;
        if (!source_settled or !input_settled) return false;
        self.phase = .writing;
        return true;
    }
    /// 접수 뒤 UI의 취소는 쓰기나 목적지를 바꾸지 않는다. 실제 worker 결과만 연산을 끝낸다.
    pub fn cancel(self: *State) bool {
        if (self.phase != .preparing) return false;
        self.phase = .cancelled;
        return true;
    }
    /// 준비/등록 실패도 정산한다. 성공은 worker 완료와 모델 경로 전환이 모두 성공한 뒤 전달한다.
    pub fn finish(self: *State, success: bool) error{InvalidPhase}!void {
        switch (self.phase) {
            .waiting_source => if (success) return error.InvalidPhase,
            .writing => {},
            else => return error.InvalidPhase,
        }
        self.phase = if (success) .succeeded else .failed;
    }
    pub fn route(self: State) Route {
        return switch (self.phase) {
            .preparing, .failed, .cancelled => .source,
            .waiting_source, .writing => .deferred,
            .succeeded => .destination,
        };
    }
};

// 실제 writer를 흉내 낸 성공 주장이 아니라 사건 순서의 계약을 검증한다.
// 호스트는 별도로 문서 신원/epoch, 대상 예약, 실제 bytes와 no-fail 경로 전환을 검증해야 한다.
test "접수 뒤 후속 저장은 성공 전 새 경로로 가지 않는다" {
    var s: State = .{};
    try std.testing.expectEqual(Route.source, s.route());
    try s.accept();
    try std.testing.expectEqual(Route.deferred, s.route());
    try std.testing.expect(try s.start(true, true));
    try std.testing.expectEqual(Route.deferred, s.route());
    try s.finish(true);
    try std.testing.expectEqual(Route.destination, s.route());
}
test "원본 저장과 입력 해석의 두 장벽을 모두 기다린다" {
    for ([_][2]bool{ .{ false, false }, .{ false, true }, .{ true, false } }) |ready| {
        var s: State = .{};
        try s.accept();
        try std.testing.expect(!try s.start(ready[0], ready[1]));
        try std.testing.expectEqual(Phase.waiting_source, s.phase);
        try std.testing.expectEqual(Route.deferred, s.route());
    }
}
test "실제 저장 실패와 등록 실패는 원래 경로로 후속 저장을 보낸다" {
    for ([_]bool{ false, true }) |started| {
        var s: State = .{};
        try s.accept();
        if (started) _ = try s.start(true, true);
        try s.finish(false);
        try std.testing.expectEqual(Route.source, s.route());
        try std.testing.expectEqual(Phase.failed, s.phase);
    }
}
test "접수 전 취소만 연산을 중단하고 접수 뒤 취소는 결과를 유실하지 않는다" {
    var before: State = .{};
    try std.testing.expect(before.cancel());
    try std.testing.expectEqual(Route.source, before.route());
    try std.testing.expectError(error.InvalidPhase, before.accept());
    var after: State = .{};
    try after.accept();
    try std.testing.expect(!after.cancel());
    try std.testing.expectEqual(Phase.waiting_source, after.phase);
    _ = try after.start(true, true);
    try std.testing.expect(!after.cancel());
    try after.finish(true);
    try std.testing.expectEqual(Route.destination, after.route());
}
test "조기 성공과 중복 완료는 저장 경로를 바꾸지 않는다" {
    var s: State = .{};
    try std.testing.expectError(error.InvalidPhase, s.finish(true));
    try std.testing.expectError(error.InvalidPhase, s.start(true, true));
    try s.accept();
    try std.testing.expectError(error.InvalidPhase, s.accept());
    try std.testing.expectError(error.InvalidPhase, s.finish(true));
    _ = try s.start(true, true);
    try s.finish(false);
    try std.testing.expectError(error.InvalidPhase, s.finish(true));
    try std.testing.expectEqual(Route.source, s.route());
}
