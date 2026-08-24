//! P4 C1의 순수 checkpoint coordinator 계약을 고정한다.
//! 실제 파일/AppKit 없이 세대, debounce, bounded retry, notice epoch와 final Quit 효과를 검증한다.

const std = @import("std");
const checkpoint = @import("workspace_checkpoint");

const policy: checkpoint.Policy = .{
    .debounce_ns = 10,
    .retry_initial_ns = 20,
    .retry_max_ns = 80,
};

test "P4 C1 overlapping mutation makes old completion stale and preserves the new debounce" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(9));
    try expectCapture(try coordinator.tick(10), 1, .background);

    try coordinator.mutation(11);
    const stale = try coordinator.captureCompleted(1, true, 12);
    try std.testing.expectEqual(checkpoint.Result{ .stale = 1 }, stale.result.?);
    try std.testing.expectEqual(checkpoint.Effect.none, stale.effect);
    try std.testing.expect(coordinator.isDirty());
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(20));
    try expectCapture(try coordinator.tick(21), 2, .background);
}

test "P4 C1 mutation after write starts makes its completion stale but preserves new dirty" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);
    try expectWrite((try coordinator.captureCompleted(1, true, 10)).effect, 1, .background);
    try coordinator.mutation(11);
    const stale = try coordinator.writeCompleted(1, true, 12);
    try std.testing.expectEqual(checkpoint.Result{ .stale = 1 }, stale.result.?);
    try std.testing.expect(coordinator.isDirty());
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(20));
    try expectCapture(try coordinator.tick(21), 2, .background);
}

test "P4 C1 background failures retain dirty use capped backoff and coalesce notice per epoch" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);

    const first = try coordinator.captureCompleted(1, false, 10);
    try std.testing.expectEqual(checkpoint.Result.capture_failed, first.result.?);
    try std.testing.expectEqual(checkpoint.Failure.capture_failed, first.notice.?);
    try std.testing.expectEqual(checkpoint.Effect.none, first.effect);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(29));
    try expectCapture(try coordinator.tick(30), 1, .background);

    try expectWrite((try coordinator.captureCompleted(1, true, 30)).effect, 1, .background);
    const second = try coordinator.writeCompleted(1, false, 30);
    try std.testing.expectEqual(checkpoint.Result.write_failed, second.result.?);
    try std.testing.expectEqual(checkpoint.Effect.none, second.effect);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(69));
    try expectCapture(try coordinator.tick(70), 1, .background);

    const third = try coordinator.captureCompleted(1, false, 70);
    try std.testing.expectEqual(@as(?checkpoint.Failure, null), third.notice);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(149));
    try expectCapture(try coordinator.tick(150), 1, .background);

    try expectWrite((try coordinator.captureCompleted(1, true, 150)).effect, 1, .background);
    const committed = try coordinator.writeCompleted(1, true, 150);
    try std.testing.expectEqual(checkpoint.Result{ .committed = 1 }, committed.result.?);
    try std.testing.expect(!coordinator.isDirty());

    try coordinator.mutation(151);
    try expectCapture(try coordinator.tick(161), 2, .background);
    const new_epoch = try coordinator.captureCompleted(2, false, 161);
    try std.testing.expectEqual(checkpoint.Failure.capture_failed, new_epoch.notice.?);
}

test "P4 C1 final quit freezes mutation and only current commit replies and detaches" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.quitRequested(1), 1, .final_quit);
    try std.testing.expectError(error.MutationFrozen, coordinator.mutation(2));
    try expectWrite((try coordinator.captureCompleted(1, true, 2)).effect, 1, .final_quit);

    const committed = try coordinator.writeCompleted(1, true, 3);
    try std.testing.expectEqual(checkpoint.Result{ .committed = 1 }, committed.result.?);
    try std.testing.expectEqual(checkpoint.Effect.reply_and_detach, committed.effect);
}

test "P4 C1 final failure cancels quit unfreezes mutations and schedules background retry" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.quitRequested(1), 1, .final_quit);
    const failed = try coordinator.captureCompleted(1, false, 1);
    try std.testing.expectEqual(checkpoint.Result.capture_failed, failed.result.?);
    try std.testing.expectEqual(checkpoint.Effect.cancel_quit, failed.effect);

    try coordinator.mutation(2);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(11));
    try expectCapture(try coordinator.tick(12), 2, .background);
}

test "P4 C1 quit waits for background work then captures current generation again" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.quitRequested(11));
    try expectWrite((try coordinator.captureCompleted(1, true, 11)).effect, 1, .background);
    const background = try coordinator.writeCompleted(1, true, 12);
    try std.testing.expectEqual(checkpoint.Result{ .committed = 1 }, background.result.?);
    try expectCapture(background.effect, 1, .final_quit);
}

test "P4 C1 invalid policy overflow and unexpected completion fail before mutation" {
    try std.testing.expectError(error.InvalidPolicy, checkpoint.Coordinator.init(.{
        .debounce_ns = 0,
        .retry_initial_ns = 1,
        .retry_max_ns = 1,
    }));

    var coordinator = try checkpoint.Coordinator.init(policy);
    try std.testing.expectError(error.Overflow, coordinator.mutation(std.math.maxInt(u64)));
    try std.testing.expect(!coordinator.isDirty());
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);
    try std.testing.expectError(error.UnexpectedCompletion, coordinator.captureCompleted(2, true, 10));
    try std.testing.expect(coordinator.isDirty());
}

test "P4 C1 background failure during accepted quit starts a fresh final capture" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.quitRequested(11));

    const failed = try coordinator.captureCompleted(1, false, 12);
    try std.testing.expectEqual(checkpoint.Result.capture_failed, failed.result.?);
    try std.testing.expectEqual(checkpoint.Failure.capture_failed, failed.notice.?);
    try expectCapture(failed.effect, 1, .final_quit);
    try std.testing.expectError(error.MutationFrozen, coordinator.mutation(13));
}

test "P4 C1 final write failure cancels quit without publishing detach" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.quitRequested(1), 1, .final_quit);
    try expectWrite((try coordinator.captureCompleted(1, true, 2)).effect, 1, .final_quit);
    const failed = try coordinator.writeCompleted(1, false, 3);
    try std.testing.expectEqual(checkpoint.Result.write_failed, failed.result.?);
    try std.testing.expectEqual(checkpoint.Effect.cancel_quit, failed.effect);
    try std.testing.expectEqual(checkpoint.Failure.write_failed, failed.notice.?);
    try std.testing.expect(coordinator.isDirty());
    try coordinator.mutation(4);
}

test "P4 C1 copied and reordered completions cannot mutate the active operation" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);
    try std.testing.expectError(error.UnexpectedCompletion, coordinator.writeCompleted(1, true, 10));
    try expectWrite((try coordinator.captureCompleted(1, true, 11)).effect, 1, .background);
    try std.testing.expectError(error.UnexpectedCompletion, coordinator.captureCompleted(1, true, 12));
    const committed = try coordinator.writeCompleted(1, true, 13);
    try std.testing.expectEqual(checkpoint.Result{ .committed = 1 }, committed.result.?);
    try std.testing.expectError(error.UnexpectedCompletion, coordinator.writeCompleted(1, true, 14));
    try std.testing.expect(!coordinator.isDirty());
}

test "P4 C1 retry delay saturates at the injected maximum" {
    var coordinator = try checkpoint.Coordinator.init(policy);
    try coordinator.mutation(0);
    try expectCapture(try coordinator.tick(10), 1, .background);
    _ = try coordinator.captureCompleted(1, false, 10);
    try expectCapture(try coordinator.tick(30), 1, .background);
    _ = try coordinator.captureCompleted(1, false, 30);
    try expectCapture(try coordinator.tick(70), 1, .background);
    _ = try coordinator.captureCompleted(1, false, 70);
    try expectCapture(try coordinator.tick(150), 1, .background);
    _ = try coordinator.captureCompleted(1, false, 150);
    try std.testing.expectEqual(checkpoint.Effect.none, try coordinator.tick(229));
    try expectCapture(try coordinator.tick(230), 1, .background);
}

fn expectCapture(effect: checkpoint.Effect, generation: u64, reason: checkpoint.Reason) !void {
    switch (effect) {
        .capture => |capture| {
            try std.testing.expectEqual(generation, capture.generation);
            try std.testing.expectEqual(reason, capture.reason);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectWrite(effect: checkpoint.Effect, generation: u64, reason: checkpoint.Reason) !void {
    switch (effect) {
        .write => |write| {
            try std.testing.expectEqual(generation, write.generation);
            try std.testing.expectEqual(reason, write.reason);
        },
        else => return error.TestUnexpectedResult,
    }
}
