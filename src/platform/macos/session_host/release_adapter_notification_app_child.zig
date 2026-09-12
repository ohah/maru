//! Closed launch boundary for the Maru app side of one notification release scenario.
//!
//! The app receives no ambient environment and can publish protocol bytes only through inherited
//! fd 3. Its process group remains separately owned after receipt EOF so the composition owner can
//! remove the exact notification before terminating the GUI.

const std = @import("std");
const builtin = @import("builtin");
const bounded = @import("bounded_process");
const receipt = @import("release_adapter_notification_app_receipt");

const inherited_receipt_fd = "3";
const arm = "MARU_SESSION_HOST_NOTIFICATION_APP_SCENARIO=maru-release-v1";

pub const Inputs = struct {
    executable: [:0]const u8,
    expected: receipt.Expected,
    runner_nonce: []const u8,
    runner_root: []const u8,
};

pub const CommandStorage = struct {
    scenario: [96:0]u8 = undefined,
    request: [192:0]u8 = undefined,
    host: [96:0]u8 = undefined,
    runtime: [96:0]u8 = undefined,
    event: [96:0]u8 = undefined,
    deadline: [96:0]u8 = undefined,
    nonce: [128:0]u8 = undefined,
    root: [std.fs.max_path_bytes:0]u8 = undefined,
    session_root: [std.fs.max_path_bytes:0]u8 = undefined,
    home: [std.fs.max_path_bytes:0]u8 = undefined,
    fixed_home: [std.fs.max_path_bytes:0]u8 = undefined,
    environment: [13][:0]const u8 = undefined,
};

pub const Plan = struct {
    executable: [:0]const u8,
    environment: []const [:0]const u8,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    child: bounded.InheritedPipeChild = .{},

    pub fn readReceipt(self: *@This(), io: std.Io, output: []u8, budget_ns: i128) ![]const u8 {
        if (self.owner != self) return error.InvalidOwner;
        return self.child.readReceipt(io, output, budget_ns);
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.owner != self) return error.InvalidOwner;
        try self.child.terminate();
        self.* = .{};
    }
};

pub fn launch(inputs: Inputs, execution: *Execution) !void {
    var executor = RealExecutor{};
    try launchInternal(&executor, inputs, execution);
}

pub fn launchWith(executor: anytype, inputs: Inputs, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("launchWith is a test-only seam");
    try launchInternal(executor, inputs, execution);
}

fn launchInternal(executor: anytype, inputs: Inputs, execution: *Execution) !void {
    if (execution.owner != null or execution.child.owner != null or execution.child.pid != -1 or
        execution.child.read_fd != -1 or execution.child.receipt_complete or execution.child.receipt_failed) return error.InvalidOwner;
    if (aliasesInputs(std.mem.asBytes(execution), inputs)) return error.InvalidOwner;
    var storage: CommandStorage = .{};
    const plan = try commandPlan(inputs, &storage);
    executor.spawn(plan, &execution.child) catch |err| {
        if (execution.child.owner == &execution.child) execution.owner = execution;
        return err;
    };
    if (execution.child.owner != &execution.child) return error.InvalidOwner;
    execution.owner = execution;
}

fn commandPlan(inputs: Inputs, storage: *CommandStorage) !Plan {
    try receipt.validateExpected(inputs.expected);
    if (!validAbsolute(inputs.executable) or !canonicalUuid(inputs.runner_nonce)) return error.InvalidInput;
    var compact_nonce: [32]u8 = undefined;
    var cursor: usize = 0;
    for (inputs.runner_nonce) |byte| if (byte != '-') {
        compact_nonce[cursor] = byte;
        cursor += 1;
    };
    var canonical_root_storage: [96]u8 = undefined;
    const canonical_root = std.fmt.bufPrint(&canonical_root_storage, "/private/tmp/mn-{s}", .{compact_nonce}) catch return error.InvalidInput;
    if (!std.mem.eql(u8, inputs.runner_root, canonical_root)) return error.InvalidInput;

    const scenario = try env(&storage.scenario, "MARU_SESSION_HOST_NOTIFICATION_SCENARIO", inputs.expected.scenario.wire());
    const request_value = try env(&storage.request, "MARU_SESSION_HOST_NOTIFICATION_REQUEST", inputs.expected.request_identifier);
    const host_value = try env(&storage.host, "MARU_SESSION_HOST_NOTIFICATION_HOST_ID", inputs.expected.host_id);
    const runtime_value = try env(&storage.runtime, "MARU_SESSION_HOST_NOTIFICATION_RUNTIME_ID", inputs.expected.runtime_id);
    const event_value = try envInt(&storage.event, "MARU_SESSION_HOST_NOTIFICATION_EVENT_ID", inputs.expected.event_id);
    const deadline_value = try envInt(&storage.deadline, "MARU_SESSION_HOST_NOTIFICATION_DEADLINE_NS", inputs.expected.deadline_ns);
    const nonce_value = try env(&storage.nonce, "MARU_SESSION_HOST_NOTIFICATION_RUNNER_NONCE", inputs.runner_nonce);
    const root_value = try env(&storage.root, "MARU_SESSION_HOST_NOTIFICATION_RUNNER_ROOT", inputs.runner_root);
    const session_root = try childEnv(&storage.session_root, "MARU_SESSION_HOST_ROOT", inputs.runner_root, "/s");
    const home = try childEnv(&storage.home, "HOME", inputs.runner_root, "/h");
    const fixed_home = try childEnv(&storage.fixed_home, "CFFIXED_USER_HOME", inputs.runner_root, "/h");
    storage.environment = .{
        arm,
        scenario,
        request_value,
        host_value,
        runtime_value,
        event_value,
        deadline_value,
        "MARU_SESSION_HOST_NOTIFICATION_RECEIPT_FD=" ++ inherited_receipt_fd,
        nonce_value,
        root_value,
        session_root,
        home,
        fixed_home,
    };
    return .{ .executable = inputs.executable, .environment = &storage.environment };
}

pub fn commandPlanForTest(inputs: Inputs, storage: *CommandStorage) !Plan {
    if (!builtin.is_test) @compileError("commandPlanForTest is a test-only seam");
    return commandPlan(inputs, storage);
}

const RealExecutor = struct {
    fn spawn(_: *@This(), plan: Plan, child: *bounded.InheritedPipeChild) !void {
        var argv = [_:null]?[*:0]const u8{plan.executable.ptr};
        var environment: [14:null]?[*:0]const u8 = @splat(null);
        for (plan.environment, 0..) |entry, index| environment[index] = entry.ptr;
        try bounded.spawnEnvironmentInheritedPipe(plan.executable, &argv, &environment, child);
    }
};

fn env(storage: anytype, name: []const u8, value: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}={s}", .{ name, value }) catch error.InvalidInput;
}

fn envInt(storage: anytype, name: []const u8, value: u64) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}={d}", .{ name, value }) catch error.InvalidInput;
}

fn childEnv(storage: anytype, name: []const u8, root: []const u8, suffix: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}={s}{s}", .{ name, root, suffix }) catch error.InvalidInput;
}

fn validAbsolute(value: []const u8) bool {
    if (value.len < 2 or value.len >= std.fs.max_path_bytes or value[0] != '/' or value[value.len - 1] == '/') return false;
    for (value) |byte| if (byte == 0 or std.ascii.isControl(byte)) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn aliasesInputs(destination: []const u8, inputs: Inputs) bool {
    const values = [_][]const u8{
        inputs.executable,
        inputs.expected.request_identifier,
        inputs.expected.host_id,
        inputs.expected.runtime_id,
        inputs.runner_nonce,
        inputs.runner_root,
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

fn canonicalUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-' or value[14] != '4') return false;
    if (value[19] != '8' and value[19] != '9' and value[19] != 'a' and value[19] != 'b') return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return false;
    }
    return true;
}
