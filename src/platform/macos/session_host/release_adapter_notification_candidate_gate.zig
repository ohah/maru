//! R2c mounted-candidate Notification Center composition under one absolute deadline.

const std = @import("std");
const builtin = @import("builtin");
const dmg = @import("release_adapter_dmg_authority");
const identity = @import("release_adapter_notification_candidate_identity");
const concrete = @import("release_adapter_notification_concrete");
const product = @import("release_adapter_notification_product");
const helper_child = @import("release_adapter_notification_helper_child");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");

pub const Inputs = struct {
    test_uuid: []const u8,
    candidate_dmg_sha256: []const u8,
    candidate_executable_sha256: []const u8,
    designated_requirement_sha256: []const u8,
    gui_zero: concrete.Inputs,
    gui_live_then_quit: concrete.Inputs,
    output_path: [:0]const u8,
    budget_ns: i128,
};

pub const Outcome = union(enum) {
    executed,
    not_provisioned: helper_child.Provisioning,
};

const Phase = enum { pristine, ready, not_provisioned, executed, published };

pub const Gate = struct {
    owner: ?*Gate = null,
    allocator: std.mem.Allocator = undefined,
    arena: ?std.heap.ArenaAllocator = null,
    io: std.Io = undefined,
    inputs: Inputs = undefined,
    deadline_ns: i128 = 0,
    authority: identity.Authority = .{},
    transaction: product.Execution = .{},
    zero_execution: concrete.Execution = .{},
    live_execution: concrete.Execution = .{},
    zero: ?concrete.Published = null,
    live: ?concrete.Published = null,
    provisioning_value: ?helper_child.Provisioning = null,
    leaf_bytes: ?[]u8 = null,
    published: files.PinnedReleaseFile = .{},
    zero_consumed: bool = false,
    live_consumed: bool = false,
    phase: Phase = .pristine,

    pub fn init(self: *@This(), allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) !void {
        if (!pristine(self)) return error.InvalidOwner;
        try validateInputs(inputs);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const captured = try captureInputs(arena.allocator(), inputs);
        self.owner = self;
        self.allocator = allocator;
        self.arena = arena;
        self.io = io;
        self.inputs = captured;
        self.deadline_ns = @intCast(inputs.gui_zero.app_expected.deadline_ns);
        self.phase = .ready;
    }

    /// DMG candidate-gate entrypoint. A typed provisioning reason remains queryable while the
    /// error stops the outer observer before publication.
    pub fn execute(self: *@This(), candidate: dmg.MountedCandidate) !void {
        var binder = RealBinder{};
        var runner = RealRunner{};
        const outcome = try self.executeInternal(&binder, &runner, candidate);
        switch (outcome) {
            .executed => {},
            .not_provisioned => return error.NotProvisioned,
        }
    }

    pub fn provisioning(self: *const @This()) ?helper_child.Provisioning {
        if (self.owner != self or self.phase != .not_provisioned) return null;
        return self.provisioning_value;
    }

    pub fn executeWith(self: *@This(), binder: anytype, runner: anytype, candidate: dmg.MountedCandidate) !Outcome {
        if (!builtin.is_test) @compileError("notification candidate gate injection is test-only");
        return self.executeInternal(binder, runner, candidate);
    }

    fn executeInternal(self: *@This(), binder: anytype, runner: anytype, candidate: dmg.MountedCandidate) !Outcome {
        try self.validate(.ready);
        var steps = Steps(@TypeOf(binder), @TypeOf(runner)){
            .gate = self,
            .binder = binder,
            .runner = runner,
            .candidate = candidate,
        };
        product.executeWith(&steps, &self.transaction) catch |err| {
            if (err == error.CleanupFailed or self.transaction.needsCleanup()) return error.CleanupFailed;
            if (self.authority.owner == &self.authority) self.authority.deinit() catch return error.CleanupFailed;
            if (err == error.NotProvisioned) {
                self.phase = .not_provisioned;
                return .{ .not_provisioned = self.provisioning_value orelse return error.InvalidResult };
            }
            self.resetAttempt();
            return err;
        };
        self.phase = .executed;
        return .executed;
    }

    pub fn publish(self: *@This(), candidate: dmg.MountedCandidate) !void {
        try self.validate(.executed);
        try self.revalidate(candidate);
        const bytes = self.leaf_bytes orelse return error.InvalidResult;
        try files.publishSummaryOwnedExclusive(&self.published, self.inputs.output_path, bytes);
        errdefer self.published.remove(self.inputs.output_path) catch {};
        var held = try self.published.readHeldAlloc(self.allocator, self.inputs.output_path, evidence.max_evidence_bytes);
        defer held.deinit(self.allocator);
        var parsed = try evidence.parseNotificationCenterLeaf(self.allocator, held.bytes);
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.test_uuid, self.inputs.test_uuid) or
            !std.mem.eql(u8, parsed.value.candidate_dmg_sha256, self.inputs.candidate_dmg_sha256) or
            !std.mem.eql(u8, parsed.value.candidate_executable_sha256, self.inputs.candidate_executable_sha256) or
            !std.mem.eql(u8, parsed.value.designated_requirement_sha256, self.inputs.designated_requirement_sha256))
            return error.EvidenceMismatch;
        self.phase = .published;
    }

    pub fn rollbackPublished(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.published.value() != null) try self.published.remove(self.inputs.output_path);
        if (self.phase == .published) self.phase = .executed;
    }

    pub fn readPublished(self: *@This(), allocator: std.mem.Allocator) !files.Input {
        try self.validate(.published);
        return self.published.readHeldAlloc(allocator, self.inputs.output_path, evidence.max_evidence_bytes);
    }

    pub fn finish(self: *@This()) !void {
        try self.validate(.published);
        var failed = false;
        self.published.deinit() catch {
            failed = true;
        };
        self.authority.deinit() catch {
            failed = true;
        };
        self.allocator.free(self.leaf_bytes.?);
        self.arena.?.deinit();
        self.* = .{};
        if (failed) return error.CleanupFailed;
    }

    pub fn finishNotProvisioned(self: *@This()) !void {
        try self.validate(.not_provisioned);
        self.arena.?.deinit();
        self.* = .{};
    }

    pub fn cleanup(self: *@This()) !void {
        var runner = RealRunner{};
        return self.cleanupInternal(&runner);
    }

    pub fn cleanupWith(self: *@This(), runner: anytype) !void {
        if (!builtin.is_test) @compileError("notification candidate gate cleanup injection is test-only");
        return self.cleanupInternal(runner);
    }

    fn cleanupInternal(self: *@This(), runner: anytype) !void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.published.value() != null) try self.published.remove(self.inputs.output_path);
        if (self.leaf_bytes) |bytes| {
            self.allocator.free(bytes);
            self.leaf_bytes = null;
        }
        if (self.transaction.needsCleanup()) {
            var binder = NoopBinder{};
            var steps = Steps(@TypeOf(&binder), @TypeOf(runner)){
                .gate = self,
                .binder = &binder,
                .runner = runner,
                .candidate = undefined,
            };
            try product.retryCleanupWith(&steps, &self.transaction);
        }
        if (self.authority.owner == &self.authority) try self.authority.deinit();
        self.arena.?.deinit();
        self.* = .{};
    }

    fn validate(self: *@This(), wanted: Phase) !void {
        if (self.owner != self or self.phase != wanted) return error.InvalidPhase;
    }

    fn revalidate(self: *@This(), candidate: dmg.MountedCandidate) !void {
        _ = try remaining(self.io, self.deadline_ns);
        try self.authority.revalidate(candidate);
    }

    fn resetAttempt(self: *@This()) void {
        self.transaction = .{};
        self.zero_execution = .{};
        self.live_execution = .{};
        self.zero = null;
        self.live = null;
        self.provisioning_value = null;
        self.zero_consumed = false;
        self.live_consumed = false;
    }
};

fn Steps(comptime Binder: type, comptime Runner: type) type {
    return struct {
        gate: *Gate,
        binder: Binder,
        runner: Runner,
        candidate: dmg.MountedCandidate,

        pub fn bindAuthorities(self: *@This()) !void {
            try matchCandidateInputs(self.gate.inputs, self.candidate);
            try self.binder.bind(self.gate.io, self.candidate, &self.gate.authority, self.gate.deadline_ns);
        }
        pub fn startDeadline(self: *@This()) !*i128 {
            const left = try remaining(self.gate.io, self.gate.deadline_ns);
            if (left > self.gate.inputs.budget_ns) return error.InvalidInput;
            return &self.gate.deadline_ns;
        }
        pub fn validateInitialAuthorities(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.gate.revalidate(self.candidate);
        }
        pub fn runGuiZero(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.runScenario(self.gate.inputs.gui_zero, &self.gate.zero_execution, &self.gate.zero);
        }
        pub fn validateAfterGuiZero(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.gate.revalidate(self.candidate);
        }
        pub fn runGuiLiveThenQuit(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.runScenario(self.gate.inputs.gui_live_then_quit, &self.gate.live_execution, &self.gate.live);
        }
        pub fn validateAfterGuiLiveThenQuit(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.gate.revalidate(self.candidate);
        }
        pub fn cleanupNotifications(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            const zero = self.gate.zero orelse return error.InvalidResult;
            const live = self.gate.live orelse return error.InvalidResult;
            const bytes = try evidence.writeNotificationCenterLeaf(self.gate.allocator, .{
                .test_uuid = self.gate.inputs.test_uuid,
                .candidate_dmg_sha256 = self.gate.inputs.candidate_dmg_sha256,
                .candidate_executable_sha256 = self.gate.inputs.candidate_executable_sha256,
                .designated_requirement_sha256 = self.gate.inputs.designated_requirement_sha256,
                .permission = .authorized,
                .gui_zero = zero.continuity.scenario,
                .gui_live_then_quit = live.continuity.scenario,
                .cleanup_complete = true,
            });
            errdefer self.gate.allocator.free(bytes);
            try self.cleanupGuiLiveThenQuit();
            try self.cleanupGuiZero();
            self.gate.leaf_bytes = bytes;
        }
        pub fn validateAfterCleanup(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.gate.revalidate(self.candidate);
        }
        pub fn publishEvidence(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            if (self.gate.leaf_bytes == null) return error.InvalidResult;
        }
        pub fn validateFinalAuthorities(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            try self.gate.revalidate(self.candidate);
        }
        pub fn validateFinalDeadline(self: *@This(), deadline: *i128) !void {
            try self.same(deadline);
            _ = try remaining(self.gate.io, deadline.*);
        }
        pub fn cleanupEvidence(self: *@This()) !void {
            if (self.gate.leaf_bytes) |bytes| self.gate.allocator.free(bytes);
            self.gate.leaf_bytes = null;
        }
        pub fn cleanupGuiLiveThenQuit(self: *@This()) !void {
            if (self.gate.live_consumed) return;
            try self.cleanupScenario(self.gate.inputs.gui_live_then_quit, &self.gate.live_execution);
            self.gate.live_consumed = true;
        }
        pub fn cleanupGuiZero(self: *@This()) !void {
            if (self.gate.zero_consumed) return;
            try self.cleanupScenario(self.gate.inputs.gui_zero, &self.gate.zero_execution);
            self.gate.zero_consumed = true;
        }

        fn runScenario(self: *@This(), inputs: concrete.Inputs, execution: *concrete.Execution, result: *?concrete.Published) !void {
            const observed = try self.runner.execute(self.gate.io, self.gate.allocator, inputs, execution);
            switch (observed) {
                .published => |value| result.* = value,
                .not_provisioned => |value| {
                    self.gate.provisioning_value = value;
                    return error.NotProvisioned;
                },
            }
        }
        fn cleanupScenario(self: *@This(), inputs: concrete.Inputs, execution: *concrete.Execution) !void {
            if (execution.owner.needsCleanup()) return self.runner.retryCleanup(self.gate.io, self.gate.allocator, inputs, execution);
            if (execution.owner.ownsReceipt()) return self.runner.finish(inputs.output_path, execution);
        }
        fn same(self: *@This(), deadline: *i128) !void {
            if (deadline != &self.gate.deadline_ns) return error.DeadlineChanged;
        }
    };
}

const RealBinder = struct {
    pub fn bind(_: *@This(), io: std.Io, candidate: dmg.MountedCandidate, result: *identity.Authority, deadline_ns: i128) !void {
        try identity.bindUntil(io, candidate, result, deadline_ns);
    }
};

const RealRunner = struct {
    pub fn execute(_: *@This(), io: std.Io, allocator: std.mem.Allocator, inputs: concrete.Inputs, execution: *concrete.Execution) !concrete.Result {
        return concrete.execute(io, allocator, inputs, execution);
    }
    pub fn finish(_: *@This(), output_path: [:0]const u8, execution: *concrete.Execution) !void {
        try concrete.finishSuccessful(output_path, execution);
    }
    pub fn retryCleanup(_: *@This(), io: std.Io, allocator: std.mem.Allocator, inputs: concrete.Inputs, execution: *concrete.Execution) !void {
        try concrete.retryCleanup(io, allocator, inputs, execution);
    }
};

const NoopBinder = struct {};

fn captureInputs(allocator: std.mem.Allocator, source: Inputs) !Inputs {
    return .{
        .test_uuid = try allocator.dupe(u8, source.test_uuid),
        .candidate_dmg_sha256 = try allocator.dupe(u8, source.candidate_dmg_sha256),
        .candidate_executable_sha256 = try allocator.dupe(u8, source.candidate_executable_sha256),
        .designated_requirement_sha256 = try allocator.dupe(u8, source.designated_requirement_sha256),
        .gui_zero = try captureScenario(allocator, source.gui_zero),
        .gui_live_then_quit = try captureScenario(allocator, source.gui_live_then_quit),
        .output_path = try allocator.dupeZ(u8, source.output_path),
        .budget_ns = source.budget_ns,
    };
}

fn captureScenario(allocator: std.mem.Allocator, source: concrete.Inputs) !concrete.Inputs {
    return .{
        .app_executable = try allocator.dupeZ(u8, source.app_executable),
        .helper_executable = try allocator.dupeZ(u8, source.helper_executable),
        .runtime_preparation_executable = if (source.runtime_preparation_executable) |value| try allocator.dupeZ(u8, value) else null,
        .runner_nonce = try allocator.dupe(u8, source.runner_nonce),
        .runner_root = try allocator.dupeZ(u8, source.runner_root),
        .output_path = try allocator.dupeZ(u8, source.output_path),
        .app_expected = .{
            .scenario = source.app_expected.scenario,
            .request_identifier = try allocator.dupe(u8, source.app_expected.request_identifier),
            .host_id = try allocator.dupe(u8, source.app_expected.host_id),
            .runtime_id = try allocator.dupe(u8, source.app_expected.runtime_id),
            .event_id = source.app_expected.event_id,
            .clicked_at_ns = source.app_expected.clicked_at_ns,
            .deadline_ns = source.app_expected.deadline_ns,
        },
        .helper_expected = .{
            .visible_nonce = try allocator.dupe(u8, source.helper_expected.visible_nonce),
            .deadline_ns = source.helper_expected.deadline_ns,
        },
        .submitted_at_ns = source.submitted_at_ns,
        .before_marker = try allocator.dupe(u8, source.before_marker),
        .after_marker = try allocator.dupe(u8, source.after_marker),
        .budget_ns = source.budget_ns,
    };
}

fn validateInputs(inputs: Inputs) !void {
    const zero_deadline = inputs.gui_zero.app_expected.deadline_ns;
    if (inputs.budget_ns <= 0 or zero_deadline == 0 or
        zero_deadline != inputs.gui_zero.helper_expected.deadline_ns or
        zero_deadline != inputs.gui_live_then_quit.app_expected.deadline_ns or
        zero_deadline != inputs.gui_live_then_quit.helper_expected.deadline_ns or
        inputs.gui_zero.app_expected.scenario != .gui_zero or
        inputs.gui_live_then_quit.app_expected.scenario != .gui_live_then_quit or
        invalidPreparationPair(inputs.gui_zero, inputs.gui_live_then_quit) or
        std.mem.eql(u8, inputs.gui_zero.output_path, inputs.gui_live_then_quit.output_path) or
        std.mem.eql(u8, inputs.output_path, inputs.gui_zero.output_path) or
        std.mem.eql(u8, inputs.output_path, inputs.gui_live_then_quit.output_path) or
        !canonicalUuid(inputs.test_uuid) or !lowerHex(inputs.candidate_dmg_sha256) or
        !lowerHex(inputs.candidate_executable_sha256) or !lowerHex(inputs.designated_requirement_sha256) or
        !absolute(inputs.output_path)) return error.InvalidInput;
    _ = std.math.cast(i128, zero_deadline) orelse return error.InvalidInput;
}

fn invalidPreparationPair(zero: concrete.Inputs, live: concrete.Inputs) bool {
    const prepared = zero.runtime_preparation_executable != null or live.runtime_preparation_executable != null;
    if (!prepared) return std.mem.eql(u8, zero.app_expected.request_identifier, live.app_expected.request_identifier);
    return zero.runtime_preparation_executable == null or live.runtime_preparation_executable == null or
        zero.app_expected.request_identifier.len != 0 or live.app_expected.request_identifier.len != 0 or
        zero.app_expected.host_id.len != 0 or live.app_expected.host_id.len != 0 or
        zero.app_expected.runtime_id.len != 0 or live.app_expected.runtime_id.len != 0 or
        zero.app_expected.event_id != 0 or live.app_expected.event_id != 0;
}

fn matchCandidateInputs(inputs: Inputs, candidate: dmg.MountedCandidate) !void {
    if (!std.mem.eql(u8, inputs.candidate_executable_sha256, candidate.main_sha256) or
        !std.mem.eql(u8, inputs.designated_requirement_sha256, candidate.designated_requirement_sha256) or
        !std.mem.eql(u8, inputs.gui_zero.app_executable, candidate.main_path) or
        !std.mem.eql(u8, inputs.gui_live_then_quit.app_executable, candidate.main_path) or
        !std.mem.eql(u8, inputs.gui_zero.helper_executable, candidate.helper_path) or
        !std.mem.eql(u8, inputs.gui_live_then_quit.helper_executable, candidate.helper_path) or
        (inputs.gui_zero.runtime_preparation_executable != null and
            (!std.mem.eql(u8, inputs.gui_zero.runtime_preparation_executable.?, candidate.mounted_cli_path) or
                !std.mem.eql(u8, inputs.gui_live_then_quit.runtime_preparation_executable.?, candidate.mounted_cli_path)))) return error.CandidateChanged;
}

fn remaining(io: std.Io, deadline_ns: i128) !i128 {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    if (now >= deadline_ns) return error.TimedOut;
    return deadline_ns - now;
}

fn pristine(self: *const Gate) bool {
    return self.owner == null and self.phase == .pristine and self.authority.owner == null and
        self.transaction.owner == null and self.published.owner == null and self.leaf_bytes == null;
}

fn lowerHex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn canonicalUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-' or value[14] != '4' or
        !(value[19] == '8' or value[19] == '9' or value[19] == 'a' or value[19] == 'b')) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn absolute(path: [:0]const u8) bool {
    return path.len >= 2 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}
