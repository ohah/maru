//! Product fresh-process bridge for validator-backed live workflow stages.

const std = @import("std");
const context = @import("release_adapter_context");
const contract = @import("release_adapter_contract");
const environment = @import("release_adapter_environment");
const owner = @import("release_adapter_live_workflow_owner");
const command_process = @import("release_adapter_live_workflow_command_process");

pub const max_arguments: usize = 3 + contract.max_command_args;
pub const Error = owner.Error || context.Error || error{
    InvalidArguments,
    InvalidCommand,
    InvalidPath,
    TooManyArguments,
};

pub const Command = struct {
    root_path: []const u8,
    root_identity: []const u8,
    validator_args: []const []const u8,
};

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len < 4) return error.InvalidArguments;
    if (args.len > max_arguments) return error.TooManyArguments;
    if (!std.mem.eql(u8, args[0], "run")) return error.InvalidCommand;
    if (!owner.canonicalRootPath(args[1])) return error.InvalidPath;
    return .{ .root_path = args[1], .root_identity = args[2], .validator_args = args[3..] };
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, workflow: context.Context) Error!void {
    const parsed = try parse(args);
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = std.fmt.bufPrintZ(&root_storage, "{s}", .{parsed.root_path}) catch return error.InvalidPath;
    const execution = try allocator.create(command_process.Execution);
    defer allocator.destroy(execution);
    execution.* = .{};
    try owner.commandProcess(io, allocator, root, parsed.root_identity, workflow, parsed.validator_args, execution);
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
