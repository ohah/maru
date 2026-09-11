//! Outer execution owner for the P5d CLI/SSH harness.
//!
//! It creates the only scratch root, launches one bounded process group with a closed environment,
//! and removes that exact root after the child has reached a terminal, reaped state.

const std = @import("std");
const bounded = @import("bounded_process");
const workspace_mod = @import("release_adapter_p5d_workspace");

const shell: [:0]const u8 = "/bin/sh";
const path_entry: [:0]const u8 = "PATH=/usr/bin:/bin";

pub const Inputs = struct {
    workspace_path: [:0]const u8,
    harness: [:0]const u8,
    candidate_cli: [:0]const u8,
    attach_product_test: [:0]const u8,
    upload_product_test: [:0]const u8,
    require_developer_id: bool,
    budget_ns: i128,
};

pub const CommandStorage = struct {
    workspace_environment: ["MARU_P5D_WORKSPACE=".len + std.fs.max_path_bytes:0]u8 = undefined,
    args: [5][:0]const u8 = undefined,
    environment: [3][:0]const u8 = undefined,
};

pub const CommandPlan = struct {
    executable: [:0]const u8,
    args: []const [:0]const u8,
    environment: []const [:0]const u8,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    workspace: workspace_mod.Workspace = .{},

    pub fn cleanup(self: *@This(), io: std.Io) !void {
        if (self.owner != self) return error.InvalidOwner;
        self.workspace.cleanup(io) catch return error.CleanupFailed;
        self.* = .{};
    }
};

pub fn run(io: std.Io, execution: *Execution, inputs: Inputs, output: []u8) ![]const u8 {
    if (output.len == 0) return error.InvalidBudget;
    if (!pristine(execution) or overlaps(std.mem.asBytes(execution), output) or
        aliasesInputs(std.mem.asBytes(execution), inputs)) return error.InvalidOwner;
    var storage: CommandStorage = .{};
    const plan = try commandPlan(inputs, &storage);
    workspace_mod.prepare(&execution.workspace, inputs.workspace_path) catch |err| {
        if (execution.workspace.owner == &execution.workspace) execution.owner = execution;
        return err;
    };
    execution.owner = execution;

    var argv: [6:null]?[*:0]const u8 = @splat(null);
    var environment: [4:null]?[*:0]const u8 = @splat(null);
    for (plan.args, 0..) |arg, index| argv[index] = arg.ptr;
    for (plan.environment, 0..) |entry, index| environment[index] = entry.ptr;

    var child_error: ?anyerror = null;
    const captured = bounded.runCaptureEnvironment(
        io,
        plan.executable,
        &argv,
        &environment,
        output,
        inputs.budget_ns,
    ) catch |err| result: {
        child_error = err;
        break :result output[0..0];
    };

    // bounded_process returns only after the exact child is reaped and its process group has been
    // terminated on failure. Cleanup therefore has one writer and may safely be authoritative.
    execution.cleanup(io) catch return error.CleanupFailed;
    if (child_error) |err| return err;
    return captured;
}

fn commandPlan(inputs: Inputs, storage: *CommandStorage) !CommandPlan {
    if (inputs.budget_ns <= 0 or !absolute(inputs.workspace_path) or !absolute(inputs.harness) or
        !absolute(inputs.candidate_cli) or !absolute(inputs.attach_product_test) or
        !absolute(inputs.upload_product_test)) return error.InvalidCommand;
    const workspace_environment = std.fmt.bufPrintZ(
        &storage.workspace_environment,
        "MARU_P5D_WORKSPACE={s}",
        .{inputs.workspace_path},
    ) catch return error.InvalidCommand;
    storage.args = .{ shell, inputs.harness, inputs.candidate_cli, inputs.attach_product_test, inputs.upload_product_test };
    storage.environment = .{
        path_entry,
        if (inputs.require_developer_id) "MARU_P5D_REQUIRE_DEVELOPER_ID=1" else "MARU_P5D_REQUIRE_DEVELOPER_ID=0",
        workspace_environment,
    };
    return .{ .executable = shell, .args = &storage.args, .environment = &storage.environment };
}

pub fn commandPlanForTest(inputs: Inputs, storage: *CommandStorage) !CommandPlan {
    if (!@import("builtin").is_test) @compileError("commandPlanForTest is a test-only seam");
    return commandPlan(inputs, storage);
}

fn absolute(path: [:0]const u8) bool {
    return path.len >= 2 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn pristine(execution: *const Execution) bool {
    return execution.owner == null and execution.workspace.owner == null and execution.workspace.root.owner == null;
}

fn aliasesInputs(bytes: []const u8, inputs: Inputs) bool {
    inline for (.{ inputs.workspace_path, inputs.harness, inputs.candidate_cli, inputs.attach_product_test, inputs.upload_product_test }) |value|
        if (overlaps(bytes, value)) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
