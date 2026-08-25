//! P4 C3a 제품 owner의 app-global change token → C1 generation 결속을 검증한다.

const std = @import("std");
const maru = @import("maru");
const product = maru.app.workspace_checkpoint_product;
const checkpoint = maru.session.workspace_checkpoint;

const policy: checkpoint.Policy = .{ .debounce_ns = 10, .retry_initial_ns = 20, .retry_max_ns = 80 };

test "P4 C3a arm 전 restore mutation은 baseline을 더럽히지 않는다" {
    var state: product.State = .{};
    try state.markChanged(.topology);
    try std.testing.expect(!state.isDirty());
    try state.arm(policy, false);
    try std.testing.expectEqual(product.SyncResult.unchanged, try state.syncChanges(1));
    try std.testing.expect(!state.isDirty());
}

test "P4 C3a 최초 persistent baseline은 명시적으로 dirty arm한다" {
    var state: product.State = .{};
    try state.arm(policy, true);
    try std.testing.expect(state.isDirty());
    try std.testing.expectEqual(product.SyncResult.changed, try state.syncChanges(5));
    try std.testing.expectEqual(checkpoint.Effect.none, try state.tick(14));
    try expectCapture(try state.tick(15), 1);
}

test "P4 C3a 여러 committed mutation을 한 owner turn에서 C1 mutation 하나로 합친다" {
    var state: product.State = .{};
    try state.arm(policy, false);
    try state.markChanged(.topology);
    try state.markChanged(.ordering);
    try state.markChanged(.selection);
    try std.testing.expectEqual(product.SyncResult.changed, try state.syncChanges(7));
    try std.testing.expectEqual(product.SyncResult.unchanged, try state.syncChanges(8));
    try expectCapture(try state.tick(17), 1);
}

test "P4 C3a write completion 전 동기화가 in-flight generation을 stale로 만든다" {
    var state: product.State = .{};
    try state.arm(policy, false);
    try state.markChanged(.topology);
    _ = try state.syncChanges(0);
    try expectCapture(try state.tick(10), 1);
    const write = try state.captureCompleted(1, true, 10);
    try expectWrite(write.effect, 1);
    try state.markChanged(.selection);
    const completion = try state.writeCompleted(1, true, 11);
    try std.testing.expectEqual(checkpoint.Result{ .stale = 1 }, completion.result.?);
    try std.testing.expect(state.isDirty());
    try expectCapture(try state.tick(21), 2);
}

test "P4 C3a change token overflow는 sticky integrity failure다" {
    var state: product.State = .{};
    try state.arm(policy, false);
    state.change_revision = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, state.markChanged(.topology));
    try std.testing.expect(state.integrity_failed);
    try std.testing.expectError(error.IntegrityFailure, state.syncChanges(1));
}

test "P4 C3a arm과 completion의 복제 순서를 fail closed한다" {
    var state: product.State = .{};
    try state.arm(policy, false);
    try std.testing.expectError(error.AlreadyArmed, state.arm(policy, false));
    try state.markChanged(.topology);
    _ = try state.syncChanges(0);
    try expectCapture(try state.tick(10), 1);
    try std.testing.expectError(error.UnexpectedCompletion, state.writeCompleted(1, true, 10));
}

test "P4 C4 Quit 요청은 관측되지 않은 mutation을 동기화하고 final capture를 즉시 낸다" {
    var state: product.State = .{};
    try state.arm(policy, false);
    try state.markChanged(.window_frame);
    const effect = try state.quitRequested(7);
    try expectCapture(effect, 1);
    switch (effect.capture.reason) {
        .final_quit => {},
        else => return error.TestUnexpectedResult,
    }
}

test "P4 C4 final 실패 뒤 mutation forwarding을 다시 받는다" {
    var state: product.State = .{};
    try state.arm(policy, true);
    const capture = try state.quitRequested(1);
    try expectCapture(capture, 1);
    const completion = try state.captureCompleted(1, false, 2);
    try std.testing.expectEqual(checkpoint.Effect.cancel_quit, completion.effect);
    try state.markChanged(.selection);
    try std.testing.expectEqual(product.SyncResult.changed, try state.syncChanges(3));
}

fn expectCapture(effect: checkpoint.Effect, generation: u64) !void {
    switch (effect) {
        .capture => |request| try std.testing.expectEqual(generation, request.generation),
        else => return error.TestUnexpectedResult,
    }
}

fn expectWrite(effect: checkpoint.Effect, generation: u64) !void {
    switch (effect) {
        .write => |request| try std.testing.expectEqual(generation, request.generation),
        else => return error.TestUnexpectedResult,
    }
}
