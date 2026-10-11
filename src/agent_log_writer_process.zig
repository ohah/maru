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
    if (std.mem.eql(u8, mode, "hook-transition") or std.mem.eql(u8, mode, "hook-trust")) {
        const binary = args.next() orelse return error.InvalidArguments;
        const provider = args.next() orelse return error.InvalidArguments;
        const local = args.next() orelse return error.InvalidArguments;
        const remote = args.next() orelse return error.InvalidArguments;
        const native_local = args.next() orelse return error.InvalidArguments;
        const native_remote = args.next() orelse return error.InvalidArguments;
        var generated: std.ArrayListUnmanaged(u8) = .empty;
        defer generated.deinit(init.gpa);
        try @import("session/agent_hook_command.zig").buildTransition(&generated, init.gpa, provider, local, remote, .{ .local = native_local, .remote = native_remote }, binary);
        if (std.mem.eql(u8, mode, "hook-trust")) {
            // Export product hashes for an external provider oracle, not a duplicate formula.
            const trust = @import("session/agent_hook_trust.zig");
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const hooks_path = try std.fmt.allocPrint(a, "{s}/hooks.json", .{directory});
            const Entry = struct { event: []const u8, key: []const u8, hash: []const u8 };
            var entries: [trust.events.len]Entry = undefined;
            var slots: [trust.events.len]trust.Slot = undefined;
            for (trust.events, 0..) |event, i| {
                var key: std.ArrayListUnmanaged(u8) = .empty;
                var hash: std.ArrayListUnmanaged(u8) = .empty;
                try trust.appendKey(&key, a, hooks_path, event, 0, 0);
                try trust.appendHash(&hash, a, event, generated.items, @import("session/agent_hook_command.zig").timeout_seconds, "*");
                entries[i] = .{ .event = event.json_name, .key = key.items, .hash = hash.items };
                slots[i] = .{ .json_name = event.json_name, .group_index = 0, .handler_index = 0, .matcher = "*" };
            }
            var config: std.ArrayListUnmanaged(u8) = .empty;
            try config.appendSlice(a, args.next() orelse "");
            const stats = try trust.applyEntries(&config, a, hooks_path, &slots, generated.items, @import("session/agent_hook_command.zig").timeout_seconds);
            const json = try std.json.Stringify.valueAlloc(a, .{ .command = generated.items, .entries = entries, .config = config.items, .stats = stats }, .{});
            try out.writeStreamingAll(init.io, json);
        } else try out.writeStreamingAll(init.io, generated.items);
        return;
    }
    if (std.mem.eql(u8, mode, "hook") or std.mem.eql(u8, mode, "hook-legacy")) {
        const binary = args.next() orelse return error.InvalidArguments;
        const provider = args.next() orelse "claude";
        var generated: std.ArrayListUnmanaged(u8) = .empty;
        defer generated.deinit(init.gpa);
        const command = @import("session/agent_hook_command.zig");
        if (std.mem.eql(u8, mode, "hook"))
            try command.buildNative(&generated, init.gpa, provider, directory, directory, binary)
        else
            try command.build(&generated, init.gpa, provider, directory, directory);
        try out.writeStreamingAll(init.io, generated.items);
        return;
    }
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
