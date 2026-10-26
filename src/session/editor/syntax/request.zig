//! 비동기 파싱 요청의 메인 스레드 수락 문턱. 큐·parser·문서 수명은 소유하지 않는다.
//! begin은 준비 할당보다 먼저 호출한다. 실패한 준비도 이전 본문의 결과를 현재로 만들면 안 된다.
const std = @import("std");
const registry = @import("../document_registry.zig");

/// 역참조하지 않는 언어 식별값과 설정 세대. 같은 언어의 설정 변경도 다른 입력 판이다.
pub const Grammar = struct { identity: usize, generation: u64 };
pub const Input = struct {
    document: registry.DocumentIdentity,
    revision: u64,
    grammar: Grammar,
};
pub const Request = struct { input: Input, serial: u64 };

/// 메인에서만 사용한다. worker에는 Request 값만 복사한다.
/// 같은 문서 identity의 수명 동안 보존해야 하며 닫을 때 invalidate한다.
/// 새 Gate를 만들 때는 registry의 새 document generation이 필요하다.
pub const Gate = struct {
    wanted: ?Request = null,
    phase: enum { invalid, preparing, awaiting, consumed } = .invalid,
    next_serial: u64 = 0,
    exhausted: bool = false,

    pub fn invalidate(self: *Gate) void {
        self.wanted = null;
        self.phase = .invalid;
    }

    /// 새 입력을 먼저 선언한다. 번호가 고갈돼도 이전 결과는 무효다.
    pub fn begin(self: *Gate, input: Input) error{SerialExhausted}!Request {
        self.invalidate();
        if (self.exhausted) return error.SerialExhausted;
        const tag: Request = .{ .input = input, .serial = self.next_serial };
        if (self.next_serial == std.math.maxInt(u64)) self.exhausted = true else self.next_serial += 1;
        self.wanted = tag;
        self.phase = .preparing;
        return tag;
    }

    /// 작업 준비가 끝난 뒤, 워커에 공개하기 전에 메인에서 호출한다.
    pub fn publish(self: *Gate, tag: Request) bool {
        if (self.phase != .preparing or !self.matches(tag)) return false;
        self.phase = .awaiting;
        return true;
    }

    /// 준비 실패나 취소의 수락 증명만 지운다. 실제 작업 자원을 해제하지 않는다.
    pub fn abandon(self: *Gate, tag: Request) bool {
        if ((self.phase != .preparing and self.phase != .awaiting) or !self.matches(tag)) return false;
        self.invalidate();
        return true;
    }

    /// 성공·완료된 결과만 caller가 넘긴다. 낡은 결과는 현재 대기를 소비하지 않는다.
    /// true여도 parser/트리 판의 증명과 결과 설치는 별도로 수행해야 한다.
    pub fn accept(self: *Gate, tag: Request) bool {
        if (self.phase != .awaiting or !self.matches(tag)) return false;
        self.phase = .consumed;
        return true;
    }

    pub fn isCurrent(self: *const Gate, tag: Request) bool {
        return self.phase == .consumed and self.matches(tag);
    }

    fn matches(self: *const Gate, candidate: Request) bool {
        return if (self.wanted) |tag| std.meta.eql(tag, candidate) else false;
    }
};

const sample: Input = .{ .document = .{ .owner = 1, .slot = 2, .generation = 3 }, .revision = 4, .grammar = .{ .identity = 5, .generation = 6 } };

test "parse request gate 정상 준비와 공개 뒤 한 번만 수락한다" {
    var gate: Gate = .{};
    const tag = try gate.begin(sample);
    try std.testing.expect(!gate.accept(tag));
    try std.testing.expect(!gate.isCurrent(tag));
    try std.testing.expect(gate.publish(tag));
    try std.testing.expect(!gate.publish(tag));
    try std.testing.expect(gate.accept(tag));
    try std.testing.expect(gate.isCurrent(tag));
    try std.testing.expect(!gate.accept(tag));
    try std.testing.expect(!gate.abandon(tag));
}

test "parse request gate 모든 입력 식별값이 일치해야 수락한다" {
    for (0..7) |kind| {
        var gate: Gate = .{};
        const tag = try gate.begin(sample);
        try std.testing.expect(gate.publish(tag));
        var other = tag;
        switch (kind) {
            0 => other.input.document.owner += 1,
            1 => other.input.document.slot += 1,
            2 => other.input.document.generation += 1,
            3 => other.input.revision += 1,
            4 => other.input.grammar.identity += 1,
            5 => other.input.grammar.generation += 1,
            else => other.serial += 1,
        }
        try std.testing.expect(!gate.accept(other));
        try std.testing.expect(!gate.abandon(other));
        try std.testing.expect(gate.accept(tag));
    }
}

test "parse request gate 준비 실패 뒤에도 이전 결과는 거절한다" {
    var gate: Gate = .{};
    const old = try gate.begin(sample);
    try std.testing.expect(gate.publish(old));
    var edited = sample;
    edited.revision += 1;
    const next = try gate.begin(edited);
    try std.testing.expect(!gate.accept(old));
    try std.testing.expect(gate.abandon(next));
    try std.testing.expect(!gate.publish(next));
    try std.testing.expect(!gate.accept(old));
    const retry = try gate.begin(edited);
    try std.testing.expect(gate.publish(retry));
    try std.testing.expect(gate.accept(retry));
}

test "parse request gate 같은 본문도 최신 재요청만 수락한다" {
    var gate: Gate = .{};
    const old = try gate.begin(sample);
    try std.testing.expect(gate.publish(old));
    const next = try gate.begin(sample);
    try std.testing.expect(old.serial != next.serial);
    try std.testing.expect(!gate.publish(old));
    try std.testing.expect(!gate.abandon(old));
    try std.testing.expect(gate.publish(next));
    try std.testing.expect(!gate.accept(old));
    try std.testing.expect(gate.accept(next));
}

test "parse request gate 닫기와 슬롯 재사용은 이전 결과를 무효화한다" {
    var gate: Gate = .{};
    const old = try gate.begin(sample);
    try std.testing.expect(gate.publish(old));
    gate.invalidate();
    try std.testing.expect(!gate.accept(old));
    try std.testing.expect(!gate.publish(old));
    var reopened = sample;
    reopened.document.generation += 1;
    const next = try gate.begin(reopened);
    try std.testing.expect(gate.publish(next));
    try std.testing.expect(!gate.accept(old));
    try std.testing.expect(gate.accept(next));
    gate.invalidate();
    try std.testing.expect(!gate.isCurrent(next));
}

test "parse request gate 준비와 결과 대기 중 취소는 한 번만 반영한다" {
    for ([_]bool{ false, true }) |published| {
        var gate: Gate = .{};
        const tag = try gate.begin(sample);
        if (published) try std.testing.expect(gate.publish(tag));
        try std.testing.expect(gate.abandon(tag));
        try std.testing.expect(!gate.abandon(tag));
        try std.testing.expect(!gate.accept(tag));
    }
}

test "parse request gate 번호를 순환하지 않고 고갈돼도 이전 결과를 무효화한다" {
    var gate: Gate = .{ .next_serial = std.math.maxInt(u64) - 1 };
    const penultimate = try gate.begin(sample);
    try std.testing.expect(gate.publish(penultimate));
    try std.testing.expect(gate.accept(penultimate));
    const last = try gate.begin(sample);
    try std.testing.expectEqual(std.math.maxInt(u64), last.serial);
    try std.testing.expect(!gate.isCurrent(penultimate));
    try std.testing.expect(gate.publish(last));
    try std.testing.expect(gate.accept(last));
    try std.testing.expectError(error.SerialExhausted, gate.begin(sample));
    try std.testing.expect(!gate.isCurrent(last));
    try std.testing.expect(!gate.accept(last));
    gate.invalidate();
    try std.testing.expectError(error.SerialExhausted, gate.begin(sample));
}

test "parse request gate 새 입력은 수락된 판도 무효화한다" {
    var gate: Gate = .{};
    const old = try gate.begin(sample);
    try std.testing.expect(gate.publish(old));
    try std.testing.expect(gate.accept(old));
    _ = try gate.begin(sample);
    try std.testing.expect(!gate.isCurrent(old));
    try std.testing.expect(!gate.accept(old));
}
