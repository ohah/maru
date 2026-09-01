//! Pre-publish transaction ordering is tested independently from leaf semantics.

const std = @import("std");
const phase = @import("release_adapter_pre_publish_phase");

const Event = enum {
    deadline,
    workspace,
    candidate,
    current_release,
    current_input,
    predecessor_input,
    predecessor_assets,
    product,
    evidence,
    asset_files,
    asset_attestations,
    compatibility,
    observation,
    validate_publication,
    cleanup_compatibility,
    cleanup_asset_attestations,
    cleanup_asset_files,
    cleanup_evidence,
    cleanup_product,
    cleanup_predecessor_assets,
    cleanup_predecessor_input,
    cleanup_current_input,
    cleanup_current_release,
    cleanup_candidate,
    cleanup_workspace,
    cleanup_deadline,
    publish,
    cleanup_observation,
};

const setup = [_]Event{ .deadline, .workspace, .candidate, .current_release, .current_input, .predecessor_input, .predecessor_assets, .product, .evidence, .asset_files, .asset_attestations, .compatibility, .observation };
const cleanup = [_]Event{ .cleanup_compatibility, .cleanup_asset_attestations, .cleanup_asset_files, .cleanup_evidence, .cleanup_product, .cleanup_predecessor_assets, .cleanup_predecessor_input, .cleanup_current_input, .cleanup_current_release, .cleanup_candidate, .cleanup_workspace, .cleanup_deadline };

const Recorder = struct {
    events: [64]Event = undefined,
    len: usize = 0,
    setup_calls: usize = 0,
    fail_setup: ?usize = null,
    fail_cleanup: ?Event = null,
    fail_publication_validation: bool = false,
    deadline_storage: u8 = 0,

    fn add(self: *@This(), event: Event) !void {
        self.events[self.len] = event;
        self.len += 1;
        if (@intFromEnum(event) <= @intFromEnum(Event.observation)) {
            const index = self.setup_calls;
            self.setup_calls += 1;
            if (self.fail_setup == index) return error.StepFailed;
        }
        if (self.fail_cleanup == event) return error.CleanupFailed;
    }

    fn same(self: *@This(), deadline: *u8) !void {
        try std.testing.expectEqual(&self.deadline_storage, deadline);
    }
    pub fn startDeadline(self: *@This()) !*u8 {
        try self.add(.deadline);
        return &self.deadline_storage;
    }
    pub fn prepareWorkspace(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.workspace);
    }
    pub fn prepareCandidate(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.candidate);
    }
    pub fn authenticateCurrentRelease(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.current_release);
    }
    pub fn authenticateCurrentInput(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.current_input);
    }
    pub fn authenticatePredecessorInput(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.predecessor_input);
    }
    pub fn authenticatePredecessorAssets(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.predecessor_assets);
    }
    pub fn observeProduct(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.product);
    }
    pub fn composeEvidence(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.evidence);
    }
    pub fn composeAssetFiles(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.asset_files);
    }
    pub fn attestAssets(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.asset_attestations);
    }
    pub fn composeCompatibility(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.compatibility);
    }
    pub fn composeObservation(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.observation);
    }
    pub fn publishSummary(self: *@This()) !void {
        try self.add(.publish);
    }
    pub fn validatePublication(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.validate_publication);
        if (self.fail_publication_validation) return error.TimedOut;
    }
    pub fn cleanupObservation(self: *@This()) void {
        self.add(.cleanup_observation) catch unreachable;
    }
    pub fn cleanupCompatibility(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_compatibility);
    }
    pub fn cleanupAssetAttestations(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_asset_attestations);
    }
    pub fn cleanupAssetFiles(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_asset_files);
    }
    pub fn cleanupEvidence(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_evidence);
    }
    pub fn cleanupProduct(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_product);
    }
    pub fn cleanupPredecessorAssets(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_predecessor_assets);
    }
    pub fn cleanupPredecessorInput(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_predecessor_input);
    }
    pub fn cleanupCurrentInput(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_current_input);
    }
    pub fn cleanupCurrentRelease(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_current_release);
    }
    pub fn cleanupCandidate(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_candidate);
    }
    pub fn cleanupWorkspace(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_workspace);
    }
    pub fn cleanupDeadline(self: *@This(), deadline: *u8) !void {
        try self.same(deadline);
        try self.add(.cleanup_deadline);
    }
};

test "successful phase cleans private owners before publishing summary" {
    var recorder = Recorder{};
    try phase.runWith(&recorder);
    try std.testing.expectEqualSlices(Event, &setup, recorder.events[0..setup.len]);
    try std.testing.expectEqualSlices(Event, cleanup[0 .. cleanup.len - 1], recorder.events[setup.len .. setup.len + cleanup.len - 1]);
    try std.testing.expectEqualSlices(Event, &.{ .validate_publication, .cleanup_deadline, .publish, .cleanup_observation }, recorder.events[setup.len + cleanup.len - 1 .. recorder.len]);
}

test "expired final publication gate cleans deadline and publishes nothing" {
    var recorder = Recorder{ .fail_publication_validation = true };
    try std.testing.expectError(error.TimedOut, phase.runWith(&recorder));
    try std.testing.expect(std.mem.indexOfScalar(Event, recorder.events[0..recorder.len], .publish) == null);
    try std.testing.expectEqualSlices(Event, &.{ .validate_publication, .cleanup_deadline, .cleanup_observation }, recorder.events[recorder.len - 3 .. recorder.len]);
}

test "failure-pristine deadline and every later setup failure leave no uncleaned attempted owner" {
    for (0..setup.len) |fail_index| {
        var recorder = Recorder{ .fail_setup = fail_index };
        try std.testing.expectError(error.StepFailed, phase.runWith(&recorder));
        try std.testing.expect(std.mem.indexOfScalar(Event, recorder.events[0..recorder.len], .publish) == null);
        if (fail_index == 0) {
            try std.testing.expectEqual(@as(usize, 1), recorder.len);
            continue;
        }
        var cleanup_start = fail_index + 1;
        if (fail_index == setup.len - 1) {
            try std.testing.expectEqual(Event.cleanup_observation, recorder.events[cleanup_start]);
            cleanup_start += 1;
        }
        const attempted_private = @min(fail_index + 1, cleanup.len);
        try std.testing.expectEqualSlices(
            Event,
            cleanup[cleanup.len - attempted_private ..],
            recorder.events[cleanup_start .. cleanup_start + attempted_private],
        );
    }
}

test "cleanup failure is terminal publication zero while later cleanup still runs" {
    var recorder = Recorder{ .fail_cleanup = .cleanup_product };
    try std.testing.expectError(error.CleanupFailed, phase.runWith(&recorder));
    try std.testing.expect(std.mem.indexOfScalar(Event, recorder.events[0..recorder.len], .publish) == null);
    try std.testing.expectEqual(Event.cleanup_deadline, recorder.events[recorder.len - 2]);
    try std.testing.expectEqual(Event.cleanup_observation, recorder.events[recorder.len - 1]);
}
