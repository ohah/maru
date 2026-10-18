//! Emits a visible skip reason for a build gate that does not apply to this host.
//! Zig 0.17 removed custom Step.makeFn callbacks, so this tiny host tool backs those notices.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    _ = args.next();
    while (args.next()) |message| std.debug.print("{s}\n", .{message});
}
