//! Product bootstrap for one protected live release workflow checkpoint root.

const std = @import("std");
const context = @import("release_adapter_context");
const environment = @import("release_adapter_environment");
const owner = @import("release_adapter_live_workflow_owner");

pub const max_token_bytes: usize = owner.max_bootstrap_token_bytes;
pub const Error = owner.Error || context.Error || error{
    InvalidArguments,
    InvalidCommand,
    InvalidPath,
    TooManyArguments,
};

pub const Command = struct { root_path: []const u8 };

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len != 2) return error.InvalidArguments;
    if (!std.mem.eql(u8, args[0], "initialize")) return error.InvalidCommand;
    const path = args[1];
    if (!owner.canonicalRootPath(path)) return error.InvalidPath;
    return .{ .root_path = path };
}

pub fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    workflow: context.Context,
    token_storage: *[max_token_bytes:0]u8,
) Error![:0]const u8 {
    const command = try parse(args);
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = std.fmt.bufPrintZ(&path_storage, "{s}", .{command.root_path}) catch return error.InvalidPath;
    return owner.bootstrapProcess(allocator, root_path, workflow, token_storage);
}

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [2][]const u8 = undefined;
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
    var token_storage: [max_token_bytes:0]u8 = undefined;
    const token = try execute(init.gpa, values[0..count], workflow, &token_storage);
    var stdout_buffer: [max_token_bytes + 1]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(token);
    try stdout.writeByte('\n');
    try stdout.flush();
}
