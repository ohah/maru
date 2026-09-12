//! Concrete app/helper composition for one Notification Center release scenario.

const std = @import("std");
const owner = @import("release_adapter_notification_process_owner");
const app_child = @import("release_adapter_notification_app_child");
const app_receipt = @import("release_adapter_notification_app_receipt");
const continuity_receipt = @import("release_adapter_notification_continuity_receipt");
const helper_child = @import("release_adapter_notification_helper_child");
const helper_receipt = @import("release_adapter_notification_helper_receipt");
const runtime_preparation = @import("release_adapter_notification_runtime_preparation");
const workspace = @import("release_adapter_notification_workspace");
const files = @import("release_adapter_files");

pub const Inputs = struct {
    app_executable: [:0]const u8,
    helper_executable: [:0]const u8,
    runtime_preparation_executable: ?[:0]const u8 = null,
    runner_nonce: []const u8,
    runner_root: [:0]const u8,
    output_path: [:0]const u8,
    app_expected: app_receipt.Expected,
    helper_expected: helper_receipt.Expected,
    submitted_at_ns: u64,
    before_marker: []const u8,
    after_marker: []const u8,
    budget_ns: i128,
};

pub const Execution = struct {
    owner: owner.Execution = .{},
    root: workspace.Workspace = .{},
    app: app_child.Execution = .{},
    helper: helper_child.Storage = .{},
    receipt: files.PinnedReleaseFile = .{},
    preparation: runtime_preparation.Prepared = .{},
    app_frame: [app_receipt.max_receipt_bytes]u8 = undefined,
    continuity_frame: [continuity_receipt.max_receipt_bytes]u8 = undefined,
    cleanup_frame: [512]u8 = undefined,
    app_cleanup_proved_runtime_gone: bool = false,
};

pub const Published = struct {
    app: app_receipt.Observed,
    continuity: continuity_receipt.Observed,
};

pub const Result = union(enum) {
    published: Published,
    not_provisioned: helper_child.Provisioning,
};

pub fn execute(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, execution: *Execution) !Result {
    var steps = Steps{ .io = io, .allocator = allocator, .inputs = inputs, .execution = execution };
    owner.executeWith(&steps, &execution.owner) catch |err| {
        if (err == error.NotProvisioned) return steps.result orelse error.NotProvisioned;
        return err;
    };
    return steps.result orelse error.InvalidReceipt;
}

pub fn retryCleanup(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, execution: *Execution) !void {
    var steps = Steps{ .io = io, .allocator = allocator, .inputs = inputs, .execution = execution };
    try owner.retryCleanupWith(&steps, &execution.owner);
}

/// Consumes the one durable scenario receipt after the outer R2 transaction has derived its
/// final evidence. A failed unlink keeps the exact held-file authority retryable.
pub fn finishSuccessful(output_path: [:0]const u8, execution: *Execution) !void {
    if (!execution.owner.ownsReceipt() or execution.receipt.value() == null) return error.InvalidOwner;
    try execution.receipt.remove(output_path);
    execution.* = .{};
}

const Steps = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    execution: *Execution,
    deadline_ns: i128 = 0,
    app_frame_len: usize = 0,
    continuity_frame_len: usize = 0,
    result: ?Result = null,

    pub fn bind(self: *@This()) !void {
        if (self.inputs.runtime_preparation_executable == null) {
            try app_child.validateInputs(.{
                .executable = self.inputs.app_executable,
                .expected = self.inputs.app_expected,
                .runner_nonce = self.inputs.runner_nonce,
                .runner_root = self.inputs.runner_root,
            });
        } else if (self.inputs.app_expected.request_identifier.len != 0 or
            self.inputs.app_expected.host_id.len != 0 or self.inputs.app_expected.runtime_id.len != 0 or
            self.inputs.app_expected.event_id != 0)
            return error.InvalidInput;
        try helper_child.validateInputs(self.inputs.helper_executable, self.inputs.helper_expected, self.inputs.budget_ns);
        if (!canonicalAbsolute(self.inputs.output_path) or
            self.inputs.app_expected.deadline_ns != self.inputs.helper_expected.deadline_ns or
            self.inputs.submitted_at_ns == 0 or self.inputs.submitted_at_ns >= self.inputs.app_expected.deadline_ns or
            !canonicalScalar(self.inputs.before_marker) or !canonicalScalar(self.inputs.after_marker) or
            std.mem.eql(u8, self.inputs.before_marker, self.inputs.after_marker) or
            !std.mem.startsWith(u8, self.inputs.helper_expected.visible_nonce, self.inputs.runner_nonce) or
            aliasesExecution(self.execution, self.inputs))
            return error.InvalidInput;
    }

    pub fn startDeadline(self: *@This()) !*i128 {
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.deadline_ns = self.inputs.app_expected.deadline_ns;
        if (self.deadline_ns <= now or self.deadline_ns - now > self.inputs.budget_ns)
            return error.InvalidInput;
        return &self.deadline_ns;
    }

    pub fn createRoot(self: *@This(), _: *i128) !void {
        try workspace.prepare(&self.execution.root, self.inputs.runner_root);
    }

    /// R2 receives an already prepared scenario today. R3b2 replaces this no-op through the
    /// product composition, after this owner has created the private root and before AppKit can
    /// observe the runtime. The hook is deliberately part of the production ordering contract.
    pub fn prepareRuntime(self: *@This(), deadline: *i128) !void {
        const executable = self.inputs.runtime_preparation_executable orelse return;
        try runtime_preparation.prepare(self.allocator, self.io, .{
            .executable = executable,
            .runner_root = self.inputs.runner_root,
            .runner_nonce = self.inputs.runner_nonce,
            .visible_nonce = self.inputs.helper_expected.visible_nonce,
            .before_marker = self.inputs.before_marker,
            .deadline_ns = deadline.*,
        }, &self.execution.preparation);
        self.inputs.app_expected.request_identifier = self.execution.preparation.requestIdentifier();
        self.inputs.app_expected.host_id = self.execution.preparation.hostId();
        self.inputs.app_expected.runtime_id = self.execution.preparation.runtimeId();
        self.inputs.app_expected.event_id = 1;
        try app_child.validateInputs(.{
            .executable = self.inputs.app_executable,
            .expected = self.inputs.app_expected,
            .runner_nonce = self.inputs.runner_nonce,
            .runner_root = self.inputs.runner_root,
        });
    }

    pub fn launchApp(self: *@This(), _: *i128) !void {
        try app_child.launch(.{
            .executable = self.inputs.app_executable,
            .expected = self.inputs.app_expected,
            .runner_nonce = self.inputs.runner_nonce,
            .runner_root = self.inputs.runner_root,
        }, &self.execution.app);
    }

    pub fn emitNotification(self: *@This(), _: *i128) !void {
        if (self.inputs.runtime_preparation_executable != null)
            try runtime_preparation.emit(&self.execution.preparation);
    }

    pub fn runHelper(self: *@This(), deadline: *i128) !helper_child.Clicked {
        const observed = try helper_child.run(self.io, self.allocator, self.inputs.helper_executable, self.inputs.helper_expected, try remaining(self.io, deadline.*), &self.execution.helper);
        return switch (observed) {
            .clicked => |click| click,
            .not_provisioned => |kind| {
                self.result = .{ .not_provisioned = kind };
                return error.NotProvisioned;
            },
        };
    }

    pub fn collectAppReceipt(self: *@This(), deadline: *i128) ![]const u8 {
        const bytes = try self.execution.app.readReceipt(self.io, &self.execution.app_frame, try remaining(self.io, deadline.*));
        self.app_frame_len = bytes.len;
        return self.execution.app_frame[0..self.app_frame_len];
    }

    pub fn collectContinuityReceipt(self: *@This(), deadline: *i128) ![]const u8 {
        const bytes = try self.execution.app.readReceipt(self.io, &self.execution.continuity_frame, try remaining(self.io, deadline.*));
        self.continuity_frame_len = bytes.len;
        return self.execution.continuity_frame[0..self.continuity_frame_len];
    }

    pub fn publishReceipt(self: *@This(), _: *i128, click: helper_child.Clicked, app_bytes: []const u8, continuity_bytes: []const u8) !void {
        var expected = self.inputs.app_expected;
        expected.clicked_at_ns = click.clicked_at_ns;
        const app_observed = try app_receipt.parse(self.allocator, app_bytes, expected);
        const continuity_observed = try continuity_receipt.parse(self.allocator, continuity_bytes, .{
            .visible_nonce = self.inputs.helper_expected.visible_nonce,
            .app = expected,
            .app_receipt_bytes = app_bytes,
            .helper_receipt_bytes = click.receipt_bytes,
            .submitted_at_ns = self.inputs.submitted_at_ns,
            .before_marker = self.inputs.before_marker,
            .after_marker = self.inputs.after_marker,
        });
        try files.publishSummaryOwnedExclusive(&self.execution.receipt, self.inputs.output_path, continuity_bytes);
        self.result = .{ .published = .{ .app = app_observed, .continuity = continuity_observed } };
    }

    pub fn cleanupReceipt(self: *@This()) !void {
        if (self.execution.receipt.owner == null) return;
        self.execution.receipt.remove(self.inputs.output_path) catch return error.CleanupFailed;
    }

    pub fn cleanupRequest(self: *@This()) !void {
        if (self.execution.app.owner == null) return;
        try self.execution.app.requestCleanup(self.io, self.actualExpected(), &self.execution.cleanup_frame, try remaining(self.io, self.deadline_ns));
        self.execution.app_cleanup_proved_runtime_gone = true;
    }

    pub fn cleanupHelper(_: *@This()) !void {}

    pub fn cleanupApp(self: *@This()) !void {
        if (self.execution.app.owner == null) return;
        try self.execution.app.cleanup();
    }

    pub fn cleanupRuntime(self: *@This()) !void {
        if (self.execution.preparation.owner != &self.execution.preparation) return;
        if (self.execution.app_cleanup_proved_runtime_gone) {
            try runtime_preparation.releaseAfterAppCleanup(&self.execution.preparation);
            self.execution.app_cleanup_proved_runtime_gone = false;
        } else {
            try runtime_preparation.cleanup(self.io, &self.execution.preparation);
        }
    }

    pub fn cleanupRoot(self: *@This()) !void {
        if (self.execution.root.owner == null) return;
        try self.execution.root.cleanup(self.io);
    }

    fn actualExpected(self: *@This()) app_receipt.Expected {
        if (self.execution.preparation.owner != &self.execution.preparation) return self.inputs.app_expected;
        var expected = self.inputs.app_expected;
        expected.request_identifier = self.execution.preparation.requestIdentifier();
        expected.host_id = self.execution.preparation.hostId();
        expected.runtime_id = self.execution.preparation.runtimeId();
        expected.event_id = 1;
        return expected;
    }
};

fn remaining(io: std.Io, deadline_ns: i128) !i128 {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    if (now >= deadline_ns) return error.TimedOut;
    return deadline_ns - now;
}

fn aliasesExecution(execution: *Execution, inputs: Inputs) bool {
    const destination = std.mem.asBytes(execution);
    const values = [_][]const u8{
        inputs.app_executable,
        inputs.helper_executable,
        inputs.runtime_preparation_executable orelse "",
        inputs.runner_nonce,
        inputs.runner_root,
        inputs.output_path,
        inputs.app_expected.request_identifier,
        inputs.app_expected.host_id,
        inputs.app_expected.runtime_id,
        inputs.helper_expected.visible_nonce,
        inputs.before_marker,
        inputs.after_marker,
    };
    for (values) |value| if (overlaps(destination, value)) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn canonicalAbsolute(value: []const u8) bool {
    if (value.len < 2 or value.len >= std.fs.max_path_bytes or value[0] != '/' or value[value.len - 1] == '/') return false;
    for (value) |byte| if (byte == 0 or std.ascii.isControl(byte)) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component|
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn canonicalScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}
