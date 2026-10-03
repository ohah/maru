//! Measure the actual C2 publisher including its create-once backup; not the fsync prototype.
const std = @import("std");
const file = @import("checkpoint_file");
pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len != 4) return error.ExpectedParentBytesMode;
    const parent = try a.dupeZ(u8, args[1]);
    defer a.free(parent);
    const count = try std.fmt.parseInt(usize, args[2], 10);
    const bytes = try a.alloc(u8, count);
    defer a.free(bytes);
    @memset(bytes, 'x');
    try std.Io.Dir.cwd().createDirPath(init.io, parent);
    if (file.publish(parent, bytes) != .committed or file.publish(parent, bytes) != .committed) return error.SeedFailed;
    for (0..5) |iteration| {
        if (std.mem.eql(u8, args[3], "rearm") and file.releaseBackup(parent) != .committed) return error.ReleaseFailed;
        const start = std.Io.Clock.awake.now(init.io).nanoseconds;
        if (file.publish(parent, bytes) != .committed) return error.PublishFailed;
        const end = std.Io.Clock.awake.now(init.io).nanoseconds;
        const path = try std.fmt.allocPrint(a, "{s}/workspace.v1", .{parent});
        defer a.free(path);
        const loaded = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(count + 1));
        defer a.free(loaded);
        if (!std.mem.eql(u8, loaded, bytes)) return error.BytesChanged;
        std.debug.print("bytes={d} mode={s} iteration={d} publish_us={d}\n", .{ count, args[3], iteration, @divTrunc(end - start, 1000) });
    }
}
