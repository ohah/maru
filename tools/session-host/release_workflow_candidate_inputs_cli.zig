//! Product fresh-process bridge for signed candidate input validation and stage settlement.

const std = @import("std");
const context = @import("release_adapter_context");
const environment = @import("release_adapter_environment");
const owner = @import("release_adapter_live_workflow_owner");

pub const Error = owner.Error || context.Error || error{
    InvalidArguments,
    InvalidCommand,
    InvalidPath,
    TooManyArguments,
};

pub const Command = struct {
    root_path: []const u8,
    root_identity: []const u8,
    candidate_directory: []const u8,
};

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len != 4) return error.InvalidArguments;
    if (!std.mem.eql(u8, args[0], "pin")) return error.InvalidCommand;
    if (!owner.canonicalRootPath(args[1]) or !owner.canonicalRootPath(args[3])) return error.InvalidPath;
    return .{ .root_path = args[1], .root_identity = args[2], .candidate_directory = args[3] };
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, workflow: context.Context) Error!void {
    const command = try parse(args);
    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var candidate_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root = std.fmt.bufPrintZ(&root_storage, "{s}", .{command.root_path}) catch return error.InvalidPath;
    const candidate = std.fmt.bufPrintZ(&candidate_storage, "{s}", .{command.candidate_directory}) catch return error.InvalidPath;
    try owner.candidateInputsProcess(allocator, root, command.root_identity, workflow, candidate);
}

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [4][]const u8 = undefined;
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
    try execute(init.gpa, values[0..count], workflow);
}
