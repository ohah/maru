//! Fresh-process, credential-free bridge for the authored subject selector.

const std = @import("std");
const c = std.c;
const environment_mod = @import("release_adapter_environment");
const profile_mod = @import("release_adapter_profile_endorsement");
const projection = @import("release_adapter_profile_authored_attestation_projection");

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [projection.argument_count][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    const context = try environment_mod.readCurrent();
    var marker: u8 = 0;
    const profile_environment: profile_mod.Environment = .{ .context = @ptrCast(&marker), .read_fn = readProfileEnvironment };
    const execution = try init.gpa.create(projection.Execution);
    defer init.gpa.destroy(execution);
    execution.* = .{};
    const output = try projection.compose(init.gpa, context, profile_environment, values[0..count], execution);
    defer if (execution.owner == execution) execution.deinit() catch {};
    var stdout_buffer: [projection.max_output_bytes]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_file_writer.interface.writeAll(output);
    try stdout_file_writer.interface.flush();
    try execution.deinit();
}

fn readProfileEnvironment(_: *anyopaque, name: [:0]const u8) ?[]const u8 {
    return std.mem.span(c.getenv(name) orelse return null);
}
