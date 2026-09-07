//! The upgrade-B leaves are one transaction: neither YAML nor a product runner may reorder them.

const std = @import("std");
const phase = @import("release_adapter_candidate_upgrade_phase");

const Event = enum {
    start_deadline,
    validate_initial,
    materialize_predecessor,
    materialize_current,
    run_one,
    validate_after_one,
    run_near_max,
    validate_after_near_max,
    publish_evidence,
    validate_final,
    validate_deadline,
    cleanup_evidence,
    cleanup_near_max,
    cleanup_one,
    cleanup_current,
    cleanup_predecessor,
};

test "success uses one deadline and preserves all three outputs" {
    var steps = Steps{};
    try phase.runWith(&steps);
    try std.testing.expectEqualSlices(Event, &.{
        .start_deadline,
        .validate_initial,
        .materialize_predecessor,
        .materialize_current,
        .run_one,
        .validate_after_one,
        .run_near_max,
        .validate_after_near_max,
        .publish_evidence,
        .validate_final,
        .validate_deadline,
    }, steps.events[0..steps.event_count]);
    try std.testing.expectEqual(@as(usize, 10), steps.deadline_uses);
}

test "every operation failure cleans only attempted outputs in reverse order" {
    for (0..11) |fail_index| {
        var steps = Steps{ .fail_index = fail_index };
        try std.testing.expectError(error.InjectedFailure, phase.runWith(&steps));
        try std.testing.expectEqual(fail_index + 1, steps.operation_index);
        const expected = switch (fail_index) {
            0, 1 => &[_]Event{},
            2 => &[_]Event{.cleanup_predecessor},
            3 => &[_]Event{ .cleanup_current, .cleanup_predecessor },
            4, 5 => &[_]Event{ .cleanup_one, .cleanup_current, .cleanup_predecessor },
            6, 7 => &[_]Event{ .cleanup_near_max, .cleanup_one, .cleanup_current, .cleanup_predecessor },
            8, 9, 10 => &[_]Event{ .cleanup_evidence, .cleanup_near_max, .cleanup_one, .cleanup_current, .cleanup_predecessor },
            else => unreachable,
        };
        try std.testing.expectEqualSlices(Event, expected, steps.cleanupEvents());
    }
}

test "cleanup is best effort and cleanup failure outranks execution failure" {
    inline for (.{ CleanupFailure.evidence, .near_max, .one, .current, .predecessor }) |cleanup_failure| {
        var steps = Steps{ .fail_index = 8, .cleanup_fail = cleanup_failure };
        try std.testing.expectError(error.CleanupFailed, phase.runWith(&steps));
        try std.testing.expectEqual(@as(usize, 9), steps.operation_index);
        try std.testing.expectEqualSlices(Event, &.{ .cleanup_evidence, .cleanup_near_max, .cleanup_one, .cleanup_current, .cleanup_predecessor }, steps.cleanupEvents());
    }
}

test "final deadline failure cleans every attempted output" {
    var steps = Steps{ .fail_index = 10 };
    try std.testing.expectError(error.InjectedFailure, phase.runWith(&steps));
    try std.testing.expectEqual(@as(usize, 10), steps.deadline_uses);
    try std.testing.expectEqualSlices(Event, &.{ .cleanup_evidence, .cleanup_near_max, .cleanup_one, .cleanup_current, .cleanup_predecessor }, steps.cleanupEvents());
}

const CleanupFailure = enum { none, evidence, near_max, one, current, predecessor };

const Steps = struct {
    deadline: u8 = 0,
    events: [24]Event = undefined,
    event_count: usize = 0,
    operation_index: usize = 0,
    fail_index: ?usize = null,
    cleanup_fail: CleanupFailure = .none,
    deadline_uses: usize = 0,

    fn record(self: *@This(), event: Event) !void {
        self.events[self.event_count] = event;
        self.event_count += 1;
        const index = self.operation_index;
        self.operation_index += 1;
        if (self.fail_index == index) return error.InjectedFailure;
    }

    fn use(self: *@This(), deadline: *u8, event: Event) !void {
        try std.testing.expectEqual(&self.deadline, deadline);
        self.deadline_uses += 1;
        try self.record(event);
    }

    pub fn startDeadline(self: *@This()) !*u8 {
        try self.record(.start_deadline);
        return &self.deadline;
    }
    pub fn validateInitialAuthorities(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .validate_initial);
    }
    pub fn materializePredecessor(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .materialize_predecessor);
    }
    pub fn materializeCurrent(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .materialize_current);
    }
    pub fn runSignedOne(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .run_one);
    }
    pub fn validateAuthoritiesAfterOne(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .validate_after_one);
    }
    pub fn runSignedNearMax(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .run_near_max);
    }
    pub fn validateAuthoritiesAfterNearMax(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .validate_after_near_max);
    }
    pub fn publishEvidence(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .publish_evidence);
    }
    pub fn validateFinalAuthorities(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .validate_final);
    }
    pub fn validateFinalDeadline(self: *@This(), deadline: *u8) !void {
        try self.use(deadline, .validate_deadline);
    }

    pub fn cleanupEvidence(self: *@This()) !void {
        try self.cleanup(.cleanup_evidence, .evidence);
    }
    pub fn cleanupNearMax(self: *@This()) !void {
        try self.cleanup(.cleanup_near_max, .near_max);
    }
    pub fn cleanupOne(self: *@This()) !void {
        try self.cleanup(.cleanup_one, .one);
    }
    pub fn cleanupCurrent(self: *@This()) !void {
        try self.cleanup(.cleanup_current, .current);
    }
    pub fn cleanupPredecessor(self: *@This()) !void {
        try self.cleanup(.cleanup_predecessor, .predecessor);
    }

    fn cleanup(self: *@This(), event: Event, kind: CleanupFailure) !void {
        self.events[self.event_count] = event;
        self.event_count += 1;
        if (self.cleanup_fail == kind) return error.InjectedCleanup;
    }

    fn cleanupEvents(self: *const @This()) []const Event {
        for (self.events[0..self.event_count], 0..) |event, index| switch (event) {
            .cleanup_evidence, .cleanup_near_max, .cleanup_one, .cleanup_current, .cleanup_predecessor => return self.events[index..self.event_count],
            else => {},
        };
        return &.{};
    }
};
