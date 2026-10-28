//! 파싱 수락 계약의 공개 facade와 전용 판정자. 구현은 문서 수명에서도 재사용한다.
const std = @import("std");
const implementation = @import("request/gate.zig");
pub const Grammar = implementation.Grammar;
pub const Input = implementation.Input;
pub const Request = implementation.Request;
pub const Gate = implementation.Gate;
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
