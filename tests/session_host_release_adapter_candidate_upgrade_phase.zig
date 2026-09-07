//! The upgrade-B leaves are one transaction: neither YAML nor a product runner may reorder them.

const std = @import("std");
const phase = @import("release_adapter_candidate_upgrade_phase");

const Event = enum {
    start_deadline,
    validate_initial,
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
};

test "success uses one deadline and preserves all three outputs" {
    var steps = Steps{};
    try phase.runWith(&steps);
    try std.testing.expectEqualSlices(Event, &.{
        .start_deadline,
        .validate_initial,
        .run_one,
        .validate_after_one,
        .run_near_max,
        .validate_after_near_max,
        .publish_evidence,
        .validate_final,
        .validate_deadline,
    }, steps.events[0..steps.event_count]);
    try std.testing.expectEqual(@as(usize, 8), steps.deadline_uses);
}

test "every operation failure cleans only attempted outputs in reverse order" {
    for (0..9) |fail_index| {
        var steps = Steps{ .fail_index = fail_index };
        try std.testing.expectError(error.InjectedFailure, phase.runWith(&steps));
        try std.testing.expectEqual(fail_index + 1, steps.operation_index);
        const expected = switch (fail_index) {
            0, 1 => &[_]Event{},
            2, 3 => &[_]Event{.cleanup_one},
            4, 5 => &[_]Event{ .cleanup_near_max, .cleanup_one },
            6, 7, 8 => &[_]Event{ .cleanup_evidence, .cleanup_near_max, .cleanup_one },
            else => unreachable,
        };
        try std.testing.expectEqualSlices(Event, expected, steps.cleanupEvents());
    }
}

test "cleanup is best effort and cleanup failure outranks execution failure" {
    inline for (.{ CleanupFailure.evidence, .near_max, .one }) |cleanup_failure| {
        var steps = Steps{ .fail_index = 6, .cleanup_fail = cleanup_failure };
        try std.testing.expectError(error.CleanupFailed, phase.runWith(&steps));
        try std.testing.expectEqual(@as(usize, 7), steps.operation_index);
        try std.testing.expectEqualSlices(Event, &.{ .cleanup_evidence, .cleanup_near_max, .cleanup_one }, steps.cleanupEvents());
    }
}

test "final deadline failure cleans every attempted output" {
    var steps = Steps{ .fail_index = 8 };
    try std.testing.expectError(error.InjectedFailure, phase.runWith(&steps));
    try std.testing.expectEqual(@as(usize, 8), steps.deadline_uses);
    try std.testing.expectEqualSlices(Event, &.{ .cleanup_evidence, .cleanup_near_max, .cleanup_one }, steps.cleanupEvents());
}

const CleanupFailure = enum { none, evidence, near_max, one };

const Steps = struct {
    deadline: u8 = 0,
    events: [16]Event = undefined,
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

    fn cleanup(self: *@This(), event: Event, kind: CleanupFailure) !void {
        self.events[self.event_count] = event;
        self.event_count += 1;
        if (self.cleanup_fail == kind) return error.InjectedCleanup;
    }

    fn cleanupEvents(self: *const @This()) []const Event {
        for (self.events[0..self.event_count], 0..) |event, index| switch (event) {
            .cleanup_evidence, .cleanup_near_max, .cleanup_one => return self.events[index..self.event_count],
            else => {},
        };
        return &.{};
    }
};
