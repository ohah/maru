//! CR6e-b final soak validator. Every numbered raw pair must exist and pass the same hard budgets.

const std = @import("std");
const budget = @import("session_host_cr6e_budget_validator.zig");

const required_batches: usize = 20;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const root = args.next() orelse return error.MissingArtifactRoot;
    if (args.next() != null) return error.TooManyArguments;

    for (0..required_batches) |index| {
        const transport_path = try std.fmt.allocPrint(allocator, "{s}/transport-{d}.json", .{ root, index });
        defer allocator.free(transport_path);
        const recovery_path = try std.fmt.allocPrint(allocator, "{s}/recovery-{d}.json", .{ root, index });
        defer allocator.free(recovery_path);
        const transport = try std.Io.Dir.cwd().readFileAlloc(io, transport_path, allocator, .limited(1024 * 1024));
        defer allocator.free(transport);
        const recovery = try std.Io.Dir.cwd().readFileAlloc(io, recovery_path, allocator, .limited(1024 * 1024));
        defer allocator.free(recovery);
        try budget.validatePairBytes(allocator, transport, recovery);
    }
    const extra_transport = try std.fmt.allocPrint(allocator, "{s}/transport-{d}.json", .{ root, required_batches });
    defer allocator.free(extra_transport);
    const extra_recovery = try std.fmt.allocPrint(allocator, "{s}/recovery-{d}.json", .{ root, required_batches });
    defer allocator.free(extra_recovery);
    if (try fileExists(io, extra_transport) or try fileExists(io, extra_recovery))
        return error.UnexpectedExtraBatch;
    std.debug.print("CR6e-b soak validated: {d} transport pairs, {d} actual-AppKit recoveries\n", .{
        required_batches * 2,
        required_batches * 5,
    });
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "CR6e-b soak batch count is pinned" {
    try std.testing.expectEqual(@as(usize, 20), required_batches);
}
