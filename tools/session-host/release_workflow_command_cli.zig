//! Product fresh-process bridge for validator-backed live workflow stages.

const std = @import("std");
const context = @import("release_adapter_context");
const contract = @import("release_adapter_contract");
const environment = @import("release_adapter_environment");
const owner = @import("release_adapter_live_workflow_owner");
const command_process = @import("release_adapter_live_workflow_command_process");
const profile = @import("release_adapter_profile_endorsement");
const c = std.c;

pub const profiled_option_count: usize = 22;
const max_run_arguments: usize = 3 + contract.max_command_args;
pub const max_arguments: usize = 3 + 2 * profiled_option_count;
pub const Error = owner.Error || context.Error || profile.Error || contract.Error || error{
    InvalidArguments,
    InvalidCommand,
    InvalidPath,
    TooManyArguments,
};

pub const ProfiledCommand = struct {
    root_path: []const u8,
    root_identity: []const u8,
    baseline_args: [contract.max_command_args][]const u8,
    profile_args: [contract.max_command_args][]const u8,

    pub fn validatorArgs(self: *const @This(), selected: profile.Profile) []const []const u8 {
        return switch (selected) {
            .baseline_a => &self.baseline_args,
            .upgrade_b => &self.profile_args,
        };
    }
};

const ProfiledExecution = struct {
    const State = enum { pristine, ready, active, consumed };
    owner: ?*@This() = null,
    state: State = .pristine,
    argument_bytes: [max_arguments][contract.max_cli_value_bytes]u8 = undefined,
    argument_slices: [max_arguments][]const u8 = undefined,
    parsed: ?ProfiledCommand = null,
    profile_owner: profile.Owner = .{},

    fn init(self: *@This(), allocator: std.mem.Allocator, args: []const []const u8, workflow: context.Context, profile_environment: profile.Environment) Error!void {
        if (self.owner != null or self.state != .pristine or self.parsed != null or !self.profile_owner.isPristineForComposition()) return error.InvalidOwner;
        if (args.len != max_arguments) return if (args.len > max_arguments) error.TooManyArguments else error.InvalidArguments;
        for (args) |arg| {
            if (arg.len > contract.max_cli_value_bytes or overlaps(arg, std.mem.asBytes(self))) return error.InvalidOwner;
        }
        self.owner = self;
        errdefer self.deinit() catch {};
        for (args, 0..) |arg, index| {
            @memcpy(self.argument_bytes[index][0..arg.len], arg);
            self.argument_slices[index] = self.argument_bytes[index][0..arg.len];
        }
        self.parsed = try parseProfiled(self.argument_slices[0..args.len]);
        try profile.bindFromEnvironment(allocator, workflow, profile_environment, &self.profile_owner);
        self.state = .ready;
    }

    fn run(self: *@This(), io: std.Io, allocator: std.mem.Allocator, workflow: context.Context, profile_environment: profile.Environment) Error!void {
        if (self.owner != self or self.state != .ready or self.parsed == null) return error.InvalidOwner;
        self.state = .active;
        defer self.state = .consumed;
        const selected = (try self.profile_owner.revalidateEnvironment(allocator, workflow, profile_environment)).profile();
        var parsed = &self.parsed.?;
        try executeCommand(io, allocator, parsed.root_path, parsed.root_identity, parsed.validatorArgs(selected), workflow);
    }

    fn deinit(self: *@This()) Error!void {
        if (self.owner != self) return error.InvalidOwner;
        var failed = false;
        if (self.profile_owner.owner == &self.profile_owner) self.profile_owner.deinit() catch {
            failed = true;
        };
        @memset(std.mem.asBytes(&self.argument_bytes), 0);
        @memset(std.mem.asBytes(&self.argument_slices), 0);
        @memset(std.mem.asBytes(&self.parsed), 0);
        self.* = .{};
        if (failed) return error.InvalidOwner;
    }
};

const profiled_options = [_][]const u8{
    "--repo",                "--tag",                   "--github-cli",              "--github-cli-sha256", "--test-uuid",          "--dmg",
    "--frozen-executable",   "--candidate-dmg-bundle",  "--candidate-frozen-bundle", "--dmg-work",          "--baseline-workspace", "--app-main-executable",
    "--app-cli-executable",  "--manifest",              "--source-root",             "--zig",               "--zig-size",           "--zig-sha256",
    "--durable-preparation", "--predecessor-workspace", "--upgrade-workspace",       "--timing-output",
};

pub const Command = struct {
    root_path: []const u8,
    root_identity: []const u8,
    validator_args: []const []const u8,
};

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len < 4) return error.InvalidArguments;
    if (args.len > max_run_arguments) return error.TooManyArguments;
    if (!std.mem.eql(u8, args[0], "run")) return error.InvalidCommand;
    if (!owner.canonicalRootPath(args[1])) return error.InvalidPath;
    return .{ .root_path = args[1], .root_identity = args[2], .validator_args = args[3..] };
}

pub fn parseProfiled(args: []const []const u8) Error!ProfiledCommand {
    if (args.len != max_arguments) return if (args.len > max_arguments) error.TooManyArguments else error.InvalidArguments;
    if (!std.mem.eql(u8, args[0], "run-profiled-stage3")) return error.InvalidCommand;
    if (!owner.canonicalRootPath(args[1])) return error.InvalidPath;
    var values: [profiled_option_count]?[]const u8 = @splat(null);
    var index: usize = 3;
    while (index < args.len) : (index += 2) {
        const option = args[index];
        const value = args[index + 1];
        if (value.len == 0 or value.len > contract.max_cli_value_bytes) return error.InvalidArguments;
        var found: ?usize = null;
        for (profiled_options, 0..) |candidate, candidate_index| {
            if (std.mem.eql(u8, option, candidate)) {
                found = candidate_index;
                break;
            }
        }
        const option_index = found orelse return error.InvalidArguments;
        if (values[option_index] != null) return error.InvalidArguments;
        values[option_index] = value;
    }
    for (&values) |value| if (value == null) return error.InvalidArguments;

    var result: ProfiledCommand = .{
        .root_path = args[1],
        .root_identity = args[2],
        .baseline_args = undefined,
        .profile_args = undefined,
    };
    result.baseline_args = commandArgs("prepare-candidate", &values, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 });
    result.profile_args = commandArgs("prepare-profile-candidate", &values, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 19, 20, 18, 21 });
    const baseline = switch (try contract.parseArgs(&result.baseline_args)) {
        .prepare_candidate => |value| value,
        else => unreachable,
    };
    const upgrade = switch (try contract.parseArgs(&result.profile_args)) {
        .prepare_profile_candidate => |value| value,
        else => unreachable,
    };
    try contract.validateProfiledStage3Pair(baseline, upgrade);
    return result;
}

fn commandArgs(command: []const u8, values: *const [profiled_option_count]?[]const u8, comptime indices: []const usize) [contract.max_command_args][]const u8 {
    comptime if (indices.len * 2 + 1 != contract.max_command_args) @compileError("profiled stage-3 argv size drift");
    var result: [contract.max_command_args][]const u8 = undefined;
    result[0] = command;
    inline for (indices, 0..) |source, destination| {
        result[destination * 2 + 1] = profiled_options[source];
        result[destination * 2 + 2] = values[source].?;
    }
    return result;
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, workflow: context.Context) Error!void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "run-profiled-stage3"))
        return executeProfiled(io, allocator, args, workflow);
    const parsed = try parse(args);
    return executeCommand(io, allocator, parsed.root_path, parsed.root_identity, parsed.validator_args, workflow);
}

fn executeCommand(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, root_identity: []const u8, validator_args: []const []const u8, workflow: context.Context) Error!void {
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = std.fmt.bufPrintZ(&root_storage, "{s}", .{root_path}) catch return error.InvalidPath;
    const execution = try allocator.create(command_process.Execution);
    defer allocator.destroy(execution);
    execution.* = .{};
    try owner.commandProcess(io, allocator, root, root_identity, workflow, validator_args, execution);
}

fn executeProfiled(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, workflow: context.Context) Error!void {
    var marker: u8 = 0;
    const profile_environment: profile.Environment = .{ .context = @ptrCast(&marker), .read_fn = readProfileEnvironment };
    const execution = try allocator.create(ProfiledExecution);
    defer allocator.destroy(execution);
    execution.* = .{};
    try execution.init(allocator, args, workflow, profile_environment);
    defer if (execution.owner == execution) execution.deinit() catch {};
    try execution.run(io, allocator, workflow, profile_environment);
}

fn readProfileEnvironment(_: *anyopaque, name: [:0]const u8) ?[]const u8 {
    return std.mem.span(c.getenv(name) orelse return null);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [max_arguments][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    const workflow = try environment.readCurrent();
    try execute(init.io, init.gpa, values[0..count], workflow);
}
