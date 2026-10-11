//! Test-only process driver. Never installed or used as the product hook entrypoint.
const std = @import("std");
const writer = @import("platform/agent_log_writer.zig");
const codec = @import("session/agent_log_generation.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const directory = args.next() orelse return error.InvalidArguments;
    const mode = args.next() orelse return error.InvalidArguments;
    const dir = try std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(init.io);
    const out = std.Io.File.stdout();
    if (std.mem.eql(u8, mode, "hold")) {
        const lease = try writer.acquire(init.io, dir, "a");
        defer lease.release(init.io);
        try out.writeStreamingAll(init.io, "ready\n");
        while (true) try std.Io.sleep(init.io, .fromMilliseconds(1000), .awake);
    }
    if (std.mem.eql(u8, mode, "append")) {
        const tag = args.next() orelse return error.InvalidArguments;
        const count = try std.fmt.parseInt(u16, args.next() orelse "1", 10);
        if (count == 0 or count > 1000 or tag.len > 64) return error.InvalidArguments;
        for (tag) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidArguments;
        const deadline = std.Io.Clock.awake.now(init.io).nanoseconds + 1500 * std.time.ns_per_ms;
        var result: codec.Position = undefined;
        for (0..count) |index| {
            var buffer: [256]u8 = undefined;
            const line = try std.fmt.bufPrint(&buffer, "claude\t{{\"tag\":\"{s}{d}\"}}\n", .{ tag, index });
            while (true) {
                result = writer.append(init.io, dir, "a", line) catch |err| {
                    if (err != error.WouldBlock or std.Io.Clock.awake.now(init.io).nanoseconds >= deadline) return err;
                    try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
                    continue;
                };
                break;
            }
        }
        const encoded = codec.encodeGeneration(result.generation);
        var buffer: [256]u8 = undefined;
        try out.writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "{{\"gen\":\"{s}\",\"at\":{d}}}\n", .{ encoded, result.offset }));
    } else if (std.mem.eql(u8, mode, "rotate")) {
        const generation = try codec.decodeGeneration(args.next() orelse return error.InvalidArguments);
        const offset = try std.fmt.parseInt(u64, args.next() orelse return error.InvalidArguments, 10);
        const snapshot = try std.fmt.parseInt(u64, args.next() orelse return error.InvalidArguments, 10);
        const position = try writer.rotate(init.io, dir, "a", .{ .generation = generation, .offset = offset }, snapshot);
        if (position) |p| {
            const encoded = codec.encodeGeneration(p.generation);
            var buffer: [256]u8 = undefined;
            try out.writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "{{\"gen\":\"{s}\",\"at\":0}}\n", .{encoded}));
        } else try out.writeStreamingAll(init.io, "null\n");
    } else return error.InvalidArguments;
}
