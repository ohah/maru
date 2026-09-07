//! Product fresh-process bridge between GitHub action outcomes and durable workflow checkpoints.

const std = @import("std");
const context = @import("release_adapter_context");
const environment = @import("release_adapter_environment");
const owner = @import("release_adapter_live_workflow_owner");
const phase = @import("release_adapter_live_workflow_phase");

pub const Error = owner.Error || context.Error || error{
    InvalidArguments,
    InvalidCommand,
    InvalidPath,
    InvalidResult,
    InvalidStage,
    TooManyArguments,
};

const Target = struct {
    root_path: []const u8,
    root_identity: []const u8,
    invocation: owner.Invocation,
};

const Commit = struct {
    target: Target,
    result: phase.Result,
};

pub const Command = union(enum) {
    admit: Target,
    commit: Commit,
};

pub fn parse(args: []const []const u8) Error!Command {
    if (args.len == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "admit")) {
        if (args.len != 4) return error.InvalidArguments;
        return .{ .admit = try target(args[1], args[2], args[3]) };
    }
    if (std.mem.eql(u8, args[0], "commit")) {
        if (args.len != 5) return error.InvalidArguments;
        return .{ .commit = .{
            .target = try target(args[1], args[2], args[3]),
            .result = try parseResult(args[4]),
        } };
    }
    return error.InvalidCommand;
}

pub fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    workflow: context.Context,
) Error!void {
    const command = try parse(args);
    const selected = switch (command) {
        .admit => |value| value,
        .commit => |value| value.target,
    };
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = std.fmt.bufPrintZ(&path_storage, "{s}", .{selected.root_path}) catch
        return error.InvalidPath;
    switch (command) {
        .admit => try owner.admitActionProcess(allocator, root_path, selected.root_identity, workflow, selected.invocation),
        .commit => |value| try owner.commitActionProcess(allocator, root_path, selected.root_identity, workflow, selected.invocation, value.result),
    }
}

fn target(root_path: []const u8, root_identity: []const u8, stage_text: []const u8) Error!Target {
    if (root_path.len == 0 or root_path[0] != '/' or root_path.len >= std.fs.max_path_bytes)
        return error.InvalidPath;
    return .{
        .root_path = root_path,
        .root_identity = root_identity,
        .invocation = try parseInvocation(stage_text),
    };
}

fn parseInvocation(text: []const u8) Error!owner.Invocation {
    if (std.mem.eql(u8, text, "candidate_attestation")) return .{ .candidate_attestation = {} };
    if (std.mem.eql(u8, text, "authored_attestation")) return .{ .authored_attestation = {} };
    return error.InvalidStage;
}

fn parseResult(text: []const u8) Error!phase.Result {
    if (std.mem.eql(u8, text, "succeeded")) return .succeeded;
    if (std.mem.eql(u8, text, "failed")) return .failed;
    return error.InvalidResult;
}

pub fn main(init: std.process.Init) !void {
    var values: [5][]const u8 = undefined;
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
