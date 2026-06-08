const std = @import("std");
const pty_reader = @import("pty_reader.zig");

pub const default_timeout_ms: i64 = 5_000;
pub const default_poll_interval_ms: i64 = 10;

pub const DeadlineConfig = struct {
    timeout_ms: i64 = default_timeout_ms,
    poll_interval_ms: i64 = default_poll_interval_ms,
};

pub fn popWithDeadline(
    io: std.Io,
    queue: *pty_reader.PtyEventQueue,
    config: DeadlineConfig,
) !pty_reader.QueuedPtyEvent {
    // Smoke는 제품 이벤트 루프가 아니다. 그래도 popBlocking을 그대로 쓰면 shell
    // startup이나 native bridge가 멈췄을 때 실패 artifact도 없이 영원히 대기한다.
    // 그래서 smoke harness만 deadline을 갖고 queue를 polling한다.
    const started = std.Io.Timestamp.now(io, .awake);
    while (true) {
        if (queue.tryPop()) |event| return event;
        if (queue.closedAndEmpty()) return error.ReaderQueueClosedBeforeTermination;

        if (started.untilNow(io, .awake).toMilliseconds() >= config.timeout_ms) {
            return error.SmokeDrainTimedOut;
        }

        try std.Io.sleep(
            io,
            std.Io.Duration.fromMilliseconds(config.poll_interval_ms),
            .awake,
        );
    }
}

test "smoke drain returns the first queued event before the deadline" {
    // 이 helper는 smoke 전용 timeout wrapper다. event가 이미 있으면 제품 queue의
    // ownership 규칙을 바꾸지 않고 그대로 event를 돌려줘야 한다.
    const allocator = std.testing.allocator;
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();

    const bytes = try allocator.dupe(u8, "ready");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } });

    const event = try popWithDeadline(std.testing.io, &queue, .{ .timeout_ms = 1 });
    defer event.deinit(allocator);
    try std.testing.expect(event == .output);
    try std.testing.expectEqualStrings("ready", event.output.bytes);
}

test "smoke drain reports timeout when no event arrives" {
    // smoke가 기다리던 PTY event를 끝내 받지 못하면 CI가 멈추는 대신 명시적
    // SmokeDrainTimedOut을 반환해야 한다.
    const allocator = std.testing.allocator;
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();

    try std.testing.expectError(
        error.SmokeDrainTimedOut,
        popWithDeadline(std.testing.io, &queue, .{ .timeout_ms = 1, .poll_interval_ms = 1 }),
    );
}

test "smoke drain preserves early queue close as a lifecycle failure" {
    // queue가 닫힌 상태는 timeout과 의미가 다르다. reader/PTY lifecycle이 잘못 닫힌
    // 것이므로 기존 smoke error label을 유지해야 원인 분석이 가능하다.
    const allocator = std.testing.allocator;
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    queue.close();

    try std.testing.expectError(
        error.ReaderQueueClosedBeforeTermination,
        popWithDeadline(std.testing.io, &queue, .{ .timeout_ms = 1 }),
    );
}
