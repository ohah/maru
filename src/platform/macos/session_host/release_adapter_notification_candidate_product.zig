//! Product composition for the provisioned Notification Center gate against one mounted DMG.
//!
//! Paths inside the DMG do not exist until `release_adapter_dmg_authority` owns the read-only
//! mount. This adapter therefore snapshots only runner-owned scenario data up front and fills the
//! app/helper paths from the `MountedCandidate` delivered by that owner.

const std = @import("std");
const dmg = @import("release_adapter_dmg_authority");
const apple_product = @import("release_adapter_apple_product");
const apple_transport = @import("release_adapter_apple_transport");
const concrete = @import("release_adapter_notification_concrete");
const gate_mod = @import("release_adapter_notification_candidate_gate");
const helper_child = @import("release_adapter_notification_helper_child");

pub const Scenario = struct {
    runner_nonce: []const u8,
    runner_root: [:0]const u8,
    output_path: [:0]const u8,
    app_expected: @import("release_adapter_notification_app_receipt").Expected,
    helper_expected: @import("release_adapter_notification_helper_receipt").Expected,
    submitted_at_ns: u64,
    before_marker: []const u8,
    after_marker: []const u8,
    budget_ns: i128,
};

pub const Inputs = struct {
    candidate_dmg: [:0]const u8,
    private_dmg_work: [:0]const u8,
    expected_dmg: dmg.ExpectedDmg,
    expected_version: []const u8,
    test_uuid: []const u8,
    candidate_executable_sha256: []const u8,
    designated_requirement_sha256: []const u8,
    gui_zero: Scenario,
    gui_live_then_quit: Scenario,
    output_path: [:0]const u8,
    budget_ns: i128,
};

pub const Adapter = struct {
    owner: ?*@This() = null,
    allocator: std.mem.Allocator = undefined,
    arena: ?std.heap.ArenaAllocator = null,
    io: std.Io = undefined,
    inputs: Inputs = undefined,
    gate: gate_mod.Gate = .{},

    pub fn init(self: *@This(), allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) !void {
        if (self.owner != null or self.gate.owner != null) return error.InvalidOwner;
        if (inputs.budget_ns <= 0) return error.InvalidInput;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const captured = try captureInputs(arena.allocator(), inputs);
        self.* = .{ .owner = self, .allocator = allocator, .arena = arena, .io = io, .inputs = captured };
    }

    pub fn execute(self: *@This(), candidate: dmg.MountedCandidate) !void {
        if (self.owner != self or self.gate.owner != null) return error.InvalidOwner;
        const gate_inputs = materialize(&self.inputs, candidate);
        try self.gate.init(self.allocator, self.io, gate_inputs);
        self.gate.execute(candidate) catch |err| {
            // Provisioning is a typed terminal observation, not a generic failure. Keep the inner
            // owner alive until the outer workflow records which prerequisite was absent.
            if (err == error.NotProvisioned) return err;
            if (self.gate.owner == &self.gate) self.gate.cleanup() catch return error.CleanupFailed;
            return err;
        };
    }

    pub fn publish(self: *@This(), candidate: dmg.MountedCandidate) !void {
        if (self.owner != self) return error.InvalidOwner;
        try self.gate.publish(candidate);
    }

    pub fn rollbackPublished(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        try self.gate.rollbackPublished();
    }

    pub fn provisioning(self: *const @This()) ?helper_child.Provisioning {
        if (self.owner != self) return null;
        return self.gate.provisioning();
    }

    pub fn finishNotProvisioned(self: *@This()) !void {
        if (self.owner != self or self.provisioning() == null) return error.InvalidOwner;
        try self.gate.finishNotProvisioned();
        self.arena.?.deinit();
        self.* = .{};
    }

    pub fn finish(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        try self.gate.finish();
        self.arena.?.deinit();
        self.* = .{};
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        if (self.gate.owner == &self.gate) try self.gate.cleanup();
        self.arena.?.deinit();
        self.* = .{};
    }
};

/// On success `result` owns the published notification leaf until `finish`. A typed
/// `NotProvisioned` result remains available through `provisioning` until
/// `finishNotProvisioned`; every other failure leaves exact retry cleanup authority in `result`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    apple_storage: *apple_transport.Storage,
    result: *Adapter,
) !apple_product.Observed {
    try result.init(allocator, io, inputs);
    return dmg.observeWithMountedGate(
        allocator,
        io,
        result,
        result.inputs.candidate_dmg,
        result.inputs.private_dmg_work,
        result.inputs.expected_dmg,
        result.inputs.expected_version,
        apple_storage,
        result.inputs.budget_ns,
    );
}

pub fn materializeForTest(inputs: *const Inputs, candidate: dmg.MountedCandidate) gate_mod.Inputs {
    if (!@import("builtin").is_test) @compileError("test-only materialization seam");
    return materialize(inputs, candidate);
}

fn materialize(inputs: *const Inputs, candidate: dmg.MountedCandidate) gate_mod.Inputs {
    return .{
        .test_uuid = inputs.test_uuid,
        .candidate_dmg_sha256 = &inputs.expected_dmg.sha256,
        .candidate_executable_sha256 = inputs.candidate_executable_sha256,
        .designated_requirement_sha256 = inputs.designated_requirement_sha256,
        .gui_zero = scenario(inputs.gui_zero, candidate),
        .gui_live_then_quit = scenario(inputs.gui_live_then_quit, candidate),
        .output_path = inputs.output_path,
        .budget_ns = inputs.budget_ns,
    };
}

fn captureInputs(allocator: std.mem.Allocator, source: Inputs) !Inputs {
    return .{
        .candidate_dmg = try allocator.dupeZ(u8, source.candidate_dmg),
        .private_dmg_work = try allocator.dupeZ(u8, source.private_dmg_work),
        .expected_dmg = source.expected_dmg,
        .expected_version = try allocator.dupe(u8, source.expected_version),
        .test_uuid = try allocator.dupe(u8, source.test_uuid),
        .candidate_executable_sha256 = try allocator.dupe(u8, source.candidate_executable_sha256),
        .designated_requirement_sha256 = try allocator.dupe(u8, source.designated_requirement_sha256),
        .gui_zero = try captureScenario(allocator, source.gui_zero),
        .gui_live_then_quit = try captureScenario(allocator, source.gui_live_then_quit),
        .output_path = try allocator.dupeZ(u8, source.output_path),
        .budget_ns = source.budget_ns,
    };
}

fn captureScenario(allocator: std.mem.Allocator, source: Scenario) !Scenario {
    return .{
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

fn scenario(input: Scenario, candidate: dmg.MountedCandidate) concrete.Inputs {
    return .{
        .app_executable = candidate.main_path,
        .helper_executable = candidate.helper_path,
        .runner_nonce = input.runner_nonce,
        .runner_root = input.runner_root,
        .output_path = input.output_path,
        .app_expected = input.app_expected,
        .helper_expected = input.helper_expected,
        .submitted_at_ns = input.submitted_at_ns,
        .before_marker = input.before_marker,
        .after_marker = input.after_marker,
        .budget_ns = input.budget_ns,
    };
}
