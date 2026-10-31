//! Fresh-process, credential-free bridge for the authored subject selector.

const std = @import("std");
const c = std.c;
const environment_mod = @import("release_adapter_environment");
const profile_mod = @import("release_adapter_profile_endorsement");
const projection = @import("release_adapter_profile_authored_attestation_projection");
const fence_command = @import("release_adapter_profile_authored_attestation_fence_command");

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch |err| {
        diagnosticError("selector", @errorName(err), diagnostic_expected_rejection);
        std.process.exit(1);
    };
}

fn mainFallible(init: std.process.Init) !void {
    var values: [fence_command.argument_count][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    diagnostic_expected_rejection = count > 14 and std.mem.eql(u8, values[14], "forged-evidence.json");
    const context = try environment_mod.readCurrent();
    var marker: u8 = 0;
    const profile_environment: profile_mod.Environment = .{ .context = @ptrCast(&marker), .read_fn = readProfileEnvironment };
    if (count > 0 and std.mem.eql(u8, values[0], "fence")) {
        const execution = try init.gpa.create(fence_command.Execution);
        defer init.gpa.destroy(execution);
        execution.* = .{};
        const output = try fence_command.compose(init.io, init.gpa, context, profile_environment, values[0..count], execution);
        defer if (execution.owner == execution) execution.deinit() catch {};
        var stdout_buffer: [fence_command.max_output_bytes]u8 = undefined;
        var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        try stdout_file_writer.interface.writeAll(output);
        try stdout_file_writer.interface.flush();
        try execution.deinit();
        return;
    }
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

var diagnostic_expected_rejection = false;

// Temporary CI diagnosis only. Remove before proposing a product change.
extern "c" fn getdtablesize() c_int;
fn diagnosticError(component: []const u8, name: []const u8, expected: bool) void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "component={s} pid={d} ppid={d} mode={s} error={s} expected={} fd_limit={d}\n", .{ component, c.getpid(), c.getppid(), @tagName(@import("builtin").mode), name, expected, getdtablesize() }) catch return;
    const fd = c.open("zig-out/fence-child-errors.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd >= 0) {
        _ = c.write(fd, line.ptr, line.len);
        _ = c.close(fd);
    }
}
